import AppKit
import Combine

/// A ⌘⌥ layer as Studio lists it: each of its entries with the windows it
/// matched, and where each window is. That's its desktop (`LayerRoster`),
/// unless the layer stage parked it in the main display's corner or hid its
/// app. Telling those apart is pure, so it's tested without windows.
struct LayerOverview: Identifiable, Equatable {
    enum Spot: Equatable {
        case at(LayerRoster.Place)
        /// Hanging off the main display's bottom-right corner, where a switch
        /// parks it; on a desktop that isn't showing when `desktop` is set.
        case parked(desktop: Int?)
        /// Its app is hidden.
        case hidden

        /// What Studio writes beside the window, nil when it's here.
        var note: String? {
            switch self {
            case .at(let place): return place.note
            case .parked(nil): return "Parked"
            case .parked(let desktop?): return "Parked, Desktop \(desktop)"
            case .hidden: return "Hidden"
            }
        }

        /// A switch can put it away: it isn't on another display, which
        /// switches leave be.
        var canPutAway: Bool {
            if case .at(.display) = self { return false }
            return true
        }

        /// On a desktop a display is showing, where it can be seen.
        var isShowing: Bool {
            switch self {
            case .at(.here), .at(.display(_, nil)): return true
            default: return false
            }
        }

        /// One word for where it is, as the daemon and the assistant report
        /// it: showing, elsewhere (a desktop that isn't showing, or full
        /// screen), parked or hidden.
        var presence: String {
            switch self {
            case .at(.noWindow), .at(.notOpen): return "missing"
            case .at: return isShowing ? "showing" : "elsewhere"
            case .parked: return "parked"
            case .hidden: return "hidden"
            }
        }
    }

    struct Window: Identifiable, Equatable {
        let wid: UInt32
        let app: String
        let title: String
        let spot: Spot
        /// Its Spaces and frame (CG, top-left origin) as the inventory last
        /// had them: the true frame for a hidden app's collapsed window.
        var spaceIds: [Int] = []
        var frame: CGRect = .zero
        /// How its entry holds it: a generated pin, a rule, an app...
        var tier: LayerMembership.Tier? = nil
        var id: UInt32 { wid }
    }

    /// A member Spaces can't place: minimized, or closed but kept. Its
    /// state is unknown, so it stays out of the confirmed `windows`.
    struct Unplaced: Identifiable, Equatable {
        let wid: UInt32
        let app: String
        let title: String
        var frame: CGRect = .zero
        var tier: LayerMembership.Tier? = nil
        var id: UInt32 { wid }
    }

    struct Entry: Identifiable, Equatable {
        /// Its index in the layer's `projects`.
        let index: Int
        /// The app, tab group or project it matches.
        let name: String
        /// The title it looks for, if it looks for one.
        let pattern: String?
        let windows: [Window]
        /// Why nothing matched (`.noWindow`, `.notOpen`), nil when something did.
        let missing: LayerRoster.Place?
        /// Members it holds that Spaces can't place, kept apart from `windows`.
        var unknown: [Unplaced] = []
        var id: Int { index }
    }

    /// The layer's index in the config's layers, which `focusLayer` takes.
    let index: Int
    let id: String
    let label: String
    let layout: String?
    /// The layer ⌘⌥ last switched to.
    let isActive: Bool
    let entries: [Entry]

    /// Where the layer sits on the ⌘⌥ pad.
    var slot: Int? { LayerSlots.slot(forIndex: index) }
    var windows: [Window] { entries.flatMap(\.windows) }
    var showingIds: Set<UInt32> { Set(windows.filter(\.spot.isShowing).map(\.wid)) }

    /// How menus and bars write a layer's window count.
    static func countNote(_ count: Int) -> String {
        switch count {
        case 0: return "No windows"
        case 1: return "1 window"
        default: return "\(count) windows"
        }
    }

    /// A layer's pad key, "⌘⌥3", or nil past the eighth layer.
    static func chord(forIndex index: Int) -> String? {
        LayerSlots.slot(forIndex: index).map { "⌘⌥\($0)" }
    }

    /// How Studio's layer scope names a ⌘⌥ layer, beside its saved layers.
    static func scopeId(for layerId: String) -> String { "workspace-layer:\(layerId)" }

    static func layerId(fromScope scopeId: String) -> String? {
        let prefix = "workspace-layer:"
        return scopeId.hasPrefix(prefix) ? String(scopeId.dropFirst(prefix.count)) : nil
    }

