import AppKit

enum Terminal: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm2 = "iTerm2"
    case warp = "Warp"
    case ghostty = "Ghostty"
    case kitty = "Kitty"
    case alacritty = "Alacritty"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .terminal:  return "com.apple.Terminal"
        case .iterm2:    return "com.googlecode.iterm2"
        case .warp:      return "dev.warp.Warp-Stable"
        case .ghostty:   return "com.mitchellh.ghostty"
        case .kitty:     return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        }
    }

    /// The terminal a bundle ID belongs to. Warp ships Stable, Preview and
    /// other channels under `dev.warp.Warp-*`.
    static func from(bundleId: String) -> Terminal? {
        if bundleId.hasPrefix("dev.warp.Warp") { return .warp }
        if bundleId.hasPrefix("com.mitchellh.ghostty") { return .ghostty }
        return allCases.first { $0.bundleId == bundleId }
    }

    /// The terminal a CGWindowList owner name belongs to. Owner names are
    /// the apps' display names, which do not always match our raw values
    /// ("kitty", "iTerm 2").
    static func from(windowApp app: String) -> Terminal? {
        switch app.lowercased() {
        case "terminal": return .terminal
        case "iterm2", "iterm 2", "iterm": return .iterm2
        case "warp", "warppreview", "warp preview": return .warp
        case "ghostty": return .ghostty
        case "kitty": return .kitty
        case "alacritty": return .alacritty
        default: return nil
        }
    }

    /// The terminal whose app bundle holds the executable at the start of a
    /// process command line, e.g. "/Applications/Ghostty.app/Contents/MacOS/ghostty".
    static func from(executable args: String) -> Terminal? {
        guard let marker = args.range(of: ".app/Contents/MacOS/") else { return nil }
        let bundlePath = args[args.startIndex..<marker.lowerBound]
        let name = bundlePath.split(separator: "/").last.map(String.init) ?? ""
        return from(windowApp: name)
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    static var installed: [Terminal] {
        allCases.filter(\.isInstalled)
    }

    /// Launch a command in this terminal
    func launch(command: String, in directory: String) {
        // Use single quotes for the shell command to avoid AppleScript escaping issues
        let dir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = command.replacingOccurrences(of: "'", with: "'\\''")
        let fullCmd = "cd '\(dir)' && \(cmd)"

        switch self {
        case .terminal:
            runOsascript(
                "tell application \"Terminal\"",
                "activate",
                "do script \"\(fullCmd)\"",
                "end tell"
            )

        case .iterm2:
            runOsascript(
                "tell application \"iTerm2\"",
                "activate",
                "set newWindow to (create window with default profile)",
                "tell current session of newWindow",
                "write text \"\(fullCmd)\"",
                "end tell",
                "end tell"
            )

        case .warp:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "Warp", directory]
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                runOsascript(
                    "tell application \"System Events\"",
                    "tell process \"Warp\"",
                    "keystroke \"\(cmd)\"",
                    "keystroke return",
                    "end tell",
                    "end tell"
                )
            }

        case .ghostty:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "Ghostty"]
            task.environment = ["GHOSTTY_SHELL_COMMAND": fullCmd]
            try? task.run()

        case .kitty:
            if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let kittyBin = appUrl.appendingPathComponent("Contents/MacOS/kitty").path
                let task = Process()
                task.executableURL = URL(fileURLWithPath: kittyBin)
                task.arguments = ["--single-instance", "--directory", directory, "sh", "-c", command]
                try? task.run()
            }

        case .alacritty:
            if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let bin = appUrl.appendingPathComponent("Contents/MacOS/alacritty").path
                let task = Process()
                task.executableURL = URL(fileURLWithPath: bin)
                task.arguments = ["--working-directory", directory, "-e", "sh", "-c", command]
                try? task.run()
            }
        }
    }

    /// Launch a command in a new tab of the current terminal window
    func launchTab(command: String, in directory: String, tabName: String? = nil) {
        let dir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = command.replacingOccurrences(of: "'", with: "'\\''")
        let fullCmd = "cd '\(dir)' && \(cmd)"

        switch self {
        case .iterm2:
            var lines = [
                "tell application \"iTerm2\"",
                "activate",
                "if (count of windows) = 0 then",
                "  create window with default profile",
                "else",
                "  tell current window to create tab with default profile",
                "end if",
                "tell current session of current tab of current window",
                "  write text \"\(fullCmd)\"",
            ]
            if let name = tabName {
                let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
                lines.append("  set name to \"\(escaped)\"")
            }
            lines.append("end tell")
            lines.append("end tell")
            runOsascriptLines(lines)

        case .terminal:
            var lines = [
                "tell application \"Terminal\"",
                "activate",
                "if (count of windows) = 0 then",
                "  do script \"\(fullCmd)\"",
                "else",
                "  do script \"\(fullCmd)\" in front window",
                "end if",
            ]
            if let name = tabName {
                let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
                lines.append("set custom title of selected tab of front window to \"\(escaped)\"")
            }
            lines.append("end tell")
            runOsascriptLines(lines)

        default:
            // Terminals without AppleScript tab support: fall back to new window
            launch(command: command, in: directory)
        }
    }

    /// Rename the current/frontmost tab in this terminal
    func nameTab(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        switch self {
        case .iterm2:
            runOsascript(
                "tell application \"iTerm2\"",
                "tell current session of current tab of current window",
                "set name to \"\(escaped)\"",
                "end tell",
                "end tell"
            )
        case .terminal:
            runOsascript(
                "tell application \"Terminal\"",
                "set custom title of selected tab of front window to \"\(escaped)\"",
                "end tell"
            )
        default:
            break
        }
    }

    /// The tag we put in the terminal window title via tmux set-titles
    static func windowTag(for session: String) -> String {
        "[lattices:\(session)]"
    }

    /// Find and focus the existing terminal window by its [lattices:name] tag, or open a new attach
    func focusOrAttach(session: String) {
        let tag = Terminal.windowTag(for: session)

        switch self {
        case .terminal:
            runOsascript(
                "tell application \"Terminal\"",
                "activate",
                "set found to false",
                "repeat with w in windows",
                "  if name of w contains \"\(tag)\" then",
                "    set index of w to 1",
                "    set found to true",
                "    exit repeat",
                "  end if",
                "end repeat",
                "if not found then do script \"tmux attach -t \(session)\"",
                "end tell"
            )

        case .iterm2:
            // Search through all sessions in all tabs of all windows
            runOsascript(
                "tell application \"iTerm2\"",
                "activate",
                "set found to false",
                "repeat with w in windows",
                "  repeat with t in tabs of w",
                "    repeat with s in sessions of t",
                "      if name of s contains \"\(tag)\" then",
                "        select w",
                "        tell w to set current tab to t",
                "        set found to true",
                "        exit repeat",
                "      end if",
                "    end repeat",
                "    if found then exit repeat",
                "  end repeat",
                "  if found then exit repeat",
                "end repeat",
                "if not found then",
                "  if (count of windows) = 0 then",
                "    create window with default profile",
                "  else",
                "    tell current window to create tab with default profile",
                "  end if",
                "  tell current session of current tab of current window",
                "    write text \"tmux attach -t \(session)\"",
                "  end tell",
                "end if",
                "end tell"
            )

        default:
            // For terminals without good AppleScript support, just activate and attach
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", rawValue]
            try? task.run()
        }
    }
}

/// Run an AppleScript by joining lines into a single -e script block
private func runOsascript(_ lines: String...) {
    runOsascriptLines(lines)
}

/// Run an AppleScript from an array of lines
private func runOsascriptLines(_ lines: [String]) {
    let script = lines.joined(separator: "\n")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
}
