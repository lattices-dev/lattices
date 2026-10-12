import AppKit
import CryptoKit
import Foundation

// MARK: - Data Model

struct TabGroupTab: Codable {
    let path: String?
    let label: String?
    let app: String?
    let title: String?
    let url: String?
    let launch: String?

    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        if let path { return (path as NSString).lastPathComponent }
        return app ?? title ?? "Tab"
    }

    var isTerminal: Bool { path != nil }
}

struct TabGroup: Codable, Identifiable {
    let id: String
    let label: String
    let tabs: [TabGroupTab]
}

struct LayerProject: Codable {
    let path: String?
    let group: String?
    let tile: String?
    let display: Int?
    var app: String?       // match by owner app name (e.g. "Google Chrome", "Xcode")
    var title: String?     // substring match on window title (case-insensitive)
    let url: String?       // URL to open if no matching window found
    let launch: String?    // app name to launch if not running (via `open -a`)
    /// A Studio rule (regex, exact names, sessions, exclusions), for what
    /// `app` and `title` can't say. Takes the place of the fields above.
    var match: StudioLayerClause? = nil
    /// Windows added to the layer by hand as this entry. A pin outranks any
    /// rule, so its window stays here whatever its title turns to.
    var pins: [LayerPin]? = nil
    /// Saved from a window (⌘⌥T, the layer bezel, a move) rather than
    /// written: it holds windows by its pins alone (`isSaved`). Nil in an
    /// entry written by hand, and then left out of the file.
    var saved: Bool? = nil
}

/// A window saved into a layer, by wid while it lives. `app` and `title`,
/// as they read when it was saved, find it again once the wid is gone
/// and its app has quit (`LayerMembership`).
struct LayerPin: Codable, Equatable {
    var wid: UInt32
    let app: String
    let title: String
    /// The process that had the window. Nil in a pin from before it was
    /// kept, and then left out of the file.
    var pid: Int32? = nil
}

struct Layer: Codable, Identifiable {
    let id: String
    var label: String
    var projects: [LayerProject]
    /// How to lay the layer's windows out when it's shown: "auto",
    /// "columns" or "master-stack" (`LayerLayout`). Nil leaves them where
    /// they are.
    var layout: String? = nil
}

struct WorkspaceConfig: Codable {
    let name: String
    let groups: [TabGroup]?
    var layers: [Layer]?
}

// MARK: - Grid Presets & Named Layouts

struct GridPreset: Codable {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat

    var fractions: (CGFloat, CGFloat, CGFloat, CGFloat) { (x, y, w, h) }
}

struct LayoutWindowSpec: Codable {
    let id: String?
    let app: String
    let tile: String?       // TilePosition name, preset name, or omitted for engine layouts
    let display: Int?       // spatial display number (1-based), nil = current
    let title: String?      // optional title match for disambiguation
}

struct LayoutManagement: Codable, Equatable {
    let reconcile: String?
    let ambiguity: String?
    let fullscreen: String?
    let debounceMilliseconds: Int?
}

struct LayoutConfig: Codable {
    let engine: String?
    let gap: CGFloat?
    let masterRatio: CGFloat?
    let masterCount: Int?
    let management: LayoutManagement?
    let windows: [LayoutWindowSpec]

    var usesMasterStack: Bool {
        switch engine?.lowercased() {
        case "master-stack", "master":
            return true
        default:
            return false
        }
    }

    enum Placement {
        case named(String)
        case fractions(FractionalPlacement)
    }

    func placement(at index: Int) -> Placement? {
        guard windows.indices.contains(index) else { return nil }
        if let tile = windows[index].tile, !tile.isEmpty {
            return .named(tile)
        }
        guard usesMasterStack, let box = masterStackFractions(at: index) else { return nil }
        return .fractions(box)
    }

    func masterStackFractions(at index: Int) -> FractionalPlacement? {
        guard windows.indices.contains(index) else { return nil }
        let masters = max(masterCount ?? 1, 1)
        let ratio = min(max(masterRatio ?? 0.62, 0.05), 0.95)
        let stackWidth = 1 - ratio
        if index < masters {
            let height = 1 / CGFloat(masters)
            return FractionalPlacement(x: 0, y: CGFloat(index) * height, w: ratio, h: height)
        }
        let stackIndex = index - masters
        let stackCount = windows.count - masters
        guard stackCount > 0, stackWidth > 0 else { return nil }
        let height = 1 / CGFloat(stackCount)
        return FractionalPlacement(x: ratio, y: CGFloat(stackIndex) * height, w: stackWidth, h: height)
    }
}

struct GridFile: Codable {
    let presets: [String: GridPreset]?
    let layouts: [String: LayoutConfig]?
    let snapZones: SnapZonesConfig?
}

enum SnapModifierKey: String, Codable, Equatable, CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .command:
            return "Command"
        case .option:
            return "Option"
        case .control:
            return "Control"
        case .shift:
            return "Shift"
        }
    }

    var shortLabel: String {
        switch self {
        case .command:
            return "Cmd"
        case .option:
            return "Opt"
        case .control:
            return "Ctrl"
        case .shift:
            return "Shift"
        }
    }

    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .command:
            return .maskCommand
        case .option:
            return .maskAlternate
        case .control:
            return .maskControl
        case .shift:
            return .maskShift
        }
    }

}

enum SnapZoneTriggerSpec: Codable, Equatable {
    case named(String)
    case fractions(FractionalPlacement)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let named = try? container.decode(String.self) {
            self = .named(named)
            return
        }

        let preset = try container.decode(GridPreset.self)
        guard let placement = FractionalPlacement(x: preset.x, y: preset.y, w: preset.w, h: preset.h) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "snap zone trigger fractions must stay within 0...1"
            )
        }
        self = .fractions(placement)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let name):
            try container.encode(name)
        case .fractions(let placement):
            try container.encode(GridPreset(x: placement.x, y: placement.y, w: placement.w, h: placement.h))
        }
    }
}

enum SnapZonePlacementSpec: Codable, Equatable {
    case named(String)
    case fractions(FractionalPlacement)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let named = try? container.decode(String.self) {
            self = .named(named)
            return
        }

        let preset = try container.decode(GridPreset.self)
        guard let placement = FractionalPlacement(x: preset.x, y: preset.y, w: preset.w, h: preset.h) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "snap zone placement fractions must stay within 0...1"
            )
        }
        self = .fractions(placement)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let name):
            try container.encode(name)
        case .fractions(let placement):
            try container.encode(GridPreset(x: placement.x, y: placement.y, w: placement.w, h: placement.h))
        }
    }
}

struct SnapZoneDefinition: Codable, Equatable, Identifiable {
    let rawID: String?
    let label: String?
    let placement: SnapZonePlacementSpec
    let trigger: SnapZoneTriggerSpec
    let priority: Int?

    enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case label
        case placement
        case trigger
        case priority
    }

    var id: String {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallbackID : trimmed
    }

    private var fallbackID: String {
        switch placement {
        case .named(let name):
            return name
        case .fractions(let fractions):
            return "fractions-\(fractions.x)-\(fractions.y)-\(fractions.w)-\(fractions.h)"
        }
    }
}

