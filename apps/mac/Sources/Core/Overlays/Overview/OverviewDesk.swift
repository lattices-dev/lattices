import AppKit
import SwiftUI

// MARK: - Stage

/// The desk drawn to scale: every monitor side by side, as large as the
/// room allows, each with its Desktops beneath its map. A monitor's map
/// shows its focused Desktop, or the one it's showing. Tapping a Desktop
/// focuses the list on it; tapping it again gives the whole list back.
/// Clicking a window selects it; dragging it to a map or Desktop moves it
/// through the same verified path as the window's Move menu.
struct OverviewStage: View {
    @ObservedObject var model: OverviewModel

    static let headHeight: CGFloat = 16
    static let spacing: CGFloat = 8
    static let captionHeight: CGFloat = 12
    static let displayGap: CGFloat = 36
    static let thumbGap: CGFloat = 6
    static let thumbWidth: CGFloat = 84
    static let minThumbWidth: CGFloat = 44
    static let hintHeight: CGFloat = 34
    /// The widest monitor's map never gets narrower; past it the row scrolls.
    static let minMapWidth: CGFloat = 260

    struct Layout: Equatable {
        var maps: [CGSize]
        var thumbs: [CGSize]
    }

    /// One scale for every monitor so they compare, a smaller one drawn a
    /// little larger to stay readable, fitted to `room` below each map's
    /// head and Desktops.
    static func layout(_ desk: [OverviewDeskMonitor], in room: CGSize) -> Layout {
        guard !desk.isEmpty else { return Layout(maps: [], thumbs: []) }
        let sizes: [CGSize] = desk.map { monitor in
            let b = monitor.display.bounds
            return b.width > 0 && b.height > 0 ? b.size : CGSize(width: 1600, height: 1000)
        }
        let widest = sizes.map(\.width).max() ?? 1
        let drawn: [CGSize] = sizes.map { size in
            let boost: CGFloat = size.width < widest * 0.7 ? 1.12 : 1
            return CGSize(width: size.width * boost, height: size.height * boost)
        }
        let thumbRow: CGFloat = sizes.map { thumbWidth / ($0.width / $0.height) }.max() ?? 50
        let chrome = headHeight + spacing * 2 + thumbRow + 4 + captionHeight
        let across = room.width - displayGap * CGFloat(desk.count - 1)
        let byWidth = across / drawn.reduce(0) { $0 + $1.width }
        let byHeight = max(1, room.height - chrome) / (drawn.map(\.height).max() ?? 1)
        let floor = minMapWidth / ((drawn.map(\.width).max()) ?? 1)
        let scale = max(floor, min(byWidth, byHeight))
        let maps = drawn.map { CGSize(width: ($0.width * scale).rounded(), height: ($0.height * scale).rounded()) }
        let thumbs: [CGSize] = zip(desk, maps).enumerated().map { index, pair in
            let count = CGFloat(max(1, pair.0.spaces.count))
            let fit = (pair.1.width - thumbGap * (count - 1)) / count
            let width = max(minThumbWidth, min(thumbWidth, fit)).rounded()
            let aspect = sizes[index].width / sizes[index].height
            return CGSize(width: width, height: (width / aspect).rounded())
        }
        return Layout(maps: maps, thumbs: thumbs)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let layout = Self.layout(model.projection.desk, in: geo.size)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Self.displayGap) {
                        ForEach(Array(model.projection.desk.enumerated()), id: \.element.id) { index, monitor in
                            OverviewDisplayBlock(
                                model: model, monitor: monitor,
                                mapSize: layout.maps[index], thumbSize: layout.thumbs[index],
                                quiet: model.workingRows.isEmpty
                            )
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .overlay {
                    if model.workingRows.isEmpty, !model.projection.desk.isEmpty {
                        OverviewEmptyScope(model: model)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Group {
                if let edit = model.editing {
                    OverviewDraftBar(model: model, edit: edit)
                } else if let wid = model.focusedWid, let row = model.projection.all[wid] {
                    OverviewSelectionBar(model: model, row: row)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                } else {
                    OverviewHint(model: model)
                }
            }
            .frame(height: Self.hintHeight)
            .padding(.horizontal, 24)
        }
        .background(
            ZStack {
                OverviewStageGround()
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearSelection() }
            }
        )
    }
}

// MARK: - Display

/// One monitor: its name and size and what its map shows, the map, and
/// every Desktop it owns beneath it.
struct OverviewDisplayBlock: View {
    @ObservedObject var model: OverviewModel
    let monitor: OverviewDeskMonitor
    let mapSize: CGSize
    let thumbSize: CGSize
    /// Nothing anywhere is in scope; the stage says so once.
    let quiet: Bool

