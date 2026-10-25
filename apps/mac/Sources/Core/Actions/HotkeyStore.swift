import Carbon
import AppKit
import Combine

// MARK: - HotkeyGroup

enum HotkeyGroup: String, CaseIterable {
    case app
    case layers
    case tiling
}

// MARK: - HotkeyAction

enum HotkeyAction: String, CaseIterable, Codable {
    // App
    case palette
    case screenMap
    case bezel
    case cheatSheet
    case desktopInventory
    case omniSearch
    case voiceCommand
    case handsOff
    case unifiedWindow
    case hud
    case mouseFinder
    case overlayActors
    case workspaceAssistant
    case activityLog
    case gridPlacement
    case commandBar
    case focusMode
    case stageMode
    // Layers
    case layer1, layer2, layer3, layer4, layer5, layer6, layer7, layer8, layer9
    case layerNext, layerPrev, layerUp, layerDown, layerTag
    // Tiling
    case tileLeft, tileRight, tileMaximize, tileCenter
    case tileTopLeft, tileTopRight, tileBottomLeft, tileBottomRight
    case tileTop, tileBottom, tileDistribute, tileTypeGrid, tileOrganize
    case tileLeftThird, tileCenterThird, tileRightThird
    case tileOpenCell
    case motionMode
    case inPlaceMode
    case chordHints

    var label: String {
        switch self {
        case .palette:         return "Command Palette"
        case .screenMap:       return "Overview"
        case .bezel:           return "Window Bezel"
        case .cheatSheet:      return "Cheat Sheet"
        case .desktopInventory: return "Overview (alternate)"
        case .omniSearch:      return "Search"
        case .voiceCommand:    return "Voice Command"
        case .handsOff:        return "Hands-Off Mode"
        case .unifiedWindow:   return "Workspace Home"
        case .hud:             return "HUD"
        case .mouseFinder:     return "Find Mouse"
        case .overlayActors:   return "Toggle Overlay Actors"
        case .workspaceAssistant: return "Workspace Assistant"
        case .activityLog:     return "Activity Log"
        case .gridPlacement:   return "Grid Placement"
        case .commandBar:      return "Command Bar"
        case .focusMode:       return "Focus Mode"
        case .stageMode:       return "Stage"
        case .layer1:          return "Layer 1"
        case .layer2:          return "Layer 2"
        case .layer3:          return "Layer 3"
        case .layer4:          return "Layer 4"
        case .layer5:          return "Show Current Layer"
        case .layer6:          return "Layer 6"
        case .layer7:          return "Layer 7"
        case .layer8:          return "Layer 8"
        case .layer9:          return "Layer 9"
        case .layerNext:       return "Layer Right"
        case .layerPrev:       return "Layer Left"
        case .layerUp:         return "Layer Up"
        case .layerDown:       return "Layer Down"
        case .layerTag:        return "Tag Window"
        case .tileLeft:        return "Tile Left"
        case .tileRight:       return "Tile Right"
        case .tileMaximize:    return "Maximize"
        case .tileCenter:      return "Center"
        case .tileTopLeft:     return "Top Left"
        case .tileTopRight:    return "Top Right"
        case .tileBottomLeft:  return "Bottom Left"
        case .tileBottomRight: return "Bottom Right"
        case .tileTop:         return "Top Half"
        case .tileBottom:      return "Bottom Half"
        case .tileDistribute:  return "Distribute"
        case .tileTypeGrid:    return "Grid Type"
        case .tileOrganize:    return "Organize Windows"
        case .tileLeftThird:   return "Left Third"
        case .tileCenterThird: return "Center Third"
        case .tileRightThird:  return "Right Third"
        case .tileOpenCell:    return "Fill Open Cell"
        case .motionMode:      return "Hyperspace"
        case .inPlaceMode:     return "In-Place Tools"
        case .chordHints:      return "Window Nav Hints"
        }
    }

    var group: HotkeyGroup {
        switch self {
        case .palette, .screenMap, .bezel, .cheatSheet, .desktopInventory, .omniSearch, .voiceCommand, .handsOff, .unifiedWindow, .hud, .mouseFinder, .overlayActors, .workspaceAssistant, .activityLog, .gridPlacement, .commandBar, .focusMode, .stageMode, .inPlaceMode, .chordHints: return .app
        case .layer1, .layer2, .layer3, .layer4, .layer5,
             .layer6, .layer7, .layer8, .layer9,
             .layerNext, .layerPrev, .layerUp, .layerDown, .layerTag: return .layers
        default: return .tiling
        }
    }

