import Foundation
import XCTest
@testable import Lattices

final class CompanionDaemonBoundaryTests: XCTestCase {
    func testRealLegacySocketRejectsSpeechWithoutCapability() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture-capability".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let run = URL(fileURLWithPath: "/private/tmp/lats-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: run) }
        let tokenFile = run.appendingPathComponent("lattices.token")
        let server = DaemonServer(port: 0, tokenURL: tokenFile, speechCapabilityURL: file)
        server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.listeningPort, 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(server.listeningPort)")!)
        request.setValue(try String(contentsOf: tokenFile, encoding: .utf8), forHTTPHeaderField: "x-lattices-token")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string("{\"id\":\"denied\",\"method\":\"speech.status\"}"))
        let message = try await socket.receive()
        let data: Data
        switch message { case .string(let string): data = Data(string.utf8); case .data(let bytes): data = bytes; @unknown default: fatalError() }
        let response = try JSONDecoder().decode(DaemonResponse.self, from: data)
        XCTAssertEqual(response.id, "denied")
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error.map(VoiceHelperRouting.errorCode), "helper_unauthorized")
    }
}
