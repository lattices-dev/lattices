@testable import ActionCore
import Foundation
import XCTest

final class ActionLayerSafetyGateTests: XCTestCase {
    private func withPolicy(_ content: String?, body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("isolation-block.json")
        if let content { try Data(content.utf8).write(to: url) }
        try body(url)
    }

    func testMissingPolicyDoesNotBlock() throws {
        try withPolicy(nil) { url in
            let state = ActionLayerSafetyGate.read(at: url)
            XCTAssertFalse(state.blocked)
            XCTAssertNil(ActionLayerSafetyGate.refusal(for: state))
        }
    }

    func testConfirmedFailureBlocksWithReasonAndPath() throws {
        try withPolicy(#"{"blocked":true,"reason":"physical display mode changed"}"#) { url in
            let state = ActionLayerSafetyGate.read(at: url)
            XCTAssertTrue(state.blocked)
            XCTAssertEqual(state.reason, "physical display mode changed")
            let refusal = try XCTUnwrap(ActionLayerSafetyGate.refusal(for: state))
            XCTAssertTrue(refusal.contains(url.path))
            XCTAssertTrue(refusal.contains("No virtual display was created"))
        }
    }

    func testExplicitFalseDoesNotBlock() throws {
        try withPolicy(#"{"blocked":false}"#) { url in
            XCTAssertFalse(ActionLayerSafetyGate.read(at: url).blocked)
        }
    }

    func testMalformedExistingPoliciesFailClosed() throws {
        for content in ["", "not json", "{}", #"{"blocked":"false"}"#, #"{"blocked":true,"reason":42}"#] {
            try withPolicy(content) { url in
                XCTAssertTrue(ActionLayerSafetyGate.read(at: url).blocked, content)
            }
        }
    }

    func testDirectoryInsteadOfFileFailsClosed() throws {
        try withPolicy(nil) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertTrue(ActionLayerSafetyGate.read(at: url).blocked)
        }
    }
}
