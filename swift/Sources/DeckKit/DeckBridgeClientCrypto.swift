import CryptoKit
import Foundation

/// The device half of the companion bridge's crypto, shared by every client
/// that pairs with a bridge (the iOS companion, a Mac visiting another host).
/// It matches `LatticesCompanionSecurityCoordinator` on the Mac and
/// `packages/host-linux/src/bridge/security.ts` on Linux; changing any of
/// these strings breaks every existing pairing.
public struct DeckBridgeClientCrypto: Sendable {
    public enum Failure: Error, Equatable {
        case invalidBridgeKey
        case invalidEnvelope
    }

    public struct SignedRequest: Sendable {
        public let headers: [String: String]
        public let body: Data
        public let nonce: String
        public let timestamp: String
    }

    public let deviceID: String
    public let signingKey: SymmetricKey
    public let encryptionKey: SymmetricKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey, deviceID: String, bridgePublicKey: String) throws {
        guard let raw = Data(base64Encoded: bridgePublicKey),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw Failure.invalidBridgeKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        func derive(_ info: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("lattices-bridge-v1".utf8),
                sharedInfo: Data(info.utf8),
                outputByteCount: 32
            )
        }
        self.deviceID = deviceID
        self.signingKey = derive("signing")
        self.encryptionKey = derive("encryption")
    }

    // MARK: Requests

    /// Signs a request, sealing `plaintext` into an envelope first when the
    /// bridge requires encrypted payloads.
    public func sign(
        method: String,
        path: String,
        plaintext: Data?,
        encrypt: Bool = true,
        now: Date = Date(),
        nonce: String = UUID().uuidString.lowercased()
    ) throws -> SignedRequest {
        let timestamp = Self.timestamp(now)
        var body = plaintext ?? Data()
        if encrypt, let plaintext {
            let aad = Self.join(["request", method.uppercased(), path, deviceID, timestamp, nonce])
            let sealed = try ChaChaPoly.seal(plaintext, using: encryptionKey, authenticating: aad)
            body = try JSONEncoder().encode(DeckEncryptedEnvelope(sealedBox: sealed.combined.base64EncodedString()))
        }
        let canonical = Self.join([
            method.uppercased(), path, deviceID, timestamp, nonce,
            SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
        ])
        let signature = Data(HMAC<SHA256>.authenticationCode(for: canonical, using: signingKey)).base64EncodedString()
        return SignedRequest(
            headers: [
                "X-Lattices-Device-Id": deviceID,
                "X-Lattices-Timestamp": timestamp,
                "X-Lattices-Nonce": nonce,
                "X-Lattices-Signature": signature,
            ],
            body: body,
            nonce: nonce,
            timestamp: timestamp
        )
    }

    /// Opens a protected response's envelope.
    public func openResponse(_ data: Data, status: Int, path: String, nonce: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(DeckEncryptedEnvelope.self, from: data),
              let combined = Data(base64Encoded: envelope.sealedBox) else {
            throw Failure.invalidEnvelope
        }
        return try open(combined, aad: Self.join(["response", String(status), path, deviceID, nonce]))
    }

    // MARK: Visit frames

    public enum Direction: String, Sendable {
        /// From the visiting device to the host.
        case up
        /// From the host to the visiting device.
        case down
    }

    /// A `/visit` frame: the combined sealed box, raw. See docs/visit.md.
    public func sealFrame(_ plaintext: Data, direction: Direction, upgradeNonce: String, seq: UInt64) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: encryptionKey, authenticating: frameAAD(direction, upgradeNonce, seq)).combined
    }

    public func openFrame(_ frame: Data, direction: Direction, upgradeNonce: String, seq: UInt64) throws -> Data {
        try open(frame, aad: frameAAD(direction, upgradeNonce, seq))
    }

    private func frameAAD(_ direction: Direction, _ upgradeNonce: String, _ seq: UInt64) -> Data {
        Self.join(["visit", direction.rawValue, deviceID, upgradeNonce, String(seq)])
    }

    // MARK: Helpers

    private func open(_ combined: Data, aad: Data) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plaintext = try? ChaChaPoly.open(box, using: encryptionKey, authenticating: aad) else {
            throw Failure.invalidEnvelope
        }
        return plaintext
    }

    private static func join(_ parts: [String]) -> Data {
        Data(parts.joined(separator: "\n").utf8)
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A device's fingerprint as both sides show it when pairing.
    public static func fingerprint(publicKeyBase64: String) -> String {
        let hex = SHA256.hash(data: Data(publicKeyBase64.utf8)).map { String(format: "%02x", $0) }.joined()
        let compact = Array(hex.prefix(12).uppercased())
        return stride(from: 0, to: compact.count, by: 4).map { String(compact[$0..<min($0 + 4, compact.count)]) }.joined(separator: "-")
    }
}
