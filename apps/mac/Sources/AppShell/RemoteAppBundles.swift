import AppKit
import HudsonObservability

/// A saved remote app as an app of its own, so Cmd-Tab, the Dock and
/// Spotlight list it like any other. Each is a small bundle in
/// ~/Applications/Lattices whose executable is a clone of Lattices': it
/// starts in remote-app mode (RemoteAppShell) when its Info.plist names a
/// definition. A clone, not a symlink, because a symlinked executable takes
/// the real bundle as Bundle.main; on APFS the clone costs no space.
enum RemoteAppBundles {
    /// Names the definition a bundle opens; its presence selects remote-app mode.
    static let definitionKey = "LatticesRemoteApp"
    /// The Lattices executable a bundle was cloned from, to rebuild when it changes.
    private static let sourceKey = "LatticesRemoteAppSource"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Lattices", isDirectory: true)
    }

    /// The definition this process opens, when it is one of these bundles.
    static var currentDefinition: String? {
        Bundle.main.object(forInfoDictionaryKey: definitionKey) as? String
    }

    static func bundleID(_ id: String) -> String {
        // Bundle ids take letters, digits, - and . only.
        "dev.lattices.remote." + id.replacingOccurrences(of: "_", with: "-")
    }

    static func displayName(_ definition: RemoteAppDefinition) -> String {
        "\(definition.name) — \(definition.host)"
    }

    /// The installed bundle for `id`, whatever its file name: a rename leaves the old name.
    static func installed(_ id: String, in directory: URL = directory) -> URL? {
        let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return apps.first { url in
            url.pathExtension == "app" &&
                (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?[definitionKey] as? String) == id
        }
    }

    /// Not "Lattices": the app's tools find and stop it with `pgrep -x Lattices`.
    static let executableName = "LatticesRemoteApp"

    /// Builds or rebuilds the bundle for `definition`. Only the main app
    /// builds bundles, since it is the one whose executable gets cloned.
    @discardableResult
    static func install(_ definition: RemoteAppDefinition, in directory: URL = directory) throws -> URL {
        guard currentDefinition == nil, let executable = Bundle.main.executableURL else { throw Failure.notMain }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = displayName(definition).replacingOccurrences(of: "/", with: "-")
        let target = directory.appendingPathComponent("\(name).app", isDirectory: true)

        let staging = fm.temporaryDirectory.appendingPathComponent("lattices-remote-\(UUID().uuidString)/\(name).app", isDirectory: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        // FileManager clones on APFS.
        try fm.copyItem(at: executable, to: contents.appendingPathComponent("MacOS/\(executableName)"))

        var plist: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleID(definition.id),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "1.0",
            "CFBundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "1",
            "LSMinimumSystemVersion": Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") ?? "26.0",
            "NSHighResolutionCapable": true,
            definitionKey: definition.id,
            sourceKey: sourceStamp(executable),
        ]
        plist.merge(try icon(for: definition.app, into: resources)) { $1 }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        try sign(staging)

        if let previous = installed(definition.id, in: directory), previous != target { try? fm.removeItem(at: previous) }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        LSRegisterURL(target as CFURL, true)
        return target
    }

    /// Rebuilds bundles cloned from an older Lattices and adds any a
    /// definition lacks, e.g. one an agent wrote straight to ~/.lattices/apps.
    static func refresh() {
        guard currentDefinition == nil, let executable = Bundle.main.executableURL else { return }
        let stamp = sourceStamp(executable)
        for definition in RemoteAppDefinitions.all() {
            if let url = installed(definition.id),
               let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               info[sourceKey] as? String == stamp, info["CFBundleExecutable"] as? String == executableName,
               url.lastPathComponent == "\(displayName(definition).replacingOccurrences(of: "/", with: "-")).app" { continue }
            do { try install(definition) }
            catch { DiagnosticLog.shared.warn("RemoteApp: could not build the app for \(definition.id): \(error.localizedDescription)") }
        }
    }

    static func uninstall(_ id: String) {
        running(id).forEach { $0.terminate() }
        if let url = installed(id) { try? FileManager.default.removeItem(at: url) }
    }

    static func running(_ id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(id))
    }

    /// Launches or activates the bundle for `id` and waits for its window.
    /// The ledger entry the bundle writes for its process carries the host's
    /// wid and display.
    static func open(_ id: String) async throws -> [String: Any] {
        guard let definition = RemoteAppDefinitions.get(id) else { throw RemoteAppWindows.Failure.noDefinition(id) }
        let url = try installed(id) ?? install(definition)
        let wasRunning = !running(id).isEmpty
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let pid = app.processIdentifier
        let title = displayName(definition)
        for _ in 0..<150 {
            if let window = window(pid: pid, title: title),
               let entry = RemoteAppLedger.entries().first(where: { $0.pid == pid }) {
                return ["ok": true, "wid": entry.wid, "display": entry.display, "window": window, "pid": Int(pid), "reused": wasRunning]
            }
            if app.isTerminated { throw RemoteAppWindows.Failure.host("\(title) quit before its window opened; see ~/.lattices/lattices.log") }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RemoteAppWindows.Failure.host("\(title) did not open a window")
    }

    /// The window number of `pid`'s window titled `title`.
    static func window(pid: pid_t, title: String) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.first { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && $0[kCGWindowName as String] as? String == title }?[kCGWindowNumber as String] as? Int
    }

    enum Failure: LocalizedError {
        case notMain, sign(String)
        var errorDescription: String? {
            switch self {
            case .notMain: "Only Lattices itself builds remote app bundles"
            case .sign(let message): "codesign failed: \(message)"
            }
        }
    }

    // MARK: Helpers

    private static func sourceStamp(_ executable: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(modified))"
    }

    /// The icon of a local app with the same name (Spotify here for Spotify
    /// there), else Lattices'. Returns the Info.plist keys that name it.
    /// The app's own icon with a Lattices badge in its corner, so it reads as
    /// the app reached through Lattices rather than one installed here.
    private static func icon(for app: String, into resources: URL) throws -> [String: Any] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let local = roots.map { URL(fileURLWithPath: $0).appendingPathComponent("\(app).app") }
            .first { fm.fileExists(atPath: $0.path) }
        let lattices = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let base = local.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? lattices
        let badge = local == nil ? nil : lattices

        let url = resources.appendingPathComponent("AppIcon.icns")
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.apple.icns" as CFString, sizes.count, nil) else { return [:] }
        for size in sizes {
            if let image = badged(base, badge: badge, size: size) { CGImageDestinationAddImage(destination, image, nil) }
        }
        guard CGImageDestinationFinalize(destination) else { return [:] }
        return ["CFBundleIconFile": "AppIcon"]
    }

    private static func badged(_ base: NSImage, badge: NSImage?, size: Int) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let side = CGFloat(size)
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        base.draw(in: canvas)
        if let badge {
            // Icons carry the macOS grid's empty margin; badge the visible
            // tile, drawing the Lattices tile without its own margin.
            let tile = visible(base).map { CGRect(x: $0.minX * side, y: $0.minY * side, width: $0.width * side, height: $0.height * side) } ?? canvas
            let mark = visible(badge) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let width = tile.width * 0.44
            let height = width * mark.height / max(mark.width, 0.01)
            let rect = CGRect(x: tile.maxX - width, y: tile.minY, width: width, height: height)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = side * 0.015
            shadow.shadowOffset = NSSize(width: 0, height: -side * 0.006)
            shadow.set()
            let full = CGRect(x: rect.minX - mark.minX / mark.width * rect.width,
                              y: rect.minY - mark.minY / mark.height * rect.height,
                              width: rect.width / mark.width, height: rect.height / mark.height)
            badge.draw(in: full)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    /// Where an icon is opaque, as a fraction of its canvas, bottom-left origin.
    private static func visible(_ image: NSImage) -> CGRect? {
        let side = 256
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // colorAt's rows run top-down; flip to the drawing origin.
        let s = CGFloat(side)
        return CGRect(x: CGFloat(minX) / s, y: (s - CGFloat(maxY + 1)) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    /// Ad hoc: the cloned signature names Lattices' Info.plist and resources,
    /// and an invalid signature is killed at launch.
    private static func sign(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.sign(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "status \(process.terminationStatus)")
        }
    }
}

/// The whole app when this process is a remote app bundle: one window, a
/// Dock icon, and a minimal menu. Closing the window quits; quitting returns
/// the app to its host first.
@MainActor
final class RemoteAppShell: NSObject, NSApplicationDelegate {
    private let id: String

    init(id: String) { self.id = id }

    static func run(id: String) -> Never {
        let app = NSApplication.shared
        let delegate = RemoteAppShell(id: id)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HudLoggerSinks.install(LatticesLogDiskSink.shared)
        DiagnosticLog.shared.info("RemoteApp: \(id) started as its own app (pid \(ProcessInfo.processInfo.processIdentifier))")
        NSApp.mainMenu = menu()
        openWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !RemoteAppWindows.shared.hasOpenWindows { openWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await RemoteAppWindows.shared.closeAll(); await RemoteAppWindows.shared.settle() }
                group.addTask { try? await Task.sleep(for: .seconds(4)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func openWindow() {
        Task { @MainActor in
            do {
                try await RemoteAppWindows.shared.open(definition: id)
            } catch {
                DiagnosticLog.shared.warn("RemoteApp: \(id) could not open: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Could not open \(RemoteAppDefinitions.get(id).map(RemoteAppBundles.displayName) ?? id)"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    private func menu() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fullScreen = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return main
    }
}
