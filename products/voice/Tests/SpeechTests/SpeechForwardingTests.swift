import Foundation
import XCTest
@testable import SpeechAppRuntime

typealias DaemonRequest = SpeechAppRuntime.DaemonRequest
typealias DaemonResponse = SpeechAppRuntime.DaemonResponse
typealias DaemonEvent = SpeechAppRuntime.DaemonEvent
// Production defaults are unused; tests bind their own loopback port.
enum LatticesLocalEndpoints {
    static let speechCompanionURL = URL(string: "ws://127.0.0.1:9397")!
    static let speechCompanionSocketPath = "/unused/speech.sock"
    static let speechCompanionTokenURL = URL(fileURLWithPath: "/unused/speech.token")
}

final class SpeechForwardingTests: XCTestCase {
    @MainActor
    func testSeparateCallerReservationsAndHostSurvivalAfterClientCloses() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let tokenFile = directory.appendingPathComponent("capability")
        let api = SpeechApi()
        let queue = SpeechQueue(synthesizer: FakeSpeechSynthesizer(), player: FakeSpeechPlayer())
        SpeechRpc.register(on: api, queue: queue)
        let server = SpeechServer(port: 0, capabilityURL: tokenFile, api: api, speechQueue: queue)
        server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "ws://127.0.0.1:\(server.listeningPort)")!
        let inbox = ForwardingInbox()
        let first = SpeechCompanionConnection(endpoint: endpoint, tokenFile: tokenFile,
            response: { result in Task { await inbox.add(result) } }, event: { _ in })
        let second = SpeechCompanionConnection(endpoint: endpoint, tokenFile: tokenFile,
            response: { result in Task { await inbox.add(result) } }, event: { _ in })
        await first.forward(DaemonRequest(id: "first", method: "speech.playback.reserve", params: nil))
        let accepted = try await inbox.wait("first")
        XCTAssertNil(accepted.error)
        await second.forward(DaemonRequest(id: "second", method: "speech.playback.reserve", params: nil))
        let denied = try await inbox.wait("second")
        XCTAssertNotNil(denied.error)
        let job = try queue.enqueue(SpeechRpc.parseEnqueue(.object(["text": .string("Independent job")])) )
        XCTAssertEqual(queue.snapshot.queued.first?.id, job.id)
        await second.close()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(queue.snapshot.current, "An unrelated caller must not release the first caller's reservation")
        await first.close()
        for _ in 0..<100 {
            if queue.snapshot.current?.state == .playing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queue.snapshot.current?.id, job.id)
        XCTAssertEqual(queue.snapshot.current?.state, .playing)
        XCTAssertGreaterThan(server.listeningPort, 0)
        _ = try queue.stop()
    }

    @MainActor
    func testOldReceiveFailureCannotCloseReconnectedSocket() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let tokenFile = directory.appendingPathComponent("capability")
        let api = SpeechApi()
        let queue = SpeechQueue(synthesizer: FakeSpeechSynthesizer(), player: FakeSpeechPlayer())
        SpeechRpc.register(on: api, queue: queue)
        let server = SpeechServer(port: 0, capabilityURL: tokenFile, api: api, speechQueue: queue)
        server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let inbox = ForwardingInbox()
        let client = SpeechCompanionConnection(endpoint: URL(string: "ws://127.0.0.1:\(server.listeningPort)")!, tokenFile: tokenFile,
            response: { result in Task { await inbox.add(result) } }, event: { _ in })
        await client.forward(DaemonRequest(id: "old", method: "speech.status", params: nil))
        _ = try await inbox.wait("old")
        let old = await client.testConnection()!
        await client.close()
        await client.forward(DaemonRequest(id: "new", method: "speech.status", params: nil))
        let new = await client.testConnection()!
        XCTAssertFalse(old === new)
        await client.testLateFailure(from: old)
        let result = try await inbox.wait("new")
        XCTAssertNil(result.error)
        let retained = await client.testConnection()
        XCTAssertTrue(retained === new)
        await client.forward(DaemonRequest(id: "after", method: "speech.status", params: nil))
        let after = try await inbox.wait("after")
        XCTAssertNil(after.error)
        await client.close()
    }

    func testClientBoundaryRejectsMissingWrongDuplicateAndBrowserTokens() throws {
        let file = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try Data("local-secret".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let start = "GET / HTTP/1.1\r\n"
        let header = "x-lattices-speech-token: local-secret\r\n"
        XCTAssertTrue(SpeechCompanionConnection.authorizes(handshake: start + header + "\r\n", tokenFile: file))
        for headers in ["", "x-lattices-speech-token: wrong\r\n", header + header, header + "Origin: https://example.test\r\n"] {
            XCTAssertFalse(SpeechCompanionConnection.authorizes(handshake: start + headers + "\r\n", tokenFile: file))
        }
    }
}
private actor ForwardingInbox {
    var results: [String: DaemonResponse] = [:]
    func add(_ result: DaemonResponse) { results[result.id] = result }
    func wait(_ id: String) async throws -> DaemonResponse {
        for _ in 0..<200 {
            if let result = results.removeValue(forKey: id) { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "SpeechForwardingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(id)"])
    }
}
