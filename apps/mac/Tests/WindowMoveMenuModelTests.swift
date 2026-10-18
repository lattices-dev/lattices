import XCTest
@testable import Lattices

/// Pure-model coverage for the shared right-click movement menu used by
/// Desktop Inventory and Studio: display cycling/wrap, current-display
/// handling, display-specific desktop destinations, multi-selection titles
/// and targeting, and truthful receipt summaries.
final class WindowMoveMenuModelTests: XCTestCase {
    private func display(
        _ index: Int,
        name: String? = nil,
        current: Bool = false,
        desktops: [WindowMoveMenuModel.Desktop] = []
    ) -> WindowMoveMenuModel.Display {
        WindowMoveMenuModel.Display(
            index: index,
            name: name ?? "Display \(index + 1)",
            isCurrent: current,
            desktops: desktops
        )
    }

    private func desktop(
        displayIndex: Int,
        displayName: String,
        spaceId: Int,
        number: Int,
        current: Bool = false,
        showing: Bool = false
    ) -> WindowMoveMenuModel.Desktop {
        WindowMoveMenuModel.Desktop(
            displayIndex: displayIndex,
            displayName: displayName,
            spaceId: spaceId,
            number: number,
            isCurrent: current,
            isShowing: showing
        )
    }

    private func target(_ wid: UInt32) -> WindowMoveMenuModel.Target {
        WindowMoveMenuModel.Target(wid: wid, pid: Int32(wid) + 1000)
    }

    // MARK: - Availability

    func testSingleDisplayHidesMovement() {
        let model = WindowMoveMenuModel(displays: [display(0, current: true)], targets: [target(1)])
        XCTAssertFalse(model.isAvailable)
        XCTAssertNil(model.nextDisplay)
        XCTAssertFalse(model.includesPlacement)
    }

    func testNoTargetsHidesMovement() {
        let model = WindowMoveMenuModel(displays: [display(0, current: true), display(1)], targets: [])
        XCTAssertFalse(model.isAvailable)
        XCTAssertNil(model.nextDisplay)
    }

    func testTwoDisplaysShowMovement() {
        let model = WindowMoveMenuModel(displays: [display(0, current: true), display(1)], targets: [target(1)])
        XCTAssertTrue(model.isAvailable)
        XCTAssertTrue(model.includesPlacement)
    }

    func testSingleDisplayStillOffersDesktopDestinations() {
        let desktops = [
            desktop(displayIndex: 0, displayName: "DELL", spaceId: 1, number: 1, current: true, showing: true),
            desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2),
        ]
        let model = WindowMoveMenuModel(
            displays: [display(0, name: "DELL", current: true, desktops: desktops)],
            targets: [target(1)]
        )