    /// The focused Desktop if it's this monitor's, else the one it shows.
    private var viewed: OverviewDeskSpace? {
        if let id = model.scope.spaceId, let space = monitor.spaces.first(where: { $0.spaceId == id }) {
            return space
        }
        return monitor.spaces.first(where: \.isCurrent) ?? monitor.spaces.first
    }

    /// Another monitor's Desktop, or another monitor, has the focus.
    private var scopedOut: Bool { !monitor.inScope }

    var body: some View {
        VStack(alignment: .leading, spacing: OverviewStage.spacing) {
            head
                .frame(width: mapSize.width, height: OverviewStage.headHeight)
            if let viewed {
                OverviewMap(model: model, display: monitor.display, space: viewed, size: mapSize, quiet: quiet || scopedOut)
                    .opacity(scopedOut ? 0.55 : 1)
            }
            desktops
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(monitor.display.name)
    }

    private var head: some View {
        let b = monitor.display.bounds
        let state: String = {
            guard let viewed else { return "" }
            if viewed.isCurrent { return "live · \(viewed.title)" }
            return "viewing \(viewed.desktop == nil ? "full screen" : viewed.title)"
        }()
        let name = Text(monitor.display.name)
            .font(Typo.monoBold(11))
            .foregroundColor(Palette.text)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The size only where there's room for it whole.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name.fixedSize()
                    Text("\(Int(b.width))×\(Int(b.height))")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textMuted)
                        .fixedSize()
                }
                name.lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Text(state)
                .font(Typo.mono(9))
                .foregroundColor(viewed?.isCurrent == false ? Palette.text : Palette.textDim)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Desktops

    @ViewBuilder
    private var desktops: some View {
        let count = CGFloat(monitor.spaces.count)
        let row = HStack(alignment: .top, spacing: OverviewStage.thumbGap) {
            ForEach(monitor.spaces) { space in thumb(space) }
        }
        if thumbSize.width * count + OverviewStage.thumbGap * (count - 1) > mapSize.width + 1 {
            ScrollView(.horizontal, showsIndicators: false) { row }
                .frame(width: mapSize.width, alignment: .leading)
        } else {
            row
        }
    }

