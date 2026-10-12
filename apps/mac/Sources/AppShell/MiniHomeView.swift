import AppKit
import SwiftUI

// MARK: - Mini-Home popover
//
// Rail + pane shell: the popover becomes a miniature of the Home window.
// Move gets a to-scale placement map, Home shows the live desktop layout with
// the active layer's slots, Studio lists groups/layers, and Assistant + Bar
// hand off to their real surfaces.

enum MiniHomePane: String, CaseIterable, Identifiable {
    case move, assistant, home, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .move: return "Move"
        case .assistant: return "Assistant"
        case .home: return "Home"
        case .command: return "Bar"
        }
    }

    var icon: String {
        switch self {
        case .move: return "arrow.up.left.and.arrow.down.right"
        case .assistant: return "bubble.left.and.bubble.right"
        case .home: return "house"
        case .command: return "command"
        }
    }
}

struct MiniHomeView: View {
    @ObservedObject var scanner: ProjectScanner
    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var assistant = WorkspaceAssistantSession.shared
    @State private var pane: MiniHomePane = .home
    /// Home's layer-slot selection, lifted so the pane header can name it.
    @State private var selectedLayer: Int?

    private let headerHeight: CGFloat = 38
    private let footerHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            topBand
                .frame(height: headerHeight)
            rule
            middleBand
                .frame(maxHeight: .infinity)
            rule
            paneFooter
                .frame(height: footerHeight)
            rule
            bottomBand
                .frame(height: 30)
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticesPopoverWillShow)) { _ in
            DesktopModel.shared.forcePoll()
        }
    }

    private var rule: some View {
        Rectangle().fill(Palette.border).frame(height: 0.5)
    }

    // MARK: Bands

    /// Top bar: rail side carries mark + wordmark, pane side carries the
    /// pane's title — one continuous band closed by a full-width rule.
    private var topBand: some View {
        HStack(spacing: 0) {
            railHeader
                .frame(width: 100)
                .padding(.horizontal, 6)
            paneHeader
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(railBandBackground)
    }

    /// Middle: rail nav + texture | pane body. The vertical divider lives
    /// only here, so the horizontal rules read uninterrupted.
    private var middleBand: some View {
        HStack(spacing: 0) {
            railNav
                .frame(width: 100)
                .padding(.horizontal, 6)
                .background(railBackground)
            Rectangle().fill(Palette.border).frame(width: 0.5)
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    /// Shared app controls span the entire popover, independent of the pane.
    private var bottomBand: some View {
        ZStack {
            spaceRow
                .padding(.horizontal, 80)
            lifecycleRow
        }
        .padding(.horizontal, 8)
        .background(railBandBackground)
    }

    /// Neutral band fill for the top/bottom bars — a whisper lighter than the
    /// rail so the bars read as shelves.
    private var railBandBackground: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.045), Color.white.opacity(0.015)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Rail parts

    private var railHeader: some View {
        HStack(spacing: 6) {
            latticeMark
            Text("Lattices")
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private var railNav: some View {
        VStack(spacing: 2) {
            ForEach(MiniHomePane.allCases) { item in
                MiniHomeRailButton(item: item, isActive: pane == item) {
                    pane = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    /// Monochrome gradient + faint lattice-dot texture + top shine — keeps the
    /// rail's empty middle feeling intentional instead of vacant.
    private var railBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { ctx, size in
                let step: CGFloat = 11
                var row = 0
                var y: CGFloat = step * 0.5
                while y < size.height {
                    var x: CGFloat = (row % 2 == 0) ? step * 0.5 : step
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                            with: .color(Palette.text.opacity(0.06))
                        )
                        x += step
                    }
                    y += step
                    row += 1
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.42),
                        .init(color: .black, location: 0.72),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.white.opacity(0.07), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 26)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    /// Spaces on the popover's display — current space lit; click to switch.
    @ViewBuilder
    private var spaceRow: some View {
        if let display = currentDisplaySpaces(), !display.spaces.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "display")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.textMuted)
                    .accessibilityLabel("Spaces on this display")
                ForEach(display.spaces) { space in
                    Button {
                        _ = WindowTiler.switchToSpace(spaceId: space.id)
                    } label: {
                        Text("\(space.index)")
                            .font(Typo.monoBold(7))
                            .foregroundColor(space.isCurrent ? Palette.bg : Palette.textMuted)
                            .frame(width: 13, height: 13)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(space.isCurrent
                                          ? Palette.text.opacity(0.85)
                                          : Palette.surface.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(space.isCurrent ? .clear : Palette.border,
                                                          lineWidth: 0.5)
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Space \(space.index)")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The popover's display = the screen hosting it (NSScreen.main once shown).
    /// `getDisplaySpaces` enumerates in CG display order, matching NSScreen order.
    private func currentDisplaySpaces() -> DisplaySpaces? {
        let displays = WindowTiler.getDisplaySpaces()
        guard !displays.isEmpty else { return nil }
        if let main = NSScreen.main,
           let idx = NSScreen.screens.firstIndex(of: main),
           idx < displays.count {
            return displays[idx]
        }
        return displays.first
    }

    /// App lifecycle: Settings, Restart, Quit.
    private var lifecycleRow: some View {
        HStack(spacing: 0) {
            MiniHomeRailIcon(icon: "gearshape", help: "Settings") {
                SettingsWindowController.shared.show()
            }
            .frame(width: 28)
            Spacer(minLength: 0)
            MiniHomeRailIcon(icon: "arrow.clockwise", help: "Restart Lattices") {
                PermissionChecker.shared.quitAndRelaunch()
            }
            .frame(width: 28)
            MiniHomeRailIcon(icon: "power", help: "Quit Lattices", tint: Palette.kill) {
                NSApp.terminate(nil)
            }
            .frame(width: 28)
        }
    }

    /// Same 3x3 lattice mark as the menu-bar icon. The mark itself carries the
    /// build channel: amber in dev, neutral in prod.
    private var latticeMark: some View {
        let tint = LatticesRuntime.isDevBuild ? Palette.detach : Palette.text
        let solid: Set<Int> = [0, 3, 6, 7, 8]
        return VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tint.opacity(solid.contains(row * 3 + col) ? 0.9 : 0.28))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
            }
        }
        .help(LatticesRuntime.buildChannelLabel)
    }

    // MARK: Pane dispatch

    private var selectedLayerLabel: String? {
        guard let selectedLayer,
              let layers = workspace.config?.layers,
              layers.indices.contains(selectedLayer) else { return nil }
        return layers[selectedLayer].label
    }

    @ViewBuilder
    private var paneHeader: some View {
        switch pane {
        case .move:
            MiniHomePaneHeader(title: "MOVE", subtitle: nil) { EmptyView() }
        case .assistant:
            MiniHomePaneHeader(title: "ASSISTANT", subtitle: assistant.statusText) {
                MiniHomeOpenLink(title: "Open") { AssistantAccess.show() }
            }
        case .home:
            MiniHomePaneHeader(title: "Home", qualifier: selectedLayerLabel) {
                MiniHomeOpenLink(title: "Open Home") {
                    MenuBarController.shared.dismissPopover()
                    ScreenMapWindowController.shared.showPage(.home)
                }
            }
        case .command:
            MiniHomePaneHeader(title: "BAR", subtitle: nil) { EmptyView() }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .move:
            MiniHomeMovePane()
        case .assistant:
            MiniHomeAssistantPane()
        case .home:
            MiniHomeHomePane(selectedLayer: $selectedLayer)
        case .command:
            MiniHomeCommandPane()
        }
    }

    @ViewBuilder
    private var paneFooter: some View {
        switch pane {
        case .move:
            MiniHomeMoveFooter()
        case .assistant:
            MiniHomeComposer()
        case .home:
            MiniHomeProjectStrip(scanner: scanner)
        case .command:
            MiniHomeCommandJumps()
        }
    }
}

// MARK: - Rail buttons

private struct MiniHomeRailButton: View {
    let item: MiniHomePane
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 14, alignment: .center)
                Text(item.label)
                    .font(Typo.mono(10))
                Spacer(minLength: 0)
            }
            .foregroundColor(isActive ? Palette.text : (isHovered ? Palette.textDim : Palette.textMuted))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Palette.surfaceHov : (isHovered ? Palette.surface.opacity(0.6) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MiniHomeRailIcon: View {
    let icon: String
    let help: String
    var tint: Color = Palette.textMuted
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? tint.opacity(1) : tint.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Pane chrome

private struct MiniHomePaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var qualifier: String? = nil
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, qualifier: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.qualifier = qualifier
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typo.geistMonoBold(10))
                        .foregroundColor(Palette.textDim)
                    if let qualifier, !qualifier.isEmpty {
                        Text("/ \(qualifier)")
                            .font(Typo.mono(10))
                            .foregroundColor(Palette.textMuted)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

/// Small "Open X ↗" link shown in a pane header's trailing slot.
private struct MiniHomeOpenLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(Typo.mono(9))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(Palette.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Palette.surface.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
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
                        .fill(Palette.surface.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Palette.border, lineWidth: 0.75)
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
                                Palette.textMuted.opacity(0.55),
                                style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
                            )
                            .overlay(alignment: .topLeading) {
                                Text(slot.label)
                                    .font(Typo.mono(6.5))
                                    .foregroundColor(Palette.textMuted)
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
                .fill(Color.black.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func windowRect(_ win: WindowEntry, rect r: CGRect) -> some View {
        let isFront = win.wid == frontWid
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let fill = isFront
            ? (zonesEnabled ? Color.white.opacity(0.12) : Palette.running.opacity(0.45))
            : Palette.textMuted.opacity(0.16)
        let stroke = isFront
            ? (zonesEnabled ? Palette.text.opacity(0.8) : Palette.running.opacity(0.9))
            : Palette.border

        if let onWindowTap {
            Button {
                onWindowTap(win)
            } label: {
                shape
                    .fill(fill)
                    .overlay(shape.strokeBorder(stroke, lineWidth: isFront ? 1 : 0.5))
                    .overlay(alignment: .topLeading) {
                        if r.width > 34 && r.height > 12 {
                            Text(win.app)
                                .font(Typo.mono(6.5))
                                .foregroundColor(isFront ? Palette.text : Palette.textMuted)
                                .lineLimit(1)
                                .padding(2)
                        }
                    }
                    .frame(width: max(r.width, 4), height: max(r.height, 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: r.minX, y: r.minY)
            .help("\(win.app) — \(win.title)")
        } else {
            shape
                .fill(fill)
                .overlay(shape.strokeBorder(stroke, lineWidth: isFront ? 1.5 : 0.5))
                .overlay(alignment: .topLeading) {
                    if isFront && r.width > 70 && r.height > 20 {
                        Text("Current · \(win.app)")
                            .font(Typo.mono(8))
                            .foregroundColor(Palette.text)
                            .lineLimit(1)
                            .padding(4)
                            .background(Palette.bg.opacity(0.9))
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
                            isHovered ? Color.accentColor : Palette.textMuted,
                            style: StrokeStyle(lineWidth: isHovered ? 1.5 : 0.5, dash: isHovered ? [] : [3, 3])
                        )
                )
                .overlay {
                    if isHovered {
                        Text(position.label)
                            .font(Typo.monoBold(9))
                            .foregroundColor(Palette.text)
                            .padding(4)
                            .background(Palette.bg.opacity(0.9))
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
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.text)
                if !target.title.isEmpty && target.title != target.app {
                    Text(target.title)
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textDim)
                        .lineLimit(1)
                }
            } else {
                Text("Focus a window to move it")
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textDim)
            }
            MiniDesktopMap(screen: frontScreen, zonesEnabled: canPlace) { position in
                Self.place(position)
            }
            if canPlace {
                Text("Choose a destination to move this window")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textDim)
            }
        }
        .padding(.horizontal, 12)
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
            pill(.maximize, label: "Max")
            pill(.center, label: "Center")
            pill(.leftThird, label: "⅓ L")
            pill(.centerThird, label: "⅓ C")
            pill(.rightThird, label: "⅓ R")
        }
        .padding(.horizontal, 12)
    }

    private func pill(_ position: TilePosition, label: String) -> some View {
        Button {
            MiniHomeMovePane.place(position)
        } label: {
            Text(label)
                .font(Typo.monoBold(8))
                .foregroundColor(canPlace ? Palette.textDim : Palette.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Palette.border, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canPlace)
        .opacity(canPlace ? 1 : 0.45)
        .help(position.label)
    }
}

// MARK: - Home pane

/// The layout surface: layer chips over a big live desktop map with the
/// selected layer's configured slots ghosted in. The project strip lives in
/// the shared footer band; `selectedLayer` is owned by the shell so the top
/// bar can name the selected layer.
private struct MiniHomeHomePane: View {
    @Binding var selectedLayer: Int?
    @ObservedObject private var workspace = WorkspaceManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.layers.isEmpty || workspace.isLayerFocusActive || workspace.layerFocus.needsRecovery {
                let layers = workspace.layers
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        layerChips(layers)
                        Button("Exit Layers") { workspace.exitLayers() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .help("Restore windows and leave layer focus. Saved layers stay available.")
                    }
                    if let message = workspace.layerRecoveryMessage {
                        Text(message)
                            .font(Typo.caption())
                            .foregroundColor(Palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            MiniDesktopMap(layerIndex: selectedLayer, onWindowTap: { win in
                _ = WindowTiler.focusWindow(wid: win.wid, pid: win.pid)
                MenuBarController.shared.dismissPopover()
            })
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onAppear { selectedLayer = workspace.activeLayerSelection }
        .onChange(of: workspace.activeLayerSelection) { _, newIndex in
            selectedLayer = newIndex
        }
    }

    private func layerChips(_ layers: [Layer]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let windowCounts = workspace.layerWindowCounts()
                ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                    let isActive = index == selectedLayer
                    let count = windowCounts.indices.contains(index) ? windowCounts[index] : 0
                    let verb = isActive ? "Exit" : "Focus"
                    let facts: [String?] = ["\(verb) \(layer.label)", LayerOverview.chord(forIndex: index), LayerOverview.countNote(count)]
                    let hint = facts.compactMap { $0 }.joined(separator: " · ")
                    Button {
                        if selectedLayer == index {
                            workspace.exitLayers()
                            selectedLayer = nil
                        } else {
                            selectedLayer = index
                            workspace.focusLayer(index: index)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(layer.label)
                                .font(Typo.mono(9))
                            Text("\(count)")
                                .font(Typo.monoBold(8))
                                .foregroundColor(isActive ? Palette.bg.opacity(0.8) : Palette.textMuted)
                        }
                        .foregroundColor(isActive ? Palette.bg : Palette.textDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isActive ? Palette.running : Palette.surface.opacity(0.7))
                                .overlay(
                                    Capsule().strokeBorder(isActive ? Color.clear : Palette.border, lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(hint)
                    .contextMenu {
                        Button("Exit Layers") {
                            workspace.exitLayers()
                        }
                    }
                }
            }
        }
    }

}

/// Home's footer — a compact strip of project shortcuts.
private struct MiniHomeProjectStrip: View {
    @ObservedObject var scanner: ProjectScanner

    var body: some View {
        Group {
            if scanner.projects.isEmpty {
                Text("No projects — set a scan root in Settings")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(scanner.projects) { project in
                            Button {
                                SessionManager.launch(project: project)
                                MenuBarController.shared.dismissPopover()
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(project.isRunning ? Palette.running : Palette.borderLit)
                                        .frame(width: 5, height: 5)
                                    Text(project.name)
                                        .font(Typo.mono(9))
                                        .foregroundColor(Palette.textDim)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Palette.surface.opacity(0.7))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(Palette.border, lineWidth: 0.5)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .help(project.isRunning ? "Attach to \(project.name)" : "Launch \(project.name)")
                        }
                    }
                }
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
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
                    ForEach(visibleMessages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if session.isSending {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(Palette.textMuted)
                                    .frame(width: 3, height: 3)
                                    .opacity(0.4 + 0.2 * Double(i))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .id("sending")
                    }
                }
                .padding(.horizontal, 12)
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
                .font(Typo.body(10))
                .foregroundColor(isUser ? Palette.text : Palette.textDim)
                .lineLimit(6)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isUser ? Palette.running.opacity(0.16) : Palette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isUser ? Palette.running.opacity(0.3) : Palette.border, lineWidth: 0.5)
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
                .font(Typo.mono(10))
                .foregroundColor(Palette.text)
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Palette.surface.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(fieldFocused ? Palette.running.opacity(0.4) : Palette.border, lineWidth: 0.5)
                        )
                )

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(text.isEmpty ? Palette.textMuted : Palette.bg)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(text.isEmpty ? Palette.surfaceHov : Palette.running)
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
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
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(featuredCommands) { command in
                        commandRow(command)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
        }
    }

    private var inputField: some View {
        HStack(spacing: 6) {
            Image(systemName: "command")
                .font(.system(size: 10))
                .foregroundColor(Palette.textMuted)
            TextField("search, or / for commands", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.mono(10))
                .foregroundColor(Palette.text)
                .onSubmit { open(with: text) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.surface.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
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
                    .foregroundColor(Palette.running)
                    .frame(width: 14)
                Text("/\(alias)")
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.text)
                Text(command.title)
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.surface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
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
            jump("magnifyingglass", "Inventory") {
                ScreenMapWindowController.shared.showPage(.overview)
            }
            jump("list.bullet.rectangle", "Activity") {
                ScreenMapWindowController.shared.showPage(.activity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    private func jump(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            MenuBarController.shared.dismissPopover()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(Palette.textMuted)
                Text(label)
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
