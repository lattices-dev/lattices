import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LatticesKit

final class LocalWebSocketTests: XCTestCase {
    func testAuthenticatedPrivateSocketRoundTripAndFragmentedResponse() async throws {
        let payload = Data(repeating: 65, count: 150_000)
        let server = try IPCFixture { fd, request in
            XCTAssertTrue(request.contains("Host: localhost\r\n"))
            XCTAssertTrue(request.contains("x-lattices-token: \(IPCFixture.token)\r\n"))
            let head = [UInt8](try IPCFixture.read(fd, count: 2))
            XCTAssertEqual(head[0], 0x82); XCTAssertEqual(head[1], 0xff)
            let length = try IPCFixture.read(fd, count: 8).reduce(0) { ($0 << 8) | Int($1) }
            let mask = [UInt8](try IPCFixture.read(fd, count: 4))
            let received = try IPCFixture.read(fd, count: length)
            XCTAssertEqual(Data(received.enumerated().map { $0.element ^ mask[$0.offset % 4] }), payload)
            // Control frames may occur between fragments.
            try IPCFixture.write(fd, data: Data([0x01, 2, 104, 101, 0x89, 0, 0x80, 3, 108, 108, 111]))
            _ = try IPCFixture.read(fd, count: 6) // masked pong
        }
        defer { server.close() }
        let client = LocalWebSocket(endpoint: server.endpoint, session: .shared)
        client.resume(); defer { client.cancel(with: .normalClosure, reason: nil) }
        try await client.send(.data(payload))
        let response = try await client.receive()
        guard case .data(let data) = response else { return XCTFail("Expected data") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
        await fulfillment(of: [server.finished], timeout: 5)
    }

    func testMaliciousFrameLengthFailsWithoutAllocation() async throws {
        let server = try IPCFixture { fd, _ in
            try IPCFixture.write(fd, data: Data([0x81, 127] + Array(repeating: UInt8(255), count: 8)))
        }
        defer { server.close() }
        let client = LocalWebSocket(endpoint: server.endpoint, session: .shared)
        client.resume(); defer { client.cancel(with: .normalClosure, reason: nil) }
        do { _ = try await client.receive(); XCTFail("Oversized frame accepted") }
        catch { XCTAssertEqual(error as? LatticesError, .invalidMessage) }
        await fulfillment(of: [server.finished], timeout: 5)
    }

    func testCancelUnblocksIdleReceive() async throws {
        let server = try IPCFixture { fd, _ in _ = try? IPCFixture.read(fd, count: 1) }
        defer { server.close() }
        let client = LocalWebSocket(endpoint: server.endpoint, session: .shared)
        client.resume()
        let read = Task { try await client.receive() }
        try await Task.sleep(nanoseconds: 100_000_000)
        client.cancel(with: .normalClosure, reason: nil)
        do { _ = try await read.value; XCTFail("Read survived cancellation") } catch {}
        await fulfillment(of: [server.finished], timeout: 5)
    }

    func testUnsafeCredentialFailsBeforeHandshake() async throws {
        let server = try IPCFixture { _, _ in XCTFail("Unsafe credential connected") }
        defer { server.close() }
        chmod(server.endpoint.deletingPathExtension().appendingPathExtension("token").path, 0o644)
        let client = LocalWebSocket(endpoint: server.endpoint, session: .shared)
        client.resume()
        do { try await client.send(.string("test")); XCTFail("Unsafe credential accepted") } catch {}
    }
}

private final class IPCFixture: @unchecked Sendable {
    static let token = String(repeating: "b", count: 64)
    let endpoint: URL
    let finished = XCTestExpectation(description: "server completed")
    private let fd: Int32
    private var stopped = false
    init(handler: @escaping (Int32, String) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        endpoint = directory.appendingPathComponent("lattices.sock")
        let credential = directory.appendingPathComponent("lattices.token")
        try Data(Self.token.utf8).write(to: credential); chmod(credential.path, 0o600)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(endpoint.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(fd, 4) == 0 else { throw LatticesError.disconnected }
        chmod(endpoint.path, 0o600)
        DispatchQueue.global().async {
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { self.finished.fulfill(); return }
            defer { Darwin.close(client); self.finished.fulfill() }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            do {
                var header = Data()
                while !header.suffix(4).elementsEqual([13, 10, 13, 10]) { header.append(try Self.read(client, count: 1)) }
                let request = String(decoding: header, as: UTF8.self)
                let line = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }!
                let key = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                let acceptKey = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                try Self.write(client, data: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n".utf8))
                try handler(client, request)
            } catch { XCTFail("Fixture failed: \(error)") }
        }
    }
    func close() {
        if !stopped { stopped = true; shutdown(fd, SHUT_RDWR); Darwin.close(fd); try? FileManager.default.removeItem(at: endpoint.deletingLastPathComponent()) }
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                guard n > 0 else { throw LatticesError.disconnected }; offset += n
            }
        }; return data
    }
    static func write(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard n > 0 else { throw LatticesError.disconnected }; offset += n
            }
        }
    }
}