    /// A Desktop in miniature with its name and count. The dot marks the
    /// one this monitor shows; the ring, the focused one. Tapping focuses
    /// the list on it; tapping the focused one gives the whole list back.
    private func thumb(_ space: OverviewDeskSpace) -> some View {
        let focused = model.scope.spaceId == space.spaceId
        let count = space.rows.filter(\.inScope).count
        let state: String = space.isCurrent ? "showing" : (space.mapNote ?? "not showing")
        return Button {
            model.chooseDesktop(space.spaceId)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                OverviewMiniDesktop(model: model, display: monitor.display, space: space, size: thumbSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(focused ? Palette.text : Color.clear, lineWidth: 1.5)
                    )
                HStack(spacing: 4) {
                    if space.isCurrent {
                        Circle().fill(Palette.text).frame(width: 4, height: 4)
                    }
                    // Narrow thumbs keep just the number; help and
                    // accessibility still name the Desktop and monitor.
                    Text(thumbSize.width < 76 ? space.desktop.map { "\($0)" } ?? "FS" : space.title)
                        .font(Typo.mono(8))
                        .foregroundColor(space.isCurrent || focused ? Palette.text : Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(space.rows.isEmpty ? "–" : "\(space.rows.count)")
                        .font(Typo.mono(8))
                        .foregroundColor(Palette.textMuted)
                        .fixedSize()
                }
                .frame(width: thumbSize.width, height: OverviewStage.captionHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OverviewWindowDropTarget(model: model, display: monitor.display, spaceId: space.spaceId, compact: true))
        .help((focused ? "\(space.title) on \(monitor.display.name) · click for every Desktop" : "\(space.title) on \(monitor.display.name), \(state)")
            + (space.desktop == nil ? "" : " · drop a window to move it here"))
        .accessibilityLabel("\(space.title) on \(monitor.display.name), \(state), \(count == 0 ? "nothing in scope" : "\(count) in scope")")
        .accessibilityHint(focused ? "Show every Desktop" : "Focus the list on this Desktop")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

// MARK: - Map

/// A monitor-shaped map of one Desktop: the listed windows at their frames,
/// what the list leaves out faintly behind them. Only the showing Desktop's
/// frames are live; any other says so across its top.
struct OverviewMap: View {
    @ObservedObject var model: OverviewModel
    let display: OverviewDisplay
    let space: OverviewDeskSpace
    let size: CGSize
    /// Don't say "nothing in scope" here: another monitor has the focus, or
    /// the stage says it once for all of them.
    let quiet: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
            ForEach(context, id: \.wid) { tile in contextView(tile) }
            ForEach(tiles.reversed(), id: \.row.wid) { tile in tileView(tile) }
            if !quiet, !space.rows.contains(where: \.inScope) {
                Text("Nothing in scope here")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
            if !space.isCurrent {
                peekBar
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    space.isCurrent ? Palette.borderLit : Palette.textMuted,
                    style: StrokeStyle(lineWidth: OverviewChrome.stroke, dash: space.isCurrent ? [] : [4, 3])
                )
        )
        .modifier(OverviewWindowDropTarget(model: model, display: display, spaceId: space.spaceId))
    }

    /// Why this Desktop's windows can't be acted on, and the way back.
    private var peekBar: some View {
        let text = space.desktop == nil
            ? "Full screen, not showing. Nothing here can be placed."
            : "\(space.title) — last known positions. Not live, so nothing here can be placed or arranged."
        return HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 9))
                .foregroundColor(Palette.textDim)
            Text(text)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Back to live") { model.chooseDesktop(nil) }
                .buttonStyle(.overview(height: 22))
                .fixedSize()
                .help("Every Desktop again; each map shows what its monitor is showing")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.bg.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(OverviewChrome.edgeLit, lineWidth: OverviewChrome.stroke))
        )
        .padding(6)
        .frame(width: size.width, alignment: .leading)
    }

    // MARK: Windows

    private struct Tile {
        let row: OverviewRow
        let rect: CGRect
        let live: Bool
    }

    private func scaled(_ frame: CGRect) -> CGRect? {
        let bounds = display.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let sx: CGFloat = size.width / bounds.width
        let sy: CGFloat = size.height / bounds.height
        let rect = CGRect(
            x: (frame.minX - bounds.minX) * sx, y: (frame.minY - bounds.minY) * sy,
            width: frame.width * sx, height: frame.height * sy
        ).intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, rect.width >= 3, rect.height >= 3 else { return nil }
        return rect
    }

