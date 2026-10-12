import AppKit

/// Writing the ⌘⌥ layers: every surface that saves a set of windows as a
/// layer, or adds one to it, comes through here and lands in
/// `workspace.json`, the one place layers live.
///
/// A window is saved as an entry of its app and its title as it reads now,
/// pinned by wid (`LayerPin`). The pin keeps it in while it lives, even when
/// the title moves on, and finds it again by app and title after a restart.
/// A window lives in one layer: pinning it takes the pins other layers had
/// on it.
extension WorkspaceManager {
    enum LayerEditError: LocalizedError {
        case unknownLayer(String)
        case unknownLayout(String)
        case emptyName
        case write(String)
        case changedOnDisk

        var errorDescription: String? {
            switch self {
            case .unknownLayer(let name): return "No layer named \(name)"
            case .unknownLayout(let name): return "No layout named \(name)"
            case .emptyName: return "A layer needs a name"
            case .write(let why): return "Couldn't save workspace.json: \(why)"
            case .changedOnDisk: return "workspace.json changed on disk; reloaded it, try again"
            }
        }
    }

    private static var backedUp = false

    /// One step undo takes back, the layer you were on before it, and what
    /// it did, as the bezel says it. An edit keeps the layers before it; a
    /// switch keeps where the main screen's windows sat, back to front.
    struct LayerUndo {
        enum Kind {
            case edit(layers: [Layer])
            case switched(windows: [(wid: UInt32, pid: Int32, frame: CGRect)])
        }
        let kind: Kind
        let activeIndex: Int
        let summary: String
    }

    /// Edits and switches this launch, newest last. Undoing an edit writes
    /// the layers back and moves no window; undoing a switch goes back to
    /// the layer you were on and puts its windows where they sat.
    private static var undoStack: [LayerUndo] = []
    private static let undoLimit = 30

    var canUndoLayerEdit: Bool { !Self.undoStack.isEmpty }

    var layers: [Layer] { config?.layers ?? [] }

    // MARK: Windows worth saving

    /// The windows a "save this layout" means: on screen, titled, not ours,
    /// and big enough to be a working window rather than a palette.
    func saveableWindows() -> [WindowEntry] {
        let me = getpid()
        return DesktopModel.shared.allWindows()
            .filter {
                $0.isOnScreen && $0.axVerified && !$0.title.isEmpty && $0.pid != me
                    && $0.frame.w >= 120 && $0.frame.h >= 120
            }
            .sorted { $0.zIndex < $1.zIndex }
    }

