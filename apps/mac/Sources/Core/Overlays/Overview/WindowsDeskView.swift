import AppKit
import SwiftUI

/// The Windows page as one desk: every monitor side by side as it sits, each
/// with its Desktops as tabs over its map, then one table of every matched
/// window, grouped independently from the maps. A layer pick is a
/// restriction, so it says so: the menu takes the accent and a bar names the
/// layer, counts what it hides and offers the way back. The selected
/// window's actions live in the inspector on the right.
struct WindowsDeskView: View {
    @ObservedObject var model: OverviewModel
    /// Fixture renders use the same page without following the live desktop.
    var live = true
    @ObservedObject private var index = LayerIndexState.shared
    /// The Desktop each monitor's map shows, by display index. Absent means
    /// the one it's showing.
    @State private var viewed: [Int: Int] = [:]
    @State private var deskWidth: CGFloat = 900
    @AppStorage("windows.groupBy") private var grouping = WindowsDeskGrouping.application
    @AppStorage("windows.thenGroupBy") private var subgrouping = WindowsDeskGrouping.none

    /// One neutral surface ladder for the page: light across the whole room,
    /// a textured canvas for the maps, translucent lists, and
    /// the selected or pressable thing one step higher again. Coral marks
    /// selection and an active restriction; ordinary actions stay neutral.
    static let accent = Color(red: 0.937, green: 0.416, blue: 0.278)
    static let card = Color(white: 0.145)
    static let raised = Color(white: 0.19)
    static let controlFill = Color.white.opacity(0.075)
    static let controlEdge = Color.white.opacity(0.20)
    /// Maps grow with the page so a wide window isn't two-thirds empty canvas.
    static func mapHeight(for width: CGFloat) -> CGFloat { min(320, max(230, (width * 0.14).rounded())) }
    /// Every content edge on the page: the title bar's inset, the toolbar,
    /// the canvas and the table text all hang from this guide.
    static let gutter: CGFloat = Chrome.inset

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if layerActive { restrictionBar }
                    desk
                }
                // The page title and cards share one leading guide.
                .padding(.horizontal, Self.gutter)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.clearSelection() }
            Rectangle().fill(Palette.border).frame(width: 1)
            WindowsDeskInspector(model: model)
                .frame(width: 248)
        }
        .background(WindowsDeskGround())
        .onAppear {
            guard live else { return }
            // The desk shows every Desktop at once; a narrowed scope left
            // over from the old page would hide rows with no way back.
            model.scope.spaceId = nil
            model.scope.display = nil
            model.scope.preset = nil
            model.start()
            try? index.refreshRows()
            model.chooseIndex(index.selected, rows: index.rows)
            model.updateHostDisplay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            if live { model.updateHostDisplay() }
        }
        .onDisappear { if live { model.stop() } }
    }

    // MARK: Scope

    /// Windows the page knows about, before any layer or text filter.
    private var totalCount: Int { model.projection.all.count }
    /// Windows the list and maps show.
    private var visibleCount: Int { model.projection.rows.count }
    private var layerActive: Bool { !index.selected.isEmpty }
    private var searchText: String { model.scope.search.trimmingCharacters(in: .whitespaces) }
    private var restricted: Bool { layerActive || !searchText.isEmpty }

    /// The active layer restriction, stated where the list starts: which
    /// layer, how much of the desk it shows, and the way back. It is never
    /// cleared on its own; the bar is how you leave it.
    private var restrictionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Self.accent)
            Text("Showing layer \(Text(layerTitle).foregroundColor(Palette.text).fontWeight(.semibold))")
                .foregroundColor(Palette.textDim)
                .font(Typo.body(12))
                .lineLimit(1)
            Text("\(visibleCount) of \(totalCount) windows")
                .font(Typo.body(12)).foregroundColor(Palette.textDim)
                .monospacedDigit()
            if !searchText.isEmpty {
                Text("matching “\(searchText)”")
                    .font(Typo.body(12)).foregroundColor(Palette.textMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { pickLayer(nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    Text("Show all layers").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
            }
            .buttonStyle(DeskTileButtonStyle(emphasis: true))
            .help("Clear the layer restriction")
        }
        .padding(.leading, Self.gutter)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Self.accent.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.accent.opacity(0.38), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Showing layer \(layerTitle), \(visibleCount) of \(totalCount) windows")
    }

    private var layerTitle: String {
        let picked = index.rows.filter { index.selected.contains($0.id) }
        return picked.isEmpty ? "All layers" : picked.map(\.label).joined(separator: " + ")
    }

    private func pickLayer(_ id: String?) {
        index.select(id.map { [$0] } ?? [])
        model.chooseIndex(index.selected, rows: index.rows)
    }

    // MARK: Desk

    private func space(of monitor: OverviewDeskMonitor) -> OverviewDeskSpace? {
        if let id = viewed[monitor.display.index], let space = monitor.spaces.first(where: { $0.spaceId == id }) {
            return space
        }
        return monitor.spaces.first(where: \.isCurrent) ?? monitor.spaces.first
    }

    /// One scale for every monitor so they compare, fitted to the width
    /// with each map no taller than `mapHeight(for:)`.
    private func mapSizes(_ desk: [OverviewDeskMonitor], width: CGFloat) -> [CGSize] {
        let sizes = desk.map { m -> CGSize in
            let b = m.display.bounds
            return b.width > 0 && b.height > 0 ? b.size : CGSize(width: 1600, height: 1000)
        }
        let across = width - 16 * CGFloat(max(desk.count - 1, 0))
        let scale = min(across / max(sizes.reduce(0) { $0 + $1.width }, 1),
                        Self.mapHeight(for: width) / max(sizes.map(\.height).max() ?? 1, 1))
        return sizes.map { CGSize(width: ($0.width * scale).rounded(), height: ($0.height * scale).rounded()) }
    }

    private var desk: some View {
        let monitors = model.projection.desk
        let sizes = mapSizes(monitors, width: deskWidth)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: Self.gutter) {
                ForEach(Array(monitors.enumerated()), id: \.element.id) { i, monitor in
                    displayColumn(monitor, size: sizes[i])
                }
            }
            // Let the available width drive map sizing, including below the
            // initial 900pt estimate; otherwise that estimate becomes a minimum.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { deskWidth = $0 }
            .padding(Self.gutter)
            .background(WindowsDeskStage())

            // Rows pad their own 6pt, so 10 here puts the text on the same
            // inner guide as the canvas content above.
            table
                .padding(.horizontal, Self.gutter - 6)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.018))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, lineWidth: 1))
                )
        }
    }

    private func displayColumn(_ monitor: OverviewDeskMonitor, size: CGSize) -> some View {
        let shown = space(of: monitor)
        return VStack(alignment: .leading, spacing: 8) {
            // Name over tabs on every display, so the names share one line
            // and the maps start level beneath them.
            VStack(alignment: .leading, spacing: 6) {
                head(monitor)
                ScrollView(.horizontal, showsIndicators: false) { tabs(monitor, shown: shown) }
                    .frame(height: 22)
            }
            .frame(width: size.width, alignment: .leading)
            if let shown {
                OverviewMap(model: model, display: monitor.display, space: shown, size: size)
                    .frame(width: size.width, height: size.height)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)).frame(width: size.width, height: size.height)
            }
        }
    }

    private func head(_ monitor: OverviewDeskMonitor) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(monitor.display.name).font(Typo.heading(12)).foregroundColor(Palette.text)
                .lineLimit(1)
            Text(String(Int(monitor.display.bounds.width)) + "×" + String(Int(monitor.display.bounds.height)))
                .font(Typo.mono(10)).foregroundColor(Palette.textMuted)
                .fixedSize()
        }
    }

    private func tabs(_ monitor: OverviewDeskMonitor, shown: OverviewDeskSpace?) -> some View {
        HStack(spacing: 2) {
            ForEach(monitor.spaces) { space in
                let selected = space.spaceId == shown?.spaceId
                Button {
                    viewed[monitor.display.index] = space.spaceId
                } label: {
                    HStack(spacing: 4) {
                        if space.isCurrent { Circle().fill(Palette.textDim).frame(width: 4, height: 4) }
                        Text(space.desktop.map(String.init) ?? "FS")
                    }
                    .font(Typo.body(11)).monospacedDigit()
                    .foregroundColor(selected ? Palette.text : space.rows.isEmpty ? Palette.textMuted : Palette.textDim)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Self.raised : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.isCurrent ? "\(space.title), showing now" : space.title)
            }
        }
        .fixedSize()
    }

    // MARK: Table

    private var table: some View {
        let displays = model.projection.displays
        let sections = WindowsDeskTableSection.make(rows: model.projection.rows, displays: displays,
                                                   grouping: grouping, subgrouping: subgrouping)
        let order = sections.flatMap { $0.rows.map(\.wid) }
        let columns = WindowsDeskColumns(roomy: deskWidth >= 900)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Windows").font(Typo.heading(13)).foregroundColor(Palette.text)
                Spacer()
                groupingMenu
            }
            .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 10)

            columns.header
            if restricted && visibleCount == 0 {
                noMatches
            } else if order.isEmpty {
                Text("No windows to show")
                    .font(Typo.body(12)).foregroundColor(Palette.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 20)
            }
            ForEach(sections) { section in
                if let title = section.title { groupHead(title, nested: false) }
                if let title = section.subtitle { groupHead(title, nested: true) }
                ForEach(section.rows) { row in
                    let display = displays.first { $0.index == row.display }
                    WindowsDeskRow(model: model, row: row, display: display, columns: columns, order: order)
                }
            }
        }
    }

    private var groupingMenu: some View {
        Menu {
            Picker("Group by", selection: $grouping) {
                ForEach(WindowsDeskGrouping.allCases) { Text($0.label).tag($0) }
            }
            if grouping != .none {
                Picker("Then by", selection: $subgrouping) {
                    ForEach(WindowsDeskGrouping.allCases.filter { $0 != grouping }) { Text($0.label).tag($0) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                Text(grouping == .none ? "No grouping" : "Group by \(grouping.label)")
                if subgrouping != .none && subgrouping != grouping && grouping != .none {
                    Text("· \(subgrouping.label)")
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }
            .font(Typo.body(12)).foregroundColor(Palette.textDim)
            .padding(.horizontal, 8).frame(height: Chrome.controlHeight)
            .background(RoundedRectangle(cornerRadius: Chrome.controlRadius).fill(Self.controlFill)
                .overlay(RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .strokeBorder(Palette.borderLit, lineWidth: 1)))
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("Group every matching window, across all monitors and Desktops")
        .onChange(of: grouping) { value in
            if subgrouping == value { subgrouping = .none }
        }
    }

    /// Every window filtered away: name the restriction and offer the way
    /// back, instead of a column of empty Desktops.
    private var noMatches: some View {
        HStack(spacing: 10) {
            Text(layerActive && searchText.isEmpty
                 ? "No windows on \(layerTitle)"
                 : "No windows match the current filter")
                .font(Typo.body(12)).foregroundColor(Palette.text)
            if layerActive {
                Button("Show all layers") { pickLayer(nil) }
                    .buttonStyle(.link).font(Typo.body(12))
            }
            if !searchText.isEmpty {
                Button("Clear filter") { model.scope.search = "" }
                    .buttonStyle(.link).font(Typo.body(12))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func groupHead(_ title: String, nested: Bool) -> some View {
        Text(title)
            .font(nested ? Typo.body(11) : Typo.heading(12))
            .foregroundColor(Palette.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, nested ? 16 : 6)
            .padding(.top, nested ? 8 : 16).padding(.bottom, 6)
    }

    /// Where a window sits on its monitor, in a word.
    static func `where`(_ row: OverviewRow, on display: OverviewDisplay) -> String {
        guard let frame = row.frame, display.bounds.width > 0 else { return "—" }
        let width = frame.width / display.bounds.width
        let centre = (frame.midX - display.bounds.minX) / display.bounds.width
        if width > 0.9 { return "Full" }
        if centre < 0.4 { return "Left" }
        if centre > 0.6 { return "Right" }
        return "Centre"
    }
}

// MARK: - Table organization

/// The Windows controls live in the app's title bar, beside Here and Search.
/// They observe the same model as the desk, so filtering keeps its selection,
/// keyboard focus and live counts without a second toolbar in the page.
struct WindowsDeskHeader<Navigation: View>: View {
    @ObservedObject var model: OverviewModel
    @ObservedObject private var index = LayerIndexState.shared
    @FocusState private var filterFocused: Bool
    private let navigation: (Bool) -> Navigation

    init(model: OverviewModel, @ViewBuilder navigation: @escaping (Bool) -> Navigation) {
        self.model = model
        self.navigation = navigation
    }

    private var totalCount: Int { model.projection.all.count }
    private var visibleCount: Int { model.projection.rows.count }
    private var searchText: String { model.scope.search.trimmingCharacters(in: .whitespaces) }
    private var layerActive: Bool { !index.selected.isEmpty }
    private var restricted: Bool { layerActive || !searchText.isEmpty }
    private var layerTitle: String {
        let picked = index.rows.filter { index.selected.contains($0.id) }
        return picked.isEmpty ? "All layers" : picked.map(\.label).joined(separator: " + ")
    }
    private var summary: String {
        let count = restricted ? "\(visibleCount) of \(totalCount) windows" : "\(visibleCount) windows"
        return "\(count) on \(model.projection.displays.count) displays"
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 8) {
                title(width: width)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                layerMenu(compact: width < 600)
                filterField(width: width >= 940 ? 200 : width >= 600 ? 160 : width >= 520 ? 120 : 90)
                if width >= 600 {
                    Rectangle().fill(Palette.borderLit).frame(width: 1, height: 16)
                        .padding(.horizontal, 4)
                }
                navigation(width < 840)
            }
            .padding(.horizontal, Chrome.inset)
            .frame(height: Chrome.titleBarHeight)
        }
        .frame(height: Chrome.titleBarHeight)
        .background(Palette.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: Chrome.hairline)
        }
    }

    @ViewBuilder
    private func title(width: CGFloat) -> some View {
        let name = Text("Windows").font(Typo.heading(15)).foregroundColor(Palette.text)
        let count = Text(width < 600
                         ? restricted ? "\(visibleCount) of \(totalCount) windows" : "\(visibleCount) windows"
                         : summary)
            .font(Typo.body(12)).foregroundColor(Palette.textDim).monospacedDigit()
            .lineLimit(1).truncationMode(.tail)
            .help(summary)
        if width >= 1000 {
            HStack(spacing: 12) { name; count }
        } else {
            VStack(alignment: .leading, spacing: 1) { name; count }
        }
    }

    private func pickLayer(_ id: String?) {
        index.select(id.map { [$0] } ?? [])
        model.chooseIndex(index.selected, rows: index.rows)
    }

    private func layerMenu(compact: Bool) -> some View {
        Menu {
            Button("All layers") { pickLayer(nil) }
            Divider()
            ForEach(index.rows, id: \.id) { row in
                Button(row.label) { pickLayer(row.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(layerActive ? WindowsDeskView.accent : Palette.textDim)
                if !compact {
                    Text(layerTitle).lineLimit(1).truncationMode(.tail)
                        .fontWeight(layerActive ? .semibold : .regular)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .font(Typo.body(12)).foregroundColor(Palette.text)
            .padding(.horizontal, 9)
            .frame(height: Chrome.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .fill(layerActive ? WindowsDeskView.accent.opacity(0.16) : Color.black.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: Chrome.controlRadius)
                        .strokeBorder(layerActive ? WindowsDeskView.accent.opacity(0.55)
                                      : WindowsDeskView.controlEdge, lineWidth: 1))
            )
        }
        .menuStyle(.button).buttonStyle(.plain)
        .frame(maxWidth: compact ? 32 : 180)
        .fixedSize()
        .accessibilityLabel("Layer filter: \(layerTitle)")
        .help("Layer filter: \(layerTitle)")
    }

    private func filterField(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Palette.textDim)
            TextField("Filter", text: $model.scope.search,
                      prompt: Text("Filter").foregroundColor(Palette.textDim))
                .textFieldStyle(.plain)
                .font(Typo.body(13)).foregroundColor(Palette.text)
                .focused($filterFocused)
                .accessibilityLabel("Filter windows")
            if searchText.isEmpty {
                if width >= 120 { KeyCap("/").accessibilityHidden(true) }
            } else {
                Button { model.scope.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(Palette.textDim)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: Chrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: Chrome.controlRadius).fill(Color.black.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .strokeBorder(!searchText.isEmpty ? WindowsDeskView.accent.opacity(0.55)
                                  : filterFocused ? Color.white.opacity(0.42) : WindowsDeskView.controlEdge, lineWidth: 1))
        )
        .help("Filter windows · /")
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("/", modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

enum WindowsDeskGrouping: String, CaseIterable, Identifiable {
    case none, application, monitor, desktop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .application: return "Application"
        case .monitor: return "Monitor"
        case .desktop: return "Desktop"
        }
    }

    fileprivate func key(_ row: OverviewRow) -> String {
        let monitor = row.display.map { String(format: "%08d", $0) } ?? "~"
        switch self {
        case .none: return "all"
        case .application: return row.app
        case .monitor: return monitor
        case .desktop: return monitor + ":" + (row.spaceId.map { String(format: "%08d", $0) } ?? "~")
        }
    }

    fileprivate func title(_ row: OverviewRow, displays: [OverviewDisplay]) -> String {
        let display = displays.first { $0.index == row.display }
        switch self {
        case .none: return ""
        case .application: return row.app
        case .monitor: return display?.name ?? "Off screen"
        case .desktop:
            guard let display else { return "Off screen" }
            let desktop = row.spaceId.flatMap { display.desktopNumber(of: $0) }
                .map { "Desktop \($0)" } ?? row.state.label
            return "\(display.name) · \(desktop)"
        }
    }
}

/// Presentation order is independent from monitor-map tabs. A window appears
/// once, even when it belongs to several Spaces, and subgroup ids retain their
/// parent so identically named Desktops on different monitors never collide.
struct WindowsDeskTableSection: Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let rows: [OverviewRow]

    static func make(rows: [OverviewRow], displays: [OverviewDisplay], grouping: WindowsDeskGrouping,
                     subgrouping: WindowsDeskGrouping = .none) -> [Self] {
        var seen = Set<UInt32>()
        let unique = rows.filter { seen.insert($0.wid).inserted }.sorted {
            let app = $0.app.localizedStandardCompare($1.app)
            if app != .orderedSame { return app == .orderedAscending }
            let title = $0.title.localizedStandardCompare($1.title)
            return title == .orderedSame ? $0.wid < $1.wid : title == .orderedAscending
        }
        func buckets(_ rows: [OverviewRow], by kind: WindowsDeskGrouping) -> [(key: String, title: String, rows: [OverviewRow])] {
            Dictionary(grouping: rows, by: { kind.key($0) })
                .sorted {
                    // Numeric display/Space keys keep physical order, with
                    // unplaced windows last. App names use natural sorting.
                    kind == .application
                        ? $0.key.localizedStandardCompare($1.key) == .orderedAscending
                        : $0.key < $1.key
                }
                .map { (key: $0.key, title: kind.title($0.value[0], displays: displays), rows: $0.value) }
        }
        return buckets(unique, by: grouping).flatMap { parent -> [Self] in
            guard grouping != .none, subgrouping != .none, subgrouping != grouping else {
                return [Self(id: parent.key, title: grouping == .none ? nil : parent.title, subtitle: nil, rows: parent.rows)]
            }
            return buckets(parent.rows, by: subgrouping).enumerated().map { index, child in
                Self(id: parent.key + "/" + child.key, title: index == 0 ? parent.title : nil,
                     subtitle: child.title, rows: child.rows)
            }
        }
    }
}

struct WindowsDeskColumns {
    let roomy: Bool
    static let spacing: CGFloat = 12
    var application: CGFloat { roomy ? 176 : 148 }
    var monitor: CGFloat { roomy ? 152 : 124 }
    var desktop: CGFloat { 64 }
    var position: CGFloat { 80 }

    var header: some View {
        HStack(spacing: Self.spacing) {
            Text("Application").frame(width: application, alignment: .leading)
            Text("Window").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text("Monitor").frame(width: monitor, alignment: .leading)
            Text("Desktop").frame(width: desktop, alignment: .leading)
            if roomy { Text("Position").frame(width: position, alignment: .leading) }
        }
        .font(Typo.body(11)).foregroundColor(Palette.textDim)
        .padding(.horizontal, 6).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

// MARK: - Row

struct WindowsDeskRow: View {
    @ObservedObject var model: OverviewModel
    let row: OverviewRow
    let display: OverviewDisplay?
    let columns: WindowsDeskColumns
    let order: [UInt32]
    @State private var hovered = false

    private var selected: Bool { model.selection.contains(row.wid) }

    private var desktop: String {
        row.spaceId.flatMap { display?.desktopNumber(of: $0) }.map(String.init)
            ?? (row.state == .fullScreen ? "Full screen" : "—")
    }

    private var place: String {
        display.map { WindowsDeskView.where(row, on: $0) } ?? "—"
    }

    var body: some View {
        HStack(spacing: WindowsDeskColumns.spacing) {
            HStack(spacing: 10) {
                WindowsDeskAppIcon(pid: row.pid, size: 24)
                Text(row.app).font(Typo.body(13)).foregroundColor(Palette.text).lineLimit(1)
            }
            .frame(width: columns.application, alignment: .leading)
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(Typo.body(12)).foregroundColor(selected ? Palette.text : Palette.textDim)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help("\(row.title)\n\(row.state.label)")
            Text(display?.name ?? "Off screen")
                .frame(width: columns.monitor, alignment: .leading)
                .help(display?.name ?? row.state.label)
            Text(desktop).monospacedDigit()
                .frame(width: columns.desktop, alignment: .leading)
            if columns.roomy {
                Text(place).frame(width: columns.position, alignment: .leading)
            }
        }
        .font(Typo.body(12)).foregroundColor(Palette.textDim).lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(
                selected ? WindowsDeskView.accent.opacity(0.16) : hovered ? Color.white.opacity(0.04) : .clear)
        )
        // A leading coral tick so selection reads even at a glance across a
        // wide row; drawn inside the rounded fill, never clipped by it.
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(WindowsDeskView.accent).frame(width: 1, height: 22).padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.select(row.wid); model.focus(row.wid) }
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) { model.toggle(row.wid) }
            else if mods.contains(.shift) { model.extend(to: row.wid, orderedRows: order) }
            else { model.select(row.wid) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct WindowsDeskAppIcon: View {
    let pid: Int32
    let size: CGFloat

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow").font(.system(size: size * 0.8)).foregroundColor(Palette.textDim)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Inspector

struct WindowsDeskInspector: View {
    @ObservedObject var model: OverviewModel

    private static let placements: [(TilePosition, String, String)] = [
        (.left, "Left", "rectangle.lefthalf.inset.filled"),
        (.right, "Right", "rectangle.righthalf.inset.filled"),
        (.maximize, "Fill", "rectangle.inset.filled"),
        (.center, "Centre", "rectangle.center.inset.filled"),
    ]

    var body: some View {
        Group {
            if let wid = model.focusedWid, let row = model.projection.all[wid] {
                ScrollView {
                    content(row)
                        .padding(.horizontal, 16)
                        .padding(.top, 1)
                        .padding(.bottom, 16)
                }
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 14) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(LinearGradient(
                                colors: [Color.white.opacity(0.65), Color.white.opacity(0.22)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .accessibilityHidden(true)
                        VStack(spacing: 6) {
                            Text("Select a window")
                                .font(Typo.body(13)).foregroundColor(Palette.textDim)
                            Text("Choose one from the canvas or list.")
                                .font(Typo.body(11)).foregroundColor(Palette.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, min(200, geometry.size.height * 0.26))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.012))
    }

    private func display(of row: OverviewRow) -> OverviewDisplay? {
        row.display.flatMap { index in model.projection.displays.first { $0.index == index } }
    }

    private func content(_ row: OverviewRow) -> some View {
        let display = display(of: row)
        let layers = model.layers.filter { row.layerIds.contains($0.id) }.map(\.label)
        let canPlace = model.projection.placeExclusion(row.wid) == nil
        let targets = model.projection.moveTargets(for: row.wid)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    WindowsDeskAppIcon(pid: row.pid, size: 24)
                    Text(row.app).font(Typo.body(12)).foregroundColor(Palette.textDim)
                }
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(Typo.body(15)).foregroundColor(Palette.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                fact("Display", display?.name ?? "—")
                fact("Desktop", row.spaceId.flatMap { display?.desktopNumber(of: $0) }.map(String.init) ?? row.state.label)
                fact("Layer", layers.isEmpty ? "None" : layers.joined(separator: ", "))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }

            Button { model.focus(row.wid) } label: {
                HStack(spacing: 8) {
                    Text(row.state == .unknown ? "Restore" : "Focus").font(Typo.heading(13))
                    Spacer()
                    KeyCap("↵").accessibilityHidden(true)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(DeskPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityHint("Press Return to \(row.state == .unknown ? "restore" : "focus") this window")

            if let here = model.bringHereTarget(for: row.wid) {
                Button { model.move(row.wid, toSpace: here.spaceId) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.left.square").font(.system(size: 11))
                        Text("Bring here").font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(DeskTileButtonStyle(emphasis: true))
                .disabled(!model.moving.isEmpty)
                .help("Move to \(here.title)")
                .accessibilityLabel("Bring here — \(here.title)")
            }

            section("Place") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Self.placements, id: \.0) { position, label, symbol in
                        Button { model.place(row.wid, at: position) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
                                Text(label).font(Typo.body(12))
                            }
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, 9)
                        }
                        .buttonStyle(DeskTileButtonStyle())
                        .disabled(!canPlace)
                    }
                }
            }

            if let display, !display.desktops.isEmpty {
                section("Move to desktop") {
                    // A fixed column count keeps two-digit desktops on one line
                    // and wraps long lists into even rows.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                             count: min(8, display.desktops.count)), spacing: 4) {
                        ForEach(Array(display.desktops.enumerated()), id: \.offset) { i, spaceId in
                            let here = spaceId == row.spaceId
                            let available = targets.contains { $0.spaceId == spaceId } && model.moving.isEmpty
                            Button { model.move(row.wid, toSpace: spaceId) } label: {
                                Text("\(i + 1)")
                                    .font(Typo.body(12)).monospacedDigit()
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, minHeight: 26)
                            }
                            .buttonStyle(DeskTileButtonStyle(radius: 5, current: here))
                            .disabled(here || !available)
                            .help(here ? "Current desktop" : "Move to Desktop \(i + 1)")
                        }
                    }
                }
            }
            if model.moving.contains(row.wid) {
                Text("Moving…").font(Typo.body(11)).foregroundColor(Palette.textDim)
            } else if let error = model.actionError, error.wid == row.wid {
                Text(error.destination == nil ? error.failure.details : error.failure.message)
                    .font(Typo.body(11)).foregroundColor(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundColor(Palette.textMuted).frame(width: 60, alignment: .leading)
            Text(value).foregroundColor(Palette.text).lineLimit(1).truncationMode(.tail)
        }
        .font(Typo.body(12))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.heading(12)).foregroundColor(Palette.textDim)
            content()
        }
    }
}

/// Focus is a calm, raised action. Coral remains the selection/filter signal.
private struct DeskPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Chrome.controlRadius)
            configuration.label
                .foregroundColor(Palette.text)
                .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.05 : hovered ? 0.16 : 0.10)))
                .overlay(shape.strokeBorder(Color.white.opacity(hovered ? 0.26 : 0.16), lineWidth: 1))
                .overlay(shape.strokeBorder(Color.white.opacity(focused ? 0.5 : 0), lineWidth: 1).padding(-2))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.1), value: hovered)
        }
    }
}

