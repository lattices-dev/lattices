import Carbon
import XCTest
@testable import Lattices

final class LayerTilingShortcutTests: XCTestCase {
    private let arrows: [(HotkeyAction, HotkeyAction, UInt32)] = [
        (.layerPrev, .tileLeft, 123), (.layerNext, .tileRight, 124),
        (.layerUp, .tileTop, 126), (.layerDown, .tileBottom, 125),
    ]

    func testLayerAndTileArrowsShareCommandOptionAndFreeControlOption() {
        for (layer, tile, code) in arrows {
            XCTAssertEqual(HotkeyStore.defaultBindings[layer]?.keyCode, code)
            XCTAssertEqual(HotkeyStore.defaultBindings[layer]?.carbonModifiers, UInt32(cmdKey | optionKey))
            XCTAssertEqual(HotkeyStore.defaultBindings[tile]?.keyCode, code)
            XCTAssertEqual(HotkeyStore.defaultBindings[tile]?.carbonModifiers, UInt32(cmdKey | optionKey | shiftKey))
            XCTAssertFalse(HotkeyStore.defaultBindings.values.contains {
                $0.keyCode == code && $0.carbonModifiers == UInt32(controlKey | optionKey)
            })
        }
    }

    func testMigratesPersistedFormerDefaults() throws {
        try withDefaults { defaults in
            for (_, tile, code) in arrows {
                try save(tile, code: code, modifiers: UInt32(controlKey | optionKey), in: defaults)
            }
            HotkeyStore.migrateLayerTilingArrows(in: defaults)
            for (_, tile, code) in arrows {
                XCTAssertNil(defaults.data(forKey: "hotkey.\(tile.rawValue)"))
                XCTAssertEqual(HotkeyStore.defaultBindings[tile]?.keyCode, code)
                XCTAssertEqual(HotkeyStore.defaultBindings[tile]?.carbonModifiers, UInt32(cmdKey | optionKey | shiftKey))
            }
        }
    }

    func testPreservesCustomAndDisabledBindings() throws {
        try withDefaults { defaults in
            try save(.tileLeft, code: 0, modifiers: UInt32(controlKey | optionKey), in: defaults)
            try save(.tileRight, code: 124, modifiers: UInt32(cmdKey | shiftKey), in: defaults)
            try save(.tileTop, code: 126, modifiers: UInt32(controlKey | optionKey), in: defaults)
            defaults.set(true, forKey: "hotkey.tileTop.disabled")

            HotkeyStore.migrateLayerTilingArrows(in: defaults)

            XCTAssertEqual(try load(.tileLeft, from: defaults).keyCode, 0)
            XCTAssertEqual(try load(.tileRight, from: defaults).carbonModifiers, UInt32(cmdKey | shiftKey))
            XCTAssertEqual(try load(.tileTop, from: defaults).carbonModifiers, UInt32(controlKey | optionKey))
            XCTAssertTrue(defaults.bool(forKey: "hotkey.tileTop.disabled"))
            XCTAssertNil(defaults.data(forKey: "hotkey.tileBottom"))
        }
    }

    func testLaterExplicitOptBackInIsNotMigratedAgain() throws {
        try withDefaults { defaults in
            HotkeyStore.migrateLayerTilingArrows(in: defaults)
            try save(.tileLeft, code: 123, modifiers: UInt32(controlKey | optionKey), in: defaults)
            HotkeyStore.migrateLayerTilingArrows(in: defaults)
            XCTAssertEqual(try load(.tileLeft, from: defaults).carbonModifiers, UInt32(controlKey | optionKey))
        }
    }

    func testNewDefaultsYieldToExplicitDestinationBindings() throws {
        var bindings = HotkeyStore.defaultBindings
        let occupied = try XCTUnwrap(bindings[.tileLeft])
        bindings[.workspaceAssistant] = occupied
        HotkeyStore.preserveExplicitArrowBindings(in: &bindings, explicitActions: [.workspaceAssistant])
        XCTAssertEqual(bindings[.workspaceAssistant], occupied)
        XCTAssertNil(bindings[.tileLeft])
        XCTAssertNotNil(bindings[.tileRight])
    }

    func testExplicitTileOverrideIsNotRemoved() {
        var bindings = HotkeyStore.defaultBindings
        let chosen = bindings[.tileLeft]
        bindings[.workspaceAssistant] = chosen
        HotkeyStore.preserveExplicitArrowBindings(in: &bindings, explicitActions: [.workspaceAssistant, .tileLeft])
        XCTAssertEqual(bindings[.tileLeft], chosen)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "LayerTilingShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func save(_ action: HotkeyAction, code: UInt32, modifiers: UInt32, in defaults: UserDefaults) throws {
        let binding = KeyBinding(keyCode: code, carbonModifiers: modifiers,
                                 displayParts: KeyBinding.displayParts(keyCode: code, carbonModifiers: modifiers))
        defaults.set(try JSONEncoder().encode(binding), forKey: "hotkey.\(action.rawValue)")
    }

    private func load(_ action: HotkeyAction, from defaults: UserDefaults) throws -> KeyBinding {
        try JSONDecoder().decode(KeyBinding.self, from: XCTUnwrap(defaults.data(forKey: "hotkey.\(action.rawValue)")))
    }
}
