import AppKit
import HudsonObservability
import SwiftUI
import HudsonShell
import HudsonUI

// MARK: - Navigation Pages

enum AppPage: String, CaseIterable {
    case home
    /// Every window: replaces Studio (`screenMap`) and Windows
    /// (`desktopInventory`).
    case overview
    case layers
    /// Nearby machines, visiting cursor and display arrangement.
    case machines
    case activity
    case runs
    case assistant
    case settings
    case companionSettings
    case docs

    var label: String {
        switch self {
        case .home:             return "Home"
        case .overview:         return "Overview"
        case .layers:           return "Layers"
        case .machines:         return "Machines"
        case .activity:         return "Activity"
        case .runs:             return "Runs"
        case .assistant:        return "Assistant"
        case .settings:         return "Settings"
        case .companionSettings:return "Settings"
        case .docs:             return "Docs"
        }
    }

    var icon: String {
        switch self {
        case .home:             return "house"
        case .overview:         return "rectangle.3.group"
        case .layers:           return "square.3.layers.3d"
        case .machines:         return "display.2"
        case .activity:         return "list.bullet.rectangle"
        case .runs:             return "record.circle"
        case .assistant:        return "bubble.left.and.bubble.right"
        case .settings:         return "gearshape"
        case .companionSettings:return "ipad.and.iphone"
        case .docs:             return "book"
        }
    }

    /// The rail's groups, in order. They answer "what kind of thing is this":
    /// places you work, agent surfaces, system state — so Runs and Activity stop
    /// reading as peers of Home.
    static let navigationGroups: [(title: String, pages: [AppPage])] = [
        ("Workspace", [.home, .overview, .layers, .machines]),
        ("Agents",    [.assistant, .runs]),
        ("System",    [.activity]),
    ]

    /// Pages shown as primary tabs in the unified window
    static var primaryTabs: [AppPage] { navigationGroups.flatMap(\.pages) }

    /// A page by raw value, old names included: Studio and Windows open
    /// Overview.
    static func named(_ raw: String) -> AppPage? {
        switch raw {
        case "screenMap", "desktopInventory": return .overview
        case "hosts": return .machines
        default: return AppPage(rawValue: raw)
        }
    }
}

// MARK: - App Shell View

struct AppShellView: View {
    @ObservedObject private var layerIndex = LayerIndexState.shared
    @ObservedObject var controller: ScreenMapController
    @ObservedObject var windowController = ScreenMapWindowController.shared
    @ObservedObject private var scanner = ProjectScanner.shared
    @ObservedObject private var ocr = ScreenText.shared
    @StateObject private var overview = OverviewModel()

    /// Labels are on by default. Collapsing to the icon rail stays available
    /// through the brand mark, but as a preference the user sets and keeps —
    /// not the state the app boots into.
    @AppStorage("sidebar.compact") private var sidebarCompact = false
    /// Expanded label-column width. The rail's trailing edge is a drag handle
    /// (same `HudNavigationSidebar.resizable` behavior Scout ships); the width
    /// persists, and dragging below `collapseLabelWidth` folds into the icon
    /// rail. Both bindings are caller-owned — the host previews during the drag
    /// and commits through these on release.
    @AppStorage("sidebar.labelWidth") private var sidebarLabelWidth = 120.0
    /// Actions the visible page published with `.pageActions(_:)`.
    @State private var pageActions: [PageAction] = []
    @ObservedObject private var daemon = DaemonServer.shared
    @ObservedObject private var desktop = DesktopModel.shared

    private var manifest: HudAppManifest {
        HudAppManifest(name: "Lattices", accent: Palette.textDim, targetLabel: "Machine")
    }

    /// Hudson rail ↔ our `activePage`. Selecting a rail item routes through the
    /// same `showPage` path the old tabs used; non-primary pages (Settings, Docs)
    /// leave the rail with no selection.
    private var selection: Binding<AppPage?> {
        Binding(
            get: { AppPage.primaryTabs.contains(windowController.activePage) ? windowController.activePage : nil },
            set: { if let page = $0 { windowController.showPage(page) } }
        )
    }

