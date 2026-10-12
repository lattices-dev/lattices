import AppKit
import ApplicationServices

/// Virtual layers. A switch reconciles the main screen to the incoming
/// layer: what it wants shows, and the rest is put away. An app with nothing
/// wanted is hidden (⌘H); the other windows of the apps it does use are
/// parked in the main screen's bottom-right corner, AeroSpace-style: macOS
/// keeps a sliver showing and the rest sits off-screen. Each layer remembers
/// what else it had showing, per desktop, and gets it back on return. The
/// members it keeps `tucked` stay put away.
///
/// Only the main screen (the one layers tile onto) takes part, and only the
/// desktop it's showing. An app with windows on another display or desktop
/// is parked rather than hidden, so those stay put. A layer with nothing on
/// that desktop puts nothing away.
///
/// A switch plans first (`plan`), then runs in order: unhide the apps it
/// wants and wait for them to land, park, bring back what was parked, hide.
/// AppKit pulls an app's windows back on screen as it unhides, so one look
/// a moment later parks again whatever came back. Nothing watches in between.
///
/// Parked frames are written to `~/.lattices/layer-stage.json` so a window
/// can't be stranded in the corner: quitting puts them back, and after a
/// crash the next launch does.
///
/// Not every app lets a window go off-screen: standard Cocoa windows
/// constrain an AX move to the visible frame, so "parking" one just piles it
/// in the corner. Each park is read back, and a window that didn't go past
/// the edge is put straight back and left showing.
final class LayerStage {
    static let shared = LayerStage()

    struct ParkedWindow: Codable, Equatable {
        let wid: UInt32
        let pid: Int32
        let app: String
        let title: String
        /// Where the window was before it was parked (CG, top-left origin).
        let frame: WindowFrame
        /// Where it landed, read back after the move. Nil in a ledger from
        /// before it was kept; the park corner stands in.
        var spot: CGPoint? = nil
    }

    /// What a stage did, by window. `summary` is what's logged.
    struct Outcome {
        /// Wanted windows, less the ones it couldn't bring back.
        var shown: Set<UInt32> = []
        var parked: Set<UInt32> = []
        /// Showing windows put away by hiding their app.
        var hidden: Set<UInt32> = []
        /// Wanted windows brought back by unhiding their app.
        var unhidden: Set<UInt32> = []
        /// Wanted windows brought back from the park corner.
        var unparked: Set<UInt32> = []
        /// Windows their app kept on screen when parked: put back home.
        var stayed: Set<UInt32> = []
        /// Wanted windows AX couldn't bring back from the park corner.
        var missing: Set<UInt32> = []
        /// Parked windows AX couldn't reach, and untracked ones in the park
        /// corner: they sit on a desktop that isn't showing.
        var stillParked = 0
        /// Untracked windows found in the park corner and brought back.
        var rescued = 0
        var hiddenApps: [String] = []
        var unhiddenApps: [String] = []
        var stillHiddenApps: [String] = []

        var remainingToRestore: Int { stillParked + stillHiddenApps.count }

        var summary: String {
            "shown \(shown.count), parked \(parked.count), unparked \(unparked.count), stayed \(stayed.count), "
                + "missing \(missing.count), still parked \(stillParked), rescued \(rescued), "
                + "hid [\(hiddenApps.joined(separator: ", "))], unhid [\(unhiddenApps.joined(separator: ", "))]"
        }
    }

    struct Status {
        let parked: [ParkedWindow]
        let hiddenApps: [String]
    }

    /// What `layer-stage.json` holds. Any field may be missing, so an older
    /// file still loads.
    struct State: Codable, Equatable {
        var parked: [ParkedWindow] = []
        /// Apps a switch hid. Show All unhides these and leaves the apps the
        /// user hid alone.
        var hiddenPids: [Int32] = []
        /// "layer@space" → the windows that layer had showing on that
        /// desktop, beyond its own entries, when it was last left.
        var scenes: [String: [UInt32]] = [:]
        /// Layer id → members that layer keeps put away. Only the layer
        /// overview sets them.
        var tucked: [String: [UInt32]] = [:]
        /// Layer id → windows let out of `tucked` that a switch to the layer
        /// has yet to show: one on another desktop waits for a switch there.
        /// Its scene keeps them until then, so that switch brings them back.
        var untucked: [String: [UInt32]] = [:]

        private enum CodingKeys: String, CodingKey {
            case parked, hiddenPids, scenes, tucked, untucked
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            parked = try container.decodeIfPresent([ParkedWindow].self, forKey: .parked) ?? []
            hiddenPids = try container.decodeIfPresent([Int32].self, forKey: .hiddenPids) ?? []
            scenes = try container.decodeIfPresent([String: [UInt32]].self, forKey: .scenes) ?? [:]
            tucked = try container.decodeIfPresent([String: [UInt32]].self, forKey: .tucked) ?? [:]
            untucked = try container.decodeIfPresent([String: [UInt32]].self, forKey: .untucked) ?? [:]
        }