        XCTAssertTrue(model.isAvailable)
        XCTAssertNil(model.nextDisplay)
        XCTAssertFalse(model.includesPlacement)
        XCTAssertFalse(model.isDisabled(desktops[1]))
    }

    func testDesktopDestinationsRequireAWindowTarget() {
        let destination = desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2)
        let model = WindowMoveMenuModel(
            displays: [display(0, name: "DELL", desktops: [destination])],
            targets: [],
            here: destination
        )

        XCTAssertFalse(model.isAvailable)
        XCTAssertNil(model.nextDisplay)
        XCTAssertFalse(model.includesPlacement)
    }

    // MARK: - Display-specific desktop destinations

    func testMatchingDesktopNumbersRemainDistinctAcrossDisplays() {
        // Desktop 2 on the physical display must retain Space 3, even when
        // the clicked window belongs to the virtual display's Desktop 2.
        let physical = desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2, showing: true)
        let virtual = desktop(
            displayIndex: 2,
            displayName: "Action Agent Layer",
            spaceId: 1956,
            number: 2,
            current: true
        )
        let model = WindowMoveMenuModel(
            displays: [
                display(0, name: "DELL", desktops: [physical]),
                display(2, name: "Action Agent Layer", current: true, desktops: [virtual]),
            ],
            targets: [target(1)]
        )

        XCTAssertEqual(model.displays[0].desktops[0].title, "DELL · Desktop 2")
        XCTAssertEqual(model.displays[1].desktops[0].title, "Action Agent Layer · Desktop 2")
        XCTAssertEqual(model.displays[0].desktops[0].spaceId, 3)
        XCTAssertEqual(model.displays[1].desktops[0].spaceId, 1956)
        XCTAssertNotEqual(physical, virtual)
        XCTAssertFalse(model.isDisabled(physical))
        XCTAssertTrue(model.isDisabled(virtual))
    }

    func testShowingDesktopIsSelectableWhenWindowIsOnAnInactiveDesktop() {
        let source = desktop(
            displayIndex: 2,
            displayName: "Action Agent Layer",
            spaceId: 1956,
            number: 2,
            current: true
        )
        let showing = desktop(
            displayIndex: 2,
            displayName: "Action Agent Layer",
            spaceId: 2377,
            number: 4,
            showing: true
        )
        let model = WindowMoveMenuModel(
            displays: [display(2, name: "Action Agent Layer", current: true, desktops: [source, showing])],
            targets: [target(1)]
        )

        XCTAssertTrue(model.isDisabled(source))
        XCTAssertFalse(model.isDisabled(showing))
    }

    func testCurrentDesktopDisabledOnlyForSingleTarget() {
        let current = desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2, current: true)
        let other = desktop(displayIndex: 0, displayName: "DELL", spaceId: 1, number: 1)
        let displays = [display(0, name: "DELL", current: true, desktops: [current, other])]
        let single = WindowMoveMenuModel(displays: displays, targets: [target(1)])
        let multi = WindowMoveMenuModel(displays: displays, targets: [target(1), target(2)])

        XCTAssertTrue(single.isDisabled(current))
        XCTAssertFalse(single.isDisabled(other))
        XCTAssertFalse(multi.isDisabled(current))
        XCTAssertFalse(multi.isDisabled(other))
    }

    func testAssignedAppCannotChooseRefusedDesktopOrBringHere() {
        var refused = desktop(displayIndex: 0, displayName: "DELL", spaceId: 1, number: 1, showing: true)
        refused.isRefused = true
        let assigned = desktop(displayIndex: 0, displayName: "DELL", spaceId: 6, number: 3)
        let otherDisplay = desktop(displayIndex: 1, displayName: "U32", spaceId: 46, number: 1)
        let model = WindowMoveMenuModel(displays: [
            display(0, desktops: [refused, assigned]), display(1, desktops: [otherDisplay])
        ], targets: [target(1)], here: refused)
        XCTAssertTrue(model.isDisabled(refused))
        XCTAssertTrue(model.isDisabled(model.here!))
        XCTAssertFalse(model.isDisabled(assigned))
        XCTAssertFalse(model.isDisabled(otherDisplay))
    }

    func testBringHereUsesTheInterfaceDisplayInsteadOfTheWindowDisplay() {
        let destination = desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2, showing: true)
        let source = desktop(
            displayIndex: 2,
            displayName: "Action Agent Layer",
            spaceId: 2377,
            number: 4,
            current: true
        )
        let model = WindowMoveMenuModel(
            displays: [
                display(0, name: "DELL", desktops: [destination]),
                display(2, name: "Action Agent Layer", current: true, desktops: [source]),
            ],
            targets: [target(1)],
            here: destination
        )

        XCTAssertEqual(model.currentDisplay?.index, 2)
        XCTAssertEqual(model.here?.displayIndex, 0)
        XCTAssertEqual(model.here?.spaceId, 3)
        XCTAssertEqual(model.bringHereTitle, "Bring Here — DELL · Desktop 2")
    }

    func testBringHereTitleCountsSelectedWindows() {
        let destination = desktop(displayIndex: 0, displayName: "DELL", spaceId: 3, number: 2, showing: true)
        let model = WindowMoveMenuModel(
            displays: [display(0, name: "DELL", desktops: [destination])],
            targets: [target(1), target(2), target(3)],
            here: destination
        )

        XCTAssertEqual(model.bringHereTitle, "Bring 3 Windows Here — DELL · Desktop 2")
    }

    // MARK: - Next-display cycling

    func testNextDisplayStepsThroughTopology() {
        let model = WindowMoveMenuModel(
            displays: [display(0), display(1, current: true), display(2)],
            targets: [target(1)]
        )
        XCTAssertEqual(model.nextDisplay?.index, 2)
    }

    func testNextDisplayWrapsFromLastToFirst() {
        let model = WindowMoveMenuModel(
            displays: [display(0), display(1), display(2, current: true)],
            targets: [target(1)]
        )
        XCTAssertEqual(model.nextDisplay?.index, 0)
    }

    func testNextDisplayFallsBackToFirstWhenAnchorUnresolved() {
        // No display is marked current (anchor could not be resolved) —
        // cycling still yields a deterministic target.
        let model = WindowMoveMenuModel(displays: [display(0), display(1)], targets: [target(1)])
        XCTAssertEqual(model.nextDisplay?.index, 0)
    }

    func testCurrentDisplayIsMarked() {
        let model = WindowMoveMenuModel(
            displays: [display(0), display(1, current: true)],
            targets: [target(1)]
        )
        XCTAssertEqual(model.currentDisplay?.index, 1)
    }

    // MARK: - Titles

    func testSingleWindowTitles() {
        let model = WindowMoveMenuModel(displays: [display(0, current: true), display(1)], targets: [target(1)])
        XCTAssertEqual(model.nextMonitorTitle, "Move to Next Monitor")
        XCTAssertEqual(model.moveToMonitorTitle, "Move to Monitor")
    }

    func testMultiWindowTitlesCountTargets() {
        let model = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1)],
            targets: [target(1), target(2), target(3)]
        )
        XCTAssertEqual(model.nextMonitorTitle, "Move 3 Windows to Next Monitor")
        XCTAssertEqual(model.moveToMonitorTitle, "Move 3 Windows to Monitor")
    }

    // MARK: - Placement gating

    func testMultiSelectionOmitsPlacement() {
        // Several windows sent to one slot would overlap; Move & Place must
        // disappear for multi-target menus.
        let model = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1)],
            targets: [target(1), target(2)]
        )
        XCTAssertTrue(model.isAvailable)
        XCTAssertFalse(model.includesPlacement)
    }

    func testCurrentDisplayDisabledOnlyForSingleTarget() {
        // Single window: its own display is not a meaningful target.
        let single = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1)],
            targets: [target(1)]
        )
        XCTAssertTrue(single.isDisabled(single.displays[0]))
        XCTAssertFalse(single.isDisabled(single.displays[1]))

        // Multi-selection may span monitors — the anchor display must stay
        // selectable so the whole selection can gather onto it.
        let multi = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1)],
            targets: [target(1), target(2)]
        )
        XCTAssertFalse(multi.isDisabled(multi.displays[0]))
        XCTAssertFalse(multi.isDisabled(multi.displays[1]))
    }

    func testPlacementSlotsCoverCanonicalNamedPositions() {
        let slots = WindowMoveMenuModel.placementSlots
        XCTAssertTrue(slots.contains(.maximize))
        XCTAssertTrue(slots.contains(.center))
        for half: TilePosition in [.left, .right, .top, .bottom] {
            XCTAssertTrue(slots.contains(half))
        }
        for quarter: TilePosition in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
            XCTAssertTrue(slots.contains(quarter))
        }
        for third: TilePosition in [.leftThird, .centerThird, .rightThird] {
            XCTAssertTrue(slots.contains(third))
        }
    }

    // MARK: - Right-click target rule

    func testClickOutsideSelectionTargetsClickedWindowOnly() {
        let clicked = target(9)
        let selection = [target(1), target(2)]
        XCTAssertEqual(WindowMoveMenuModel.resolveTargets(clicked: clicked, selection: selection), [clicked])
    }

    func testClickInsideMultiSelectionTargetsWholeSelection() {
        let selection = [target(1), target(2), target(3)]
        XCTAssertEqual(
            WindowMoveMenuModel.resolveTargets(clicked: target(2), selection: selection),
            selection
        )
    }

    func testClickOnSoleSelectedWindowTargetsItAlone() {
        let clicked = target(1)
        XCTAssertEqual(WindowMoveMenuModel.resolveTargets(clicked: clicked, selection: [clicked]), [clicked])
    }

    // MARK: - Accessibility labels

    func testAccessibilityLabelsNameActionAndTarget() {
        let model = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1, name: "Studio Display")],
            targets: [target(1), target(2)]
        )
        XCTAssertEqual(
            model.moveAccessibilityLabel(to: model.displays[1]),
            "Move 2 windows to Studio Display"
        )
    }

    func testSingleWindowAccessibilityLabelNamesTargetDisplay() {
        let model = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1, name: "Studio Display")],
            targets: [target(1)]
        )
        XCTAssertEqual(
            model.moveAccessibilityLabel(to: model.displays[1]),
            "Move window to Studio Display"
        )
    }

    func testPlacementAccessibilityLabelNamesSlotAndDisplay() {
        let model = WindowMoveMenuModel(
            displays: [display(0, current: true), display(1, name: "Studio Display")],
            targets: [target(1)]
        )
        let label = model.placeAccessibilityLabel(slot: .bottomRight, on: model.displays[1])
        XCTAssertEqual(label, "Move window to Studio Display and place \(TilePosition.bottomRight.label)")
    }

    func testRuntimeReceiptRequiresVerifiedSuccess() {
        XCTAssertNil(WindowMovementService.failureMessage(for: .object([
            "status": .string("ok"), "verified": .bool(true),
        ])))
        XCTAssertNotNil(WindowMovementService.failureMessage(for: .object([
            "status": .string("ok"), "verified": .bool(false),
        ])))
        XCTAssertNotNil(WindowMovementService.failureMessage(for: .object([
            "status": .string("failed"), "verified": .bool(true),
        ])))
    }

    func testRuntimeFailureReasonRemainsVisible() {
        XCTAssertEqual(WindowMovementService.failureMessage(for: .object([
            "status": .string("failed"), "verified": .bool(false),
            "failureReason": .string("Window stayed on Action Agent Layer; rollback verified"),
        ])), "Window stayed on Action Agent Layer; rollback verified")
        XCTAssertEqual(WindowMovementService.failureMessage(for: .object([
            "status": .string("blocked"), "blockedReason": .string("Accessibility is disabled"),
        ])), "Accessibility is disabled")
    }

    func testAssignedDesktopBlockShowsActionableMessage() {
        let message = "Chrome is assigned to Desktop 3 on DELL in macOS"
        XCTAssertEqual(WindowMovementService.failureMessage(for: .object([
            "status": .string("blocked"), "blockedReason": .string("app-assigned-desktop"),
            "message": .string(message), "assignedSpaceId": .int(6), "verified": .bool(false),
        ])), message)
    }

    // MARK: - Truthful receipts

    func testMoveOutcomeFullSuccess() {
        let single = WindowMovementService.moveOutcome(okWids: [11], total: 1, blocked: false, displayName: "DELL U2720Q")
        XCTAssertTrue(single.ok)
        XCTAssertEqual(single.message, "Moved to DELL U2720Q")
        XCTAssertEqual(single.movedWids, [11])

        let multi = WindowMovementService.moveOutcome(okWids: [1, 2, 3], total: 3, blocked: false, displayName: "DELL U2720Q")
        XCTAssertTrue(multi.ok)
        XCTAssertEqual(multi.message, "Moved 3 windows to DELL U2720Q")
        XCTAssertEqual(multi.movedWids, [1, 2, 3])
    }

    func testMoveOutcomeBlockedIsNotSuccess() {
        let outcome = WindowMovementService.moveOutcome(okWids: [], total: 1, blocked: true, displayName: "DELL")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("Accessibility"))
        XCTAssertTrue(outcome.movedWids.isEmpty)
    }

    func testMoveOutcomePartialCarriesOnlySuccessfulWids() {
        let outcome = WindowMovementService.moveOutcome(okWids: [7], total: 3, blocked: false, displayName: "DELL")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("1/3"))
        XCTAssertEqual(outcome.movedWids, [7])
    }

    func testMoveOutcomeUnverifiedIsNotReportedAsMovedAndCarriesNoWids() {
        let outcome = WindowMovementService.moveOutcome(okWids: [], total: 1, blocked: false, displayName: "DELL")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("not verified"))
        XCTAssertTrue(outcome.movedWids.isEmpty)
    }
}
