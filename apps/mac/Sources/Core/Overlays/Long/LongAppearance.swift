import AppKit
import SwiftUI

/// Long follows the desktop, independently of the app's deliberately dark shell.
/// AppDelegate pins NSApp.appearance, so merely inheriting it would never turn light.
@MainActor
final class LongPanel: NSPanel {
    private var appearanceObserver: NSObjectProtocol?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        refreshSystemAppearance()
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
    }

    static func appearanceName(for style: String?) -> NSAppearance.Name {
        style == "Dark" ? .darkAqua : .aqua
    }

    func refreshSystemAppearance() {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        appearance = NSAppearance(named: Self.appearanceName(for: style))
    }

    deinit {
        if let appearanceObserver { DistributedNotificationCenter.default().removeObserver(appearanceObserver) }
    }
}

/// Scoped tokens: do not change the intentionally dark palette of other overlays.
struct LongPalette {
    let scheme: ColorScheme
    var isLight: Bool { scheme == .light }
    var body: Color { isLight ? Long.lit : Long.ink }
    var face: Color { isLight ? Long.ink : Long.lit }
    var text: Color { face }
    var textDim: Color { face.opacity(0.8) }
    var textMuted: Color { face.opacity(0.65) }
    var bg: Color { body }
    var surface: Color { face.opacity(0.045) }
    var surfaceHov: Color { face.opacity(0.10) }
    var border: Color { face.opacity(0.12) }
    var borderLit: Color { face.opacity(0.22) }
    var shadowOpacity: Double { isLight ? 0.30 : 0.24 }
    var shadowRadius: CGFloat { isLight ? 5 : 3 }
    var shadowOffset: CGFloat { isLight ? 4 : 3 }
}
