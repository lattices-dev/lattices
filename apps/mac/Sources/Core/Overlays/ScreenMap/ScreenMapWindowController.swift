import AppKit
import SwiftUI

/// Manages the unified app window (Home + Layout + Search + Settings).
/// Singleton with show/close/toggle, plus showPage() for navigation.
final class ScreenMapWindowController: ObservableObject {
    static let shared = ScreenMapWindowController()

    private var window: NSWindow?
    private var controller: ScreenMapController?
    @Published var activePage: AppPage = .home

    var isVisible: Bool { window?.isVisible ?? false }

    /// Exposed for event monitor filtering
    var nsWindow: NSWindow? { window }

    private var workspaceWindowSize: NSSize {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        var bbox = CGRect.zero
        for (i, screen) in screens.enumerated() {
            let cgY = primaryHeight - screen.frame.maxY
            let cgRect = CGRect(x: screen.frame.origin.x, y: cgY,
                                width: screen.frame.width, height: screen.frame.height)
            bbox = i == 0 ? cgRect : bbox.union(cgRect)
        }
        let mainVisibleSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let aspectRatio = bbox.width / max(bbox.height, 1)
        let maxWidth = max(900, min(1760, mainVisibleSize.width * 0.92))
        let width = min(max(1080, CGFloat(720) * aspectRatio + 220), maxWidth)
        let height = min(max(680, mainVisibleSize.height * 0.78), 760)
        return NSSize(width: width, height: height)
    }

    private func preferredWindowSize(for page: AppPage) -> NSSize {
        switch page {
        case .home:
            return NSSize(width: 980, height: 720)
        case .settings, .companionSettings, .docs, .activity, .runs:
            return NSSize(width: 900, height: 640)
        case .overview, .assistant, .layers, .machines:
            return workspaceWindowSize
        }
    }

    func toggle() {
        if let w = window, w.isVisible {
            close()
        } else {
            show()
        }
    }

    /// Show the window on the current page (defaults to Home).
    func show() {
        if let existing = window {
            if activePage == .overview {
                controller?.enter()
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let ctrl = ScreenMapController()
        ctrl.onDismiss = { [weak self] in
            self?.close()
        }
        if activePage == .overview {
            ctrl.enter()
        }

        let view = AppShellView(controller: ctrl)
        let initialSize = preferredWindowSize(for: activePage)

        let w = AppWindowShell.makeWindow(
            config: .init(
                title: "Lattices",
                titleVisible: false,
                initialSize: initialSize,
                minSize: NSSize(width: 600, height: 400),
                titlebarAppearsTransparent: true,
                fullSizeContent: true
            ),
            rootView: view
        )
        AppWindowShell.positionCentered(w)
        AppWindowShell.present(w)

        self.window = w
        self.controller = ctrl
    }

    /// Navigate to a specific page, opening the window if needed.
    func showPage(_ page: AppPage) {
        activePage = page
        show()
    }

    func showAssistant() {
        WorkspaceAssistantSession.shared.prepareForDisplay()
        showPage(.assistant)
    }

    func showScreenMapOverview() {
        activePage = .overview
        show()
        DispatchQueue.main.async { [weak self] in
            self?.controller?.focusViewportPreset(.overview)
        }
    }

    /// Open screen map focused on a specific window.
    func showWindow(wid: UInt32) {
        activePage = .overview
        show()

        // Avoid overlapping the command bar — nudge screen map below it
        if let w = window, let voicePanel = UnifiedCommandBarWindow.shared.panel, voicePanel.isVisible {
            let voiceBottom = voicePanel.frame.minY
            let mapFrame = w.frame
            if mapFrame.maxY > voiceBottom - 10 {
                // Position just below the voice panel
                let newY = voiceBottom - mapFrame.height - 16
                w.setFrameOrigin(NSPoint(x: mapFrame.origin.x, y: max(newY, 40)))
            }
        }

        // Select after a brief delay so the controller has time to populate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.controller?.selectSingle(wid)
        }
    }

    func close() {
        controller?.endPreview()
        window?.orderOut(nil)
        window = nil
        controller = nil
        activePage = .home
        AppDelegate.updateActivationPolicy()
    }
}
