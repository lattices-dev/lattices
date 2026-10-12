import CryptoKit
import XCTest
@testable import DeckKit

/// Vectors from packages/host-linux/src/bridge/security.ts, so the Swift
/// client and the Linux host can't drift apart.
final class DeckBridgeClientCryptoTests: XCTestCase {
    private let devicePublic = "pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk="
    private let bridgePublic = "zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk="

    private func crypto() throws -> DeckBridgeClientCrypto {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        XCTAssertEqual(key.publicKey.rawRepresentation.base64EncodedString(), devicePublic)
        return try DeckBridgeClientCrypto(privateKey: key, deviceID: "dev-1", bridgePublicKey: bridgePublic)
    }

    func testSignsLikeTheLinuxHost() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let signed = try crypto().sign(
            method: "GET", path: "/visit", plaintext: nil,
            now: formatter.date(from: "2026-10-09T21:00:00.000Z")!, nonce: "abc-nonce"
        )
        XCTAssertEqual(signed.headers["X-Lattices-Signature"], "nwfF2UwaCrRCfnM5iiWugEq4lYv4HuP05VTPdmsJ9ik=")
        XCTAssertTrue(signed.body.isEmpty)
    }

    func testOpensAFrameTheLinuxHostSealed() throws {
        let frame = Data(base64Encoded: "MBUZX2FWWXfE4oFsNiRWFSJ8V9ZsEOQh9qYf6Uyan9FRl+jzuRSb8xWl/WayxRmtfJvDMA4=")!
        let plaintext = try crypto().openFrame(frame, direction: .down, upgradeNonce: "abc-nonce", seq: 3)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"t":"ready","x":1,"y":2}"#)
        XCTAssertThrowsError(try crypto().openFrame(frame, direction: .down, upgradeNonce: "abc-nonce", seq: 4))
        XCTAssertThrowsError(try crypto().openFrame(frame, direction: .up, upgradeNonce: "abc-nonce", seq: 3))
    }

    func testFrameRoundTrip() throws {
        let c = try crypto()
        let sealed = try c.sealFrame(Data("hi".utf8), direction: .up, upgradeNonce: "n", seq: 0)
        XCTAssertEqual(try c.openFrame(sealed, direction: .up, upgradeNonce: "n", seq: 0), Data("hi".utf8))
    }
}
