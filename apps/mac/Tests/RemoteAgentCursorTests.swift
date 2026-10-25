import AppKit
import XCTest
@testable import Lattices

@MainActor
final class RemoteAgentCursorTests: XCTestCase {
    func testDecorationNeverInterceptsInput() {
        let cursor = RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        cursor.follow(CGPoint(x: 200, y: 100), reduceMotion: false)
        XCTAssertFalse(cursor.isHidden)
        XCTAssertNil(cursor.hitTest(CGPoint(x: 216, y: 118)))
    }

    func testLeavingDuringFlightCannotResurrectTheHand() async throws {
        let cursor = RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: false)
        cursor.land(at: CGPoint(x: 500, y: 300), reduceMotion: false)
        XCTAssertTrue(cursor.isLanding)
        cursor.reset()
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertTrue(cursor.isHidden)
        XCTAssertFalse(cursor.isLanding)
        XCTAssertTrue(cursor.layer?.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
    }

    func testReducedMotionHasNoTravelScaleOrDrop() async throws {
        let cursor = RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: true)
        cursor.follow(CGPoint(x: 250, y: 100), reduceMotion: true)
        cursor.land(at: CGPoint(x: 250, y: 100), reduceMotion: true)
        await Task.yield()
        let keys = cursor.layer?.sublayers?.flatMap { $0.animationKeys() ?? [] } ?? []
        XCTAssertFalse(keys.contains("flight"))
        XCTAssertFalse(keys.contains("spread"))
        XCTAssertFalse(keys.contains("drop"))
        cursor.reset()
    }

    func testRapidClicksRetargetWithoutAStaleLanding() async throws {
        let cursor = RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: false)
        cursor.land(at: CGPoint(x: 500, y: 300), reduceMotion: false)
        cursor.land(at: CGPoint(x: 100, y: 100), reduceMotion: false)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertFalse(cursor.isLanding)
        XCTAssertFalse(cursor.isHidden)
        cursor.reset()
    }

    func testReturnModeKeepsItsHomeAcrossHoverAndInterruptedClicks() async throws {
        let cursor = RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        cursor.behavior = .returnToOrigin
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: true)
        let hand = try XCTUnwrap(cursor.layer?.sublayers?.last)
        let home = hand.position
        cursor.follow(CGPoint(x: 300, y: 100), reduceMotion: true)
        XCTAssertEqual(hand.position, home)
        cursor.land(at: CGPoint(x: 300, y: 100), reduceMotion: true)
        cursor.land(at: CGPoint(x: 400, y: 200), reduceMotion: true)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(hand.position, home)
        XCTAssertFalse(cursor.isLanding)
        cursor.reset()
    }
}
