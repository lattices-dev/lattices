import XCTest
@testable import Lattices

/// Pure unit tests for Lattices previous/next Space navigation.
///
/// Product path under test: resolve an adjacent Space ID, then switch via
/// SkyLight (`switchToSpace`) — mouse gestures (`space.previous` /
/// `space.next`), companion deck relative focus, etc.
///
/// These tests do **not** exercise macOS Mission Control Control+Left/Right
/// system shortcuts. Live SkyLight switches are intentionally out of scope
/// (would move the real desktop).
final class AdjacentSpaceTests: XCTestCase {

    func testLateDockLandingDoesNotDiscardTheRemainingBurst() {
        var time: TimeInterval = 0
        var current = 1
        // Replay a fast first landing followed by commits beyond the old
        // 250ms cutoff. Each confirmed step permits the next swipe.
        for target in 2...18 {
            let departure = current
            let landsAt = time + (target == 2 ? 0.02 : 0.45)
            current = WindowTiler.waitForSpaceChange(from: departure, read: {
                time >= landsAt ? target : departure
            }, now: { time }, pause: { time += 0.01 })
            XCTAssertEqual(current, target)
            XCTAssertLessThan(time - landsAt, 0.011)
        }
    }

    func testLandingPollWaitsForDockCommitsBeyondOneSecond() {
        for delay in [1.5, 2.9] {
            var time: TimeInterval = 0
            let landed = WindowTiler.waitForSpaceChange(from: 5, read: {
                time >= delay ? 6 : 5
            }, now: { time }, pause: { time += 0.01 })
            XCTAssertEqual(landed, 6, "Do not release the switch worker while its swipe can still land")
            XCTAssertGreaterThanOrEqual(time, delay)
            XCTAssertLessThan(time, delay + 0.011)
        }
    }

    func testLandingPollReturnsImmediatelyAndIgnoresUnreadableState() {
        var time: TimeInterval = 0
        var reads = 0
        let landed = WindowTiler.waitForSpaceChange(from: 5, read: {
            reads += 1
            return reads == 1 ? 0 : 6
        }, now: { time }, pause: { time += 0.01 })
        XCTAssertEqual(landed, 6)
        XCTAssertEqual(time, 0.01, accuracy: 0.0001)
        let immediate = WindowTiler.waitForSpaceChange(from: 5, read: { 6 },
            now: { time }, pause: { XCTFail("Already landed; must not sleep") })
        XCTAssertEqual(immediate, 6)
    }

    func testLandingPollBoundsANonResponsiveDock() {
        var time: TimeInterval = 0
        let result = WindowTiler.waitForSpaceChange(from: 5, read: { 5 },
            now: { time }, pause: { time += 0.01 })
        XCTAssertEqual(result, 5)
        XCTAssertGreaterThanOrEqual(time, 3)
        XCTAssertLessThan(time, 3.011)
    }

    // MARK: - Gesture / tiler adjacent target (space.previous / space.next)

