import Foundation
import XCTest
@testable import SpeechAppRuntime

final class SpeechSocketIntegrationTests: XCTestCase {
    @MainActor
    func testSpeechRequestsAndEventsRequireCapability() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let capabilityURL = directory.appendingPathComponent("capability")
        let api = SpeechApi()
        let queue = SpeechQueue(synthesizer: FakeSpeechSynthesizer(), player: FakeSpeechPlayer())
        SpeechRpc.register(on: api, queue: queue)
        let server = SpeechServer(port: 0, capabilityURL: capabilityURL, api: api, speechQueue: queue)
        server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertGreaterThan(server.listeningPort, 0)
        let token = try String(contentsOf: capabilityURL, encoding: .utf8)
        let endpoint = URL(string: "ws://127.0.0.1:\(server.listeningPort)/")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let anonymous = session.webSocketTask(with: endpoint)
        var request = URLRequest(url: endpoint)
        request.setValue(token, forHTTPHeaderField: "X-Lattices-Speech-Token")
        let authorized = session.webSocketTask(with: request)
        anonymous.resume()
        authorized.resume()
        defer {
            anonymous.cancel(with: .normalClosure, reason: nil)
            authorized.cancel(with: .normalClosure, reason: nil)
        }
        let payload = "{\"id\":\"check\",\"method\":\"speech.status\",\"params\":null}"
        do {
            try await anonymous.send(.string(payload))
            _ = try await receive(anonymous)
            XCTFail("Anonymous connection must be rejected before WebSocket upgrade")
        } catch { /* HTTP upgrade was rejected. */ }
        try await authorized.send(.string(payload))
        let accepted = try await receive(authorized)
        XCTAssertNil(accepted["error"] as? String)
        XCTAssertNotNil(accepted["result"])

        server.broadcast(DaemonEvent(event: "speech.changed", data: .object(["private": .bool(true)])))
        server.broadcast(DaemonEvent(event: "test.marker", data: .object([:])))
        let privateEvent = try await receive(authorized)
        XCTAssertEqual(privateEvent["event"] as? String, "speech.changed")
        _ = try await receive(authorized) // Consume its public marker as well.

        // Concurrent producers must not interleave frame bytes, including large
        // payloads that exceed a typical socket send buffer.
        let body = String(repeating: "speech payload ", count: 10_000)
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            server.broadcast(DaemonEvent(event: "speech.changed", data: .object([
                "sequence": .int(index), "text": .string(body)
            ])))
        }
        var sequences = Set<Int>()
        for _ in 0..<12 {
            let event = try await receive(authorized)
            let data = try XCTUnwrap(event["data"] as? [String: Any])
            XCTAssertEqual(data["text"] as? String, body)
            sequences.insert(try XCTUnwrap(data["sequence"] as? Int))
        }
        XCTAssertEqual(sequences, Set(0..<12))
        try await authorized.send(.string("{\"id\":\"reserve\",\"method\":\"speech.playback.reserve\"}"))
        let reservation = try await receive(authorized)
        XCTAssertEqual(reservation["result"] as? Bool, true)
        let job = try queue.enqueue(SpeechRpc.parseEnqueue(.object(["text": .string("After worker disconnect")])))
        XCTAssertEqual(queue.snapshot.current, nil)
        XCTAssertEqual(queue.snapshot.queued.first?.id, job.id)
        authorized.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<100 {
            if queue.snapshot.current?.state == .playing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queue.snapshot.current?.id, job.id)
        XCTAssertEqual(queue.snapshot.current?.state, .playing)
        _ = try queue.stop()
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: throw CocoaError(.coderReadCorrupt)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
