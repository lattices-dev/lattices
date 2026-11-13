import AppKit
import QuartzCore
import XCTest
@testable import Lattices

@MainActor
final class RemoteAgentCursorTests: XCTestCase {
    func testDecorationNeverInterceptsInput() {
        let cursor = makeCursor()
        cursor.follow(CGPoint(x: 200, y: 100), reduceMotion: false)
        XCTAssertFalse(cursor.isHidden)
        XCTAssertNil(cursor.hitTest(CGPoint(x: 200, y: 100)))
    }

    func testCompanionSettlesExactlyAtTheDotIncludingPictureEdges() throws {
        let cursor = makeCursor()
        let pointer = try pointer(in: cursor)
        for point in [CGPoint(x: 200, y: 100), .zero, CGPoint(x: 599, y: 399)] {
            cursor.follow(point, reduceMotion: false)
            XCTAssertEqual(pointer.position, point)
        }
        cursor.reset()
    }

    func testFastMovementNeverCreatesADistantTrailingPointer() throws {
        let cursor = makeCursor()
        let pointer = try pointer(in: cursor)
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: false)
        cursor.follow(CGPoint(x: 550, y: 350), reduceMotion: false)
        XCTAssertEqual(pointer.position, CGPoint(x: 550, y: 350))
        let settle = try XCTUnwrap(pointer.animation(forKey: "settle") as? CABasicAnimation)
        let start = try XCTUnwrap((settle.fromValue as? NSValue)?.pointValue)
        XCTAssertLessThanOrEqual(hypot(start.x - 550, start.y - 350), RemoteAgentCursorView.maximumSeparation + 0.001)
        XCTAssertLessThanOrEqual(settle.duration, RemoteAgentCursorView.catchUp)
        XCTAssertGreaterThan(pointer.opacity, 0, "The companion remains visible at rest")
    }

    func testClicksStayAtTheDotWithoutMovingTheCompanion() async throws {
        let cursor = makeCursor()
        let pointer = try pointer(in: cursor)
        cursor.follow(CGPoint(x: 250, y: 100), reduceMotion: false)
        cursor.indicateClick(at: CGPoint(x: 500, y: 300), reduceMotion: false)
        let ripple = try XCTUnwrap(cursor.layer?.sublayers?.first)
        XCTAssertEqual(ripple.position, CGPoint(x: 500, y: 300))
        XCTAssertEqual(pointer.position, CGPoint(x: 250, y: 100))
        XCTAssertTrue((pointer.animationKeys() ?? []).isEmpty)
        cursor.follow(CGPoint(x: 350, y: 220), reduceMotion: false)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(pointer.position, CGPoint(x: 350, y: 220), "No delayed retreat after a click")
        cursor.reset()
    }

    func testDotHotspotIsAtItsCenter() {
        let cursor = RemoteAgentCursorView.controlCursor
        XCTAssertEqual(cursor.hotSpot, CGPoint(x: 6, y: 6))
        XCTAssertEqual(cursor.image.size, CGSize(width: 12, height: 12))
    }

    func testLeavingClearsAnimationsAndClicksCannotResurrectTheCompanion() async throws {
        let cursor = makeCursor()
        let pointer = try pointer(in: cursor)
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: false)
        cursor.follow(CGPoint(x: 500, y: 300), reduceMotion: false)
        cursor.indicateClick(at: CGPoint(x: 500, y: 300), reduceMotion: false)
        cursor.reset()
        cursor.indicateClick(at: CGPoint(x: 100, y: 100), reduceMotion: false)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertTrue(cursor.isHidden)
        XCTAssertTrue(cursor.layer?.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)

        let reentry = CGPoint(x: 50, y: 60)
        cursor.follow(reentry, reduceMotion: false)
        XCTAssertEqual(pointer.position, reentry)
        XCTAssertNil(pointer.animation(forKey: "settle"))
        cursor.reset()
    }

    func testReducedMotionKeepsStableCompanionWithoutRippleScale() throws {
        let cursor = makeCursor()
        let pointer = try pointer(in: cursor)
        let point = CGPoint(x: 250, y: 100)
        cursor.follow(CGPoint(x: 20, y: 20), reduceMotion: false)
        cursor.follow(point, reduceMotion: false)
        cursor.indicateClick(at: point, reduceMotion: false)
        cursor.follow(point, reduceMotion: true)
        cursor.indicateClick(at: point, reduceMotion: true)
        XCTAssertEqual(pointer.position, point)
        XCTAssertTrue((pointer.animationKeys() ?? []).isEmpty)
        let keys = cursor.layer?.sublayers?.flatMap { $0.animationKeys() ?? [] } ?? []
        XCTAssertEqual(keys, ["fade"])
        cursor.reset()
    }

    private func makeCursor() -> RemoteAgentCursorView {
        RemoteAgentCursorView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    private func pointer(in cursor: RemoteAgentCursorView) throws -> CALayer {
        try XCTUnwrap(cursor.layer?.sublayers?.last)
    }
}
