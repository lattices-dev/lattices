import AppKit
import Combine

/// The desktop calls Overview makes, behind one seam so tests can spy on
/// them. Browsing (scope, filters, Show in scope) makes none of them.
protocol OverviewActions {
    /// Lays out `windows` on the monitor `displayId`, in place.
    func distribute(_ windows: [(wid: UInt32, pid: Int32)], displayId: UInt32, shape: [Int]?)
    func focus(wid: UInt32, pid: Int32)
    /// Tiles one window to `position` on the monitor `displayId`.
    func place(wid: UInt32, pid: Int32, position: TilePosition, displayId: UInt32)
    /// Moves one window to an absolute Space on any display. Slow: calls
    /// `completion` on the main queue with nil, or why it failed.
    func moveToSpace(wid: UInt32, pid: Int32, spaceId: Int, completion: @escaping (OverviewMoveFailure?) -> Void)
    /// Writes the layer's layout and tucked lists. Never activates it.
    /// Resolves `plan.layerId` again, so a reorder can't edit another layer.
    func saveLayer(_ plan: LayerEditPlan) throws
    /// Runs the switch of `layerId` if it is still the active layer, which
    /// moves its windows.
    func rearrange(layerId: String) throws
}

struct OverviewMoveFailure: Equatable {
    let details: String
    var originalPositionRestored = false

    static func from(_ receipt: JSON) -> Self? {
        guard let details = WindowMovementService.failureMessage(for: receipt) else { return nil }
        return Self(details: details, originalPositionRestored: receipt["rollback"]?["verified"]?.boolValue == true)
    }

    var message: String {
        let reason = details.localizedCaseInsensitiveContains("Mission Control")
            ? "Lattices couldn’t complete the move through Mission Control."
            : "Lattices couldn’t confirm that the window reached its destination."
        return reason + (originalPositionRestored
            ? " The window is back at its original position."
            : " Check the window’s current Desktop before trying again.")
    }
}

struct OverviewMoveError: Equatable {
    let wid: UInt32
    let pid: Int32?
    let app: String
    let windowTitle: String
    let destination: OverviewMoveDestination?
    let failure: OverviewMoveFailure

    var title: String { "Couldn’t move \(app)" }
}

enum OverviewEditError: LocalizedError, Equatable {
    case layerGone(String)
    case notActive(String)

    var errorDescription: String? {
        switch self {
        case .layerGone(let id): return "Layer \(id) is gone; nothing was saved"
        case .notActive(let id): return "Layer \(id) is no longer active; saved without rearranging"
        }
    }
}

/// A staged Edit layer session: what Save would write. Whether the layer
/// is active is read live, never kept here.
struct LayerEdit: Equatable {
    let layerId: String
    let originalLayout: String?
    let originalTucked: Set<UInt32>
    var layout: String?
    var tucked: Set<UInt32>

    init(layer: LayerOverview, tucked: Set<UInt32>) {
        layerId = layer.id
        originalLayout = layer.layout
        originalTucked = tucked
        layout = layer.layout
        self.tucked = tucked
    }

    var hasChanges: Bool { layout != originalLayout || tucked != originalTucked }

    /// Save layer: configuration only, never a switch.
    func savePlan() -> LayerEditPlan {
        LayerEditPlan(
            layerId: layerId,
            layout: layout != originalLayout ? .some(layout) : nil,
            tuck: tucked.subtracting(originalTucked),
            untuck: originalTucked.subtracting(tucked),
            rearrange: false
        )
    }

    /// Save and rearrange: the same write, then the active layer's switch.
    /// Nil unless the layer is active now.
    func saveAndRearrangePlan(isActive: Bool) -> LayerEditPlan? {
        guard isActive else { return nil }
        var plan = savePlan()
        plan.rearrange = true
        return plan
    }
}

/// Names its layer by id only: the index is looked up when it's applied.
struct LayerEditPlan: Equatable {
    let layerId: String
    /// The layout to write, when it changed (`.some(nil)` clears it).
    let layout: String??
    let tuck: Set<UInt32>
    let untuck: Set<UInt32>
    var rearrange: Bool
}