struct SnapZonesConfig: Codable, Equatable {
    let enabled: Bool?
    let modifier: SnapModifierKey?
    let zoneOpacity: Double?
    let highlightOpacity: Double?
    let previewOpacity: Double?
    let cornerRadius: CGFloat?
    let rules: [SnapZoneDefinition]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case modifier
        case zoneOpacity
        case highlightOpacity
        case previewOpacity
        case cornerRadius
        case rules
        case zones
    }

    init(
        enabled: Bool?,
        modifier: SnapModifierKey?,
        zoneOpacity: Double?,
        highlightOpacity: Double?,
        previewOpacity: Double?,
        cornerRadius: CGFloat?,
        rules: [SnapZoneDefinition]?
    ) {
        self.enabled = enabled
        self.modifier = modifier
        self.zoneOpacity = zoneOpacity
        self.highlightOpacity = highlightOpacity
        self.previewOpacity = previewOpacity
        self.cornerRadius = cornerRadius
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        modifier = try container.decodeIfPresent(SnapModifierKey.self, forKey: .modifier)
        zoneOpacity = try container.decodeIfPresent(Double.self, forKey: .zoneOpacity)
        highlightOpacity = try container.decodeIfPresent(Double.self, forKey: .highlightOpacity)
        previewOpacity = try container.decodeIfPresent(Double.self, forKey: .previewOpacity)
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        let decodedRules = try container.decodeIfPresent([SnapZoneDefinition].self, forKey: .rules)
        let decodedZones = try container.decodeIfPresent([SnapZoneDefinition].self, forKey: .zones)
        rules = decodedRules ?? decodedZones
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(modifier, forKey: .modifier)
        try container.encodeIfPresent(zoneOpacity, forKey: .zoneOpacity)
        try container.encodeIfPresent(highlightOpacity, forKey: .highlightOpacity)
        try container.encodeIfPresent(previewOpacity, forKey: .previewOpacity)
        try container.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try container.encodeIfPresent(rules, forKey: .rules)
    }

    static let defaults = SnapZonesConfig(
        enabled: true,
        modifier: .command,
        zoneOpacity: 0.10,
        highlightOpacity: 0.22,
        previewOpacity: 0.18,
        cornerRadius: 18,
        rules: [
            SnapZoneDefinition(
                rawID: "top-left",
                label: "Top Left",
                placement: .named("top-left"),
                trigger: .fractions(FractionalPlacement(x: 0.00, y: 0.00, w: 0.24, h: 0.18)!),
                priority: 40
            ),
            SnapZoneDefinition(
                rawID: "maximize",
                label: "Maximize",
                placement: .named("maximize"),
                trigger: .fractions(FractionalPlacement(x: 0.24, y: 0.00, w: 0.52, h: 0.12)!),
                priority: 20
            ),
            SnapZoneDefinition(
                rawID: "top-right",
                label: "Top Right",
                placement: .named("top-right"),
                trigger: .fractions(FractionalPlacement(x: 0.76, y: 0.00, w: 0.24, h: 0.18)!),
                priority: 40
            ),
            SnapZoneDefinition(
                rawID: "left",
                label: "Left",
                placement: .named("left"),
                trigger: .fractions(FractionalPlacement(x: 0.00, y: 0.18, w: 0.12, h: 0.64)!),
                priority: 10
            ),
            SnapZoneDefinition(
                rawID: "right",
                label: "Right",
                placement: .named("right"),
                trigger: .fractions(FractionalPlacement(x: 0.88, y: 0.18, w: 0.12, h: 0.64)!),
                priority: 10
            ),
            SnapZoneDefinition(
                rawID: "bottom-left",
                label: "Bottom Left",
                placement: .named("bottom-left"),
                trigger: .fractions(FractionalPlacement(x: 0.00, y: 0.82, w: 0.24, h: 0.18)!),
                priority: 40
            ),
            SnapZoneDefinition(
                rawID: "bottom-right",
                label: "Bottom Right",
                placement: .named("bottom-right"),
                trigger: .fractions(FractionalPlacement(x: 0.76, y: 0.82, w: 0.24, h: 0.18)!),
                priority: 40
            ),
        ]
    )

    func merged(over defaults: SnapZonesConfig = .defaults) -> SnapZonesConfig {
        SnapZonesConfig(
            enabled: enabled ?? defaults.enabled,
            modifier: modifier ?? defaults.modifier,
            zoneOpacity: zoneOpacity ?? defaults.zoneOpacity,
            highlightOpacity: highlightOpacity ?? defaults.highlightOpacity,
            previewOpacity: previewOpacity ?? defaults.previewOpacity,
            cornerRadius: cornerRadius ?? defaults.cornerRadius,
            rules: rules ?? defaults.rules
        )
    }
}

// MARK: - Manager

