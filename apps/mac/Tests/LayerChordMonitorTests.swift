import CoreGraphics
import XCTest
@testable import Lattices

final class LayerChordMonitorTests: XCTestCase {
    private let browse: CGEventFlags = [.maskCommand, .maskAlternate]
    private let tile: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]

    func testTheExactLayerChordStartsOnceAndReleasesOnce() {
        var chord = LayerChordState()
        XCTAssertNil(chord.update(.maskCommand))
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertTrue(chord.holding)
        XCTAssertNil(chord.update(browse))
        XCTAssertEqual(chord.update(.maskAlternate), .released)
        XCTAssertFalse(chord.holding)
        XCTAssertNil(chord.update([]))
    }

    func testAddingShiftCancelsInsteadOfOfferingToSwitchLayers() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update(tile), .cancelled)
        XCTAssertFalse(chord.holding)
        // Letting go of the tiling chord cannot release the abandoned aim.
        XCTAssertNil(chord.update([.maskCommand, .maskShift]))
        XCTAssertNil(chord.update([]))
    }

    func testAddingControlCancelsInsteadOfOfferingToSwitchLayers() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update(browse.union(.maskControl)), .cancelled)
        XCTAssertNil(chord.update([]))
    }

    func testShiftFirstTilingAndHyperNeverStartLayerBrowsing() {
        var chord = LayerChordState()
        XCTAssertNil(chord.update(.maskShift))
        XCTAssertNil(chord.update([.maskShift, .maskCommand]))
        XCTAssertEqual(chord.update(tile), .cancelled)
        XCTAssertEqual(chord.update(tile.union(.maskControl)), .cancelled)
        XCTAssertFalse(chord.holding)
    }

    func testReturningToTheExactChordStartsAFreshBrowse() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update(tile), .cancelled)
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update([]), .released)
    }

    func testAnExplicitCancelDoesNotBecomeAReleaseLater() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        chord.cancel()
        XCTAssertNil(chord.update([]))
    }

    func testCapsLockAndFunctionFlagsDoNotChangeTheLayerChord() {
        XCTAssertEqual(LayerChordState.mode(browse.union([.maskAlphaShift, .maskSecondaryFn])), .browse)
        XCTAssertEqual(LayerChordState.mode(tile), .cancel)
        XCTAssertEqual(LayerChordState.mode(browse.union(.maskControl)), .cancel)
        // The release watcher must also cancel if a base modifier came up
        // before it observes the added Shift or Control.
        XCTAssertEqual(LayerChordState.mode([.maskCommand, .maskShift]), .cancel)
    }

    func testTilingArrowsPassThroughFrozenPreviewAndPendingLayerChoice() {
        for key: Int64 in [123, 124, 125, 126] {
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: tile))
            XCTAssertEqual(LayerAim.choice(for: key, flags: tile), .cancelAndPass)
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: browse))
            XCTAssertEqual(LayerAim.choice(for: key, flags: browse), .pass)
        }
    }

    func testControlCannotExtendLayerBrowsingOrLoseItsArrow() {
        let flags = browse.union(.maskControl)
        for key: Int64 in [123, 124, 125, 126] {
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: flags))
            XCTAssertEqual(LayerAim.choice(for: key, flags: flags), .cancelAndPass)
        }
    }

    func testControlOptionArrowsLeavePreviewForUserShortcuts() {
        for key: Int64 in [123, 124, 125, 126] {
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: [.maskControl, .maskAlternate]))
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: []))
        }
    }

    func testUnmodifiedConfirmationAndPreviewNavigationRemainAvailable() {
        XCTAssertEqual(LayerAim.choice(for: 36, flags: []), .confirm)
        XCTAssertEqual(LayerAim.choice(for: 76, flags: []), .confirm)
        XCTAssertEqual(LayerAim.choice(for: 53, flags: []), .cancel)
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 48, flags: .maskShift))
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 123, flags: []))
    }
}
