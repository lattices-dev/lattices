#if LATTICES_BUNDLE
import XCTest
import Foundation
import Darwin
@testable import Lattices

final class CompanionPrivateIPCTests: XCTestCase {
    func testPrivateCompanionAdmissionParsingAndCleanup() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("companion.sock").path
        let credential = directory.appendingPathComponent("companion.token")
        let server = LatticesCompanionBridgeServer(socketPath: path, tokenURL: credential)
        server.start()
        defer { server.stop() }
        let token = try String(contentsOf: credential, encoding: .utf8)
        for file in [path, credential.path] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        func request(_ headers: String = "") -> String { "GET /test-unknown-route HTTP/1.1\r\nHost: localhost\r\n" + headers + "\r\n" }
        let auth = "x-lattices-token: \(token)\r\n"
        XCTAssertTrue(try exchange(path: path, text: request()).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(try exchange(path: path, text: request("x-lattices-token: wrong\r\n")).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(try exchange(path: path, text: request(auth)).hasPrefix("HTTP/1.1 404"))
        for origin in ["null", "https://example.com"] {
            XCTAssertTrue(try exchange(path: path, text: request(auth + "Origin: \(origin)\r\n")).hasPrefix("HTTP/1.1 403"))
        }
        for malformed in [
            "GET /test-unknown-route HTTP/1.1\r\nMalformed\r\n\r\n",
            request(auth + "Host: localhost\r\n"), request(auth + auth),
            request(auth + "Content-Length: -1\r\n"), request(auth + "Content-Length: 1x\r\n"),
            request(auth + "Content-Length: 9999999999999999999999999\r\n"),
            request(auth + "Transfer-Encoding: chunked\r\n")
        ] {
            XCTAssertTrue(try exchange(path: path, text: malformed).hasPrefix("HTTP/1.1 400"))
        }
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.path))
    }

    func testRejectedEndpointInitializationReleasesItsLock() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("companion.sock")
        let token = directory.appendingPathComponent("companion.token")
        try Data("owned sentinel".utf8).write(to: path)
        XCTAssertThrowsError(try PrivateLocalEndpoint(socketPath: path.path, tokenURL: token))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "owned sentinel")
        try FileManager.default.removeItem(at: path)
        let lease = try PrivateLocalEndpoint(socketPath: path.path, tokenURL: token)
        lease.closeLease()
    }

    private func exchange(path: String, text: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let bytes = Array(text.utf8)
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var response = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &response, response.count)
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return String(decoding: response.prefix(count), as: UTF8.self)
    }
}
#endif
