import XCTest
@testable import Lattices

final class MouseHandoffTests: XCTestCase {
    func testExactPhysicalChordOnly() {
        XCTAssertTrue(MouseHandoffGesture.qualifies(button: 1, flags: .maskControl, sourcePID: 0))
        XCTAssertFalse(MouseHandoffGesture.qualifies(button: 1, flags: [], sourcePID: 0))
        XCTAssertFalse(MouseHandoffGesture.qualifies(button: 1, flags: [.maskControl, .maskShift], sourcePID: 0))
        XCTAssertFalse(MouseHandoffGesture.qualifies(button: 2, flags: .maskControl, sourcePID: 0))
        XCTAssertFalse(MouseHandoffGesture.qualifies(button: 1, flags: .maskControl, sourcePID: 123))
    }

    func testDeliberateHorizontalThrowInEitherDirection() {
        XCTAssertEqual(MouseHandoffGesture.direction(delta: CGPoint(x: -80, y: 20), threshold: 68), .left)
        XCTAssertEqual(MouseHandoffGesture.direction(delta: CGPoint(x: 80, y: -20), threshold: 68), .right)
        for delta in [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: -80, y: 70)] {
            XCTAssertNil(MouseHandoffGesture.direction(delta: delta, threshold: 68))
        }
        XCTAssertNil(MouseHandoffGesture.direction(delta: CGPoint(x: -80, y: 0), threshold: 100))
    }

    func testPairedChannelCycleAndPreflight() {
        typealias Host = LogitechHostConnection.HostInfo
        for current: UInt8 in 0..<3 {
            let keyboard = Host(feature: 8, count: 3, current: current)
            let mouse = Host(feature: 10, count: 3, current: current)
            XCTAssertEqual(LogitechHostConnection.pairedTarget(keyboard: keyboard, mouse: mouse, direction: .left), [2, 0, 1][Int(current)])
            XCTAssertEqual(LogitechHostConnection.pairedTarget(keyboard: keyboard, mouse: mouse, direction: .right), [1, 2, 0][Int(current)])
        }
        let mouse = Host(feature: 10, count: 3, current: 2)
        for keyboard in [Host(feature: 8, count: 3, current: 1), Host(feature: 8, count: 2, current: 2), Host(feature: 8, count: 3, current: 3)] {
            XCTAssertNil(LogitechHostConnection.pairedTarget(keyboard: keyboard, mouse: mouse, direction: .left))
        }
        XCTAssertNil(LogitechHostConnection.pairedTarget(keyboard: mouse, mouse: Host(feature: 10, count: 2, current: 2), direction: .right))
    }

    func testOneShotCooldown() {
        var gate = MouseHandoffCooldown()
        XCTAssertTrue(gate.reserve(at: 1))
        XCTAssertFalse(gate.reserve(at: 1))
        XCTAssertFalse(gate.reserve(at: 5.9))
        XCTAssertTrue(gate.reserve(at: 6))
    }

    func testChangeHostFrameAndReplyCorrelation() {
        let frame = LogitechHostConnection.frame(feature: 0x0a, function: 1, parameters: [1])
        XCTAssertEqual(frame.count, 20)
        XCTAssertEqual(Array(frame.prefix(5)), [0x11, 0xff, 0x0a, 0x1b, 1])
        XCTAssertEqual(Array(frame.suffix(15)), [UInt8](repeating: 0, count: 15))
        XCTAssertTrue(LogitechHostConnection.matches(frame, feature: 0x0a, function: 1))
        XCTAssertFalse(LogitechHostConnection.matches(frame, feature: 0x0b, function: 1))
        XCTAssertFalse(LogitechHostConnection.matches(frame, feature: 0x0a, function: 0))
        XCTAssertFalse(LogitechHostConnection.matches(Array(frame.prefix(5)), feature: 0x0a, function: 1))
        let error: [UInt8] = [0x10, 0xff, 0xff, 0x0a, 0x1b, 0x02, 0]
        XCTAssertTrue(LogitechHostConnection.matches(error, feature: 0x0a, function: 1))
        XCTAssertFalse(LogitechHostConnection.matches(error, feature: 0x0a, function: 0))
    }
}
