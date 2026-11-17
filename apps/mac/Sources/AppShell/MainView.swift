import SwiftUI

enum MainViewLayout {
    case popover
    case embedded
}

struct MainView: View {
    @ObservedObject var scanner: ProjectScanner
    var layout: MainViewLayout = .popover
    @StateObject private var prefs = Preferences.shared
    @StateObject private var permChecker = PermissionChecker.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @StateObject private var inventory = InventoryManager.shared
    @State private var searchText = ""
    @State private var tmuxBannerDismissed = false
    @ObservedObject private var tmuxModel = TmuxModel.shared
    @State private var orphanSectionCollapsed = true
    private let embeddedProjectColumns = Array(
        repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .top),
        count: 3
    )
    private let embeddedProjectCardHeight: CGFloat = 118
    private let embeddedProjectGridSpacing: CGFloat = 10
    private let embeddedEmptyStateHeight: CGFloat = 150
    private var filtered: [Project] {
        if searchText.isEmpty { return scanner.projects }
        return scanner.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredOrphans: [TmuxSession] {
        if searchText.isEmpty { return inventory.orphans }
        return inventory.orphans.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var needsSetup: Bool { prefs.scanRoot.isEmpty }
    private var runningCount: Int { scanner.projects.filter(\.isRunning).count }
    private var hasVisibleGroups: Bool {
        guard let groups = workspace.config?.groups else { return false }
        return !groups.isEmpty && searchText.isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            mainContent
        }
        .frame(
            minWidth: layout == .popover ? MenuBarController.popoverWidth : 0,
            idealWidth: layout == .popover ? MenuBarController.popoverWidth : nil,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .background {
            if layout == .embedded { PanelBackground() }
        }
        .preferredColorScheme(layout == .embedded ? .dark : nil)
        .onAppear {
            runRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticesPopoverWillShow)) { _ in
            guard layout == .popover else { return }
            runRefresh()
        }
    }

    private func runRefresh() {
        let tTotal = DiagnosticLog.shared.startTimed("MainView.refresh (total)")
        scanner.updateRoot(prefs.scanRoot)

        if !prefs.scanRoot.isEmpty {
            let tScan = DiagnosticLog.shared.startTimed("ProjectScanner.scan")
            scanner.scan()
            DiagnosticLog.shared.finish(tScan)
        } else {
            DiagnosticLog.shared.info("ProjectScanner.scan skipped: scan root not set")
            scanner.projects = []
        }

        // Only the full workspace displays orphan tmux sessions. The popup's
        // projects are refreshed by the scanner's background queue above.
        if layout == .embedded {
            let tInv = DiagnosticLog.shared.startTimed("InventoryManager.refresh")
            inventory.refresh()
            DiagnosticLog.shared.finish(tInv)
        }

        let tPerm = DiagnosticLog.shared.startTimed("PermissionChecker.check")
        permChecker.check()
        DiagnosticLog.shared.finish(tPerm)

        DiagnosticLog.shared.finish(tTotal)
    }

    private var visiblyMissingCapabilities: [Capability] {
        Capability.available.filter { !$0.isGranted && !prefs.isCapabilityDismissed($0.rawValue) }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Permission banner — only when something is missing AND not snoozed
            if layout == .popover {
                popoverNotices
            } else if !visiblyMissingCapabilities.isEmpty {
                permissionBanner
            }

            // tmux not-found banner
            if layout == .embedded && needsSetup {
                scanRootSetupBanner
            }

            if layout == .embedded && !tmuxModel.isAvailable && !tmuxBannerDismissed {
                tmuxBanner
            }

            if layout == .popover {
                MiniHomeView(scanner: scanner)
            } else {
                Rectangle()
                    .fill(Palette.border)
                    .frame(height: 0.5)

                embeddedProjectArea
                    .layoutPriority(1)

                Rectangle()
                    .fill(Palette.border)
                    .frame(height: 0.5)

                // Actions footer
                actionsSection

                Rectangle()
                    .fill(Palette.border)
                    .frame(height: 0.5)

                // Bottom bar
                bottomBar
            }
        }
    }

    /// Keep setup notices compact and adaptive so they do not displace the
    /// menu's actions or inherit the full workspace's dark-only palette.
    private var popoverNotices: some View {
        VStack(spacing: 8) {
            if !visiblyMissingCapabilities.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        PermissionsAssistantWindowController.shared.show(focus: visiblyMissingCapabilities.first)
                    } label: {
                        Label("Optional permissions…", systemImage: "slider.horizontal.3")
                    }
                    .help(bannerSummary(visiblyMissingCapabilities))
                    Spacer()
                    Button("Later") {
                        for cap in visiblyMissingCapabilities { prefs.dismissCapability(cap.rawValue) }
                    }
                }
            }
            if !tmuxModel.isAvailable && !tmuxBannerDismissed {
                HStack(spacing: 8) {
                    Text("Terminal sessions need tmux.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Install") { installTmux() }
                    Button { tmuxBannerDismissed = true } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss tmux notice")
                }
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.top, visiblyMissingCapabilities.isEmpty && (tmuxModel.isAvailable || tmuxBannerDismissed) ? 0 : 12)
    }

    private func installTmux() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "brew install tmux"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private var embeddedProjectArea: some View {
        Group {
            if filtered.isEmpty && !hasVisibleGroups {
                emptyState
                    .frame(maxWidth: .infinity)
                    .frame(height: embeddedEmptyStateHeight)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    embeddedProjectsSection
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 154, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var embeddedProjectsSection: some View {
        VStack(spacing: 0) {
            if hasVisibleGroups, let groups = workspace.config?.groups {
                LazyVStack(spacing: 4) {
                    ForEach(groups) { group in
                        TabGroupRow(group: group, workspace: workspace)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, filtered.isEmpty ? 8 : 6)
            }

            if !filtered.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(searchText.isEmpty ? "Projects" : "Matches")
                            .font(Typo.monoBold(10))
                            .foregroundColor(Palette.textMuted)

                        if searchText.isEmpty {
                            Text("\(runningCount) live")
                                .font(Typo.mono(9))
                                .foregroundColor(Palette.running.opacity(0.8))
                        }

                        Spacer()

                        Text("\(filtered.count)")
                            .font(Typo.mono(9))
                            .foregroundColor(Palette.textMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    LazyVGrid(columns: embeddedProjectColumns, spacing: embeddedProjectGridSpacing) {
                        ForEach(filtered) { project in
                            HomeProjectCard(
                                project: project,
                                onLaunch: { launchProject(project) },
                                onDetach: { detachProject(project) },
                                onKill: { killProject(project) },
                                onSync: { syncProject(project) },
                                onRestart: { paneName in restartProject(project, paneName: paneName) }
                            )
                            .frame(height: embeddedProjectCardHeight)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }

            if !filteredOrphans.isEmpty {
                orphanSection
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Orphan section

    private var orphanSection: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: 0.5)
                .padding(.vertical, 4)

            // Section header
            Button {
                withAnimation(.easeOut(duration: 0.15)) { orphanSectionCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: orphanSectionCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Palette.textMuted)

                    Text("Unmanaged Sessions")
                        .font(Typo.caption(10))
                        .foregroundColor(Palette.textMuted)

                    Text("\(filteredOrphans.count)")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.detach)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.detach.opacity(0.12))
                        )

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !orphanSectionCollapsed {
                ForEach(filteredOrphans) { session in
                    OrphanRow(
                        session: session,
                        onAttach: {
                            let terminal = Preferences.shared.terminal
                            terminal.focusOrAttach(session: session.name)
                        },
                        onKill: {
                            SessionManager.killByName(session.name)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                inventory.refresh()
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Actions footer

    private var actionsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick Actions")
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.textMuted)

                Spacer()

                Button("Help & shortcuts") {
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(.plain)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Move is a one-line action that unfolds the placement grid —
            // keeps the actions footer compact until you need window spots.
            FrontWindowPlacementGrid(
                onPlaced: {
                    MenuBarController.shared.dismissPopover()
                }
            )

            ActionRow(
                label: "Assistant",
                detail: "AI chat for settings, planning, and workspace help",
                hotkeyTokens: hotkeyTokens(.workspaceAssistant),
                icon: "bubble.left.and.bubble.right",
                accentColor: Palette.running
            ) {
                AssistantAccess.show()
            }
            ActionRow(
                label: "Home",
                detail: "Workspace overview and project launcher",
                hotkeyTokens: hotkeyTokens(.unifiedWindow),
                icon: "house",
                accentColor: Palette.textDim
            ) {
                MenuBarController.shared.dismissPopover()
                ScreenMapWindowController.shared.showPage(.home)
            }
            ActionRow(
                label: "Studio",
                detail: "Arrange windows and layers",
                hotkeyTokens: hotkeyTokens(.screenMap),
                icon: "rectangle.3.group",
                accentColor: Palette.textDim
            ) {
                ScreenMapWindowController.shared.showPage(.overview)
            }
            ActionRow(
                label: "Command Bar",
                detail: "Browse, search, and run slash commands",
                hotkeyTokens: hotkeyTokens(.commandBar),
                icon: "text.cursor",
                accentColor: Palette.textDim
            ) {
                MenuBarController.shared.dismissPopover()
                UnifiedCommandBarWindow.shared.toggle(mode: .search)
            }
        }
        .padding(.vertical, 4)
        .background(Palette.surface.opacity(0.4))
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            bottomBarButton(icon: "gearshape", label: "Settings") {
                SettingsWindowController.shared.show()
            }

            if !permChecker.allGranted {
                Button {
                    PermissionsAssistantWindowController.shared.show()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Palette.detach)
                            .frame(width: 5, height: 5)
                        Text("Permissions")
                            .font(Typo.mono(9))
                            .foregroundColor(Palette.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            bottomBarButton(icon: "power", label: "Quit", color: Palette.kill) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.bg)
    }

    private func bottomBarButton(icon: String, label: String, color: Color = Palette.textMuted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(Typo.mono(9))
            }
            .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }

    private func hotkeyTokens(_ action: HotkeyAction) -> [String] {
        guard let binding = HotkeyStore.shared.bindings[action],
              let key = binding.displayParts.last else { return [] }

        let modifiers = Set(binding.displayParts.dropLast())
        if modifiers == Set(["Ctrl", "Option", "Shift", "Cmd"]) {
            return ["Hyper", shortenHotkeyToken(key)]
        }

        return binding.displayParts.map(shortenHotkeyToken)
    }

    private func shortenHotkeyToken(_ token: String) -> String {
        switch token {
        case "Cmd": return "⌘"
        case "Shift": return "⇧"
        case "Option": return "⌥"
        case "Ctrl": return "⌃"
        case "Return": return "↩"
        case "Escape": return "Esc"
        case "Space": return "Space"
        default: return token
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Palette.textMuted)

            Text("No projects yet")
                .font(Typo.heading(14))
                .foregroundColor(Palette.textDim)

            Text("Choose a repo and we’ll hand off to the CLI\nin your terminal.")
                .font(Typo.mono(11))
                .foregroundColor(Palette.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button(action: CliActionLauncher.initializeProjectInTerminal) {
                    Text("Initialize Project")
                        .angularButton(Palette.running)
                }
                .buttonStyle(.plain)

                Button(action: CliActionLauncher.launchProjectInTerminal) {
                    Text("Launch Project")
                        .angularButton(.white, filled: false)
                }
                .buttonStyle(.plain)
            }

            Text("Initialize runs  lattices init && lattices start  in the folder you choose.")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Permission banner

    private var scanRootSetupBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.running)
                Text("PROJECT DISCOVERY")
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.running)
                Spacer()
            }

            Text("Set a scan root so Home can show your Lattices projects automatically.")
                .font(Typo.mono(10))
                .foregroundColor(Palette.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    chooseScanRoot()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Choose Folder")
                            .font(Typo.monoBold(10))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Palette.running.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Palette.running.opacity(0.45), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Text("Open Settings")
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.running.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.running.opacity(0.20), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var permissionBanner: some View {
        let missing = visiblyMissingCapabilities

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.detach)
                Text("OPTIONAL CAPABILITIES")
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.detach)
                Spacer()
                Button {
                    for cap in missing { prefs.dismissCapability(cap.rawValue) }
                } label: {
                    Text("Maybe later")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }

            Text(bannerSummary(missing))
                .font(Typo.mono(10))
                .foregroundColor(Palette.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(missing) { cap in
                    capabilityChip(cap)
                }
                Spacer(minLength: 0)
            }

            Button {
                PermissionsAssistantWindowController.shared.show(focus: missing.first)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open Permissions Assistant")
                        .font(Typo.monoBold(10))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.detach.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Palette.detach.opacity(0.45), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.detach.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.detach.opacity(0.20), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func bannerSummary(_ missing: [Capability]) -> String {
        switch missing.count {
        case 0: return ""
        case 1: return "\(missing[0].title) is off. Lattices works without it."
        default: return "\(missing.count) capabilities are off. Turn on whichever you want; the rest of the app works without them."
        }
    }

    private func capabilityChip(_ cap: Capability) -> some View {
        Button {
            PermissionsAssistantWindowController.shared.show(focus: cap)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: cap.iconName)
                    .font(.system(size: 9, weight: .semibold))
                Text(cap.title)
                    .font(Typo.mono(9))
            }
            .foregroundColor(Palette.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Palette.surface)
                    .overlay(
                        Capsule().strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - tmux banner

    private var tmuxBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.detach)
                Text("TMUX NOT FOUND")
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.detach)
                Spacer()
                Button { tmuxBannerDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }

            Text("Session management requires tmux. Install it with Homebrew:")
                .font(Typo.mono(10))
                .foregroundColor(Palette.text)

            Button {
                installTmux()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                    Text("brew install tmux")
                        .font(Typo.monoBold(10))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.detach.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Text("Window tiling, search, and OCR work without tmux.")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.detach.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.detach.opacity(0.20), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Helpers

    private func chooseScanRoot() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder Lattices should scan for projects."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: prefs.scanRoot.isEmpty ? NSHomeDirectory() : prefs.scanRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        prefs.scanRoot = url.path
        scanner.updateRoot(url.path)
        scanner.scan()
        inventory.refresh()
    }

    private func launchProject(_ project: Project) {
        SessionManager.launch(project: project)
    }

    private func detachProject(_ project: Project) {
        SessionManager.detach(project: project)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            scanner.refreshStatus()
        }
    }

    private func killProject(_ project: Project) {
        SessionManager.kill(project: project)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            scanner.refreshStatus()
        }
    }

    private func syncProject(_ project: Project) {
        SessionManager.sync(project: project)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            scanner.refreshStatus()
        }
    }

    private func restartProject(_ project: Project, paneName: String?) {
        SessionManager.restart(project: project, paneName: paneName)
    }
}

private struct HomeProjectCard: View {
    let project: Project
    let onLaunch: () -> Void
    let onDetach: () -> Void
    let onKill: () -> Void
    let onSync: () -> Void
    let onRestart: (String?) -> Void

    @State private var isHovered = false

    private var summaryText: String {
        if !project.paneSummary.isEmpty { return project.paneSummary }
        if let cmd = project.devCommand, !cmd.isEmpty { return cmd }
        return project.hasConfig
            ? "\(project.paneCount) pane\(project.paneCount == 1 ? "" : "s")"
            : "No config"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(project.isRunning ? Palette.running : Palette.borderLit)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(Typo.heading(13))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)

                    Text(summaryText)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if project.isRunning {
                    Text("LIVE")
                        .font(Typo.monoBold(8))
                        .foregroundColor(Palette.running)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Palette.running.opacity(0.10))
                        )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if project.isRunning {
                    Button(action: onDetach) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 10, weight: .medium))
                            .angularButton(Palette.detach, filled: false)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                Button(action: onLaunch) {
                    Text(project.isRunning ? "Attach" : "Launch")
                        .angularButton(project.isRunning ? Palette.running : Palette.launch)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(hovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if project.isRunning {
                Button("Attach") { onLaunch() }
                Button("Detach") { onDetach() }
                Button {
                    WindowTiler.navigateToWindow(
                        session: project.sessionName,
                        terminal: Preferences.shared.terminal
                    )
                } label: {
                    Label("Go to Window", systemImage: "macwindow")
                }
                Divider()
                Button("Sync Session") { onSync() }
                Menu("Restart Pane") {
                    ForEach(project.paneNames, id: \.self) { name in
                        Button(name) { onRestart(name) }
                    }
                }
                Divider()
                Button("Kill Session") { onKill() }
            } else {
                Button("Launch") { onLaunch() }
            }
        }
    }
}