    private var entries: [HudSidebarEntry<AppPage>] {
        AppPage.navigationGroups.flatMap { group -> [HudSidebarEntry<AppPage>] in
            [.section(id: group.title, title: group.title)]
                + group.pages.map { .item(HudSidebarItem(id: $0, title: $0.label, icon: $0.icon)) }
        }
    }

    var body: some View {
        // Read the inset before extending the sidebar beneath the titlebar.
        GeometryReader { proxy in
            HudAppShell(
                statusBarSpan: .besideLeading,
                stage: .roundedCard(radius: 10),
                stageInsets: EdgeInsets(
                    top: proxy.safeAreaInsets.top,
                    leading: 0,
                    bottom: HudSpacing.sm,
                    trailing: HudSpacing.sm
                )
            ) {
                navigationSidebar(headerOffset: HudSidebarLayout.headerOffset(
                    topInset: proxy.safeAreaInsets.top,
                    pageHeaderHeight: Chrome.titleBarHeight
                ))
                .environment(\.hudsonSidebarStyle, HudSidebarStyle(surface: .glass))
            } trailing: {
                EmptyView()
            } topDrawer: {
                titleBar(compact: proxy.size.width <
                    HudSidebarLayout.railWidth + (sidebarCompact ? 0 : CGFloat(sidebarLabelWidth)) + 650)
            } bottomDrawer: {
                EmptyView()
            } content: {
                contentArea
            } statusBar: {
                if windowController.activePage == .layers || windowController.activePage == .overview {
                    layersStatusBar
                } else {
                    statusBar(availableWidth: proxy.size.width - HudSidebarLayout.railWidth
                        - (sidebarCompact ? 0 : CGFloat(sidebarLabelWidth)) - HudSpacing.sm)
                }
            }
            .onPreferenceChange(PageActionsKey.self) { pageActions = $0 }
            .ignoresSafeArea(.container, edges: .top)
            .background(ShellGlassBackdrop())
        }
        .environment(\.hudTheme, .lattices)
        .background(HudWindowChrome(colorScheme: .dark, isMovableByWindowBackground: false))
        .hudsonAppManifest(manifest)
        .onChange(of: windowController.activePage) { page in
            clearRelevantDismissals(for: page)
        }
    }

    // MARK: - Navigation Rail