    private var tiles: [Tile] {
        space.rows.compactMap { (row: OverviewRow) -> Tile? in
            let live = space.drawsLive(row)
            if space.desktop == nil {
                return Tile(row: row, rect: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8), live: live)
            }
            guard let frame = row.frame, let rect = scaled(frame) else { return nil }
            return Tile(row: row, rect: rect, live: live)
        }
    }

    /// A window: its app, then its title where there's room. Dashed where
    /// the frame is last known.
    private func tileView(_ tile: Tile) -> some View {
        let wid = tile.row.wid
        let selected = model.selection.contains(wid)
        let scoped = !(model.scope.layerIds ?? model.scope.layerId.map { [$0] } ?? []).isEmpty
        let member = scoped && tile.row.inScope
        let fill: Color = member ? Palette.running.opacity(0.16) : scoped ? Color.clear : selected ? Color.white.opacity(0.2) : (tile.live ? Color(white: 0.17) : Color.white.opacity(0.025))
        let ink: Color = selected ? Palette.text : (tile.live ? Palette.textDim : Palette.textMuted)
        let showsApp = tile.rect.width > 36 && tile.rect.height > 15
        let showsTitle = !tile.row.title.isEmpty && tile.rect.width > 60 && tile.rect.height > 32
        let base = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(fill)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    member ? Palette.running.opacity(0.65) : scoped ? Color.clear : selected ? Palette.text : Color.white.opacity(tile.live ? 0.28 : 0.3),
                    style: StrokeStyle(lineWidth: selected ? 1.5 : OverviewChrome.stroke, dash: tile.live ? [] : [4, 3])
                )
            if showsApp {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scoped && !tile.row.inScope ? tile.row.title : tile.row.app)
                        .font(Typo.monoBold(10))
                        .foregroundColor(ink)
                        .lineLimit(1)
                    if showsTitle && (!scoped || tile.row.inScope) {
                        Text(tile.row.title)
                            .font(Typo.mono(9))
                            .foregroundColor(selected ? Palette.text : Palette.textMuted)
                            .lineLimit(tile.rect.height > 60 ? 2 : 1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 5)
            }
        }
        .frame(width: tile.rect.width, height: tile.rect.height)
        .opacity(tile.row.inScope ? 1 : (scoped ? 0.18 : 0.4))
        .contentShape(Rectangle())
        .onTapGesture { OverviewDeskRow.pick(wid, model: model) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.focus(wid) })
        .modifier(OverviewWindowDragSource(model: model, row: tile.row))
        .help((tile.row.title.isEmpty ? tile.row.app : "\(tile.row.app) — \(tile.row.title)")
            + (model.projection.moveTargets(for: wid).isEmpty ? "" : " · drag to a map or Desktop to move"))
        return base
            .offset(x: tile.rect.minX, y: tile.rect.minY)
            .accessibilityElement()
            .accessibilityLabel("\(tile.row.app), \(tile.row.title.isEmpty ? "Untitled" : tile.row.title), \(tile.live ? "live" : "last known")")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private struct Context {
        let wid: UInt32
        let rect: CGRect
    }

    /// Windows here that the list leaves out: a layer's non-members, or
    /// what search or kind hide. Faint, and never a target.
    private var context: [Context] {
        guard space.desktop != nil else { return [] }
        let listed = Set(model.projection.rows.map(\.wid))
        let rows: [OverviewRow] = model.projection.all.values.filter { row in
            !listed.contains(row.wid) && row.display == display.index && row.spaceId == space.spaceId
        }
        return rows.sorted { $0.wid > $1.wid }.compactMap { row in
            guard let frame = row.frame, let rect = scaled(frame) else { return nil }
            return Context(wid: row.wid, rect: rect)
        }
    }

    private func contextView(_ tile: Context) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.02))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.07), lineWidth: OverviewChrome.stroke))
            .frame(width: tile.rect.width, height: tile.rect.height)
            .offset(x: tile.rect.minX, y: tile.rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty scope

/// Nothing anywhere is in scope: what the scope is, and a way out of each
/// part of it. Every filter that can empty the list has a button here.
struct OverviewEmptyScope: View {
    @ObservedObject var model: OverviewModel

    /// Index picks (several layers, Unassigned) that aren't one ⌘⌥ layer.
    private var pickedLabels: [String] {
        guard model.scope.layerId == nil, let ids = model.scope.layerIds, !ids.isEmpty else { return [] }
        return ids.map { id in model.layerIndexRows.first { $0.id == id }?.label ?? id }
    }

    private var hasLayerScope: Bool {
        model.scope.layerId != nil || !(model.scope.layerIds ?? []).isEmpty || model.scope.scopedWindowIds != nil
    }

    private var sentence: String {
        var parts: [String] = [model.scope.preset.map { $0.lowercased() } ?? "windows"]
        if let id = model.scope.layerId {
            parts.append("in " + (model.layers.first { $0.id == id }?.label ?? id))
        } else if !pickedLabels.isEmpty {
            parts.append("in " + pickedLabels.joined(separator: ", "))
        }
        if let id = model.scope.spaceId, let title = model.projection.desk.flatMap(\.spaces).first(where: { $0.spaceId == id })?.title {
            parts.append("on " + title)
        } else if let index = model.scope.display, let name = model.displays.first(where: { $0.index == index })?.name {
            parts.append("on " + name)
        }
        if !model.scope.search.isEmpty { parts.append("matching “\(model.scope.search)”") }
        return "No \(parts.joined(separator: " "))."
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Nothing in scope")
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)
            Text(sentence)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if model.scope.preset != nil {
                    Button("Clear kind") { model.scope.preset = nil }
                        .buttonStyle(.overview)
                }
                if !model.scope.search.isEmpty {
                    Button("Clear search") { model.scope.search = "" }
                        .buttonStyle(.overview)
                }
                if model.scope.spaceId != nil {
                    Button("Every Desktop") { model.chooseDesktop(nil) }
                        .buttonStyle(.overview)
                } else if model.scope.display != nil {
                    Button("All monitors") { model.scope.display = nil }
                        .buttonStyle(.overview)
                }
                if hasLayerScope {
                    Button("No layer") { model.chooseLayer(nil) }
                        .buttonStyle(.overview)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 320)
        .overviewCard(radius: 9)
    }
}

