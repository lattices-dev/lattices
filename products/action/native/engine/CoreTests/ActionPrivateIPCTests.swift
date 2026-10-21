import XCTest
@testable import ActionCore
import Darwin

final class ActionPrivateIPCTests: XCTestCase {
    func testUpgradeRequiresOneValidTokenAndExactHostWithoutOrigin() throws {
        let auth = ActionAgentAuthentication(token: String(repeating: "a", count: 64), tokenFile: URL(fileURLWithPath: "/unused"))
        let good = [(name: "Host", value: "localhost"), (name: "x-lattices-token", value: auth.token)]
        XCTAssertTrue(ActionPrivateIPC.authorize(headers: good, authentication: auth, port: nil))
        XCTAssertFalse(ActionPrivateIPC.authorize(headers: [], authentication: auth, port: nil))
        XCTAssertFalse(ActionPrivateIPC.authorize(headers: good + [(name: "Origin", value: "https://example.com")], authentication: auth, port: nil))
        XCTAssertFalse(ActionPrivateIPC.authorize(headers: good + [(name: "x-lattices-token", value: auth.token)], authentication: auth, port: nil))
        XCTAssertFalse(ActionPrivateIPC.authorize(headers: [(name: "Host", value: "attacker.example"), good[1]], authentication: auth, port: nil))
        XCTAssertFalse(ActionPrivateIPC.authorize(headers: [(name: "Host", value: "localhost"), (name: "x-lattices-token", value: "wrong")], authentication: auth, port: nil))
        XCTAssertTrue(ActionPrivateIPC.authorize(headers: [(name: "Host", value: "127.0.0.1:4319"), good[1]], authentication: auth, port: 4319))
    }
    func testTokenCreationIsStableAndRefusesUnsafeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ActionAgentAuthentication.create(rootURL: root)
        XCTAssertEqual(try ActionAgentAuthentication.create(rootURL: root).token, first.token)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first.tokenFile.path)
        XCTAssertThrowsError(try ActionAgentAuthentication.create(rootURL: root))
        try FileManager.default.removeItem(at: first.tokenFile)
        try FileManager.default.createSymbolicLink(at: first.tokenFile, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        XCTAssertThrowsError(try ActionAgentAuthentication.create(rootURL: root))
    }
    func testCompetingLeaseDoesNotRemoveActiveSocketPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("action.sock").path
        let lease = try ActionPrivateSocketLease(path: path)
        try Data("sentinel".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ActionPrivateSocketLease(path: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        withExtendedLifetime(lease) {}
    }
}
