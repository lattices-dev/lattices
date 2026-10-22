import Foundation

// MARK: - Unified Output

struct TerminalInstance {
    // Join key
    let tty: String

    // Tab info (from AppleScript)
    let app: Terminal?
    let windowIndex: Int?
    let tabIndex: Int?
    let isActiveTab: Bool
    let tabTitle: String?
    let terminalSessionId: String?     // iTerm2 unique ID, Ghostty terminal ID, kitty window ID

    // Process info (from ps)
    let processes: [ProcessEntry]
    let shellPid: Int?
    let cwd: String?

    // Tmux info
    let tmuxSession: String?
    let tmuxPaneId: String?

    // Window info (from CGWindowList)
    let windowId: UInt32?
    let windowTitle: String?

    /// How `windowId` was found, or `.app` when only the terminal app (and
    /// process) that owns this TTY is known.
    var windowAttribution: TerminalWindowAttribution? = nil
    /// With `.app`: the titled windows of the owning terminal process. One of
    /// them holds this TTY; nothing says which.
    var windowCandidates: [UInt32] = []

    // Computed
    var hasClaude: Bool {
        processes.contains { $0.comm == "claude" }
    }

    var displayName: String {
        if let session = tmuxSession { return session }
        if let title = tabTitle, !title.isEmpty { return title }
        if let title = windowTitle, !title.isEmpty { return title }
        return tty
    }
}

/// The evidence that tied a TTY to a window, strongest first.
enum TerminalWindowAttribution: String {
    /// The window title carries the TTY's `[lattices:session]` tag.
    case tag
    /// The terminal app named the window (iTerm2 window ID, kitty platform window ID).
    case terminal
    /// The terminal app named the window title, and one window carries it.
    case terminalTitle = "terminal-title"
    /// The terminal app gave a front-to-back window index.
    case position
    /// The shell's cwd appears in the title of a window.
    case cwdTitle = "cwd-title"
    /// The terminal process that owns the TTY has one titled window.
    case singleWindow = "single-window"
    /// Only the owning terminal app is known; see `windowCandidates`.
    case app
}

/// The terminal app process a TTY descends from.
struct TerminalOwner: Equatable {
    let app: Terminal
    /// The GUI process that owns the windows. Nil when only an executable
    /// path inside the app bundle named the app.
    let pid: Int?
}

// MARK: - Synthesizer

enum TerminalSynthesizer {

