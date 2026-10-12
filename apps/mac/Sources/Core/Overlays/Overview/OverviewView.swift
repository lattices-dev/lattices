import AppKit
import SwiftUI

/// Overview: the desk drawn to scale, under one scope bar. The bar picks
/// the list: a layer's windows or every window, by kind and search. The
/// stage draws every monitor with its Desktops beneath it; tapping a
/// Desktop focuses the list on it, and tapping it again gives it all back.
/// Windows the maps don't show wait in the tray below, beside the box that
/// arranges the selection. The selected window carries its own actions;
/// the list comes in on demand for every Desktop at once and for many
/// windows. Browsing never touches the desktop; only those actions and
/// the T and D keys do.
struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    @ObservedObject var controller: ScreenMapController
    /// Off for fixture renders: no live reads, no shared selection.
    var live = true
    @FocusState private var searchFocused: Bool
    @FocusState private var canvasFocused: Bool
    @ObservedObject private var index = LayerIndexState.shared
    private let indexTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var barWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            OverviewLayerIndex(rows: indexRows, selected: selectedLayers, readAt: index.readAt, live: live) { id, additive in
                if live { index.choose(id, additive: additive); applyIndex() }
                else {
                    let ids = id.map { additive ? (selectedLayers.contains($0) ? selectedLayers.filter { $0 != id } : selectedLayers + [$0]) : [$0] } ?? []
                    model.chooseIndex(ids, rows: indexRows)
                }
            }
            deskBody
        }
        .onReceive(indexTimer) { _ in
            guard live else { return }
            _ = try? index.snapshot()
            applyIndex()
        }
        .onReceive(index.$selected) { _ in if live { DispatchQueue.main.async { applyIndex() } } }
        .onAppear { if live { _ = try? index.snapshot(); applyIndex() } }
    }

    private var indexRows: [LayerIndexState.Row] { live ? index.rows : model.indexFixtureRows }
    private var selectedLayers: [String] { live ? index.selected : model.scope.layerIds ?? model.scope.layerId.map { [$0] } ?? [] }
    private func applyIndex() { model.chooseIndex(index.selected, rows: index.rows) }

    private var deskBody: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                stage
                Divider().overlay(Palette.border)
                OverviewTray(model: model)
            }
            .overlay(alignment: .topLeading) {
                if let wid = model.moving.first, let row = model.projection.all[wid] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Moving \(row.app)…").font(Typo.mono(10))
                    }
                    .padding(10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(10)
                } else if let error = model.actionError {
                    Text(error)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.kill)
                        .padding(10)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                        .accessibilityLabel("Window move failed: \(error)")
                }
            }
            // The list lies over the stage and tray, under the scope bar
            // and its toggle; opening or closing it moves nothing.
            .overlay(alignment: .trailing) {
                if model.membershipShown {
                    OverviewWorkingList(model: model)
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .background(Palette.bg)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.borderLit).frame(width: 1)
                        }
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.45), radius: 18, x: -6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.membershipShown)
        .background(Palette.bg)
        .onAppear {
            guard live else { return }
            model.start()
            model.attach(canvas: controller)
            controller.enter()
            canvasFocused = true
            DispatchQueue.main.async { model.updateHostDisplay() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            if live { model.updateHostDisplay() }
        }
        .onDisappear {
            guard live else { return }
            model.detach(canvas: controller)
            model.stop()
        }
    }

    // MARK: Scope bar

    /// The list, in one line: the layer, toggled; the kind, where there's
    /// room; search. A layer chip picks the list Overview shows, whole,
    /// dropping any Desktop focus; it never switches, activates or arranges
    /// a layer. The list toggle sits at the end.
    private var scopeBar: some View {
        HStack(spacing: 6) {
            scopeLabel
            Spacer(minLength: 8)
            if barWidth >= 1000 {
                HStack(spacing: 5) {
                    ForEach(FilterPreset.allCases.filter { $0 != .all }, id: \.self) { preset in kindChip(preset) }
                }
                .fixedSize()
            } else {
                kindMenu
            }
            searchField
                .frame(width: barWidth >= 1000 ? 170 : 130)
            listToggle
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { barWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scope")
    }

    private var separator: some View {
        Rectangle().fill(OverviewChrome.edgeLit).frame(width: OverviewChrome.stroke, height: 18).padding(.horizontal, 4)
    }

    private var scopeLabel: some View {
        let selected = indexRows.filter { selectedLayers.contains($0.id) }
        let title = selectedLayers.isEmpty ? "All windows" : selected.map(\.label).joined(separator: " + ")
        let count = Set((selectedLayers.isEmpty ? indexRows : selected).flatMap(\.windows)).count
        return HStack(spacing: 6) {
            Text(title + (selectedLayers.isEmpty ? " · \(count) on \(model.projection.displays.count) displays" : " · \(count) open"))
                .font(Typo.body(12)).foregroundColor(Palette.textDim).lineLimit(1)
            if !selectedLayers.isEmpty {
                Button {
                    if live { index.select([]); applyIndex() } else { model.chooseIndex([], rows: indexRows) }
                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).help("All windows")
            }
        }
    }

    private func kindChip(_ preset: FilterPreset) -> some View {
        let selected = model.scope.preset == preset.rawValue
        return Button {
            model.scope.preset = selected ? nil : preset.rawValue
        } label: {
            Text(preset.rawValue).fixedSize()
        }
        .buttonStyle(.overview(.quiet, selected: selected))
        .help(selected ? "Every kind again" : "Only \(preset.rawValue.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var kindMenu: some View {
        Menu {
            ForEach(FilterPreset.allCases, id: \.self) { preset in
                Button(preset.rawValue) { model.scope.preset = preset == .all ? nil : preset.rawValue }
            }
        } label: {
            OverviewMenuLabel(title: model.scope.preset ?? "Kind", selected: model.scope.preset != nil)
        }
        .overviewMenu(selected: model.scope.preset != nil)
        .accessibilityLabel("Kind, \(model.scope.preset ?? FilterPreset.all.rawValue)")
    }

    private var searchField: some View {
        TextField("Filter windows  /", text: Binding(
            get: { model.scope.search },
            set: { model.scope.search = $0 }
        ))
        .textFieldStyle(.plain)
        .font(Typo.mono(10))
        .foregroundColor(Palette.text)
        .padding(.horizontal, 9)
        .frame(height: OverviewChrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: OverviewChrome.radius)
                .fill(Color.black.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: OverviewChrome.radius)
                        .strokeBorder(searchFocused ? OverviewChrome.edgeOn : OverviewChrome.edgeLit, lineWidth: OverviewChrome.stroke)
                )
        )
        .focused($searchFocused)
        .onChange(of: model.searchRequest) { _ in searchFocused = true }
        .onSubmit { canvasFocused = true }
        .accessibilityLabel("Filter windows")
    }

    // MARK: List toggle

    /// The list's name and size; opens and closes the sidebar.
    private var listToggle: some View {
        let name = OverviewWorkingList.name(model)
        let count = OverviewWorkingList.count(model)
        let unsaved = model.editing != nil
        return Button {
            model.toggleMembership()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 10))
                if barWidth >= 1000 {
                    Text(name)
                        .font(Typo.mono(10))
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text("\(count)")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
                if unsaved {
                    Circle().fill(Palette.detach).frame(width: 5, height: 5)
                }
            }
        }
        .buttonStyle(.overview(selected: model.membershipShown))
        .fixedSize()
        .help(model.membershipShown ? "Hide the list" : "Show the list: every Desktop at once, and many windows")
        .accessibilityLabel(
            (model.membershipShown ? "Hide" : "Show") + " the list, \(name), \(count)"
                + (unsaved ? ", unsaved edits" : "")
        )
    }

    // MARK: Stage

    /// ↑ ↓ step through the list (shift extends), ← → step the Desktop
    /// focus, ↵ focuses the window, T and D tile or distribute the
    /// selection, / searches, Esc closes the sidebar, then clears the
    /// selection.
    private var stage: some View {
        OverviewStage(model: model)
            .focusable()
            .focused($canvasFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                switch press.key {
                case .upArrow: model.step(-1, extend: extend)
                case .downArrow: model.step(1, extend: extend)
                case .leftArrow: model.stepDesktop(-1)
                case .rightArrow: model.stepDesktop(1)
                case .return:
                    guard let wid = model.focusedWid else { return .ignored }
                    model.focus(wid)
                case .escape:
                    if model.membershipShown { model.membershipShown = false } else { model.clearSelection() }
                default:
                    switch press.characters.lowercased() {
                    case "t": model.run(model.plan(.tile))
                    case "d": model.run(model.plan(.distribute))
                    case "/": model.requestSearch()
                    default: return .ignored
                    }
                }
                return .handled
            }
    }

    /// Show in scope finds every window a scope can hold; Spaces can't place
    /// unknown ones, and closed ones are gone.
    static func canShow(_ reason: Exclusion) -> Bool {
        reason != .unknown && reason != .gone
    }

    static func reasons(_ reasons: [Exclusion]) -> String {
        var order: [Exclusion] = []
        var counts: [Exclusion: Int] = [:]
        for reason in reasons {
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.map { "\(counts[$0]!) \($0.label)" }.joined(separator: ", ")
    }
}

