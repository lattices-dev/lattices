import CoreGraphics
import XCTest
@testable import ActionCore

final class ActionPointerMotionTests: XCTestCase {
    func testEaseStartsAndEndsAtRest() {
        XCTAssertEqual(ActionPointerMotion.ease(0), 0)
        XCTAssertEqual(ActionPointerMotion.ease(1), 1)
        XCTAssertEqual(ActionPointerMotion.ease(0.5), 0.5, accuracy: 1e-9)
        // Slow at the ends, fast through the middle.
        XCTAssertLessThan(ActionPointerMotion.ease(0.05), 0.01)
        XCTAssertGreaterThan(ActionPointerMotion.ease(0.55) - ActionPointerMotion.ease(0.45), 0.15)
    }

    func testPathLandsExactlyOnItsEnds() {
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 400, y: 260)
        let control = ActionPointerMotion.bowControl(from: start, to: end, fraction: 0.06, limit: 14)
        XCTAssertEqual(ActionPointerMotion.point(from: start, control: control, to: end, progress: 0), start)
        XCTAssertEqual(ActionPointerMotion.point(from: start, control: control, to: end, progress: 1), end)
    }

    func testBowStaysSmall() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 1000, y: 0)
        let control = ActionPointerMotion.bowControl(from: start, to: end, fraction: 0.06, limit: 14)
        XCTAssertEqual(abs(control.y), 14, accuracy: 1e-6)
        XCTAssertEqual(ActionPointerMotion.bowControl(from: start, to: start, fraction: 0.06, limit: 14), start)
    }

    func testDragPaceFollowsDistance() {
        let origin = CGPoint.zero
        XCTAssertEqual(ActionPointerMotion.dragDurationMs(from: origin, to: CGPoint(x: 10, y: 0)), 140)
        XCTAssertEqual(ActionPointerMotion.dragDurationMs(from: origin, to: CGPoint(x: 288, y: 0)), 230)
        XCTAssertEqual(ActionPointerMotion.dragDurationMs(from: origin, to: CGPoint(x: 3000, y: 0)), 420)
    }
}