    /// Pure-function merge: joins 5 slices by TTY into unified TerminalInstances.
    ///
    /// - Parameters:
    ///   - processTable: Full process table from ProcessQuery.snapshot()
    ///   - interesting: Filtered interesting processes
    ///   - tmuxSessions: Current tmux sessions with panes
    ///   - terminalTabs: AppleScript-enumerated tabs
    ///   - windows: CGWindowList entries
    static func synthesize(
        processTable: [Int: ProcessEntry],
        interesting: [ProcessEntry],
        tmuxSessions: [TmuxSession],
        terminalTabs: [TerminalTab],
        windows: [UInt32: WindowEntry]
    ) -> [TerminalInstance] {

        // 1. Single pass: index ALL processes by normalized TTY
        //    This avoids O(TTYs × processes) re-scans later.
        var allProcessesByTTY: [String: [ProcessEntry]] = [:]
        for entry in processTable.values {
            let tty = TerminalQuery.normalizeTTY(entry.tty)
            guard tty != "??" else { continue }
            allProcessesByTTY[tty, default: []].append(entry)
        }

        // 2. Group interesting processes by TTY (subset of above)
        var interestingByTTY: [String: [ProcessEntry]] = [:]
        for entry in interesting {
            let tty = TerminalQuery.normalizeTTY(entry.tty)
            guard tty != "??" else { continue }
            interestingByTTY[tty, default: []].append(entry)
        }

        // 3. Build tmux pane → TTY lookup
        var tmuxByTTY: [String: (session: String, paneId: String)] = [:]
        for session in tmuxSessions {
            for pane in session.panes {
                if let entry = processTable[pane.pid] {
                    let tty = TerminalQuery.normalizeTTY(entry.tty)
                    if tty != "??" {
                        tmuxByTTY[tty] = (session: session.name, paneId: pane.id)
                    }
                }
            }
        }

        // 4. Index terminal tabs by TTY
        var tabByTTY: [String: TerminalTab] = [:]
        for tab in terminalTabs {
            tabByTTY[tab.tty] = tab
        }

        // 5. Collect all known TTYs (union of all maps)
        var allTTYs = Set(allProcessesByTTY.keys)
        allTTYs.formUnion(tmuxByTTY.keys)
        allTTYs.formUnion(tabByTTY.keys)

        // 6. Build window lookup for positional matching, and the terminal
        //    app behind each window-owning pid for process-tree attribution.
        let windowsByApp = buildWindowsByApp(windows)
        let terminalPids = terminalPids(in: windows)

        // 7. For each TTY, merge all slices
        var instances: [TerminalInstance] = []
        for tty in allTTYs {
            let procs = interestingByTTY[tty] ?? []
            let tab = tabByTTY[tty]
            let tmux = tmuxByTTY[tty]

            // Shell PID: prefer the interactive shell on this TTY, then fall
            // back to the root process whose parent is not on this TTY.
            // Shells reparented to launchd (zsh prompt workers such as
            // gitstatus/p10k, which sit in "/") lose to the user's shell.
            let ttyProcs = allProcessesByTTY[tty] ?? []
            let ttyPids = Set(ttyProcs.map(\.pid))
            let shells = ttyProcs
                .filter { isInteractiveShell($0.comm) }
                .sorted { $0.pid < $1.pid }
            let shellPid = (shells.last { $0.ppid != 1 } ?? shells.last)?.pid
                ?? ttyProcs.first { !ttyPids.contains($0.ppid) }?.pid

            // CWD: deepest interesting process's cwd, or shell's cwd
            let cwd = procs.last(where: { $0.cwd != nil })?.cwd
                ?? (shellPid.flatMap { processTable[$0]?.cwd })

            // Owner: the terminal app process this TTY's root descends from.
            // tmux panes descend from the tmux server, so they have none.
            let roots = ttyProcs
                .filter { !ttyPids.contains($0.ppid) && $0.ppid != 1 }
                .sorted { $0.pid < $1.pid }
            let owner = roots.lazy.compactMap {
                Self.owner(ofPid: $0.pid, processTable: processTable, terminalPids: terminalPids)
            }.first

            // Window: try lattices tag match first, then what the terminal
            // app reported, then process-tree evidence.
            let resolution = resolveWindow(
                tmuxSession: tmux?.session,
                tab: tab,
                cwd: cwd,
                owner: owner,
                windowsByApp: windowsByApp,
                allWindows: windows
            )
            let windowMatch = resolution.window
            let app = tab?.app ?? owner?.app ?? windowMatch.flatMap { terminal(for: $0) }

            instances.append(TerminalInstance(
                tty: tty,
                app: app,
                windowIndex: tab?.windowIndex,
                tabIndex: tab?.tabIndex,
                isActiveTab: tab?.isActiveTab ?? false,
                tabTitle: tab?.title,
                terminalSessionId: tab?.sessionId,
                processes: procs,
                shellPid: shellPid,
                cwd: cwd,
                tmuxSession: tmux?.session,
                tmuxPaneId: tmux?.paneId,
                windowId: windowMatch?.wid,
                windowTitle: windowMatch?.title,
                windowAttribution: resolution.attribution,
                windowCandidates: resolution.candidates
            ))
        }

        // 8. Sort: Claude first, active tabs first, then by TTY
        instances.sort { a, b in
            if a.hasClaude != b.hasClaude { return a.hasClaude }
            if a.isActiveTab != b.isActiveTab { return a.isActiveTab }
            return a.tty < b.tty
        }

        return instances
    }

    // MARK: - Window Attribution

