import CoreGraphics
import Foundation

/// Mac keystrokes as visit messages: plain typing goes as `text` (what the
/// Mac's layout produced), anything with ⌘ or ⌃, and keys that don't type,
/// go as `key` with an XKB keysym name and modifiers. ⌘ is sent as super.
enum VisitKeys {
    /// The summon chord: ⌃⌥⌘ Home (fn ← on a Mac keyboard).
    static func isSummon(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 115 && flags.contains([.maskControl, .maskAlternate, .maskCommand])
    }

    /// Fab's hold-to-talk key, from `voice.holdKey` in ~/.fab/settings.json:
    /// fn by default, -1 when Fab isn't set up or talk is off.
    static func fabHoldKey() -> Int64 {
        let path = NSHomeDirectory() + "/.fab/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return -1 }
        let voice = settings["voice"] as? [String: Any] ?? [:]
        if voice["holdFn"] as? Bool == false { return -1 }
        let codes: [String: Int64] = ["fn": 63, "rightOption": 61, "rightCommand": 54, "rightControl": 62]
        return codes[voice["holdKey"] as? String ?? "fn"] ?? -1
    }

    static func message(keyCode: Int64, flags: CGEventFlags, typed: String) -> [String: Any]? {
        let chord = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if !chord, special[keyCode] == nil, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            return ["t": "text", "text": typed]
        }
        guard let key = special[keyCode] ?? plain[keyCode] else { return nil }
        var mods: [String] = []
        if flags.contains(.maskControl) { mods.append("ctrl") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskAlternate) { mods.append("alt") }
        if flags.contains(.maskCommand) { mods.append("super") }
        return ["t": "key", "key": key, "mods": mods]
    }

    /// Keys that don't type a character.
    static let special: [Int64: String] = [
        36: "Return", 76: "KP_Enter", 48: "Tab", 51: "BackSpace", 53: "Escape", 117: "Delete",
        49: "space", 115: "Home", 119: "End", 116: "Prior", 121: "Next",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// ANSI positions, for chords: ⌘C is super+c whatever the layout types.
    static let plain: [Int64: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t",
        32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "minus", 24: "equal", 33: "bracketleft", 30: "bracketright", 42: "backslash",
        41: "semicolon", 39: "apostrophe", 50: "grave", 43: "comma", 47: "period", 44: "slash",
        49: "space",
    ]
}