// MARK: - Hint and draft

/// How to pick, the keys, and what the scope holds.
struct OverviewHint: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        let rows = model.workingRows
        let live = rows.filter { model.projection.placeExclusion($0.wid) == nil }.count
        HStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    Text("Click to select · ⌘-click to add · double-click to focus · drag to a Desktop to move")
                    Text("T · D · / · ↵")
                }
                Text("T · D · / · ↵")
            }
            .font(Typo.mono(9))
            .foregroundColor(Palette.textMuted)
            .lineLimit(1)
            Spacer(minLength: 8)
            (Text("\(rows.count)").foregroundColor(Palette.text) + Text(" in scope · ")
                + Text("\(live)").foregroundColor(Palette.text) + Text(" can arrange · \(rows.count - live) elsewhere"))
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// While a layer is being edited: what's changed and the way out. Saving
/// never arranges; only the active layer can be saved and arranged.
struct OverviewDraftBar: View {
    @ObservedObject var model: OverviewModel
    let edit: LayerEdit

    var body: some View {
        let name = model.layers.first { $0.id == edit.layerId }?.label ?? edit.layerId
        HStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 10))
                .foregroundColor(Palette.textDim)
            Text("Editing ").font(Typo.mono(9)).foregroundColor(Palette.textDim)
                + Text(name).font(Typo.monoBold(9)).foregroundColor(Palette.text)
            Text(edit.hasChanges ? "unsaved changes" : "no changes yet")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("Discard") { model.cancelEditing() }
                .buttonStyle(.overview(.quiet, height: 22))
            Button("Save") { model.saveLayer() }
                .buttonStyle(.overview(height: 22))
                .disabled(!edit.hasChanges)
                .help("Saves the layout and tucks. Doesn't move windows.")
            Button("Save & arrange") { model.saveAndRearrange() }
                .buttonStyle(.overview(height: 22))
                .disabled(!model.canRearrange)
                .help(model.canRearrange ? "Saves, then lays out the active layer's windows again" : "Only the active layer can be arranged")
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 28)
        .overviewCard(radius: 7)
    }
}

// MARK: - Tray

/// Below the maps: every listed window, grouped by Desktop, the ones the
/// maps show first, then the windows on no Space; and the box that
/// arranges the selection.
struct OverviewTray: View {
    @ObservedObject var model: OverviewModel

    static let height: CGFloat = 150

    struct Group: Identifiable {
        let id: String
        let title: String
        let detail: String
        let rows: [OverviewRow]
    }