    var carbonID: UInt32 {
        switch self {
        case .palette:         return 1
        case .screenMap:       return 200
        case .bezel:           return 201
        case .cheatSheet:      return 202
        case .desktopInventory: return 203
        case .omniSearch:      return 204
        case .voiceCommand:    return 205
        case .handsOff:        return 206
        case .unifiedWindow:   return 207
        case .hud:             return 208
        case .mouseFinder:     return 209
        case .overlayActors:   return 210
        case .workspaceAssistant: return 211
        case .activityLog:     return 212
        case .gridPlacement:   return 213
        case .commandBar:      return 214
        case .focusMode:       return 215
        case .stageMode:       return 220
        case .layer1:          return 101
        case .layer2:          return 102
        case .layer3:          return 103
        case .layer4:          return 104
        case .layer5:          return 105
        case .layer6:          return 106
        case .layer7:          return 107
        case .layer8:          return 108
        case .layer9:          return 109
        case .layerNext:       return 110
        case .layerPrev:       return 111
        case .layerTag:        return 112
        case .layerUp:         return 113
        case .layerDown:       return 114
        case .tileLeft:        return 300
        case .tileRight:       return 301
        case .tileMaximize:    return 302
        case .tileCenter:      return 303
        case .tileTopLeft:     return 304
        case .tileTopRight:    return 305
        case .tileBottomLeft:  return 306
        case .tileBottomRight: return 307
        case .tileTop:         return 308
        case .tileBottom:      return 309
        case .tileDistribute:  return 310
        case .tileTypeGrid:    return 314
        case .tileLeftThird:   return 311
        case .tileCenterThird: return 312
        case .tileRightThird:  return 313
        case .tileOrganize:    return 315
        case .motionMode:      return 316
        case .inPlaceMode:     return 317
        case .tileOpenCell:    return 318
        case .chordHints:      return 319
        }
    }

    static var layerActions: [HotkeyAction] {
        [.layer1, .layer2, .layer3, .layer4, .layer5, .layer6, .layer7, .layer8, .layer9]
    }
}

// MARK: - KeyBinding

