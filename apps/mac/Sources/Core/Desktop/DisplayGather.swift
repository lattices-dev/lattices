import AppKit

/// Lending a screen: gather the windows on one display onto another, laid
/// out as they were in miniature, and restore them when it's yours again.
///
/// When a display goes away (unplugged, or a monitor whose input switched
/// to another machine and told the Mac), every remaining screen asks
/// whether to gather its windows there (`DisplayPrompt`); the screen you
/// click on is where they go. When it comes back, it asks to put them back.
/// A monitor that switches input without telling the Mac does nothing, so
/// `lats display lend <n>` asks the same question on command.
///
/// What a gather moved, and from where, is kept in
/// `~/.lattices/display-gather.json` until it's restored.
final class DisplayGather {
    static let shared = DisplayGather()

    /// A display as the API numbers it (`spaces.list` displayIndex), with
    /// its frames in top-left global coordinates.
    struct Screen: Equatable {
        let index: Int
        let id: String
        let name: String
        let frame: CGRect
        let visible: CGRect
        let isMain: Bool
    }

    /// A window as it sat on the display it was gathered from: its frame as
    /// a share of that display's visible frame.
    struct Kept: Codable, Equatable {
        let wid: UInt32
        let pid: Int32
        let app: String
        let title: String
        let unit: CGRect
    }

    /// What a gather took off a display, back to front.
    struct Stash: Codable, Equatable {
        let displayId: String
        let displayName: String
        var windows: [Kept]
        let gatheredTo: String
        let at: Date
    }

    /// Stashes by display id.
    private(set) var stashes: [String: Stash] = [:]
    /// The windows each display showed just before the last
    /// reconfiguration, by display id, back to front.
    private var lastSeen: [String: (screen: Screen, windows: [Kept])] = [:]
    private var lastSeenAt: CFTimeInterval = 0
    private var known: Set<String> = []
    private var asleep = false
    private var wokeAt: CFTimeInterval = 0
    private var started = false

    /// How long a display has to stay gone, or back, before it asks, so a
    /// flicker or a mode change doesn't.
    private static let settle: TimeInterval = 2.5
    /// Displays come and go around sleep; nothing asks this soon after.
    private static let quietAfterWake: TimeInterval = 15

