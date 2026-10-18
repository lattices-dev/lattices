import AppKit
import XCTest
@testable import Lattices

final class MouseGestureSpaceMoveTests: XCTestCase {
    func testShiftConvertsOnlyDesktopActions() {
        XCTAssertEqual(MouseGestureSpaceMove.offset(for: .spaceNext, flags: .maskShift), 1)
        XCTAssertEqual(MouseGestureSpaceMove.offset(for: .spacePrevious, flags: .maskShift), -1)
        for action in [MouseShortcutActionType.spaceNext, .spacePrevious, .screenMapToggle, .dictationStart, .shortcutSend, .appActivate] {
            XCTAssertNil(MouseGestureSpaceMove.offset(for: action, flags: []))
            XCTAssertNil(MouseGestureSpaceMove.offset(for: action, flags: .maskControl))
        }
        for action in [MouseShortcutActionType.screenMapToggle, .dictationStart, .shortcutSend, .appActivate] {
            XCTAssertNil(MouseGestureSpaceMove.offset(for: action, flags: .maskShift))
        }
    }

    func testDestinationUsesWindowDesktopOrderAndDoesNotWrap() {
        let desktops = [9, 3, 12]
        XCTAssertEqual(MouseGestureSpaceMove.destination(in: desktops, sourceSpaces: [3], offset: 1), 12)
        XCTAssertEqual(MouseGestureSpaceMove.destination(in: desktops, sourceSpaces: [3], offset: -1), 9)
        XCTAssertNil(MouseGestureSpaceMove.destination(in: desktops, sourceSpaces: [9], offset: -1))
        XCTAssertNil(MouseGestureSpaceMove.destination(in: desktops, sourceSpaces: [12], offset: 1))
    }

    func testRejectsFullscreenMissingAndAllDesktopWindows() {
        for source in [[], [7], [9, 3]] {
            XCTAssertNil(MouseGestureSpaceMove.destination(in: [9, 3, 12], sourceSpaces: source, offset: 1))
        }
        XCTAssertNil(MouseGestureSpaceMove.destination(in: [], sourceSpaces: [9], offset: 1))
    }

    func testShiftHUDMatchesCustomDesktopMappingsAndLeavesOtherActionsAlone() {
        let rules = [
            MouseShortcutRule(id: "custom", enabled: true, device: .any,
                trigger: .init(button: .button4, kind: .shape, direction: nil, shape: .circle),
                action: .init(type: .spaceNext)),
            MouseShortcutRule(id: "dictation", enabled: true, device: .any,
                trigger: .init(button: .button4, kind: .drag, direction: .up, shape: nil),
                action: .init(type: .dictationStart)),
        ]
        let shifted = MouseGestureInkMenu.build(rules: rules, button: .button4, device: nil, threshold: 68, flags: .maskShift)
        XCTAssertEqual(shifted.shapes[.circle]?.title, "Move window to next desktop")
        XCTAssertEqual(shifted.drags[.up]?.title, "Dictate")
        let normal = MouseGestureInkMenu.build(rules: rules, button: .button4, device: nil, threshold: 68)
        XCTAssertEqual(normal.shapes[.circle]?.title, "Next desktop")
    }
}
