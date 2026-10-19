import CryptoKit
import Foundation

/// The private, app-scoped credential a mobile device presents inside an encrypted
/// peer session. The value is random and never shown as part of the pairing UI.
public struct BlinkPeerClientIdentity: Codable, Equatable, Sendable {
    public var credential: String
    public var name: String

    public init(credential: String, name: String) {
        self.credential = credential
        self.name = name
    }
}

/// A device the Mac has explicitly approved for read-only note access.
public struct BlinkTrustedPeer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var approvedAt: Date

    public init(id: String, name: String, approvedAt: Date = .now) {
        self.id = id
        self.name = name
        self.approvedAt = approvedAt
    }
}

enum BlinkPeerTrustStoreError: Error, LocalizedError {
    case invalidHostKey

    var errorDescription: String? {
        switch self {
        case .invalidHostKey:
            return "Canvas's saved Mac identity is invalid. Remove its Keychain item before retrying."
        }
    }
}

/// Persists approved device credentials. Authorization is still enforced per
/// request against the credential inside the encrypted session; this store only
/// decides whether the Mac must ask the person again when a device reconnects.
///
/// Both the credential list and the host agreement private key are bearer
/// secrets, so they live in the Keychain rather than in `UserDefaults`.
public final class BlinkPeerTrustStore: @unchecked Sendable {
    private static let productionStorageKey = "blink.peer.trusted-devices"

    /// Inspect existing approvals without initializing the normal trust store,
    /// which intentionally removes obsolete preference-based credentials.
    public static func mobileAccessEnabled(configuration: Data?, hasHomeOverride: Bool) -> Bool {
        BlinkMobileAccessPolicy.resolve(
            configuration: configuration,
            hasHomeOverride: hasHomeOverride
        ) {
            try BlinkKeychainSecretStorage().data(forKey: productionStorageKey)
        }
    }

    private let storage: any BlinkPeerSecretStorage
    private let storageKey: String
    private let lock = NSLock()
    private var cachedPeers: [BlinkTrustedPeer]?
    private var cachedHostKey: Curve25519.KeyAgreement.PrivateKey?
    private var persistenceFailureStorage: String?

    public convenience init() {
        self.init(storage: BlinkKeychainSecretStorage(), storageKey: Self.productionStorageKey)
        // The old UserDefaults values are deliberately not migrated: a plist is
        // readable by any user-level process and travels in Preferences
        // backups, so an already-approved credential could be replayed from
        // another machine. Devices approved before this build pair once more.
        // This mirrors the iOS companion's non-migrating device seed.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.productionStorageKey)
        defaults.removeObject(forKey: "\(Self.productionStorageKey).host-agreement-key")
    }

    init(storage: any BlinkPeerSecretStorage, storageKey: String = productionStorageKey) {
        self.storage = storage
        self.storageKey = storageKey
    }

    public var peers: [BlinkTrustedPeer] {
        lock.withLock { load() }
    }

    /// Non-nil when the Keychain refused a read or write. The trusted set still
    /// works for the life of the process, but it will not survive a relaunch.
    public var persistenceFailure: String? {
        lock.withLock { persistenceFailureStorage }
    }

    public func contains(credential: String) -> Bool {
        lock.withLock { load().contains { $0.id == credential } }
    }

    @discardableResult
    public func approve(_ identity: BlinkPeerClientIdentity) -> BlinkTrustedPeer {
        lock.withLock {
            var current = load()
            if let index = current.firstIndex(where: { $0.id == identity.credential }) {
                // The stored name is pinned at first approval. A device holding
                // a valid credential must not be able to relabel its own row in
                // the Revoke menu to look like a different, expected device.
                return current[index]
            }

            let peer = BlinkTrustedPeer(id: identity.credential, name: identity.name)
            current.append(peer)
            save(current)
            return peer
        }
    }

    @discardableResult
    public func revoke(id: String) throws -> Bool {
        try lock.withLock {
            var current = load()
            let oldCount = current.count
            current.removeAll { $0.id == id }
            guard current.count != oldCount else { return false }
            do {
                let data = try JSONEncoder().encode(current)
                try storage.set(data, forKey: storageKey)
                cachedPeers = current
                persistenceFailureStorage = nil
                return true
            } catch {
                // Revocation is a security boundary: do not report success or
                // update the in-process set unless the removal is durable.
                persistenceFailureStorage = error.localizedDescription
                throw error
            }
        }
    }

    /// A stable app-layer agreement key authenticates this Mac across
    /// Multipeer sessions. The framework still supplies mandatory transport
    /// encryption; this key creates an end-to-end sealed channel that a relay
    /// or lookalike advertiser cannot decrypt.
    func hostAgreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try lock.withLock {
            if let cachedHostKey { return cachedHostKey }
            do {
                let key = hostKeyStorageKey
                if let data = try storage.data(forKey: key) {
                    guard let existing = try? Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: data
                    ) else {
                        throw BlinkPeerTrustStoreError.invalidHostKey
                    }
                    cachedHostKey = existing
                    persistenceFailureStorage = nil
                    return existing
                }
                let created = Curve25519.KeyAgreement.PrivateKey()
                try storage.set(created.rawRepresentation, forKey: key)
                cachedHostKey = created
                persistenceFailureStorage = nil
                return created
            } catch {
                persistenceFailureStorage = error.localizedDescription
                throw error
            }
        }
    }

    private var hostKeyStorageKey: String { "\(storageKey).host-agreement-key" }

    private func load() -> [BlinkTrustedPeer] {
        if let cachedPeers { return cachedPeers }
        var decoded: [BlinkTrustedPeer] = []
        record {
            if let data = try storage.data(forKey: storageKey) {
                decoded = (try? JSONDecoder().decode([BlinkTrustedPeer].self, from: data)) ?? []
            }
        }
        let sorted = decoded.sorted {
            if $0.approvedAt != $1.approvedAt { return $0.approvedAt < $1.approvedAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        cachedPeers = sorted
        return sorted
    }

    private func save(_ peers: [BlinkTrustedPeer]) {
        cachedPeers = peers
        guard let data = try? JSONEncoder().encode(peers) else { return }
        record { try storage.set(data, forKey: storageKey) }
    }

    /// Keep the in-memory set authoritative for this process even when the
    /// Keychain is unavailable, and surface why persistence failed.
    private func record(_ operation: () throws -> Void) {
        do {
            try operation()
            persistenceFailureStorage = nil
        } catch {
            persistenceFailureStorage = error.localizedDescription
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