    var groups: [Group] {
        var shown: [Group] = []
        var rest: [Group] = []
        for monitor in model.projection.desk {
            let viewed = model.scope.spaceId.flatMap { id in monitor.spaces.first { $0.spaceId == id } }
                ?? monitor.spaces.first(where: \.isCurrent)
            for space in monitor.spaces where !space.rows.isEmpty {
                let onMap = space.spaceId == viewed?.spaceId
                let state = onMap ? "on the map" : space.isCurrent ? "live" : (space.mapNote ?? "not showing")
                let group = Group(
                    id: "\(space.spaceId)", title: space.title,
                    detail: "\(monitor.display.name) · \(state)", rows: space.rows
                )
                if onMap { shown.append(group) } else { rest.append(group) }
            }
        }
        if !model.projection.unplaced.isEmpty {
            rest.append(Group(id: "unplaced", title: "Not on a Space", detail: "hidden · minimized", rows: model.projection.unplaced))
        }
        return shown + rest
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let groups = self.groups
                if groups.isEmpty {
                    Text("Nothing listed")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textMuted)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    let width = max(190, min(280, geo.size.width / CGFloat(groups.count)))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(groups) { group in
                                groupView(group)
                                    .frame(width: width, height: geo.size.height, alignment: .topLeading)
                                    .overlay(alignment: .trailing) {
                                        Rectangle().fill(Palette.border).frame(width: 1)
                                    }
                            }
                        }
                    }
                }
            }
            Rectangle().fill(Palette.border).frame(width: 1)
            OverviewArrangeBox(model: model)
        }
        .frame(height: Self.height)
    }

    private func groupView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.title.uppercased())
                    .font(Typo.monoBold(8))
                    .foregroundColor(Palette.textDim)
                    .lineLimit(1)
                    .fixedSize()
                Text(group.detail)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("\(group.rows.count)")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.horizontal, 14)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group.rows) { row in chip(row, unplaced: group.id == "unplaced") }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// A window: app, title, and why it isn't on a map where the group
    /// doesn't already say. Outside the Desktop focus, faint.
    private func chip(_ row: OverviewRow, unplaced: Bool) -> some View {
        let selected = model.selection.contains(row.wid)
        let why: String? = {
            if unplaced { return row.state.label.lowercased() }
            switch row.state {
            case .appHidden: return "hidden"
            case .parked: return "parked"
            default: return LayerOverviewDetail.tierLabel(row.tier)
            }
        }()
        return HStack(spacing: 7) {
            Text(row.app)
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.text)
                .lineLimit(1)
                .fixedSize()
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let why {
                Text(why)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Palette.surfaceHov : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? OverviewChrome.edgeOn : Color.clear, lineWidth: OverviewChrome.stroke)
        )
        .opacity(row.inScope ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { OverviewDeskRow.pick(row.wid, model: model) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.focus(row.wid) })
        .modifier(OverviewWindowDragSource(model: model, row: row))
        .help((row.title.isEmpty ? row.app : "\(row.app) — \(row.title)")
            + (model.projection.moveTargets(for: row.wid).isEmpty ? "" : " · drag to a map or Desktop to move"))
        .accessibilityElement()
        .accessibilityLabel("\(row.app), \(row.title.isEmpty ? "Untitled" : row.title), \(model.projection.location(of: row))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Tile and distribute the selection, monitor by monitor, saying what's
/// left out and why; and the layer in scope, with the way to edit it.
/// Nothing here saves a layer.
struct OverviewArrangeBox: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        let tile = model.plan(.tile)
        let distribute = model.plan(.distribute)
        let names: [Int: String] = Dictionary(uniqueKeysWithValues: model.projection.displays.map { ($0.index, $0.name) })
        let split: String = tile.groups.isEmpty
            ? (model.selection.isEmpty ? "Select windows to arrange them" : "No live windows selected")
            : tile.groups.map { "\(names[$0.display] ?? "Display") \($0.windows.count)" }.joined(separator: " · ")
        let leftOut: String = tile.excluded.isEmpty
            ? "Only live windows on a showing Desktop move"
            : "Left out: \(tile.excludedSummary)"
        VStack(alignment: .leading, spacing: 7) {
            Text("ARRANGE SELECTION")
                .font(Typo.monoBold(8))
                .foregroundColor(Palette.textDim)
            HStack(spacing: 8) {
                arrangeButton(tile, key: "T")
                arrangeButton(distribute, key: "D")
            }
            Text(split)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textDim)
                .lineLimit(1)
            Text(leftOut)
                .font(Typo.mono(8))
                .foregroundColor(Palette.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            layerLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.015))
    }

    private func arrangeButton(_ plan: OverviewBulkPlan, key: String) -> some View {
        Button {
            model.run(plan)
        } label: {
            HStack(spacing: 6) {
                Text("\(plan.action.verb) \(plan.eligibleCount)")
                OverviewKeycap(key: key)
            }
        }
        .buttonStyle(.overview(fill: true))
        .disabled(!plan.isEnabled)
        .help(plan.excludedSummary.isEmpty ? plan.label : "\(plan.label). Left out: \(plan.excludedSummary)")
        .accessibilityLabel(plan.label)
    }

    @ViewBuilder
    private var layerLine: some View {
        if let ids = model.scope.layerIds, ids.count > 1 {
            Text(model.layers.filter { ids.contains($0.id) }.map(\.label).joined(separator: " + ") + " · \(ids.count) layers")
                .font(Typo.mono(9)).foregroundColor(Palette.textDim).lineLimit(1)
        } else if let id = model.scope.layerId, let layer = model.layers.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.textDim)
                Text(layer.label).font(Typo.monoBold(9)).foregroundColor(Palette.text)
                    + Text(layer.isActive ? " · active layer" : " · not active").font(Typo.mono(9)).foregroundColor(Palette.textDim)
                Spacer(minLength: 4)
                if model.editing == nil {
                    Button("Edit layer") {
                        model.beginEditing(layer)
                        model.membershipShown = true
                    }
                    .buttonStyle(.overview(.quiet, height: 22))
                    .fixedSize()
                    .help("Edit the layout and tucks in the list")
                }
            }
            .lineLimit(1)
        }
    }
}


