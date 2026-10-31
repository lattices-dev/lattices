import AppKit
import SwiftUI

@main
struct LatticesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Lattices is an LSUIElement app whose real UI is AppKit-driven (the menu
        // bar item plus the unified app window in `ScreenMapWindowController`).
        // SwiftUI still requires a `Scene`, and macOS binds the standard Settings
        // command (⌘,) and the app-menu "Settings…" item to a `Settings` scene.
        //
        // Previously this scene hosted `SettingsContentView` directly, so ⌘,/the
        // menu opened a *detached* "Lattices Settings" window — just the settings
        // sub-sidebar, with none of the primary app shell or navigation rail. We
        // now do two things so Settings always renders inside the unified shell:
        //
        //   1. Replace the `.appSettings` command group so ⌘,/the menu route
        //      through `SettingsWindowController` (→ the Settings *page* inside
        //      `AppShellView`, primary rail intact).
        //   2. Keep the scene content as a redirect that immediately closes its
        //      throwaway window and routes — a safety net in case anything else
        //      ever opens the scene (e.g. `SettingsLink`/`openSettings`).
        Settings {
            SettingsSceneRedirect()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Update Lattices…") {
                    AppUpdater.shared.promptForUpdate()
                }
                .disabled(!AppUpdater.shared.canUpdate)

                Divider()
            }

            // The rail's pages in the View menu, ⌘1 down the rail, so every page
            // is reachable from the keyboard and through the menu bar's
            // accessibility tree.
            CommandGroup(before: .sidebar) {
                ForEach(Array(AppPage.primaryTabs.enumerated()), id: \.element) { index, page in
                    Button(page.label) {
                        ScreenMapWindowController.shared.showPage(page)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
            }
        }
    }
}

/// Zero-size bridge hosted by the SwiftUI `Settings` scene. If macOS ever opens
/// the standard Settings window, this view grabs its host `NSWindow`, closes it
/// before it can become a visible detached island, and routes Settings into the
/// unified Lattices app shell (with the primary rail) instead.
private struct SettingsSceneRedirect: View {
    @State private var hostWindow: NSWindow?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(WindowGrabber { hostWindow = $0 })
            .onAppear { redirect() }
    }

    private func redirect() {
        DispatchQueue.main.async {
            (hostWindow ?? NSApp.keyWindow)?.close()
            SettingsWindowController.shared.show()
        }
    }
}

/// Resolves the `NSWindow` hosting a SwiftUI view so callers can act on it.
private struct WindowGrabber: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
