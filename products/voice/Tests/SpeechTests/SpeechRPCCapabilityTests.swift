import Foundation
import XCTest
@testable import SpeechAppRuntime

final class SpeechRPCCapabilityTests: XCTestCase {
    func testPrivateCapabilityAndHeaderValidation() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capability")
        let capability = try SpeechRPCCapability(url: url)
        let token = try String(contentsOf: url, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        func handshake(_ headers: String) -> String { "GET / HTTP/1.1\r\n\(headers)\r\n\r\n" }
        let header = "X-Lattices-Speech-Token: \(token)"
        XCTAssertTrue(capability.authorizes(handshake: handshake(header)))
        XCTAssertFalse(capability.authorizes(handshake: handshake("Host: localhost")))
        XCTAssertFalse(capability.authorizes(handshake: handshake(header + "\r\nOrigin: http://localhost")))
        XCTAssertFalse(capability.authorizes(handshake: handshake(header + "\r\n" + header)))
        XCTAssertFalse(capability.authorizes(handshake: handshake("X-Lattices-Speech-Token: wrong")))
        let replacement = try SpeechRPCCapability(url: url)
        capability.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        replacement.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