class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published var config: WorkspaceConfig?
    @Published var activeLayerIndex: Int = 0
    @Published private(set) var layerFocus = LayerFocusState()
    @Published var isSwitching: Bool = false
    @Published var gridPresets: [String: GridPreset] = [:]
    @Published var gridLayouts: [String: LayoutConfig] = [:]
    @Published var snapZonesConfig: SnapZonesConfig = .defaults
    @Published private(set) var selectedGroupTabIndices: [String: Int] = [:]
    @Published private(set) var expandedGroupIDs: Set<String> = []

    let configPath: String
    private let gridConfigPath: String
    private let snapZonesConfigPath: String
    private var gridConfigSourceToken = ""
    private var tmuxPath: String { TmuxQuery.resolvedPath ?? "/opt/homebrew/bin/tmux" }
    let activeLayerKey = "lattices.activeLayerIndex"
    /// Classic is showing: every window put back, as if Lattices weren't
    /// running (`showClassic`). Any layer switch ends it.
    @Published var classicShowing = false
    /// Classic · one space is carrying windows to the showing desktops.
    var classicGathering = false
    private let layerFocusKey = "lattices.isLayerFocusActive"
    private let layerRecoveryKey = "lattices.layerRecoveryRemaining"
    private var layerSpaceObserver: NSObjectProtocol?
    private var layerRecoveryWork: DispatchWorkItem?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.configPath = (home as NSString).appendingPathComponent(".lattices/workspace.json")
        self.gridConfigPath = (home as NSString).appendingPathComponent(".lattices/grid.json")
        self.snapZonesConfigPath = (home as NSString).appendingPathComponent(".lattices/snap-zones.json")
        self.activeLayerIndex = UserDefaults.standard.integer(forKey: activeLayerKey)
        self.layerFocus = LayerFocusState(
            // Older versions always retained an active index. Keep that mode
            // until the first explicit exit, including its hidden-app ledger.
            persistedActive: UserDefaults.standard.object(forKey: layerFocusKey) as? Bool,
            hasRememberedLayer: UserDefaults.standard.object(forKey: activeLayerKey) != nil,
            pendingRestorationCount: UserDefaults.standard.integer(forKey: layerRecoveryKey)
        )
        loadConfig()
        loadGridConfig()
        layerSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleLayerRecovery() }
        if layerFocus.needsRecovery {
            DispatchQueue.main.async { [weak self] in self?.scheduleLayerRecovery() }
        }
    }

    var isLayerFocusActive: Bool { layerFocus.isActive }
    var activeLayerSelection: Int? {
        isLayerFocusActive && layers.indices.contains(activeLayerIndex) ? activeLayerIndex : nil
    }

    var activeLayer: Layer? {
        guard isLayerFocusActive, let config, let layers = config.layers,
              layers.indices.contains(activeLayerIndex) else { return nil }
        return layers[activeLayerIndex]
    }

    var layerRecoveryMessage: String? {
        let count = layerFocus.pendingRestorationCount
        guard layerFocus.needsRecovery else { return nil }
        return "Layers off · \(count) still waiting to restore. Visit their desktops to finish."
    }

    /// The shared exit for menus, the preview, command bar, editor and daemon.
    /// Keep the layer definitions and desktop assignments; restore only what
    /// the stage put away. Main-thread ordering makes an exit follow the full
    /// switch, and the generation cancels its delayed launches and placement.
    @discardableResult
    func exitLayers(showFeedback: Bool = true) -> LayerStage.Outcome {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.exitLayers(showFeedback: showFeedback) }
        }
        dispatchPrecondition(condition: .onQueue(.main))
        layerRecoveryWork?.cancel()
        layerFocus.exit()
        persistLayerFocus()
        classicShowing = false
        isSwitching = false
        LayerAim.shared.cancel()
        LayerPreview.shared.dismiss()
        let outcome = restoreExitedLayerWindows()
        if showFeedback {
            LayerBezel.shared.acknowledge(outcome.remainingToRestore == 0
                ? "Layers off" : "Layers off · \(outcome.remainingToRestore) waiting to restore")
        }
        // Apps can take a moment to expose AX windows after being unhidden.
        scheduleLayerRecovery()
        return outcome
    }

    private func persistLayerFocus() {
        UserDefaults.standard.set(layerFocus.isActive, forKey: layerFocusKey)
        UserDefaults.standard.set(layerFocus.pendingRestorationCount, forKey: layerRecoveryKey)
    }

    private func restoreExitedLayerWindows() -> LayerStage.Outcome {
        let generation = layerFocus.generation
        let outcome = LayerStage.shared.showAll()
        layerFocus.recovered(remaining: outcome.remainingToRestore, generation: generation)
        persistLayerFocus()
        return outcome
    }

    private func scheduleLayerRecovery() {
        guard layerFocus.needsRecovery else { return }
        layerRecoveryWork?.cancel()
        let generation = layerFocus.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.layerFocus.acceptsRecovery(generation) else { return }
            _ = self.restoreExitedLayerWindows()
        }
        layerRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Look up a layer index by id or label (case-insensitive)
    func layerIndex(named name: String) -> Int? {
        guard let layers = config?.layers else { return nil }
        // Try exact id match first
        if let i = layers.firstIndex(where: { $0.id == name }) { return i }
        // Then case-insensitive id
        if let i = layers.firstIndex(where: { $0.id.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return i }
        // Then case-insensitive label
        if let i = layers.firstIndex(where: { $0.label.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return i }
        return nil
    }

    // MARK: - Config I/O

    func loadConfig() {
        migrateStudioLayersIfNeeded()
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            config = nil
            return
        }
        do {
            config = try JSONDecoder().decode(WorkspaceConfig.self, from: data)
            // Clamp saved index
            if let config, let layers = config.layers, activeLayerIndex >= layers.count {
                activeLayerIndex = 0
            }
        } catch {
            DiagnosticLog.shared.error("WorkspaceManager: failed to decode workspace.json — \(error.localizedDescription)")
            config = nil
        }
    }

    /// Studio layers lived in layers.json until they were folded into the
    /// workspace's layers. With no workspace.json yet, carry them over once,
    /// each rule an entry, so ⌘⌥ reaches them. layers.json is left as it was.
    private func migrateStudioLayersIfNeeded() {
        struct StudioLayerFile: Decodable {
            let name: String
            let match: [StudioLayerClause]
        }
        let fm = FileManager.default
        let legacyPath = ((configPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("layers.json")
        guard !fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: legacyPath),
              let studio = try? JSONDecoder().decode([StudioLayerFile].self, from: data),
              !studio.isEmpty
        else { return }

        var layers: [Layer] = []
        for old in studio {
            let projects = old.match.map {
                LayerProject(path: nil, group: nil, tile: nil, display: nil,
                             url: nil, launch: nil, match: $0)
            }
            layers.append(Layer(
                id: Self.uniqueLayerID(for: old.name, in: layers),
                label: old.name,
                projects: projects,
                layout: "auto"
            ))
        }
        do {
            var root: [String: Any] = ["name": "workspace"]
            root["layers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layers))
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try out.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            DiagnosticLog.shared.info("WorkspaceManager: moved \(layers.count) Studio layers from layers.json into workspace.json")
        } catch {
            DiagnosticLog.shared.error("WorkspaceManager: couldn't move layers.json into workspace.json — \(error.localizedDescription)")
        }
    }

    func reloadConfig() {
        loadConfig()
        loadGridConfig()
    }

    // MARK: - Grid Config I/O

    func loadGridConfig() {
        let token = gridConfigSourceFingerprint()
        if token == gridConfigSourceToken { return }
        gridConfigSourceToken = token

        var presets: [String: GridPreset] = [:]
        var layouts: [String: LayoutConfig] = [:]
        var snapZones = SnapZonesConfig.defaults

        // Load global ~/.lattices/grid.json
        if FileManager.default.fileExists(atPath: gridConfigPath),
           let data = FileManager.default.contents(atPath: gridConfigPath) {
            do {
                let gridFile = try JSONDecoder().decode(GridFile.self, from: data)
                if let p = gridFile.presets { presets.merge(p) { _, new in new } }
                if let l = gridFile.layouts { layouts.merge(l) { _, new in new } }
                if let snap = gridFile.snapZones {
                    snapZones = snap.merged(over: snapZones)
                }
            } catch {
                DiagnosticLog.shared.error("WorkspaceManager: failed to decode grid.json — \(Self.describeDecodingError(error))")
            }
        }

        if FileManager.default.fileExists(atPath: snapZonesConfigPath),
           let data = FileManager.default.contents(atPath: snapZonesConfigPath) {
            do {
                let config = try JSONDecoder().decode(SnapZonesConfig.self, from: data)
                snapZones = config.merged(over: snapZones)
            } catch {
                DiagnosticLog.shared.error("WorkspaceManager: failed to decode snap-zones.json — \(error.localizedDescription)")
            }
        }

        // Merge per-project .lattices.json "grid" section on top
        let projectGridPath = ".lattices.json"
        if FileManager.default.fileExists(atPath: projectGridPath),
           let data = FileManager.default.contents(atPath: projectGridPath) {
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let gridDict = json["grid"] {
                    let gridData = try JSONSerialization.data(withJSONObject: gridDict)
                    let gridFile = try JSONDecoder().decode(GridFile.self, from: gridData)
                    if let p = gridFile.presets { presets.merge(p) { _, new in new } }
                    if let l = gridFile.layouts { layouts.merge(l) { _, new in new } }
                    if let snap = gridFile.snapZones {
                        snapZones = snap.merged(over: snapZones)
                    }
                }
            } catch {
                DiagnosticLog.shared.error("WorkspaceManager: failed to decode .lattices.json grid — \(Self.describeDecodingError(error))")
            }
        }

        self.gridPresets = presets
        self.gridLayouts = layouts
        self.snapZonesConfig = snapZones
    }

    func updateSnapModifier(_ modifier: SnapModifierKey) {
        let updated = SnapZonesConfig(
            enabled: snapZonesConfig.enabled,
            modifier: modifier,
            zoneOpacity: snapZonesConfig.zoneOpacity,
            highlightOpacity: snapZonesConfig.highlightOpacity,
            previewOpacity: snapZonesConfig.previewOpacity,
            cornerRadius: snapZonesConfig.cornerRadius,
            rules: snapZonesConfig.rules
        )

        do {
            let url = URL(fileURLWithPath: snapZonesConfigPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updated)
            try data.write(to: url, options: .atomic)

            loadGridConfig()
            DiagnosticLog.shared.info("WorkspaceManager: updated snap modifier to \(modifier.rawValue)")
        } catch {
            DiagnosticLog.shared.error("WorkspaceManager: failed to write snap-zones.json — \(error.localizedDescription)")
        }
    }

    /// Resolve a tile string to fractions: check user presets first, then built-in TilePosition
    func resolveTileFractions(_ tile: String) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        resolvePlacement(tile)?.fractions
    }

    func resolveLayoutFractions(_ layout: LayoutConfig, windowIndex: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        switch layout.placement(at: windowIndex) {
        case .named(let tile):
            return resolveTileFractions(tile)
        case .fractions(let box):
            return box.fractions
        case nil:
            return nil
        }
    }

    private func gridConfigSourceFingerprint() -> String {
        func stamp(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? -1
            return "\(path):\(mtime):\(size)"
        }
        let projectGrid = (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(".lattices.json")
        return [gridConfigPath, snapZonesConfigPath, projectGrid].map(stamp).joined(separator: "|")
    }

    static func describeDecodingError(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "(root)" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .valueNotFound(let type, let context):
            return "missing \(type) at \(path(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch (\(type)) at \(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "corrupted at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    func resolvePlacement(_ tile: String) -> PlacementSpec? {
        if let preset = gridPresets[tile],
           let placement = FractionalPlacement(x: preset.x, y: preset.y, w: preset.w, h: preset.h) {
            return .fractions(placement)
        }
        return PlacementSpec(string: tile)
    }

    // MARK: - Tab Groups

    func group(byId id: String) -> TabGroup? {
        config?.groups?.first(where: { $0.id == id })
    }

    var activeLayerGroups: [TabGroup] {
        guard let layer = activeLayer else { return [] }
        return layer.projects.compactMap { project in
            project.group.flatMap(group(byId:))
        }
    }

    func selectedTabIndex(in group: TabGroup) -> Int {
        min(selectedGroupTabIndices[group.id] ?? 0, max(0, group.tabs.count - 1))
    }

    func isGroupExpanded(_ group: TabGroup) -> Bool {
        expandedGroupIDs.contains(group.id)
    }

    func isTabRunning(_ tab: TabGroupTab) -> Bool {
        if let path = tab.path {
            let name = Self.sessionName(for: path)
            return shell([tmuxPath, "has-session", "-t", name]) == 0
        }
        guard let app = tab.app else { return false }
        return DesktopModel.shared.windowForApp(app: app, title: tab.title) != nil
            || Self.findAppWindow(app: app, title: tab.title) != nil
    }

    func isGroupRunning(_ group: TabGroup) -> Bool {
        group.tabs.contains(where: isTabRunning)
    }

    /// Count how many tabs in the group have running sessions
    func runningTabCount(_ group: TabGroup) -> Int {
        group.tabs.filter(isTabRunning).count
    }

    /// Launch a mixed group. Project tabs open in the terminal; app/URL tabs
    /// open as native application windows.
    func launchGroup(_ group: TabGroup, layerGeneration: UInt64? = nil) {
        let terminal = Preferences.shared.terminal
        let latticesCommand = LatticesRuntime.cliShellCommand
        for (i, tab) in group.tabs.enumerated() {
            guard !isTabRunning(tab) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) {
                if let layerGeneration, !self.layerFocus.acceptsLayerWork(layerGeneration) { return }
                if let path = tab.path {
                    let earlierTerminalTabs = group.tabs[..<i].contains(where: \.isTerminal)
                    if !earlierTerminalTabs {
                        terminal.launch(command: "\(latticesCommand) start", in: path)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if let layerGeneration, !self.layerFocus.acceptsLayerWork(layerGeneration) { return }
                            terminal.nameTab(tab.displayLabel)
                        }
                    } else {
                        terminal.launchTab(
                            command: "\(latticesCommand) start",
                            in: path,
                            tabName: tab.displayLabel
                        )
                    }
                } else {
                    self.launch(tab)
                }
            }
        }
    }

    /// Kill all individual tab sessions for a group
    func killGroup(_ group: TabGroup) {
        for tab in group.tabs {
            guard let path = tab.path else { continue }
            let name = Self.sessionName(for: path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tmuxPath)
            task.arguments = ["kill-session", "-t", name]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    /// Focus a specific terminal or application window in a mixed tab group.
    /// When the group is collapsed, switching tabs keeps every member in the
    /// group's configured layer slot.
    func focusTab(group: TabGroup, tabIndex: Int) {
        guard tabIndex >= 0, tabIndex < group.tabs.count else { return }
        selectedGroupTabIndices[group.id] = tabIndex
        let tab = group.tabs[tabIndex]
        if !isGroupExpanded(group) {
            collapseGroup(group)
        }

        if let entry = window(for: tab) {
            _ = WindowTiler.focusWindow(wid: entry.wid, pid: entry.pid)
            WindowTiler.highlightWindowById(wid: entry.wid)
        } else if let path = tab.path {
            Preferences.shared.terminal.focusOrAttach(session: Self.sessionName(for: path))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.collapseGroup(group)
            }
        } else {
            launch(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.collapseGroup(group)
            }
        }
    }

    /// Toggle between a single-slot cross-app tab stack and a full smart grid.
    func toggleGroupLayout(_ group: TabGroup) {
        if isGroupExpanded(group) {
            collapseGroup(group)
        } else {
            expandGroupToGrid(group)
        }
    }

    func expandGroupToGrid(_ group: TabGroup) {
        DesktopModel.shared.poll()
        let windows = orderedWindows(for: group)
        guard !windows.isEmpty else { return }
        expandedGroupIDs.insert(group.id)
        WindowTiler.batchRaiseAndDistribute(
            windows: windows.map { (wid: $0.wid, pid: $0.pid) },
            reactivateLattices: false
        )
        DiagnosticLog.shared.info("WorkspaceManager: expanded mixed group '\(group.label)' to grid")
    }

    func collapseGroup(_ group: TabGroup) {
        DesktopModel.shared.poll()
        let selected = selectedTabIndex(in: group)
        let front = group.tabs.indices.contains(selected) ? window(for: group.tabs[selected]) : nil
        collapse(group, windows: orderedWindows(for: group), focusing: front)
    }

    /// `collapseGroup` after a layer launched the group's missing tabs: only
    /// the windows layer `layerId` holds by the group's entry now, on screen
    /// and not tucked. Nothing once another layer is active.
    private func collapseGroup(_ group: TabGroup, ofLayer layerId: String) {
        guard let layer = activeLayer, layer.id == layerId,
              let entry = layer.projects.firstIndex(where: { $0.group == group.id }) else { return }
        let tucked = LayerStage.shared.tucked(layerId)
        let held = membership(of: layer, in: DesktopModel.shared.refreshNow()).members
            .filter { $0.project == entry && $0.entry.isOnScreen && !tucked.contains($0.entry.wid) }
        let windows = tabOrdered(held.map(\.entry), in: group)
        let selected = selectedTabIndex(in: group)
        let front = group.tabs.indices.contains(selected)
            ? windows.last { LayerMembership.reads(group.tabs[selected], $0) } : nil
        collapse(group, windows: windows, focusing: front)
    }

    /// Stacks `windows` in the group's slot, the last in front, and focuses `front`.
    private func collapse(_ group: TabGroup, windows: [WindowEntry], focusing front: WindowEntry?) {
        guard !windows.isEmpty,
              let (placement, targetScreen) = groupPlacement(group) else { return }

        let frame = WindowTiler.tileFrame(for: placement, on: targetScreen)
        WindowTiler.batchMoveAndRaiseWindows(
            windows.map { (wid: $0.wid, pid: $0.pid, frame: frame) }
        )
        expandedGroupIDs.remove(group.id)

        if let front {
            _ = WindowTiler.focusWindow(wid: front.wid, pid: front.pid)
        }
        DiagnosticLog.shared.info("WorkspaceManager: collapsed mixed group '\(group.label)' to \(placement.wireValue)")
    }

    private func window(for tab: TabGroupTab, currentSpaceOnly: Bool = false) -> WindowEntry? {
        if let path = tab.path {
            return windowForSession(Self.sessionName(for: path), currentSpaceOnly: currentSpaceOnly)
        }
        guard let app = tab.app else { return nil }
        return DesktopModel.shared.windowForApp(app: app, title: tab.title, currentSpaceOnly: currentSpaceOnly)
    }

    private func orderedWindows(for group: TabGroup, currentSpaceOnly: Bool = false) -> [WindowEntry] {
        let selected = selectedTabIndex(in: group)
        var result: [WindowEntry] = []
        for (index, tab) in group.tabs.enumerated() where index != selected {
            if let entry = window(for: tab, currentSpaceOnly: currentSpaceOnly), !result.contains(where: { $0.wid == entry.wid }) {
                result.append(entry)
            }
        }
        if selected < group.tabs.count,
           let entry = window(for: group.tabs[selected], currentSpaceOnly: currentSpaceOnly),
           !result.contains(where: { $0.wid == entry.wid }) {
            result.append(entry)
        }
        return result
    }

    /// One of `windows` per tab of `group`, the front one each tab reads,
    /// with the selected tab last so it lands in front.
    private func tabOrdered(_ windows: [WindowEntry], in group: TabGroup) -> [WindowEntry] {
        let selected = selectedTabIndex(in: group)
        var order = group.tabs.indices.filter { $0 != selected }
        if group.tabs.indices.contains(selected) { order.append(selected) }
        var result: [WindowEntry] = []
        for index in order {
            let tab = group.tabs[index]
            if let window = windows.first(where: { window in
                LayerMembership.reads(tab, window) && !result.contains { $0.wid == window.wid }
            }) {
                result.append(window)
            }
        }
        return result
    }

    private func groupPlacement(_ group: TabGroup) -> (PlacementSpec, NSScreen)? {
        let project = activeLayer?.projects.first(where: { $0.group == group.id })
            ?? config?.layers?.lazy.compactMap { layer in
                layer.projects.first(where: { $0.group == group.id })
            }.first
        let placement = project?.tile.flatMap(resolvePlacement) ?? .tile(.topLeft)
        guard let targetScreen = screen(for: project?.display) else { return nil }
        return (placement, targetScreen)
    }

    private func launch(_ tab: TabGroupTab) {
        if let urlString = tab.url, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let appName = tab.launch ?? tab.app {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
    }

    /// Run a command and return exit code
    private func shell(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Display Helper

    /// Resolve a display index to an NSScreen (falls back to first screen)
    private func screen(for displayIndex: Int?) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let idx = displayIndex ?? 0
        return idx < screens.count ? screens[idx] : screens[0]
    }

    // MARK: - Window Lookup

    /// Find a tracked window for a session name (instant — uses DesktopModel cache)
    private func windowForSession(_ sessionName: String, currentSpaceOnly: Bool = false) -> WindowEntry? {
        DesktopModel.shared.windowForSession(sessionName, currentSpaceOnly: currentSpaceOnly)
    }

    // MARK: - Tiling

    /// Re-tile the current layer without switching (for "tile all"): the
    /// same switch, to the layer already active.
    func retileCurrentLayer() {
        guard isLayerFocusActive else { return }
        tileLayer(index: activeLayerIndex)
    }

    // MARK: - Layer Stage

    /// What entries point at beyond the layers: tab groups and projects'
    /// companion windows.
    var membershipSources: LayerMembership.Sources {
        LayerMembership.Sources(
            group: { self.group(byId: $0) },
            projectWindows: { self.projectWindows(at: $0) }
        )
    }

    /// Which layer holds each window, across every configured layer.
    func layerMembership(in windows: [WindowEntry]) -> LayerMembership.Resolution {
        LayerMembership.resolve(layers, windows: windows, sources: membershipSources)
    }

    /// Every window the layer holds, on any desktop: the layer's own
    /// windows, as opposed to whatever else was showing when it was left.
    func memberWindowIDs(of layer: Layer, in windows: [WindowEntry]) -> Set<UInt32> {
        Set(memberWindows(of: layer, in: windows).map(\.entry.wid))
    }

    /// The layer's windows in entry order, front to back within an entry,
    /// each under the entry that holds it, whose index in `layer.projects`
    /// is `project`. A window belongs to one layer at most
    /// (`LayerMembership`). `placed` marks the ones whose entry sets its own
    /// `tile` or `display`, which a layout leaves be.
    func memberWindows(of layer: Layer, in windows: [WindowEntry]) -> [(entry: WindowEntry, placed: Bool, project: Int)] {
        membership(of: layer, in: windows).members
    }

    /// `memberWindows`, and which of them a pin holds. A configured layer is
    /// weighed against the others; one that isn't, or a stand-in whose id
    /// has a `#`, is resolved alone.
    func membership(of layer: Layer, in windows: [WindowEntry]) -> (members: [LayerMembership.Member], pinned: Set<UInt32>) {
        var scope = [layer]
        var at = 0
        if !layer.id.contains("#"), let index = layers.firstIndex(where: { $0.id == layer.id }) {
            scope = layers
            scope[index] = layer
            at = index
        }
        let resolution = LayerMembership.resolve(scope, windows: windows, sources: membershipSources)
        let members = resolution.layers[at]
        return (members, resolution.pinned.intersection(members.map(\.entry.wid)))
    }

    /// Put away what the incoming layer doesn't use and bring back what it
    /// had showing (see `LayerStage`), from a fresh inventory. Staging the
    /// active layer again reconciles it the same way.
    @discardableResult
    func stageSwitch(to index: Int, in layers: [Layer], persistRebinds: Bool = true) -> LayerStage.Outcome {
        dispatchPrecondition(condition: .onQueue(.main))
        let outgoing = isLayerFocusActive && layers.indices.contains(activeLayerIndex) ? layers[activeLayerIndex] : nil
        layerRecoveryWork?.cancel()
        layerFocus.enter()
        persistLayerFocus()
        let windows = DesktopModel.shared.refreshNow()
        let resolution = LayerMembership.resolve(layers, windows: windows, sources: membershipSources)
        var members: [String: Set<UInt32>] = [:]
        for (layer, held) in zip(layers, resolution.layers) {
            members[layer.id, default: []].formUnion(held.map(\.entry.wid))
        }
        if persistRebinds { keepRebinds(resolution, of: layers) }
        return LayerStage.shared.stage(outgoing: outgoing, incoming: layers[index], members: members, windows: windows)
    }

    // MARK: - Layer Switch

    /// The one switch every path takes, the active layer again included:
    /// stage (`stageSwitch`), then from a fresh inventory resolve the
    /// layer's windows, let `place` put them where their entries say, lay
    /// them out (`arrangeLayer`) or raise them in place, show the bezel from
    /// that inventory and what the stage did, and post `.layerSwitched`.
    /// The members the layer keeps `tucked` stay put away: `place` gets them
    /// to leave be, and nothing lays them out or raises them.
    /// The bezel leaves the apps out when `listApps` is false.
    @discardableResult
    private func switchLayer(
        to index: Int,
        in layers: [Layer],
        listApps: Bool = true,
        persistRebinds: Bool = true,
        place: (_ held: [LayerMembership.Member], _ pinned: Set<UInt32>, _ tucked: Set<UInt32>) -> Void = { _, _, _ in }
    ) -> LayerStage.Outcome {
        dispatchPrecondition(condition: .onQueue(.main))
        let layer = layers[index]
        noteSwitch(to: index, in: layers)
        let outcome = stageSwitch(to: index, in: layers, persistRebinds: persistRebinds)

        let windows = DesktopModel.shared.refreshNow()
        let (held, pinned) = membership(of: layer, in: windows)
        let tucked = LayerStage.shared.tucked(layer.id)
        place(held, pinned, tucked)
        if !arrangeLayer(layer, windows: windows, except: tucked) {
            raiseWindows(of: layer, held: held.filter { !tucked.contains($0.entry.wid) }, pinned: pinned)
        }

        activeLayerIndex = index
        classicShowing = false
        UserDefaults.standard.set(index, forKey: activeLayerKey)

        if listApps {
            showBezel(for: index, in: layers, windows: windows, outcome: outcome)
        } else {
            LayerBezel.shared.show(label: layer.label, index: index, total: layers.count)
        }
        EventBus.shared.post(.layerSwitched(index: index))
        return outcome
    }

    // MARK: - Layer Focus (no launching)

    /// Switch to a layer: put away what it doesn't use, then bring its
    /// windows forward — no launching. This is the default hotkey action. A
    /// layer with a `layout` lays its windows out (`arrangeLayer`); one
    /// without raises them in place. Choosing the active layer again runs
    /// the same switch, which reconciles it and gathers its windows back
    /// up. Windows on a desktop that isn't showing are left there; raising
    /// one would switch Spaces.
    func focusLayer(index: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.focusLayer(index: index) }
            return
        }
        guard let config, let layers = config.layers, layers.indices.contains(index) else { return }
        let switching = !isLayerFocusActive || index != activeLayerIndex

        let diag = DiagnosticLog.shared
        let t = diag.startTimed("focusLayer \(activeLayerIndex)→\(index)")

        switchLayer(to: index, in: layers)
        if switching {
            HandsOffSession.shared.playCachedCue("Switched.")
        }

        diag.finish(t)
    }

    /// Raises the layer's windows on the showing desktop, where they are:
    /// every window pinned to an entry, then the front window of an app or
    /// rule entry holding no pinned one, or of each tab of a group, and a
    /// project's session and companion windows. Only the members `held`
    /// resolved for the layer; `pinned` are the ones a pin holds.
    private func raiseWindows(of targetLayer: Layer, held: [LayerMembership.Member], pinned: Set<UInt32>) {
        let members = held.filter { $0.entry.isOnScreen }
        var seen = Set<UInt32>()
        var windowsToRaise: [(wid: UInt32, pid: Int32)] = []
        func raise(_ entry: WindowEntry) {
            if seen.insert(entry.wid).inserted { windowsToRaise.append((entry.wid, entry.pid)) }
        }

        for (index, lp) in targetLayer.projects.enumerated() {
            let mine = members.filter { $0.project == index }
            let pinnedHere = mine.filter { pinned.contains($0.entry.wid) }
            pinnedHere.forEach { raise($0.entry) }

            if lp.match != nil {
                if pinnedHere.isEmpty, let front = mine.first { raise(front.entry) }
                continue
            }
            if let groupId = lp.group, let grp = group(byId: groupId) {
                tabOrdered(mine.map(\.entry), in: grp).forEach(raise)
                continue
            }
            if lp.app != nil {
                if pinnedHere.isEmpty, let front = mine.first { raise(front.entry) }
                continue
            }
            if lp.path != nil {
                mine.forEach { raise($0.entry) }
            }
        }

        if !windowsToRaise.isEmpty {
            WindowTiler.raiseWindowsAndReactivate(windows: windowsToRaise)
        }
    }

    // MARK: - Layer Tiling

    /// A running session the inventory has no window for yet, tiled by name
    /// after the switch.
    private typealias TileFallback = (session: String, position: PlacementSpec, screen: NSScreen)
    /// A launch to run after the switch, and where to tile its session once
    /// it's up.
    private typealias TileLaunch = (session: String, position: PlacementSpec?, screen: NSScreen, launchAction: () -> Void)

    /// Switch to a layer as `focusLayer` does, first putting each entry's
    /// windows where its `tile` or `display` says (`tileEntries`). With
    /// `launch`, it also starts what isn't running and tiles it once it's
    /// up; the bezel then leaves the apps out, since ones still launching
    /// would read as not open. Choosing the active layer again runs the same
    /// switch, which re-tiles it.
    func tileLayer(index: Int, launch: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.tileLayer(index: index, launch: launch) }
            return
        }
        guard let config, let layers = config.layers, layers.indices.contains(index) else { return }

        let diag = DiagnosticLog.shared
        let label = launch ? "tileLayer(launch)" : "tileLayer(focus)"
        let overall = diag.startTimed("\(label) \(activeLayerIndex)→\(index)")

        isSwitching = true
        let terminal = Preferences.shared.terminal
        let scanner = ProjectScanner.shared
        var fallbacks: [TileFallback] = []
        var launchQueue: [TileLaunch] = []

        switchLayer(to: index, in: layers, listApps: !launch) { held, pinned, tucked in
            let work = self.tileEntries(of: layers[index], index: index, held: held, pinned: pinned, tucked: tucked, launch: launch)
            fallbacks = work.fallbacks
            launchQueue = work.launches
        }
        let generation = layerFocus.generation

        // Phase 3: fallback for running-but-untracked windows
        for (i, fb) in fallbacks.enumerated() {
            let delay = Double(i) * 0.15 + 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.layerFocus.acceptsLayerWork(generation) else { return }
                diag.info("  tile fallback: \(fb.session) → \(fb.position.wireValue)")
                WindowTiler.navigateToWindow(session: fb.session, terminal: terminal)
                WindowTiler.tile(session: fb.session, terminal: terminal, to: fb.position, on: fb.screen)
            }
        }

        // Phase 4: staggered tile for newly-launched windows
        for (i, item) in launchQueue.enumerated() {
            let delay = Double(i) * 0.15 + 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.layerFocus.acceptsLayerWork(generation) else { return }
                item.launchAction()
                if let pos = item.position {
                    let t = diag.startTimed("tile launched: \(item.session) → \(pos.wireValue)")
                    WindowTiler.tile(session: item.session, terminal: terminal, to: pos, on: item.screen)
                    diag.finish(t)
                }
            }
        }

        let maxDelay = max(
            fallbacks.isEmpty ? 0.0 : Double(fallbacks.count) * 0.15 + 0.3,
            launchQueue.isEmpty ? 0.0 : Double(launchQueue.count) * 0.15 + 0.5
        )
        let cleanupDelay = max(0.2, maxDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) {
            guard self.layerFocus.acceptsLayerWork(generation) else { return }
            scanner.refreshStatus()
            self.isSwitching = false
            diag.finish(overall)
        }
    }

    /// Puts each entry's windows where its `tile` or `display` says, from
    /// the members `held` a fresh inventory resolved for the layer (`pinned`
    /// the ones a pin holds), and with `launch` starts what isn't running.
    /// Only windows the layer holds are placed; `findAppWindow` only tells
    /// whether an app is open elsewhere, so a second one isn't launched.
    /// `tucked` ones are left where they are, as if on another desktop.
    /// Returns the sessions to tile by name and the launches to run.
    private func tileEntries(
        of targetLayer: Layer,
        index: Int,
        held: [LayerMembership.Member],
        pinned: Set<UInt32>,
        tucked: Set<UInt32>,
        launch: Bool
    ) -> (fallbacks: [TileFallback], launches: [TileLaunch]) {
        let diag = DiagnosticLog.shared
        let terminal = Preferences.shared.terminal
        let scanner = ProjectScanner.shared
        let generation = layerFocus.generation

        // Tile debug log (written to ~/.lattices/tile-debug.log)
        let debugPath = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".lattices/tile-debug.log")
        var debugLines: [String] = ["tileLayer index=\(index) launch=\(launch) layer=\(targetLayer.id)"]

        // Phase 1: classify each project
        var batchMoves: [(wid: UInt32, pid: Int32, frame: CGRect)] = []
        var fallbacks: [TileFallback] = []
        var launchQueue: [TileLaunch] = []

        // Log screen info
        for (i, s) in NSScreen.screens.enumerated() {
            debugLines.append("screen[\(i)]: frame=\(s.frame) visible=\(s.visibleFrame)")
        }

        // The window each app or rule entry places: one pinned to it, else
        // its front one. `away` are the ones on a desktop that isn't showing,
        // or put away.
        let members = held.filter { $0.entry.isOnScreen && !tucked.contains($0.entry.wid) }
        func target(for entry: Int) -> WindowEntry? {
            let mine = members.filter { $0.project == entry }
            return (mine.first { pinned.contains($0.entry.wid) } ?? mine.first)?.entry
        }
        func showing(_ entry: Int) -> [WindowEntry] {
            members.filter { $0.project == entry }.map(\.entry)
        }
        func away(_ entry: Int) -> [WindowEntry] {
            held.filter { $0.project == entry && (!$0.entry.isOnScreen || tucked.contains($0.entry.wid)) }.map(\.entry)
        }

        for (entryIndex, lp) in targetLayer.projects.enumerated() {
            guard let lpScreen = screen(for: lp.display) else { continue }

            if lp.match != nil {
                if let pos = lp.tile.flatMap({ resolvePlacement($0) }), let entry = target(for: entryIndex) {
                    batchMoves.append((entry.wid, entry.pid, WindowTiler.tileFrame(for: pos, on: lpScreen)))
                }
                continue
            }

            if let groupId = lp.group, let grp = group(byId: groupId) {
                let position = lp.tile.flatMap { resolvePlacement($0) }
                let groupWindows = tabOrdered(showing(entryIndex), in: grp)
                let groupRunning = isGroupRunning(grp)

                if !groupWindows.isEmpty, let pos = position {
                    let frame = WindowTiler.tileFrame(for: pos, on: lpScreen)
                    batchMoves.append(contentsOf: groupWindows.map {
                        (wid: $0.wid, pid: $0.pid, frame: frame)
                    })
                    expandedGroupIDs.remove(grp.id)
                    if launch, runningTabCount(grp) < grp.tabs.count {
                        launchGroup(grp, layerGeneration: generation)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            guard self.layerFocus.acceptsLayerWork(generation) else { return }
                            self.collapseGroup(grp, ofLayer: targetLayer.id)
                        }
                    }
                } else if !groupRunning && launch {
                    diag.info("  launch group: \(grp.label)")
                    launchQueue.append(("group:\(grp.id)", nil, lpScreen, { [weak self] in
                        guard let self else { return }
                        self.launchGroup(grp, layerGeneration: generation)
                        if position != nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                guard self.layerFocus.acceptsLayerWork(generation) else { return }
                                self.collapseGroup(grp, ofLayer: targetLayer.id)
                            }
                        }
                    }))
                } else if groupWindows.isEmpty {
                    diag.info("  skip (not running): \(grp.label)")
                }
                continue
            }

            // App-based window matching
            if let appName = lp.app {
                let position = lp.tile.flatMap { resolvePlacement($0) }
                if let entry = target(for: entryIndex) {
                    if let pos = position {
                        let frame = WindowTiler.tileFrame(for: pos, on: lpScreen)
                        batchMoves.append((entry.wid, entry.pid, frame))
                    }
                } else if let found = away(entryIndex).first {
                    // Open on a desktop that isn't showing: leave it there rather
                    // than switch Spaces, and don't launch a second one.
                    diag.info("  skip (on another desktop): \(appName) wid=\(found.wid)")
                } else if launch, let found = Self.findAppWindow(app: appName, title: lp.title) {
                    // Open, but not a window this layer holds: don't launch a second one.
                    diag.info("  skip (open, not held): \(appName) wid=\(found.wid)")
                } else if launch {
                    diag.info("  launch app: \(appName)")
                    let capturedLp = lp
                    let capturedScreen = lpScreen
                    launchQueue.append(("app:\(appName)", nil, capturedScreen, { [weak self] in
                        self?.launchAppEntry(capturedLp)
                    }))
                    // Queue a delayed tile after launch, of the window the
                    // entry holds once it's up.
                    if let pos = position {
                        let delay = Double(launchQueue.count) * 0.5 + 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.layerFocus.acceptsLayerWork(generation),
                                  let entry = self.launchedWindow(of: targetLayer, entry: entryIndex) else { return }
                            let frame = WindowTiler.tileFrame(for: pos, on: capturedScreen)
                            WindowTiler.batchMoveAndRaiseWindows([(entry.wid, entry.pid, frame)])
                        }
                    }
                } else {
                    diag.info("  skip (not found): \(appName)")
                }
                continue
            }

            guard let path = lp.path else { continue }
            let sessionName = Self.sessionName(for: path)
            let project = scanner.projects.first(where: { $0.path == path })
            let position = lp.tile.flatMap { resolvePlacement($0) }
            // Check scanner first, fall back to direct tmux check for projects without .lattices.json
            let isRunning = project?.isRunning == true || shell([tmuxPath, "has-session", "-t", sessionName]) == 0

            if isRunning {
                let sessionWindow = showing(entryIndex).first { LayerMembership.shows(session: sessionName, $0) }
                let foundWindow = sessionWindow ?? away(entryIndex).first { LayerMembership.shows(session: sessionName, $0) }
                let msg = "  \(sessionName): running=\(isRunning) window=\(foundWindow?.wid ?? 0) tile=\(position?.wireValue ?? "nil") desktopCount=\(DesktopModel.shared.windows.count)"
                diag.info(msg)
                debugLines.append(msg)
                if let pos = position, let window = sessionWindow {
                    let frame = WindowTiler.tileFrame(for: pos, on: lpScreen)
                    batchMoves.append((window.wid, window.pid, frame))
                    debugLines.append("    → batch move wid=\(window.wid) frame=\(frame)")
                } else if let pos = position {
                    if foundWindow != nil {
                        // On a desktop that isn't showing: leave it there.
                        debugLines.append("    → skip (on another desktop)")
                    } else {
                        fallbacks.append((sessionName, pos, lpScreen))
                        debugLines.append("    → fallback \(pos.wireValue)")
                    }
                }
            } else if launch {
                if let project {
                    let t = diag.startTimed("launch: \(project.name)")
                    SessionManager.launch(project: project)
                    diag.finish(t)
                } else {
                    diag.info("  launch (direct): \(sessionName)")
                    terminal.launch(command: "\(LatticesRuntime.cliShellCommand) start", in: path)
                }
                launchQueue.append((sessionName, position, lpScreen, {}))
            } else {
                diag.info("  skip (not running): \(sessionName)")
            }

            // Compose companion windows from project's .lattices.json "windows" array
            let companions = projectWindows(at: path)
            for cw in companions {
                guard let appName = cw.app else { continue }
                let cwScreen = screen(for: cw.display ?? lp.display) ?? lpScreen
                let cwPosition = cw.tile.flatMap { resolvePlacement($0) }
                func reads(_ window: WindowEntry) -> Bool { LayerMembership.reads(app: appName, title: cw.title, window) }
                if let entry = showing(entryIndex).first(where: reads) {
                    if let pos = cwPosition {
                        let frame = WindowTiler.tileFrame(for: pos, on: cwScreen)
                        batchMoves.append((entry.wid, entry.pid, frame))
                    }
                } else if away(entryIndex).contains(where: reads) {
                    diag.info("  skip companion (on another desktop): \(appName)")
                } else if launch, DesktopModel.shared.windowForApp(app: appName, title: cw.title) != nil {
                    // Open, but not a window this layer holds: don't launch a second one.
                    diag.info("  skip companion (open, not held): \(appName)")
                } else if launch {
                    diag.info("  launch companion: \(appName)")
                    let capturedCw = cw
                    launchQueue.append(("app:\(appName)", nil, cwScreen, { [weak self] in
                        self?.launchAppEntry(capturedCw)
                    }))
                    if let pos = cwPosition {
                        let capturedTitle = cw.title
                        let capturedScreen = cwScreen
                        let delay = Double(launchQueue.count) * 0.5 + 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.layerFocus.acceptsLayerWork(generation),
                                  let entry = self.launchedWindow(of: targetLayer, entry: entryIndex, matching: {
                                LayerMembership.reads(app: appName, title: capturedTitle, $0)
                            }) else { return }
                            let frame = WindowTiler.tileFrame(for: pos, on: capturedScreen)
                            WindowTiler.batchMoveAndRaiseWindows([(entry.wid, entry.pid, frame)])
                        }
                    }
                }
            }
        }

        // Write debug log
        debugLines.append("batchMoves=\(batchMoves.count) fallbacks=\(fallbacks.count) launchQueue=\(launchQueue.count)")
        try? debugLines.joined(separator: "\n").write(toFile: debugPath, atomically: true, encoding: .utf8)

        // Phase 2: batch tile all tracked windows
        if !batchMoves.isEmpty {
            let t = diag.startTimed("batch tile \(batchMoves.count) windows")
            WindowTiler.batchMoveAndRaiseWindows(batchMoves)
            diag.finish(t)
        }
        return (fallbacks, launchQueue)
    }

    /// The window entry `project` of `layer` holds on the showing desktop
    /// that `matching` picks, from a fresh inventory: where a launch that
    /// has come up gets tiled.
    private func launchedWindow(
        of layer: Layer,
        entry project: Int,
        matching: (WindowEntry) -> Bool = { _ in true }
    ) -> WindowEntry? {
        memberWindows(of: layer, in: DesktopModel.shared.refreshNow())
            .first { $0.project == project && $0.entry.isOnScreen && matching($0.entry) }?.entry
    }

    // MARK: - Per-Project Window Config

    /// Read companion window entries from a project's .lattices.json "windows" array
    func projectWindows(at projectPath: String) -> [LayerProject] {
        let configPath = (projectPath as NSString).appendingPathComponent(".lattices.json")
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windowsArray = json["windows"] else { return [] }
        do {
            let windowsData = try JSONSerialization.data(withJSONObject: windowsArray)
            return try JSONDecoder().decode([LayerProject].self, from: windowsData)
        } catch {
            DiagnosticLog.shared.error("WorkspaceManager: failed to decode windows in \(configPath) — \(error.localizedDescription)")
            return []
        }
    }

    /// Editor-only confirmed path. Never persists rebound pins or changes the
    /// workspace configuration. Opening entries does not stage or arrange.
    func executeEditorAction(_ operation: EditorActions.Operation) throws -> [String: Any] {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync { try self.executeEditorAction(operation) }
        }
        let subject = try EditorSubject(data: Data(contentsOf: URL(fileURLWithPath: configPath)))
        guard let index = subject.layers.firstIndex(where: { $0.id == operation.layerId }) else {
            throw EditorBridgeError("stale_plan", "The layer no longer exists.")
        }
        if operation.kind == "gather", operation.mode == "focus" {
            let outcome = switchLayer(to: index, in: subject.layers, persistRebinds: false)
            return ["putAway": outcome.parked.union(outcome.hidden).count, "skipped": outcome.missing.count]
        }
        guard operation.kind == "open", operation.mode == "launch" else {
            throw EditorBridgeError("invalid_request", "Unsupported operation.")
        }
        let layer = subject.layers[index]
        // Validate every index before any launch. Missingness and canonical
        // identities were already checked against the fresh confirmed snapshot.
        guard operation.entryIndices.allSatisfy({ layer.projects.indices.contains($0) }) else {
            throw EditorBridgeError("stale_plan", "Entries changed.")
        }
        for entryIndex in operation.entryIndices {
            let project = layer.projects[entryIndex]
            if let url = project.url, let target = URL(string: url) {
                NSWorkspace.shared.open(target)
            } else if let app = project.launch ?? project.app ?? project.match?.appEquals ?? project.match?.app {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-a", app]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try task.run()
            } else if let path = project.path {
                Preferences.shared.terminal.launch(command: "\(LatticesRuntime.cliShellCommand) start", in: path)
            }
        }
        return [:] // Launch acceptance is not proof that a window opened.
    }

    // MARK: - App Launch Helper

    /// Launch an app-based layer project (open URL or launch app by name)
    private func launchAppEntry(_ lp: LayerProject) {
        if let urlStr = lp.url, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        } else if let appName = lp.launch ?? lp.app {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
    }

    // MARK: - App Window Fallback (CGWindowList .optionAll)

    /// Find an app window across ALL Spaces via CGWindowList (bypasses DesktopModel cache)
    static func findAppWindow(app: String, title: String?) -> (wid: UInt32, pid: Int32)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName.localizedCaseInsensitiveContains(app),
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect),
                  rect.width >= 50, rect.height >= 50 else { continue }

            if let title {
                let windowTitle = info[kCGWindowName as String] as? String ?? ""
                guard windowTitle.localizedCaseInsensitiveContains(title) else { continue }
            }

            return (wid, pid)
        }
        return nil
    }

    // MARK: - Session Name Helper

    /// Replicates Project.sessionName logic from a bare path
    static func sessionName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = name.replacingOccurrences(
            of: "[^a-zA-Z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let hash = SHA256.hash(data: Data(path.utf8))
        let short = hash.prefix(3).map { String(format: "%02x", $0) }.joined()
        return "\(base)-\(short)"
    }
}
