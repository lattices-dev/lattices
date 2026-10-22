import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Lattices

final class DeviceIdentityTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("lattices-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func jwk(_ key: Curve25519.KeyAgreement.PrivateKey) -> Data {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let object = ["kty": "OKP", "crv": "X25519", "x": b64url(key.publicKey.rawRepresentation), "d": b64url(key.rawRepresentation)]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testANewMachineGetsOnePrivateIdentityThatStaysStable() throws {
        let first = try DeviceIdentity.load(base: base)
        let path = DeviceIdentity.path(base: base)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(path.deletingLastPathComponent()), 0o700)
        let second = try DeviceIdentity.load(base: base)
        XCTAssertEqual(first.publicKeyBase64, second.publicKeyBase64)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path), ["device.json"])
    }

    func testPinnedGatewayKeyIsKeptWithTheClientIDAndLegacyFilesGo() throws {
        let files = DeviceIdentity.LegacyFiles(base: base)
        let gateway = Curve25519.KeyAgreement.PrivateKey()
        try put(jwk(gateway), at: files.gatewayKey)
        try put(Data(#"[{"id":"peer"}]"#.utf8), at: files.gatewayClients)
        try put(Curve25519.KeyAgreement.PrivateKey().rawRepresentation, at: files.companionKey)
        try put(jwk(Curve25519.KeyAgreement.PrivateKey()), at: files.hostBridgeKey)
        let client = try JSONSerialization.data(withJSONObject: ["id": "client-id", "name": "mini", "privateKey": try JSONSerialization.jsonObject(with: jwk(Curve25519.KeyAgreement.PrivateKey()))])
        try put(client, at: files.client)
        try put(Curve25519.KeyAgreement.PrivateKey().rawRepresentation, at: files.visitKey)

        let identity = try DeviceIdentity.load(base: base)
        XCTAssertEqual(identity.privateKey.rawRepresentation, gateway.rawRepresentation)
        XCTAssertEqual(identity.id, "client-id")
        XCTAssertEqual(identity.name, "mini")
        for url in files.keys { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.gatewayClients.path))
    }

    func testUnpinnedGatewayKeyYieldsToTheCompanionBridgeKey() throws {
        let files = DeviceIdentity.LegacyFiles(base: base)
        try put(jwk(Curve25519.KeyAgreement.PrivateKey()), at: files.gatewayKey)
        try put(Data("[]".utf8), at: files.gatewayClients)
        let companion = Curve25519.KeyAgreement.PrivateKey()
        try put(companion.rawRepresentation, at: files.companionKey)
        try put(Curve25519.KeyAgreement.PrivateKey().rawRepresentation, at: files.visitKey)
        XCTAssertEqual(try DeviceIdentity.load(base: base).privateKey.rawRepresentation, companion.rawRepresentation)
    }

    func testUnsafeOrMalformedIdentityIsRefusedNeverReplaced() throws {
        _ = try DeviceIdentity.load(base: base)
        let path = DeviceIdentity.path(base: base)
        let good = try Data(contentsOf: path)

        chmod(path.path, 0o644)
        XCTAssertThrowsError(try DeviceIdentity.load(base: base))
        chmod(path.path, 0o600)

        try put(Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "X25519", with: "Ed25519").utf8), at: path)
        XCTAssertThrowsError(try DeviceIdentity.load(base: base))

        try FileManager.default.removeItem(at: path)
        let target = base.appendingPathComponent("elsewhere.json")
        try put(good, at: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        XCTAssertThrowsError(try DeviceIdentity.load(base: base))
        XCTAssertEqual(try Data(contentsOf: target), good)
    }

    func testReadsTheFileTheCLIWrites() throws {
        // identity/device.json as packages/desktop-client/device-identity.ts writes it.
        let json = #"{"version":1,"id":"cli-written","name":"mini","privateKey":{"kty":"OKP","crv":"X25519","x":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw","d":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}}"#
        try put(Data(json.utf8), at: DeviceIdentity.path(base: base))
        let identity = try XCTUnwrap(DeviceIdentity.read(base: base))
        XCTAssertEqual(identity.id, "cli-written")
        XCTAssertEqual(identity.privateKey.rawRepresentation, Data(1...32))
    }
}