// MARK: - Selection bar

/// The selected window's actions, in the row under the maps so it never
/// covers a window. Focus; Show in scope when the
/// scope hides it; tile it on its monitor or carry it to another Desktop,
/// each saying why when it can't; and its layers. None of them saves a
/// layer; many windows tile or distribute from the box below.
struct OverviewSelectionBar: View {
    @ObservedObject var model: OverviewModel
    let row: OverviewRow

    private static let placements: [(TilePosition, String)] = [
        (.left, "rectangle.lefthalf.filled"), (.right, "rectangle.righthalf.filled"),
        (.maximize, "rectangle.fill"), (.center, "rectangle.center.inset.filled"),
    ]

    var body: some View {
        content(row).fixedSize()
    }

    private func showReason(_ row: OverviewRow) -> Exclusion? {
        guard let reason = model.projection.outOfScopeSelection.first(where: { $0.wid == row.wid })?.reason,
              OverviewView.canShow(reason) else { return nil }
        return reason
    }

    private func content(_ row: OverviewRow) -> some View {
        let placeBlock = model.projection.placeExclusion(row.wid)
        let outside = showReason(row)
        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(row.app)
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.text)
                    .fixedSize()
                if !row.title.isEmpty {
                    Text(row.title)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200, alignment: .leading)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            if model.selection.count > 1 {
                Text("+\(model.selection.count - 1) selected")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize()
                    .padding(.horizontal, 4)
            }
            divider
            Button {
                model.focus(row.wid)
            } label: {
                HStack(spacing: 5) {
                    Text("Focus").font(Typo.monoBold(10))
                    Text("↵").font(Typo.mono(9)).opacity(0.55)
                }
            }
            .buttonStyle(.overview(.primary))
            .disabled(row.state == .unknown)
            .help(row.state == .unknown ? "Can't focus: minimized or closed" : "Bring it forward")
            if outside != nil {
                iconButton("Show in scope", systemImage: "eye", label: "Show in scope") { model.showInScope(row.wid) }
            }
            ForEach(Self.placements, id: \.0) { position, image in
                iconButton(placeBlock.map { "Can't tile: \($0.label)" } ?? "\(position.label) on its monitor",
                           systemImage: image, label: nil) {
                    model.place(row.wid, at: position)
                }
                .disabled(placeBlock != nil)
                .accessibilityLabel("Place \(position.label.lowercased())")
            }
            if let here = model.bringHereTarget(for: row.wid) {
                iconButton("Move to \(here.title)", systemImage: "arrow.down.left.square", label: "Bring Here") {
                    model.move(row.wid, toSpace: here.spaceId)
                }
                .disabled(!model.moving.isEmpty)
                .accessibilityLabel("Bring Here — \(here.title)")
            }
            moveMenu(row)
            divider
            layerMenu(row)
            if let outside {
                why("Selected but \(outside.label)")
            } else if let placeBlock {
                why("Can't place: \(placeBlock.label)")
            }
        }
        .padding(3)
        .overviewCard(radius: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(row.app)")
    }

    private var divider: some View {
        Rectangle().fill(OverviewChrome.edgeLit).frame(width: OverviewChrome.stroke, height: 16).padding(.horizontal, 2)
    }

    private func why(_ text: String) -> some View {
        Text(text)
            .font(Typo.mono(8))
            .foregroundColor(Palette.textMuted)
            .lineLimit(2)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private func iconButton(_ help: String, systemImage: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10))
                if let label { Text(label) }
            }
            .frame(minWidth: label == nil ? 10 : nil)
        }
        .buttonStyle(.overview(.quiet))
        .help(help)
    }

    @ViewBuilder
    private func moveMenu(_ row: OverviewRow) -> some View {
        let targets = model.projection.moveTargets(for: row.wid)
        if model.moving.contains(row.wid) {
            Text("Moving…").font(Typo.mono(9)).foregroundColor(Palette.textMuted).padding(.horizontal, 6)
        } else {
            Menu {
                if let here = model.bringHereTarget(for: row.wid) {
                    Button("Bring Here — \(here.title)") { model.move(row.wid, toSpace: here.spaceId) }
                    Divider()
                }
                ForEach(targets, id: \.spaceId) { target in
                    Button(target.title) { model.move(row.wid, toSpace: target.spaceId) }
                }
            } label: {
                OverviewMenuLabel(title: "Move", selected: true)
            }
            .overviewMenu(quiet: true)
            .disabled(targets.isEmpty || !model.moving.isEmpty)
            .help(OverviewProjection.moveExclusion(row).map { "Can't move: \($0.label)" }
                ?? "Move to a chosen display and Desktop; verifies the destination")
            .accessibilityLabel("Move to display and desktop")
        }
    }

    /// The layers it's in, and the way to edit one in the list.
    private func layerMenu(_ row: OverviewRow) -> some View {
        let member = model.layers.filter { row.layerIds.contains($0.id) }
        let scoped = model.scope.layerId.flatMap { id in model.layers.first { $0.id == id } }
        let editable = (scoped.map { [$0] } ?? []) + member.filter { $0.id != scoped?.id }
        return Menu {
            Text(member.isEmpty ? "In no layer" : "In " + member.map(\.label).joined(separator: ", "))
            if model.editing == nil {
                ForEach(editable, id: \.id) { layer in
                    Button("Edit \(layer.label)…") {
                        model.beginEditing(layer)
                        model.membershipShown = true
                    }
                }
            }
        } label: {
            OverviewMenuLabel(title: "Layer", selected: true)
        }
        .overviewMenu(quiet: true)
        .help(member.isEmpty ? "In no layer" : "In " + member.map(\.label).joined(separator: ", "))
    }
}

