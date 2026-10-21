import Darwin
import Foundation
import XCTest
@testable import BlinkCore

final class BlinkPrivateIPCTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testPrivateSocketRoundTripAndActiveListenerProtection() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("blink.sock")
        let received = expectation(description: "same-user local RPC")
        let server = BlinkSocketServer(path: path) { data, _ in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"method\":\"system.hello\"}")
            received.fulfill()
        }
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try BlinkPrivateIPC.validateSocket(path)
        let socketAttributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((socketAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try BlinkPrivateIPC.removeStaleSocket(path), "Must not unlink a live server")
        let duplicate = BlinkSocketServer(path: path) { _, _ in }
        XCTAssertThrowsError(try duplicate.start())
        duplicate.stop()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try BlinkPrivateIPC.address(path)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(connected, 0)
        XCTAssertTrue(BlinkPrivateIPC.sameUserPeer(fd))
        let request = Data("{\"method\":\"system.hello\"}\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        await fulfillment(of: [received], timeout: 3)
        assertPrivateDescriptorsCloseOnExec(path.path, excluding: [fd])
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testUnsafePathsAndNonPeersAreRejected() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try BlinkPrivateIPC.prepareDirectory(link))
        let regular = directory.appendingPathComponent("blink.sock")
        try Data("preserve".utf8).write(to: regular)
        XCTAssertThrowsError(try BlinkPrivateIPC.removeStaleSocket(regular))
        XCTAssertThrowsError(try BlinkPrivateIPC.validateSocket(regular))
        XCTAssertEqual(try String(contentsOf: regular, encoding: .utf8), "preserve")
        XCTAssertFalse(BlinkPrivateIPC.sameUserPeer(-1))
    }
}

// Inspect live descriptors, including both ends of the real client/server
// transport, so child processes cannot retain its listeners or locks.
private func assertPrivateDescriptorsCloseOnExec(_ path: String, excluding: Set<Int32> = [], minimum: Int = 2) {
    var matching = 0
    var lockInfo = stat()
    let hasLock = lstat(path + ".lock", &lockInfo) == 0
    for fd in 0..<getdtablesize() where !excluding.contains(fd) {
        let flags = fcntl(fd, F_GETFD)
        if flags < 0 { continue }
        var matches = false
        for peer in [false, true] {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length)
                }
            }
            if result == 0, address.sun_family == sa_family_t(AF_UNIX) {
                let name = withUnsafeBytes(of: address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                matches = matches || name == path
            }
        }
        var info = stat()
        if hasLock, fstat(fd, &info) == 0, info.st_dev == lockInfo.st_dev, info.st_ino == lockInfo.st_ino { matches = true }
        if matches {
            matching += 1
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "Private IPC descriptor \(fd) leaks across exec")
        }
    }
    XCTAssertGreaterThanOrEqual(matching, minimum)
}
