import AppKit
import SwiftUI

/// Home opens on the work already in progress — sessions you'd resume and the
/// windows currently on screen — instead of a wall of cards that duplicate the
/// sidebar. The page header (title + actions) is chrome furniture owned by
/// AppShellView; this view is just the scrollable content below it.
struct HomeDashboardView: View {
    var onNavigate: ((AppPage) -> Void)? = nil

    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var scanner = ProjectScanner.shared
    @ObservedObject private var workspace = WorkspaceManager.shared

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bg)
        .onAppear {
            WorkspaceAssistantSession.shared.prepareForDisplay()
            desktop.start()        // guarded — no-op if already polling
            desktop.forcePoll()    // fresh snapshot on open
            scanner.scan()
        }
    }

    @ViewBuilder
    private var content: some View {
        if layers.isEmpty {
            mainColumn
        } else {
            HStack(alignment: .top, spacing: 24) {
                mainColumn
                asideColumn
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            sessionsSection
            activeWindowsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section header

    /// One heading style for every section: name, optional live count, optional
    /// trailing action. Matches the "Sec" furniture in the design mock.
    private func sectionHeader(
        title: String,
        count: Int? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Typo.heading(13))
                .foregroundColor(Palette.text)
            if let count {
                Text("\(count)")
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textMuted)
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typo.body(11))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Sessions

    /// The three things you'd actually resume: running sessions first, then
    /// recently scanned projects. Chat/Studio/Search/Runs/Activity already
    /// live permanently in the sidebar, so they don't need a card here too.
    private var sessions: [Project] {
        Array(
            scanner.projects.sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .prefix(3)
        )
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Sessions", count: sessions.count, actionTitle: "Manage") {
                onNavigate?(.overview)
            }

            if sessions.isEmpty {
                Text("No projects found")
                    .font(Typo.body(12))
                    .foregroundColor(Palette.textMuted)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(sessions) { project in
                        sessionCard(project)
                    }
                }
            }
        }
    }

    private func sessionCard(_ project: Project) -> some View {
        Button {
            SessionManager.launch(project: project)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(Typo.heading(13))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(project.isRunning ? Palette.running : Palette.textMuted)
                            .frame(width: 5, height: 5)
                        Text(project.isRunning ? "Running" : "Stopped")
                            .font(Typo.caption(10))
                    }
                    .fixedSize()
                    .foregroundColor(project.isRunning ? Palette.running : Palette.textMuted)
                }

                Text(displayPath(project.path))
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    ForEach(facts(for: project), id: \.self) { fact in
                        Text(fact)
                    }
                }
                .font(Typo.mono(10))
                .foregroundColor(project.isRunning ? Palette.textDim : Palette.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Real facts only — a stopped session has no live pane/window count, so
    /// it gets its configured pane count instead of a fabricated "last run".
    private func facts(for project: Project) -> [String] {
        guard project.isRunning else {
            return ["\(project.paneCount) panes configured"]
        }
        return ["tmux · \(project.paneCount) panes", "\(windowCount(for: project)) windows"]
    }

    private func windowCount(for project: Project) -> Int {
        desktop.allWindows().filter { $0.latticesSession == project.sessionName }.count
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Active windows

    /// On-screen windows, most-recently-interacted first, then frontmost order.
    private var activeWindows: [WindowEntry] {
        let focusedWindowID = desktop.focusedWindowID
        return desktop.allWindows()
            .filter { $0.isOnScreen && !$0.title.isEmpty }
            .sorted { a, b in
                if let focusedWindowID, a.wid != b.wid {
                    if a.wid == focusedWindowID { return true }
                    if b.wid == focusedWindowID { return false }
                }
                let da = desktop.lastInteractionDate(for: a.wid)
                let db = desktop.lastInteractionDate(for: b.wid)
                switch (da, db) {
                case let (.some(x), .some(y)):
                    if x != y { return x > y }
                    return a.zIndex < b.zIndex
                case (.some, .none):           return true
                case (.none, .some):           return false
                case (.none, .none):           return a.zIndex < b.zIndex
                }
            }
    }

    private var activeWindowsSection: some View {
        let windows = activeWindows
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Active windows", count: windows.count, actionTitle: "Open in Windows") {
                onNavigate?(.overview)
            }

            if windows.isEmpty {
                emptyWindows
            } else {
                VStack(spacing: 2) {
                    windowsColumnHeader
                    ForEach(windows.prefix(14), id: \.wid) { window in
                        WindowSnapshotRow(
                            window: window,
                            lastActive: desktop.lastInteractionDate(for: window.wid)
                        )
                    }
                }
            }
        }
    }

    /// Column labels, so the trailing numbers read as data instead of decoration.
    /// Widths are shared with `WindowSnapshotRow` via `HomeWindowColumn` so the
    /// header and every row resolve to the same grid.
    private var windowsColumnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: HomeWindowColumn.icon)
            Text("App")
                .frame(width: HomeWindowColumn.app, alignment: .leading)
            Text("Window")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Region")
                .frame(width: HomeWindowColumn.region, alignment: .leading)
            Text("Active")
                .frame(width: HomeWindowColumn.trailing, alignment: .trailing)
        }
        .font(Typo.caption(10))
        .tracking(0.5)
        .textCase(.uppercase)
        .lineLimit(1)
        .foregroundColor(Palette.textMuted)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 0.5)
        }
    }

    private var emptyWindows: some View {
        VStack(spacing: 6) {
            Image(systemName: "macwindow")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(Palette.textMuted)
            Text("No active windows on screen")
                .font(Typo.body(12))
                .foregroundColor(Palette.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    // MARK: - Layouts (aside)

    /// Saved layers double as named layouts — real config, not the mock's
    /// placeholder "Dev three-up / Review / Focus" list. Empty when the user
    /// hasn't configured any, which is an honest state, so the aside just
    /// doesn't render rather than showing an explainer.
    private var layers: [Layer] { workspace.config?.layers ?? [] }

    private var asideColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Layouts")
            let counts = workspace.layerWindowCounts()
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                layoutRow(layer, index: index, windows: counts.indices.contains(index) ? counts[index] : 0)
            }
        }
    }

    private func layoutRow(_ layer: Layer, index: Int, windows: Int) -> some View {
        Button {
            workspace.focusLayer(index: index)
        } label: {
            HStack(spacing: 10) {
                layoutGlyph(cells: layer.projects.count)
                Text(layer.label)
                    .font(Typo.body(12))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(LayerOverview.countNote(windows))
                    .font(Typo.mono(10))
                    .foregroundColor(windows > 0 ? Palette.textDim : Palette.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func layoutGlyph(cells: Int) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<max(min(cells, 3), 1), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.28))
            }
        }
        .padding(1.5)
        .frame(width: 27, height: 18)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.borderLit, lineWidth: 0.5))
        )
    }
}

