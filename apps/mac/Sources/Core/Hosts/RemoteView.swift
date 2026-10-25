import AppKit
import Foundation

/// Pure pieces of the remote viewer: what to capture, where a click lands on
/// the other machine, how fast to pull frames, and which key was pressed.
enum RemoteView {
    /// What a viewer shows. Frames are in the host's layout coordinates, the
    /// same space its `computer.*` input takes.
    enum Target: Hashable {
        case display(index: Int, name: String)
        case window(wid: UInt32, app: String, title: String)
        case region(CGRect)

        var params: [String: Any] {
            switch self {
            case .display(let index, _): return ["displayIndex": index]
            case .window(let wid, _, _): return ["wid": Int(wid)]
            case .region(let rect):
                return ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
            }
        }

        var label: String {
            switch self {
            case .display(let index, let name): return name.isEmpty ? "Display \(index + 1)" : name
            case .window(_, let app, let title): return title.isEmpty || title == app ? app : "\(app) · \(title)"
            case .region(let rect): return "Region \(Int(rect.width))×\(Int(rect.height))"
            }
        }

        var kind: String {
            switch self {
            case .display: return "Monitor"
            case .window: return "App"
            case .region: return "Region"
            }
        }

        var wid: UInt32? {
            if case .window(let wid, _, _) = self { return wid }
            return nil
        }
    }

    struct Display: Equatable, Identifiable {
        var index: Int
        var name: String
        var frame: CGRect
        var scale: Double
        var id: Int { index }
    }

    static func parseDisplays(_ value: Any?) -> [Display] {
        (value as? [[String: Any]] ?? []).enumerated().compactMap { offset, item in
            guard let frame = rect(item["frame"]), frame.width > 0, frame.height > 0 else { return nil }
            let index = (item["displayIndex"] as? Int) ?? (item["index"] as? Int) ?? offset
            let name = item["name"] as? String ?? item["displayId"] as? String ?? ""
            return Display(index: index, name: name, frame: frame, scale: item["scale"] as? Double ?? 1)
        }
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let f = value as? [String: Any],
              let w = (f["w"] ?? f["width"]) as? Double, let h = (f["h"] ?? f["height"]) as? Double else { return nil }
        return CGRect(x: f["x"] as? Double ?? 0, y: f["y"] as? Double ?? 0, width: w, height: h)
    }

    // MARK: - Geometry

    /// Where an image of `image` size sits when aspect-fit into `bounds`.
    static func fit(_ image: CGSize, in bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point in the view (top-left origin) as a point on the other machine,
    /// or nil when it falls in the letterbox around the picture.
    static func remotePoint(_ point: CGPoint, view: CGSize, image: CGSize, frame: CGRect) -> CGPoint? {
        let shown = fit(image, in: view)
        guard shown.width > 0, shown.contains(point) else { return nil }
        let u = (point.x - shown.minX) / shown.width
        let v = (point.y - shown.minY) / shown.height
        return CGPoint(x: (frame.minX + u * frame.width).rounded(), y: (frame.minY + v * frame.height).rounded())
    }

    /// A drag between two view points as a rect on the other machine, clamped
    /// to what is shown. Tiny drags are a click, not a region.
    static func remoteRegion(from a: CGPoint, to b: CGPoint, view: CGSize, image: CGSize, frame: CGRect, minimum: CGFloat = 24) -> CGRect? {
        let shown = fit(image, in: view)
        guard shown.width > 0 else { return nil }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, shown.minX), shown.maxX), y: min(max(p.y, shown.minY), shown.maxY))
        }
        let p = clamp(a), q = clamp(b)
        let local = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        let sx = frame.width / shown.width, sy = frame.height / shown.height
        let remote = CGRect(x: frame.minX + (local.minX - shown.minX) * sx, y: frame.minY + (local.minY - shown.minY) * sy,
                            width: local.width * sx, height: local.height * sy).integral
        return remote.width >= minimum && remote.height >= minimum ? remote : nil
    }

    // MARK: - Pacing

    struct Pace: Equatable {
        var delay: TimeInterval
        var quality: Int
    }

    /// Pull, don't push: the next frame is requested after the last one lands.
    /// Right after input the viewer goes as fast as the link allows at a lower
    /// quality; idle it settles to a calm rate and a sharper picture.
    static func pace(roundTrip: TimeInterval, sinceInput: TimeInterval) -> Pace {
        let interactive = sinceInput < 2
        let target: TimeInterval = interactive ? 1.0 / 20 : sinceInput < 15 ? 1.0 / 8 : 1.0 / 2
        let quality = interactive ? (roundTrip > 0.15 ? 45 : 60) : 75
        return Pace(delay: max(0, target - roundTrip), quality: quality)
    }

    /// Pixel width worth asking for: what the view shows on this screen, capped.
    static func requestWidth(viewWidth: CGFloat, backingScale: CGFloat, cap: Int = 2560) -> Int {
        max(320, min(cap, Int((viewWidth * max(1, backingScale)).rounded())))
    }

    // MARK: - Keys

    enum Key: Equatable {
        case text(String)
        case press(key: String, modifiers: [String])
    }

    private static let named: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "forwarddelete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Plain printable keys become text (one `typeText`); anything with a
    /// command/control/option modifier or a named key becomes a key press.
    static func key(keyCode: UInt16, characters: String?, ignoringModifiers: String?, modifiers: NSEvent.ModifierFlags) -> Key? {
        var mods: [String] = []
        if modifiers.contains(.command) { mods.append("command") }
        if modifiers.contains(.control) { mods.append("control") }
        if modifiers.contains(.option) { mods.append("option") }
        let chorded = !mods.isEmpty
        if modifiers.contains(.shift) { mods.append("shift") }
        if let name = named[keyCode] { return .press(key: name, modifiers: mods) }
        if chorded, let base = ignoringModifiers?.lowercased(), base.count == 1 {
            return .press(key: base, modifiers: mods)
        }
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
        return .text(characters)
    }
}
