@preconcurrency import MultipeerConnectivity

import BlinkCore
import CryptoKit
import Foundation

/// Advertises a read-only snapshot service over Multipeer Connectivity.
/// `MCSession` encryption is mandatory; a new device receives no note data
/// until the Mac explicitly approves its private credential.
public final class BlinkLANPeerServer: NSObject, @unchecked Sendable {
    public static let serviceType = "blink-notes"
    public typealias ApprovalHandler = @Sendable (BlinkPeerClientIdentity) async -> Bool

    /// A denial silences new prompts for a while, so a device that loops
    /// connect → requestAccess cannot stack focus-stealing modals.
    static let approvalCooldown: TimeInterval = 60

    public let host: BlinkPeerHost

    private let snapshotService: BlinkSnapshotService
    private let trustStore: BlinkPeerTrustStore
    private let approvalHandler: ApprovalHandler
    private let hostAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let lock = NSLock()
    /// Bookkeeping for revoke-time disconnects, never the authorization boundary.
    private var authorizedCredentialsByPeerKey: [String: String] = [:]
    /// At most one approval prompt is outstanding process-wide, so two peers can
    /// never drive nested `runModal()` sessions on the main queue.
    private var pendingApprovalPeerKey: String?
    private var approvalPausedUntil: Date?
    private var advertisingFailureStorage: String?
    private var statusObserver: (@Sendable () -> Void)?

    enum ApprovalGate: Equatable {
        case ask
        case alreadyPending
        case cooling
    }

    public init(
        hostID: String,
        displayName: String,
        snapshotService: BlinkSnapshotService,
        trustStore: BlinkPeerTrustStore = BlinkPeerTrustStore(),
        approvalHandler: @escaping ApprovalHandler = { _ in false }
    ) throws {
        let hostAgreementPrivateKey = try trustStore.hostAgreementPrivateKey()
        let hostPublicKey = hostAgreementPrivateKey.publicKey.rawRepresentation.base64EncodedString()
        self.host = BlinkPeerHost(id: hostID, name: displayName, publicKey: hostPublicKey)
        self.snapshotService = snapshotService
        self.trustStore = trustStore
        self.approvalHandler = approvalHandler
        self.hostAgreementPrivateKey = hostAgreementPrivateKey

        let peerID = MCPeerID(displayName: displayName)
        self.peerID = peerID
        self.session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: [
                "version": BlinkPeerWire.discoveryVersion,
                "hostID": hostID,
                "hostKey": hostPublicKey,
            ],
            serviceType: Self.serviceType
        )
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    public func start() {
        lock.withLock { advertisingFailureStorage = nil }
        advertiser.startAdvertisingPeer()
        notifyStatusChange()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        lock.withLock {
            authorizedCredentialsByPeerKey.removeAll()
            pendingApprovalPeerKey = nil
            approvalPausedUntil = nil
        }
    }

    public var trustedPeers: [BlinkTrustedPeer] {
        trustStore.peers
    }

    public var advertisingFailure: String? {
        lock.withLock { advertisingFailureStorage }
    }

    /// Set when the Keychain refused the approved-device list. Pairing still
    /// works for this launch, but approvals will not survive a restart.
    public var trustPersistenceFailure: String? {
        trustStore.persistenceFailure
    }

    public func observeStatus(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { statusObserver = observer }
        observer()
    }

