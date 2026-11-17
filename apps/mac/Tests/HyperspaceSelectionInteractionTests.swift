import AppKit
import XCTest
@testable import Lattices

@MainActor
final class HyperspaceSelectionInteractionTests: XCTestCase {
    func testAppIconsRemainAvailableAcrossSelectionAndDeselection() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let hud = HyperspaceDesktopHUD()
        defer { hud.orderOut(nil) }
        var selected: [UInt32] = []
        var picked: [UInt32] = []
        func render() {
            hud.update(.init(windows: [UInt32(1), 2, 3].map { id in
                .init(id: id, app: id == 1 ? "Rex Beta" : "App \(id)", title: "Window \(id)",
                      frame: CGRect(x: 0, y: 0, width: 800, height: 600), icon: nil,
                      slot: selected.firstIndex(of: id).map { $0 + 1 })
            }, area: screen.visibleFrame, desktop: true, hasChanges: false, canUndo: false,
               preview: nil, notice: nil, busy: false), on: screen)
        }
        hud.onPick = { id in
            picked.append(id)
            if selected.contains(id) { selected.removeAll { $0 == id } }
            else { selected.append(id) }
            render()
        }
        render()
        let initialFrame = hud.frame
        let rex = try XCTUnwrap(windowButton(1, in: hud.contentView))
        rex.performClick(nil)

        XCTAssertEqual(picked, [1], "An app icon selects its window exactly once")
        XCTAssertEqual(selected, [1])
        XCTAssertTrue(hud.isVisible, "Selection must keep Hyperspace open")
        XCTAssertEqual(hud.frame, initialFrame, "Selecting must not collapse or move the picker")
        XCTAssertNotNil(windowButton(1, in: hud.contentView), "Keep the selected icon available to deselect")
        XCTAssertEqual(windowButton(1, in: hud.contentView)?.accessibilityValue() as? String, "Selected, window 1")
        let second = try XCTUnwrap(windowButton(2, in: hud.contentView), "Keep other icons available to build a selection")
        second.performClick(nil)
        XCTAssertEqual(selected, [1, 2])
        XCTAssertEqual(windowButton(2, in: hud.contentView)?.accessibilityValue() as? String, "Selected, window 2")
        try XCTUnwrap(windowButton(1, in: hud.contentView)).performClick(nil)
        XCTAssertEqual(selected, [2])
        XCTAssertEqual(picked, [1, 2, 1])
        XCTAssertEqual(windowButton(1, in: hud.contentView)?.accessibilityValue() as? String, "Not selected")
        XCTAssertEqual(windowButton(2, in: hud.contentView)?.accessibilityValue() as? String, "Selected, window 1")
        XCTAssertEqual(hud.frame, initialFrame)
        XCTAssertTrue(hud.isVisible)
    }

    private func windowButton(_ id: UInt32, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == "hud.window.\(id)" { return button }
        return view.subviews.lazy.compactMap { self.windowButton(id, in: $0) }.first
    }
}
