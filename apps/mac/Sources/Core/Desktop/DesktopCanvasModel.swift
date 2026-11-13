import AppKit

/// Coordinates belong to a Space, independently of the monitor's visible area.
struct DesktopCanvasModel {
    struct Item {
        let id: UInt32
        let pid: Int32
        let title: String
        var frame: CGRect
    }
    var items: [Item]
    var viewport: CGRect
    var extent: CGRect = CGRect(x: -6000, y: -6000, width: 12000, height: 12000)

    mutating func expand() {
        for item in items { extent = extent.union(item.frame.insetBy(dx: -400, dy: -400)) }
        extent = extent.union(viewport)
    }

    /// Windows whose title-bar centre belongs to this viewport are materialized.
    /// Keeping a whole native frame on its display prevents AppKit from forcing
    /// it onto a neighbouring physical monitor or making its controls unreachable.
    static func physicalFrame(_ logical: CGRect, viewport: CGRect, screen: CGRect) -> CGRect? {
        let handle = CGPoint(x: logical.midX, y: logical.minY + min(16, logical.height / 2))
        guard viewport.contains(handle) else { return nil }
        let size = CGSize(width: min(logical.width, screen.width), height: min(logical.height, screen.height))
        return CGRect(x: min(max(screen.minX + logical.minX - viewport.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(screen.minY + logical.minY - viewport.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func logicalFrame(_ physical: CGRect, viewport: CGRect, screen: CGRect) -> CGRect {
        physical.offsetBy(dx: viewport.minX - screen.minX, dy: viewport.minY - screen.minY)
    }

    enum KeyAction { case exit, work, zoomOut, zoomIn, left, right, down, up }

    /// These keys are local to Arrange; application modifier chords keep their
    /// normal meaning. The global entry/return chords are handled by the tap.
    static func keyAction(code: UInt16, flags: NSEvent.ModifierFlags) -> KeyAction? {
        guard flags.intersection([.control, .command, .option]).isEmpty else { return nil }
        switch code {
        case 53: return .exit
        case 36, 76: return .work
        case 27, 78: return .zoomOut
        case 24, 69: return .zoomIn
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    static func usesGesture(_ flags: CGEventFlags) -> Bool {
        flags.contains([.maskControl, .maskCommand]) && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
    }

    static func recoveryFrame(_ original: CGRect, displays: [CGRect]) -> CGRect {
        let handle = CGPoint(x: original.midX, y: original.minY + 16)
        guard !displays.contains(where: { $0.contains(handle) }), let display = displays.first else { return original }
        return CGRect(x: display.minX + 32, y: display.minY + 48,
                      width: min(original.width, max(120, display.width - 64)),
                      height: min(original.height, max(80, display.height - 96)))
    }
}

/// Both completions run on main. A repeated callback cannot dismiss a later
/// surface; the controller also rejects callbacks from a cancelled generation.
final class DesktopCanvasHandoff {
    enum Part: Hashable { case motion, native }
    private var completed = Set<Part>()
    private var delivered = false
    func arrive(_ part: Part) -> Bool {
        completed.insert(part)
        guard completed.count == 2, !delivered else { return false }
        delivered = true
        return true
    }
}