    /// Same resolution used by mouse-gesture `space.previous` (−1) / `space.next` (+1).
    func testAdjacentSpaceMovesNextAndPrevious() {
        let spaces = [
            SpaceInfo(id: 10, index: 1, display: 0, isCurrent: true),
            SpaceInfo(id: 11, index: 2, display: 0, isCurrent: false),
            SpaceInfo(id: 12, index: 3, display: 0, isCurrent: false),
        ]

        XCTAssertEqual(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 11, offset: -1)?.id,
            10,
            "space.previous should target the prior Space id"
        )
        XCTAssertEqual(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 11, offset: 1)?.id,
            12,
            "space.next should target the following Space id"
        )
        XCTAssertEqual(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 10, offset: 1)?.id,
            11
        )
    }

    func testAdjacentSpaceBoundsReturnNil() {
        let spaces = [
            SpaceInfo(id: 10, index: 1, display: 0, isCurrent: true),
            SpaceInfo(id: 11, index: 2, display: 0, isCurrent: false),
        ]

        XCTAssertNil(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 10, offset: -1),
            "no previous Space on the first slot"
        )
        XCTAssertNil(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 11, offset: 1),
            "no next Space on the last slot"
        )
        XCTAssertNil(WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 99, offset: 1))
        XCTAssertNil(WindowTiler.adjacentSpace(in: [], currentSpaceId: 10, offset: 1))
    }

    func testAdjacentSpaceOffsetZeroReturnsCurrent() {
        let spaces = [
            SpaceInfo(id: 10, index: 1, display: 0, isCurrent: false),
            SpaceInfo(id: 11, index: 2, display: 0, isCurrent: true),
        ]
        XCTAssertEqual(
            WindowTiler.adjacentSpace(in: spaces, currentSpaceId: 11, offset: 0)?.id,
            11
        )
    }

    // MARK: - Companion deck relative focus (spaces.focusRelative)

    func testRelativeSpaceTargetDirection() {
        let display = DisplaySpaces(
            displayIndex: 0,
            displayId: "main",
            spaces: [
                SpaceInfo(id: 10, index: 1, display: 0, isCurrent: false),
                SpaceInfo(id: 11, index: 2, display: 0, isCurrent: true),
                SpaceInfo(id: 12, index: 3, display: 0, isCurrent: false),
            ],
            currentSpaceId: 11
        )

        XCTAssertEqual(display.relativeSpace(direction: -1)?.id, 10)
        XCTAssertEqual(display.relativeSpace(direction: 1)?.id, 12)
        XCTAssertNil(display.relativeSpace(direction: 2))
    }

    func testRelativeSpaceTargetAtEnds() {
        let firstCurrent = DisplaySpaces(
            displayIndex: 0,
            displayId: "main",
            spaces: [
                SpaceInfo(id: 10, index: 1, display: 0, isCurrent: true),
                SpaceInfo(id: 11, index: 2, display: 0, isCurrent: false),
            ],
            currentSpaceId: 10
        )
        XCTAssertNil(firstCurrent.relativeSpace(direction: -1))
        XCTAssertEqual(firstCurrent.relativeSpace(direction: 1)?.id, 11)

        let lastCurrent = DisplaySpaces(
            displayIndex: 0,
            displayId: "main",
            spaces: [
                SpaceInfo(id: 10, index: 1, display: 0, isCurrent: false),
                SpaceInfo(id: 11, index: 2, display: 0, isCurrent: true),
            ],
            currentSpaceId: 11
        )
        XCTAssertNil(lastCurrent.relativeSpace(direction: 1))
        XCTAssertEqual(lastCurrent.relativeSpace(direction: -1)?.id, 10)
    }
    // MARK: - Mouse gesture defaults → Lattices actions

    func testDefaultMouseShortcutsWireSpacePreviousAndNextActions() {
        let rules = MouseShortcutConfig.defaults.rules
        let previous = rules.first { $0.id == "space-previous" }
        let next = rules.first { $0.id == "space-next" }

        XCTAssertNotNil(previous)
        XCTAssertNotNil(next)
        XCTAssertEqual(previous?.enabled, true)
        XCTAssertEqual(next?.enabled, true)
        // Action types drive WindowTiler.switchToAdjacentSpace — not OS shortcuts.
        XCTAssertEqual(previous?.action.type, .spacePrevious)
        XCTAssertEqual(next?.action.type, .spaceNext)
        XCTAssertEqual(MouseShortcutActionType.spacePrevious.rawValue, "space.previous")
        XCTAssertEqual(MouseShortcutActionType.spaceNext.rawValue, "space.next")
        XCTAssertEqual(previous?.trigger.button, .middle)
        XCTAssertEqual(next?.trigger.button, .middle)
        XCTAssertEqual(previous?.trigger.kind, .drag)
        XCTAssertEqual(next?.trigger.kind, .drag)
        XCTAssertEqual(previous?.trigger.direction, .left)
        XCTAssertEqual(next?.trigger.direction, .right)
    }

    // MARK: - Ctrl+arrow stepping through Mission Control order

    /// Fullscreen app Spaces (here 20) sit between desktops and are real
    /// steps — a Ctrl+→ from desktop 10 lands on the fullscreen app.
    func testAdjacentSpaceIdIncludesFullscreenSpaces() {
        let ordered = [10, 20, 11]
        XCTAssertEqual(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 10, offset: 1), 20)
        XCTAssertEqual(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 20, offset: 1), 11)
        XCTAssertEqual(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 20, offset: -1), 10)
    }

    /// Merged presses clamp at the ends instead of failing outright.
    func testAdjacentSpaceIdClampsMergedOffsets() {
        let ordered = [10, 11, 12]
        XCTAssertEqual(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 11, offset: 5), 12)
        XCTAssertEqual(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 11, offset: -5), 10)
    }

    func testAdjacentSpaceIdReportsEdgeAndUnknown() {
        let ordered = [10, 11]
        XCTAssertNil(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 11, offset: 1))
        XCTAssertNil(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 10, offset: -1))
        XCTAssertNil(WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: 99, offset: 1))
        XCTAssertNil(WindowTiler.adjacentSpaceId(in: [], currentSpaceId: 10, offset: 1))
    }
    /// Regression: the old eight-attempt loop stranded a merged 17-key
    /// burst on desktop 10 even though its planned destination was 18.
    func testLongMergedBurstHasEnoughAttemptsInBothDirections() {
        let ordered = Array(1...18)
        for (start, offset, expected) in [(1, 17, 18), (18, -17, 1)] {
            let target = WindowTiler.adjacentSpaceId(in: ordered, currentSpaceId: start, offset: offset)
            XCTAssertEqual(target, expected)
            var current = start
            for _ in 0..<WindowTiler.spaceSwitchAttemptLimit(distance: offset) {
                if current == target { break }
                current += offset > 0 ? 1 : -1
            }
            XCTAssertEqual(current, target, "A long burst must not stop halfway")
        }
    }

}
