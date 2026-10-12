import AppKit
import Combine
import Foundation

// MARK: - Result Types

enum OmniResultKind: String {
    case window
    case project
    case app
    case session
    case layer
    case group
    case action
    case process
    case ocrContent
}

struct OmniResult: Identifiable {
    let id = UUID()
    let kind: OmniResultKind
    let title: String
    let subtitle: String
    let icon: String
    let score: Int           // higher = better match
    let action: () -> Void

    /// Group label for display
    var groupLabel: String {
        switch kind {
        case .window:     return "Windows"
        case .project:    return "Projects"
        case .app:        return "Applications"
        case .session:    return "Sessions"
        case .layer:      return "Layers"
        case .group:      return "Groups"
        case .action:     return "App"
        case .process:    return "Processes"
        case .ocrContent: return "Screen Text"
        }
    }
}

// MARK: - Activity Summary

struct ActivitySummary {
    struct AppWindowCount: Identifiable {
        let id: String
        let appName: String
        let count: Int
    }

    struct SessionInfo: Identifiable {
        let id: String
        let name: String
        let paneCount: Int
        let attached: Bool
    }

    let windowsByApp: [AppWindowCount]
    let totalWindows: Int
    let sessions: [SessionInfo]
    let interestingProcesses: [ProcessEntry]
    let lastOcrScan: Date?
    let ocrWindowCount: Int
}

// MARK: - State

final class OmniSearchState: ObservableObject {
    @Published var query: String = ""
    @Published var results: [OmniResult] = []
    @Published var selectedIndex: Int = 0
    @Published var activitySummary: ActivitySummary?

    /// Command mode: a leading "/" routes to the command engine (placement +
    /// window actions) instead of search, reusing the standalone bar's logic.
    let command = CommandBarState()
    var commandMode: Bool { query.hasPrefix("/") }

    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: AnyCancellable?

    init() {
        // Single-char queries fire immediately with a lightweight search;
        // longer queries debounce 150ms and run the full search.
        debounceTimer = $query
            .removeDuplicates()
            .sink { [weak self] q in
                guard let self else { return }
                self.fullSearchTask?.cancel()
                if q.hasPrefix("/") {                       // command mode
                    self.command.query = String(q.dropFirst())
                    self.results = []
                    return
                }
                if q.isEmpty {
                    self.results = BrowseMenu.build()   // no-typing browse menu (was the palette)
                    self.refreshSummary()
                } else if q.count == 1 {
                    self.quickSearch(q)        // single char: window index only, no debounce
                } else {
                    self.fullSearchTask = DispatchWorkItem { [weak self] in
                        self?.search(q)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: self.fullSearchTask!)
                }
            }

        // Surface nested command-engine changes to views observing this state.
        command.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        refreshSummary()
    }

    private var fullSearchTask: DispatchWorkItem?

    // MARK: - Quick search (first character — window index only, no terminal/OCR/projects)

    private func quickSearch(_ query: String) {
        let q = query.lowercased()
        let desktop = DesktopModel.shared
        var all: [OmniResult] = BrowseMenu.machinesSection().filter { row in
            q.split(separator: " ").allSatisfy { row.title.localizedCaseInsensitiveContains(String($0)) }
        }

        for entry in desktop.allWindows() {
            var score = 0
            if entry.title.lowercased().contains(q) { score += 3 }
            if entry.app.lowercased().contains(q) { score += 2 }
            if entry.latticesSession?.lowercased().contains(q) == true { score += 3 }
            guard score > 0 else { continue }

            let wid = entry.wid
            let pid = entry.pid
            all.append(OmniResult(
                kind: .window,
                title: entry.app,
                subtitle: entry.title.isEmpty ? "Window \(wid)" : entry.title,
                icon: "macwindow",
                score: score
            ) {
                WindowTiler.focusWindow(wid: wid, pid: pid)
            })
        }

        all.sort { $0.score > $1.score }
        results = Array(all.prefix(12))
        selectedIndex = 0
    }

    // MARK: - Search (delegates to unified search.query API)

