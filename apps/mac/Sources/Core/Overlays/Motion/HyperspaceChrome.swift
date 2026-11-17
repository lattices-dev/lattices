import AppKit
import SwiftUI

/// One material for Hyperspace's tools, window previews and overview controls.
/// Capture, selection and placement remain owned by the existing components.
enum HyperspaceChrome {
    static let ivory = NSColor(calibratedRed: 0.937, green: 0.957, blue: 1.0, alpha: 1)
    /// Type on the graphite surface (fab's ink / label greys).
    static let ink = Color(nsColor: Lens.srgb(0xededee))
    static let secondary = Color(nsColor: Lens.srgb(0x8b8c91))
    /// Dark ink for the few light chips (keycaps, white capsules) that sit on windows.
    static let inkColor = NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.19, alpha: 1)
    static let paperInk = Color(nsColor: inkColor)
    /// Selection and the target ring, the only hue in the chrome.
    /// Follows the HUD tone: amber on graphite (see `Lens.coral`).
    static var accentColor: NSColor { Lens.coral }
    static var accent: Color { Color(nsColor: accentColor) }
    // Existing preview and overview callers share this compatibility name.
    static var sage: Color { accent }
    /// A light hairline and a faint well, read against graphite.
    static let border = Color.white.opacity(0.10)
    static let well = Color.white.opacity(0.06)
}

enum HyperspaceTool: String, CaseIterable {
    case layers = "Layers", grid = "Grid", map = "Map"
}

/// Overview cards and previews use the same native optical surface as the HUD.
final class HyperspaceGlassView: NSView {
    private let glass: LensGlassView

    /// The compatibility argument no longer paints over the system material.
    init(frame: NSRect, cornerRadius: CGFloat = 14, tintOpacity: CGFloat = 0.34) {
        glass = LensGlassView(frame: CGRect(origin: .zero, size: frame.size), radius: cornerRadius, graphite: true)
        super.init(frame: frame)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    func update(cornerRadius: CGFloat, tintOpacity: CGFloat) {
        glass.update(cornerRadius: cornerRadius)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct HyperspaceGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    var tintOpacity: CGFloat = 0.34

    func makeNSView(context: Context) -> HyperspaceGlassView {
        HyperspaceGlassView(frame: .zero, cornerRadius: cornerRadius, tintOpacity: tintOpacity)
    }

    func updateNSView(_ nsView: HyperspaceGlassView, context: Context) {
        nsView.update(cornerRadius: cornerRadius, tintOpacity: tintOpacity)
    }
}

/// The existing wallpaper cache supplies a still for this display. Nothing
/// changes the user's wallpaper, switches a Space, or captures the desktop.
private final class HyperspaceBackdropView: NSView {
    private let wallpaper = CALayer()
    private let veil = CALayer()
    private var load: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = HyperspaceChrome.ivory.cgColor
        wallpaper.contentsGravity = .resizeAspectFill
        wallpaper.masksToBounds = true
        layer?.addSublayer(wallpaper)
        veil.backgroundColor = NSColor.white.withAlphaComponent(0.34).cgColor
        layer?.addSublayer(veil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        wallpaper.frame = bounds
        veil.frame = bounds
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        load?.cancel()
        guard let screen = window?.screen else { return }
        load = SpaceCanvasWallpaper.shared.load(for: screen) { [weak self] image in
            self?.wallpaper.contents = image?.cgImage
        }
    }
}

struct HyperspaceDesktopBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HyperspaceBackdropView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