// MARK: - List sidebar

/// The working list and what to do with it. With a layer chosen: its whole
/// membership, members, entries with no window, tucked and unclaimed
/// windows, whatever search or kind hide on the canvas; with a Desktop
/// chosen, the part on that Desktop, and the way back to all of them.
/// With All windows: every listed window, Desktop by Desktop. Clicking
/// selects (shift extends, ⌘ adds); the footer acts on the selection.
struct OverviewWorkingList: View {
    @ObservedObject var model: OverviewModel

    /// "Lattices", or "All windows".
    static func name(_ model: OverviewModel) -> String {
        let ids = model.scope.layerIds ?? model.scope.layerId.map { [$0] } ?? []
        guard !ids.isEmpty else { return "All windows" }
        return ids.map { id in model.layerIndexRows.first { $0.id == id }?.label ?? id }.joined(separator: " + ")
    }

    /// What the list holds now: entries and windows, in the subset if any.
    static func count(_ model: OverviewModel) -> Int {
        if let ids = model.scope.scopedWindowIds { return Set(ids).count }
        return Set(model.layerIndexRows.flatMap(\.windows)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.border)
            if let space = scopedSpace {
                subsetBar(space)
                Divider().overlay(Palette.border)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.scope.layerId != nil {
                            layerList
                        } else {
                            windowList
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.revealRequest) { request in
                    guard let wid = request.wid else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(wid, anchor: .center) }
                }
            }
            Divider().overlay(Palette.border)
            OverviewSelectionPanel(model: model)
        }
        .background(Palette.bg)
    }

    // MARK: Header

    private var header: some View {
        let membership = model.workingMembership
        return HStack(spacing: 8) {
            Text(Self.name(model))
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.text)
                .lineLimit(1)
            if let membership {
                if let slot = membership.slot {
                    Text("⌘⌥\(slot)").font(Typo.mono(9)).foregroundColor(Palette.textMuted)
                }
                if membership.isActive {
                    Text("active").font(Typo.mono(8)).foregroundColor(Palette.textDim)
                }
            }
            Spacer(minLength: 6)
            Text("\(Self.count(model))")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
            Button {
                model.membershipShown = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Palette.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the list")
            .accessibilityLabel("Hide the list")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: Desktop subset

    private var scopedSpace: (monitor: OverviewDeskMonitor, space: OverviewDeskSpace)? {
        guard let id = model.scope.spaceId else { return nil }
        for monitor in model.projection.desk {
            if let space = monitor.spaces.first(where: { $0.spaceId == id }) { return (monitor, space) }
        }
        return nil
    }

    /// How much of the list the Desktop leaves out, for the way back.
    private var leftOut: Int {
        if model.scope.layerId != nil {
            return max(0, (model.layerMembership?.count ?? 0) - Self.count(model))
        }
        return max(0, model.projection.rows.count - model.workingRows.count)
    }

    private func subsetBar(_ scoped: (monitor: OverviewDeskMonitor, space: OverviewDeskSpace)) -> some View {
        let hidden = leftOut
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(scoped.space.title) · \(scoped.monitor.display.name)")
                    .font(Typo.monoBold(9))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Text(hidden > 0 ? "\(hidden) more on other desktops" : (scoped.space.isCurrent ? "showing" : scoped.space.mapNote ?? "not showing"))
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("All desktops") { model.chooseDesktop(nil) }
                .buttonStyle(.overview(.secondary, height: 22))
                .fixedSize()
                .help("The whole list again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.surface)
    }

    // MARK: Layer

    @ViewBuilder
    private var layerList: some View {
        if let membership = model.workingMembership {
            if !membership.members.isEmpty {
                section("Members", count: membership.members.count) {
                    ForEach(membership.members) { item in
                        itemRow(item, detail: [item.entry, LayerOverviewDetail.tierLabel(item.tier)])
                    }
                }
            }
            if !membership.missing.isEmpty {
                section("No window", count: membership.missing.count) {
                    ForEach(membership.missing) { entry in missingRow(entry) }
                }
            }
            if !membership.tucked.isEmpty {
                section("Tucked", count: membership.tucked.count) {
                    ForEach(membership.tucked) { item in itemRow(item, detail: [item.entry]) }
                }
            }
            if !membership.unclaimed.isEmpty {
                section("Unclaimed", count: membership.unclaimed.count) {
                    ForEach(membership.unclaimed) { item in
                        itemRow(item, detail: ["not configured"], unclaimed: true)
                    }
                }
            }
            if membership.isEmpty {
                Text(model.scope.spaceId == nil ? "Nothing configured" : "Nothing on this Desktop")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textMuted)
            }
            if let layer = model.layers.first(where: { $0.id == membership.layerId }) {
                editSection(layer)
            }
        }
    }

    // MARK: All windows

    private struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [OverviewRow]
        let unplaced: Bool
    }

    private var groups: [Group] {
        var out: [Group] = []
        for monitor in model.projection.desk {
            for space in monitor.spaces {
                let rows = space.rows.filter(\.inScope)
                guard !rows.isEmpty else { continue }
                let state = space.isCurrent ? "showing" : (space.mapNote ?? "not showing")
                out.append(Group(
                    id: "\(space.spaceId)", title: "\(monitor.display.name) · \(space.title) · \(state)",
                    rows: rows, unplaced: false
                ))
            }
        }
        let unplaced = model.projection.unplaced.filter(\.inScope)
        if !unplaced.isEmpty {
            out.append(Group(id: "unplaced", title: "Minimized or closed", rows: unplaced, unplaced: true))
        }
        return out
    }

    @ViewBuilder
    private var windowList: some View {
        let groups = self.groups
        if groups.isEmpty {
            Text(model.scope.spaceId == nil ? "No windows" : "Nothing on this Desktop")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
        }
        ForEach(groups) { group in
            section(group.title, count: group.rows.count) {
                ForEach(group.rows) { row in
                    OverviewDeskRow(model: model, row: row, showsUnknown: false)
                        .id(row.wid)
                }
            }
        }
    }

    // MARK: Rows

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased())
                    .font(Typo.monoBold(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.bottom, 2)
            content()
        }
    }

    /// Title first; the entry and where it is are secondary.
    private func itemRow(_ item: OverviewMembership.Item, detail: [String?], unclaimed: Bool = false) -> some View {
        let selected = model.selection.contains(item.wid)
        let listed = model.isListed(item.wid)
        let secondary = (detail.compactMap { $0 } + [item.location]).joined(separator: " · ")
        return HStack(spacing: 6) {
            Button { OverviewDeskRow.pick(item.wid, model: model) } label: {
                HStack(alignment: .top, spacing: 7) {
                    marker(item, unclaimed: unclaimed)
                        .frame(width: 5, height: 5)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? item.app : "\(item.app) — \(item.title)")
                            .font(Typo.mono(9))
                            .foregroundColor(listed ? Palette.text : Palette.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(secondary)
                            .font(Typo.mono(8))
                            .foregroundColor(Palette.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.app), \(item.title.isEmpty ? "Untitled" : item.title), \(secondary)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !listed, item.location != "Minimized or closed" {
                Button("Show") { model.showInScope(item.wid) }
                    .buttonStyle(.overview(.quiet, height: 20))
                    .help("Clear what hides it on the canvas")
                    .accessibilityLabel("Show \(item.app) on the canvas")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Palette.surfaceHov : Color.clear))
        .modifier(OverviewWindowDragSource(model: model, row: model.projection.all[item.wid]))
        .id(item.wid)
    }

    @ViewBuilder
    private func marker(_ item: OverviewMembership.Item, unclaimed: Bool) -> some View {
        if unclaimed {
            Circle().strokeBorder(Palette.textMuted, style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 1.5]))
        } else if item.isShowing {
            Circle().fill(Palette.textDim)
        } else {
            Circle().strokeBorder(Palette.textMuted, lineWidth: 0.75)
        }
    }

    private func missingRow(_ entry: OverviewMembership.Missing) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .strokeBorder(Palette.textMuted, lineWidth: 0.75)
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textDim)
                    .lineLimit(1)
                Text(([entry.pattern].compactMap { $0 } + [entry.note]).joined(separator: " · "))
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Edit

    @ViewBuilder
    private func editSection(_ layer: LayerOverview) -> some View {
        Divider().overlay(Palette.border)
        if let edit = model.editing, edit.layerId == layer.id {
            layerEditor(edit, layer: layer)
        } else {
            // A rearrange fails after the draft closed; say so here.
            if let error = model.editError {
                Text(error)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.kill)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Edit layer") { model.beginEditing(layer) }
                .buttonStyle(.overview)
                .disabled(model.editing != nil)
        }
    }

    private static let layouts: [(label: String, value: String?)] = [
        ("In place", nil), ("Auto", "auto"), ("Columns", "columns"), ("Main and stack", "master-stack"),
    ]

    private func layerEditor(_ edit: LayerEdit, layer: LayerOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Layout", selection: Binding(
                get: { edit.layout ?? "" },
                set: { model.editing?.layout = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(Self.layouts, id: \.label) { option in
                    Text(option.label).tag(option.value ?? "")
                }
            }
            .font(Typo.mono(9))

            ForEach(layer.entries.flatMap(\.windows)) { window in
                Toggle(isOn: Binding(
                    get: { model.editing?.tucked.contains(window.wid) ?? false },
                    set: { on in
                        if on { model.editing?.tucked.insert(window.wid) } else { model.editing?.tucked.remove(window.wid) }
                    }
                )) {
                    Text("Tuck \(window.title.isEmpty ? window.app : window.title)")
                        .font(Typo.mono(8))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }

            if let error = model.editError {
                Text(error)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.kill)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Cancel") { model.cancelEditing() }
                    .buttonStyle(.overview(.quiet))
                Button("Save layer") { model.saveLayer() }
                    .buttonStyle(.overview)
                    .disabled(!edit.hasChanges)
                    .help("Saves the layout and tucks. Doesn't move windows.")
                if model.canRearrange {
                    Button("Save and rearrange") { model.saveAndRearrange() }
                        .buttonStyle(.overview)
                        .help("Saves, then lays out the active layer's windows again")
                }
            }
            .font(Typo.mono(9))
        }
    }
}

