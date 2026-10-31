import AppKit
import SwiftUI

/// The Windows page as one desk: every monitor side by side as it sits, each
/// with its Desktops as tabs over its map, then one table of the same windows
/// grouped by monitor and Desktop, then what's off screen. Layers are a quiet
/// filter; the selected window's actions live in the inspector on the right.
struct WindowsDeskView: View {
    @ObservedObject var model: OverviewModel
    @ObservedObject private var index = LayerIndexState.shared
    /// The Desktop each monitor's map shows, by display index. Absent means
    /// the one it's showing.
    @State private var viewed: [Int: Int] = [:]
    @FocusState private var filterFocused: Bool
    @State private var deskWidth: CGFloat = 900

    /// One surface ladder for the page: the canvas is its own cool slate so it
    /// reads as a different place, lists and controls sit a step above the
    /// page, and the selected or pressable thing one step higher again. Coral
    /// marks selection.
    static let accent = Color(red: 0.937, green: 0.416, blue: 0.278)
    static let stage = Color(red: 0.085, green: 0.105, blue: 0.15)
    static let card = Color(white: 0.145)
    static let raised = Color(white: 0.19)
    static let mapHeight: CGFloat = 230

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    toolbar
                    desk
                }
                // The toolbar shares a guide with the sidebar's first section
                // header, which sits just under the title bar.
                .padding(.horizontal, 18)
                .padding(.top, 1)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.clearSelection() }
            Rectangle().fill(Palette.border).frame(width: 1)
            WindowsDeskInspector(model: model)
                .frame(width: 248)
        }
        .background(Palette.bg)
        .onAppear {
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
        .onDisappear { model.stop() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            let count = model.projection.rows.count
            (Text("\(count)").foregroundColor(Palette.text).fontWeight(.semibold)
                + Text(" windows on \(model.projection.displays.count) displays").foregroundColor(Palette.textDim))
                .font(Typo.body(12))
            Spacer(minLength: 8)
            layerMenu
            filterField
        }
        .frame(height: 28)
    }

    private var layerTitle: String {
        let picked = index.rows.filter { index.selected.contains($0.id) }
        return picked.isEmpty ? "All layers" : picked.map(\.label).joined(separator: " + ")
    }

    private func pickLayer(_ id: String?) {
        index.select(id.map { [$0] } ?? [])
        model.chooseIndex(index.selected, rows: index.rows)
    }

    private var layerMenu: some View {
        Menu {
            Button("All layers") { pickLayer(nil) }
            Divider()
            ForEach(index.rows, id: \.id) { row in
                Button(row.label) { pickLayer(row.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(layerTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(Typo.body(12))
            .foregroundColor(Palette.textDim)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Self.card))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(Palette.textMuted)
            TextField("Filter", text: $model.scope.search)
                .textFieldStyle(.plain)
                .font(Typo.body(12))
                .focused($filterFocused)
            Text("/").font(Typo.mono(10)).foregroundColor(Palette.textMuted)
        }
        .padding(.horizontal, 9)
        .frame(width: 180, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Self.card))
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("/", modifiers: [])
                .opacity(0)
        }
    }

    // MARK: Desk

    private func space(of monitor: OverviewDeskMonitor) -> OverviewDeskSpace? {
        if let id = viewed[monitor.display.index], let space = monitor.spaces.first(where: { $0.spaceId == id }) {
            return space
        }
        return monitor.spaces.first(where: \.isCurrent) ?? monitor.spaces.first
    }

    /// One scale for every monitor so they compare, fitted to the width
    /// with each map no taller than `mapHeight`.
    private func mapSizes(_ desk: [OverviewDeskMonitor], width: CGFloat) -> [CGSize] {
        let sizes = desk.map { m -> CGSize in
            let b = m.display.bounds
            return b.width > 0 && b.height > 0 ? b.size : CGSize(width: 1600, height: 1000)
        }
        let across = width - 16 * CGFloat(max(desk.count - 1, 0))
        let scale = min(across / max(sizes.reduce(0) { $0 + $1.width }, 1),
                        Self.mapHeight / max(sizes.map(\.height).max() ?? 1, 1))
        return sizes.map { CGSize(width: ($0.width * scale).rounded(), height: ($0.height * scale).rounded()) }
    }

    private var desk: some View {
        let monitors = model.projection.desk
        let sizes = mapSizes(monitors, width: deskWidth)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(monitors.enumerated()), id: \.element.id) { i, monitor in
                    displayColumn(monitor, size: sizes[i])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { deskWidth = $0 }
            .padding(16)
            .background(WindowsDeskStage())

            table(monitors)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Self.card))
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
            Text(monitor.display.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Palette.text)
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
                    .font(Typo.mono(11))
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

    private func table(_ monitors: [OverviewDeskMonitor]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(monitors) { monitor in
                let shown = space(of: monitor)
                groupHead(monitor.display.name, detail: shown?.title)
                if let rows = shown?.rows, !rows.isEmpty {
                    ForEach(rows) { row in
                        WindowsDeskRow(model: model, row: row, place: Self.where(row, on: monitor.display))
                    }
                } else {
                    Text("Nothing on this Desktop")
                        .font(Typo.body(12)).foregroundColor(Palette.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            if !model.projection.unplaced.isEmpty {
                groupHead("Off screen", detail: nil)
                ForEach(model.projection.unplaced) { row in
                    WindowsDeskRow(model: model, row: row, place: row.state.label)
                }
            }
        }
    }

    private func groupHead(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.7).foregroundColor(Palette.textMuted)
            if let detail { Text(detail).font(Typo.body(11)).foregroundColor(Palette.textMuted) }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 4)
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

// MARK: - Row

struct WindowsDeskRow: View {
    @ObservedObject var model: OverviewModel
    let row: OverviewRow
    let place: String
    @State private var hovered = false

    private var selected: Bool { model.selection.contains(row.wid) }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                WindowsDeskAppIcon(pid: row.pid, size: 14)
                Text(row.app).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.text).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(Typo.mono(11)).foregroundColor(Palette.textDim)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(place).font(Typo.body(11)).foregroundColor(Palette.textMuted)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(
                selected ? WindowsDeskView.accent.opacity(0.16) : hovered ? Color.white.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.select(row.wid); model.focus(row.wid) }
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) { model.toggle(row.wid) }
            else if mods.contains(.shift) { model.extend(to: row.wid) }
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
        if let wid = model.focusedWid, let row = model.projection.all[wid] {
            ScrollView {
                content(row)
                    .padding(.horizontal, 16)
                    .padding(.top, 1)
                    .padding(.bottom, 16)
            }
        } else {
            Text("Select a window")
                .font(Typo.body(12)).foregroundColor(Palette.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    WindowsDeskAppIcon(pid: row.pid, size: 20)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(WindowsDeskView.raised))
                    Text(row.app).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.text)
                }
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(Typo.mono(11)).foregroundColor(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                fact("Display", display?.name ?? "—")
                fact("Desktop", row.spaceId.flatMap { display?.desktopNumber(of: $0) }.map(String.init) ?? row.state.label)
                fact("Layer", layers.isEmpty ? "None" : layers.joined(separator: ", "))
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }

            Button { model.focus(row.wid) } label: {
                HStack(spacing: 8) {
                    Text(row.state == .unknown ? "Restore" : "Focus").font(.system(size: 12, weight: .semibold))
                    Text("↵").font(Typo.mono(10)).opacity(0.7)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(WindowsDeskView.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            section("Place") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Self.placements, id: \.0) { position, label, symbol in
                        Button { model.place(row.wid, at: position) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: symbol).font(.system(size: 11))
                                Text(label)
                            }
                            .font(Typo.body(12))
                            .foregroundColor(Palette.textDim)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, 9)
                            .background(RoundedRectangle(cornerRadius: 6).fill(WindowsDeskView.raised))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlace)
                        .opacity(canPlace ? 1 : 0.45)
                    }
                }
            }

            if let display, !display.desktops.isEmpty {
                section("Move to desktop") {
                    HStack(spacing: 4) {
                        ForEach(Array(display.desktops.enumerated()), id: \.offset) { i, spaceId in
                            let here = spaceId == row.spaceId
                            let target = targets.first { $0.spaceId == spaceId }
                            Button { model.move(row.wid, toSpace: spaceId) } label: {
                                Text("\(i + 1)")
                                    .font(Typo.mono(11))
                                    .foregroundColor(here ? Palette.textMuted : Palette.textDim)
                                    .frame(maxWidth: .infinity, minHeight: 26)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(here ? Color.clear : WindowsDeskView.raised))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(here ? Palette.borderLit : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(here || target == nil || !model.moving.isEmpty)
                        }
                    }
                }
            }
            if model.moving.contains(row.wid) {
                Text("Moving…").font(Typo.mono(10)).foregroundColor(Palette.textMuted)
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
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.7).foregroundColor(Palette.textMuted)
            content()
        }
    }
}

/// The canvas the displays sit on: recessed below the page and dotted, so it
/// reads as a place to arrange things rather than another list.
private struct WindowsDeskStage: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        shape.fill(WindowsDeskView.stage)
            .overlay {
                Canvas { context, size in
                    let step: CGFloat = 14
                    var dots = Path()
                    var y = step / 2
                    while y < size.height {
                        var x = step / 2
                        while x < size.width {
                            dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
                            x += step
                        }
                        y += step
                    }
                    context.fill(dots, with: .color(.white.opacity(0.07)))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.border, lineWidth: 1))
    }
}
