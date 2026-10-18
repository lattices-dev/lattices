import XCTest
@testable import Lattices

final class SpaceSwitchSelectionTests: XCTestCase {
    func testInputDuringLandingStartsAtCommittedDestinationWithoutRetargetingCover() throws {
        var committed = try XCTUnwrap(SpaceSwitchSelection(ordered: [1, 5, 6, 7], current: 1))
        committed.choose(6)
        var next = SpaceSwitchLandingInput(selection: committed, point: CGPoint(x: 50, y: 80))
        next.press(-1, repeated: false)
        XCTAssertEqual(next.selection.target, 5)
        XCTAssertEqual(committed.target, 6, "The posted switch must retain its cover and destination")
        XCTAssertEqual(next.point, CGPoint(x: 50, y: 80))
        XCTAssertFalse(next.selection.scrubbing)
    }

    func testLandingRepeatsClampEachPressAndReleaseBeforeResume() throws {
        let committed = try XCTUnwrap(SpaceSwitchSelection(ordered: [1, 5, 6, 7], current: 6))
        var next = SpaceSwitchLandingInput(selection: committed, point: nil)
        for _ in 0..<100 { next.press(1, repeated: true) }
        next.press(-1, repeated: false)
        XCTAssertEqual(next.selection.target, 6, "Excess repeats must not delay reversal")
        XCTAssertEqual(next.direction, -1)
        XCTAssertTrue(next.selection.scrubbing)
        next.release()
        XCTAssertFalse(next.selection.scrubbing, "A key released under the cover must not leave navigation held")
    }

    func testCanvasRequestedDuringLandingRetainsNextDestinationThroughKeyRelease() throws {
        let committed = try XCTUnwrap(SpaceSwitchSelection(ordered: [1, 5, 6, 7], current: 6))
        var next = SpaceSwitchLandingInput(selection: committed, point: nil)
        next.press(-1, repeated: false)
        next.openCanvas()
        next.release()
        XCTAssertTrue(next.wantsCanvas)
        XCTAssertTrue(next.selection.scrubbing, "Opening the chooser must not implicitly commit its selection")
        XCTAssertEqual(next.selection.target, 5)
    }

    func testMergedTapsSkipIntermediateDesktopsInBothDirections() {
        for distance in -17...17 {
            XCTAssertEqual(SpaceSwitchTransit.usesDirectJump(distance: distance, hasDisplayPoint: true), abs(distance) > 1)
            XCTAssertFalse(SpaceSwitchTransit.usesDirectJump(distance: distance, hasDisplayPoint: false))
        }
    }

    func testTapIsImmediateButRepeatsWaitForRelease() throws {
        var state = try XCTUnwrap(SpaceSwitchSelection(ordered: Array(1...18), current: 1))
        state.press(1, repeated: false)
        XCTAssertEqual(state.target, 2)
        XCTAssertFalse(state.scrubbing)
        for _ in 0..<16 { state.press(1, repeated: true) }
        XCTAssertEqual(state.target, 18)
        XCTAssertTrue(state.scrubbing)
        state.release()
        XCTAssertFalse(state.scrubbing)
        XCTAssertEqual(state.target, 18)
    }

    func testExcessRepeatsAtEdgeDoNotBuildUpOnReversal() throws {
        var state = try XCTUnwrap(SpaceSwitchSelection(ordered: Array(1...18), current: 17))
        for _ in 0..<100 { state.press(1, repeated: true) }
        state.press(-1, repeated: false)
        XCTAssertEqual(state.target, 17)
        XCTAssertTrue(state.scrubbing, "Changing direction within a hold must not start real transit")
        for _ in 0..<100 { state.press(-1, repeated: true) }
        state.press(1, repeated: true)
        XCTAssertEqual(state.target, 2)
    }

    func testSelectionUsesSpaceIDsAndIncludesFullscreenPositions() throws {
        var state = try XCTUnwrap(SpaceSwitchSelection(ordered: [9, 41, 6, 99], current: 41))
        state.press(1, repeated: true)
        XCTAssertEqual(state.target, 6)
        state.press(-1, repeated: true)
        XCTAssertEqual(state.target, 41)
        XCTAssertNil(SpaceSwitchSelection(ordered: [], current: 1))
        XCTAssertNil(SpaceSwitchSelection(ordered: [9, 41], current: 1))
    }

    func testHoldKeepsTheChooserFromLandingUntilRelease() throws {
        var state = try XCTUnwrap(SpaceSwitchSelection(ordered: Array(1...16), current: 8))
        state.hold()
        XCTAssertTrue(state.scrubbing)
        state.press(1, repeated: false)
        XCTAssertTrue(state.scrubbing, "A tap inside the zoomed chooser must not start transit")
        XCTAssertEqual(state.target, 9)
        state.release()
        XCTAssertFalse(state.scrubbing)
    }
    func testChooserReleaseKeepsSelectionHeldUntilExplicitLanding() throws {
        var state = try XCTUnwrap(SpaceSwitchSelection(ordered: [1, 5, 6, 7], current: 5))
        state.hold()
        state.choose(7)
        XCTAssertFalse(state.release(choosing: true))
        XCTAssertTrue(state.scrubbing)
        state.press(-1, repeated: false)
        XCTAssertEqual(state.target, 6)
        XCTAssertFalse(state.release(choosing: true))
        XCTAssertTrue(state.scrubbing)
        XCTAssertTrue(state.release(choosing: false))
        XCTAssertFalse(state.scrubbing)
        XCTAssertEqual(state.target, 6)
    }

}
