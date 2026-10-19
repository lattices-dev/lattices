import BlinkCore
import CryptoKit
import Foundation

public struct BlinkPeerHost: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var publicKey: String

    public init(id: String, name: String, publicKey: String = "") {
        self.id = id
        self.name = name
        self.publicKey = publicKey
    }
}

enum BlinkPeerWire {
    /// Bumped whenever the request/response shape or key schedule changes.
    /// Discovery filters on the same value, so mismatched builds never pair.
    static let version = 4
    static let discoveryVersion = "4"
}

struct BlinkPeerRequestEnvelope: Codable {
    var version: Int = BlinkPeerWire.version
    var id: UUID
    var clientPublicKey: Data
    var sealedPayload: Data
}

enum BlinkPeerRequest: Codable {
    case requestAccess(BlinkPeerClientIdentity)
    /// The credential travels with every data-bearing request. Multipeer's
    /// `MCPeerID` is client-chosen and not a stable identity, so it can only be
    /// bookkeeping — the credential is the authorization boundary.
    case fetchSnapshot(credential: String, ifNoneMatch: String?)
}

struct BlinkPeerResponseEnvelope: Codable {
    var version: Int = BlinkPeerWire.version
    var id: UUID
    var sealedPayload: Data
}

enum BlinkPeerResponse: Codable {
    case accessGranted(BlinkPeerHost)
    case snapshot(BlinkSnapshotFetchResult)
    case failure(BlinkPeerFailure)
}

struct BlinkPeerFailure: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

public enum BlinkPeerError: Error, LocalizedError, Equatable, Sendable {
    case peerUnavailable
    case connectionFailed(String)
    case accessDenied
    case unauthorized
    case invalidResponse
    case requestTimedOut
    case remoteFailure(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .peerUnavailable:
            return "That Mac is no longer available nearby."
        case .connectionFailed(let detail):
            return "Canvas could not connect to the Mac: \(detail)"
        case .accessDenied:
            return "Access wasn’t allowed on your Mac. You can try again."
        case .unauthorized:
            return "This device no longer has access to the Mac. Request access again."
        case .invalidResponse:
            return "The Mac returned an invalid Canvas response."
        case .requestTimedOut:
            return "The Mac did not respond in time."
        case .remoteFailure(_, let message):
            return message
        }
    }
}

public struct BlinkLANPeerCandidate: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hostID: String
    public var publicKey: String

    public init(id: String, name: String, hostID: String, publicKey: String) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.publicKey = publicKey
    }
}

enum BlinkPeerCrypto {
    private static let salt = Data("dev.arach.blink.peer.v4".utf8)

    /// A credential is a 64-character lowercase hex HMAC scoped to one host key.
    static func isWellFormedCredential(_ credential: String) -> Bool {
        credential.utf8.count == 64 && credential.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func symmetricKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    static func seal<Value: Encodable>(_ value: Value, using key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        return try ChaChaPoly.seal(plaintext, using: key).combined
    }

    static func open<Value: Decodable>(
        _ type: Value.Type,
        from combined: Data,
        using key: SymmetricKey
    ) throws -> Value {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try JSONDecoder().decode(type, from: ChaChaPoly.open(box, using: key))
    }

    static func credential(seed: String, hostPublicKey: Data) -> String {
        let key = SymmetricKey(data: Data(seed.utf8))
        return HMAC<SHA256>.authenticationCode(for: hostPublicKey, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
