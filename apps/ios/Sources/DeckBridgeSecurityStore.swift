import CryptoKit
import DeckKit
import Foundation
import Security
import UIKit

enum DeckBridgeSecurityError: LocalizedError {
    case pairingRequired
    case insufficientCapability(String)
    case invalidBridgeKey
    case invalidEnvelope

    var errorDescription: String? {
        switch self {
        case .pairingRequired:
            return "Approve this iPad or iPhone on your Mac before using the protected bridge."
        case .insufficientCapability(let capability):
            return "This pairing does not grant the required bridge capability: \(capability). Pair again from the Mac."
        case .invalidBridgeKey:
            return "The Mac bridge returned an invalid encryption identity."
        case .invalidEnvelope:
            return "The encrypted bridge payload could not be decoded."
        }
    }
}

struct StoredBridgeTrust: Codable, Equatable, Sendable {
    var bridgeName: String
    var bridgePublicKey: String
    var bridgeFingerprint: String
    var requestSigningRequired: Bool
    var payloadEncryptionRequired: Bool
    var grantedCapabilities: [String]?
    var pairedAt: Date

    /// Where this Mac was last reachable. Optional so records written before
    /// these fields existed still decode — synthesized `Decodable` uses
    /// `decodeIfPresent` for optionals, so old JSON reads back with both nil.
    ///
    /// This is what lets a paired-but-not-currently-discovered Mac stay in the
    /// roster as something you can reconnect to, rather than a dead card.
    var lastKnownHost: String?
    var lastKnownPort: Int?

    var effectiveCapabilities: [String] {
        grantedCapabilities ?? DeckBridgeCapability.legacyCompanionCapabilities
    }
}

struct PreparedBridgeRequest {
    let headers: [String: String]
    let body: Data?
    let requestNonce: String
}

final class DeckBridgeSecurityStore {
    static let shared = DeckBridgeSecurityStore()
    static let trustDidChangeNotification = Notification.Name("DeckBridgeSecurityStore.trustDidChange")

    private enum DefaultsKey {
        static let deviceID = "companion.security.deviceID"
        static let trustedBridges = "companion.security.trustedBridges"
    }

    private enum KeychainKey {
        static let service = "dev.lattices.app.companion"
        static let account = "device.keyagreement.private"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let deviceID: String
    private var trustedBridges: [String: StoredBridgeTrust]

    private init() {
        self.privateKey = Self.loadOrCreatePrivateKey()

        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: DefaultsKey.deviceID), saved.isEmpty == false {
            self.deviceID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: DefaultsKey.deviceID)
            self.deviceID = generated
        }