/// Secondary inspector buttons: a raised tile that lifts on hover and sinks
/// when pressed. `current` marks the state the window is already in.
private struct DeskTileButtonStyle: ButtonStyle {
    var radius: CGFloat = 6
    var emphasis = false
    var current = false

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, radius: radius, emphasis: emphasis, current: current)
    }

    private struct Tile: View {
        let configuration: Configuration
        let radius: CGFloat
        let emphasis: Bool
        let current: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius)
            let fill: Color = current ? .clear
                : configuration.isPressed ? Color(white: 0.16)
                : hovered && enabled ? Color(white: 0.235)
                : WindowsDeskView.raised
            configuration.label
                .foregroundColor(current || emphasis || (hovered && enabled) ? Palette.text : Palette.textDim)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(current ? Palette.borderLit : .clear))
                .contentShape(shape)
                .opacity(enabled || current ? 1 : 0.45)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.1), value: hovered)
        }
    }
}

/// A single overhead light across the whole Windows page. Child surfaces
/// transmit it, so the list and inspector belong to the same space.
private struct WindowsDeskGround: View {
    var body: some View {
        ZStack {
            EllipticalGradient(
                stops: [
                    .init(color: Color(red: 0.20, green: 0.205, blue: 0.22), location: 0),
                    .init(color: Color(red: 0.12, green: 0.123, blue: 0.135), location: 0.58),
                    .init(color: Palette.bg, location: 1),
                ],
                center: UnitPoint(x: 0.45, y: -0.08),
                startRadiusFraction: 0, endRadiusFraction: 1.1
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Only the monitor canvas carries the dot texture, recessed into the lit room.
private struct WindowsDeskStage: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        shape.fill(Color.black.opacity(0.18))
            .overlay(OverviewStageGround(dotOpacity: 0.14, dotSize: 1.2))
            .clipShape(shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [OverviewChrome.edgeLit, OverviewChrome.edge], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            ))
    }
}
