import AppKit

/// The merged command bar's no-typing browse menu (the retired CommandPalette's
/// job): actionable rows for the empty-query state, built from the same manager
/// calls the palette used. Rendered through the standard `OmniResult` list, so
/// selection and commit behave exactly like search results.
enum BrowseMenu {
    static func build() -> [OmniResult] {
        var out: [OmniResult] = []
        out += windowSection()
        out += projectsSection()
        out += layersSection()
        out += groupsSection()
        out += appSection()
        out += machinesSection()
        return out
    }

    static func machinesSection(screens: [DisplayGather.Screen] = DisplayGather.screens(), hosts: [VisitTrust.Host] = VisitTrust.shared.list()) -> [OmniResult] {
        var rows: [OmniResult] = []
        func add(_ title: String, _ method: String, _ params: JSON? = nil) {
            rows.append(OmniResult(kind: .action, title: title, subtitle: "", icon: "desktopcomputer", score: 10) { ClusterVerbs.run(method, params) })
        }
        for screen in screens {
            let params: JSON = .object(["display": .int(screen.index)])
            add("Bring everything to \(screen.name)", "bring", params)
            add("Make \(screen.name) main", "main", params)
            add("\(screen.name) elsewhere", "elsewhere", params)
            add("\(screen.name) here", "here", params)
        }
        for host in hosts { add("Visit \(host.name)", "visit.start", .object(["host": .string(host.name)])) }
        add("Home — end visit", "home")
        add("Undo bring", "bring", .object(["undo": .bool(true)]))
        return rows
    }

    // MARK: - Window (act on the frontmost window captured at open time)

    private static func windowSection() -> [OmniResult] {
        guard let entry = DesktopModel.shared.frontmostWindow() else { return [] }
        let app = entry.app
        let wid = entry.wid
        let pid = entry.pid
        let screen = WindowTiler.screenForWindowFrame(entry.frame)
        let placements: [(String, String, PlacementSpec)] = [
            ("Left", "rectangle.lefthalf.filled", .tile(.left)),
            ("Right", "rectangle.righthalf.filled", .tile(.right)),
            ("Maximize", "rectangle.fill", .tile(.maximize)),
        ]
        return placements.map { label, icon, spec in
            OmniResult(
                kind: .window,
                title: "Tile \(app) \(label)",
                subtitle: entry.title.isEmpty ? "Snap the frontmost window" : entry.title,
                icon: icon,
                score: 0
            ) {
                WindowTiler.tileWindowById(wid: wid, pid: pid, to: spec, on: screen)
            }
        }
    }

    // MARK: - Projects

    private static func projectsSection() -> [OmniResult] {
        var out: [OmniResult] = []
        for project in ProjectScanner.shared.projects {
            if project.isRunning {
                out.append(OmniResult(
                    kind: .project,
                    title: "Attach \(project.name)",
                    subtitle: "Open terminal to running session",
                    icon: "play.fill",
                    score: 0
                ) {
                    SessionManager.launch(project: project)
                })
                out.append(OmniResult(
                    kind: .project,
                    title: "Kill \(project.name)",
                    subtitle: "Terminate the session",
                    icon: "xmark.circle.fill",
                    score: 0
                ) {
                    SessionManager.kill(project: project)
                })
            } else {
                out.append(OmniResult(
                    kind: .project,
                    title: "Launch \(project.name)",
                    subtitle: project.paneSummary.isEmpty
                        ? (project.devCommand ?? project.path)
                        : project.paneSummary,
                    icon: "play.circle",
                    score: 0
                ) {
                    SessionManager.launch(project: project)
                })
            }
        }
        return out
    }

    // MARK: - Layers