// MARK: - Window table column widths

/// Shared between the column header and every row so they can never resolve
/// to different tracks.
private enum HomeWindowColumn {
    static let icon: CGFloat = 18
    static let app: CGFloat = 108
    static let region: CGFloat = 60
    static let trailing: CGFloat = 84
}

// MARK: - Window snapshot row

/// One window in the Home "Active windows" table. One fixed row height; the
/// trailing column is a single reserved-width `ZStack` that swaps its content
/// between metadata and quick actions on hover, so nothing else in the row
/// ever moves.
private struct WindowSnapshotRow: View {
    let window: WindowEntry
    let lastActive: Date?

    @State private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(spacing: 10) {
                icon
                    .frame(width: HomeWindowColumn.icon)

                Text(window.app)
                    .font(Typo.heading(12))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                    .frame(width: HomeWindowColumn.app, alignment: .leading)

                Text(secondaryTitle)
                    .font(Typo.body(11))
                    .foregroundColor(Palette.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(regionLabel)
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
                    .frame(width: HomeWindowColumn.region, alignment: .leading)

                trailingSlot
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.05 : 0.02))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let img = NSRunningApplication(processIdentifier: window.pid)?.icon {
            Image(nsImage: img).resizable().frame(width: 18, height: 18)
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Palette.surface).frame(width: 18, height: 18)
        }
    }

    private var secondaryTitle: String {
        (window.title.isEmpty || window.title == window.app) ? "" : window.title
    }

    /// One fixed-width slot: last-active time at rest, quick actions on hover.
    /// Both live in the same `ZStack` frame so the swap never shifts the row.
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            Text(timeAgo ?? "—")
                .font(Typo.mono(10))
                .foregroundColor(Palette.textMuted)
                .opacity(hovering ? 0 : 1)

            actions
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(width: HomeWindowColumn.trailing, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton("arrow.up.left.and.arrow.down.right", "Focus", action: focus)
            actionButton("rectangle.lefthalf.filled", "Tile left") { tile("left") }
            actionButton("rectangle.righthalf.filled", "Tile right") { tile("right") }
        }
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.textMuted)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Circle().strokeBorder(Palette.border, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func focus() {
        _ = WindowTiler.focusWindow(wid: window.wid, pid: window.pid)
        WindowTiler.highlightWindowById(wid: window.wid)
    }

    private func tile(_ position: String) {
        guard let placement = PlacementSpec(string: position) else { return }
        _ = WindowTiler.focusWindow(wid: window.wid, pid: window.pid)
        WindowTiler.tileWindowById(wid: window.wid, pid: window.pid, to: placement)
        WindowTiler.highlightWindowById(wid: window.wid)
    }

    /// Coarse horizontal region from the window's centre across the full desktop.
    /// Not a true macOS Space index (that needs a live CGS query per window,
    /// too costly to run for a whole table every poll) — a cheap, honest stand-in.
    private var regionLabel: String {
        let centerX = window.frame.x + window.frame.w / 2
        let totalWidth = NSScreen.screens.map(\.frame.maxX).max()
            ?? NSScreen.main?.frame.width ?? 1
        let frac = totalWidth > 0 ? centerX / totalWidth : 0.5
        if frac < 0.34 { return "Left" }
        if frac < 0.66 { return "Center" }
        return "Right"
    }

    private var timeAgo: String? {
        guard let lastActive else { return nil }
        let s = Date().timeIntervalSince(lastActive)
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