struct KeyBinding: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    var displayParts: [String]

    var compactDisplayParts: [String] {
        guard let key = displayParts.last else { return [] }
        let modifiers = Set(displayParts.dropLast())
        if modifiers == Set(["Ctrl", "Option", "Shift", "Cmd"]) {
            return ["Hyper", key]
        }
        return displayParts
    }

    var symbolicDisplay: String {
        let symbols = ["Ctrl": "⌃", "Option": "⌥", "Shift": "⇧", "Cmd": "⌘"]
        return displayParts.map { symbols[$0] ?? $0 }.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    static func displayParts(keyCode: UInt32, carbonModifiers: UInt32) -> [String] {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("Option") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("Shift") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("Cmd") }
        parts.append(keyName(for: keyCode))
        return parts
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`", 51: "Delete",
            53: "Escape",
            65: ".", // numpad
            67: "*", // numpad
            69: "+", // numpad
            71: "Clear", // numpad
            75: "/", // numpad
            76: "Enter", // numpad
            78: "-", // numpad
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", // numpad
            87: "5", 88: "6", 89: "7", 91: "8", 92: "9", // numpad
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 114: "Help",
            115: "Home", 116: "PgUp", 117: "Del", 118: "F4",
            119: "End", 120: "F2", 121: "PgDn", 122: "F1",
            123: "\u{2190}", // left arrow
            124: "\u{2192}", // right arrow
            125: "\u{2193}", // down arrow
            126: "\u{2191}", // up arrow
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

private enum HotkeyFileOverride: Decodable {
    case binding(KeyBinding)
    case disabled

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .disabled
        } else {
            self = .binding(try container.decode(KeyBinding.self))
        }
    }
}

// MARK: - HotkeyStore

class HotkeyStore: ObservableObject {
    static let shared = HotkeyStore()

    @Published var bindings: [HotkeyAction: KeyBinding]
    private var callbacks: [HotkeyAction: () -> Void] = [:]

    private func instrumentedCallback(for action: HotkeyAction, callback: @escaping () -> Void) -> () -> Void {
        {
            let timed = DiagnosticLog.shared.startTimed("Hotkey \(action.label)")
            callback()
            DiagnosticLog.shared.finish(timed)
        }
    }

    static let defaultBindings: [HotkeyAction: KeyBinding] = {
        var d = [HotkeyAction: KeyBinding]()
        let hyper = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let cmdShift = UInt32(cmdKey | shiftKey)
        let cmdOpt = UInt32(cmdKey | optionKey)
        let cmdOptShift = UInt32(cmdKey | optionKey | shiftKey)
        let ctrlOpt = UInt32(controlKey | optionKey)
        let ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)

        func bind(_ action: HotkeyAction, _ keyCode: UInt32, _ mods: UInt32) {
            d[action] = KeyBinding(
                keyCode: keyCode,
                carbonModifiers: mods,
                displayParts: KeyBinding.displayParts(keyCode: keyCode, carbonModifiers: mods)
            )
        }

        // App
        bind(.workspaceAssistant, 0, cmdShift) // Cmd+Shift+A
        bind(.unifiedWindow, 18, hyper)  // Hyper+1 (Workspace Home)
        bind(.screenMap, 37, hyper)      // Hyper+L (Layout)
        bind(.bezel,     19, hyper)      // Hyper+2
        bind(.hud,       20, hyper)      // Hyper+3 (HUD overlay)
        let cmdCtrl = UInt32(cmdKey | controlKey)
        bind(.handsOff, 46, cmdCtrl)          // Ctrl+Cmd+M
        bind(.activityLog, 37, cmdShift)   // Cmd+Shift+L
        bind(.cheatSheet, 22, hyper)       // Hyper+6
        bind(.mouseFinder, 26, hyper)      // Hyper+7
        bind(.gridPlacement, 5, ctrlOpt)   // Ctrl+Opt+G (4x4 placement target)
        bind(.commandBar, 49, ctrlOpt)     // Ctrl+Opt+Space (THE command bar — browse/search/commands)
        bind(.focusMode, 6, hyper)         // Hyper+Z — reversible window spotlight
        bind(.stageMode, 7, hyper)         // Hyper+X — grow the window you are in (Hyper+S is Talkie screenshots)

        // Layers: Cmd+Option+1-9, one per slot of the pad; 5 shows the current one
        let layerKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, action) in HotkeyAction.layerActions.enumerated() {
            bind(action, layerKeyCodes[i], cmdOpt)
        }

        // Layer moves across the pad: Cmd+Option+Arrow / Cmd+Option+T
        bind(.layerNext, 124, cmdOpt)  // Cmd+Opt+→
        bind(.layerPrev, 123, cmdOpt)  // Cmd+Opt+←
        bind(.layerUp,   126, cmdOpt)  // Cmd+Opt+↑
        bind(.layerDown, 125, cmdOpt)  // Cmd+Opt+↓
        bind(.layerTag,   17, cmdOpt)  // Cmd+Opt+T

        // Arrows share the layer family: add Shift to arrange the window.
        // Ctrl+Option+arrows remain available to other apps and custom bindings.
        bind(.tileLeft,        123, cmdOptShift)  // Cmd+Opt+Shift+←
        bind(.tileRight,       124, cmdOptShift)  // Cmd+Opt+Shift+→
        bind(.tileTop,         126, cmdOptShift)  // Cmd+Opt+Shift+↑
        bind(.tileBottom,      125, cmdOptShift)  // Cmd+Opt+Shift+↓
        bind(.tileMaximize,     36, ctrlOpt)  // Ctrl+Opt+Return
        bind(.tileCenter,        8, ctrlOpt)  // Ctrl+Opt+C
        bind(.tileTopLeft,      32, ctrlOpt)  // Ctrl+Opt+U
        bind(.tileTopRight,     34, ctrlOpt)  // Ctrl+Opt+I
        bind(.tileBottomLeft,   38, ctrlOpt)  // Ctrl+Opt+J
        bind(.tileBottomRight,  40, ctrlOpt)  // Ctrl+Opt+K
        bind(.tileDistribute,    2, ctrlOpt)  // Ctrl+Opt+D
        bind(.tileTypeGrid,     16, hyper)    // Hyper+Y
        bind(.tileLeftThird,    18, ctrlOptShift)  // Ctrl+Opt+Shift+1
        bind(.tileCenterThird,  19, ctrlOptShift)  // Ctrl+Opt+Shift+2
        bind(.tileRightThird,   20, ctrlOptShift)  // Ctrl+Opt+Shift+3
        bind(.tileOrganize,     31, ctrlOpt)  // Ctrl+Opt+O
        bind(.tileOpenCell,      9, ctrlOpt)  // Ctrl+Opt+V
        bind(.motionMode,       49, hyper)    // Hyper+Space — Hyperspace (full survey)
        bind(.inPlaceMode,       5, hyper)    // Hyper+G — in-place window tools
        bind(.chordHints,        4, hyper)    // Hyper+H — jump-letter badges on windows

        return d
    }()

    private static func storageKey(for action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue)"
    }

    private static func disabledKey(for action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue).disabled"
    }

    /// Move only persisted former defaults. User remaps, disabled actions, and
    /// the higher-priority hotkeys.json file keep their explicit choices.
    static func migrateLayerTilingArrows(in defaults: UserDefaults) {
        let migrationKey = "hotkey.tilingArrows.cmdOptShift.v1"
        guard !defaults.bool(forKey: migrationKey) else { return }
        let formerModifiers = UInt32(controlKey | optionKey)
        for action in [HotkeyAction.tileLeft, .tileRight, .tileTop, .tileBottom] {
            let key = storageKey(for: action)
            guard !defaults.bool(forKey: disabledKey(for: action)),
                  let data = defaults.data(forKey: key),
                  let binding = try? JSONDecoder().decode(KeyBinding.self, from: data),
                  let replacement = defaultBindings[action],
                  binding.keyCode == replacement.keyCode,
                  binding.carbonModifiers == formerModifiers else { continue }
            // Inherit the new default rather than saving it as a user override.
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
    }

    /// New defaults must not take a chord already assigned by the user, including
    /// file overrides. Explicit tile remaps remain under the user's control too.
    static func preserveExplicitArrowBindings(
        in bindings: inout [HotkeyAction: KeyBinding], explicitActions: Set<HotkeyAction>
    ) {
        for tile in [HotkeyAction.tileLeft, .tileRight, .tileTop, .tileBottom] {
            guard !explicitActions.contains(tile), let proposed = bindings[tile] else { continue }
            let occupied = explicitActions.contains { action in
                guard action != tile, let binding = bindings[action] else { return false }
                return binding.keyCode == proposed.keyCode && binding.carbonModifiers == proposed.carbonModifiers
            }
            if occupied { bindings.removeValue(forKey: tile) }
        }
    }

    private init() {
        // Start with defaults
        var merged = Self.defaultBindings

        // Layer 2: UserDefaults overrides
        let ud = UserDefaults.standard
        Self.migrateLayerTilingArrows(in: ud)
        var explicitActions = Set<HotkeyAction>()
        for action in HotkeyAction.allCases {
            if ud.bool(forKey: Self.disabledKey(for: action)) {
                merged.removeValue(forKey: action)
                continue
            }

            let key = Self.storageKey(for: action)
            if let data = ud.data(forKey: key),
               let binding = try? JSONDecoder().decode(KeyBinding.self, from: data) {
                merged[action] = binding
                explicitActions.insert(action)
            }
        }

        // Layer 3: ~/.lattices/hotkeys.json overrides
        let jsonPath = NSHomeDirectory() + "/.lattices/hotkeys.json"
        if let data = FileManager.default.contents(atPath: jsonPath),
           let overrides = try? JSONDecoder().decode([String: HotkeyFileOverride].self, from: data) {
            for (rawValue, override) in overrides {
                if let action = HotkeyAction(rawValue: rawValue) {
                    switch override {
                    case .binding(let binding):
                        merged[action] = binding
                        explicitActions.insert(action)
                    case .disabled:
                        merged.removeValue(forKey: action)
                    }
                }
            }
        }

        Self.preserveExplicitArrowBindings(in: &merged, explicitActions: explicitActions)

        // Retire Hyper+P → Desktop Inventory; Studio is Hyper+L. Clear the old default
        // for installs that still have it persisted without a custom remap.
        let hyper = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        if let binding = merged[.desktopInventory],
           binding.keyCode == 35,
           binding.carbonModifiers == hyper,
           !ud.bool(forKey: "hotkey.desktopInventory.hyperpRemoved.v1") {
            merged.removeValue(forKey: .desktopInventory)
            ud.set(true, forKey: Self.disabledKey(for: .desktopInventory))
            ud.set(true, forKey: "hotkey.desktopInventory.hyperpRemoved.v1")
        }

        // Retire Cmd+Shift+M (palette) and Hyper+5 (omniSearch): the unified
        // command bar (Ctrl+Opt+Space) is the single command surface. Only
        // clears bindings that still match the old defaults — custom remaps
        // are left alone.
        let cmdShift = UInt32(cmdKey | shiftKey)
        let retired: [(HotkeyAction, UInt32, UInt32, String)] = [
            (.palette, 46, cmdShift, "hotkey.palette.retired.v1"),
            (.omniSearch, 23, hyper, "hotkey.omniSearch.retired.v1"),
        ]
        for (action, keyCode, mods, flag) in retired {
            if let binding = merged[action],
               binding.keyCode == keyCode,
               binding.carbonModifiers == mods,
               !ud.bool(forKey: flag) {
                merged.removeValue(forKey: action)
                ud.set(true, forKey: Self.disabledKey(for: action))
                ud.set(true, forKey: flag)
            }
        }


        // Free Ctrl+Opt+1/2/3 for the tile-pointer matrix; vertical thirds
        // move to Ctrl+Opt+Shift+1/2/3. Only migrate installs still on the
        // old default — custom remaps are left alone.
        let ctrlOpt = UInt32(controlKey | optionKey)
        let thirdRetarget: [(HotkeyAction, UInt32, String)] = [
            (.tileLeftThird, 18, "hotkey.tileLeftThird.ctrlOptShift.v1"),
            (.tileCenterThird, 19, "hotkey.tileCenterThird.ctrlOptShift.v1"),
            (.tileRightThird, 20, "hotkey.tileRightThird.ctrlOptShift.v1"),
        ]
        for (action, keyCode, flag) in thirdRetarget {
            if let binding = merged[action],
               binding.keyCode == keyCode,
               binding.carbonModifiers == ctrlOpt,
               let replacement = Self.defaultBindings[action],
               !ud.bool(forKey: flag) {
                merged[action] = replacement
                if let data = try? JSONEncoder().encode(replacement) {
                    ud.set(data, forKey: Self.storageKey(for: action))
                }
                ud.set(true, forKey: flag)
            }
        }

        self.bindings = merged
    }

    // MARK: - Registration

    func register(action: HotkeyAction, callback: @escaping () -> Void) {
        callbacks[action] = callback
        guard let binding = bindings[action] else {
            HotkeyManager.shared.unregisterSingle(id: action.carbonID)
            return
        }
        HotkeyManager.shared.registerSingle(
            id: action.carbonID,
            keyCode: binding.keyCode,
            modifiers: binding.carbonModifiers,
            callback: instrumentedCallback(for: action, callback: callback)
        )
    }

    // MARK: - Update

    func updateBinding(for action: HotkeyAction, to binding: KeyBinding) {
        bindings[action] = binding

        // Persist to UserDefaults
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: Self.storageKey(for: action))
        }
        UserDefaults.standard.removeObject(forKey: Self.disabledKey(for: action))

        // Re-register if we have a callback
        if let callback = callbacks[action] {
            HotkeyManager.shared.registerSingle(
                id: action.carbonID,
                keyCode: binding.keyCode,
                modifiers: binding.carbonModifiers,
                callback: instrumentedCallback(for: action, callback: callback)
            )
        }
    }

    func clearBinding(for action: HotkeyAction) {
        bindings.removeValue(forKey: action)
        UserDefaults.standard.removeObject(forKey: Self.storageKey(for: action))
        UserDefaults.standard.set(true, forKey: Self.disabledKey(for: action))
        HotkeyManager.shared.unregisterSingle(id: action.carbonID)
    }

    // MARK: - Reset

    func resetBinding(for action: HotkeyAction) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey(for: action))
        UserDefaults.standard.removeObject(forKey: Self.disabledKey(for: action))

        guard let defaultBinding = Self.defaultBindings[action] else {
            bindings.removeValue(forKey: action)
            HotkeyManager.shared.unregisterSingle(id: action.carbonID)
            return
        }

        bindings[action] = defaultBinding
        if let callback = callbacks[action] {
            HotkeyManager.shared.registerSingle(
                id: action.carbonID,
                keyCode: defaultBinding.keyCode,
                modifiers: defaultBinding.carbonModifiers,
                callback: instrumentedCallback(for: action, callback: callback)
            )
        }
    }

    func resetAll() {
        for action in HotkeyAction.allCases {
            UserDefaults.standard.removeObject(forKey: Self.storageKey(for: action))
            UserDefaults.standard.removeObject(forKey: Self.disabledKey(for: action))
        }
        bindings = Self.defaultBindings

        // Re-register all with stored callbacks
        for (action, callback) in callbacks {
            guard let binding = bindings[action] else {
                HotkeyManager.shared.unregisterSingle(id: action.carbonID)
                continue
            }
            HotkeyManager.shared.registerSingle(
                id: action.carbonID,
                keyCode: binding.keyCode,
                modifiers: binding.carbonModifiers,
                callback: instrumentedCallback(for: action, callback: callback)
            )
        }
    }

    // MARK: - Conflict detection

    func conflicts(for action: HotkeyAction, with binding: KeyBinding) -> HotkeyAction? {
        for (existingAction, existingBinding) in bindings {
            if existingAction != action &&
               existingBinding.keyCode == binding.keyCode &&
               existingBinding.carbonModifiers == binding.carbonModifiers {
                return existingAction
            }
        }
        return nil
    }
}