        /// Leaves `tucked` and `untucked` out while they're empty.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(parked, forKey: .parked)
            try container.encode(hiddenPids, forKey: .hiddenPids)
            try container.encode(scenes, forKey: .scenes)
            if !tucked.isEmpty { try container.encode(tucked, forKey: .tucked) }
            if !untucked.isEmpty { try container.encode(untucked, forKey: .untucked) }
        }
    }

    /// macOS keeps a parked window's top strip on screen; a window this close
    /// to the right edge is still where a switch put it.
    private static let parkedSlack: CGFloat = 40
    /// How far above the bottom edge macOS may pull a parked window's top
    /// to keep its title bar in reach.
    private static let parkedDrop: CGFloat = 160
    /// The size bar of `DesktopModel.isContent`, for the strays
    /// `rescueStrays` reads straight from CG.
    private static let minSide: CGFloat = 120
    /// How long a switch waits for the apps it unhides to come back.
    private static let unhideWait: TimeInterval = 0.3
    /// When the one look after a switch runs.
    private static let verifyDelay: TimeInterval = 0.15

    private let lock = NSLock()
    private var state: State
    private let statePath: String
    /// Moves on with each stage and Show All; a look scheduled by an earlier
    /// one finds it moved and does nothing.
    private var generation = 0
    /// What the last stage hid or parked, until its look. A hide lands a
    /// moment after it's asked for, and until then the app reads as showing.
    private var settlingPids = Set<Int32>()
    private var settlingWids = Set<UInt32>()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        statePath = (home as NSString).appendingPathComponent(".lattices/layer-stage.json")
        state = Self.load(from: statePath) ?? State()
    }

    // MARK: - Status

    /// What switches have put away. Reads only: windows that closed or were
    /// dragged back, and apps no longer hidden, are left out, and the ledger
    /// isn't written.
    func status() -> Status {
        let live = Self.liveWindows()
        let main = Stage.mainBounds
        lock.lock(); defer { lock.unlock() }
        let hidden = hiddenAppsLocked()
        let parked = live.map {
            Self.stillParked(state.parked, live: $0, main: main, hidden: hidden.union(settlingPids))
        } ?? state.parked
        let apps = Self.stillHidden(state.hiddenPids, hidden: hidden, settling: settlingPids).map { pid in
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        }
        return Status(parked: parked, hiddenApps: apps)
    }

    // MARK: - Tucked and scenes

    /// The members `layerId` keeps put away: a switch to it parks them
    /// rather than showing them.
    func tucked(_ layerId: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        return Set(state.tucked[layerId] ?? [])
    }

    /// Keep `wid` put away in `layerId`, or let it show again. The next
    /// switch to the layer acts on it.
    func setTucked(_ wid: UInt32, _ tucked: Bool, layer layerId: String) {
        lock.lock(); defer { lock.unlock() }
        Self.applyTuck(wid, tucked, layer: layerId, to: &state)
        persistLocked()
    }

    /// Tuck and untuck several members of `layerId` in one write. The ledger
    /// in memory changes only once the write lands, so a failed one leaves
    /// both as they were.
    func setTucks(tuck: Set<UInt32>, untuck: Set<UInt32>, layer layerId: String) throws {
        lock.lock(); defer { lock.unlock() }
        state = try Self.committingTucks(tuck: tuck, untuck: untuck, layer: layerId, to: state, path: statePath)
    }

    /// `state` with the tucks applied, once it's written to `path`. Throws,
    /// and writes nothing, when the write fails.
    static func committingTucks(
        tuck: Set<UInt32>,
        untuck: Set<UInt32>,
        layer layerId: String,
        to state: State,
        path: String
    ) throws -> State {
        var next = state
        for wid in tuck.sorted() { applyTuck(wid, true, layer: layerId, to: &next) }
        for wid in untuck.sorted() { applyTuck(wid, false, layer: layerId, to: &next) }
        guard next != state else { return state }
        try write(next, to: path)
        return next
    }

    private static func applyTuck(_ wid: UInt32, _ tucked: Bool, layer layerId: String, to state: inout State) {
        var wids = state.tucked[layerId] ?? []
        let was = wids.contains(wid)
        wids.removeAll { $0 == wid }
        if tucked { wids.append(wid) }
        state.tucked[layerId] = wids.isEmpty ? nil : wids
        var freed = (state.untucked[layerId] ?? []).filter { $0 != wid }
        if was && !tucked { freed.append(wid) }
        state.untucked[layerId] = freed.isEmpty ? nil : freed
    }

    /// What `layerId` was let show again since it was last switched to.
    func untucked(_ layerId: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        return Set(state.untucked[layerId] ?? [])
    }

    /// Each parked window's home: where it was before it was parked (CG,
    /// top-left origin). Read only; Overview outlines parked windows there.
    func homes() -> [UInt32: CGRect] {
        lock.lock(); defer { lock.unlock() }
        var homes: [UInt32: CGRect] = [:]
        for window in state.parked {
            homes[window.wid] = CGRect(x: window.frame.x, y: window.frame.y, width: window.frame.w, height: window.frame.h)
        }
        return homes
    }

    /// The windows `layerId` had showing beyond its members, on any desktop:
    /// its scenes' extras, which nothing claims. Read only.
    func extras(of layerId: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(layerId)@"
        return Set(state.scenes.filter { $0.key.hasPrefix(prefix) }.values.joined())
    }

    /// Every layer's tucked members, by layer id. Read only.
    func tuckedByLayer() -> [String: Set<UInt32>] {
        lock.lock(); defer { lock.unlock() }
        return state.tucked.mapValues { Set($0) }
    }

    /// What the last stage hid or parked, until its look.
    func settling() -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        return settlingWids
    }

    /// The windows `layer` had showing beyond its members when it was last
    /// left, on the desktop the main screen is showing.
    func scene(for layer: Layer) -> [UInt32] {
        guard let stage = Stage.current() else { return [] }
        lock.lock(); defer { lock.unlock() }
        return state.scenes[stage.sceneKey(layer)] ?? []
    }

    // MARK: - Switch

    /// Stage a switch from `outgoing` to `incoming`, which may be the same
    /// layer: choosing it again reconciles the screen to it all the same.
    ///
    /// Remembers what `outgoing` had showing, then shows what `incoming`
    /// wants and puts away the rest. `members` maps each layer id to every
    /// window its entries match; a window another layer claims never joins
    /// this layer's scene. Runs one switch at a time: one that arrives
    /// mid-stage waits for it.
    @discardableResult
    func stage(
        outgoing: Layer?,
        incoming: Layer,
        members: [String: Set<UInt32>],
        windows: [WindowEntry]
    ) -> Outcome {
        var outcome = Outcome()
        guard let stage = Stage.current() else {
            DiagnosticLog.shared.info("LayerStage: the main screen isn't showing a desktop — leaving windows alone")
            return outcome
        }
        let live = Self.liveWindows()

        lock.lock()
        defer {
            persistLocked()
            lock.unlock()
        }
        pruneLocked(stage.bounds, live: live)

        // 1. What the outgoing layer had showing, beyond every layer's
        //    members, and what it keeps put away or was just let show.
        if let outgoing {
            state.scenes[stage.sceneKey(outgoing)] = Self.scene(
                of: windows, stage: stage, claimed: Set(members.values.joined()), settling: settlingWids,
                keeping: Set((state.tucked[outgoing.id] ?? []) + (state.untucked[outgoing.id] ?? []))
            )
        }

        // 2. What the incoming layer wants on this desktop. Wanting nothing
        //    here puts away only what it keeps tucked. What it was let show
        //    waits for a stage that shows it, unless another layer claims it.
        let tucked = Set(state.tucked[incoming.id] ?? [])
        let claimed = Self.union(members, except: incoming.id)
        let untucked = state.untucked[incoming.id] ?? []
        let want = Self.want(
            own: members[incoming.id] ?? [],
            scene: (state.scenes[stage.sceneKey(incoming)] ?? []) + untucked,
            claimed: claimed,
            tucked: tucked,
            windows: windows,
            stage: stage
        )
        state.untucked[incoming.id] = Self.stillUntucked(untucked, claimed: claimed, shown: [])
        let plan = Self.plan(
            want: want,
            windows: windows,
            parked: state.parked,
            stage: stage,
            apps: appsLocked(Set(windows.filter { stage.contains($0) }.map(\.pid))),
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            tucked: tucked
        )
        guard !want.isEmpty || plan != Plan() else {
            DiagnosticLog.shared.info("LayerStage: \(outgoing?.id ?? "-") → \(incoming.id): nothing wanted on this desktop — leaving windows alone")
            return outcome
        }

        generation += 1
        applyLocked(plan, want: want, windows: windows, stage: stage, into: &outcome)
        state.untucked[incoming.id] = Self.stillUntucked(untucked, claimed: claimed, shown: outcome.shown)
        outcome.stillParked = state.parked.count
        DiagnosticLog.shared.info("LayerStage: \(outgoing?.id ?? "-") → \(incoming.id): \(outcome.summary)")
        scheduleVerifyLocked(outcome.parked)
        return outcome
    }

    /// Run `plan` in its order: unhide and wait, park, restore, hide.
    private func applyLocked(
        _ plan: Plan,
        want: Set<UInt32>,
        windows: [WindowEntry],
        stage: Stage,
        into outcome: inout Outcome
    ) {
        // 3. Unhide the apps that own a wanted window, and let that land
        //    before parking their other windows.
        for pid in plan.unhide {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            app.unhide()
            outcome.unhiddenApps.append(app.localizedName ?? "pid \(pid)")
            state.hiddenPids.removeAll { $0 == pid }
            settlingPids.remove(pid)
        }
        outcome.unhidden = plan.unhidden
        Self.awaitUnhide(Set(plan.unhide))

        // 4. Park what isn't wanted. A window the ledger has keeps its home.
        if !plan.park.isEmpty {
            if stage.canPark {
                let entries = Dictionary(windows.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
                let targets = plan.park.compactMap { wid -> ParkedWindow? in
                    if let known = state.parked.first(where: { $0.wid == wid }) { return known }
                    return entries[wid].map {
                        ParkedWindow(wid: $0.wid, pid: $0.pid, app: $0.app, title: $0.title, frame: $0.frame)
                    }
                }
                (outcome.parked, outcome.stayed) = parkLocked(targets, at: stage.parkOrigin)
            } else {
                DiagnosticLog.shared.warn("LayerStage: a display sits past the main screen's bottom-right corner — not parking \(plan.park.count) windows")
            }
        }

        // 5. Bring back what the layer wants from the park corner.
        let restored = Self.restore(state.parked.filter { plan.restore.contains($0.wid) })
        state.parked.removeAll { restored.contains($0.wid) }
        outcome.unparked = restored
        outcome.missing = Set(plan.restore).subtracting(restored)
        outcome.shown = want.subtracting(outcome.missing)

        // 6. Hide the apps with nothing wanted. The frontmost goes last, so
        //    each hide hands focus to an app that's staying.
        for pid in plan.hide {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // hide() answers false even when the app goes on to hide, so its
            // answer can't be the cue to park the windows instead.
            EditorMutationJournal.hiding(app)
            app.hide()
            outcome.hiddenApps.append(app.localizedName ?? "pid \(pid)")
            if !state.hiddenPids.contains(pid) { state.hiddenPids.append(pid) }
            settlingPids.insert(pid)
        }
        outcome.hidden = plan.hidden
        settlingWids.formUnion(outcome.parked)
        settlingWids.formUnion(plan.hidden)
    }

    /// One look, `verifyDelay` after a stage: a single deferred call, not a
    /// watch.
    private func scheduleVerifyLocked(_ parked: Set<UInt32>) {
        let generation = self.generation
        let journal = EditorMutationJournal.current
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay) {
            if let journal {
                guard !journal.sealed else { return }
                journal.run { self.verify(generation, parked: parked) }
            } else { self.verify(generation, parked: parked) }
        }
    }

    /// Park again, once, what came back on screen after `generation`'s stage
    /// parked it, and log what stayed. If a later stage or Show All has run,
    /// the screen is theirs and this does nothing.
    private func verify(_ generation: Int, parked wids: Set<UInt32>) {
        let live = wids.isEmpty ? nil : Self.liveWindows()
        let main = Stage.mainBounds
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return }
        settlingPids.removeAll()
        settlingWids.removeAll()
        guard let live else { return }
        let pulled = state.parked.filter { wids.contains($0.wid) && Self.isPulledBack($0, live: live, main: main) }
        guard !pulled.isEmpty, Stage.canPark(main, others: Stage.otherDisplayBounds()) else { return }
        let again = parkLocked(pulled, at: Stage.parkOrigin(of: main))
        let stayed = pulled.filter { again.stayed.contains($0.wid) }.map(\.app)
        DiagnosticLog.shared.info("LayerStage: \(pulled.count) windows came back on screen — parked \(again.parked.count) again, stayed [\(stayed.joined(separator: ", "))]")
    }

    /// Reconcile only the restored window; never clear unrelated/user state.
    func editorRestored(window: UInt32, parkedBefore: ParkedWindow?) {
        lock.lock()
        defer { lock.unlock() }
        state.parked.removeAll { $0.wid == window }
        if let parkedBefore { state.parked.append(parkedBefore) }
        settlingWids.remove(window)
        persistLocked()
    }

    func editorUnhid(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        state.hiddenPids.removeAll { $0 == pid }
        settlingPids.remove(pid)
        persistLocked()
    }

    // MARK: - Show All

    /// Unpark every parked window, unhide every app a switch hid, and forget
    /// the layers' scenes. The escape hatch: it also brings back windows
    /// sitting in the park corner that the ledger lost, such as one an app
    /// reopened where it last saw it. Tucked sets are kept.
    @discardableResult
    func showAll() -> Outcome {
        let live = Self.liveWindows()
        lock.lock()
        defer {
            persistLocked()
            lock.unlock()
        }
        generation += 1
        var outcome = Outcome()
        pruneLocked(Stage.mainBounds, live: live)
        // Hidden apps may expose no AX windows. Unhide first, then restore;
        // keep failed unhides in the ledger so Exit Layers can retry them.
        var stillHiddenPids: [Int32] = []
        for pid in state.hiddenPids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.isHidden || settlingPids.contains(pid) else { continue }
            let name = app.localizedName ?? "pid \(pid)"
            if app.unhide() {
                outcome.unhiddenApps.append(name)
            } else {
                stillHiddenPids.append(pid)
                outcome.stillHiddenApps.append(name)
            }
        }
        state.hiddenPids = stillHiddenPids
        let restored = Self.restore(state.parked)
        outcome.unparked = restored
        state.parked.removeAll { restored.contains($0.wid) }
        outcome.stillParked = state.parked.count
        let strays = Self.rescueStrays(tracked: Set(state.parked.map(\.wid)))
        outcome.rescued = strays.rescued
        outcome.stillParked += strays.found - strays.rescued
        state.scenes.removeAll()
        settlingPids.removeAll()
        settlingWids.removeAll()
        DiagnosticLog.shared.info("LayerStage: show all — \(outcome.summary)")
        return outcome
    }

    /// Put parked windows back where they were. Runs on quit (the SIGTERM
    /// path included) and at launch, after a crash. Hidden apps stay hidden:
    /// that's an ordinary macOS state, and ⌘-Tab brings them back.
    @discardableResult
    func restoreParked(reason: String) -> Int {
        guard AXIsProcessTrusted() else { return 0 }
        let live = Self.liveWindows()
        lock.lock()
        defer { lock.unlock() }
        guard !state.parked.isEmpty else { return 0 }
        pruneLocked(Stage.mainBounds, live: live)
        let restored = Self.restore(state.parked)
        state.parked.removeAll { restored.contains($0.wid) }
        persistLocked()
        DiagnosticLog.shared.info("LayerStage: restored \(restored.count) parked windows (\(reason)); \(state.parked.count) out of reach")
        return restored.count
    }

    // MARK: - Plan

    /// A window as the WindowServer lists it now, on screen or not.
    struct LiveWindow: Equatable {
        let pid: Int32
        let frame: CGRect
        var layer = 0
    }

    /// A switch's moves, in the order they run.
    struct Plan: Equatable {
        /// Apps that own a wanted window and are hidden.
        var unhide: [Int32] = []
        /// Unwanted windows to park. Those of an app coming back are parked
        /// even if the ledger has them: unhiding pulls them on screen.
        var park: [UInt32] = []
        /// Wanted windows the ledger has parked.
        var restore: [UInt32] = []
        /// Apps with nothing wanted and nothing elsewhere, the frontmost last.
        var hide: [Int32] = []
        /// The showing windows `hide` puts away.
        var hidden: Set<UInt32> = []
        /// The wanted windows `unhide` brings back.
        var unhidden: Set<UInt32> = []
    }

    /// Plan the switch to `want`. What's showing is read from where each
    /// window is, not from the ledger. `apps` has the apps a stage may
    /// touch; windows of any other are left alone. An empty `want` puts away
    /// only the `tucked` windows showing, and hides an app only when nothing
    /// else of it is showing.
    static func plan(
        want: Set<UInt32>,
        windows: [WindowEntry],
        parked: [ParkedWindow],
        stage: Stage,
        apps: [Int32: DesktopModel.AppFacts],
        frontmost: Int32?,
        tucked: Set<UInt32> = []
    ) -> Plan {
        var plan = Plan()
        let only: Set<UInt32>? = want.isEmpty ? tucked : nil
        guard only?.isEmpty != true else { return plan }
        let onStage = windows.filter { isStageable($0) && stage.contains($0) && apps[$0.pid] != nil }
        let ledger = Set(parked.map(\.wid))
        let wanted = onStage.filter { want.contains($0.wid) }
        let wantPids = Set(wanted.map(\.pid))
        // Apps that keep a window: a wanted one, or one an empty `want`
        // leaves showing.
        var keeps = wantPids

        for entry in wanted where apps[entry.pid]?.isHidden == true {
            if !plan.unhide.contains(entry.pid) { plan.unhide.append(entry.pid) }
            plan.unhidden.insert(entry.wid)
        }
        plan.restore = wanted.filter { ledger.contains($0.wid) }.map(\.wid)

        let unhiding = Set(plan.unhide)
        var away: [Int32: [UInt32]] = [:]
        var order: [Int32] = []
        for entry in onStage where !want.contains(entry.wid) {
            if unhiding.contains(entry.pid) {
                // Coming back pulls it on screen. One in the corner that the
                // ledger doesn't have has no home to keep, so it stays.
                if ledger.contains(entry.wid) || !Stage.inParkCorner(rect(entry.frame), of: stage.bounds) {
                    plan.park.append(entry.wid)
                }
                continue
            }
            guard isShowing(entry, on: stage) else { continue }
            if let only, !only.contains(entry.wid) {
                keeps.insert(entry.pid)
                continue
            }
            if away[entry.pid] == nil { order.append(entry.pid) }
            away[entry.pid, default: []].append(entry.wid)
        }

        var hide: [Int32] = []
        for pid in order {
            let strays = away[pid] ?? []
            let elsewhere = windows.contains { $0.pid == pid && isStageable($0) && stage.isElsewhere($0) }
            if !keeps.contains(pid), apps[pid]?.isRegular == true, !elsewhere {
                hide.append(pid)
                plan.hidden.formUnion(strays)
            } else {
                plan.park.append(contentsOf: strays)
            }
        }
        plan.hide = hide.filter { $0 != frontmost } + hide.filter { $0 == frontmost }
        return plan
    }

    /// What `incoming` shows on this desktop: its members and its scene,
    /// less what another layer claims and what it keeps tucked.
    static func want(
        own: Set<UInt32>,
        scene: [UInt32],
        claimed: Set<UInt32>,
        tucked: Set<UInt32>,
        windows: [WindowEntry],
        stage: Stage
    ) -> Set<UInt32> {
        let wids = own.union(scene.filter { !claimed.contains($0) }).subtracting(tucked)
        return Set(windows.filter { wids.contains($0.wid) && isStageable($0) && stage.contains($0) }.map(\.wid))
    }

    /// What a layer has showing beyond the layers' members: every showing
    /// window on stage that no layer claims. What the last stage put away
    /// doesn't count; its hide may not have landed. A window in `keeping`
    /// counts wherever it is on stage, showing or not.
    static func scene(
        of windows: [WindowEntry],
        stage: Stage,
        claimed: Set<UInt32>,
        settling: Set<UInt32>,
        keeping: Set<UInt32> = []
    ) -> [UInt32] {
        windows.filter {
            guard !claimed.contains($0.wid) else { return false }
            if keeping.contains($0.wid) { return isStageable($0) && stage.contains($0) }
            return isShowing($0, on: stage) && !settling.contains($0.wid)
        }.map(\.wid)
    }

    /// On stage, on screen and out of the park corner.
    static func isShowing(_ entry: WindowEntry, on stage: Stage) -> Bool {
        isStageable(entry) && stage.contains(entry) && entry.isOnScreen
            && !Stage.inParkCorner(rect(entry.frame), of: stage.bounds)
    }

    /// The ledger less the windows that closed or were dragged back. A
    /// collapsed window, or one whose app is `hidden`, is still parked.
    static func stillParked(
        _ parked: [ParkedWindow],
        live: [UInt32: LiveWindow],
        main: CGRect,
        hidden: Set<Int32>
    ) -> [ParkedWindow] {
        parked.filter { window in
            guard let now = live[window.wid], now.pid == window.pid else { return false }
            return hidden.contains(window.pid) || !isPulledBack(window, live: live, main: main)
        }
    }

    /// Out of the park corner and in view again, moved by hand or pulled
    /// back by its app. A collapsed window (its app hid) isn't.
    static func isPulledBack(_ window: ParkedWindow, live: [UInt32: LiveWindow], main: CGRect) -> Bool {
        guard let now = live[window.wid], now.pid == window.pid, !isCollapsed(now.frame) else { return false }
        return !Stage.isParked(now.frame, spot: window.spot, in: main)
    }

    /// CG's frame for a hidden app's window on macOS 27: next to nothing.
    static func isCollapsed(_ frame: CGRect) -> Bool {
        frame.width < DesktopModel.minWindowSide || frame.height < DesktopModel.minWindowSide
    }

    /// `pids` that are `hidden` now, or were hidden by a stage a moment ago
    /// and may not have landed. Each once, in order.
    static func stillHidden(_ pids: [Int32], hidden: Set<Int32>, settling: Set<Int32>) -> [Int32] {
        var seen = Set<Int32>()
        return pids.filter { (hidden.contains($0) || settling.contains($0)) && seen.insert($0).inserted }
    }

    /// The windows a layer was let show that a stage has yet to: less the
    /// ones it `shown`, and the ones another layer `claimed`. Nil for none.
    static func stillUntucked(_ untucked: [UInt32], claimed: Set<UInt32>, shown: Set<UInt32>) -> [UInt32]? {
        let left = untucked.filter { !claimed.contains($0) && !shown.contains($0) }
        return left.isEmpty ? nil : left
    }

    /// `lists` without the windows that closed, and without the lists that
    /// leaves empty.
    static func pruneDead(_ lists: [String: [UInt32]], alive: Set<UInt32>) -> [String: [UInt32]] {
        lists.compactMapValues { wids -> [UInt32]? in
            let living = wids.filter { alive.contains($0) }
            return living.isEmpty ? nil : living
        }
    }

    /// Windows in the park corner that the ledger doesn't have: one an app
    /// reopened where it last saw it, or one a lost ledger forgot.
    static func strays(
        in live: [UInt32: LiveWindow],
        tracked: Set<UInt32>,
        main: CGRect,
        stageable: (Int32) -> Bool
    ) -> [UInt32] {
        var strays: [UInt32] = []
        for (wid, window) in live where window.layer == 0 && !tracked.contains(wid) {
            guard window.pid != getpid(),
                  window.frame.width >= minSide, window.frame.height >= minSide,
                  Stage.inParkCorner(window.frame, of: main),
                  stageable(window.pid) else { continue }
            strays.append(wid)
        }
        return strays.sorted()
    }

    // MARK: - Stage geometry

    /// The main screen, the desktop it's showing, and the other displays.
    struct Stage {
        /// CG bounds (top-left origin).
        let bounds: CGRect
        let others: [CGRect]
        let spaceId: Int
        /// The desktop showing on every display.
        let currentSpaceIds: Set<Int>

        static var mainBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

        static func current() -> Stage? {
            let main = CGMainDisplayID()
            let all = WindowTiler.getDisplaySpaces()
            guard let display = WindowTiler.displaySpaces(forDisplayID: main, in: all),
                  display.spaces.contains(where: { $0.id == display.currentSpaceId }) else {
                return nil
            }
            return Stage(
                bounds: CGDisplayBounds(main),
                others: otherDisplayBounds(),
                spaceId: display.currentSpaceId,
                currentSpaceIds: Set(all.map(\.currentSpaceId))
            )
        }

        var parkOrigin: CGPoint { Self.parkOrigin(of: bounds) }

        var canPark: Bool { Self.canPark(bounds, others: others) }

        /// Bottom-right corner, one point in. macOS clamps the rest and
        /// leaves a sliver showing.
        static func parkOrigin(of bounds: CGRect) -> CGPoint {
            CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1)
        }

        /// Parked windows hang off the corner; with another display there
        /// they'd land on it instead. One beside the main screen is no bother.
        static func canPark(_ bounds: CGRect, others: [CGRect]) -> Bool {
            let beyond = CGRect(x: bounds.maxX - 1, y: bounds.maxY - LayerStage.parkedSlack, width: 20_000, height: 20_000)
            return !others.contains { $0.intersects(beyond) }
        }

        /// Where a park leaves a window: its top-left within `parkedSlack` of
        /// the right edge and `parkedDrop` of the bottom. That point sits on
        /// the main screen, so a display beside it can't blur the test.
        static func inParkCorner(_ frame: CGRect, of bounds: CGRect) -> Bool {
            frame.minX >= bounds.maxX - LayerStage.parkedSlack && frame.minX < bounds.maxX
                && frame.minY >= bounds.maxY - LayerStage.parkedDrop && frame.minY < bounds.maxY
        }

        /// Where a park left it: by the spot it landed on, or in the corner.
        static func isParked(_ frame: CGRect, spot: CGPoint?, in bounds: CGRect) -> Bool {
            if let spot, abs(frame.minX - spot.x) <= LayerStage.parkedSlack,
               abs(frame.minY - spot.y) <= LayerStage.parkedSlack {
                return true
            }
            return inParkCorner(frame, of: bounds)
        }

        func sceneKey(_ layer: Layer) -> String { "\(layer.id)@\(spaceId)" }

        /// On the main screen's desktop: centred on the main screen, or
        /// hanging off its bottom-right corner.
        func contains(_ entry: WindowEntry) -> Bool {
            guard entry.spaceIds.contains(spaceId) else { return false }
            let rect = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            if bounds.contains(centre) { return true }
            if others.contains(where: { $0.contains(centre) }) { return false }
            return rect.minX >= bounds.maxX - LayerStage.parkedSlack || bounds.intersects(rect)
        }

        /// Showing on another display, or sitting on another desktop.
        func isElsewhere(_ entry: WindowEntry) -> Bool {
            if entry.isOnScreen { return !contains(entry) }
            return !entry.spaceIds.isEmpty && currentSpaceIds.isDisjoint(with: entry.spaceIds)
        }

        static func otherDisplayBounds() -> [CGRect] {
            let main = CGMainDisplayID()
            return activeDisplays().filter { $0 != main }.map { CGDisplayBounds($0) }
        }

        private static func activeDisplays() -> [CGDirectDisplayID] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
            return Array(ids.prefix(Int(count)))
        }
    }

    // MARK: - Helpers

    private static func isStageable(_ entry: WindowEntry) -> Bool {
        DesktopModel.isContent(entry)
    }

    private static func rect(_ frame: WindowFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
    }

    /// Regular apps are hidden or parked, accessory apps only parked.
    /// Background agents and Lattices' own apps are left alone.
    private static func stageableApp(_ pid: Int32) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy != .prohibited,
              !LatticesRuntime.isLatticesBundleIdentifier(app.bundleIdentifier) else { return nil }
        return app
    }

    /// What `plan` reads from the apps a stage may touch. A hide asked for
    /// a moment ago counts as hidden, landed or not.
    private func appsLocked(_ pids: Set<Int32>) -> [Int32: DesktopModel.AppFacts] {
        var apps: [Int32: DesktopModel.AppFacts] = [:]
        for pid in pids {
            guard let app = Self.stageableApp(pid) else { continue }
            apps[pid] = DesktopModel.AppFacts(
                bundleId: app.bundleIdentifier,
                isHidden: app.isHidden || settlingPids.contains(pid),
                isRegular: app.activationPolicy == .regular
            )
        }
        return apps
    }

    /// The apps of the ledger and `hiddenPids` that are hidden right now.
    private func hiddenAppsLocked() -> Set<Int32> {
        let pids = Set(state.parked.map(\.pid)).union(state.hiddenPids)
        return pids.filter { NSRunningApplication(processIdentifier: $0)?.isHidden == true }
    }

    private static func union(_ members: [String: Set<UInt32>], except id: String) -> Set<UInt32> {
        members.reduce(into: Set<UInt32>()) { result, pair in
            if pair.key != id { result.formUnion(pair.value) }
        }
    }

    /// Forget what's gone: parked windows that closed or were dragged back
    /// by hand, apps no longer hidden, and closed windows in scenes and
    /// tucked sets. A collapsed window, or a hidden app's, is still parked.
    private func pruneLocked(_ main: CGRect, live: [UInt32: LiveWindow]?) {
        let hidden = hiddenAppsLocked()
        state.hiddenPids = Self.stillHidden(state.hiddenPids, hidden: hidden, settling: settlingPids)
        guard let live else { return }
        state.parked = Self.stillParked(state.parked, live: live, main: main, hidden: hidden.union(settlingPids))
        let alive = Set(live.keys)
        state.scenes = Self.pruneDead(state.scenes, alive: alive)
        state.tucked = Self.pruneDead(state.tucked, alive: alive)
        state.untucked = Self.pruneDead(state.untucked, alive: alive)
    }

    /// Park windows at `origin`, keeping their size, and note where each
    /// landed. The ledger is written before anything moves, so a crash
    /// mid-switch can't lose a window; one the ledger has already keeps its
    /// home, and stays listed if AX can't reach it. Returns the windows that
    /// parked, and the ones their app kept on screen; those go straight back
    /// home and leave the ledger.
    private func parkLocked(_ windows: [ParkedWindow], at origin: CGPoint) -> (parked: Set<UInt32>, stayed: Set<UInt32>) {
        guard !windows.isEmpty else { return ([], []) }
        let known = Set(state.parked.map(\.wid))
        let fresh = windows.filter { !known.contains($0.wid) }
        state.parked.append(contentsOf: fresh)
        persistLocked()

        let homes = Dictionary(state.parked.map { ($0.wid, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var spots: [UInt32: CGPoint] = [:]
        var stayed = Set<UInt32>()
        Self.withAXWindows(for: windows.map { (wid: $0.wid, pid: $0.pid) }) { wid, axWindow in
            guard !Self.isMinimized(axWindow) else { return }
            let capture = EditorMutationJournal.begin(wid: wid, ax: axWindow, parked: true)
            if EditorMutationJournal.current != nil && capture == nil { return }
            defer { EditorMutationJournal.end(capture) }
            var point = origin
            guard let value = AXValueCreate(.cgPoint, &point),
                  AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) == .success else { return }
            // A Cocoa window constrains the move to the screen; it lands in
            // the corner in full view. Put it back rather than lose it there.
            guard let landed = Self.position(of: axWindow), landed.x >= origin.x + 1 - Self.parkedSlack else {
                if let home = homes[wid] {
                    var back = CGPoint(x: home.x, y: home.y)
                    if let value = AXValueCreate(.cgPoint, &back) {
                        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
                    }
                }
                stayed.insert(wid)
                return
            }
            spots[wid] = landed
        }
        let freshWids = Set(fresh.map(\.wid))
        state.parked.removeAll { stayed.contains($0.wid) || (freshWids.contains($0.wid) && spots[$0.wid] == nil) }
        for index in state.parked.indices {
            if let spot = spots[state.parked[index].wid] { state.parked[index].spot = spot }
        }
        if !stayed.isEmpty {
            DiagnosticLog.shared.info("LayerStage: \(stayed.count) windows stayed on screen when parked — left where they were")
        }
        return (Set(spots.keys), stayed)
    }

    /// Wait until each of `pids` has a window on screen again, up to
    /// `unhideWait`. Reads the WindowServer rather than `isHidden` or
    /// `didUnhideApplicationNotification`: both arrive on the main run loop,
    /// which a stage holds, and turning it here would let a second switch in.
    private static func awaitUnhide(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        let deadline = Date().addingTimeInterval(unhideWait)
        repeat {
            if pids.isSubset(of: onScreenPids()) { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        DiagnosticLog.shared.info("LayerStage: \(pids.count) apps took over \(Int(unhideWait * 1000)) ms to unhide — parking anyway")
    }

    /// The apps with a window on screen, on any display. A hidden app's
    /// windows collapse to a point, so those don't count.
    private static func onScreenPids() -> Set<Int32> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { window -> Int32? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), !isCollapsed(rect) else { return nil }
            return window[kCGWindowOwnerPID as String] as? Int32
        })
    }

    /// Bring back windows sitting in the main screen's park corner that
    /// aren't in the ledger. Centres each on the main screen, keeping its
    /// size. Only reaches desktops that are showing; the rest count as found
    /// but not rescued.
    private static func rescueStrays(tracked: Set<UInt32>) -> (found: Int, rescued: Int) {
        let bounds = Stage.mainBounds
        guard Stage.canPark(bounds, others: Stage.otherDisplayBounds()) else {
            DiagnosticLog.shared.info("LayerStage: a display sits past the main screen's bottom-right corner — not rescuing corner windows")
            return (0, 0)
        }
        guard let live = liveWindows() else { return (0, 0) }
        let found = strays(in: live, tracked: tracked, main: bounds) { stageableApp($0) != nil }
        guard !found.isEmpty else { return (0, 0) }
        let targets = found.compactMap { wid -> (wid: UInt32, pid: Int32)? in
            guard let window = live[wid] else { return nil }
            return (wid: wid, pid: window.pid)
        }
        var rescued = 0
        withAXWindows(for: targets) { wid, axWindow in
            guard let size = live[wid]?.frame.size else { return }
            let capture = EditorMutationJournal.begin(wid: wid, ax: axWindow, parked: true)
            if EditorMutationJournal.current != nil && capture == nil { return }
            defer { EditorMutationJournal.end(capture) }
            var point = CGPoint(
                x: bounds.midX - min(size.width, bounds.width) / 2,
                y: max(bounds.minY, bounds.midY - min(size.height, bounds.height) / 2)
            )
            guard let value = AXValueCreate(.cgPoint, &point),
                  AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) == .success else { return }
            rescued += 1
        }
        return (found.count, rescued)
    }

    /// Move parked windows back to their saved frames. Returns the ones AX
    /// reached; a window on a desktop that isn't showing stays parked.
    private static func restore(_ parked: [ParkedWindow]) -> Set<UInt32> {
        guard !parked.isEmpty else { return [] }
        let byWid = Dictionary(parked.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
        var restored = Set<UInt32>()
        withAXWindows(for: parked.map { ($0.wid, $0.pid) }) { wid, axWindow in
            guard let saved = byWid[wid] else { return }
            let capture = EditorMutationJournal.begin(wid: wid, ax: axWindow, parked: true)
            if EditorMutationJournal.current != nil && capture == nil { return }
            defer { EditorMutationJournal.end(capture) }
            var point = CGPoint(x: saved.frame.x, y: saved.frame.y)
            var size = CGSize(width: saved.frame.w, height: saved.frame.h)
            guard let position = AXValueCreate(.cgPoint, &point),
                  AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, position) == .success else { return }
            // Size after position: in the corner, macOS may have squeezed it.
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
            }
            restored.insert(wid)
        }
        return restored
    }

    /// Resolve AX windows by CGWindowID, one AX query per app. AX lists only
    /// the windows on desktops that are showing.
    private static func withAXWindows(
        for targets: [(wid: UInt32, pid: Int32)],
        _ body: (UInt32, AXUIElement) -> Void
    ) {
        for (pid, wanted) in Dictionary(grouping: targets, by: { $0.pid }) {
            let appRef = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appRef, 0.5)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }

            // Enhanced UI makes Chrome and friends animate AX moves; switch
            // it off while moving, and put it back after.
            var enhancedRef: CFTypeRef?
            let enhanced = AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &enhancedRef) == .success
                && (enhancedRef as? Bool) == true
            if enhanced {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            defer {
                if enhanced {
                    AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
            }

            let wids = Set(wanted.map(\.wid))
            for axWindow in axWindows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &wid) == .success, wids.contains(wid) else { continue }
                body(wid, axWindow)
            }
        }
    }

    private static func position(of axWindow: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func isMinimized(_ axWindow: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &ref) == .success
            && (ref as? Bool) == true
    }

    /// Every window's owner, CG frame and layer, by id, on screen or not: a
    /// hidden app's windows and those on other desktops included. A lookup
    /// of one window by id finds only on-screen ones. Nil if the list can't
    /// be read.
    private static func liveWindows() -> [UInt32: LiveWindow]? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var windows: [UInt32: LiveWindow] = [:]
        for window in info {
            guard let wid = window[kCGWindowNumber as String] as? UInt32,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { continue }
            windows[wid] = LiveWindow(pid: pid, frame: rect, layer: window[kCGWindowLayer as String] as? Int ?? 0)
        }
        return windows
    }

    // MARK: - Persistence

    private static func load(from path: String) -> State? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func persistLocked() {
        try? Self.write(state, to: statePath)
    }

    /// Writes the ledger atomically, making its folder if need be.
    static func write(_ state: State, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