    struct WindowResolution: Equatable {
        var window: WindowEntry?
        var attribution: TerminalWindowAttribution?
        var candidates: [UInt32] = []

        static let none = WindowResolution(window: nil, attribution: nil)
    }

    /// Resolve a window for this TTY without terminal app scripting. Try the
    /// lattices tmux tag first, then what the terminal app reported, then the
    /// terminal process that owns the TTY. A TTY whose owner has several
    /// windows and no title evidence stays at app level: no window, and the
    /// owner's windows as candidates.
    static func resolveWindow(
        tmuxSession: String?,
        tab: TerminalTab?,
        cwd: String?,
        owner: TerminalOwner?,
        windowsByApp: [String: [WindowEntry]],
        allWindows: [UInt32: WindowEntry]
    ) -> WindowResolution {
        // Strategy 1: lattices session tag match
        if let session = tmuxSession {
            let tag = Terminal.windowTag(for: session)
            if let match = allWindows.values.first(where: { $0.title.contains(tag) }) {
                return WindowResolution(window: match, attribution: .tag)
            }
        }

        // Strategy 2: direct window ID match. iTerm2 and kitty expose the
        // same ID as CGWindowList, which is safer than positional matching
        // when multiple terminal windows share the same shell title.
        if let windowId = tab?.windowId,
           let match = allWindows[windowId] {
            return WindowResolution(window: match, attribution: .terminal)
        }

        // Strategy 3: the terminal named the window title (Ghostty). Accept
        // it only when exactly one window of that app carries it.
        if let tab, let title = tab.windowTitle, !title.isEmpty {
            let matches = allWindows.values.filter {
                terminal(for: $0) == tab.app && ($0.title == title || $0.fullTitle == title)
            }
            if matches.count == 1 {
                return WindowResolution(window: matches[0], attribution: .terminalTitle)
            }
        }

        // Strategy 4: positional match by app + window index. Only
        // Terminal.app and iTerm2 report windows front to back; Ghostty keeps
        // untitled helper windows that would shift the index.
        if let tab = tab, tab.app == .terminal || tab.app == .iterm2 {
            let appName = windowAppName(for: tab.app)
            if let appWindows = windowsByApp[appName],
               tab.windowIndex < appWindows.count {
                return WindowResolution(window: appWindows[tab.windowIndex], attribution: .position)
            }
        }

        // Strategy 5: the terminal process that owns this TTY.
        if let owner {
            return resolveOwnedWindow(owner: owner, cwd: cwd, allWindows: allWindows)
        }

        // Strategy 6: shell cwd appears in a terminal window title.
        if let cwdMatch = terminalWindowMatching(cwd: cwd, allWindows: allWindows) {
            return WindowResolution(window: cwdMatch, attribution: .cwdTitle)
        }

        return .none
    }

    /// Pick a window of the owning terminal process: the one window whose
    /// title names the cwd, or its only titled window. Otherwise return no
    /// window and the owner's windows as candidates.
    static func resolveOwnedWindow(
        owner: TerminalOwner,
        cwd: String?,
        allWindows: [UInt32: WindowEntry]
    ) -> WindowResolution {
        let owned = allWindows.values.filter { window in
            guard window.hasTitle else { return false }
            if let pid = owner.pid { return Int(window.pid) == pid }
            return terminal(for: window) == owner.app
        }
        guard !owned.isEmpty else { return .none }

        let fragments = cwdTitleFragments(cwd ?? "")
        let named = owned.filter { window in
            fragments.contains {
                titleNames(window.title, fragment: $0) || titleNames(window.fullTitle ?? "", fragment: $0)
            }
        }
        if named.count == 1 {
            return WindowResolution(window: named[0], attribution: .cwdTitle)
        }
        if owned.count == 1 {
            return WindowResolution(window: owned[0], attribution: .singleWindow)
        }
        let candidates = owned.sorted {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.wid < $1.wid
        }.map(\.wid)
        return WindowResolution(window: nil, attribution: .app, candidates: candidates)
    }

