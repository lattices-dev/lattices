import CommonCrypto
import Darwin
import Foundation
import XCTest
@testable import Lattices

final class DaemonSpeechPrivateForwardingTests: XCTestCase {
    private static let childKey = "LATTICES_SPEECH_FORWARDING_TEST_CHILD"

    func testDefaultDaemonForwardsToSpeechPrivateSocketWithItsOwnToken() async throws {
        if ProcessInfo.processInfo.environment[Self.childKey] == "1" {
            try exerciseDefaultForwarding()
            print("PRIVATE_SPEECH_FORWARDING_OK")
            return
        }

        // Keep endpoint overrides out of the parent test process, whose other
        // tests and singletons may already have resolved their runtime paths.
        let directory = URL(fileURLWithPath: "/private/tmp/lats-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("child.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest",
                             "LatticesTests.DaemonSpeechPrivateForwardingTests/testDefaultDaemonForwardsToSpeechPrivateSocketWithItsOwnToken",
                             Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childKey] = "1"
        environment["LATTICES_RUNTIME_DIR"] = directory.path
        for key in ["LATTICES_ALLOW_LOOPBACK_TCP", "LATTICES_SPEECH_TCP", "LATTICES_VOICE_ALLOW_LEGACY_TCP"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardOutput = log; process.standardError = log
        let exited = expectation(description: "isolated daemon-to-Speech regression process exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        await fulfillment(of: [exited], timeout: 15)
        guard !process.isRunning else { return }
        let output = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("PRIVATE_SPEECH_FORWARDING_OK"), output)
    }

    private func exerciseDefaultForwarding() throws {
        let directory = LatticesLocalEndpoints.runtimeDirectory
        let legacyURL = directory.appendingPathComponent("legacy-speech-capability")
        let legacyToken = "legacy-caller-capability-is-not-the-private-token"
        try Data(legacyToken.utf8).write(to: legacyURL)
        XCTAssertEqual(chmod(legacyURL.path, 0o600), 0)
        let speechPath = LatticesLocalEndpoints.speechCompanionSocketPath
        let speechTokenURL = LatticesLocalEndpoints.speechCompanionTokenURL
        let lease = try PrivateLocalEndpoint(socketPath: speechPath, tokenURL: speechTokenURL)
        defer { lease.closeLease() }
        let listener = try descriptor()
        defer { Darwin.close(listener) }
        try lease.bindSocket(listener, path: speechPath)
        let privateToken = try lease.publishToken(at: speechTokenURL)
        XCTAssertNotEqual(privateToken, legacyToken)
        guard Darwin.listen(listener, 1) == 0 else { throw socketError() }

        let served = expectation(description: "Speech received the authenticated forwarded request")
        let callerFinished = DispatchSemaphore(value: 0)
        defer { callerFinished.signal() }
        DispatchQueue(label: "test.speech.private-responder").async {
            defer { served.fulfill() }
            do {
                var readable = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&readable, 1, 4000) == 1 else { throw POSIXError(.ETIMEDOUT) }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { throw self.socketError() }
                defer { Darwin.close(peer) }
                try self.configure(peer)
                let handshake = try self.readHeader(peer)
                guard DaemonAdmission.allows(handshake, token: privateToken, port: nil) else {
                    throw POSIXError(.EACCES)
                }
                XCTAssertFalse(handshake.lowercased().contains("x-lattices-speech-token:"))
                let key = try XCTUnwrap(handshake.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                    .split(separator: ":", maxSplits: 1).last)
                    .trimmingCharacters(in: .whitespaces)
                let bytes = Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
                CC_SHA1(bytes, CC_LONG(bytes.count), &digest)
                try self.writeAll(peer, Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                    "Connection: Upgrade\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n").utf8))
                let request = try JSONDecoder().decode(DaemonRequest.self, from: self.readFrame(peer, masked: true))
                XCTAssertEqual(request.id, "private-forwarding")
                XCTAssertEqual(request.method, "speech.voices", "The actual voice.list request must reach Speech")
                let response = DaemonResponse(id: request.id,
                    result: .object(["source": .string("isolated-private-speech")]), error: nil)
                try self.writeFrame(peer, data: JSONEncoder().encode(response), masked: false)
                // Keep the helper connection alive until the daemon's caller
                // has received the result, matching the real persistent helper.
                _ = callerFinished.wait(timeout: .now() + 5)
            } catch {
                XCTFail("Private Speech responder failed: \(error)")
            }
        }

        // Do not inject speechEndpoint: the production default is the behavior
        // under test. Legacy caller authorization is deliberately a different
        // credential, so forwarding that token also fails this regression.
        let server = DaemonServer(speechCapabilityURL: legacyURL, eventBus: EventBus())
        server.start()
        defer { server.stop() }
        XCTAssertEqual(server.listeningPort, 0)
        let token = try String(contentsOf: LatticesLocalEndpoints.agentTokenURL, encoding: .utf8)
        let client = try connectUnix(LatticesLocalEndpoints.agentSocketPath)
        defer { Darwin.close(client) }
        try writeAll(client, Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nx-lattices-token: \(token)\r\n" +
            "x-lattices-speech-token: \(legacyToken)\r\n\r\n").utf8))
        XCTAssertTrue(try readHeader(client).hasPrefix("HTTP/1.1 101"))
        try writeFrame(client, data: Data(#"{"id":"private-forwarding","method":"voice.list"}"#.utf8), masked: true)
        let response = try JSONDecoder().decode(DaemonResponse.self, from: readFrame(client, masked: false))
        XCTAssertEqual(response.id, "private-forwarding")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["source"]?.stringValue, "isolated-private-speech")
        callerFinished.signal()
        wait(for: [served], timeout: 5)
    }

    private func descriptor() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do { try configure(fd); return fd } catch { Darwin.close(fd); throw error }
    }

    private func configure(_ fd: Int32) throws {
        guard PrivateLocalEndpoint.preventInheritance(fd) else { throw socketError() }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else { throw socketError() }
    }

    private func connectUnix(_ path: String) throws -> Int32 {
        let fd = try descriptor()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { let error = socketError(); Darwin.close(fd); throw error }
        return fd
    }

    private func readHeader(_ fd: Int32) throws -> String {
        var data = Data()
        while !data.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard data.count < 8192 else { throw POSIXError(.EMSGSIZE) }
            data.append(try readExactly(fd, count: 1))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func readFrame(_ fd: Int32, masked: Bool) throws -> Data {
        let header = [UInt8](try readExactly(fd, count: 2))
        guard header[0] == 0x81, (header[1] & 0x80 != 0) == masked else { throw POSIXError(.EPROTO) }
        var length = Int(header[1] & 0x7f)
        if length == 126 { length = try readExactly(fd, count: 2).reduce(0) { ($0 << 8) | Int($1) } }
        guard header[1] & 0x7f != 127, length < 8192 else { throw POSIXError(.EMSGSIZE) }
        let mask = masked ? [UInt8](try readExactly(fd, count: 4)) : [0, 0, 0, 0]
        return Data(try readExactly(fd, count: length).enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    private func writeFrame(_ fd: Int32, data: Data, masked: Bool) throws {
        guard data.count < 126 else { throw POSIXError(.EMSGSIZE) }
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload = masked ? Data(data.enumerated().map { $0.element ^ mask[$0.offset % 4] }) : data
        try writeAll(fd, Data([0x81, UInt8(data.count) | (masked ? 0x80 : 0)]) + (masked ? Data(mask) : Data()) + payload)
    }

    private func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let read = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                guard read > 0 else { throw socketError() }
                offset += read
            }
        }
        return result
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw socketError() }
                offset += written
            }
        }
    }

    private func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
