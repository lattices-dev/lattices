import AppKit
import SwiftUI

/// NSWindow that strips the blue focus ring AppKit's shared field editor draws
/// around a focused text field. Lattices windows use dark, custom SwiftUI
/// content, so that ring reads as a stray little blue rectangle.
/// `.textFieldStyle(.plain)` removes the field's *own* bezel/ring but not the
/// field editor's, so we kill it here, once, for every text field hosted in the
/// window.
private final class NoFocusRingWindow: NSWindow {
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        (editor as? NSTextView)?.focusRingType = .none
        return editor
    }
}

/// Shared factory for standalone NSWindow chrome.
/// Every managed window (Screen Map, Settings, Diagnostics, etc.) uses this
/// to get consistent title bar styling, dark appearance, and positioning.
struct AppWindowShell {

    struct Config {
        var title: String
        var titleVisible: Bool = true
        var initialSize: NSSize
        var minSize: NSSize
        var maxSize: NSSize? = nil
        var miniaturizable: Bool = true
        var titlebarAppearsTransparent: Bool = false
        /// Let content fill the whole window, including under the title bar, so
        /// chrome (e.g. a tab strip) can sit in the traffic-light row instead of
        /// below a reserved title band.
        var fullSizeContent: Bool = false
    }

    /// Create a styled NSWindow hosting a SwiftUI root view.
    static func makeWindow<V: View>(config: Config, rootView: V) -> NSWindow {
        let hosting = NSHostingView(
            rootView: rootView
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        if config.miniaturizable { styleMask.insert(.miniaturizable) }
        if config.fullSizeContent { styleMask.insert(.fullSizeContentView) }

        let w = NoFocusRingWindow(
            contentRect: NSRect(origin: .zero, size: config.initialSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(origin: .zero, size: config.initialSize))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        w.contentView = container
        w.title = config.title
        w.titlebarAppearsTransparent = config.titlebarAppearsTransparent
        w.titleVisibility = config.titleVisible ? .visible : .hidden
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = config.minSize
        if let maxSize = config.maxSize {
            w.maxSize = maxSize
        }
        return w
    }

    /// Center the window on screen, nudged 8% above vertical center.
    /// Clamps to 92% screen width / 85% screen height.
    static func positionCentered(_ window: NSWindow, on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        window.setFrame(centeredFrame(size: window.frame.size, in: screen.visibleFrame), display: true)
    }

    static func centeredFrame(size: NSSize, in frame: NSRect) -> NSRect {
        let w = min(size.width, frame.width * 0.92)
        let h = min(size.height, frame.height * 0.85)
        return NSRect(x: frame.midX - w / 2, y: frame.midY - h / 2 + frame.height * 0.08, width: w, height: h)
    }

    /// Bring the window to front where the person is: the screen under the
    /// pointer and the desktop showing there. Fronting it in place can raise
    /// it on another display or switch to another desktop, out of sight.
    static func present(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if let screen = pointerScreen(), window.screen != screen {
            positionCentered(window, on: screen)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.updateActivationPolicy()
    }

    static func pointerScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