    private func search(_ query: String) {
        let q = query.lowercased()
        var all: [OmniResult] = BrowseMenu.machinesSection().filter { row in
            q.split(separator: " ").allSatisfy { row.title.localizedCaseInsensitiveContains(String($0)) }
        }

        // ── Daemon search: windows, terminals, OCR — single source of truth ──
        // This is synchronous on the daemon's in-process API, not a network call.
        if let json = try? LatticesApi.shared.dispatch(
            method: "search.query",
            params: .object(["query": .string(q)])
        ), case .array(let hits) = json {
            let desktop = DesktopModel.shared
            for hit in hits {
                guard let wid = hit["wid"]?.uint32Value else { continue }
                let app = hit["app"]?.stringValue ?? ""
                let title = hit["title"]?.stringValue ?? ""
                var score = hit["score"]?.intValue ?? 0
                // Rank prefix / word-start matches above mid-word substring hits.
                if app.lowercased().hasPrefix(q) || title.lowercased().hasPrefix(q) {
                    score += 6
                } else if title.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                    score += 3
                }
                let pid = desktop.windows[wid]?.pid ?? 0
                let sources = (hit["matchSources"]?.arrayValue ?? []).compactMap(\.stringValue)

                // Determine kind from match sources
                let hasOcr = sources.contains("ocr")
                let hasTerminal = !Set(sources).isDisjoint(with: ["cwd", "tab", "tmux", "process"])
                let kind: OmniResultKind = hasOcr ? .ocrContent : hasTerminal ? .session : .window

                let icon: String
                let subtitle: String
                switch kind {
                case .ocrContent:
                    icon = "doc.text.magnifyingglass"
                    subtitle = hit["ocrSnippet"]?.stringValue ?? title
                case .session:
                    icon = "terminal"
                    let tabs = hit["terminalTabs"]?.arrayValue ?? []
                    let cwds = tabs.compactMap { $0["cwd"]?.stringValue }
                    subtitle = cwds.first ?? title
                default:
                    icon = "macwindow"
                    subtitle = title.isEmpty ? "Window \(wid)" : title
                }

                all.append(OmniResult(
                    kind: kind,
                    title: app,
                    subtitle: subtitle,
                    icon: icon,
                    score: score
                ) {
                    WindowTiler.focusWindow(wid: wid, pid: pid)
                })
            }
        }

        // ── Projects: local-only (not window-centric, so not in daemon search) ──
        for project in ProjectScanner.shared.projects {
            let score = scoreProjectMatch(q, name: project.name, path: project.path)
            if score > 0 {
                let proj = project
                all.append(OmniResult(
                    kind: .project,
                    title: project.name,
                    subtitle: project.path,
                    icon: "folder",
                    score: score
                ) {
                    SessionManager.launch(project: proj)
                })
            }
        }

        // ── Applications: launch or activate by name ──
        for match in AppIndex.shared.match(q, limit: 5) {
            let entry = match.entry
            let running = match.isRunning
            all.append(OmniResult(
                kind: .app,
                title: entry.name,
                subtitle: running ? "Running — bring to front" : "Launch application",
                icon: running ? "app.badge" : "arrow.up.forward.app",
                score: match.score
            ) {
                AppIndex.shared.launch(entry)
            })
        }

        // ── tmux sessions: focus/attach by session name ──
        let terminal = Preferences.shared.terminal
        let sessionMatches = TmuxModel.shared.sessions
            .compactMap { session -> (Int, TmuxSession)? in
                let score = FuzzyScore.score(query: q, candidate: session.name)
                return score > 0 ? (score, session) : nil
            }
            .sorted { $0.0 > $1.0 }
            .prefix(5)
        for (score, session) in sessionMatches {
            let name = session.name
            all.append(OmniResult(
                kind: .session,
                title: name,
                subtitle: "\(session.panes.count) pane\(session.panes.count == 1 ? "" : "s")"
                    + (session.attached ? " · attached" : ""),
                icon: "terminal",
                score: score
            ) {
                WindowTiler.navigateToWindow(session: name, terminal: terminal)
            })
        }

        all.sort { $0.score > $1.score }
        results = all
        selectedIndex = 0
    }

    // MARK: - Project scoring (local — projects aren't windows)

    private func scoreProjectMatch(_ query: String, name: String, path: String) -> Int {
        let nameScore = FuzzyScore.score(query: query, candidate: name)
        if nameScore > 0 { return nameScore }
        return path.lowercased().contains(query) ? 40 : 0
    }

    // MARK: - Navigation

    func moveSelection(_ delta: Int) {
        if commandMode { command.moveSelection(delta); return }
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    // MARK: - Activity Summary

    func refreshSummary() {
        let desktop = DesktopModel.shared
        let windows = desktop.allWindows()

        // Group by app
        var appCounts: [String: Int] = [:]
        for win in windows {
            appCounts[win.app, default: 0] += 1
        }
        let windowsByApp = appCounts
            .sorted { $0.value > $1.value }
            .map { ActivitySummary.AppWindowCount(id: $0.key, appName: $0.key, count: $0.value) }

        // Sessions
        let sessions = TmuxModel.shared.sessions.map {
            ActivitySummary.SessionInfo(
                id: $0.id,
                name: $0.name,
                paneCount: $0.panes.count,
                attached: $0.attached
            )
        }

        // Processes
        let procs = ProcessModel.shared.interesting

        // OCR info
        let ocrResults = ScreenText.shared.results
        let lastScan: Date? = ocrResults.values.map(\.timestamp).max()

        activitySummary = ActivitySummary(
            windowsByApp: windowsByApp,
            totalWindows: windows.count,
            sessions: sessions,
            interestingProcesses: procs,
            lastOcrScan: lastScan,
            ocrWindowCount: ocrResults.count
        )
    }

    /// Grouped results for display
    var groupedResults: [(String, [OmniResult])] {
        let groups = Dictionary(grouping: results) { $0.groupLabel }
        let order: [String] = ["Windows", "Projects", "Applications", "Sessions", "Layers", "Groups", "App", "Processes", "Screen Text"]
        return order.compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            return (key, items)
        }
    }
}
