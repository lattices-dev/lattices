import AppKit
import Carbon
import XCTest
@testable import Lattices

final class ScreenMapShortcutTests: XCTestCase {
    func testDefaultDirectionalShortcutsMatchDesktopAndFreeControlOptionArrows() {
        let directions: [(UInt16, TilePosition)] = [(123, .left), (124, .right), (126, .top), (125, .bottom)]
        for (key, position) in directions {
            XCTAssertEqual(ScreenMapController.directionalTilePosition(
                for: key, modifiers: [.command, .option, .shift], bindings: HotkeyStore.defaultBindings
            ), position)
            XCTAssertNil(ScreenMapController.directionalTilePosition(
                for: key, modifiers: [.control, .option], bindings: HotkeyStore.defaultBindings
            ))
            XCTAssertNil(ScreenMapController.directionalTilePosition(
                for: key, modifiers: [.command, .option], bindings: HotkeyStore.defaultBindings
            ))
        }
    }

    func testUsesCustomKeyAndModifiersWithoutKeepingTheDefaultAlias() {
        var bindings = HotkeyStore.defaultBindings
        bindings[.tileLeft] = KeyBinding(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey), displayParts: [])

        XCTAssertEqual(ScreenMapController.directionalTilePosition(
            for: 0, modifiers: [.control, .option], bindings: bindings
        ), .left)
        XCTAssertNil(ScreenMapController.directionalTilePosition(
            for: 123, modifiers: [.command, .option, .shift], bindings: bindings
        ))
        XCTAssertNil(ScreenMapController.directionalTilePosition(
            for: 0, modifiers: [.control, .option, .shift], bindings: bindings
        ))
    }

    func testExplicitControlOptionArrowRemapWorksAndDisabledBindingDoesNot() {
        var bindings = HotkeyStore.defaultBindings
        bindings[.tileTop] = KeyBinding(keyCode: 126, carbonModifiers: UInt32(controlKey | optionKey), displayParts: [])
        XCTAssertEqual(ScreenMapController.directionalTilePosition(
            for: 126, modifiers: [.control, .option, .numericPad, .function], bindings: bindings
        ), .top)

        bindings.removeValue(forKey: .tileTop)
        XCTAssertNil(ScreenMapController.directionalTilePosition(
            for: 126, modifiers: [.control, .option], bindings: bindings
        ))
        XCTAssertNil(ScreenMapController.directionalTilePosition(
            for: 126, modifiers: [.command, .option, .shift], bindings: bindings
        ))
    }
}