    @discardableResult
    public func revokeTrustedPeer(id: String) throws -> Bool {
        let hadLiveSession = try lock.withLock { () throws -> Bool? in
            guard try trustStore.revoke(id: id) else { return nil }
            let matchingKeys = authorizedCredentialsByPeerKey.compactMap { key, credential in
                credential == id ? key : nil
            }
            matchingKeys.forEach { authorizedCredentialsByPeerKey[$0] = nil }
            return !matchingKeys.isEmpty
        }
        guard let hadLiveSession else { return false }
        if hadLiveSession {
            // MCSession only exposes whole-session disconnect. Other approved
            // devices can reconnect immediately without another prompt.
            session.disconnect()
        }
        return true
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard let envelope = try? JSONDecoder().decode(BlinkPeerRequestEnvelope.self, from: data),
              envelope.version == BlinkPeerWire.version,
              let responseKey = try? BlinkPeerCrypto.symmetricKey(
                  privateKey: hostAgreementPrivateKey,
                  peerPublicKey: envelope.clientPublicKey
              ),
              let request = try? BlinkPeerCrypto.open(
                  BlinkPeerRequest.self,
                  from: envelope.sealedPayload,
                  using: responseKey
              )
        else { return }

        switch request {
        case .requestAccess(let requestedIdentity):
            let key = peerKey(peer)
            guard BlinkPeerCrypto.isWellFormedCredential(requestedIdentity.credential) else {
                send(
                    .failure(BlinkPeerFailure(code: "invalid-identity", message: "Canvas on this device needs to be reinstalled.")),
                    id: envelope.id,
                    to: peer,
                    using: responseKey
                )
                return
            }
            let identity = BlinkPeerClientIdentity(
                credential: requestedIdentity.credential,
                name: peer.displayName
            )

            if lock.withLock({ trustStore.contains(credential: identity.credential) }) {
                grantAccess(
                    to: identity,
                    requestID: envelope.id,
                    peer: peer,
                    using: responseKey,
                    approving: false
                )
                return
            }

            switch claimApprovalSlot(for: key) {
            case .alreadyPending:
                send(
                    .failure(BlinkPeerFailure(code: "approval-pending", message: "An approval request is already open on your Mac.")),
                    id: envelope.id,
                    to: peer,
                    using: responseKey
                )
                return
            case .cooling:
                send(
                    .failure(BlinkPeerFailure(code: "access-denied", message: "Access wasn’t allowed on your Mac. Try again in a minute.")),
                    id: envelope.id,
                    to: peer,
                    using: responseKey
                )
                return
            case .ask:
                break
            }

            Task { [approvalHandler] in
                let approved = await approvalHandler(identity)
                self.releaseApprovalSlot(approved: approved)
                guard approved else {
                    self.send(
                        .failure(BlinkPeerFailure(code: "access-denied", message: "Access wasn’t allowed on your Mac.")),
                        id: envelope.id,
                        to: peer,
                        using: responseKey
                    )
                    return
                }
                self.grantAccess(
                    to: identity,
                    requestID: envelope.id,
                    peer: peer,
                    using: responseKey,
                    approving: true
                )
            }

        case .fetchSnapshot(let credential, let etag):
            // Authorize on the credential presented inside the sealed payload,
            // not on the peer's self-chosen display name and MCPeerID hash.
            let authorizedCredential = lock.withLock { () -> String? in
                let key = peerKey(peer)
                guard BlinkPeerCrypto.isWellFormedCredential(credential),
                      trustStore.contains(credential: credential)
                else {
                    authorizedCredentialsByPeerKey[key] = nil
                    return nil
                }
                authorizedCredentialsByPeerKey[key] = credential
                return credential
            }
            guard let authorizedCredential else {
                send(
                    .failure(BlinkPeerFailure(code: "unauthorized", message: "Request access from this Mac before syncing.")),
                    id: envelope.id,
                    to: peer,
                    using: responseKey
                )
                return
            }
            Task { [snapshotService] in
                do {
                    let result = try await snapshotService.fetchSnapshot(ifNoneMatch: etag)
                    self.sendIfAuthorized(
                        .snapshot(result),
                        id: envelope.id,
                        credential: authorizedCredential,
                        to: peer,
                        using: responseKey
                    )
                } catch {
                    self.send(
                        .failure(BlinkPeerFailure(code: "snapshot-failed", message: error.localizedDescription)),
                        id: envelope.id,
                        to: peer,
                        using: responseKey
                    )
                }
            }
        }
    }