    /// Walk up the parent chain from `pid` to the terminal app process. A
    /// window-owning pid wins; an executable inside a terminal app bundle
    /// names the app when no window-owning ancestor exists.
    static func owner(
        ofPid pid: Int,
        processTable: [Int: ProcessEntry],
        terminalPids: [Int: Terminal]
    ) -> TerminalOwner? {
        var current = pid
        var byPath: Terminal?
        var visited: Set<Int> = []
        while current > 1, visited.count < 64, visited.insert(current).inserted {
            if let app = terminalPids[current] {
                return TerminalOwner(app: app, pid: current)
            }
            guard let entry = processTable[current] else { break }
            if byPath == nil { byPath = Terminal.from(executable: entry.args) }
            current = entry.ppid
        }
        return byPath.map { TerminalOwner(app: $0, pid: nil) }
    }

    /// Window-owning pids of terminal apps.
    static func terminalPids(in windows: [UInt32: WindowEntry]) -> [Int: Terminal] {
        var result: [Int: Terminal] = [:]
        for window in windows.values {
            if let app = terminal(for: window) { result[Int(window.pid)] = app }
        }
        return result
    }

    /// The title names the path `fragment` and not a longer sibling:
    /// "~/dev/lattices" names ~/dev/lattices; "~/dev/lattices-try" does not.
    static func titleNames(_ title: String, fragment: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        var searchStart = title.startIndex
        while searchStart < title.endIndex,
              let range = title.range(of: fragment, range: searchStart..<title.endIndex) {
            if range.upperBound == title.endIndex { return true }
            let next = title[range.upperBound]
            if !(next.isLetter || next.isNumber || next == "-" || next == "_" || next == ".") {
                return true
            }
            searchStart = title.index(after: range.lowerBound)
        }
        return false
    }

    // MARK: - Private Helpers

    /// Group windows by app name for positional matching.
    private static func buildWindowsByApp(_ windows: [UInt32: WindowEntry]) -> [String: [WindowEntry]] {
        var result: [String: [WindowEntry]] = [:]
        for w in windows.values {
            result[w.app, default: []].append(w)
        }
        // Terminal window indices are presented in front-to-back app order.
        // CGWindowIDs are allocation IDs, not a spatial or z-order signal, so
        // sorting by wid makes positional terminal matching drift to unrelated
        // windows as soon as older windows are still open.
        for key in result.keys {
            result[key]?.sort {
                if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                return $0.wid < $1.wid
            }
        }
        return result
    }

    private static func isInteractiveShell(_ command: String) -> Bool {
        ProcessQuery.isInteractiveShell(command)
    }

    private static func terminalWindowMatching(
        cwd: String?,
        allWindows: [UInt32: WindowEntry]
    ) -> WindowEntry? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let fragments = cwdTitleFragments(cwd)
        guard !fragments.isEmpty else { return nil }

        let matches = allWindows.values.filter { window in
            terminal(for: window) != nil &&
            fragments.contains { fragment in window.title.contains(fragment) }
        }
        return matches.sorted {
            if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen && !$1.isOnScreen }
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.wid < $1.wid
        }.first
    }

    private static func cwdTitleFragments(_ cwd: String) -> [String] {
        guard !cwd.isEmpty, cwd != "/" else { return [] }
        var fragments: [String] = [cwd]
        let home = NSHomeDirectory()
        if cwd == home {
            return []
        } else if cwd.hasPrefix(home + "/") {
            fragments.append("~" + cwd.dropFirst(home.count))
        }
        return fragments.filter { $0.count >= 5 }
    }

    private static func terminal(for window: WindowEntry) -> Terminal? {
        if let bundleId = window.bundleId, let app = Terminal.from(bundleId: bundleId) {
            return app
        }
        return Terminal.from(windowApp: window.app)
    }

    private static func windowAppName(for terminal: Terminal) -> String {
        switch terminal {
        case .iterm2: return "iTerm 2"
        default: return terminal.rawValue
        }
    }
}
