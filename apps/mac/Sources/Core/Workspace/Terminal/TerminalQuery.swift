import AppKit
import Darwin

// MARK: - Data Model

struct TerminalTab {
    let app: Terminal
    let windowId: UInt32?     // CGWindowID when exposed by the terminal app
    let windowIndex: Int
    let tabIndex: Int
    let tty: String           // normalized: "ttys003"
    let isActiveTab: Bool
    let title: String
    let sessionId: String?    // iTerm2 unique ID, Ghostty terminal ID, kitty window ID
    /// The window title the terminal app reports, when it gives no CGWindowID (Ghostty).
    var windowTitle: String? = nil
}

/// One Ghostty terminal surface as its AppleScript dictionary lists it.
struct GhosttySurface: Equatable {
    let windowIndex: Int
    let windowName: String
    let tabIndex: Int          // 0-based
    let tabName: String
    let isSelectedTab: Bool
    let terminalId: String
    let title: String
    let workingDirectory: String
}

/// A TTY that descends from a terminal app, with the working directories of
/// its shells. Used to join terminal-reported surfaces, which carry a cwd but
/// no TTY, onto TTYs.
struct TerminalShell: Equatable {
    let tty: String
    let cwds: Set<String>
}

// MARK: - Query

enum TerminalQuery {

    /// Normalize TTY strings: strip "/dev/" prefix if present.
    /// iTerm2 returns "/dev/ttys003", Terminal.app and `ps` return "ttys003".
    static func normalizeTTY(_ raw: String) -> String {
        if raw.hasPrefix("/dev/") {
            return String(raw.dropFirst(5))
        }
        return raw
    }

    /// Query all running terminal emulators for tab info.
    /// Only queries apps that are currently running (won't auto-launch).
    ///
    /// Warp has no tab API, and Ghostty or kitty may not answer; their TTYs
    /// are still attributed to the app (and, where the evidence allows, a
    /// window) from the process tree in TerminalSynthesizer.
    static func queryAll() -> [TerminalTab] {
        var results: [TerminalTab] = []
        if isAppRunning("iTerm2") || isAppRunning("iTerm 2") {
            results.append(contentsOf: queryITerm2())
        }
        if isAppRunning("Terminal") {
            results.append(contentsOf: queryTerminalApp())
        }

        let ghosttyPids = runningPids(.ghostty)
        let kittyPids = runningPids(.kitty)
        if !ghosttyPids.isEmpty || !kittyPids.isEmpty {
            let table = ProcessQuery.snapshot()
            if !kittyPids.isEmpty {
                results.append(contentsOf: queryKitty(pids: kittyPids, processTable: table))
            }
            if !ghosttyPids.isEmpty {
                results.append(contentsOf: queryGhostty(pids: ghosttyPids, processTable: table))
            }
        }
        return results
    }

    // MARK: - iTerm2

