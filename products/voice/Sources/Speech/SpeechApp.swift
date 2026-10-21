import SwiftUI
import OSLog

@main
enum SpeechEntry {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-host"),
           CommandLine.arguments.indices.contains(index + 1) {
            let capability = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            SpeechRpc.register(on: .shared)
            SpeechRuntime.start(presentHUD: false, refreshVoices: false)
            let host = SpeechServer(port: 0, capabilityURL: capability)
            host.start()
            guard host.listeningPort > 0 else { exit(1) }
            print("{\"port\":\(host.listeningPort)}")
            fflush(stdout)
            signal(SIGTERM, SIG_IGN)
            let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            shutdown.setEventHandler { host.stop(); exit(0) }
            shutdown.resume()
            withExtendedLifetime(shutdown) { RunLoop.main.run() }
            return
        }
        SpeechApp.main()
    }
}
struct SpeechApp: App {
    @NSApplicationDelegateAdaptor(SpeechAppDelegate.self) private var delegate
    @ObservedObject private var visibility = CompanionMenuBarVisibility.shared
    var body: some Scene {
        MenuBarExtra("Voice", systemImage: "waveform", isInserted: Binding(get: { visibility.isVisible }, set: { _ in })) {
            Button("Show Playback") { SpeechPlaybackHUD.shared.showFromMenu() }
            SettingsLink()
            Divider()
            Button("Quit Voice") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        Settings { SpeechControlsContent(padding: 20) }
    }
}
/// Settings content for both the Settings scene and the controls window. The
/// theme is dark-only, so it pins the color scheme and paints Palette.bg.
struct SpeechControlsContent: View {
    var padding: CGFloat = 0
    var body: some View {
        SpeechSettingsView()
            .padding(padding)
            .frame(width: 540, height: 620)
            .background(Palette.bg)
            .preferredColorScheme(.dark)
    }
}
final class SpeechAppDelegate: NSObject, NSApplicationDelegate {
    private var controls: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        SpeechVoicePreferences.migrateLegacyDefaults()
        SpeechRpc.register(on: .shared)
        SpeechRuntime.start()
        SpeechServer.shared.start()
        if !CompanionMenuBarVisibility.shared.isVisible { showControls() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls(); return true
    }
    private func showControls() {
        if controls == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SpeechControlsContent()))
            window.title = "Voice"
            // The theme is dark-only (white text on Palette.bg). Pin the window's
            // appearance and background so text stays legible in light mode.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Palette.bg)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            controls = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controls?.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { SpeechServer.shared.stop() }
}
enum SpeechEndpoints {
    static let rpcPort: UInt16 = 9397
    static var runtimeDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LATTICES_RUNTIME_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/run")
    }
    static var socketURL: URL { runtimeDirectory.appendingPathComponent("speech.sock") }
    static var tokenURL: URL { runtimeDirectory.appendingPathComponent("speech.token") }
}
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    private let logger = Logger(subsystem: "dev.lattices.Speech", category: "runtime")
    func info(_ message: String) { logger.info("\(message, privacy: .private)") }
    func warn(_ message: String) { logger.warning("\(message, privacy: .private)") }
    func error(_ message: String) { logger.error("\(message, privacy: .private)") }
}