        self.trustedBridges = Self.loadTrustedBridges()
    }

    var devicePublicKeyBase64: String {
        Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
    }

    /// This device's own fingerprint, derived exactly as the Mac derives it for
    /// its approval alert (`LatticesCompanionSecurityCoordinator.fingerprint`).
    /// Both screens show the same string — that is the whole point of showing
    /// it, and it is why this derivation must not drift from the Mac's.
    ///
    /// Hex has no confusable pairs to worry about: `O`, `I` and `L` are not in
    /// the alphabet, so `0` and `1` are unambiguous.
    var deviceFingerprint: String {
        let digest = SHA256.hash(data: Data(devicePublicKeyBase64.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let compact = String(hex.prefix(12)).uppercased()
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")
    }

    func isTrusted(health: BridgeHealthResponse) -> Bool {
        trustedBridges[health.bridgePublicKey] != nil
    }

    /// Whether this device has paired with the Mac behind an endpoint.
    ///
    /// One definition, because this comparison was previously written out by
    /// hand in `ContentView.prepareConnection` and `DeckFleetStore.synchronize`
    /// and the two are easy to let drift apart.
    ///
    /// Note the limit of what this proves: the fingerprint arrives in an
    /// unauthenticated Bonjour TXT record, so a match is a *hint* that this is
    /// a Mac we know, good enough to decide what to show in a roster. It is not
    /// authentication — that happens against `health.bridgePublicKey` when the
    /// connection is actually made.
    func isTrusted(endpoint: BridgeEndpoint) -> Bool {
        guard let fingerprint = endpoint.bridgeFingerprint, !fingerprint.isEmpty else { return false }
        return trustedBridges.values.contains {
            $0.bridgeFingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame
        }
    }

    /// The trust record for a Mac, by the public key its `/health` reports.
    /// This is the authenticated identity — prefer it over fingerprint matching
    /// anywhere the answer decides what a control does.
    func trust(forPublicKey publicKey: String) -> StoredBridgeTrust? {
        trustedBridges[publicKey]
    }

    /// All Macs this device has paired with (most recently paired first).
    func trustedBridgeList() -> [StoredBridgeTrust] {
        trustedBridges.values.sorted { $0.pairedAt > $1.pairedAt }
    }

    /// Forget a previously paired bridge by its public key.
    func forgetBridge(publicKey: String) {
        guard trustedBridges.removeValue(forKey: publicKey) != nil else { return }
        persistTrustedBridges()
        NotificationCenter.default.post(name: Self.trustDidChangeNotification, object: nil)
    }

    func pairingRequest() -> DeckPairingRequest {
        DeckPairingRequest(
            deviceID: deviceID,
            deviceName: UIDevice.current.name,
            devicePublicKey: devicePublicKeyBase64,
            platform: "iOS \(UIDevice.current.systemVersion)",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            requestedCapabilities: DeckBridgeCapability.defaultCompanionCapabilities
        )
    }

    func storePairing(
        _ response: DeckPairingResponse,
        lastKnownHost: String? = nil,
        lastKnownPort: Int? = nil
    ) {
        // `alreadyTrusted` comes back for a Mac we have paired with before, so
        // keep the original pairing date rather than restamping it every time
        // a retry resolves.
        let existing = trustedBridges[response.bridgePublicKey]
        trustedBridges[response.bridgePublicKey] = StoredBridgeTrust(
            bridgeName: response.bridgeName,
            bridgePublicKey: response.bridgePublicKey,
            bridgeFingerprint: response.bridgeFingerprint,
            requestSigningRequired: response.requestSigningRequired,
            payloadEncryptionRequired: response.payloadEncryptionRequired,
            grantedCapabilities: response.grantedCapabilities,
            pairedAt: existing?.pairedAt ?? Date(),
            lastKnownHost: lastKnownHost ?? existing?.lastKnownHost,
            lastKnownPort: lastKnownPort ?? existing?.lastKnownPort
        )
        persistTrustedBridges()
        NotificationCenter.default.post(name: Self.trustDidChangeNotification, object: nil)
    }

    /// Remember where a Mac answered, so it stays reconnectable once it stops
    /// advertising on Bonjour. Only ever called after `/health` has proved the
    /// public key, so an address can never be attached to the wrong Mac.
    func rememberAddress(forPublicKey publicKey: String, host: String, port: Int) {
        guard var trust = trustedBridges[publicKey] else { return }
        guard trust.lastKnownHost != host || trust.lastKnownPort != port else { return }
        trust.lastKnownHost = host
        trust.lastKnownPort = port
        trustedBridges[publicKey] = trust
        persistTrustedBridges()
    }

    func prepareRequest(
        method: String,
        path: String,
        plaintextBody: Data?,
        health: BridgeHealthResponse
    ) throws -> PreparedBridgeRequest {
        guard let trust = trustedBridges[health.bridgePublicKey] else {
            throw DeckBridgeSecurityError.pairingRequired
        }
        try requireCapability(for: path, trust: trust)
        let signed = try crypto(health).sign(
            method: method,
            path: path,
            plaintext: plaintextBody,
            encrypt: trust.payloadEncryptionRequired
        )
        return PreparedBridgeRequest(
            headers: signed.headers,
            body: signed.body.isEmpty ? nil : signed.body,
            requestNonce: signed.nonce
        )
    }

    func openProtectedResponse<T: Decodable>(
        _ type: T.Type,
        data: Data,
        status: Int,
        path: String,
        requestNonce: String,
        health: BridgeHealthResponse
    ) throws -> T {
        let plaintext: Data
        do {
            plaintext = try crypto(health).openResponse(data, status: status, path: path, nonce: requestNonce)
        } catch DeckBridgeClientCrypto.Failure.invalidEnvelope {
            throw DeckBridgeSecurityError.invalidEnvelope
        }
        return try decoder.decode(type, from: plaintext)
    }

    private func crypto(_ health: BridgeHealthResponse) throws -> DeckBridgeClientCrypto {
        do {
            return try DeckBridgeClientCrypto(privateKey: privateKey, deviceID: deviceID, bridgePublicKey: health.bridgePublicKey)
        } catch {
            throw DeckBridgeSecurityError.invalidBridgeKey
        }
    }
}

private extension DeckBridgeSecurityStore {
    static func loadTrustedBridges() -> [String: StoredBridgeTrust] {
        guard
            let data = UserDefaults.standard.data(forKey: DefaultsKey.trustedBridges),
            let bridges = try? JSONDecoder().decode([StoredBridgeTrust].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: bridges.map { ($0.bridgePublicKey, $0) })
    }

    static func loadOrCreatePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if
            let stored = MobileKeychainBridge.load(service: KeychainKey.service, account: KeychainKey.account),
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
        {
            return key
        }

        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = MobileKeychainBridge.save(
            key.rawRepresentation,
            service: KeychainKey.service,
            account: KeychainKey.account
        )
        return key
    }

    func persistTrustedBridges() {
        let values = trustedBridges.values.sorted {
            $0.bridgeName.localizedCaseInsensitiveCompare($1.bridgeName) == .orderedAscending
        }
        guard let data = try? encoder.encode(values) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.trustedBridges)
    }

    func requireCapability(for path: String, trust: StoredBridgeTrust) throws {
        let required: String?
        switch path {
        case "/deck/snapshot":
            required = DeckBridgeCapability.deckRead
        case "/deck/perform":
            required = DeckBridgeCapability.deckPerform
        case "/deck/trackpad":
            required = DeckBridgeCapability.inputTrackpad
        case "/deck/preview":
            required = DeckBridgeCapability.screenPreview
        default:
            required = nil
        }

        guard let required else { return }
        guard trust.effectiveCapabilities.contains(required) else {
            throw DeckBridgeSecurityError.insufficientCapability(required)
        }
    }
}

private enum MobileKeychainBridge {
    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var insert = query
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}