    private func grantAccess(
        to identity: BlinkPeerClientIdentity,
        requestID: UUID,
        peer: MCPeerID,
        using responseKey: SymmetricKey,
        approving: Bool
    ) {
        guard session.connectedPeers.contains(peer) else { return }
        let granted = lock.withLock { () -> Bool in
            if approving {
                _ = trustStore.approve(identity)
            } else {
                guard trustStore.contains(credential: identity.credential) else { return false }
                _ = trustStore.approve(identity)
            }
            authorizedCredentialsByPeerKey[peerKey(peer)] = identity.credential
            return true
        }
        notifyStatusChange()
        guard granted else {
            send(
                .failure(BlinkPeerFailure(code: "unauthorized", message: "Request access from this Mac before syncing.")),
                id: requestID,
                to: peer,
                using: responseKey
            )
            return
        }
        send(.accessGranted(host), id: requestID, to: peer, using: responseKey)
    }

    private func send(
        _ response: BlinkPeerResponse,
        id: UUID,
        to peer: MCPeerID,
        using responseKey: SymmetricKey
    ) {
        guard session.connectedPeers.contains(peer),
              let sealedPayload = try? BlinkPeerCrypto.seal(response, using: responseKey),
              let data = try? JSONEncoder().encode(
                BlinkPeerResponseEnvelope(id: id, sealedPayload: sealedPayload)
              ) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func notifyStatusChange() {
        let observer = lock.withLock { statusObserver }
        observer?()
    }

    /// Serialize the final authorization check and send initiation with revoke.
    /// Once `session.send` returns, the encrypted payload was queued while the
    /// credential was still trusted; revoke can then disconnect the session.
    private func sendIfAuthorized(
        _ response: BlinkPeerResponse,
        id: UUID,
        credential: String,
        to peer: MCPeerID,
        using responseKey: SymmetricKey
    ) {
        guard let sealedPayload = try? BlinkPeerCrypto.seal(response, using: responseKey),
              let data = try? JSONEncoder().encode(
                  BlinkPeerResponseEnvelope(id: id, sealedPayload: sealedPayload)
              )
        else { return }

        lock.withLock {
            guard authorizedCredentialsByPeerKey[peerKey(peer)] == credential,
                  trustStore.contains(credential: credential),
                  session.connectedPeers.contains(peer)
            else { return }
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    /// Take the single process-wide approval slot, or say why the request
    /// cannot raise a prompt right now.
    func claimApprovalSlot(for key: String, now: Date = Date()) -> ApprovalGate {
        lock.withLock {
            if let approvalPausedUntil, approvalPausedUntil > now { return .cooling }
            guard pendingApprovalPeerKey == nil else { return .alreadyPending }
            pendingApprovalPeerKey = key
            return .ask
        }
    }

    func releaseApprovalSlot(approved: Bool, now: Date = Date()) {
        lock.withLock {
            pendingApprovalPeerKey = nil
            // Only a denial starts the cooldown; an approved device should be
            // able to keep working immediately.
            if !approved {
                approvalPausedUntil = now.addingTimeInterval(Self.approvalCooldown)
            }
        }
    }

    private func peerKey(_ peer: MCPeerID) -> String {
        "\(peer.displayName)#\(peer.hash)"
    }

}

extension BlinkLANPeerServer: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        invitationHandler(true, session)
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        lock.withLock { advertisingFailureStorage = error.localizedDescription }
        notifyStatusChange()
    }
}

extension BlinkLANPeerServer: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected {
            // The pending-approval slot is deliberately not released here: the
            // alert is still on screen, and a peer that disconnects mid-prompt
            // must not be able to open a second one.
            lock.withLock { authorizedCredentialsByPeerKey[peerKey(peerID)] = nil }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        receive(data, from: peerID)
    }

    public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
