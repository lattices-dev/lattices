import Darwin
import Foundation
import XCTest
@testable import SpeechAppRuntime

final class SpeechPrivateIPCTests: XCTestCase {
    @MainActor
    func testPrivateSocketRoundTripAndHandshakeDenials() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let socket = directory.appendingPathComponent("speech.sock")
        let token = directory.appendingPathComponent("speech.token")
        let api = SpeechApi()
        let queue = SpeechQueue(synthesizer: FakeSpeechSynthesizer(), player: FakeSpeechPlayer())
        SpeechRpc.register(on: api, queue: queue)
        let server = SpeechServer(socketURL: socket, tokenURL: token, capabilityURL: directory.appendingPathComponent("legacy"), api: api, speechQueue: queue)
        server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(server.listeningPort, 0, "Default IPC must not bind TCP")
        XCTAssertEqual(try permissions(socket), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(token), 0o600)
        let secret = try String(contentsOf: token, encoding: .utf8)
        let duplicate = SpeechServer(socketURL: socket, tokenURL: token, capabilityURL: directory.appendingPathComponent("legacy"), api: api, speechQueue: queue)
        duplicate.start(); duplicate.stop()
        XCTAssertEqual(try String(contentsOf: token, encoding: .utf8), secret, "A second helper must not rotate the live capability")
        // An idle handshake cannot monopolize the listener queue.
        let idle = try connectUnix(socket.path)
        defer { Darwin.close(idle) }
        let answer = expectation(description: "authenticated Unix RPC response")
        let client = SpeechCompanionConnection(socketPath: socket.path, tokenFile: token,
            response: { response in
                XCTAssertNil(response.error); XCTAssertEqual(response.id, "ipc")
                answer.fulfill()
            }, event: { _ in })
        await client.forward(DaemonRequest(id: "ipc", method: "speech.status", params: nil))
        await fulfillment(of: [answer], timeout: 3)
        assertPrivateDescriptorsCloseOnExec(socket.path, excluding: [idle], minimum: 3)
        await client.close()
        let denials = try await Task.detached {
            try ["", "x-lattices-token: wrong\r\n", "x-lattices-token: \(secret)\r\nOrigin: https://evil.test\r\n", "x-lattices-token: \(secret)\r\nx-lattices-token: \(secret)\r\n"].map {
                try self.handshake(socket.path, headers: $0)
            }
        }.value
        for denied in denials { XCTAssertTrue(denied.isEmpty || denied.hasPrefix("HTTP/1.1 403"), denied) }
        let badHost = try await Task.detached { try self.handshake(socket.path, headers: "x-lattices-token: \(secret)\r\n", host: "evil.test") }.value
        XCTAssertTrue(badHost.hasPrefix("HTTP/1.1 403"))
        // A UInt64.max frame length used to trap Int conversion. Reject without
        // allocating, and leave the server available to a fresh connection.
        let oversizedClosed = try await Task.detached {
            let fd = try self.connectUnix(socket.path); defer { Darwin.close(fd) }
            _ = try self.upgrade(fd, headers: "x-lattices-token: \(secret)\r\n")
            let frame: [UInt8] = [0x81, 0xFF] + Array(repeating: 0xFF, count: 8)
            _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            var byte: UInt8 = 0
            return Darwin.read(fd, &byte, 1) == 0
        }.value
        XCTAssertTrue(oversizedClosed)
        let stillAlive = try await Task.detached { try self.handshake(socket.path, headers: "x-lattices-token: \(secret)\r\n") }.value
        XCTAssertTrue(stillAlive.hasPrefix("HTTP/1.1 101"))
    }

    @MainActor
    func testStopClosesExistingConnectionsAndAllowsRestart() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let socket = directory.appendingPathComponent("speech.sock")
        let token = directory.appendingPathComponent("speech.token")
        let api = SpeechApi()
        let queue = SpeechQueue(synthesizer: FakeSpeechSynthesizer(), player: FakeSpeechPlayer())
        let server = SpeechServer(socketURL: socket, tokenURL: token, capabilityURL: directory.appendingPathComponent("legacy"), api: api, speechQueue: queue)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 {
            server.start()
            let secret = try String(contentsOf: token, encoding: .utf8)
            let fd = try await Task.detached {
                let fd = try self.connectUnix(socket.path)
                XCTAssertTrue(try self.upgrade(fd, headers: "x-lattices-token: \(secret)\r\n").hasPrefix("HTTP/1.1 101"))
                return fd
            }.value
            server.stop()
            let closed = await Task.detached {
                defer { Darwin.close(fd) }
                var byte: UInt8 = 0
                return Darwin.read(fd, &byte, 1) == 0
            }.value
            XCTAssertTrue(closed, "Stopping must close accepted descriptors, not only the listener")
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        }
    }

    func testSymlinkAndWrongFileTypesFailClosed() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let linked = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        XCTAssertThrowsError(try SpeechPrivateIPC.prepareDirectory(linked))
        let regular = directory.appendingPathComponent("speech.sock")
        try Data("keep me".utf8).write(to: regular)
        XCTAssertThrowsError(try SpeechPrivateIPC.removeStaleSocket(regular))
        XCTAssertEqual(try String(contentsOf: regular, encoding: .utf8), "keep me")
        let token = directory.appendingPathComponent("token")
        try FileManager.default.createSymbolicLink(at: token, withDestinationURL: regular)
        XCTAssertThrowsError(try SpeechRPCCapability(url: token))
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
    private func connectUnix(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { dest in path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    private func handshake(_ path: String, headers: String, host: String = "localhost") throws -> String {
        let fd = try connectUnix(path); defer { Darwin.close(fd) }
        return try upgrade(fd, headers: headers, host: host)
    }
    private func upgrade(_ fd: Int32, headers: String, host: String = "localhost") throws -> String {
        let request = Data("GET / HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\(headers)\r\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        var response = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(fd, &response, response.count)
        guard count > 0 else { return "" }
        return String(decoding: response.prefix(count), as: UTF8.self)
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
