import CryptoKit
import Foundation
import Network
import XCTest
@testable import Lattices

final class RemoteHostGatewayCredentialsTests: XCTestCase {
    private let publicKey = "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns="
    private let fingerprint = "A053-D765-5733"
    private let identity = #"{"id":"native-test-client","privateKey":{"kty":"OKP","crv":"X25519","x":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw","d":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}}"#

    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try put(identity, at: dir.appendingPathComponent("client.json"))
        let hosts = ["100.64.0.5:9399": ["host": "mini", "hostPublicKey": publicKey, "hostFingerprint": fingerprint]]
        let data = try JSONSerialization.data(withJSONObject: hosts)
        try put(String(decoding: data, as: UTF8.self), at: dir.appendingPathComponent("paired-hosts.json"))
        return dir
    }
    private func put(_ value: String, at url: URL) throws {
        try Data(value.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func testSignsTheCLIProtocolGoldenVector() throws {
        let dir = try fixture()
        let date = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!
        let headers = try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir, now: date, nonce: "fixed-test-nonce")
        XCTAssertEqual(headers["Host"], "100.64.0.5:9399")
        XCTAssertEqual(headers["X-Lattices-Device-Id"], "native-test-client")
        XCTAssertEqual(headers["X-Lattices-Timestamp"], "2026-10-19T00:00:00.000Z")
        // Independently calculated with Node X25519 + HKDF-SHA256 + HMAC.
        XCTAssertEqual(headers["X-Lattices-Signature"], "p2HzrVdyk01zps9FweuUSwLuOEpILY9aHFPr+G4J9CQ=")
    }

    func testEachConnectionGetsAFreshNonce() throws {
        let dir = try fixture()
        let a = try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir)
        let b = try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir)
        XCTAssertNotEqual(a["X-Lattices-Nonce"], b["X-Lattices-Nonce"])
        XCTAssertNotEqual(a["X-Lattices-Signature"], b["X-Lattices-Signature"])
    }

    func testTailnetAliasMatchesCLITrustButPortIsExact() throws {
        let dir = try fixture()
        XCTAssertNoThrow(try RemoteHostGatewayCredentials.headers(address: "mini.tailnet.example", port: 9399, directory: dir))
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "mini.tailnet.example", port: 9400, directory: dir))
    }

    func testMissingPairingDoesNotCreateIdentityOrFallBackToUnsigned() throws {
        let dir = try fixture()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("client.json"))
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "unknown", port: 9399, directory: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Gateway pairing required"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("client.json").path))
    }

    func testFingerprintMismatchIsRejected() throws {
        let dir = try fixture()
        let url = dir.appendingPathComponent("paired-hosts.json")
        try put(String(contentsOf: url).replacingOccurrences(of: fingerprint, with: "0000-0000-0000"), at: url)
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir))
    }

    func testMalformedAndWorldReadableIdentityAreRejected() throws {
        let dir = try fixture()
        let url = dir.appendingPathComponent("client.json")
        try put(identity.replacingOccurrences(of: "X25519", with: "Ed25519"), at: url)
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir))
        try put(identity, at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir))
    }

    func testSymlinkIdentityIsRejected() throws {
        let dir = try fixture(), url = dir.appendingPathComponent("client.json"), target = dir.appendingPathComponent("key.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try RemoteHostGatewayCredentials.headers(address: "100.64.0.5", port: 9399, directory: dir))
    }

    func testUnsafeAddressesAndAmbiguousAliasesAreRejected() throws {
        for address in ["bad/path", "host?query", "user@host", "host\r\nX-Test: injected"] {
            XCTAssertNil(RemoteHostGatewayCredentials.gatewayURL(address: address, port: 9399))
        }
        XCTAssertEqual(RemoteHostGatewayCredentials.gatewayURL(address: "100.64.0.5", port: 9399)?.path, "/")
        XCTAssertNotNil(RemoteHostGatewayCredentials.gatewayURL(address: "fd7a:115c:a1e0::1", port: 9399))
        let entry = RemoteHostGatewayCredentials.StoredHost(host: "mini", hostPublicKey: publicKey, hostFingerprint: fingerprint)
        XCTAssertNil(RemoteHostGatewayCredentials.pairedHost(address: "mini.tailnet", port: 9399, hosts: ["a:9399": entry, "b:9399": entry]))
    }

    func testWebSocketSendsExactlyOneCompleteHostHeader() throws {
        let dir = try fixture()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "native-gateway-test")
        let listening = expectation(description: "listening")
        let received = expectation(description: "upgrade captured")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listening.fulfill()
            case .failed(let error):
                XCTFail("Listener failed: \(error)")
                listening.fulfill()
            default: break
            }
        }
        listener.newConnectionHandler = { peer in
            var request = Data()
            func read() {
                peer.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                    if let data { request.append(data) }
                    if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
                        let hostHeaders = lines.filter { $0.lowercased().hasPrefix("host:") }
                        XCTAssertEqual(hostHeaders, ["Host: 127.0.0.1:\(listener.port!.rawValue)"])
                        XCTAssertFalse(lines.contains { $0.lowercased().hasPrefix("origin:") })
                        XCTAssertTrue(lines.contains { $0.lowercased().hasPrefix("x-lattices-signature:") })
                        peer.cancel()
                        received.fulfill()
                    } else if complete || error != nil || request.count > 65_536 {
                        XCTFail("Incomplete upgrade")
                        peer.cancel()
                        received.fulfill()
                    } else { read() }
                }
            }
            peer.start(queue: queue)
            read()
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        wait(for: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let hosts = ["127.0.0.1:\(port)": ["host": "test", "hostPublicKey": publicKey, "hostFingerprint": fingerprint]]
        try put(String(decoding: JSONSerialization.data(withJSONObject: hosts), as: UTF8.self), at: dir.appendingPathComponent("paired-hosts.json"))
        let connection = RemoteHostConnection(address: "127.0.0.1", port: port, credentialDirectory: dir)
        defer { connection.cancel() }
        connection.start()
        wait(for: [received], timeout: 5)
    }

    func testGatewayErrorsExplainAuthAndMethodBoundaries() {
        XCTAssertTrue(RemoteHostConnection.gatewayError("scope_denied: missing lattices:windows.list").contains("permission denied"))
        XCTAssertTrue(RemoteHostConnection.gatewayError("method_denied: capture.live").contains("unavailable through the gateway"))
        XCTAssertTrue(RemoteHostConnection.gatewayError("pairing_required: test").contains("pair --read-only --screen"))
    }

    func testHandshakeDeadlineClosesAnUnresponsiveGateway() throws {
        let (listener, connection, disconnected) = try unresponsiveGateway(timeout: 0.25)
        defer { listener.cancel(); connection.cancel() }
        let closed = expectation(description: "handshake deadline")
        connection.onReady = { XCTFail("A TCP connection is not a completed WebSocket handshake") }
        connection.onClose = { reason in
            XCTAssertTrue(reason?.contains("Gateway handshake timed out") == true)
            closed.fulfill()
        }
        connection.start()
        wait(for: [closed, disconnected], timeout: 3)
    }

    func testCancellationCancelsThePendingHandshakeDeadline() throws {
        let (listener, connection, _) = try unresponsiveGateway(timeout: 0.25)
        defer { listener.cancel() }
        let closed = expectation(description: "cancelled")
        let extraClose = expectation(description: "no timeout after cancellation")
        extraClose.isInverted = true
        var closeCount = 0
        connection.onClose = { reason in
            closeCount += 1
            if closeCount == 1 {
                XCTAssertNil(reason)
                closed.fulfill()
            } else { extraClose.fulfill() }
        }
        connection.start()
        connection.cancel()
        wait(for: [closed], timeout: 3)
        wait(for: [extraClose], timeout: 0.4)
    }

    func testSuccessfulUpgradeCancelsHandshakeDeadline() throws {
        let port = try httpGateway { peer, request in
            let keyLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
            guard let keyLine else { XCTFail("Missing WebSocket key"); return }
            let key = keyLine.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            peer.send(content: Data(response.utf8), completion: .contentProcessed { error in XCTAssertNil(error) })
        }
        let connection = try localConnection(port: port, timeout: 1)
        defer { connection.cancel() }
        let ready = expectation(description: "WebSocket opened")
        let closed = expectation(description: "deadline stays cancelled after opening")
        closed.isInverted = true
        connection.onReady = { ready.fulfill() }
        connection.onClose = { _ in closed.fulfill() }
        connection.start()
        wait(for: [ready], timeout: 3)
        wait(for: [closed], timeout: 1.2)
        connection.onClose = nil
    }

    func testRedirectDoesNotForwardGatewayCredentials() throws {
        let destinationReached = expectation(description: "redirect destination must not receive credentials")
        destinationReached.isInverted = true
        let destination = try httpGateway { _, _ in destinationReached.fulfill() }
        let sourceReached = expectation(description: "signed gateway request")
        let source = try httpGateway { peer, request in
            XCTAssertTrue(request.lowercased().contains("x-lattices-signature:"))
            sourceReached.fulfill()
            let response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(destination)/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            peer.send(content: Data(response.utf8), completion: .contentProcessed { error in XCTAssertNil(error) })
        }
        let connection = try localConnection(port: source, timeout: 2)
        defer { connection.cancel() }
        let closed = expectation(description: "redirect rejected")
        connection.onReady = { XCTFail("Redirect is not an authenticated gateway connection") }
        connection.onClose = { reason in
            XCTAssertNotNil(reason)
            closed.fulfill()
        }
        connection.start()
        wait(for: [sourceReached, closed], timeout: 3)
        wait(for: [destinationReached], timeout: 0.5)
    }

    func testCancellationThenDroppingOwnerClosesSocket() throws {
        let received = expectation(description: "gateway received the upgrade")
        let disconnected = expectation(description: "cancel survives immediate owner release")
        let port = try httpGateway { peer, _ in
            received.fulfill()
            func read() {
                peer.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, complete, error in
                    if complete || error != nil { disconnected.fulfill() }
                    else { read() }
                }
            }
            read()
        }
        var connection: RemoteHostConnection? = try localConnection(port: port, timeout: 5)
        connection?.start()
        wait(for: [received], timeout: 3)
        connection?.cancel()
        connection = nil
        wait(for: [disconnected], timeout: 2)
    }

    private func localConnection(port: UInt16, timeout: TimeInterval) throws -> RemoteHostConnection {
        let dir = try fixture()
        let hosts = ["127.0.0.1:\(port)": ["host": "test", "hostPublicKey": publicKey, "hostFingerprint": fingerprint]]
        try put(String(decoding: JSONSerialization.data(withJSONObject: hosts), as: UTF8.self), at: dir.appendingPathComponent("paired-hosts.json"))
        return RemoteHostConnection(address: "127.0.0.1", port: port, credentialDirectory: dir, handshakeTimeout: timeout)
    }

    private func httpGateway(handler: @escaping (NWConnection, String) -> Void) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "http-gateway-test")
        var peers: [NWConnection] = []
        let listening = expectation(description: "HTTP gateway listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { peer in
            peers.append(peer)
            var request = Data()
            func read() {
                peer.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                    if let data { request.append(data) }
                    if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                        handler(peer, String(decoding: request, as: UTF8.self))
                    } else if complete || error != nil || request.count > 65_536 {
                        peer.cancel()
                    } else { read() }
                }
            }
            peer.start(queue: queue)
            read()
        }
        listener.start(queue: queue)
        addTeardownBlock {
            listener.cancel()
            queue.sync { for peer in peers { peer.cancel() } }
        }
        wait(for: [listening], timeout: 3)
        return try XCTUnwrap(listener.port?.rawValue)
    }

    /// Accept TCP and read the request, but deliberately never complete HTTP Upgrade.
    private func unresponsiveGateway(timeout: TimeInterval) throws -> (NWListener, RemoteHostConnection, XCTestExpectation) {
        let dir = try fixture()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "unresponsive-gateway-test")
        let listening = expectation(description: "unresponsive gateway listening")
        let disconnected = XCTestExpectation(description: "client closed its TCP connection")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { peer in
            func read() {
                peer.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, complete, error in
                    if complete || error != nil {
                        peer.cancel()
                        disconnected.fulfill()
                    } else { read() }
                }
            }
            peer.start(queue: queue)
            read()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let hosts = ["127.0.0.1:\(port)": ["host": "test", "hostPublicKey": publicKey, "hostFingerprint": fingerprint]]
        try put(String(decoding: JSONSerialization.data(withJSONObject: hosts), as: UTF8.self), at: dir.appendingPathComponent("paired-hosts.json"))
        return (listener, RemoteHostConnection(address: "127.0.0.1", port: port, credentialDirectory: dir, handshakeTimeout: timeout), disconnected)
    }
}
