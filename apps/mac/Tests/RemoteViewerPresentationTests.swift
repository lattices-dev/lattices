import XCTest
@testable import Lattices

final class RemoteViewerPresentationTests: XCTestCase {
    @MainActor
    func testFullScreenControlsHideAndMenuOwnsDelayedPointerExit() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        presentation.setFullScreen(true)
        XCTAssertFalse(presentation.controlsVisible)
        presentation.setControlsHovered(true)
        XCTAssertTrue(presentation.controlsVisible)
        presentation.setControlsHovered(false)
        presentation.setMenuTracking(true)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible, "A menu must survive a pending pointer-exit hide")
        XCTAssertTrue(presentation.localControlsActive)
        presentation.setMenuTracking(false)
        presentation.hideControlsIfIdle()
        XCTAssertFalse(presentation.controlsVisible)
        XCTAssertFalse(presentation.localControlsActive)
    }

    @MainActor
    func testKeyboardFocusPinsControlsAndSuspendsCaptureOnlyOnOwnershipChange() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        var suspensions = 0
        presentation.localInteractionBegan = { suspensions += 1 }
        presentation.setFullScreen(true)
        presentation.setControlsHovered(true)
        presentation.noteKeyboardNavigation()
        presentation.setControlsFocused(true)
        presentation.setControlsHovered(false)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertEqual(suspensions, 1)
        presentation.setControlsFocused(false)
        presentation.hideControlsIfIdle()
        XCTAssertFalse(presentation.controlsVisible)
        presentation.setFullScreen(false)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible, "A delayed fullscreen hide cannot hide windowed controls")
    }

    @MainActor
    func testMouseFocusDoesNotPinControlsAfterMenuDismisses() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        presentation.setFullScreen(true)
        presentation.setControlsHovered(true)
        presentation.notePointerInteraction()
        presentation.setControlsFocused(true)
        presentation.setMenuTracking(true)
        presentation.setControlsHovered(false)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible)
        presentation.setMenuTracking(false)
        presentation.hideControlsIfIdle()
        XCTAssertFalse(presentation.controlsVisible)
        XCTAssertFalse(presentation.localControlsActive)
    }

    @MainActor
    func testClosingInvalidatesPendingHideAndInteractionCallbacks() {
        let presentation = RemoteViewerPresentation()
        presentation.setFullScreen(true)
        presentation.setControlsHovered(true)
        presentation.setControlsHovered(false)
        presentation.invalidate()
        presentation.hideControlsIfIdle()
        presentation.setControlsFocused(true)
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertFalse(presentation.localControlsActive)
    }

    @MainActor
    func testHoverRevealsChromeWithoutTakingKeyboardOwnership() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        var suspensions = 0
        var returns = 0
        presentation.localInteractionBegan = { suspensions += 1 }
        presentation.remoteInteractionRequested = { returns += 1 }
        presentation.setFullScreen(true)
        presentation.setEdgeHovered(true)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertFalse(presentation.localControlsActive)
        presentation.setEdgeHovered(false)
        presentation.setControlsHovered(true)
        presentation.hideControlsIfIdle()
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertFalse(presentation.localControlsActive)
        XCTAssertEqual(suspensions, 0, "Hovering local chrome must not swallow remote typing")
        presentation.setControlsHovered(false)
        presentation.hideControlsIfIdle()
        XCTAssertFalse(presentation.controlsVisible)
        XCTAssertEqual(returns, 0, "Hover alone must not steal first responder from a control")
    }

    @MainActor
    func testEnablingRemoteInputReturnsFocusWhileToolbarIsStillHovered() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        var returns = 0
        presentation.remoteInteractionRequested = { returns += 1 }
        presentation.setControlsHovered(true)
        presentation.notePointerInteraction()
        presentation.setControlsFocused(true)
        presentation.requestRemoteInput()
        XCTAssertFalse(presentation.localControlsActive)
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertEqual(returns, 1, "Control/Keyboard enable needs one explicit focus handoff")
    }

    @MainActor
    func testMenuOwnsKeyboardThenReturnsItOnceWhileHoverRemains() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        var suspensions = 0
        var returns = 0
        presentation.localInteractionBegan = { suspensions += 1 }
        presentation.remoteInteractionRequested = { returns += 1 }
        presentation.setControlsHovered(true)
        presentation.setMenuTracking(true)
        XCTAssertTrue(presentation.localControlsActive)
        XCTAssertEqual(suspensions, 1)
        presentation.requestRemoteInput()
        XCTAssertTrue(presentation.localControlsActive, "An open menu must finish before handing input back")
        XCTAssertEqual(returns, 0)
        presentation.setMenuTracking(false)
        XCTAssertFalse(presentation.localControlsActive)
        XCTAssertEqual(returns, 1)
        presentation.setControlsHovered(false)
        presentation.setControlsHovered(true)
        XCTAssertEqual(returns, 1, "Frame/chrome updates must not repeat the focus handoff")
    }

    @MainActor
    func testRemoteTabDoesNotActivateStaleToolbarFocus() {
        let presentation = RemoteViewerPresentation()
        defer { presentation.invalidate() }
        presentation.setControlsFocused(true)
        presentation.notePointerInteraction()
        presentation.remoteInputIsFirstResponder = { true }
        presentation.noteKeyboardNavigation()
        XCTAssertFalse(presentation.localControlsActive, "Tab while typing remotely belongs to the remote app")
        presentation.remoteInputIsFirstResponder = { false }
        presentation.noteKeyboardNavigation()
        XCTAssertTrue(presentation.localControlsActive, "Actual toolbar keyboard navigation stays local")
        presentation.requestRemoteInput()
        XCTAssertFalse(presentation.localControlsActive, "A picture click returns ownership explicitly")
    }

}
