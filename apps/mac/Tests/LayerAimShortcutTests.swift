import AppKit
import CoreGraphics
import XCTest
@testable import Lattices

final class LayerAimShortcutTests: XCTestCase {
    private let browse: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    private let direct: CGEventFlags = [.maskCommand, .maskAlternate]

    func testDefaultLayerActionBrowsesWhileHeldAndDecidesAfterRelease() {
        let binding = HotkeyStore.defaultBindings[.layerPrev]
        XCTAssertEqual(LayerAim.entry(for: browse, binding: binding), .browse)
        XCTAssertEqual(LayerAim.entry(for: browse.union([.maskAlphaShift, .maskSecondaryFn]), binding: binding), .browse)
        XCTAssertEqual(LayerAim.entry(for: .maskAlternate, binding: binding), .decide)
        XCTAssertEqual(LayerAim.entry(for: [], binding: binding), .decide)
    }

    func testLateDefaultArrowActionCannotReviveBrowseAfterCommandWasAdded() {
        let binding = HotkeyStore.defaultBindings[.layerPrev]
        XCTAssertEqual(LayerAim.entry(for: browse.union(.maskCommand), binding: binding), .cancel)
        XCTAssertEqual(LayerAim.entry(for: [.maskCommand, .maskShift], binding: binding), .cancel)
        XCTAssertEqual(LayerAim.entry(for: direct, binding: binding), .cancel)
    }

    func testEveryArrowChordReleaseSubsetCanOfferItsDecision() {
        let binding = HotkeyStore.defaultBindings[.layerPrev]
        for flags: CGEventFlags in [[], .maskControl, .maskAlternate, .maskShift,
                                    [.maskControl, .maskAlternate], [.maskControl, .maskShift],
                                    [.maskAlternate, .maskShift]] {
            XCTAssertEqual(LayerAim.entry(for: flags, binding: binding), .decide)
        }
    }

    func testDirectLayerActionKeepsItsOwnHeldChord() {
        let binding = KeyBinding(keyCode: 18,
                                 carbonModifiers: KeyBinding.carbonModifiers(from: [.command, .option]),
                                 displayParts: [])
        XCTAssertEqual(LayerAim.entry(for: direct, binding: binding), .browse)
        XCTAssertEqual(LayerAim.entry(for: [], binding: binding), .decide)
        XCTAssertEqual(LayerAim.entry(for: direct.union(.maskShift), binding: binding), .cancel)
        XCTAssertEqual(LayerAim.entry(for: browse, binding: binding), .cancel)
    }

    func testExplicitCustomLayerActionsDecideWhileTheirModifiersAreHeld() {
        let modifiers: [(NSEvent.ModifierFlags, CGEventFlags)] = [
            ([.control, .option], [.maskControl, .maskAlternate]),
            ([.command, .shift], [.maskCommand, .maskShift]),
            ([.command, .option, .shift], [.maskCommand, .maskAlternate, .maskShift]),
            ([], []),
        ]
        for (appKitFlags, cgFlags) in modifiers {
            let binding = KeyBinding(keyCode: 123,
                                     carbonModifiers: KeyBinding.carbonModifiers(from: appKitFlags),
                                     displayParts: [])
            XCTAssertEqual(LayerAim.entry(for: cgFlags, binding: binding), .decide)
            // Fast release or a remaining Cmd+Option pair must not turn a
            // dispatched custom action into the default held browse.
            XCTAssertEqual(LayerAim.entry(for: [], binding: binding), .decide)
            XCTAssertEqual(LayerAim.entry(for: browse, binding: binding), .decide)
        }
    }

    func testRemappedKeysOutsideTheirChordFamilyRemainCustomActions() {
        let remaps: [(UInt32, NSEvent.ModifierFlags, CGEventFlags)] = [
            (123, [.command, .option], direct),
            (18, [.control, .option, .shift], browse),
            (8, [.control, .option, .shift], browse),
        ]
        for (key, modifiers, flags) in remaps {
            let binding = KeyBinding(keyCode: key,
                                     carbonModifiers: KeyBinding.carbonModifiers(from: modifiers),
                                     displayParts: [])
            XCTAssertTrue(LayerAim.isCustomShortcut(binding))
            XCTAssertEqual(LayerAim.entry(for: flags, binding: binding), .decide)
            XCTAssertEqual(LayerAim.entry(for: [], binding: binding), .decide)
        }
    }

    func testFixedKeypadActionsRetainDefaultChordCancellation() {
        XCTAssertEqual(LayerAim.entry(for: direct, binding: nil), .browse)
        XCTAssertEqual(LayerAim.entry(for: [], binding: nil), .decide)
        XCTAssertEqual(LayerAim.entry(for: direct.union(.maskShift), binding: nil), .cancel)
        XCTAssertEqual(LayerAim.entry(for: browse, binding: nil), .cancel)
    }

    func testCustomDecisionSurvivesEveryCommandOptionShiftReleaseOrder() {
        assertCustomDecisionSurvivesRelease(of: [.maskCommand, .maskAlternate, .maskShift])
    }

    func testCustomDecisionSurvivesEveryHyperReleaseOrder() {
        assertCustomDecisionSurvivesRelease(of: [.maskCommand, .maskAlternate, .maskShift, .maskControl])
    }

    func testDelayedChordEventsCannotCancelOrResumeACustomDecision() {
        var chord = LayerChordState()
        XCTAssertEqual(chord.update(browse), .pressed)
        // The explicit custom action reached Carbon before these queued
        // modifier events. None may cancel, resume, or release its decision.
        for flags in [browse.union(.maskCommand), browse, direct, CGEventFlags()] {
            XCTAssertNil(chord.update(flags, preservingShortcutDecision: true))
            XCTAssertFalse(chord.holding)
        }
        // Once the choice is resolved, a new default browse works normally.
        XCTAssertEqual(chord.update(browse), .pressed)
        XCTAssertEqual(chord.update(browse.union(.maskCommand)), .cancelled)
    }

    private func assertCustomDecisionSurvivesRelease(of modifiers: [CGEventFlags]) {
        let initial = modifiers.reduce(CGEventFlags()) { $0.union($1) }
        func release(_ remaining: [CGEventFlags], flags: CGEventFlags, chord: LayerChordState) {
            guard !remaining.isEmpty else { return }
            for (index, modifier) in remaining.enumerated() {
                var next = chord
                let released = flags.subtracting(modifier)
                XCTAssertNil(next.update(released, preservingShortcutDecision: true))
                XCTAssertFalse(next.holding)
                var rest = remaining
                rest.remove(at: index)
                release(rest, flags: released, chord: next)
            }
        }
        release(modifiers, flags: initial, chord: LayerChordState())
    }
}