/// The live desktop, through the existing handlers.
struct LiveOverviewActions: OverviewActions {
    func distribute(_ windows: [(wid: UInt32, pid: Int32)], displayId: UInt32, shape: [Int]?) {
        guard let screen = OverviewModel.screen(forDisplayID: displayId) else {
            DiagnosticLog.shared.warn("Overview: no screen for display \(displayId); skipped \(windows.count) windows")
            return
        }
        WindowTiler.batchRaiseAndDistribute(windows: windows, shape: shape, screen: screen)
    }

    func focus(wid: UInt32, pid: Int32) {
        _ = WindowTiler.focusWindow(wid: wid, pid: pid)
    }

    func place(wid: UInt32, pid: Int32, position: TilePosition, displayId: UInt32) {
        guard let screen = OverviewModel.screen(forDisplayID: displayId) else {
            DiagnosticLog.shared.warn("Overview: no screen for display \(displayId); didn't place \(wid)")
            return
        }
        WindowTiler.tileWindowById(wid: wid, pid: pid, to: position, on: screen)
    }

    func moveToSpace(wid: UInt32, pid: Int32, spaceId: Int, completion: @escaping (OverviewMoveFailure?) -> Void) {
        // Absolute Space identity resolves its display in the shared movement
        // runtime. It handles inactive source desktops and verifies the landing.
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: OverviewMoveFailure?
            do {
                let receipt = try ActionRuntime.shared.executeWindowMove(
                    params: .object(["wid": .int(Int(wid)), "spaceId": .int(spaceId)]),
                    source: "app.overview"
                )
                failure = OverviewMoveFailure.from(receipt)
            } catch {
                failure = OverviewMoveFailure(details: error.localizedDescription)
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func saveLayer(_ plan: LayerEditPlan) throws {
        let workspace = WorkspaceManager.shared
        guard let index = workspace.layers.firstIndex(where: { $0.id == plan.layerId }) else {
            throw OverviewEditError.layerGone(plan.layerId)
        }
        // Either write can fail and throw. Tucks only follow a written
        // layout; a failed tuck write leaves the ledger as it was, and saving
        // the kept draft again rewrites the same layout.
        if let layout = plan.layout { try workspace.setLayout(layout, forLayer: index) }
        if !plan.tuck.isEmpty || !plan.untuck.isEmpty {
            try LayerStage.shared.setTucks(tuck: plan.tuck, untuck: plan.untuck, layer: plan.layerId)
        }
    }

    func rearrange(layerId: String) throws {
        let workspace = WorkspaceManager.shared
        guard let index = workspace.layers.firstIndex(where: { $0.id == layerId }) else {
            throw OverviewEditError.layerGone(layerId)
        }
        guard index == workspace.activeLayerSelection else { throw OverviewEditError.notActive(layerId) }
        workspace.focusLayer(index: index)
    }
}

/// What Overview hands the Studio canvas it hosts.
struct OverviewCanvasHost: Equatable {
    let title: String
    /// Windows drawn as live tiles; the canvas shows only these.
    let liveWids: Set<UInt32>
    /// Placed windows without a live tile.
    let outlines: [OverviewCanvasItem]
    let selected: Set<UInt32>
}

/// Overview's shared state: the scope it browses, its one selection and
/// an Edit layer session. The list, canvas and inspector all read
/// `projection` and write `selection` here.
final class OverviewModel: ObservableObject {
    @Published var scope: OverviewScope {
        didSet {
            guard scope != oldValue else { return }
            scope.save(to: defaults)
            // Browsing a layer points the sidebar at it; clearing the layer
            // or narrowing the monitor or Desktop never moves it.
            if let id = scope.layerId, id != oldValue.layerId { rememberMembershipLayer(id) }
            recompute()
        }
    }
    @Published private(set) var selection: Set<UInt32> = []
    @Published private(set) var projection: OverviewProjection = .empty
    @Published var editing: LayerEdit?
    /// Why the last Save or rearrange didn't land. A failed Save keeps the
    /// draft open; a failed rearrange comes after the draft closed.
    @Published private(set) var editError: String?
    /// Why the last direct action (place, move) didn't land.
    @Published private(set) var actionError: OverviewMoveError?
    /// Screen hosting Overview, captured before a move can focus another app.
    @Published var hostDisplayId: UInt32?
    /// Windows with a Space move under way.
    @Published private(set) var moving: Set<UInt32> = []
    /// The last row the user picked, for the inspector.
    @Published private(set) var focusedWid: UInt32?

    /// The membership sidebar, brought in on demand. Hiding it keeps its
    /// layer, its membership and any open edit.
    @Published var membershipShown = false
    /// The layer the sidebar shows, as the user last chose or browsed it.
    /// The monitor, Desktop, search and kind never change it.
    @Published private(set) var membershipLayerId: String?
    /// That layer's whole membership, from every window.
    @Published private(set) var membership: OverviewMembership?
    static let membershipLayerKey = "overview.membershipLayer.v1"

    let layerStore = LayerOverviewStore()
    private let defaults: UserDefaults
    private let actions: OverviewActions
    private var inputs: OverviewProjection.Inputs
    private weak var canvas: ScreenMapController?
    private var watches: Set<AnyCancellable> = []
    private var canvasWatch: AnyCancellable?
    /// Between `start()` and `stop()` Overview owns the shared selection.
    private(set) var ownsSharedSelection = false
    /// Every window the desktop model knows, content or not, by id.
    private var aliveWindows: [UInt32: WindowEntry] = [:]

    init(
        defaults: UserDefaults = .standard,
        actions: OverviewActions = LiveOverviewActions(),
        inputs: OverviewProjection.Inputs? = nil
    ) {
        self.defaults = defaults
        self.actions = actions
        self.scope = OverviewScope.load(from: defaults)
        self.membershipLayerId = defaults.string(forKey: Self.membershipLayerKey)
        self.inputs = inputs ?? OverviewProjection.Inputs(windows: [], displays: [], main: .zero)
        aliveWindows = Dictionary(self.inputs.windows.map { ($0.wid, $0) }, uniquingKeysWith: { a, _ in a })
        recompute()
    }

    // MARK: Live inputs

    /// Follows the desktop and the layers until `stop()`.
    func start() {
        guard watches.isEmpty else { return }
        layerStore.start()
        layerStore.$layers
            .merge(with: DesktopModel.shared.$windows.map { _ in [] }.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &watches)
        refresh()
        claimSharedSelection()
    }

    func stop() {
        layerStore.stop()
        watches.removeAll()
        releaseSharedSelection()
    }

    /// From here Overview's selection is the shared one, published once.
    func claimSharedSelection() {
        ownsSharedSelection = true
        publishSharedSelection()
    }

    func releaseSharedSelection() {
        ownsSharedSelection = false
    }

    /// Reads the desktop, layers and stage again.
    func refresh() {
        updateHostDisplay()
        let stage = LayerStage.shared
        let windows = DesktopModel.shared.allWindows()
        var extras: [String: Set<UInt32>] = [:]
        for layer in layerStore.layers { extras[layer.id] = stage.extras(of: layer.id) }
        update(OverviewProjection.Inputs(
            windows: windows.filter(DesktopModel.isContent),
            layers: layerStore.layers,
            displays: Self.liveDisplays(),
            main: CGDisplayBounds(CGMainDisplayID()),
            homes: stage.homes(),
            tucked: stage.tuckedByLayer(),
            extras: extras,
            ocrText: ScreenText.shared.results.mapValues(\.fullText)
        ), alive: windows)
    }

    /// New inputs. A selected window gone from the desktop model, `alive`
    /// (default: the inputs' windows), is the only thing that leaves the
    /// selection on its own.
    func update(_ inputs: OverviewProjection.Inputs, alive: [WindowEntry]? = nil) {
        self.inputs = inputs
        let alive = alive ?? inputs.windows
        aliveWindows = Dictionary(alive.map { ($0.wid, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = selection.filter { aliveWindows[$0] != nil }
        if kept != selection { setSelection(kept) }
        dropGoneLayerPicks()
        recompute()
    }

    /// The scope is saved, so an index pick can outlive its layer (renamed
    /// or deleted). It would hide every window; drop it instead.
    private func dropGoneLayerPicks() {
        guard !inputs.layers.isEmpty, let ids = scope.layerIds, !ids.isEmpty else { return }
        let known = Set(inputs.layers.map(\.id))
        let kept = ids.filter { known.contains($0) || $0.hasPrefix("__unassigned__") }
        if kept != ids { chooseIndex(kept, rows: layerIndexRows) }
    }

    private func recompute() {
        let next = OverviewProjection.make(inputs, scope: scope, selection: selection)
        if next != projection { projection = next }
        let members = membershipLayer.flatMap { OverviewMembership.make(layerId: $0, inputs: inputs, projection: next) }
        if members != membership { membership = members }
        pushCanvasSelection()
    }

    // MARK: Membership sidebar

    /// The layer the sidebar shows: the remembered one while it exists,
    /// else the layer the scope browses, else the active layer, else the
    /// first.
    var membershipLayer: String? {
        let exists: (String) -> Bool = { id in self.layers.contains { $0.id == id } }
        if let id = membershipLayerId, exists(id) { return id }
        if let id = scope.layerId, exists(id) { return id }
        return layers.first(where: \.isActive)?.id ?? layers.first?.id
    }

    func chooseMembershipLayer(_ id: String) {
        guard rememberMembershipLayer(id) else { return }
        recompute()
    }

    @discardableResult
    private func rememberMembershipLayer(_ id: String) -> Bool {
        guard id != membershipLayerId else { return false }
        membershipLayerId = id
        defaults.set(id, forKey: Self.membershipLayerKey)
        return true
    }

    func toggleMembership() { membershipShown.toggle() }

    // MARK: Layer and Desktop

    /// Scope one: a layer, or every window. It always opens whole: any
    /// Desktop subset belonged to the list it narrowed, so it goes.
    func chooseLayer(_ id: String?) {
        var next = scope
        next.layerId = id
        next.layerIds = id.map { [$0] } ?? []
        next.scopedWindowIds = nil
        next.display = nil
        next.spaceId = nil
        scope = next
        if ownsSharedSelection { LayerIndexState.shared.select(id.map { [$0] } ?? []) }
    }

    func chooseIndex(_ ids: [String], rows: [LayerIndexState.Row]) {
        var next = scope
        next.layerIds = ids
        next.layerId = ids.count == 1 && layers.contains(where: { $0.id == ids[0] }) ? ids[0] : nil
        next.scopedWindowIds = ids.isEmpty ? nil : Array(Set(rows.filter { ids.contains($0.id) }.flatMap(\.windows)))
        if next.layerIds != scope.layerIds { next.display = nil; next.spaceId = nil }
        scope = next
    }

    var layerIndexRows: [LayerIndexState.Row] { ownsSharedSelection ? LayerIndexState.shared.rows : indexFixtureRows }

    var indexFixtureRows: [LayerIndexState.Row] {
        let assigned = Set(inputs.layers.flatMap { $0.windows.map(\.wid) })
        return inputs.layers.map { LayerIndexState.Row(id: $0.id, label: $0.label, windows: $0.windows.map(\.wid)) }
            + [.init(id: "__unassigned__", label: "Unassigned", windows: inputs.windows.filter { !assigned.contains($0.wid) }.map(\.wid))]
    }

    /// Scope two: one Desktop of the chosen list, nil (or the same Desktop
    /// again) for all of them. Its monitor comes with it.
    func chooseDesktop(_ spaceId: Int?) {
        var next = scope
        if let spaceId, spaceId != scope.spaceId,
           let display = displays.first(where: { $0.owns(spaceId) }) {
            next.display = display.index
            next.spaceId = spaceId
        } else {
            next.display = nil
            next.spaceId = nil
        }
        scope = next
    }

    /// Every Desktop left to right as the strip shows them, after All
    /// desktops: monitor by monitor, then each one's full-screen Spaces.
    var desktopOrder: [Int] {
        projection.desk.flatMap { $0.spaces.map(\.spaceId) }
    }

    /// ← → walk the Desktop subset through the strip, wrapping through All
    /// desktops.
    func stepDesktop(_ delta: Int) {
        let order: [Int?] = [nil] + desktopOrder.map { Optional($0) }
        guard order.count > 1 else { return }
        let at = order.firstIndex(of: scope.spaceId) ?? 0
        chooseDesktop(order[((at + delta) % order.count + order.count) % order.count])
    }

    /// The working list the sidebar acts on: the chosen layer's whole
    /// membership, or its part on the chosen Desktop. Nil for every window.
    /// Search and kind never narrow it.
    var workingMembership: OverviewMembership? {
        guard let whole = layerMembership else { return nil }
        guard let spaceId = scope.spaceId else { return whole }
        return whole.on(space: spaceId)
    }

    /// The chosen layer's whole membership, whatever Desktop is chosen.
    var layerMembership: OverviewMembership? {
        guard let id = scope.layerId else { return nil }
        if let membership, membership.layerId == id { return membership }
        return OverviewMembership.make(layerId: id, inputs: inputs, projection: projection)
    }

    /// Every window's working list: the matched rows in the Desktop subset.
    var workingRows: [OverviewRow] { projection.inScopeRows }

    /// Selects a window and brings its row into view. Browsing only: the
    /// scope and the desktop don't change.
    func reveal(_ wid: UInt32) {
        select(wid)
        revealRequest = RevealRequest(wid: wid, serial: revealRequest.serial + 1)
    }

    /// Whether `wid` has a row in the desk now.
    func isListed(_ wid: UInt32) -> Bool {
        projection.rows.contains { $0.wid == wid }
    }

    /// The windows drawn live on the canvas: all it can select or act on.
    var canvasWids: Set<UInt32> {
        Set(projection.canvas.filter { !$0.isOutline }.map(\.wid))
    }

    /// The canvas holds only its own part of the selection, so its key
    /// actions never reach a window it doesn't draw.
    private func pushCanvasSelection() {
        canvas?.setSelectionQuietly(selection.intersection(canvasWids))
    }

    // MARK: Selection

    /// The user's selection, from the list, canvas or inspector.
    func setSelection(_ ids: Set<UInt32>) {
        guard ids != selection else { return }
        selection = ids
        if let focusedWid, !ids.contains(focusedWid) { self.focusedWid = ids.count == 1 ? ids.first : nil }
        if focusedWid == nil, ids.count == 1 { focusedWid = ids.first }
        recompute()
        publishSharedSelection()
    }

    /// Puts the whole canonical selection, filtered or not, in the shared
    /// store that voice and agents read. Once per change.
    private func publishSharedSelection() {
        guard ownsSharedSelection else { return }
        let store = WindowSelectionStore.shared
        guard !selection.isEmpty else { store.clear(); return }
        let summaries = selection.compactMap { wid in
            aliveWindows[wid].map { SelectedWindowSummary(wid: $0.wid, app: $0.app, title: $0.title, latticesSession: $0.latticesSession) }
        }
        store.setSelection(summaries, source: Self.selectionSource)
    }

    static let selectionSource = "overview"

    func select(_ wid: UInt32) {
        focusedWid = wid
        setSelection([wid])
    }

    func toggle(_ wid: UInt32) {
        var next = selection
        if next.contains(wid) { next.remove(wid) } else { next.insert(wid); focusedWid = wid }
        setSelection(next)
    }

    /// Extends the selection over the rows from the focused one to `wid`.
    func extend(to wid: UInt32) {
        let rows = workingRows.map(\.wid)
        guard let anchor = focusedWid, let a = rows.firstIndex(of: anchor), let b = rows.firstIndex(of: wid) else {
            toggle(wid); return
        }
        setSelection(selection.union(rows[min(a, b)...max(a, b)]))
    }

    /// Arrow keys in the list: moves to the next or previous row, or with
    /// shift adds it to the selection.
    func step(_ delta: Int, extend: Bool) {
        let rows = workingRows.map(\.wid)
        guard !rows.isEmpty else { return }
        let next: UInt32
        if let current = focusedWid, let at = rows.firstIndex(of: current) {
            next = rows[max(0, min(rows.count - 1, at + delta))]
        } else {
            next = delta < 0 ? rows[rows.count - 1] : rows[0]
        }
        if extend {
            focusedWid = next
            setSelection(selection.union([next]))
        } else {
            select(next)
        }
    }

    /// Shows a selected window in the inspector without changing the
    /// selection.
    func inspect(_ wid: UInt32) {
        guard selection.contains(wid) else { return }
        focusedWid = wid
    }

    func clearSelection() {
        focusedWid = nil
        setSelection([])
    }

    /// The canvas mirrors the selection. Its user selections come back here;
    /// its housekeeping (refresh, scope changes) stays quiet and never does.
    func attach(canvas controller: ScreenMapController) {
        canvas = controller
        controller.publishesSharedSelection = false
        controller.onSelectionChange = { [weak self] ids in
            self?.canvasSelected(ids)
        }
        pushCanvasSelection()
        // A canvas refresh clears its own selection quietly; put ours back.
        canvasWatch = controller.$editor
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] _ in
                guard let self, controller != nil else { return }
                self.pushCanvasSelection()
            }
    }

    /// A user selection on the canvas replaces the canvas's part of the
    /// selection; windows it doesn't draw stay selected.
    func canvasSelected(_ ids: Set<UInt32>) {
        let mine = ids.intersection(canvasWids)
        if mine.count == 1 { focusedWid = mine.first }
        setSelection(selection.subtracting(canvasWids).union(mine))
        pushCanvasSelection()
    }

    /// An outline click: outlines aren't live tiles, so Overview selects.
    func outlineClicked(_ wid: UInt32, extending: Bool) {
        if extending { toggle(wid) } else { select(wid) }
    }

    /// What the hosted canvas draws: live tiles by id, outlines, and which
    /// outlines are selected.
    var canvasHost: OverviewCanvasHost {
        OverviewCanvasHost(
            title: scopeTitle,
            liveWids: canvasWids,
            outlines: projection.canvas.filter(\.isOutline),
            selected: selection
        )
    }

    var scopeTitle: String {
        var parts: [String] = []
        if let index = scope.display, let display = displays.first(where: { $0.index == index }) {
            parts.append(display.name)
            if let space = scope.spaceId {
                parts.append(display.desktopNumber(of: space).map { "Desktop \($0)" } ?? "Full screen")
            }
        } else {
            parts.append("All monitors")
        }
        if let id = scope.layerId, let layer = layers.first(where: { $0.id == id }) { parts.append(layer.label) }
        return parts.joined(separator: " · ")
    }

    // MARK: Hosted canvas keys

    enum CanvasKeyRoute: Equatable {
        /// An Overview command: it acts on the shared scope or selection.
        case overview(OverviewCommand)
        /// Pan, zoom or selection the canvas handles itself.
        case canvas
        /// Not the canvas's: the list, buttons and menus get it.
        case pass
    }

    /// Hosted, the canvas takes keys only while it has keyboard focus, and
    /// then only its viewport and selection keys.
    /// Tile and distribute run Overview's plans; ← → step Overview's monitor
    /// scope and / opens Overview's search, so the scope column, list,
    /// counts and canvas can't disagree. Everything else, and every key
    /// with a modifier, passes on: arrows, Return, Tab, Escape and Space
    /// reach the list and controls. Studio's staging and move keys never
    /// run.
    static func canvasKeyRoute(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, canvasFocused: Bool, searching: Bool) -> CanvasKeyRoute {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard canvasFocused, !searching, mods.isEmpty else { return .pass }
        switch keyCode {
        case 17: return .overview(.bulk(.tile))        // t
        case 2: return .overview(.bulk(.distribute))   // d
        case 123: return .overview(.monitor(-1))       // ←
        case 124: return .overview(.monitor(1))        // →
        case 44: return .overview(.search)             // /
        case 0, 7,                                     // a select all, x deselect
             18, 19, 20, 21, 15, 29,                   // viewports
             49:                                       // space: hold to pan
            return .canvas
        default:
            return .pass
        }
    }

    /// Steps the monitor scope through All monitors and each monitor, left
    /// to right, as the canvas's ← → did.
    func stepMonitor(_ delta: Int) {
        let order: [Int?] = [nil] + displays.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.index)
        guard order.count > 1 else { return }
        let at = order.firstIndex(of: scope.display) ?? 0
        let next = order[((at + delta) % order.count + order.count) % order.count]
        var scope = self.scope
        scope.display = next
        scope.spaceId = nil
        self.scope = scope
    }

    /// Asks the view to focus Overview's search field.
    @Published private(set) var searchRequest = 0
    func requestSearch() { searchRequest += 1 }

    func detach(canvas controller: ScreenMapController) {
        guard canvas === controller else { return }
        controller.onSelectionChange = nil
        controller.publishesSharedSelection = true
        canvas = nil
        canvasWatch = nil
    }

    // MARK: Scope

    /// Shows `wid`'s row: its monitor and Space, with any filter hiding it
    /// cleared, and selects it. Browsing only: the desktop doesn't change.
    func showInScope(_ wid: UInt32) {
        guard let next = OverviewProjection.scope(showing: wid, from: scope, inputs: inputs) else { return }
        scope = next
        focusedWid = wid
        setSelection(selection.union([wid]))
        revealRequest = RevealRequest(wid: wid, serial: revealRequest.serial + 1)
    }

    /// A row the list must scroll to, even when it was already focused.
    struct RevealRequest: Equatable {
        let wid: UInt32?
        let serial: Int
    }
    @Published private(set) var revealRequest = RevealRequest(wid: nil, serial: 0)

    var displays: [OverviewDisplay] { inputs.displays }
    var layers: [LayerOverview] { inputs.layers }
    func tucked(_ layerId: String) -> Set<UInt32> { inputs.tucked[layerId] ?? [] }
    func extras(_ layerId: String) -> Set<UInt32> { inputs.extras[layerId] ?? [] }

    // MARK: Actions

    func plan(_ action: OverviewBulkAction) -> OverviewBulkPlan {
        projection.bulk(action, selection: selection)
    }

    /// Runs `plan` one monitor at a time, each on its own screen. Excluded
    /// windows stay selected and untouched.
    @discardableResult
    func run(_ plan: OverviewBulkPlan) -> Int {
        guard plan.isEnabled else { return 0 }
        for group in plan.groups {
            actions.distribute(
                group.windows.map { ($0.wid, $0.pid) },
                displayId: group.displayId,
                shape: Self.shape(plan.action, count: group.windows.count)
            )
        }
        return plan.eligibleCount
    }

    /// Tile packs a grid; distribute lays the windows side by side in one
    /// row; arrange uses its rows when they add up to the group.
    static func shape(_ action: OverviewBulkAction, count: Int) -> [Int]? {
        switch action {
        case .tile: return nil
        case .distribute: return count > 0 ? [count] : nil
        case .arrange(let rows): return rows.reduce(0, +) == count ? rows : nil
        }
    }

    /// Tiles one window. Only a window on its monitor's current desktop.
    @discardableResult
    func place(_ wid: UInt32, at position: TilePosition) -> Bool {
        guard let row = projection.all[wid], projection.placeExclusion(wid) == nil,
              let displayId = projection.displayId(of: row) else { return false }
        actionError = nil
        actions.place(wid: wid, pid: row.pid, position: position, displayId: displayId)
        return true
    }

    func updateHostDisplay() {
        hostDisplayId = ScreenMapWindowController.shared.nsWindow?.screen.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    func bringHereTarget(for wid: UInt32) -> OverviewMoveDestination? {
        projection.bringHereTarget(for: wid, hostDisplayId: hostDisplayId)
    }

    /// Moves one window to an explicit Desktop on any display.
    @discardableResult
    func move(_ wid: UInt32, toSpace spaceId: Int) -> Bool {
        guard moving.isEmpty else { return false }
        guard let row = projection.all[wid] else {
            actionError = OverviewMoveError(wid: wid, pid: nil, app: "window", windowTitle: "", destination: nil,
                                            failure: .init(details: "The window is no longer available."))
            return false
        }
        guard let destination = projection.moveTargets(for: wid).first(where: { $0.spaceId == spaceId }) else {
            actionError = OverviewMoveError(wid: wid, pid: row.pid, app: row.app, windowTitle: row.title, destination: nil,
                                            failure: .init(details: "The window or destination Desktop is no longer available."))
            return false
        }
        actionError = nil
        moving.insert(wid)
        actions.moveToSpace(wid: wid, pid: row.pid, spaceId: spaceId) { [weak self] failure in
            guard let self else { return }
            self.moving.remove(wid)
            // The desktop watch picks up where it landed.
            if let failure {
                self.actionError = OverviewMoveError(wid: wid, pid: row.pid, app: row.app, windowTitle: row.title,
                                                     destination: destination, failure: failure)
            }
        }
        return true
    }

    var canRetryMove: Bool {
        guard moving.isEmpty, let error = actionError, let destination = error.destination,
              let row = projection.all[error.wid], row.pid == error.pid else { return false }
        return projection.moveTargets(for: error.wid).contains(destination)
    }

    @discardableResult
    func retryMove() -> Bool {
        guard canRetryMove, let error = actionError, let destination = error.destination else { return false }
        return move(error.wid, toSpace: destination.spaceId)
    }

    func dismissActionError() {
        actionError = nil
    }

    func focus(_ wid: UInt32) {
        guard let row = projection.all[wid] else { return }
        actions.focus(wid: row.wid, pid: row.pid)
    }

    // MARK: Edit layer

    func beginEditing(_ layer: LayerOverview) {
        editError = nil
        editing = LayerEdit(layer: layer, tucked: tucked(layer.id))
    }

    func cancelEditing() {
        editError = nil
        editing = nil
    }

    /// Whether `layerId` is the active layer now, from the live layers.
    func isActive(_ layerId: String) -> Bool {
        layers.first { $0.id == layerId }?.isActive ?? false
    }

    /// Save and rearrange is offered only while the edited layer is active.
    var canRearrange: Bool {
        editing.map { isActive($0.layerId) } ?? false
    }

    /// Save layer: writes configuration only. On failure the draft stays
    /// open with the error.
    @discardableResult
    func saveLayer() -> Bool {
        guard let edit = editing else { return false }
        do { try actions.saveLayer(edit.savePlan()) } catch {
            editError = error.localizedDescription
            return false
        }
        editError = nil
        editing = nil
        return true
    }

    /// Save and rearrange: the active layer only, and it moves windows. A
    /// failed write never rearranges.
    @discardableResult
    func saveAndRearrange() -> Bool {
        guard let edit = editing, let plan = edit.saveAndRearrangePlan(isActive: isActive(edit.layerId)) else { return false }
        do { try actions.saveLayer(plan) } catch {
            editError = error.localizedDescription
            return false
        }
        editError = nil
        editing = nil
        do { try actions.rearrange(layerId: plan.layerId) } catch {
            editError = error.localizedDescription
            return false
        }
        return true
    }

    // MARK: Displays

    /// Monitors in `NSScreen.screens` order, Studio's display indices.
    static func liveDisplays() -> [OverviewDisplay] {
        let spaces = WindowTiler.getDisplaySpaces()
        return NSScreen.screens.enumerated().map { index, screen in
            let id = displayID(of: screen)
            let owned = WindowTiler.displaySpaces(forDisplayID: id, in: spaces)
            return OverviewDisplay(
                index: index,
                name: screen.localizedName,
                bounds: CGDisplayBounds(id),
                desktops: owned?.spaces.map(\.id) ?? [],
                currentSpaceId: owned?.currentSpaceId ?? 0,
                spaceIds: owned?.orderedSpaceIds ?? [],
                displayId: id
            )
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(forDisplayID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }
}
