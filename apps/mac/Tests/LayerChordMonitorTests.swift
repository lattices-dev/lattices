import CoreGraphics
import XCTest
@testable import Lattices

final class LayerChordMonitorTests: XCTestCase {
    private let browse: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    private let direct: CGEventFlags = [.maskCommand, .maskAlternate]
    private let tile: CGEventFlags = [.maskControl, .maskAlternate]

    func testTheArrowChordStartsOnceAndReleasesOnce() {
        var chord = LayerChordState()
        XCTAssertNil(chord.update(.maskControl))
        XCTAssertNil(chord.update(tile))
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.activeChord, .arrows)
        XCTAssertNil(chord.update(browse))
        XCTAssertEqual(chord.update(tile), .released)
        XCTAssertFalse(chord.holding)
        XCTAssertNil(chord.update([]))
    }

    func testDirectSlotChordStillStartsAndReleases() {
        var chord = LayerChordState()
        XCTAssertNil(chord.update(.maskCommand))
        XCTAssertEqual(chord.update(direct), .pressed)
        XCTAssertEqual(chord.activeChord, .direct)
        XCTAssertEqual(chord.update(.maskAlternate), .released)
        XCTAssertNil(chord.update([]))
    }

    func testTilingChordNeverStartsLayerBrowsing() {
        var chord = LayerChordState()
        XCTAssertNil(chord.update(.maskAlternate))
        XCTAssertNil(chord.update(tile))
        XCTAssertNil(chord.update(.maskControl))
        XCTAssertNil(chord.update([]))
        XCTAssertFalse(chord.holding)
    }

    func testEveryArrowChordReleaseOrderReleasesExactlyOnce() {
        assertReleaseOrders([.maskControl, .maskAlternate, .maskShift])
    }

    func testEveryDirectChordReleaseOrderReleasesExactlyOnce() {
        assertReleaseOrders([.maskCommand, .maskAlternate])
    }

    func testAddingCommandCancelsArrowAimInsteadOfOfferingToSwitch() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update(browse.union(.maskCommand)), .cancelled)
        XCTAssertFalse(chord.holding)
        XCTAssertNil(chord.update(tile))
        XCTAssertNil(chord.update([]))
    }

    func testAddingShiftOrControlCancelsDirectSlotAim() {
        for modifier: CGEventFlags in [.maskShift, .maskControl] {
            var chord = LayerChordState()
            XCTAssertEqual(chord.update(direct), .pressed)
            XCTAssertEqual(chord.update(direct.union(modifier)), .cancelled)
            XCTAssertNil(chord.update([]))
        }
    }

    func testChangingChordCannotReleaseThePreviousAim() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(direct), .pressed)
        XCTAssertEqual(chord.update(browse), .cancelled)
        XCTAssertNil(chord.update([]))
        XCTAssertEqual(chord.update(browse), .pressed)
    }

    func testAnExplicitCancelDoesNotBecomeAReleaseLater() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        chord.cancel()
        XCTAssertNil(chord.update([]))
    }

    func testCapsLockAndFunctionFlagsDoNotChangeEitherLayerChord() {
        for flags in [browse, direct] {
            XCTAssertEqual(LayerChordState.mode(flags.union([.maskAlphaShift, .maskSecondaryFn])), .browse)
        }
        XCTAssertEqual(LayerChordState.mode(tile, for: .arrows), .release)
        XCTAssertEqual(LayerChordState.mode(browse.union(.maskCommand), for: .arrows), .cancel)
        XCTAssertEqual(LayerChordState.mode([.maskCommand, .maskShift], for: .direct), .cancel)
    }

    func testTilingArrowsPassThroughFrozenPreviewAndPendingLayerChoice() {
        for key: Int64 in [123, 124, 125, 126] {
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: tile))
            XCTAssertEqual(LayerAim.choice(for: key, flags: tile), .cancelAndPass)
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: browse))
            XCTAssertEqual(LayerAim.choice(for: key, flags: browse), .pass)
        }
    }

    func testShiftedTilingDigitsPassThroughBothLayerSurfaces() {
        for key: Int64 in [18, 19, 20] { // ⌃⌥⇧1–3: window thirds.
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: browse))
            XCTAssertEqual(LayerAim.choice(for: key, flags: browse), .cancelAndPass)
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: direct))
            XCTAssertEqual(LayerAim.choice(for: key, flags: direct), .pass)
        }
    }

    func testModifiedPlacementKeysNeverConfirmOrEditTheLayerPreview() {
        for key: Int64 in [36, 76, 8] { // ⌃⌥ Return/Enter maximize, C centers.
            XCTAssertEqual(LayerAim.choice(for: key, flags: tile), .cancelAndPass)
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: tile))
        }
        XCTAssertEqual(LayerAim.choice(for: 53, flags: .maskShift), .cancel)
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 53, flags: .maskShift))
    }

    func testEachBrowseChordOwnsOnlyItsLayerKeys() {
        XCTAssertTrue(LayerChordState.BrowseChord.arrows.accepts(key: 123))
        XCTAssertFalse(LayerChordState.BrowseChord.direct.accepts(key: 123))
        XCTAssertTrue(LayerChordState.BrowseChord.direct.accepts(key: 83))
        XCTAssertTrue(LayerChordState.BrowseChord.direct.accepts(key: 29))
        XCTAssertTrue(LayerChordState.BrowseChord.direct.accepts(key: 6))
        XCTAssertFalse(LayerChordState.BrowseChord.arrows.accepts(key: 18))
        for chord in LayerChordState.BrowseChord.allCases {
            XCTAssertTrue(chord.accepts(key: 49))
            XCTAssertFalse(chord.accepts(key: 53))
        }
    }

    func testUnmodifiedConfirmationAndPreviewNavigationRemainAvailable() {
        XCTAssertEqual(LayerAim.choice(for: 36, flags: []), .confirm)
        XCTAssertEqual(LayerAim.choice(for: 76, flags: []), .confirm)
        XCTAssertEqual(LayerAim.choice(for: 53, flags: []), .cancel)
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 48, flags: .maskShift))
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 123, flags: []))
    }

    private func assertReleaseOrders(_ modifiers: [CGEventFlags]) {
        let initial = modifiers.reduce(CGEventFlags()) { $0.union($1) }
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(initial), .pressed)
        func release(_ remaining: [CGEventFlags], flags: CGEventFlags, chord: LayerChordState, first: Bool) {
            guard !remaining.isEmpty else { return }
            for (index, modifier) in remaining.enumerated() {
                var next = chord
                let released = flags.subtracting(modifier)
                XCTAssertEqual(next.update(released), first ? .released : nil)
                XCTAssertFalse(next.holding)
                var rest = remaining
                rest.remove(at: index)
                release(rest, flags: released, chord: next, first: false)
            }
        }
        release(modifiers, flags: initial, chord: chord, first: true)
    }
}
