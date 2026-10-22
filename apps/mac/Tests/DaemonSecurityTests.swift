import XCTest
import Foundation
import Darwin
@testable import Lattices

final class DaemonSecurityTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private func request(_ extra: String = "", token: String? = nil, host: String = "localhost") -> String {
        "GET / HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        (token.map { "x-lattices-token: \($0)\r\n" } ?? "") + extra + "\r\n"
    }
    func testAdmissionRejectsAbsentWrongDuplicateAndBrowserCredentials() {
        XCTAssertTrue(DaemonAdmission.allows(request(token: token), token: token, port: nil))
        for denied in [request(), request(token: "wrong"), request("Origin: null\r\n", token: token), request("Origin: https://example.com\r\n", token: token), request("x-lattices-token: \(token)\r\n", token: token), request(token: token, host: "attacker.example"), request("Content-Length: 1\r\n", token: token)] {
            XCTAssertFalse(DaemonAdmission.allows(denied, token: token, port: nil))
        }
        XCTAssertTrue(DaemonAdmission.allows(request(token: token, host: "127.0.0.1:12345"), token: token, port: 12345))
        XCTAssertFalse(DaemonAdmission.allows(request(token: token, host: "localhost:9399"), token: token, port: 12345))
    }
    func testPrivateSocketRequiresTokenBeforeUpgradeAndCleansUp() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("lattices.sock").path
        let credential = directory.appendingPathComponent("lattices.token")
        let server = DaemonServer(socketPath: socket, tokenURL: credential)
        server.start()
        defer { server.stop() }
        XCTAssertEqual(server.listeningPort, 0)
        let secret = try String(contentsOf: credential, encoding: .utf8)
        let permissions = try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertTrue(try exchange(path: socket, text: request()).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(try exchange(path: socket, text: request("Origin: https://example.com\r\n", token: secret)).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(try exchange(path: socket, text: request(token: secret)).hasPrefix("HTTP/1.1 101"))
        // Starting a second server must not remove the first server's socket or token.
        let second = DaemonServer(socketPath: socket, tokenURL: credential)
        second.start(); second.stop()
        XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), secret)
        XCTAssertTrue(try exchange(path: socket, text: request(token: secret)).hasPrefix("HTTP/1.1 101"))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        // lattices.token is shared with the bridge and gateway admin socket.
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))
    }
    func testUnsafeDirectoryAndSymlinkAreRejected() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try PrivateLocalEndpoint.prepareDirectory(directory.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try PrivateLocalEndpoint.prepareDirectory(link.path))
    }
    private func exchange(path: String, text: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let bytes = Array(text.utf8); _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var response = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &response, response.count)
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return String(decoding: response.prefix(count), as: UTF8.self)
    }
}