    /// The layer in `layers` a scope id names: `workspace-layer:<id>`, or
    /// the index an older deck sends in the id's place. An id wins.
    static func layerIndex(fromScope scopeId: String, in layers: [Layer]) -> Int? {
        guard let raw = layerId(fromScope: scopeId) else { return nil }
        if let index = layers.firstIndex(where: { $0.id == raw }) { return index }
        guard let index = Int(raw), layers.indices.contains(index) else { return nil }
        return index
    }

    /// Where a window is: `place` from its Spaces, `frame` in CG coordinates,
    /// and `main` the main display's bounds, where the stage parks windows.
    /// A hidden app's window is hidden wherever it is; any other window
    /// Spaces can't place has no spot.
    static func spot(place: LayerRoster.Place?, frame: CGRect, appHidden: Bool, main: CGRect) -> Spot? {
        if appHidden { return .hidden }
        guard let place else { return nil }
        guard isParked(frame, main: main) else { return .at(place) }
        switch place {
        case .here: return .parked(desktop: nil)
        case .desktop(let number): return .parked(desktop: number)
        default: return .at(place)
        }
    }

    /// In the corner the stage parks windows in. The stage moves them to one
    /// point in from it and macOS clamps them back a little, so it allows
    /// the same 40 points `LayerStage` does.
    static func isParked(_ frame: CGRect, main: CGRect) -> Bool {
        frame.minX >= main.maxX - 40 && frame.minX < main.maxX
            && frame.minY >= main.minY && frame.minY < main.maxY
    }
}

extension LayerOverview {
    /// Every layer's overview from one resolution of `layers`. `active` is
    /// the layer ⌘⌥ last switched to, `main` the main display's bounds,
    /// `place` reads a window's Spaces, `groupLabel` names a tab group and
    /// `missing` says why an entry holds nothing.
    static func build(
        _ layers: [Layer],
        resolution: LayerMembership.Resolution,
        active: Int?,
        main: CGRect,
        place: ([Int]) -> LayerRoster.Place?,
        groupLabel: (String) -> String? = { _ in nil },
        missing: (LayerProject) -> LayerRoster.Place? = { _ in nil }
    ) -> [LayerOverview] {
        layers.enumerated().map { index, layer in
            let members = resolution.layers.indices.contains(index) ? resolution.layers[index] : []
            let entries = layer.projects.enumerated().map { projectIndex, project -> Entry in
                var windows: [Window] = []
                var unknown: [Unplaced] = []
                for member in members where member.project == projectIndex {
                    let entry = member.entry
                    let frame = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
                    let tier = resolution.owners[entry.wid]?.tier
                    guard let spot = spot(place: place(entry.spaceIds), frame: frame, appHidden: entry.appHidden, main: main) else {
                        unknown.append(Unplaced(wid: entry.wid, app: entry.app, title: entry.title, frame: frame, tier: tier))
                        continue
                    }
                    windows.append(Window(
                        wid: entry.wid, app: entry.app, title: entry.title, spot: spot,
                        spaceIds: entry.spaceIds, frame: frame, tier: tier
                    ))
                }
                return Entry(
                    index: projectIndex,
                    name: name(of: project, at: projectIndex, groupLabel: groupLabel),
                    pattern: pattern(of: project),
                    windows: windows,
                    missing: windows.isEmpty ? missing(project) : nil,
                    unknown: unknown
                )
            }
            return LayerOverview(
                index: index, id: layer.id, label: layer.label, layout: layer.layout,
                isActive: index == active, entries: entries
            )
        }
    }

    /// The app, tab group or project an entry matches, else its place in the layer.
    static func name(of project: LayerProject, at index: Int, groupLabel: (String) -> String?) -> String {
        let groupName: String? = project.group.map { groupLabel($0) ?? $0 }
        let folder: String? = project.path.map { ($0 as NSString).lastPathComponent }
        let named: String? = project.match?.summary ?? project.app ?? project.launch ?? groupName ?? folder
        return named ?? "Entry \(index + 1)"
    }

    /// The title an app entry looks for.
    static func pattern(of project: LayerProject) -> String? {
        project.match == nil && project.app != nil ? project.title : nil
    }
}

extension WorkspaceManager {
    /// How many windows each ⌘⌥ layer holds, in order: its overview's, the
    /// count Studio, the preview and `layers.members` list.
    func layerWindowCounts(in windows: [WindowEntry] = DesktopModel.shared.allWindows()) -> [Int] {
        overviews(in: windows).map(\.windows.count)
    }

