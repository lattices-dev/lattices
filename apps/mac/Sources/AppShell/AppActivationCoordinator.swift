import AppKit

final class AppActivationCoordinator {
    static let shared = AppActivationCoordinator()

    private var surfaceVisibilityProviders: [(id: String, isVisible: () -> Bool)] = []

    private var closeObserver: NSObjectProtocol?

    private init() {
        // Windows closed from the title bar never call back into their
        // controller. Re-check once the close has landed, so Lattices leaves
        // ⌘Tab with its last window.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func registerSurface(id: String, isVisible: @escaping () -> Bool) {
        guard !surfaceVisibilityProviders.contains(where: { $0.id == id }) else { return }
        surfaceVisibilityProviders.append((id: id, isVisible: isVisible))
    }

    func refresh() {
        let hasVisibleWindow = surfaceVisibilityProviders.contains { provider in
            provider.isVisible()
        }
        let desired: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            if desired == .regular {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