    /// The front titled content window of the frontmost app, unless that's
    /// Lattices.
    func frontmostWindow() -> WindowEntry? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !LatticesRuntime.isLatticesBundleIdentifier(app.bundleIdentifier) else { return nil }
        return DesktopModel.shared.allWindows()
            .filter { $0.pid == app.processIdentifier && $0.hasTitle && DesktopModel.isContent($0) }
            .min { $0.zIndex < $1.zIndex }
    }

    // MARK: Edits

    /// Saves `windows` as a new layer after the others, and returns its index.
    /// `tiles` gives an entry its own tile, which the layer's layout leaves be.
    @discardableResult
    func createLayer(
        label: String, windows: [WindowEntry], tiles: [UInt32: String] = [:], entries: [LayerProject] = []
    ) throws -> Int {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw LayerEditError.emptyName }
        let all = Self.creating(label: label, windows: windows, tiles: tiles, entries: entries, in: layers)
        try saveLayers(all)
        DiagnosticLog.shared.info("Layers: created '\(label)' with \(Self.distinct(windows).count) window(s)")
        return all.count - 1
    }

    /// Adds each window the layer doesn't already hold, and returns how many
    /// it took. One it holds already is pinned to the entry that holds it,
    /// so it stays when its title moves on.
    @discardableResult
    func addWindows(_ windows: [WindowEntry], toLayer index: Int, tiles: [UInt32: String] = [:]) throws -> Int {
        guard layers.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        let (all, added) = Self.adding(
            windows, to: index, in: layers, tiles: tiles,
            live: DesktopModel.shared.allWindows(), sources: membershipSources
        )
        try saveIfChanged(all)
        return added
    }

    /// Takes a window out of a layer by dropping the entries that hold only
    /// it. False when an entry that matches other windows too (a bare app,
    /// a project) still holds it; that's a JSON edit.
    @discardableResult
    func removeWindow(_ wid: UInt32, fromLayer index: Int) throws -> Bool {
        guard layers.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        let (all, removed) = Self.removing(
            wid, from: index, in: layers, live: DesktopModel.shared.allWindows(), sources: membershipSources
        )
        try saveIfChanged(all)
        return removed
    }

    enum MoveOutcome { case moved, copied, unchanged }

    /// Puts a window in the layer at `target` and takes it out of the one at
    /// `source`, in one write. `.copied` when an entry in `source` still
    /// matches it and `target` doesn't win it.
    func moveWindow(_ window: WindowEntry, from source: Int, to target: Int) throws -> MoveOutcome {
        guard source != target else { return .unchanged }
        for index in [target, source] where !layers.indices.contains(index) {
            throw LayerEditError.unknownLayer("#\(index)")
        }
        let (all, outcome) = Self.moving(
            window, from: source, to: target, in: layers,
            live: DesktopModel.shared.allWindows(), sources: membershipSources
        )
        try saveIfChanged(all)
        DiagnosticLog.shared.info("Layers: \(window.app) '\(window.title)' → '\(layers[target].label)'\(outcome == .copied ? ", still in '\(layers[source].label)'" : "")")
        return outcome
    }

    /// Replaces the entry at `entry`, or adds one when it's nil.
    func setEntry(_ project: LayerProject, at entry: Int?, inLayer index: Int) throws {
        var all = layers
        guard all.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        if let entry, all[index].projects.indices.contains(entry) {
            all[index].projects[entry] = project
        } else {
            all[index].projects.append(project)
        }
        try saveLayers(all)
    }

    func removeEntry(at entry: Int, fromLayer index: Int) throws {
        var all = layers
        guard all.indices.contains(index), all[index].projects.indices.contains(entry) else {
            throw LayerEditError.unknownLayer("#\(index)")
        }
        all[index].projects.remove(at: entry)
        try saveLayers(all)
    }

    func layerIndex(id: String) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    func renameLayer(_ index: Int, to label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw LayerEditError.emptyName }
        var all = layers
        guard all.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        all[index].label = label
        try saveLayers(all)
    }

    /// Sets how the layer lays its windows out (`LayerLayout`); nil raises
    /// them where they are. The next switch to it acts on it.
    func setLayout(_ layout: String?, forLayer index: Int) throws {
        if let layout, LayerLayout.Kind(layout) == nil { throw LayerEditError.unknownLayout(layout) }
        var all = layers
        guard all.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        all[index].layout = layout
        try saveIfChanged(all)
    }

    /// Deletes the layer. The one you're on moves down with it, so the pad
    /// still lights the same layer.
    func deleteLayer(_ index: Int) throws {
        var all = layers
        guard all.indices.contains(index) else { throw LayerEditError.unknownLayer("#\(index)") }
        let removed = all.remove(at: index)
        try saveLayers(all)
        if index < activeLayerIndex || activeLayerIndex >= all.count {
            activeLayerIndex = max(0, activeLayerIndex - 1)
            UserDefaults.standard.set(activeLayerIndex, forKey: activeLayerKey)
        }
        DiagnosticLog.shared.info("Layers: deleted '\(removed.label)'")
    }

    /// ⌘⌥T: puts the front window in the layer you're on, making a first
    /// layer when there are none, and shows the pad on it.
    func addFrontmostWindowToActiveLayer() {
        guard let window = frontmostWindow() else {
            DiagnosticLog.shared.info("Layers: no window in front to add")
            return
        }
        do {
            if layers.isEmpty {
                activeLayerIndex = try createLayer(label: "Layer 1", windows: [window])
            } else {
                let index = min(max(activeLayerIndex, 0), layers.count - 1)
                let added = try addWindows([window], toLayer: index)
                DiagnosticLog.shared.info("Layers: \(added > 0 ? "added" : "already held") \(window.app) '\(window.title)' → '\(layers[index].label)'")
            }
            showBezel(for: min(max(activeLayerIndex, 0), layers.count - 1), in: layers)
        } catch {
            DiagnosticLog.shared.error("Layers: couldn't add the front window — \(error.localizedDescription)")
        }
    }

    /// Saves what `resolution` found of the pins: the windows dead ones were
    /// rebound to (`LayerMembership.Rebind`), so a pin holds its window by
    /// wid again, and the closed ones dropped (`LayerMembership.Closed`).
    /// Only while `resolved` is what's loaded; a failed write is logged, and
    /// the next switch finds them again.
    func keepRebinds(_ resolution: LayerMembership.Resolution, of resolved: [Layer]) {
        let (rebound, closed) = (resolution.rebound.count, resolution.closed.count)
        guard rebound + closed > 0, (try? Self.same(resolved, layers)) == true else { return }
        do {
            try saveLayers(Self.keeping(resolution, in: layers), undoable: false)
            DiagnosticLog.shared.info("Layers: rebound \(rebound) pin(s) to live windows, dropped \(closed) closed")
        } catch {
            DiagnosticLog.shared.error("Layers: couldn't save rebound pins — \(error.localizedDescription)")
        }
    }

    // MARK: Edits as values

    /// `layers` with `resolution`'s rebound pins on their new windows, and
    /// without its closed pins or the saved entries those leave holding
    /// nothing (`LayerProject.isSaved`).
    static func keeping(_ resolution: LayerMembership.Resolution, in layers: [Layer]) -> [Layer] {
        var all = layers
        func has(_ layer: Int, _ project: Int, _ pin: Int) -> Bool {
            all.indices.contains(layer) && all[layer].projects.indices.contains(project)
                && all[layer].projects[project].pins?.indices.contains(pin) == true
        }
        for pin in resolution.rebound where has(pin.layer, pin.project, pin.pin) {
            all[pin.layer].projects[pin.project].pins?[pin.pin].wid = pin.wid
            all[pin.layer].projects[pin.project].pins?[pin.pin].pid = pin.pid
        }
        var closed: [Int: [Int: [LayerPin]]] = [:]
        for pin in resolution.closed where has(pin.layer, pin.project, pin.pin) {
            guard let gone = all[pin.layer].projects[pin.project].pins?[pin.pin] else { continue }
            closed[pin.layer, default: [:]][pin.project, default: []].append(gone)
        }
        for (layer, entries) in closed {
            all[layer].projects = all[layer].projects.enumerated().compactMap { project, entry in
                guard let gone = entries[project] else { return entry }
                return entry.dropping { gone.contains($0) }
            }
        }
        return all
    }

    /// `layers` with a new layer after them: `entries`, then each window as
    /// an entry of its app and title, pinned to it.
    static func creating(
        label: String, windows: [WindowEntry], tiles: [UInt32: String] = [:], entries: [LayerProject] = [],
        in layers: [Layer]
    ) -> [Layer] {
        let windows = distinct(windows)
        var layer = Layer(id: uniqueLayerID(for: label, in: layers), label: label, projects: entries, layout: "auto")
        layer.projects += windows.map { entry(for: $0, tile: tiles[$0.wid]) }
        return releasing(windows, in: layers, except: nil) + [layer]
    }

    /// `layers` with each of `windows` in the layer at `index`: pinned to the
    /// entry that holds it already, else saved as a new entry. `added`
    /// counts the new entries.
    static func adding(
        _ windows: [WindowEntry], to index: Int, in layers: [Layer], tiles: [UInt32: String] = [:],
        live: [WindowEntry], sources: LayerMembership.Sources
    ) -> (layers: [Layer], added: Int) {
        let windows = distinct(windows)
        var all = releasing(windows, in: layers, except: index)
        // An add is asked for by hand: a dead pin may take the window even
        // while its app runs on.
        var asked = sources
        asked.isRunning = { _ in false }
        let resolution = LayerMembership.resolve([all[index]], windows: live, sources: asked)
        var added = 0
        for window in windows {
            if let held = resolution.owners[window.wid]?.project {
                // A dead pin found it: that pin holds it by its wid now.
                if let rebind = resolution.rebound.first(where: { $0.wid == window.wid }) {
                    all[index].projects[rebind.project].pins?[rebind.pin].wid = window.wid
                    all[index].projects[rebind.project].pins?[rebind.pin].pid = window.pid
                    continue
                }
                let pins = all[index].projects[held].pins ?? []
                if !pins.contains(where: { $0.wid == window.wid }) {
                    all[index].projects[held].pins = pins + [LayerPin(window)]
                }
                continue
            }
            all[index].projects.append(entry(for: window, tile: tiles[window.wid]))
            added += 1
        }
        return (all, added)
    }

    /// `layers` with `wid` out of the layer at `index`: its pins there
    /// released, and each entry dropped that then holds only it, or held it
    /// by a pin and now holds nothing. `removed` is false when an entry that
    /// matches other windows too still holds it.
    static func removing(
        _ wid: UInt32, from index: Int, in layers: [Layer], live: [WindowEntry], sources: LayerMembership.Sources
    ) -> (layers: [Layer], removed: Bool) {
        var all = layers
        var layer = all[index]
        var pinnedBy = Set<Int>()
        var spent = Set<Int>()
        for entry in layer.projects.indices {
            guard let pins = layer.projects[entry].pins, pins.contains(where: { $0.wid == wid }) else { continue }
            if let kept = layer.projects[entry].dropping(where: { $0.wid == wid }) {
                layer.projects[entry] = kept
            } else {
                layer.projects[entry].pins = nil
                spent.insert(entry)
            }
            pinnedBy.insert(entry)
        }
        // Judge each entry by everything its rule matches on its own, not
        // just the windows it's first to claim.
        let doomed = layer.projects.indices.filter { entry in
            if spent.contains(entry) { return true }
            let matched = entryMatches(layer, entry: entry, in: live, sources: sources)
            return matched == [wid] || (pinnedBy.contains(entry) && matched.isEmpty)
        }
        for entry in doomed.reversed() { layer.projects.remove(at: entry) }
        all[index] = layer
        let remaining = layer.projects.indices.contains { entry in
            entryMatches(layer, entry: entry, in: live, sources: sources).contains(wid)
        }
        return (all, !remaining)
    }

    /// `layers` with `window` out of the layer at `source` and in the one at
    /// `target`. The target's pin outranks a broader entry the source keeps,
    /// so it's `.moved` once the target holds the window.
    static func moving(
        _ window: WindowEntry, from source: Int, to target: Int, in layers: [Layer],
        live: [WindowEntry], sources: LayerMembership.Sources
    ) -> (layers: [Layer], outcome: MoveOutcome) {
        // Out of the source first, while its pins still show which entries
        // held the window by pin alone.
        let (taken, removed) = removing(window.wid, from: source, in: layers, live: live, sources: sources)
        let (all, added) = adding([window], to: target, in: taken, live: live, sources: sources)
        let owner = LayerMembership.resolve(all, windows: live, sources: sources).owners[window.wid]
        if removed || owner?.layerId == all[target].id { return (all, .moved) }
        return (all, added > 0 ? .copied : .unchanged)
    }

    /// The windows one entry matches by itself, its own pins included, less
    /// those pinned to the layer's other entries. Not weighed against other
    /// layers: it's how an edit judges an entry, not membership.
    static func entryMatches(
        _ layer: Layer, entry: Int, in windows: [WindowEntry], sources: LayerMembership.Sources
    ) -> Set<UInt32> {
        let elsewhere = Set(layer.projects.indices.filter { $0 != entry }
            .flatMap { layer.projects[$0].pins ?? [] }.map(\.wid))
        let single = Layer(id: "\(layer.id)#entry", label: layer.label, projects: [layer.projects[entry]])
        let resolution = LayerMembership.resolve(
            [single], windows: windows.filter { !elsewhere.contains($0.wid) }, sources: sources
        )
        return Set(resolution.layers[0].map(\.entry.wid))
    }

    /// `layers` without the pins any layer but `except` had on `windows`,
    /// or the saved entries that leaves holding nothing.
    private static func releasing(_ windows: [WindowEntry], in layers: [Layer], except: Int?) -> [Layer] {
        func taken(_ pin: LayerPin) -> Bool {
            windows.contains { $0.wid == pin.wid && $0.app == pin.app }
        }
        var all = layers
        for index in all.indices where index != except {
            all[index].projects = all[index].projects.compactMap { $0.dropping(where: taken) }
        }
        return all
    }

    private static func entry(for window: WindowEntry, tile: String?) -> LayerProject {
        LayerProject(
            path: nil, group: nil, tile: tile, display: nil, app: window.app, title: window.savedTitle,
            url: nil, launch: nil, pins: [LayerPin(window)], saved: true
        )
    }

    private static func distinct(_ windows: [WindowEntry]) -> [WindowEntry] {
        var seen = Set<UInt32>()
        return windows.filter { seen.insert($0.wid).inserted }
    }

    // MARK: Storage

    static func uniqueLayerID(for label: String, in layers: [Layer]) -> String {
        let slug = label.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let base = slug.isEmpty ? "layer" : slug
        let taken = Set(layers.map(\.id))
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    private func saveIfChanged(_ layers: [Layer]) throws {
        guard try !Self.same(layers, self.layers) else { return }
        try saveLayers(layers)
    }

    // MARK: Undo

    /// Takes back the last edit: writes the layers as they were before it
    /// and goes back to the layer you were on, without moving a window.
    /// Returns what it took back, nil with nothing to undo.
    @discardableResult
    func undoLayerEdit() throws -> String? {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync { try self.undoLayerEdit() }
        }
        guard let last = Self.undoStack.last else { return nil }
        switch last.kind {
        case .edit(let layers):
            try saveLayers(layers, undoable: false)
            Self.undoStack.removeLast()
            activeLayerIndex = min(max(last.activeIndex, 0), max(layers.count - 1, 0))
            UserDefaults.standard.set(activeLayerIndex, forKey: activeLayerKey)
        case .switched(let windows):
            Self.undoStack.removeLast()
            undoSwitch(to: last.activeIndex, windows: windows)
        }
        DiagnosticLog.shared.info("Layers: undid \(last.summary)")
        return last.summary
    }

    /// Before a switch away from the layer you're on: where the main
    /// screen's windows sit, back to front, for undo.
    func noteSwitch(to index: Int, in layers: [Layer]) {
        guard let activeIndex = activeLayerSelection,
              index != activeIndex, layers.indices.contains(index),
              let stage = LayerStage.Stage.current() else { return }
        let showing = DesktopModel.shared.allWindows()
            .filter { LayerStage.isShowing($0, on: stage) }
            .sorted { $0.zIndex > $1.zIndex }
        var seen = Set<UInt32>()
        let windows = showing.filter { seen.insert($0.wid).inserted }.map {
            (wid: $0.wid, pid: $0.pid, frame: CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h))
        }
        Self.undoStack.append(LayerUndo(
            kind: .switched(windows: windows), activeIndex: activeIndex,
            summary: "switching to '\(layers[index].label)'"
        ))
        if Self.undoStack.count > Self.undoLimit { Self.undoStack.removeFirst() }
    }

    /// Back to layer `index` as it was: stage it again, then put `windows`
    /// where they sat, back to front.
    private func undoSwitch(to index: Int, windows: [(wid: UInt32, pid: Int32, frame: CGRect)]) {
        let layers = self.layers
        guard layers.indices.contains(index) else { return }
        stageSwitch(to: index, in: layers, persistRebinds: false)
        let live = Set(DesktopModel.shared.refreshNow().map(\.wid))
        WindowTiler.batchMoveAndRaiseWindows(windows.filter { live.contains($0.wid) }, activation: .frontmostOnly)
        activeLayerIndex = index
        classicShowing = false
        UserDefaults.standard.set(index, forKey: activeLayerKey)
        EventBus.shared.post(.layerSwitched(index: index))
    }

    /// ⌘⌥Z: undo, said on the bezel.
    func undoLayerEditFromHotkey() {
        do {
            if let summary = try undoLayerEdit() {
                LayerBezel.shared.acknowledge("Undid \(summary)")
            } else {
                LayerBezel.shared.acknowledge("Nothing to undo")
            }
        } catch {
            LayerBezel.shared.acknowledge("Couldn't undo")
            DiagnosticLog.shared.error("Layers: couldn't undo — \(error.localizedDescription)")
        }
    }

    /// What an edit from `old` to `new` did, in a few words: the layers it
    /// made, deleted, renamed or changed, by name.
    static func changeSummary(from old: [Layer], to new: [Layer]) -> String {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var parts: [String] = []
        for layer in new where before[layer.id] == nil { parts.append("creating '\(layer.label)'") }
        for layer in old where !after.contains(layer.id) { parts.append("deleting '\(layer.label)'") }
        var edited: [String] = []
        for layer in new {
            guard let was = before[layer.id] else { continue }
            if was.label != layer.label { parts.append("renaming '\(was.label)' to '\(layer.label)'") }
            var same = layer
            same.label = was.label
            if (try? Self.same([same], [was])) != true { edited.append("'\(layer.label)'") }
        }
        if !edited.isEmpty {
            let named = edited.prefix(2).joined(separator: ", ")
            parts.append("editing \(named)\(edited.count > 2 ? " +\(edited.count - 2)" : "")")
        }
        if parts.isEmpty, old.map(\.id) != new.map(\.id) { parts.append("reordering layers") }
        return parts.isEmpty ? "an edit" : parts.joined(separator: ", ")
    }

    /// Writes `layers` into workspace.json, keeping everything else in the
    /// file as it was. The first write of a launch keeps the previous file
    /// as workspace.json.bak. An `undoable` write can be taken back
    /// (`undoLayerEdit`); bookkeeping such as rebound pins can't.
    private func saveLayers(_ layers: [Layer], undoable: Bool = true) throws {
        let previous = self.layers
        let previousActive = activeLayerIndex
        let fm = FileManager.default
        var root: [String: Any] = ["name": config?.name ?? "workspace"]
        if !fm.fileExists(atPath: configPath), !self.layers.isEmpty {
            // Gone since we read it: don't bring it back from memory alone.
            loadConfig()
            throw LayerEditError.changedOnDisk
        }
        if fm.fileExists(atPath: configPath) {
            // Never write over a file we couldn't read: it holds more than layers.
            guard let data = fm.contents(atPath: configPath),
                  let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw LayerEditError.write("workspace.json isn't readable JSON; fix it first") }
            root = existing
            // Nor over layers edited since we read them.
            let onDisk: [Layer]
            do {
                onDisk = try root["layers"].map {
                    try JSONDecoder().decode([Layer].self, from: JSONSerialization.data(withJSONObject: $0))
                } ?? []
            } catch {
                throw LayerEditError.write("workspace.json's layers don't read; fix them first")
            }
            guard try Self.same(onDisk, self.layers) else {
                loadConfig()
                throw LayerEditError.changedOnDisk
            }
        }
        do {
            root["layers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layers))
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try fm.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            if !Self.backedUp, fm.fileExists(atPath: configPath) {
                let backup = configPath + ".bak"
                try? fm.removeItem(atPath: backup)
                try fm.copyItem(atPath: configPath, toPath: backup)
                Self.backedUp = true
            }
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            throw LayerEditError.write(error.localizedDescription)
        }
        if undoable, (try? Self.same(previous, layers)) != true {
            Self.undoStack.append(LayerUndo(
                kind: .edit(layers: previous), activeIndex: previousActive,
                summary: Self.changeSummary(from: previous, to: layers)
            ))
            if Self.undoStack.count > Self.undoLimit { Self.undoStack.removeFirst() }
        }
        if var config {
            config.layers = layers
            self.config = config
        } else {
            config = WorkspaceConfig(name: root["name"] as? String ?? "workspace", groups: nil, layers: layers)
        }
    }
}