    static func queryITerm2() -> [TerminalTab] {
        let script = """
        tell application "iTerm2"
            set output to ""
            set winIdx to 0
            repeat with w in windows
                set tabIdx to 0
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set output to output & (id of w) & "\t" & winIdx & "\t" & tabIdx & "\t" & (tty of s) & "\t" & (name of s) & "\t" & (unique ID of s) & linefeed
                    end repeat
                    set tabIdx to tabIdx + 1
                end repeat
                set winIdx to winIdx + 1
            end repeat
            return output
        end tell
        """

        let raw = osascript(script)
        guard !raw.isEmpty else { return [] }

        var tabs: [TerminalTab] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard cols.count >= 6 else { continue }

            let windowId = UInt32(cols[0])
            guard let winIdx = Int(cols[1]),
                  let tabIdx = Int(cols[2]) else { continue }

            let tty = normalizeTTY(String(cols[3]))
            guard tty.hasPrefix("ttys") else { continue }

            let title = String(cols[4])
            let sessionId = String(cols[5])

            tabs.append(TerminalTab(
                app: .iterm2,
                windowId: windowId,
                windowIndex: winIdx,
                tabIndex: tabIdx,
                tty: tty,
                isActiveTab: false, // iTerm2 doesn't expose this easily in a single call
                title: title,
                sessionId: sessionId
            ))
        }
        return tabs
    }

    // MARK: - Terminal.app

    static func queryTerminalApp() -> [TerminalTab] {
        let script = """
        tell application "Terminal"
            set output to ""
            set winIdx to 0
            repeat with w in windows
                set selTab to selected tab of w
                set tabIdx to 0
                repeat with t in tabs of w
                    set isSel to (t = selTab)
                    set output to output & (id of w) & "\t" & winIdx & "\t" & tabIdx & "\t" & (tty of t) & "\t" & (custom title of t) & "\t" & isSel & linefeed
                    set tabIdx to tabIdx + 1
                end repeat
                set winIdx to winIdx + 1
            end repeat
            return output
        end tell
        """

        let raw = osascript(script)
        guard !raw.isEmpty else { return [] }

        var tabs: [TerminalTab] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard cols.count >= 6 else { continue }

            let windowId = UInt32(cols[0])
            guard let winIdx = Int(cols[1]),
                  let tabIdx = Int(cols[2]) else { continue }

            let tty = normalizeTTY(String(cols[3]))
            guard tty.hasPrefix("ttys") else { continue }

            let title = String(cols[4])
            let isActive = String(cols[5]).lowercased() == "true"

            tabs.append(TerminalTab(
                app: .terminal,
                windowId: windowId,
                windowIndex: winIdx,
                tabIndex: tabIdx,
                tty: tty,
                isActiveTab: isActive,
                title: title,
                sessionId: nil
            ))
        }
        return tabs
    }

    // MARK: - Ghostty

    /// Ghostty 1.3+ has an AppleScript dictionary: windows → tabs → terminals,
    /// each terminal with a title and working directory. It gives no TTY and
    /// no CGWindowID, so surfaces join TTYs by cwd and windows by title.
    ///
    /// Scripting Ghostty needs Automation access to it. Lattices asks only
    /// when it already has that access, so this never raises a new prompt;
    /// without it Ghostty TTYs fall back to process-tree attribution.
    static func queryGhostty(pids: [Int], processTable: [Int: ProcessEntry]) -> [TerminalTab] {
        guard pids.contains(where: { canAutomateWithoutPrompt(pid: $0) }) else { return [] }

        let script = """
        tell application id "\(Terminal.ghostty.bundleId)"
            set fs to character id 31
            set rs to character id 30
            set output to ""
            set winIdx to 0
            repeat with w in windows
                set winName to name of w
                repeat with t in tabs of w
                    set tabIdx to (index of t) - 1
                    set isSel to selected of t
                    set tabName to name of t
                    repeat with s in terminals of t
                        set wd to working directory of s
                        if wd is missing value then set wd to ""
                        set output to output & winIdx & fs & tabIdx & fs & isSel & fs & (id of s) & fs & wd & fs & (name of s) & fs & tabName & fs & winName & rs
                    end repeat
                end repeat
                set winIdx to winIdx + 1
            end repeat
            return output
        end tell
        """

        let surfaces = parseGhosttySurfaces(osascript(script))
        guard !surfaces.isEmpty else { return [] }

        let shells = terminalShells(
            ownedBy: Set(pids),
            processTable: processTable,
            cwds: { ProcessQuery.batchCWD(pids: $0) }
        )
        return attributeGhostty(surfaces: surfaces, shells: shells)
    }

    /// Parse the Ghostty script output: records split by RS (0x1E), fields
    /// by US (0x1F), so titles can hold tabs and newlines.
    static func parseGhosttySurfaces(_ raw: String) -> [GhosttySurface] {
        var surfaces: [GhosttySurface] = []
        for record in raw.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let cols = record.split(separator: "\u{1F}", maxSplits: 7, omittingEmptySubsequences: false)
            guard cols.count == 8,
                  let winIdx = Int(cols[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let tabIdx = Int(cols[1]) else { continue }
            surfaces.append(GhosttySurface(
                windowIndex: winIdx,
                windowName: String(cols[7]),
                tabIndex: tabIdx,
                tabName: String(cols[6]),
                isSelectedTab: cols[2].lowercased() == "true",
                terminalId: String(cols[3]),
                title: String(cols[5]),
                workingDirectory: String(cols[4])
            ))
        }
        return surfaces
    }

    /// Join Ghostty surfaces to TTYs by working directory. A surface takes a
    /// TTY only when exactly one unclaimed shell has its cwd; surfaces whose
    /// cwd several shells share stay unattributed rather than guessed.
    static func attributeGhostty(surfaces: [GhosttySurface], shells: [TerminalShell]) -> [TerminalTab] {
        var unclaimed = shells
        var assigned: [Int: String] = [:]   // surface index → tty

        var progress = true
        while progress {
            progress = false
            for (index, surface) in surfaces.enumerated() where assigned[index] == nil {
                let cwd = normalizePath(surface.workingDirectory)
                guard !cwd.isEmpty else { continue }
                let matches = unclaimed.indices.filter { unclaimed[$0].cwds.contains(cwd) }
                // Surfaces still waiting on this cwd compete for the same shells.
                let rivals = surfaces.indices.filter {
                    assigned[$0] == nil && normalizePath(surfaces[$0].workingDirectory) == cwd
                }
                guard matches.count == 1, rivals.count == 1 else { continue }
                assigned[index] = unclaimed[matches[0]].tty
                unclaimed.remove(at: matches[0])
                progress = true
            }
        }

        return surfaces.indices.compactMap { index in
            guard let tty = assigned[index] else { return nil }
            let surface = surfaces[index]
            return TerminalTab(
                app: .ghostty,
                windowId: nil,
                windowIndex: surface.windowIndex,
                tabIndex: surface.tabIndex,
                tty: tty,
                isActiveTab: surface.isSelectedTab,
                title: surface.tabName.isEmpty ? surface.title : surface.tabName,
                sessionId: surface.terminalId,
                windowTitle: surface.windowName.isEmpty ? nil : surface.windowName
            )
        }
    }

    /// TTYs whose root process descends from one of `ownerPids`, with the
    /// cwds of their interactive shells.
    static func terminalShells(
        ownedBy ownerPids: Set<Int>,
        processTable: [Int: ProcessEntry],
        cwds resolve: ([Int]) -> [Int: String]
    ) -> [TerminalShell] {
        var byTTY: [String: [ProcessEntry]] = [:]
        for entry in processTable.values {
            let tty = normalizeTTY(entry.tty)
            guard tty.hasPrefix("ttys") else { continue }
            byTTY[tty, default: []].append(entry)
        }

        let owners = Dictionary(uniqueKeysWithValues: ownerPids.map { ($0, Terminal.ghostty) })
        var shellPidsByTTY: [String: [Int]] = [:]
        for (tty, procs) in byTTY {
            let pids = Set(procs.map(\.pid))
            let roots = procs.filter { !pids.contains($0.ppid) }
            let owned = roots.contains {
                TerminalSynthesizer.owner(ofPid: $0.pid, processTable: processTable, terminalPids: owners)?.pid != nil
            }
            guard owned else { continue }
            // Shells only: the root is often the root-owned /usr/bin/login,
            // and one unreadable pid makes lsof fail the whole batch.
            shellPidsByTTY[tty] = procs.filter { ProcessQuery.isInteractiveShell($0.comm) }.map(\.pid)
        }

        let resolved = resolve(Array(Set(shellPidsByTTY.values.flatMap { $0 })))
        return shellPidsByTTY.map { tty, pids in
            TerminalShell(tty: tty, cwds: Set(pids.compactMap { resolved[$0] }.map(normalizePath)))
        }.sorted { $0.tty < $1.tty }
    }

    private static func normalizePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            trimmed = url.path
        }
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - kitty

    /// kitty answers `kitty @ ls` over its remote-control socket when the
    /// user enabled `allow_remote_control` and `listen_on`. The socket is
    /// found from the unix sockets the kitty process holds open, so any
    /// `listen_on` path works. Without remote control this returns nothing
    /// and kitty TTYs fall back to process-tree attribution. No permission
    /// prompt is involved.
    static func queryKitty(pids: [Int], processTable: [Int: ProcessEntry]) -> [TerminalTab] {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Terminal.kitty.bundleId) else {
            return []
        }
        let kitty = appURL.appendingPathComponent("Contents/MacOS/kitty").path
        let ttyForPid: (Int) -> String? = { pid in
            guard let entry = processTable[pid] else { return nil }
            let tty = normalizeTTY(entry.tty)
            return tty.hasPrefix("ttys") ? tty : nil
        }

        var tabs: [TerminalTab] = []
        for pid in pids {
            let raw = ProcessQuery.shell(["/usr/sbin/lsof", "-a", "-p", String(pid), "-U", "-Fn"])
            for socket in parseUnixSocketPaths(raw).prefix(4) {
                let (status, output) = run(kitty, ["@", "--to", "unix:\(socket)", "ls"], timeout: 3.0)
                guard status == 0, !output.isEmpty else { continue }
                tabs.append(contentsOf: parseKittyLS(output, ttyForPid: ttyForPid))
                break
            }
        }
        return tabs
    }

    /// Socket paths from `lsof -U -Fn` output ("n/path" lines). Connected
    /// peers ("n->0x…") and unnamed sockets are skipped.
    static func parseUnixSocketPaths(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("n/") else { continue }
            let path = String(line.dropFirst())
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    /// Parse `kitty @ ls` JSON: OS windows → tabs → kitty windows (panes).
    /// Each kitty window becomes one tab entry keyed by its child's TTY;
    /// `platform_window_id` is the CGWindowID on macOS.
    static func parseKittyLS(_ json: String, ttyForPid: (Int) -> String?) -> [TerminalTab] {
        guard let data = json.data(using: .utf8),
              let osWindows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        var tabs: [TerminalTab] = []
        for (winIdx, osWindow) in osWindows.enumerated() {
            let platformId = (osWindow["platform_window_id"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
            let kittyTabs = osWindow["tabs"] as? [[String: Any]] ?? []
            for (tabIdx, kittyTab) in kittyTabs.enumerated() {
                let tabActive = (kittyTab["is_active"] as? Bool) ?? (kittyTab["is_focused"] as? Bool) ?? false
                let tabTitle = kittyTab["title"] as? String ?? ""
                for window in kittyTab["windows"] as? [[String: Any]] ?? [] {
                    guard let pid = (window["pid"] as? NSNumber)?.intValue,
                          let tty = ttyForPid(pid) else { continue }
                    let title = window["title"] as? String ?? ""
                    let windowId = (window["id"] as? NSNumber).map { String($0.intValue) }
                    tabs.append(TerminalTab(
                        app: .kitty,
                        windowId: platformId,
                        windowIndex: winIdx,
                        tabIndex: tabIdx,
                        tty: tty,
                        isActiveTab: tabActive,
                        title: title.isEmpty ? tabTitle : title,
                        sessionId: windowId
                    ))
                }
            }
        }
        return tabs
    }

    // MARK: - Helpers

    /// Check if a named app is already running (prevents AppleScript from auto-launching it).
    private static func isAppRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private static func runningPids(_ terminal: Terminal) -> [Int] {
        NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.flatMap(Terminal.from(bundleId:)) == terminal }
            .map { Int($0.processIdentifier) }
    }

    /// Whether Lattices may send Apple events to `pid` without asking the
    /// user. Never shows the Automation prompt.
    private static func canAutomateWithoutPrompt(pid: Int) -> Bool {
        var target = AEAddressDesc()
        var targetPid = pid_t(pid)
        guard AECreateDesc(typeKernelProcessID, &targetPid, MemoryLayout<pid_t>.size, &target) == noErr else {
            return false
        }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
    }

    /// Run an AppleScript and capture stdout with a short bound. These queries
    /// are explicit deep refreshes only; the normal terminal model uses
    /// Lattices' window/process/tmux state and does not script terminal apps.
    private static func osascript(_ source: String) -> String {
        run("/usr/bin/osascript", ["-e", source], timeout: 5.0).output
    }

    /// Run a command with a time bound. Stdout is drained while the command
    /// runs, so large output (kitty's JSON) cannot fill the pipe and stall it.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return (-1, "")
        }

        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if task.isRunning {
            task.terminate()
            Darwin.kill(task.processIdentifier, SIGKILL)
            _ = drained.wait(timeout: .now() + 1)
            return (-1, "")
        }

        guard drained.wait(timeout: .now() + 1) == .success else { return (-1, "") }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, text)
    }
}
