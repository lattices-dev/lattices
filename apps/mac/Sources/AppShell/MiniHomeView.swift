import AppKit
import SwiftUI

/// The menu-bar surface follows the system appearance independently of the
/// main workspace window. NSPopover owns the material, edge, and shadow.
private enum PopoverPalette {
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.045)
    static let surfaceHov = Color.primary.opacity(0.09)
    static let border = Color.primary.opacity(0.12)
    static let borderLit = Color.primary.opacity(0.22)
    static let text = Color.primary
    static let textDim = Color.secondary
    static let textMuted = Color.secondary
    static let running = Color.accentColor
}

enum MiniHomePane: String, CaseIterable, Identifiable {
    case home, move, assistant, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Workspace"
        case .move: return "Move Window"
        case .assistant: return "Assistant"
        case .command: return "Commands"
        }
    }
}

struct MiniHomeView: View {
    @ObservedObject var scanner: ProjectScanner
    @ObservedObject private var desktop = DesktopModel.shared
    @State private var pane: MiniHomePane = .home
    @State private var selectedLayer: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $pane) {
                ForEach(MiniHomePane.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            paneFooter
                .padding(.vertical, 12)

            Divider().padding(.horizontal, 16)
            spaceRow
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .onReceive(NotificationCenter.default.publisher(for: .latticesPopoverWillShow)) { _ in
            let started = desktop.requestRefresh()
            DiagnosticLog.shared.info("menuBar.desktopRefresh \(started ? "scheduled" : "already in flight")")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            latticeMark
            Text("Lattices")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Button {
                MenuBarController.shared.dismissPopover()
                ScreenMapWindowController.shared.showPage(.home)
            } label: {
                Label("Open Workspace", systemImage: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Open the full workspace window")

            Menu {
                Button("Settings…") {
                    MenuBarController.shared.dismissPopover()
                    SettingsWindowController.shared.show()
                }
                Button("Activity Log…") {
                    MenuBarController.shared.dismissPopover()
                    ScreenMapWindowController.shared.showPage(.activity)
                }
                Divider()
                Button("Restart Lattices…") { PermissionChecker.shared.quitAndRelaunch() }
                Button("Quit Lattices") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Lattices settings and more")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var latticeMark: some View {
        let solid: Set<Int> = [0, 3, 6, 7, 8]
        return VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(Color.primary.opacity(solid.contains(row * 3 + col) ? 0.85 : 0.2))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .help(LatticesRuntime.buildChannelLabel)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .home: MiniHomeHomePane(selectedLayer: $selectedLayer)
        case .move: MiniHomeMovePane()
        case .assistant: MiniHomeAssistantPane()
        case .command: MiniHomeCommandPane()
        }
    }

    @ViewBuilder
    private var paneFooter: some View {
        switch pane {
        case .home: MiniHomeProjectStrip(scanner: scanner)
        case .move: MiniHomeMoveFooter()
        case .assistant: MiniHomeComposer()
        case .command: MiniHomeCommandJumps()
        }
    }

    @ViewBuilder
    private var spaceRow: some View {
        if let display = currentDisplaySpaces(), !display.spaces.isEmpty {
            HStack(spacing: 10) {
                Label("Desktops", systemImage: "display")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(display.spaces) { space in
                                Button {
                                    _ = WindowTiler.switchToSpace(spaceId: space.id)
                                } label: {
                                    Text("\(space.index)")
                                        .font(.system(size: 11, weight: space.isCurrent ? .semibold : .regular))
                                        .monospacedDigit()
                                        .foregroundStyle(space.isCurrent ? Color.accentColor : Color.secondary)
                                        .frame(minWidth: 26, minHeight: 26)
                                        .background(space.isCurrent ? Color.accentColor.opacity(0.12) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(space.id)
                                .accessibilityLabel("Desktop \(space.index)")
                                .accessibilityAddTraits(space.isCurrent ? .isSelected : [])
                                .help("Switch to Desktop \(space.index)")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 26)
                    .onAppear {
                        if let current = display.spaces.first(where: \.isCurrent) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                    .onChange(of: display.spaces.first(where: \.isCurrent)?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func currentDisplaySpaces() -> DisplaySpaces? {
        let displays = WindowTiler.getDisplaySpaces()
        if let main = NSScreen.main,
           let index = NSScreen.screens.firstIndex(of: main), index < displays.count {
            return displays[index]
        }
        return displays.first
    }
}

// MARK: - Desktop map

/// Scaled rendering of one display plus its live windows. Optionally draws
/// the selected layer's configured tile slots (dashed) and a 3x3
/// placement-zone overlay.
struct MiniDesktopMap: View {
    /// Display to render — nil falls back to the screen hosting the popover.
    var screen: NSScreen? = nil
    /// Layer whose tile slots overlay the map — nil draws no slots.
    var layerIndex: Int? = nil
    var zonesEnabled: Bool = false
    var onZone: ((TilePosition) -> Void)? = nil
    var onWindowTap: ((WindowEntry) -> Void)? = nil

    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @State private var hoveredZone: TilePosition?

    private static let zoneGrid: [[TilePosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight],
    ]

    private var displayedScreen: NSScreen? {
        screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Index of the displayed screen in NSScreen order — matches the
    /// `display` field on layer projects.
    private var displayIndex: Int {
        guard let s = displayedScreen else { return 0 }
        return NSScreen.screens.firstIndex(of: s) ?? 0
    }

    /// NSScreen frames live in bottom-left global space; window frames are CG
    /// top-left space. Convert the shown screen into CG space.
    private var screenRects: [(screen: NSScreen, rect: CGRect)] {
        guard let s = displayedScreen else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return [(s, CGRect(
            x: s.frame.minX,
            y: primaryHeight - s.frame.maxY,
            width: s.frame.width,
            height: s.frame.height
        ))]
    }

    private var unionRect: CGRect {
        screenRects.map(\.rect).reduce(CGRect.null) { $0.union($1) }
    }

    private var mapWindows: [WindowEntry] {
        let bounds = unionRect
        return desktop.allWindows().filter {
            $0.isOnScreen &&
            $0.pid != getpid() &&
            !$0.title.isEmpty &&
            $0.frame.w > 50 && $0.frame.h > 50 &&
            CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h)
                .intersects(bounds)
        }
    }

    private var frontWid: UInt32? { desktop.frontmostWindow()?.wid }

    private var zoneScreenRect: CGRect? {
        screenRects.first?.rect
    }

    var body: some View {
        GeometryReader { geo in
            let union = unionRect
            let scale = min(geo.size.width / max(union.width, 1), geo.size.height / max(union.height, 1))
            let drawn = CGSize(width: union.width * scale, height: union.height * scale)
            let origin = CGPoint(
                x: (geo.size.width - drawn.width) / 2,
                y: (geo.size.height - drawn.height) / 2
            )
            let mapRect: (CGRect) -> CGRect = { r in
                CGRect(
                    x: origin.x + (r.minX - union.minX) * scale,
                    y: origin.y + (r.minY - union.minY) * scale,
                    width: r.width * scale,
                    height: r.height * scale
                )
            }

            ZStack(alignment: .topLeading) {
                // Displays
                ForEach(Array(screenRects.enumerated()), id: \.offset) { _, item in
                    let r = mapRect(item.rect)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(PopoverPalette.surface.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(PopoverPalette.border, lineWidth: 0.75)
                        )
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }

                // Selected layer's configured slots (dashed)
                if layerIndex != nil {
                    ForEach(Array(layerSlots().enumerated()), id: \.offset) { _, slot in
                        let r = mapRect(slot.rect)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(
                                PopoverPalette.textMuted.opacity(0.55),
                                style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
                            )
                            .overlay(alignment: .topLeading) {
                                Text(slot.label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(PopoverPalette.textMuted)
                                    .lineLimit(1)
                                    .padding(2)
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }

                // Live windows, back to front
                ForEach(Array(mapWindows.reversed()), id: \.wid) { win in
                    let r = mapRect(CGRect(x: win.frame.x, y: win.frame.y, width: win.frame.w, height: win.frame.h))
                    windowRect(win, rect: r)
                }

                // 3x3 zone overlay on the target screen
                if zonesEnabled, let zoneRect = zoneScreenRect.map(mapRect) {
                    ForEach(0..<3, id: \.self) { row in
                        ForEach(0..<3, id: \.self) { col in
                            zoneCell(Self.zoneGrid[row][col], row: row, col: col, in: zoneRect)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopoverPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PopoverPalette.border, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func windowRect(_ win: WindowEntry, rect r: CGRect) -> some View {
        let isFront = win.wid == frontWid
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let fill = isFront
            ? Color.accentColor.opacity(0.10)
            : PopoverPalette.text.opacity(0.07)
        let stroke = isFront
            ? Color.accentColor.opacity(0.65)
            : PopoverPalette.border

        if let onWindowTap {
            Button {
                onWindowTap(win)
            } label: {
                shape
                    .fill(fill)
                    .overlay(shape.strokeBorder(stroke, lineWidth: isFront ? 1 : 0.5))
                    .overlay(alignment: .topLeading) {
                        if r.width > 60 && r.height > 26 {
                            Text(win.app)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isFront ? PopoverPalette.text : PopoverPalette.textMuted)
                                .lineLimit(1)
                                .padding(6)
                        }
                    }
                    .frame(width: max(r.width, 4), height: max(r.height, 3))
                    .clipShape(shape)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: r.minX, y: r.minY)
            .help("Focus \(win.app) — \(win.title)")
            .accessibilityLabel("Focus \(win.app), \(win.title)")
        } else {
            shape
                .fill(fill)
                .overlay(shape.strokeBorder(stroke, lineWidth: isFront ? 1.5 : 0.5))
                .overlay(alignment: .topLeading) {
                    if isFront && r.width > 70 && r.height > 20 {
                        Text("Current · \(win.app)")
                            .font(Typo.mono(8))
                            .foregroundColor(PopoverPalette.text)
                            .lineLimit(1)
                            .padding(4)
                            .background(PopoverPalette.bg.opacity(0.9))
                            .padding(3)
                    }
                }
                .frame(width: max(r.width, 4), height: max(r.height, 3))
                .offset(x: r.minX, y: r.minY)
                .accessibilityLabel("\(isFront ? "Current window" : "Window"): \(win.app), \(win.title)")
        }
    }

    private func zoneCell(_ position: TilePosition, row: Int, col: Int, in rect: CGRect) -> some View {
        let cellW = rect.width / 3
        let cellH = rect.height / 3
        let cell = CGRect(
            x: rect.minX + CGFloat(col) * cellW,
            y: rect.minY + CGFloat(row) * cellH,
            width: cellW,
            height: cellH
        )
        let isHovered = hoveredZone == position

        return Button {
            onZone?(position)
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(isHovered ? 0.25 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isHovered ? Color.accentColor : PopoverPalette.textMuted,
                            style: StrokeStyle(lineWidth: isHovered ? 1.5 : 0.5, dash: isHovered ? [] : [3, 3])
                        )
                )
                .overlay {
                    if isHovered {
                        Text(position.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(PopoverPalette.text)
                            .padding(4)
                            .background(PopoverPalette.bg.opacity(0.9))
                    }
                }
                .frame(width: cell.width - 3, height: cell.height - 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredZone = $0 ? position : nil }
        .offset(x: cell.minX + 1.5, y: cell.minY + 1.5)
        .help("Move current window to \(position.label)")
        .accessibilityLabel("Move current window to \(position.label)")
    }

    /// Configured tile slots for the selected layer, resolved to CG rects on
    /// the displayed screen.
    private func layerSlots() -> [(rect: CGRect, label: String)] {
        guard let layerIndex,
              let layers = workspace.config?.layers,
              layers.indices.contains(layerIndex),
              let screenRect = screenRects.first?.rect else { return [] }

        return layers[layerIndex].projects.compactMap { lp in
            guard let tile = lp.tile,
                  let spec = workspace.resolvePlacement(tile),
                  (lp.display ?? 0) == displayIndex else { return nil }
            let f = spec.fractions
            let rect = CGRect(
                x: screenRect.minX + f.0 * screenRect.width,
                y: screenRect.minY + f.1 * screenRect.height,
                width: f.2 * screenRect.width,
                height: f.3 * screenRect.height
            )
            return (rect, layerSlotLabel(lp))
        }
    }

    private func layerSlotLabel(_ lp: LayerProject) -> String {
        if let groupId = lp.group, let group = workspace.group(byId: groupId) {
            return group.label
        }
        if let app = lp.app { return app }
        if let path = lp.path { return (path as NSString).lastPathComponent }
        return lp.title ?? "slot"
    }
}

// MARK: - Move pane

private struct MiniHomeMovePane: View {
    @ObservedObject private var desktop = DesktopModel.shared

    /// The window a zone click would move. `DesktopModel.frontmostWindow()`
    /// skips Lattices' own panels, so it stays valid while the popover has
    /// focus — unlike `NSWorkspace.frontmostApplication`, which is Lattices
    /// whenever the popover is open.
    private var target: WindowEntry? { desktop.frontmostWindow() }
    private var canPlace: Bool { target != nil }

    /// The map follows the window you'd be placing.
    private var frontScreen: NSScreen? {
        target.map { WindowTiler.screenForWindowFrame($0.frame) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target {
                Text("Current window · \(target.app)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(PopoverPalette.text)
                if !target.title.isEmpty && target.title != target.app {
                    Text(target.title)
                        .font(.system(size: 11))
                        .foregroundColor(PopoverPalette.textDim)
                        .lineLimit(1)
                }
            } else {
                Text("Focus a window to move it")
                    .font(.system(size: 12))
                    .foregroundColor(PopoverPalette.textDim)
            }
            MiniDesktopMap(screen: frontScreen, zonesEnabled: canPlace) { position in
                Self.place(position)
            }
            if canPlace {
                Text("Choose a destination to move this window")
                    .font(.system(size: 11))
                    .foregroundColor(PopoverPalette.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Shared with `MiniHomeMoveFooter` so pills and zones tile identically.
    static func place(_ position: TilePosition) {
        guard let target = DesktopModel.shared.frontmostWindow() else {
            NSSound.beep(); return
        }
        let screen = WindowTiler.screenForWindowFrame(target.frame)
        AppFeedback.shared.commitTactile()
        WindowTiler.tileWindowById(wid: target.wid, pid: target.pid, to: position, on: screen)
        DiagnosticLog.shared.success("Mini-Home placed \(target.app) → \(position.label)")
        MenuBarController.shared.dismissPopover()
    }
}

/// Move's footer — extra placements beyond the 3×3 grid.
private struct MiniHomeMoveFooter: View {
    @ObservedObject private var desktop = DesktopModel.shared
    private var canPlace: Bool { desktop.frontmostWindow() != nil }

    var body: some View {
        HStack(spacing: 4) {
            pill(.maximize, label: "Maximize")
            pill(.center, label: "Center")
            pill(.leftThird, label: "Left third")
            pill(.centerThird, label: "Middle third")
            pill(.rightThird, label: "Right third")
        }
        .padding(.horizontal, 16)
    }

    private func pill(_ position: TilePosition, label: String) -> some View {
        Button {
            MiniHomeMovePane.place(position)
        } label: {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(canPlace ? PopoverPalette.textDim : PopoverPalette.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(PopoverPalette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(PopoverPalette.border, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canPlace)
        .opacity(canPlace ? 1 : 0.45)
        .help(position.label)
    }
}

// MARK: - Workspace

private struct MiniHomeHomePane: View {
    @Binding var selectedLayer: Int?
    @ObservedObject private var workspace = WorkspaceManager.shared

    private var activeLayerLabel: String {
        guard let selectedLayer, workspace.layers.indices.contains(selectedLayer) else {
            return "All windows"
        }
        return workspace.layers[selectedLayer].label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Layers")
                    .font(.system(size: 12, weight: .semibold))
                Menu {
                    Button("All windows") { workspace.exitLayers() }
                    if !workspace.layers.isEmpty { Divider() }
                    ForEach(Array(workspace.layers.enumerated()), id: \.offset) { index, layer in
                        Button {
                            workspace.focusLayer(index: index)
                        } label: {
                            if index == selectedLayer {
                                Label(layer.label, systemImage: "checkmark")
                            } else {
                                Text(layer.label)
                            }
                        }
                    }
                } label: {
                    Text(activeLayerLabel).lineLimit(1)
                }
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .help("Switch the focused layer")
                Spacer(minLength: 4)
                if workspace.isLayerFocusActive || workspace.layerFocus.needsRecovery {
                    Button("Show All Windows") { workspace.exitLayers() }
                        .controlSize(.small)
                        .help("Restore windows and leave layer focus. Saved layers stay available.")
                }
            }
            if let message = workspace.layerRecoveryMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MiniDesktopMap(layerIndex: selectedLayer, onWindowTap: { win in
                _ = WindowTiler.focusWindow(wid: win.wid, pid: win.pid)
                MenuBarController.shared.dismissPopover()
            })
            .frame(minHeight: 100)

            Label("Click a window to bring it forward", systemImage: "cursorarrow")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .onAppear { selectedLayer = workspace.activeLayerSelection }
        .onChange(of: workspace.activeLayerSelection) { _, newIndex in selectedLayer = newIndex }
    }
}

private struct MiniHomeProjectStrip: View {
    @ObservedObject var scanner: ProjectScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Open a terminal session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if scanner.projects.isEmpty {
                Button("Choose a projects folder…") {
                    MenuBarController.shared.dismissPopover()
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(scanner.projects) { project in
                            Button {
                                SessionManager.launch(project: project)
                                MenuBarController.shared.dismissPopover()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(project.isRunning ? Color.green : .secondary)
                                    Text(project.name).lineLimit(1)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(PopoverPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(project.isRunning ? "Attach to \(project.name)" : "Launch \(project.name)")
                            .accessibilityLabel("\(project.isRunning ? "Attach to" : "Launch") \(project.name)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 30)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Assistant pane

/// Compact composer that writes straight into the shared assistant session —
/// replies stream in here, "Open" jumps to the full surface.
private struct MiniHomeAssistantPane: View {
    @ObservedObject private var session = WorkspaceAssistantSession.shared

    private var visibleMessages: [WorkspaceAssistantMessage] {
        session.messages.filter { $0.role != .system }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Workspace assistant").font(.system(size: 13, weight: .semibold))
                            Text(session.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Chat ↗") {
                            MenuBarController.shared.dismissPopover()
                            AssistantAccess.show()
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.bottom, 10)
                    if visibleMessages.isEmpty {
                        Text("Ask for help arranging windows, finding a project, or changing settings.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    }
                    ForEach(visibleMessages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if session.isSending {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(PopoverPalette.textMuted)
                                    .frame(width: 3, height: 3)
                                    .opacity(0.4 + 0.2 * Double(i))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .id("sending")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: session.messages.count) { _, _ in
                if let last = visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageRow(_ message: WorkspaceAssistantMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 30) }
            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(isUser ? PopoverPalette.text : PopoverPalette.textDim)
                .lineLimit(6)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isUser ? PopoverPalette.running.opacity(0.16) : PopoverPalette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isUser ? PopoverPalette.running.opacity(0.3) : PopoverPalette.border, lineWidth: 0.5)
                        )
                )
            if !isUser { Spacer(minLength: 30) }
        }
    }
}

/// Assistant's footer — the composer, writing into the shared session.
private struct MiniHomeComposer: View {
    @ObservedObject private var session = WorkspaceAssistantSession.shared
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Ask Scout…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(PopoverPalette.text)
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(PopoverPalette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(fieldFocused ? PopoverPalette.running.opacity(0.4) : PopoverPalette.border, lineWidth: 0.5)
                        )
                )

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(text.isEmpty ? PopoverPalette.textMuted : PopoverPalette.bg)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(text.isEmpty ? PopoverPalette.surfaceHov : PopoverPalette.running)
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.send(trimmed)
        text = ""
    }
}

// MARK: - Command bar pane

/// The bar is its own surface — this pane is a launcher that seeds it.
private struct MiniHomeCommandPane: View {
    @State private var text = ""

    private var featuredCommands: [BarCommand] {
        let all = CommandCatalog.all()
        return CommandCatalog.featuredGroups.flatMap { $0.names }.compactMap { name in
            all.first(where: { $0.name == name })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            inputField
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(featuredCommands) { command in
                        commandRow(command)
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer(minLength: 0)
        }
    }

    private var inputField: some View {
        HStack(spacing: 6) {
            Image(systemName: "command")
                .font(.system(size: 10))
                .foregroundColor(PopoverPalette.textMuted)
            TextField("Search windows, projects, or /commands", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(PopoverPalette.text)
                .onSubmit { open(with: text) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(PopoverPalette.surface.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(PopoverPalette.border, lineWidth: 0.5)
                )
        )
    }

    private func commandRow(_ command: BarCommand) -> some View {
        let alias = command.hint.aliases.first ?? command.name
        return Button {
            open(with: "/\(alias) ")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: command.icon)
                    .font(.system(size: 10))
                    .foregroundColor(PopoverPalette.running)
                    .frame(width: 14)
                Text("/\(alias)")
                    .font(.system(size: 12))
                    .foregroundColor(PopoverPalette.text)
                Text(command.title)
                    .font(.system(size: 11))
                    .foregroundColor(PopoverPalette.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(PopoverPalette.surface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(PopoverPalette.border, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(command.description)
    }

    /// Hand the typed text to the real bar: "/" prefixes open command mode,
    /// anything else opens search with the query seeded.
    private func open(with text: String) {
        MenuBarController.shared.dismissPopover()
        if text.hasPrefix("/") {
            UnifiedCommandBarWindow.shared.show(mode: .command, query: text)
        } else if text.isEmpty {
            UnifiedCommandBarWindow.shared.show(mode: .search)
        } else {
            UnifiedCommandBarWindow.shared.show(mode: .search, query: text)
        }
    }
}

/// Bar's footer — jumps to the full Home surfaces.
private struct MiniHomeCommandJumps: View {
    var body: some View {
        HStack(spacing: 10) {
            jump("magnifyingglass", "Windows") {
                ScreenMapWindowController.shared.showPage(.overview)
            }
            jump("stethoscope", "Diagnostics") {
                ScreenMapWindowController.shared.showPage(.activity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private func jump(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            MenuBarController.shared.dismissPopover()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(PopoverPalette.textMuted)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(PopoverPalette.textMuted)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(PopoverPalette.textMuted)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