extension WorkspaceManager {
    fileprivate static func same(_ a: [Layer], _ b: [Layer]) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(a) == encoder.encode(b)
    }
}

extension LayerPin {
    /// The window as it reads now.
    init(_ window: WindowEntry) {
        self.init(wid: window.wid, app: window.app, title: window.savedTitle, pid: window.pid)
    }
}

extension LayerProject {
    /// The entry without the pins `gone` picks; nil when it was saved from a
    /// window (`isSaved`) and that leaves it no pin to hold one by.
    func dropping(where gone: (LayerPin) -> Bool) -> LayerProject? {
        guard let pins, pins.contains(where: gone) else { return self }
        let rest = pins.filter { !gone($0) }
        if rest.isEmpty && isSaved { return nil }
        var entry = self
        entry.pins = rest.isEmpty ? nil : rest
        return entry
    }
}

private extension WindowEntry {
    /// The title an entry or pin saves: CG's, else AX's when CG has none.
    var savedTitle: String { title.isEmpty ? (fullTitle ?? "") : title }
}

// MARK: - Entries as Studio rules

extension LayerProject {
    /// An entry from a Studio rule: plain `app` and `title` when that's all
    /// it says, so the file stays readable, the rule itself otherwise.
    init(clause: StudioLayerClause) {
        self.init(path: nil, group: nil, tile: nil, display: nil, app: nil, title: nil, url: nil, launch: nil)
        setClause(clause)
    }

    /// Swaps the entry's rule, keeping its tile, display, launch and the rest.
    /// A rule set by hand is written, so a saved entry matches by it now.
    mutating func setClause(_ clause: StudioLayerClause) {
        saved = nil
        // `app` and `title` both match by substring, as the rule's `app` and
        // `titleContains` do; anything more stays a rule.
        var bare = clause
        bare.app = nil
        bare.titleContains = nil
        let plain = clause.app != nil && bare == StudioLayerClause()
        app = plain ? clause.app : nil
        title = plain ? clause.titleContains : nil
        match = plain ? nil : clause
    }

    /// The entry as a Studio rule, for Hyperspace's rule editor. A project or
    /// tab group has no rule form; nil.
    var clause: StudioLayerClause? {
        if let match { return match }
        guard let app else { return nil }
        return StudioLayerClause(app: app, titleContains: title)
    }
}
