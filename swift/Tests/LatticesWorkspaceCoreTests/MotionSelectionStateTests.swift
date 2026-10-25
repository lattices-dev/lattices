import XCTest
import LatticesWorkspaceCore

final class MotionSelectionStateTests: XCTestCase {
    func testEmptySessionDoesNotNeedSurveyInitialization() {
        var state = MotionSelectionState()
        XCTAssertEqual(state.order(on: "main"), [])
        XCTAssertEqual(state.members(on: "main"), [])
        XCTAssertTrue(state.ordersByDisplay.isEmpty)

        XCTAssertTrue(state.toggle(7, on: "main"))
        XCTAssertEqual(state.order(on: "main"), [7])
        XCTAssertEqual(state.members(on: "main"), [7])
    }

    func testDeselectAndReselectAppendsAtTheEnd() {
        var state = MotionSelectionState()
        state.append([8, 3, 5], on: "main")

        XCTAssertFalse(state.toggle(3, on: "main"))
        XCTAssertEqual(state.order(on: "main"), [8, 5])
        XCTAssertTrue(state.toggle(3, on: "main"))
        XCTAssertEqual(state.order(on: "main"), [8, 5, 3])
    }

    func testDisplaySelectionsRemainIndependentWhenAlternatingInputs() {
        var state = MotionSelectionState()
        state.append([4, 1], on: "left")
        state.append([9, 2], on: "right")
        state.toggle(4, on: "left")
        state.toggle(6, on: "right")
        state.toggle(4, on: "left")

        XCTAssertEqual(state.order(on: "left"), [1, 4])
        XCTAssertEqual(state.order(on: "right"), [9, 2, 6])
        XCTAssertEqual(state.members(on: "left"), [1, 4])
        XCTAssertEqual(state.members(on: "right"), [9, 2, 6])
    }

    func testPartialClusterAppendsMissingMembersInClusterOrder() {
        var state = MotionSelectionState()
        state.append([9, 3], on: "main")

        let added = state.toggleGroup([1, 3, 2], on: "main")

        XCTAssertEqual(added, [1, 2], "Only new selections need AX preparation")
        XCTAssertEqual(state.order(on: "main"), [9, 3, 1, 2])
    }

    func testFullySelectedClusterRemovesOnlyItsMembers() {
        var state = MotionSelectionState()
        state.append([8, 2, 9, 1, 3], on: "main")

        XCTAssertEqual(state.toggleGroup([1, 2, 3], on: "main"), [])
        XCTAssertEqual(state.order(on: "main"), [8, 9])
        XCTAssertEqual(state.members(on: "main"), [8, 9])
    }

    func testRepeatedClusterToggleFillsThenClears() {
        var state = MotionSelectionState()
        state.toggle(9, on: "main")

        XCTAssertEqual(state.toggleGroup([3, 1, 2], on: "main"), [3, 1, 2])
        XCTAssertEqual(state.toggleGroup([3, 1, 2], on: "main"), [])
        XCTAssertEqual(state.order(on: "main"), [9])
    }

    func testSearchAndLayerAdditionsPreserveSlotsAndReturnOnlyNewIDs() {
        var state = MotionSelectionState()
        state.append([6, 2], on: "main")

        XCTAssertEqual(state.append([2, 4, 1], on: "main"), [4, 1])
        XCTAssertEqual(state.append([1, 8, 4, 7], on: "main"), [8, 7])
        XCTAssertEqual(state.order(on: "main"), [6, 2, 4, 1, 8, 7])
    }

    func testDuplicateInputsNeverCreateDuplicateSlotsOrEffects() {
        var state = MotionSelectionState()

        XCTAssertEqual(state.append([2, 2, 1, 2, 1], on: "main"), [2, 1])
        XCTAssertEqual(state.toggleGroup([1, 3, 3], on: "main"), [3])
        XCTAssertEqual(state.order(on: "main"), [2, 1, 3])
        XCTAssertEqual(state.toggleGroup([3, 3], on: "main"), [])
        XCTAssertEqual(state.order(on: "main"), [2, 1])
    }

    func testEmptyClusterLeavesSessionUntouched() {
        var state = MotionSelectionState()

        XCTAssertEqual(state.toggleGroup([], on: "main"), [])
        XCTAssertTrue(state.ordersByDisplay.isEmpty)
    }

    func testMemberRefreshPrunesMovedOrClosedWindowsWithoutReorderingSurvivors() {
        var state = MotionSelectionState()
        state.append([7, 2, 9, 1], on: "left")
        state.append([4, 5], on: "right")

        state.retainWindows([1, 7, 9, 20], on: "left")

        XCTAssertEqual(state.order(on: "left"), [7, 9, 1])
        XCTAssertEqual(state.ordersByDisplay["left"], [7, 9, 1])
        XCTAssertEqual(state.members(on: "left"), [1, 7, 9])
        XCTAssertEqual(state.order(on: "right"), [4, 5])
    }

    func testSurveyResetKeepsPicksOnRemainingDisplays() {
        var state = MotionSelectionState()
        state.append([3, 1], on: "left")
        state.append([8, 4], on: "right")
        state.append([9], on: "disconnected")

        state.retainDisplays(["left", "right", "new"])

        XCTAssertEqual(state.order(on: "left"), [3, 1])
        XCTAssertEqual(state.order(on: "right"), [8, 4])
        XCTAssertNil(state.ordersByDisplay["disconnected"])
        XCTAssertNil(state.ordersByDisplay["new"])
    }

    func testClearOnAnotherDisplayPreservesCurrentDisplaySelection() {
        var state = MotionSelectionState()
        state.append([3, 1], on: "active")
        state.append([9, 8], on: "other")

        state.clear(on: "other")

        XCTAssertEqual(state.order(on: "active"), [3, 1])
        XCTAssertEqual(state.members(on: "active"), [3, 1])
        XCTAssertEqual(state.order(on: "other"), [])
    }

    func testSwapRemovalOnAnotherDisplayPreservesOtherPicksAndOrder() {
        var state = MotionSelectionState()
        state.append([5, 3], on: "active")
        state.append([9, 2, 8, 1], on: "other")

        state.remove([9, 8], on: "other")

        XCTAssertEqual(state.order(on: "active"), [5, 3])
        XCTAssertEqual(state.order(on: "other"), [2, 1])
        state.remove([1], on: "unknown")
        XCTAssertNil(state.ordersByDisplay["unknown"])
    }

    func testPublishedOrdersAreValueSnapshots() {
        var state = MotionSelectionState()
        state.append([4, 1], on: "main")
        var snapshot = state.ordersByDisplay
        snapshot["main"]?.append(7)
        state.toggle(4, on: "main")

        XCTAssertEqual(snapshot["main"], [4, 1, 7])
        XCTAssertEqual(state.order(on: "main"), [1])
    }

    func testMixedKeyboardClusterSearchSwapAndRefreshKeepAllViewsInAgreement() {
        var state = MotionSelectionState()
        state.toggle(5, on: "main")
        state.toggle(2, on: "main")
        state.toggleGroup([2, 8, 1], on: "main")
        state.append([5, 3, 8, 7], on: "main")
        state.toggle(2, on: "main")
        state.toggle(2, on: "main")
        state.remove([8, 3], on: "main")
        state.retainWindows([1, 2, 5, 9], on: "main")

        let order = state.order(on: "main")
        XCTAssertEqual(order, [5, 1, 2])
        XCTAssertEqual(state.members(on: "main"), Set(order))
        XCTAssertEqual(state.ordersByDisplay["main"], order)
        XCTAssertEqual(order.firstIndex(of: 2).map { $0 + 1 }, 3)
    }
}