    /// AppStorage stores Double; the sidebar's resize host wants CGFloat.
    private var sidebarLabelWidthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(sidebarLabelWidth) },
            set: { sidebarLabelWidth = Double($0) }
        )
    }

    private func toggleSidebar() {
        withAnimation(HudMotion.chromeSpring) { sidebarCompact.toggle() }
    }

    private func navigationSidebar(headerOffset: CGFloat) -> some View {
        HudNavigationSidebar(
            selection: selection,
            entries: entries,
            isCompact: sidebarCompact,
            accent: Palette.textDim,
            labelWidth: CGFloat(sidebarLabelWidth),
            onHeaderTap: nil
        ) {
            // railHeader — the brand mark is the top slot. The sidebar surface
            // runs to the window's top edge (floating chrome), so the headers
            // drop past the traffic lights onto the page header's center line
            // via HudSidebarLayout. The mark and wordmark are plain buttons that
            // toggle the rail; the offset moves their hit area and focus with
            // them. `onHeaderTap` is nil so the toggle has this one path.
            Button(action: toggleSidebar) {
                LatticesMarkAvatar(size: 24, tint: Palette.running)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sidebarCompact ? "Expand sidebar" : "Collapse sidebar")
            .offset(y: headerOffset)
        } labelHeader: {
            Button(action: toggleSidebar) {
                Text("Lattices")
                    .font(Typo.heading(14))
                    .foregroundColor(Palette.text)
            }
            .buttonStyle(.plain)
            .offset(y: headerOffset)
        } footer: {
            // The footer holds the two ambient things: whether the daemon is
            // reachable, and Settings — a non-primary page, so it routes through
            // showPage directly rather than the selection binding.
            VStack(spacing: 0) {
                SidebarDaemonStatus(
                    isListening: daemon.isListening,
                    port: LatticesLocalEndpoints.agentAPIPort,
                    isCompact: sidebarCompact,
                    labelWidth: CGFloat(sidebarLabelWidth)
                )

                SidebarFooterButton(
                    icon: "gearshape",
                    label: "Settings",
                    isActive: windowController.activePage == .settings,
                    isCompact: sidebarCompact,
                    labelWidth: CGFloat(sidebarLabelWidth),
                    accent: Palette.textDim
                ) {
                    windowController.showPage(.settings)
                }
            }
        }
        .resizable(
            isCompact: $sidebarCompact,
            labelWidth: sidebarLabelWidthBinding,
            minLabelWidth: 76,
            maxLabelWidth: 260,
            collapseLabelWidth: 44
        )
    }

    // MARK: - Title Bar

    /// Every page gets the same header: the page name at the leading edge, the
    /// actions that belong to that page at the trailing edge. Pages publish
    /// their own set with `.pageActions(_:)`; Search is the chrome's, because
    /// ⌘K works everywhere.
    private func titleBar(compact: Bool) -> some View {
        let layers = windowController.activePage == .layers
        let wrap = layers && compact && pageActions.contains { $0.id == "layers.arrangement" }
        return VStack(spacing: wrap ? 5 : 0) {
            HStack(spacing: 8) {
                HStack {
                    Text(windowController.activePage.label)
                        .font(Typo.heading(15)).foregroundColor(Palette.text).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                if !wrap {
                    ForEach(pageActions) { action in PageActionButton(action: action, compact: compact) }
                }
                PageActionButton(action: searchAction, compact: compact)
            }
            if wrap {
                HStack(spacing: 6) {
                    ForEach(pageActions) { action in PageActionButton(action: action, compact: true) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Chrome.inset)
        .frame(height: wrap ? 72 : Chrome.titleBarHeight)
        .background {
            if layers {
                LinearGradient(colors: [
                    Color(red: 26 / 255, green: 28 / 255, blue: 32 / 255),
                    Color(red: 21 / 255, green: 23 / 255, blue: 26 / 255)
                ], startPoint: .top, endPoint: .bottom)
            } else { Palette.bg }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(layers ? Color.white.opacity(0.07) : Palette.border)
                .frame(height: layers ? 1 : Chrome.hairline)
        }
    }

    private var searchAction: PageAction {
        PageAction(id: "chrome.search", title: "Search", icon: "magnifyingglass", shortcut: "⌘K") {
            UnifiedCommandBarWindow.shared.show(mode: .search)
        }
    }

    // MARK: - Status Bar

    private var layersStatusBar: some View {
        let count = Set(layerIndex.rows.flatMap(\.windows)).count
        let summary = "\(sessionHealthText) · \(count) content windows · \(NSScreen.screens.count) displays"
        return HStack(spacing: 12) {
            Text(summary).lineLimit(1).truncationMode(.tail).help(summary)
            Spacer(minLength: 0)
            Text(lastScanText).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .font(Typo.mono(11)).foregroundColor(Palette.textMuted).monospacedDigit()
        .padding(.horizontal, Chrome.inset)
        .frame(height: Chrome.statusBarHeight)
        .background(Palette.bg)
    }

    /// Three slots with the same meaning on every page — session health, desktop
    /// shape, last scan — so the strip never changes shape under you. Anything
    /// page-specific lives next to the thing it counts. The one variable region
    /// is the error line, and it sits between the fixed slots so they hold.
    private func statusBar(availableWidth: CGFloat) -> some View {
        // Preserve the three standard slots and their stable proportions. A
        // fixed 632pt minimum otherwise makes the whole shell clip at 600pt.
        let scale = min(1, max(0.1, (availableWidth - 2 * Chrome.inset) / 608))
        return HStack(spacing: 18 * scale) {
            statusSlot(width: 150 * scale) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(runningSessionCount > 0 ? Palette.running : Palette.textMuted)
                        .frame(width: 6, height: 6)
                    Text(sessionHealthText)
                }
            }

            statusSlot(width: 242 * scale) {
                Text(desktopShapeText)
            }

            ShellActivityError {
                windowController.showPage(.activity)
            }

            Spacer(minLength: 12 * scale)

            if ocr.isAvailable {
                statusSlot(width: 150 * scale, alignment: .trailing) {
                    Text(lastScanText)
                }
            }
        }
        .padding(.horizontal, Chrome.inset)
        .frame(height: Chrome.statusBarHeight)
        .background(Palette.bg)
    }

    /// A reserved column. Fixed width is the whole point: the numbers inside
    /// change every few seconds and the slot must not move when they do.
    private func statusSlot<Content: View>(
        width: CGFloat,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(Typo.mono(11))
            .foregroundColor(Palette.textMuted)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private var runningSessionCount: Int {
        scanner.projects.filter(\.isRunning).count
    }

    private var sessionHealthText: String {
        let running = runningSessionCount
        return "\(running) session\(running == 1 ? "" : "s") running"
    }

    /// Windows come from the live desktop model so the slot reads the same before
    /// Overview has ever been opened; spaces are only known once it has read
    /// them, and hold an em dash until then rather than lying with 0.
    private var desktopShapeText: String {
        let windows = desktop.windows.count
        let known = overview.displays
        let displays = known.isEmpty ? NSScreen.screens.count : known.count
        let spaces = known.isEmpty ? nil : known.reduce(0) { $0 + $1.desktops.count }
        let spacesText = spaces.map { "\($0)" } ?? "—"
        return "\(windows) windows · \(displays) displays · \(spacesText) spaces"
    }

    private var lastScanText: String {
        if ocr.isScanning { return "Scanning screen" }
        guard ocr.enabled else { return "Screen text off" }
        guard let last = ocr.lastReviewedAt ?? ocr.results.values.map(\.timestamp).max() else {
            return "No scan yet"
        }
        return "Scanned \(relativeStatusTime(last))"
    }

    private func relativeStatusTime(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Entering a feature page clears its capability snooze — the user is
    /// telling us they want this to work, so the banner can resurface.
    private func clearRelevantDismissals(for page: AppPage) {
        let prefs = Preferences.shared
        switch page {
        case .overview:
            prefs.clearDismissal(Capability.windowControl.rawValue)
            prefs.clearDismissal(Capability.screenSearch.rawValue)
        default:
            break
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch windowController.activePage {
        case .home:
            HomeDashboardView(onNavigate: { page in
                windowController.showPage(page)
            })
        case .overview:
            OverviewView(model: overview, controller: controller)
        case .layers:
            LayersPage()
        case .machines:
            MachinesPageView()
        case .activity:
            ActivityPageView()
        case .runs:
            RunsReviewView()
        case .assistant:
            WorkspaceAssistantView()
        case .settings:
            SettingsContentView(
                prefs: Preferences.shared,
                scanner: ProjectScanner.shared,
                onBack: { windowController.showPage(.overview) }
            )
        case .companionSettings:
            SettingsContentView(
                page: .companionSettings,
                prefs: Preferences.shared,
                scanner: ProjectScanner.shared,
                onBack: { windowController.showPage(.overview) }
            )
        case .docs:
            SettingsContentView(
                page: .docs,
                prefs: Preferences.shared,
                scanner: ProjectScanner.shared,
                onBack: { windowController.showPage(.overview) }
            )
        }
    }
}

// MARK: - Sidebar Daemon Status

/// Daemon reachability, drawn on the rail's geometry so it lines up with the
/// footer button under it: the dot centers in the fixed rail column, the name
/// and port ride the collapsing label column. Not a button — it reports, it
/// doesn't navigate.
private struct SidebarDaemonStatus: View {
    let isListening: Bool
    let port: UInt16
    let isCompact: Bool
    var labelWidth: CGFloat = HudSidebarLayout.labelWidth

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(isListening ? Palette.running : Palette.kill)
                .frame(width: 6, height: 6)
                .frame(width: HudSidebarLayout.railWidth, height: HudSidebarLayout.rowHeight)

            HStack(spacing: 6) {
                Text("Daemon")
                    .font(Typo.body(12))
                    .foregroundColor(Palette.textDim)
                Text(verbatim: ":\(port)")
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textMuted)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, HudSidebarLayout.labelLeading)
            .frame(width: isCompact ? 0 : labelWidth, alignment: .leading)
            .clipped()
            .opacity(isCompact ? 0 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isListening ? "Daemon listening on port \(port)" : "Daemon offline")
        .help(isListening ? "Daemon listening on :\(port)" : "Daemon offline")
    }
}

// MARK: - Sidebar Footer Button

/// A rail-aligned button for `HudNavigationSidebar`'s footer slot. Matches the
/// geometry and color states of the nav rail icons: the glyph centers in the
/// fixed rail column, and the label rides a width-collapsing column so it
/// animates in lockstep with the rail's compact toggle (and is clipped to the
/// rail when compact, never spilling into content).
private struct SidebarFooterButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let isCompact: Bool
    var labelWidth: CGFloat = HudSidebarLayout.labelWidth
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.hudTheme) private var theme

    private var tint: Color {
        if isActive   { return accent }
        if isHovering { return theme.palette.ink }
        return theme.palette.muted
    }

    var body: some View {
        Button(action: action) {
            row
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }

    private var row: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: HudSidebarLayout.iconSize))
                .foregroundStyle(tint)
                .frame(width: HudSidebarLayout.railWidth, height: HudSidebarLayout.rowHeight)

            Text(label)
                .font(HudFont.ui(HudTextSize.base, weight: isActive ? .medium : .regular))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, HudSidebarLayout.labelLeading)
                .frame(width: isCompact ? 0 : labelWidth, alignment: .leading)
                .clipped()
                .opacity(isCompact ? 0 : 1)
        }
        .background { hoverUnderlay }
        .contentShape(Rectangle())
    }

    /// The nav rows' hover pill, on the same metrics: surface fill, subtle
    /// hairline, row radius and insets. Like the rows, the active item shows
    /// its tint instead.
    @ViewBuilder
    private var hoverUnderlay: some View {
        if isHovering, !isActive {
            RoundedRectangle(cornerRadius: HudSidebarLayout.selectionCornerRadius)
                .fill(theme.palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: HudSidebarLayout.selectionCornerRadius)
                        .strokeBorder(theme.hairline.subtle, lineWidth: HudStrokeWidth.thin)
                )
                .padding(.horizontal, HudSidebarLayout.selectionHorizontalInset)
                .padding(.vertical, HudSidebarLayout.selectionVerticalInset)
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.06)))
        }
    }
}

