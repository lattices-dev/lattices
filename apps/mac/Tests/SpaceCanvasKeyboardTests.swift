import XCTest
@testable import Lattices

final class SpaceCanvasKeyboardTests: XCTestCase {
    func testOwnsPlainNavigationWithoutTakingWindowFocus() {
        _ = NSApplication.shared
        let panel = SpaceCanvasPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        let keyboard = SpaceCanvasKeyboard(enqueue: { $0() })
        var events: [String] = []
        keyboard.begin { events.append("\($0):\($1):\($2)") }
        XCTAssertTrue(keyboard.handle(key: 124, pressed: true, repeated: false, flags: [.maskSecondaryFn, .maskNumericPad]))
        XCTAssertTrue(keyboard.handle(key: 124, pressed: true, repeated: true, flags: []))
        XCTAssertTrue(keyboard.handle(key: 124, pressed: false, repeated: false, flags: []))
        XCTAssertEqual(events, ["124:true:false", "124:true:true", "124:false:false"])
    }

    func testHyperTransportPassesThroughTheVisibleChooser() {
        let keyboard = SpaceCanvasKeyboard(enqueue: { $0() })
        keyboard.begin { _, _, _ in XCTFail("Hyper transport belongs to the remapper") }
        for key: Int64 in [57, CapsLockHIDTransportController.transportKeyCode] {
            XCTAssertFalse(keyboard.handle(key: key, pressed: true, repeated: false, flags: []))
            XCTAssertFalse(keyboard.handle(key: key, pressed: true, repeated: true, flags: []))
            XCTAssertFalse(keyboard.handle(key: key, pressed: false, repeated: false, flags: []))
        }
    }

    func testRawHyperChordPassesBeforeRemapperAddsModifierFlags() {
        let keyboard = SpaceCanvasKeyboard(enqueue: { $0() })
        var delivered: [Int64] = []
        keyboard.begin { key, _, _ in delivered.append(key) }
        XCTAssertFalse(keyboard.handle(key: 79, pressed: true, repeated: false, flags: []))
        XCTAssertFalse(keyboard.handle(key: 5, pressed: true, repeated: false, flags: []))
        XCTAssertFalse(keyboard.handle(key: 5, pressed: false, repeated: false, flags: []))
        XCTAssertFalse(keyboard.handle(key: 79, pressed: false, repeated: false, flags: []))
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(keyboard.handle(key: 124, pressed: true, repeated: false, flags: []))
        XCTAssertEqual(delivered, [124])
    }

    func testDoesNotTakeExistingControlOrApplicationShortcuts() {
        let keyboard = SpaceCanvasKeyboard(enqueue: { $0() })
        keyboard.begin { _, _, _ in XCTFail("Modified chords keep their existing routing") }
        for flags: CGEventFlags in [.maskControl, .maskCommand, .maskAlternate, [.maskControl, .maskShift]] {
            XCTAssertFalse(keyboard.handle(key: 124, pressed: true, repeated: false, flags: flags))
            XCTAssertFalse(keyboard.handle(key: 124, pressed: false, repeated: false, flags: flags))
        }
    }

    func testClosingKeepsPressTailButNeverDeliversToReplacementCanvas() {
        var queued: [() -> Void] = []
        let keyboard = SpaceCanvasKeyboard(enqueue: { queued.append($0) })
        keyboard.begin { _, _, _ in XCTFail("Closed before dispatch") }
        XCTAssertTrue(keyboard.handle(key: 126, pressed: true, repeated: false, flags: []))
        keyboard.end()
        var delivered: [Int64] = []
        keyboard.begin { key, _, _ in delivered.append(key) }
        XCTAssertTrue(keyboard.handle(key: 126, pressed: true, repeated: true, flags: .maskControl))
        XCTAssertTrue(keyboard.handle(key: 126, pressed: false, repeated: false, flags: []))
        queued.forEach { $0() }
        XCTAssertTrue(delivered.isEmpty, "Old press and key-up cannot drive the new canvas")
        queued.removeAll()
        XCTAssertTrue(keyboard.handle(key: 126, pressed: true, repeated: false, flags: []))
        queued.forEach { $0() }
        XCTAssertEqual(delivered, [126])
    }

    func testPlainTypingCannotLeakThroughVisibleChooserButEndsWithSession() {
        let keyboard = SpaceCanvasKeyboard(enqueue: { $0() })
        XCTAssertFalse(keyboard.handle(key: 0, pressed: true, repeated: false, flags: []))
        keyboard.begin { _, _, _ in }
        XCTAssertTrue(keyboard.handle(key: 0, pressed: true, repeated: false, flags: []))
        keyboard.end()
        XCTAssertTrue(keyboard.handle(key: 0, pressed: true, repeated: true, flags: []))
        XCTAssertTrue(keyboard.handle(key: 0, pressed: false, repeated: false, flags: []))
        XCTAssertFalse(keyboard.handle(key: 0, pressed: true, repeated: false, flags: []))
    }

    func testUnownedRepeatAndKeyUpPassThroughAndTeardownInvalidatesDispatch() {
        var queued: [() -> Void] = []
        let keyboard = SpaceCanvasKeyboard(enqueue: { queued.append($0) })
        keyboard.begin { _, _, _ in XCTFail("Tap removed before dispatch") }
        XCTAssertFalse(keyboard.handle(key: 53, pressed: false, repeated: false, flags: []))
        XCTAssertFalse(keyboard.handle(key: 53, pressed: true, repeated: true, flags: []))
        XCTAssertTrue(keyboard.handle(key: 53, pressed: true, repeated: false, flags: []))
        keyboard.reset()
        queued.forEach { $0() }
        XCTAssertFalse(keyboard.handle(key: 53, pressed: false, repeated: false, flags: []))
    }
}