// MARK: - Selection

/// The foot of the list: the selection and every action on it. The focused
/// window can be focused, tiled on its monitor or carried to another
/// Desktop; the whole selection tiles or distributes. Each says why when it
/// can't, and none of them saves a layer.
private struct OverviewSelectionPanel: View {
    @ObservedObject var model: OverviewModel

    private static let placements: [TilePosition] = [.left, .right, .maximize, .center]

    var body: some View {
        let row = model.focusedWid.flatMap { model.projection.all[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.selection.isEmpty ? "No selection" : "\(model.selection.count) selected")
                    .font(Typo.monoBold(10))
                    .foregroundColor(model.selection.isEmpty ? Palette.textMuted : Palette.text)
                    .fixedSize()
                if !model.selection.isEmpty {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(.overview(.quiet, height: 22))
                        .fixedSize()
                }
                Spacer(minLength: 4)
                outsideMenu
            }
            if let row {
                focused(row)
            }
            bulkActions
            if let error = model.actionError {
                Text(error)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.kill)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
    }

    private func focused(_ row: OverviewRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title.isEmpty ? row.app : row.title)
                        .font(Typo.monoBold(9))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([row.app, row.state.label, row.position.label].compactMap { $0 }.joined(separator: " · "))
                        .font(Typo.mono(8))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)
                }
                .help(row.title.isEmpty ? row.app : "\(row.app) — \(row.title)")
                Spacer(minLength: 4)
                if showReason(row) != nil {
                    Button("Show in scope") { model.showInScope(row.wid) }
                        .buttonStyle(.overview)
                        .fixedSize()
                }
                Button("Focus") { model.focus(row.wid) }
                    .buttonStyle(.overview(.primary))
                    .disabled(row.state == .unknown)
                    .fixedSize()
            }
            directActions(row)
        }
    }

    private func showReason(_ row: OverviewRow) -> Exclusion? {
        guard let reason = model.projection.outOfScopeSelection.first(where: { $0.wid == row.wid })?.reason,
              OverviewView.canShow(reason) else { return nil }
        return reason
    }

    /// Tile a window on its current monitor or move it to any display and
    /// Desktop. Each says why when it can't.
    @ViewBuilder
    private func directActions(_ row: OverviewRow) -> some View {
        let placeBlock = model.projection.placeExclusion(row.wid)
        HStack(spacing: 4) {
            ForEach(Self.placements) { position in
                Button(position.label) { model.place(row.wid, at: position) }
                    .buttonStyle(.overview(fill: true))
                    .disabled(placeBlock != nil)
            }
            moveControl(row)
        }
        .help(placeBlock.map { "Can't tile: \($0.label)" } ?? "Tile this window on its monitor")
        if let placeBlock {
            Text("Can't tile: \(placeBlock.label)")
                .font(Typo.mono(8))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func moveControl(_ row: OverviewRow) -> some View {
        let targets = model.projection.moveTargets(for: row.wid)
        if model.moving.contains(row.wid) {
            Text("Moving…").font(Typo.mono(8)).foregroundColor(Palette.textMuted)
        } else if !targets.isEmpty {
            Menu {
                if let here = model.bringHereTarget(for: row.wid) {
                    Button("Bring Here — \(here.title)") { model.move(row.wid, toSpace: here.spaceId) }
                    Divider()
                }
                ForEach(targets, id: \.spaceId) { target in
                    Button(target.title) { model.move(row.wid, toSpace: target.spaceId) }
                }
            } label: {
                OverviewMenuLabel(title: "Move", selected: true)
            }
            .overviewMenu()
            .disabled(!model.moving.isEmpty)
            .help("Move to a chosen display and Desktop; verifies the destination")
            .accessibilityLabel("Move to display and desktop")
        } else if let block = OverviewProjection.moveExclusion(row) {
            Text("Can't move: \(block.label)")
                .font(Typo.mono(8))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
        }
    }

    /// Side by side when the labels fit the sidebar, else stacked; a label
    /// that still doesn't fit truncates rather than widening the sidebar.
    private var bulkActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { bulkButtons }.fixedSize()
            VStack(alignment: .leading, spacing: 6) { bulkButtons }
        }
    }

    private var bulkButtons: some View {
        ForEach([OverviewBulkAction.tile, .distribute], id: \.self) { action in
            let plan = model.plan(action)
            Button {
                model.run(plan)
            } label: {
                Text(plan.label).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.overview)
            .disabled(!plan.isEnabled)
            .help(plan.excludedSummary.isEmpty ? plan.label : "\(plan.label). Left out: \(plan.excludedSummary)")
        }
    }

    /// Selected windows the scope hides: what, why, and the way back.
    @ViewBuilder
    private var outsideMenu: some View {
        let outside = model.projection.outOfScopeSelection
        if !outside.isEmpty {
            Menu {
                ForEach(outside, id: \.wid) { item in
                    let row = model.projection.all[item.wid]
                    let name = row.map { $0.title.isEmpty ? $0.app : $0.title } ?? "Closed window"
                    if OverviewView.canShow(item.reason) {
                        Button("Show \(name) · \(item.reason.label)") { model.showInScope(item.wid) }
                    } else {
                        Button("\(name) · \(item.reason.label)") { model.inspect(item.wid) }
                    }
                }
            } label: {
                OverviewMenuLabel(title: "\(outside.count) outside")
            }
            .overviewMenu(quiet: true)
        }
    }
}