// MARK: - Shell Glass Backdrop

/// What shows outside the stage card: the titlebar band above it, the gutter
/// around it and the corners its curves cut away. The shell paints nothing there, and the dark
/// window behind it is black, so this repeats the `.glass` sidebar surface
/// layer for layer, across the full window height like the sidebar, and the
/// two meet without a seam.
private struct ShellGlassBackdrop: View {
    @Environment(\.hudTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                theme.palette.chrome
            } else {
                ZStack {
                    HudVisualEffectView(
                        material: .sidebar,
                        blendingMode: .behindWindow,
                        state: .active,
                        isEmphasized: true
                    )
                    theme.palette.chrome.opacity(HudOpacity.muted)
                    LinearGradient(
                        colors: [Color.white.opacity(0.040), Color.white.opacity(0.018), Color.black.opacity(0.060)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Log traffic must not invalidate the full shell during a Space switch.
/// Only this small status slot observes the live log buffer.
private struct ShellActivityError: View {
    @ObservedObject private var log = HudLogStore.shared
    let openActivity: () -> Void

    var body: some View {
        if let message = message {
            Button(action: openActivity) {
                Text(message)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.kill)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help("Open Activity")
        }
    }

    /// Warnings stay in the log. Only errors belong in the status strip.
    private var message: String? {
        guard let entry = log.entries.last,
              entry.level == .error || entry.level == .fault else { return nil }
        let trimmed = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