    /// Every ⌘⌥ layer's overview, from one resolution of `windows`.
    func overviews(in windows: [WindowEntry]) -> [LayerOverview] {
        let layers = self.layers
        guard !layers.isEmpty else { return [] }
        let context = LayerRoster.Context.current()
        let running = NSWorkspace.shared.runningApplications
        return LayerOverview.build(
            layers,
            resolution: layerMembership(in: windows),
            active: activeLayerSelection,
            main: CGDisplayBounds(CGMainDisplayID()),
            place: context.place(of:),
            groupLabel: { self.group(byId: $0)?.label },
            missing: { self.missingApp(for: $0, running: running)?.place }
        )
    }
}

/// Studio's ⌘⌥ layers, rebuilt as windows move while Studio is open.
final class LayerOverviewStore: ObservableObject {
    @Published private(set) var layers: [LayerOverview] = []
    private var watch: AnyCancellable?

    /// Rebuilds on each window poll, config reload and layer switch, until
    /// `stop()`.
    func start() {
        guard watch == nil else { return }
        let workspace = WorkspaceManager.shared
        // The publishers fire before the change lands; rebuild after it has.
        watch = DesktopModel.shared.$windows.map { _ in () }
            .merge(with: workspace.$config.map { _ in () }, workspace.$activeLayerIndex.map { _ in () })
            .merge(with: workspace.$layerFocus.map { _ in () })
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
        rebuild()
    }

    func stop() {
        watch = nil
    }

    func rebuild() {
        let fresh = WorkspaceManager.shared.overviews(in: DesktopModel.shared.allWindows())
        if fresh != layers { layers = fresh }
    }
}

extension WorkspaceManager {
    /// Every ⌘⌥ layer as the assistant reads it: rules and live members.
    func layersContextPayload(in desktop: DesktopModel = .shared) -> [String: Any] {
        [
            "file": "\(NSHomeDirectory())/.lattices/workspace.json",
            "active": activeLayerSelection.map { $0 as Any } ?? NSNull(),
            "focusActive": isLayerFocusActive,
            "rememberedIndex": activeLayerIndex,
            "layers": overviews(in: desktop.allWindows()).map { layerContextPayload($0) },
        ]
    }

    /// One layer as the assistant reads it: each entry's rule and the windows it holds.
    func layerContextPayload(_ overview: LayerOverview) -> [String: Any] {
        let projects = config?.layers?.first { $0.id == overview.id }?.projects ?? []
        return [
            "id": overview.id,
            "label": overview.label,
            "index": overview.index,
            "slot": overview.slot.map { $0 as Any } ?? NSNull(),
            "active": overview.isActive,
            "entries": overview.entries.map { entry -> [String: Any] in
                let rule = projects.indices.contains(entry.index) ? projects[entry.index].clause?.summary : nil
                return [
                    "name": entry.name,
                    "rule": rule.map { $0 as Any } ?? NSNull(),
                    "missing": entry.missing?.note.map { $0 as Any } ?? NSNull(),
                    "windows": entry.windows.map { window -> [String: Any] in
                        [
                            "wid": Int(window.wid), "app": window.app, "title": window.title,
                            "showing": window.spot.isShowing, "presence": window.spot.presence,
                            "where": window.spot.note.map { $0 as Any } ?? NSNull(),
                        ]
                    },
                ]
            },
        ]
    }

    /// One layer as the daemon reports it (`layers.members`, `desktop.snapshot`):
    /// each entry's rule and the windows it holds, with where each one is.
    func layerMembersJSON(_ overview: LayerOverview) -> JSON {
        let projects = layers.first { $0.id == overview.id }?.projects ?? []
        func text(_ value: String?) -> JSON { value.map { .string($0) } ?? .null }
        return .object([
            "id": .string(overview.id),
            "label": .string(overview.label),
            "index": .int(overview.index),
            "slot": overview.slot.map { .int($0) } ?? .null,
            "active": .bool(overview.isActive),
            "layout": text(overview.layout),
            "entries": .array(overview.entries.map { entry in
                .object([
                    "index": .int(entry.index),
                    "name": .string(entry.name),
                    "rule": text(projects.indices.contains(entry.index) ? projects[entry.index].clause?.summary : nil),
                    "pattern": text(entry.pattern),
                    "missing": text(entry.missing?.note),
                    "windows": .array(entry.windows.map { window in
                        .object([
                            "wid": .int(Int(window.wid)),
                            "app": .string(window.app),
                            "title": .string(window.title),
                            "presence": .string(window.spot.presence),
                            "where": text(window.spot.note),
                        ])
                    }),
                ])
            }),
        ])
    }

    func layerContextJSON(_ overview: LayerOverview) -> String {
        let payload = layerContextPayload(overview)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
