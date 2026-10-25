import XCTest
import AppKit
@testable import Lattices

final class RemoteKeyboardTests: XCTestCase {
    func testResizeKeysKeepTheirPhysicalPositionsWhenShifted() {
        XCTAssertEqual(RemoteKeyboard.evdev[24], 13) // = and + -> XKB code 21
        XCTAssertEqual(RemoteKeyboard.evdev[27], 12) // - and _ -> XKB code 20
        XCTAssertEqual(RemoteKeyboard.evdev[55], 125) // Command -> left Super
        XCTAssertEqual(RemoteKeyboard.evdev[59], 29) // Control stays Control
        XCTAssertEqual(RemoteKeyboard.evdev[60], 54) // Right Shift stays distinct
    }

    func testReleaseChordDoesNotStealPlainEscapeOrOtherShortcuts() {
        XCTAssertTrue(RemoteKeyboard.isRelease(keyCode: 53, flags: [.maskControl, .maskAlternate]))
        XCTAssertFalse(RemoteKeyboard.isRelease(keyCode: 53, flags: []))
        XCTAssertFalse(RemoteKeyboard.isRelease(keyCode: 53, flags: [.maskCommand]))
        XCTAssertFalse(RemoteKeyboard.isRelease(keyCode: 24, flags: [.maskControl, .maskAlternate]))
    }

    func testFullScreenShortcutRequiresExactlyControlCommandF() {
        XCTAssertTrue(RemoteKeyboard.isFullScreen(keyCode: 3, flags: [.maskControl, .maskCommand]))
        XCTAssertTrue(RemoteKeyboard.isFullScreen(keyCode: 3, flags: [.maskControl, .maskCommand, .maskAlphaShift]))
        XCTAssertFalse(RemoteKeyboard.isFullScreen(keyCode: 3, flags: [.maskCommand]))
        XCTAssertFalse(RemoteKeyboard.isFullScreen(keyCode: 3, flags: [.maskControl, .maskCommand, .maskShift]))
        XCTAssertFalse(RemoteKeyboard.isFullScreen(keyCode: 53, flags: []))
    }

    func testCloseShortcutRequiresExactlyCommandW() {
        XCTAssertTrue(RemoteKeyboard.isClose(keyCode: 13, flags: [.maskCommand]))
        XCTAssertTrue(RemoteKeyboard.isClose(keyCode: 13, flags: [.maskCommand, .maskAlphaShift]))
        XCTAssertFalse(RemoteKeyboard.isClose(keyCode: 13, flags: []))
        XCTAssertFalse(RemoteKeyboard.isClose(keyCode: 13, flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(RemoteKeyboard.isClose(keyCode: 13, flags: [.maskCommand, .maskControl]))
        XCTAssertFalse(RemoteKeyboard.isClose(keyCode: 13, flags: [.maskCommand, .maskAlternate]))
        XCTAssertFalse(RemoteKeyboard.isClose(keyCode: 3, flags: [.maskCommand]))
    }

    @MainActor
    func testSuspendReleasesRemoteKeysAndIgnoresModifierHeldAcrossResume() throws {
        let capture = RemoteKeyboardCapture()
        capture.active = { true }
        var keys: [String] = []
        capture.key = { code, down in keys.append("\(code):\(down)") }
        let control = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true))
        control.flags = [.maskControl]
        _ = capture.receive(.flagsChanged, control)
        capture.suspend()
        XCTAssertEqual(keys, ["29:true", "29:false"])

        capture.prepareForCapture(keysAlreadyDown: [59])
        control.flags = []
        _ = capture.receive(.flagsChanged, control)
        XCTAssertEqual(keys, ["29:true", "29:false"], "Releasing the locally held Control must not press it remotely")
        control.flags = [.maskControl]
        _ = capture.receive(.flagsChanged, control)
        control.flags = []
        _ = capture.receive(.flagsChanged, control)
        XCTAssertEqual(keys.suffix(2), ["29:true", "29:false"])
    }

    @MainActor
    func testLocalFullScreenReleasesHeldKeysBeforeTogglingAndDoesNotForwardF() throws {
        let capture = RemoteKeyboardCapture()
        capture.active = { true }
        var actions: [String] = []
        capture.key = { code, down in actions.append("\(code):\(down)") }
        capture.toggleFullScreen = { actions.append("fullscreen") }
        let command = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true))
        command.flags = [.maskCommand]
        _ = capture.receive(.flagsChanged, command)
        let shortcut = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true))
        shortcut.flags = [.maskControl, .maskCommand]
        _ = capture.receive(.keyDown, shortcut)
        XCTAssertEqual(actions, ["125:true", "125:false", "fullscreen"])
        shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        _ = capture.receive(.keyDown, shortcut)
        XCTAssertEqual(actions.count, 3, "Holding the local shortcut must not repeatedly toggle fullscreen")
    }

    @MainActor
    func testLocalCloseReleasesHeldKeysBeforeClosingAndDoesNotForwardW() throws {
        let capture = RemoteKeyboardCapture()
        capture.active = { true }
        var actions: [String] = []
        capture.key = { code, down in actions.append("\(code):\(down)") }
        capture.closeWindow = { actions.append("close") }
        let command = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true))
        command.flags = [.maskCommand]
        _ = capture.receive(.flagsChanged, command)
        let shortcut = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true))
        shortcut.flags = [.maskCommand]
        XCTAssertNil(capture.receive(.keyDown, shortcut))
        XCTAssertEqual(actions, ["125:true", "125:false", "close"])
        shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(capture.receive(.keyDown, shortcut))
        XCTAssertEqual(actions.count, 3, "Holding the local shortcut must not close another window")
    }

    @MainActor
    func testCommandWRemainsRemoteWithoutALocalCloseHandler() throws {
        let capture = RemoteKeyboardCapture()
        capture.active = { true }
        var keys: [String] = []
        capture.key = { code, down in keys.append("\(code):\(down)") }
        let shortcut = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true))
        shortcut.flags = [.maskCommand]
        _ = capture.receive(.keyDown, shortcut)
        _ = capture.receive(.keyUp, shortcut)
        XCTAssertEqual(keys, ["17:true", "17:false"])
    }
}