    private static var storePath: String {
        NSHomeDirectory() + "/.lattices/display-gather.json"
    }

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        load()
        known = Set(Self.screens().map(\.id))
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            let begin = flags.contains(.beginConfigurationFlag)
            DispatchQueue.main.async { DisplayGather.shared.reconfigured(begin: begin) }
        }, nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.wokeAt = CACurrentMediaTime()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconfigured(begin: false) }
    }

    // MARK: Screens

    /// The displays now, as the API numbers them. Main thread.
    static func screens() -> [Screen] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let main = NSScreen.screens.first
        return WindowTiler.getDisplaySpaces().compactMap { display in
            guard let screen = DisplayGeometryMapper.screen(for: display, in: NSScreen.screens) else { return nil }
            return Screen(
                index: display.displayIndex,
                id: display.displayId,
                name: screen.localizedName,
                frame: DisplayGeometryMapper.topLeftFrame(screen.frame, primaryHeight: primaryHeight),
                visible: DisplayGeometryMapper.topLeftFrame(screen.visibleFrame, primaryHeight: primaryHeight),
                isMain: screen == main
            )
        }
    }

    /// A display by its index or a piece of its name.
    static func screen(named query: String, among all: [Screen]? = nil) -> Screen? {
        let all = all ?? screens()
        if let index = Int(query) { return all.first { $0.index == index } }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return all.first { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The display holding the most of `frame`.
    static func owner(of frame: CGRect, among screens: [Screen]) -> Screen? {
        var best: (screen: Screen, area: CGFloat)?
        for screen in screens {
            let overlap = screen.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    /// `unit`, a share of one display, on the visible frame `to`: the same
    /// place and proportions, kept inside it.
    static func carry(_ unit: CGRect, to visible: CGRect) -> CGRect {
        let w = min(max(unit.width, 0.05), 1)
        let h = min(max(unit.height, 0.05), 1)
        let x = min(max(unit.minX, 0), 1 - w)
        let y = min(max(unit.minY, 0), 1 - h)
        return CGRect(
            x: visible.minX + x * visible.width, y: visible.minY + y * visible.height,
            width: w * visible.width, height: h * visible.height
        ).integral
    }

    /// `frame` as a share of `visible`.
    static func unit(of frame: CGRect, in visible: CGRect) -> CGRect {
        guard let f = DisplayGeometryMapper.normalizedFractions(of: frame, in: visible) else { return .zero }
        return CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
    }

    /// The content windows showing on `screen`, back to front.
    static func windows(on screen: Screen, among screens: [Screen], from inventory: [WindowEntry]) -> [Kept] {
        var seen = Set<UInt32>()
        return inventory
            .filter { $0.isOnScreen && !$0.appHidden && DesktopModel.isContent($0) }
            .sorted { $0.zIndex > $1.zIndex }
            .filter { seen.insert($0.wid).inserted }
            .compactMap { entry in
                let frame = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
                guard owner(of: frame, among: screens)?.id == screen.id else { return nil }
                return Kept(wid: entry.wid, pid: entry.pid, app: entry.app, title: entry.title, unit: unit(of: frame, in: screen.visible))
            }
    }

    // MARK: Gather and restore

    /// Moves what display `from` shows onto display `to`, as it sat there.
    /// Works for a display that's still here (live windows) or one that just
    /// left (what it showed before it went). Returns how many moved.
    @discardableResult
    func gather(from id: String, to target: Screen) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        let screens = Self.screens()
        let inventory = DesktopModel.shared.refreshNow()
        let windows: [Kept]
        let name: String
        if let source = screens.first(where: { $0.id == id }) {
            guard source.id != target.id else { return 0 }
            windows = Self.windows(on: source, among: screens, from: inventory)
            name = source.name
        } else if let seen = lastSeen[id] {
            windows = seen.windows
            name = seen.screen.name
        } else {
            return 0
        }
        let live = Dictionary(inventory.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
        let moving = windows.filter { live[$0.wid] != nil }
        guard !moving.isEmpty else { return 0 }
        WindowTiler.batchMoveAndRaiseWindows(
            moving.map { (wid: $0.wid, pid: $0.pid, frame: Self.carry($0.unit, to: target.visible)) },
            activation: .frontmostOnly
        )
        // A second gather of the same display adds to the first.
        var stash = stashes[id] ?? Stash(displayId: id, displayName: name, windows: [], gatheredTo: target.id, at: Date())
        let already = Set(stash.windows.map(\.wid))
        stash.windows += moving.filter { !already.contains($0.wid) }
        stashes[id] = stash
        save()
        DiagnosticLog.shared.info("DisplayGather: gathered \(moving.count) window(s) from \(name) onto \(target.name)")
        return moving.count
    }

    /// Puts back what was gathered off display `id`, where it sat. Returns
    /// how many moved; nil when that display isn't here.
    @discardableResult
    func restore(_ id: String) -> Int? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let stash = stashes[id] else { return 0 }
        guard let screen = Self.screens().first(where: { $0.id == id }) else { return nil }
        let live = Set(DesktopModel.shared.refreshNow().map(\.wid))
        let moving = stash.windows.filter { live.contains($0.wid) }
        WindowTiler.batchMoveAndRaiseWindows(
            moving.map { (wid: $0.wid, pid: $0.pid, frame: Self.carry($0.unit, to: screen.visible)) },
            activation: .frontmostOnly
        )
        stashes[id] = nil
        save()
        DiagnosticLog.shared.info("DisplayGather: restored \(moving.count) window(s) to \(screen.name)")
        return moving.count
    }

    /// Forgets what was gathered off display `id`, leaving the windows be.
    func forget(_ id: String) {
        stashes[id] = nil
        save()
    }

    // MARK: Asking

    /// Asks on every other screen whether to gather display `id`'s windows
    /// there. With the display still here, it lends it: the same question
    /// as when it leaves.
    func ask(gathering id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let screens = Self.screens()
        let source = screens.first { $0.id == id } ?? lastSeen[id]?.screen
        guard let source else { return }
        let windows = screens.contains(where: { $0.id == id })
            ? Self.windows(on: source, among: screens, from: DesktopModel.shared.refreshNow())
            : lastSeen[id]?.windows ?? []
        let others = screens.filter { $0.id != id }
        guard !others.isEmpty, !windows.isEmpty else {
            DiagnosticLog.shared.info("DisplayGather: \(source.name) — nothing to gather")
            return
        }
        DisplayPrompt.shared.ask(
            on: others,
            title: screens.contains(where: { $0.id == id }) ? "Lend \(source.name)" : "\(source.name) left",
            detail: Self.summary(windows),
            go: "Gather here",
            stay: "Leave them"
        ) { [weak self] picked in
            guard let self, let picked else { return }
            self.gather(from: id, to: picked)
        }
    }

    /// Asks on display `id`, back again, whether to put its windows back.
    func ask(restoring id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let stash = stashes[id], let screen = Self.screens().first(where: { $0.id == id }) else { return }
        let live = Set(DesktopModel.shared.allWindows().map(\.wid))
        let windows = stash.windows.filter { live.contains($0.wid) }
        guard !windows.isEmpty else {
            forget(id)
            return
        }
        DisplayPrompt.shared.ask(
            on: [screen],
            title: "\(screen.name) is back",
            detail: Self.summary(windows),
            go: "Put them back",
            stay: "Leave them"
        ) { [weak self] picked in
            guard let self else { return }
            if picked != nil { self.restore(id) } else { self.forget(id) }
        }
    }

    /// "6 windows · Zed, Ghostty, Safari +2"
    static func summary(_ windows: [Kept]) -> String {
        var apps: [String] = []
        for window in windows.reversed() where !apps.contains(window.app) { apps.append(window.app) }
        let count = windows.count == 1 ? "1 window" : "\(windows.count) windows"
        let named = apps.prefix(3).joined(separator: ", ") + (apps.count > 3 ? " +\(apps.count - 3)" : "")
        return "\(count) · \(named)"
    }

    // MARK: Reconfiguration

    private func reconfigured(begin: Bool) {
        if begin {
            snapshot()
            return
        }
        let now = Set(Self.screens().map(\.id))
        let gone = known.subtracting(now)
        let back = now.subtracting(known)
        known = now
        guard !gone.isEmpty || !back.isEmpty else { return }
        DiagnosticLog.shared.info("DisplayGather: displays changed — gone \(gone.count), back \(back.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            guard let self, !self.asleep, CACurrentMediaTime() - self.wokeAt > Self.quietAfterWake else { return }
            let present = Set(Self.screens().map(\.id))
            for id in gone where !present.contains(id) { self.ask(gathering: id) }
            for id in back where present.contains(id) && self.stashes[id] != nil { self.ask(restoring: id) }
        }
    }

    /// What each display shows, before a reconfiguration moves anything.
    private func snapshot() {
        guard CACurrentMediaTime() - lastSeenAt > 1 else { return }
        lastSeenAt = CACurrentMediaTime()
        let screens = Self.screens()
        let inventory = DesktopModel.shared.allWindows()
        for screen in screens {
            lastSeen[screen.id] = (screen, Self.windows(on: screen, among: screens, from: inventory))
        }
    }

    // MARK: Store

    private func load() {
        guard let data = FileManager.default.contents(atPath: Self.storePath),
              let decoded = try? JSONDecoder().decode([String: Stash].self, from: data) else { return }
        stashes = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stashes) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
    }
}
