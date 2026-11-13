import XCTest
@testable import Lattices

final class DaemonDeliveryTests: XCTestCase {
    private func fields(_ delivery: DaemonDelivery, _ method: String) -> [String: JSON] {
        guard case .object(let object) = delivery.json(method: method) else { return [:] }
        return object
    }

    func testRefusalsNeverReachedTheDesktop() {
        XCTAssertEqual(DaemonDelivery.failed(RouterError.missingParam("wid")), .notDelivered)
        XCTAssertEqual(DaemonDelivery.failed(RouterError.notFound("window 4")), .notDelivered)
        XCTAssertEqual(fields(.notDelivered, "computer.click")["retrySafe"], .bool(true))
    }

    func testAHandlerFailureMayHaveActed() {
        XCTAssertEqual(DaemonDelivery.failed(RouterError.custom("AX press failed")), .uncertain)
        XCTAssertEqual(DaemonDelivery.failed(NSError(domain: "x", code: 1)), .uncertain)
        XCTAssertEqual(fields(.uncertain, "computer.click"), [
            "status": .string("delivery_uncertain"), "retrySafe": .bool(false), "recovery": .string("observe_then_retry"),
        ])
        XCTAssertEqual(fields(.uncertain, "windows.focus")["retrySafe"], .bool(true))
    }

    func testDeliveredClicksAreNotResent() {
        XCTAssertEqual(fields(.deliveredUnverified, "computer.typeText")["retrySafe"], .bool(false))
        XCTAssertEqual(fields(.deliveredUnverified, "windows.place")["retrySafe"], .bool(true))
    }

    func testReadsOmitTheField() throws {
        let data = try JSONEncoder().encode(DaemonResponse(id: "1", result: .null, error: nil))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("delivery"))
    }
}
