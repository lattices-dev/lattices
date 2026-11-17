import AppKit

/// Applets run on a stock Mac and can be placed on the Desktop or dragged into
/// the Dock. No development toolchain is needed when a user exports one.
struct ApplicationShortcutExporter {
    func export(_ shortcut: ApplicationShortcut, to destination: URL) async throws {
        try shortcut.validate()
        guard destination.isFileURL, destination.pathExtension.lowercased() == "app" else {
            throw ApplicationShortcutError.invalidTarget("Save the shortcut as an application (.app).")
        }
        let iconFiles = await MainActor.run { Self.iconFiles(for: shortcut) }
        try await Task.detached(priority: .userInitiated) {
            try Self.build(shortcut, at: destination, iconFiles: iconFiles)
        }.value
    }

    @MainActor
    private static func iconFiles(for shortcut: ApplicationShortcut) -> [String: Data] {
        guard let identifier = shortcut.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return [:] }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        var files: [String: Data] = [:]
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return [:] }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                          operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else { return [:] }
                files["icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"] = png
            }
        }
        return files
    }

    private static func build(_ shortcut: ApplicationShortcut, at destination: URL, iconFiles: [String: Data]) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw ApplicationShortcutError.existingDestination }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".lattices-shortcut-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let appURL = staging.appendingPathComponent("Shortcut.app")
        // The only interpolation into executable source is a typed UUID.
        let script = "open location \"\(shortcut.url.absoluteString)\""
        try run("/usr/bin/osacompile", ["-o", appURL.path, "-e", script])

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String,
              executable == URL(fileURLWithPath: executable).lastPathComponent else {
            throw ApplicationShortcutError.invalidApplication
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard manager.isExecutableFile(atPath: executableURL.path) else { throw ApplicationShortcutError.invalidApplication }
        plist["CFBundleIdentifier"] = "dev.lattices.shortcut.\(shortcut.id.uuidString.lowercased())"
        plist["CFBundleDisplayName"] = shortcut.name
        plist["CFBundleName"] = shortcut.name
        plist["CFBundleShortVersionString"] = "1.0"
        plist["CFBundleVersion"] = "1"
        plist["LSUIElement"] = true

        if !iconFiles.isEmpty {
            let iconset = staging.appendingPathComponent("Shortcut.iconset")
            try manager.createDirectory(at: iconset, withIntermediateDirectories: false)
            for (name, data) in iconFiles { try data.write(to: iconset.appendingPathComponent(name)) }
            let iconURL = appURL.appendingPathComponent("Contents/Resources/Shortcut.icns")
            try run("/usr/bin/iconutil", ["-c", "icns", "-o", iconURL.path, iconset.path])
            plist["CFBundleIconFile"] = "Shortcut.icns"
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", appURL.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", appURL.path])
        // moveItem refuses an existing destination, including a destination
        // that appeared while the applet was compiling.
        try manager.moveItem(at: appURL, to: destination)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ApplicationShortcutError.toolFailed("Could not create the shortcut: \(detail.isEmpty ? URL(fileURLWithPath: executable).lastPathComponent : detail)")
        }
    }
}