/// A Desktop in miniature: its windows as outlines at their frames, the
/// selected ones in ink. Only the showing Space has live frames; the rest
/// are last known or saved homes, drawn dashed. A full-screen Space is one
/// box.
struct OverviewMiniDesktop: View {
    @ObservedObject var model: OverviewModel
    let display: OverviewDisplay
    let space: OverviewDeskSpace
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(space.rows.isEmpty ? 0.18 : 0.35))
            ForEach(tiles.reversed(), id: \.wid) { tile in tileView(tile) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    space.isCurrent ? Palette.borderLit : Palette.border,
                    style: StrokeStyle(lineWidth: OverviewChrome.stroke, dash: space.isCurrent ? [] : [2, 1.5])
                )
        )
    }

    private struct Tile {
        let wid: UInt32
        let rect: CGRect
        let live: Bool
    }

    private var tiles: [Tile] {
        let bounds = display.bounds
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let map = CGRect(origin: .zero, size: size)
        let sx: CGFloat = size.width / bounds.width
        let sy: CGFloat = size.height / bounds.height
        return space.rows.compactMap { (row: OverviewRow) -> Tile? in
            let live = space.drawsLive(row)
            if space.desktop == nil {
                return Tile(wid: row.wid, rect: map.insetBy(dx: 2, dy: 2), live: live)
            }
            guard let frame = row.frame else { return nil }
            let scaled = CGRect(
                x: (frame.minX - bounds.minX) * sx, y: (frame.minY - bounds.minY) * sy,
                width: frame.width * sx, height: frame.height * sy
            )
            let rect = scaled.intersection(map)
            guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
            return Tile(wid: row.wid, rect: rect, live: live)
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        let selected = model.selection.contains(tile.wid)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(selected ? 0.34 : (tile.live ? 0.1 : 0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(
                        selected ? Palette.text : Color.white.opacity(tile.live ? 0.3 : 0.24),
                        style: StrokeStyle(lineWidth: OverviewChrome.stroke, dash: tile.live ? [] : [2, 1.5])
                    )
            )
            .frame(width: tile.rect.width, height: tile.rect.height)
            .offset(x: tile.rect.minX, y: tile.rect.minY)
    }
}

// MARK: - Rows

/// A window's row: app, title and what keeps it from showing. Its group
/// says which Desktop, so the row only adds what the group doesn't.
struct OverviewDeskRow: View {
    @ObservedObject var model: OverviewModel
    let row: OverviewRow
    /// Rows outside any Desktop say "minimized or closed" when their
    /// group doesn't.
    let showsUnknown: Bool

    /// Click selects; shift extends over the rows, ⌘ adds or removes.
    static func pick(_ wid: UInt32, model: OverviewModel) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) { model.extend(to: wid) }
        else if mods.contains(.command) { model.toggle(wid) }
        else { model.select(wid) }
    }

    var body: some View {
        let selected = model.selection.contains(row.wid)
        Button {
            Self.pick(row.wid, model: model)
        } label: {
            HStack(spacing: 8) {
                Text(row.app)
                    .font(Typo.monoBold(9))
                    .foregroundColor(Palette.textDim)
                    .frame(width: 70, alignment: .leading)
                    .lineLimit(1)
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let note {
                    Text(note)
                        .font(Typo.mono(8))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Palette.surfaceHov : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? OverviewChrome.edgeOn : Color.clear, lineWidth: OverviewChrome.stroke)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.app), \(row.title.isEmpty ? "Untitled" : row.title), \(model.projection.location(of: row))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: selected ? "Remove from selection" : "Add to selection") { model.toggle(row.wid) }
    }

    private var note: String? {
        var parts: [String] = []
        if let tier = LayerOverviewDetail.tierLabel(row.tier) { parts.append(tier) }
        switch row.state {
        case .parked: parts.append("parked")
        case .appHidden: parts.append("hidden")
        case .unknown where showsUnknown: parts.append("minimized or closed")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
