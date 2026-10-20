import Darwin
import Foundation
import XCTest
@testable import Lattices

final class DaemonLifecycleTests: XCTestCase {
    func testRestartsDoNotDuplicateEventsAndSlowPeersDoNotBlockAdmission() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lattices.sock").path
        let credential = directory.appendingPathComponent("lattices.token")
        let bus = EventBus()
        let server = DaemonServer(socketPath: path, tokenURL: credential, eventBus: bus)
        defer { server.stop() }
        var previousToken: String?
        for _ in 0..<3 {
            server.start()
            let token = try String(contentsOf: credential, encoding: .utf8)
            XCTAssertNotEqual(token, previousToken)
            previousToken = token
            server.stop()
        }
        server.start()
        let token = try String(contentsOf: credential, encoding: .utf8)
        XCTAssertNotEqual(token, previousToken)
        // These peers never complete an HTTP request. Admission must remain
        // independent from the serial RPC queue and from the other peers.
        var slowPeers: [Int32] = []
        defer { slowPeers.forEach { close($0) } }
        for _ in 0..<6 { slowPeers.append(try connectPeer(path)) }
        let peer = try connectPeer(path)
        defer { close(peer) }
        let started = Date()
        try writeAll(peer, Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nx-lattices-token: \(token)\r\n\r\n").utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            XCTAssertLessThan(header.count, 8192)
            header.append(try readExactly(peer, 1))
        }
        XCTAssertTrue(String(decoding: header, as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        // Subscribe and await the acknowledgement to establish that the
        // post-upgrade client is registered before publishing our test event.
        let subscription = Data(#"{"id":"sub","method":"events.subscribe","params":{"events":["layer.switched"]}}"#.utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        try writeAll(peer, Data([0x81, 0x80 | UInt8(subscription.count)] + mask + subscription.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
        XCTAssertTrue(try readText(peer).contains("\"id\":\"sub\""))
        bus.post(.layerSwitched(index: 7))
        XCTAssertTrue(try readText(peer).contains("\"event\":\"layer.switched\""))
        var descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 150), 0, "Restart caused a duplicate model event")
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.path))
    }

    private func connectPeer(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do {
            guard PrivateLocalEndpoint.preventInheritance(fd) else { throw socketError() }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw socketError() }
            return fd
        } catch { close(fd); throw error }
    }

    private func readText(_ fd: Int32) throws -> String {
        let header = [UInt8](try readExactly(fd, 2))
        guard header[0] == 0x81, header[1] & 0x80 == 0 else { throw socketError() }
        var length = Int(header[1])
        if length == 126 { length = try readExactly(fd, 2).reduce(0) { ($0 << 8) | Int($1) } }
        guard length < 8192, header[1] != 127 else { throw socketError() }
        return String(decoding: try readExactly(fd, length), as: UTF8.self)
    }
    private func readExactly(_ fd: Int32, _ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = read(fd, bytes.baseAddress!.advanced(by: offset), size - offset)
                guard count > 0 else { throw socketError() }; offset += count
            }
        }
        return data
    }
    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw socketError() }; offset += count
            }
        }
    }
    private func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
