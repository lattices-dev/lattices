import AppKit
import XCTest
@testable import Lattices

final class SpaceCanvasPointerProtectionTests: XCTestCase {
    func testPendingLeaseBlocksEveryUnmarkedPointerType() {
        var policy = SpaceCanvasPointerProtection.Policy()
        policy.leases.insert(UUID())
        for type in SpaceCanvasPointerProtection.Policy.eventTypes {
            XCTAssertTrue(policy.consumes(type, marker: 0, button: 4), "\(type)")
        }
        XCTAssertFalse(policy.consumes(.keyDown, marker: 0))
        XCTAssertFalse(policy.consumes(.flagsChanged, marker: 0))
    }

    func testCarryStreamPassesWithoutTakingHumanButtonOwnership() {
        var policy = SpaceCanvasPointerProtection.Policy()
        policy.leases.insert(UUID())
        for type in SpaceCanvasPointerProtection.Policy.eventTypes {
            XCTAssertFalse(policy.consumes(type, marker: WindowSpaceCarry.pointerEventMarker))
        }
        XCTAssertTrue(policy.buttons.isEmpty)
        XCTAssertTrue(policy.consumes(.leftMouseDown, marker: 123), "Unrelated synthetic input is also blocked")
        XCTAssertFalse(policy.consumes(.leftMouseUp, marker: WindowSpaceCarry.pointerEventMarker))
        XCTAssertEqual(policy.buttons, [0], "Synthetic release must not release a swallowed human press")
    }

    func testEndRetainsOnlyMatchingHumanPressTails() {
        var policy = SpaceCanvasPointerProtection.Policy()
        let id = UUID()
        policy.leases.insert(id)
        XCTAssertTrue(policy.consumes(.leftMouseDown, marker: 0))
        XCTAssertTrue(policy.consumes(.otherMouseDown, marker: 0, button: 4))
        policy.leases.remove(id)
        XCTAssertTrue(policy.needsTap)
        XCTAssertTrue(policy.consumes(.leftMouseDragged, marker: 0))
        XCTAssertFalse(policy.consumes(.rightMouseDown, marker: 0))
        XCTAssertFalse(policy.consumes(.scrollWheel, marker: 0))
        XCTAssertTrue(policy.consumes(.leftMouseUp, marker: 0))
        XCTAssertTrue(policy.needsTap)
        XCTAssertFalse(policy.consumes(.otherMouseUp, marker: 0, button: 3))
        XCTAssertTrue(policy.consumes(.otherMouseUp, marker: 0, button: 4))
        XCTAssertFalse(policy.needsTap)
        XCTAssertFalse(policy.consumes(.mouseMoved, marker: 0))
    }

    func testAnOlderCompletionCannotReleaseANewerLease() {
        var policy = SpaceCanvasPointerProtection.Policy()
        let old = UUID(), new = UUID()
        policy.leases = [old, new]
        policy.leases.remove(old)
        XCTAssertTrue(policy.consumes(.leftMouseDown, marker: 0))
        XCTAssertTrue(policy.consumes(.leftMouseUp, marker: 0))
        policy.leases.remove(old)
        XCTAssertTrue(policy.needsTap)
        policy.leases.remove(new)
        XCTAssertFalse(policy.needsTap)
    }
}