    private static func layersSection() -> [OmniResult] {
        let workspace = WorkspaceManager.shared
        let layers = workspace.layers
        var out: [OmniResult] = []
        let windowCounts = workspace.layerWindowCounts()
        for (index, layer) in layers.enumerated() {
            let i = index
            let count = windowCounts.indices.contains(i) ? windowCounts[i] : 0
            let isActive = i == workspace.activeLayerSelection
            let facts: [String?] = [LayerOverview.chord(forIndex: i), LayerOverview.countNote(count), isActive ? "active" : nil]
            let subtitle = facts.compactMap { $0 }.joined(separator: " · ")
            if count > 0 {
                out.append(OmniResult(
                    kind: .layer,
                    title: "Focus Layer: \(layer.label)",
                    subtitle: subtitle,
                    icon: "square.stack.3d.up",
                    score: 0
                ) {
                    workspace.focusLayer(index: i)
                })
            } else {
                out.append(OmniResult(
                    kind: .layer,
                    title: "Launch Layer: \(layer.label)",
                    subtitle: subtitle,
                    icon: "square.stack.3d.up",
                    score: 0
                ) {
                    workspace.tileLayer(index: i, launch: true)
                })
            }
        }
        out.insert(OmniResult(
            kind: .layer,
            title: "Exit Layers",
            subtitle: workspace.layerRecoveryMessage ?? "Show all windows and turn layer focus off",
            icon: "rectangle.portrait.and.arrow.right",
            score: 0
        ) { workspace.exitLayers() }, at: 0)
        return out
    }

    // MARK: - Tab groups

    private static func groupsSection() -> [OmniResult] {
        let workspace = WorkspaceManager.shared
        guard let groups = workspace.config?.groups else { return [] }
        var out: [OmniResult] = []
        for group in groups {
            if workspace.isGroupRunning(group) {
                out.append(OmniResult(
                    kind: .group,
                    title: "Attach \(group.label)",
                    subtitle: "\(group.tabs.count) tabs",
                    icon: "rectangle.stack",
                    score: 0
                ) {
                    workspace.focusTab(group: group, tabIndex: workspace.selectedTabIndex(in: group))
                })
            } else {
                out.append(OmniResult(
                    kind: .group,
                    title: "Launch \(group.label)",
                    subtitle: "\(group.tabs.count) tabs",
                    icon: "rectangle.stack",
                    score: 0
                ) {
                    workspace.launchGroup(group)
                })
            }
        }
        return out
    }

    // MARK: - App

    private static func appSection() -> [OmniResult] {
        [
            OmniResult(kind: .action, title: "Workspace Assistant",
                       subtitle: "Open AI chat", icon: "bubble.left.and.bubble.right", score: 0) {
                AssistantAccess.show()
            },
            OmniResult(kind: .action, title: "Studio",
                       subtitle: "Arrange windows & layers", icon: "rectangle.3.group", score: 0) {
                ScreenMapWindowController.shared.showPage(.overview)
            },
            OmniResult(kind: .action, title: "Activity Log",
                       subtitle: "View logs, events, and diagnostics", icon: "list.bullet.rectangle", score: 0) {
                ScreenMapWindowController.shared.showPage(.activity)
            },
            OmniResult(kind: .action, title: "Toggle Focus Mode",
                       subtitle: "Spotlight the frontmost window (Hyper+Z)", icon: "viewfinder", score: 0) {
                FocusModeController.shared.toggle()
            },
            OmniResult(kind: .action, title: "Settings",
                       subtitle: "Terminal, scan root, keyboard, shortcuts, voice, and OCR", icon: "gearshape", score: 0) {
                SettingsWindowController.shared.show()
            },
            OmniResult(kind: .action, title: "Refresh Projects",
                       subtitle: "Re-scan .lattices.json configs, reload workspace.json", icon: "arrow.clockwise", score: 0) {
                ProjectScanner.shared.scan()
                WorkspaceManager.shared.reloadConfig()
            },
            OmniResult(kind: .action, title: "Quit Lattices",
                       subtitle: "Exit the menu bar app", icon: "power", score: 0) {
                NSApp.terminate(nil)
            },
        ]
    }
}
