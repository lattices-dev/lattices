import AppKit
import ApplicationServices
import CoreGraphics

final class DesktopModel: ObservableObject {
    static let shared = DesktopModel()

    /// System helper processes that should never appear in search results or window lists.
    /// These are XPC services, agents, and background helpers — not user-facing apps.
    private static let systemHelperProcesses: Set<String> = [
        // Apple system helpers
        "CredentialsProviderExtensionHost",
        "AuthenticationServicesAgent",
        "SafariPasswordExtension",
        "com.apple.WebKit.WebAuthn",
        "SharedWebCredentialRunner",
        "ViewBridgeAuxiliary",
        "universalaccessd",
        "CoreServicesUIAgent",
        "UserNotificationCenter",
        "AutoFillPanelService",
        "AutoFill",
        "CoreLocationAgent",
        "SecurityAgent",
        "coreautha",
        "coreauth",
        "talagent",
        "CommCenter",
        "AXVisualSupportAgent",
        "SystemUIServer",
        "Dock",
        "Window Server",
        "WindowManager",
        "NotificationCenter",
        "ControlCenter",
        "Spotlight",
        "Keychain Access",
        "loginwindow",
        "ScreenSaverEngine",
        "SoftwareUpdateNotificationManager",
        "WiFiAgent",
        "pboard",
        "storeuid",
        // Third-party helpers
        "CursorUIViewService",
        "Codex Computer Use",
        "Electron Helper",
        "Google Chrome Helper",
    ]

    /// Suffixes that indicate a helper/service process, not a user-facing app
    private static let helperSuffixes = ["Service", "Agent", "Helper", "Extension", "Daemon", "XPCService"]

    /// Real apps that happen to match helper suffixes — don't filter these
    private static let knownRealApps: Set<String> = [
        "Finder",
        "Activity Monitor",
    ]

    @Published private(set) var windows: [UInt32: WindowEntry] = [:]
    @Published private(set) var interactionDates: [UInt32: Date] = [:]
    @Published private(set) var focusedWindowID: UInt32?
    private var timer: Timer?
    private var lastFocusedWindowID: UInt32?
    private let pollWorker = BackgroundPollWorker(label: "lattices.desktop-inventory")
    // Explicit synchronous refreshes still return fresh truth. Serialize them
    // with the timer's worker so an older scan cannot overwrite a newer one.
    private let inventoryLock = NSRecursiveLock()
    private var lastInventory: [WindowEntry] = []
    private var inventoryRevision = 0
    private var publishedRevision = 0 // main only

    func start(interval: TimeInterval = 1.5) {
        guard timer == nil else { return }
        DiagnosticLog.shared.info("DesktopModel: starting (interval=\(interval)s)")
        pollInBackground()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollInBackground()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func allWindows() -> [WindowEntry] {
        Array(windows.values).sorted { $0.zIndex < $1.zIndex }
    }

    /// The frontmost window a user would call "the current window".
    ///
    /// Raw z-order is not enough: apps keep untitled helper surfaces (Chrome's
    /// 64×64 status/drag windows, tooltip and panel shims) in the window list,
    /// and those routinely sort above the real window. They are also absent from
    /// the app's `AXWindows`, so tiling one resolves 0 moves and then reports
    /// "drifted" forever. Filter to windows that can actually be placed, and
    /// prefer the AX-focused window when it survives the same filter.
    func frontmostWindow() -> WindowEntry? {
        let placeable = windows.values.filter(Self.isPlaceableTarget)
        if let focused = focusedWindowID.flatMap({ windows[$0] }),
           Self.isPlaceableTarget(focused) {
            return focused
        }
        return placeable.min { $0.zIndex < $1.zIndex }
    }

    /// Minimum size for a window to count as a real, user-facing target.
    private static let minTargetSide: Double = 120

    static func isPlaceableTarget(_ entry: WindowEntry) -> Bool {
        guard entry.isOnScreen, !entry.title.isEmpty else { return false }
        guard entry.frame.w >= minTargetSide, entry.frame.h >= minTargetSide else { return false }
        return entry.pid != getpid()   // never target Lattices' own panels
    }

    /// A window a layer holds: another app's, not ruled out by AX, big
    /// enough to be content, with a title, or a Space and AX has listed it.
    /// Hidden apps' windows and windows on other desktops count.
    static func isContent(_ entry: WindowEntry) -> Bool {
        entry.pid != getpid() && entry.axVerified
            && entry.frame.w >= minTargetSide && entry.frame.h >= minTargetSide
            && (entry.hasTitle || (entry.axListed && !entry.spaceIds.isEmpty))
    }

    /// The Space showing on each display right now.
    static func currentSpaceIds() -> Set<Int> {
        Set(WindowTiler.getDisplaySpaces().map(\.currentSpaceId))
    }

    /// On a desktop that's showing. A hidden app's windows count: they keep
    /// their Space, only `isOnScreen` drops.
    static func isOnCurrentSpace(_ entry: WindowEntry, current: Set<Int>) -> Bool {
        entry.isOnScreen || !current.isDisjoint(with: entry.spaceIds)
    }

    func focusedWindow() -> WindowEntry? {
        focusedWindowID.flatMap { windows[$0] }
    }

    /// Frontmost window containing `point` (CG coords, top-left origin).
    /// Walks `allWindows()` front-to-back — zIndex 0 is topmost (CGWindowList order).
    func frontWindow(at point: CGPoint, on screen: NSScreen? = nil, excludingPid: Int32? = nil) -> WindowEntry? {
        for entry in allWindows() {
            if let excludingPid, entry.pid == excludingPid { continue }
            guard Self.isPlaceableTarget(entry) else { continue }
            if let screen, WindowTiler.screenForWindowFrame(entry.frame) != screen { continue }
            let r = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
            if r.contains(point) { return entry }
        }
        return nil
    }

    /// Fresh WindowServer hit-test for interactions that must target what is
    /// under the pointer now. Unlike `frontWindow(at:)`, this does not depend
    /// on the rate-limited desktop inventory or its asynchronous publication.
    func liveFrontWindow(at point: CGPoint, excludingPid: Int32? = nil) -> WindowEntry? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for (zIndex, info) in list.enumerated() {
            guard let entry = Self.liveWindowEntry(from: info, zIndex: zIndex) else { continue }
            if let excludingPid, entry.pid == excludingPid { continue }
            guard Self.isPlaceableTarget(entry) else { continue }
            let frame = CGRect(
                x: entry.frame.x,
                y: entry.frame.y,
                width: entry.frame.w,
                height: entry.frame.h
            )
            if frame.contains(point) { return entry }
        }
        return nil
    }

    func lastInteractionDate(for wid: UInt32) -> Date? {
        interactionDates[wid]
    }

    func markInteraction(wid: UInt32, at date: Date = Date()) {
        DispatchQueue.main.async {
            self.interactionDates[wid] = date
        }
    }

    func markInteraction(wids: [UInt32], at date: Date = Date()) {
        guard !wids.isEmpty else { return }
        let unique = Set(wids)
        DispatchQueue.main.async {
            for wid in unique {
                self.interactionDates[wid] = date
            }
        }
    }

    func windowForSession(_ session: String, currentSpaceOnly: Bool = false) -> WindowEntry? {
        guard currentSpaceOnly else {
            return SessionWindowLocator.cachedWindow(forSession: session, in: windows)
        }
        let current = Self.currentSpaceIds()
        return windows.values.first { entry in
            SessionWindowLocator.matches(session: session, title: entry.title, extractedSessionName: entry.latticesSession)
                && Self.isOnCurrentSpace(entry, current: current)
        }
    }

    /// Find a window by app name and optional title substring (case-insensitive),
    /// in the CG title or AX's whole one.
    /// `currentSpaceOnly` skips windows on desktops that aren't showing —
    /// raising or tiling one of those would switch Spaces.
    func windowForApp(app: String, title: String?, currentSpaceOnly: Bool = false) -> WindowEntry? {
        let current = currentSpaceOnly ? Self.currentSpaceIds() : []
        let matches = windows.values.filter {
            $0.app.localizedCaseInsensitiveContains(app)
                && (!currentSpaceOnly || Self.isOnCurrentSpace($0, current: current))
        }
        if let title {
            return bestAppWindow(matches.filter { $0.titleContains(title) })
        }
        return bestAppWindow(matches)
    }

    private func bestAppWindow(_ matches: [WindowEntry]) -> WindowEntry? {
        matches.sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen {
                return lhs.isOnScreen && !rhs.isOnScreen
            }
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex < rhs.zIndex
            }
            let lhsArea = lhs.frame.w * lhs.frame.h
            let rhsArea = rhs.frame.w * rhs.frame.h
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }
            return lhs.wid > rhs.wid
        }.first
    }

    private static func liveWindowEntry(from info: [String: Any], zIndex: Int) -> WindowEntry? {
        guard let wid = info[kCGWindowNumber as String] as? UInt32,
              let ownerName = info[kCGWindowOwnerName as String] as? String,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              (info[kCGWindowLayer as String] as? Int ?? 0) == 0
        else { return nil }

        if systemHelperProcesses.contains(ownerName) { return nil }
        let isHelperByName = helperSuffixes.contains(where: { ownerName.hasSuffix($0) })
            && !knownRealApps.contains(ownerName)
        if isHelperByName { return nil }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else { return nil }
        let title = info[kCGWindowName as String] as? String ?? ""
        if ownerName.hasPrefix("com.apple.") && title.isEmpty { return nil }

        var entry = WindowEntry(
            wid: wid,
            app: ownerName,
            pid: pid,
            title: title,
            frame: WindowFrame(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                w: Double(rect.width),
                h: Double(rect.height)
            ),
            spaceIds: [],
            isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true,
            latticesSession: SessionWindowLocator.extractSessionName(from: title)
        )
        entry.zIndex = zIndex
        return entry
    }

    // MARK: - Polling

    private var lastPollTime: Date = .distantPast
    private static let minPollInterval: TimeInterval = 1.0

    private func pollInBackground() {
        guard Date().timeIntervalSince(lastPollTime) >= Self.minPollInterval else { return }
        pollWorker.request { [weak self] in self?.performPoll() }
    }

    /// Poll only if stale. Call `forcePoll()` to bypass the freshness check.
    func poll() {
        let now = Date()
        guard now.timeIntervalSince(lastPollTime) >= Self.minPollInterval else { return }
        lastPollTime = now
        performPoll()
    }

    /// Force a poll regardless of freshness — use sparingly.
    func forcePoll() {
        lastPollTime = Date()
        performPoll()
    }

    /// Rebuild the inventory now and return the fresh entries.
    /// `allWindows()` only mirrors the last published snapshot, so callers
    /// that need post-poll truth use this instead.
    /// Safe off the main thread; shared state is only touched on main.
    @discardableResult
    func refreshNow() -> [WindowEntry] {
        performPoll()
    }

    /// Which windows live on which Space, straight from the WindowServer —
    /// ~10ms, no Accessibility pass and nothing published. Space membership
    /// doesn't change when the user switches Spaces, so this is safe to
    /// read before a switch lands. Safe off the main thread. Collapsed
    /// windows, a hidden app's, are left out: they aren't drawn.
    func spaceMembershipSnapshot() -> [WindowEntry] {
        guard let list = Self.cgWindowList() else { return [] }
        return Self.sweep(list, sources: .live, recoverCollapsed: false)
            .entries.values.sorted { $0.zIndex < $1.zIndex }
    }

    @discardableResult
    private func performPoll() -> [WindowEntry] {
        inventoryLock.lock()
        defer { inventoryLock.unlock() }
        // Never synchronously hop back to main while holding this lock: an
        // explicit main-thread refresh may itself be waiting for this scan.
        guard let list = Self.cgWindowList() else { return lastInventory }
        inventoryRevision &+= 1
        var sweep = Self.sweep(list, sources: .live, recoverCollapsed: true)

        // AX reconciliation: which windows on showing desktops AX lists
        var asked: Set<Int32> = []
        let axFrames = Self.reconcile(&sweep.entries, current: Self.currentSpaceIds()) { pid, candidates in
            asked.insert(pid)
            return self.axWindows(pid: pid, candidates: candidates)
        }

        cacheLock.lock()
        let lastFrames = self.lastFrames
        let fullTitles = self.fullTitles
        let axListed = self.axListed
        cacheLock.unlock()

        Self.resolveCollapsed(&sweep, axFrames: axFrames, lastFrames: lastFrames)
        Self.carryFullTitles(&sweep.entries, known: fullTitles)
        for wid in axListed where sweep.entries[wid] != nil {
            sweep.entries[wid]?.axListed = true
        }
        Self.dropProxies(&sweep.entries, facts: sweep.facts)
        remember(sweep.entries, asked: asked)
        lastInventory = finishPoll(sweep.entries, revision: inventoryRevision)
        return lastInventory
    }

    private static func cgWindowList() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    // MARK: - Inventory

    /// What the inventory reads from a window's app, once per app per sweep.
    struct AppFacts: Equatable {
        var bundleId: String? = nil
        var isHidden = false
        /// A regular app, one with a Dock icon.
        var isRegular = true
    }

    /// What CGWindowList leaves out. Tests pass fixtures.
    struct InventorySources {
        var appFacts: (Int32) -> AppFacts
        var spaces: (UInt32) -> [Int]
        var trueBounds: (UInt32) -> CGRect?

        static let live = InventorySources(
            appFacts: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return AppFacts() }
                return AppFacts(
                    bundleId: app.bundleIdentifier,
                    isHidden: app.isHidden,
                    isRegular: app.activationPolicy == .regular
                )
            },
            spaces: { WindowTiler.getSpacesForWindow($0) },
            trueBounds: { WindowTiler.trueBounds(of: $0) }
        )
    }

    /// The CG half of a poll.
    struct Sweep {
        var entries: [UInt32: WindowEntry] = [:]
        /// Collapsed windows the WindowServer gave no true frame for. They
        /// hold the collapsed frame until AX or a past poll gives one.
        var unresolved: Set<UInt32> = []
        var facts: [Int32: AppFacts] = [:]
    }

    /// One window as AX lists it.
    struct AXWindow: Equatable {
        var title: String
        var frame: CGRect?
    }

    /// Smallest side a window keeps. Below it sit menu extras and status items.
    static let minWindowSide: CGFloat = 50

    /// Every real window in `list`, CGWindowList rows front to back, with its
    /// Space IDs. A collapsed window that is titled, or whose app is hidden,
    /// keeps its true frame when `recoverCollapsed`, and is dropped otherwise.
    static func sweep(_ list: [[String: Any]], sources: InventorySources, recoverCollapsed: Bool) -> Sweep {
        var sweep = Sweep()
        var zCounter = 0

        for info in list {
            guard let wid = info[kCGWindowNumber as String] as? UInt32,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

            // Skip non-standard layers (menus, overlays)
            guard layer == 0 else { continue }

            // Skip system helper processes (autofill, credential providers, etc.)
            if systemHelperProcesses.contains(ownerName) { continue }

            // Skip processes whose name ends with common helper suffixes
            // (e.g. "CursorUIViewService", "AutoFillPanelService", "SecurityAgent")
            // but not known real apps that happen to have these words
            let isHelperByName = helperSuffixes.contains(where: { ownerName.hasSuffix($0) })
                && !knownRealApps.contains(ownerName)
            if isHelperByName { continue }

            // Skip windows with no title from processes containing "com.apple."
            if ownerName.hasPrefix("com.apple.") && title.isEmpty { continue }

            let facts: AppFacts
            if let known = sweep.facts[pid] {
                facts = known
            } else {
                facts = sources.appFacts(pid)
                sweep.facts[pid] = facts
            }

            // Skip tiny windows (menu extras, status items), but recover a
            // real window CG collapsed: a hidden app's report 1×1.
            var collapsed = false
            if !isWindowSized(rect) {
                guard recoverCollapsed, !title.isEmpty || facts.isHidden else { continue }
                collapsed = true
                if let bounds = sources.trueBounds(wid), isWindowSized(bounds) {
                    rect = bounds
                } else {
                    sweep.unresolved.insert(wid)
                }
            }

            var entry = WindowEntry(
                wid: wid,
                app: ownerName,
                pid: pid,
                title: title,
                frame: frame(rect),
                spaceIds: sources.spaces(wid),
                isOnScreen: isOnScreen,
                latticesSession: SessionWindowLocator.extractSessionName(from: title)
            )
            entry.zIndex = zCounter
            entry.bundleId = facts.bundleId
            entry.appHidden = facts.isHidden
            entry.collapsed = collapsed
            zCounter += 1
            sweep.entries[wid] = entry
        }
        return sweep
    }

    /// Checks the windows on showing desktops against AX by window number,
    /// with one `listing` per app: `candidates` maps its windows there to
    /// their CG titles, and it returns AX's windows by number, or nil when AX
    /// doesn't answer. A window AX lists is verified and listed, and takes
    /// AX's whole title; one it doesn't list isn't verified. AX can't see
    /// other desktops, so their windows keep `axVerified`, as do a hidden
    /// app's when AX lists nothing for it. Returns AX's frames by window
    /// number.
    static func reconcile(
        _ entries: inout [UInt32: WindowEntry],
        current: Set<Int>,
        me: Int32 = getpid(),
        listing: (_ pid: Int32, _ candidates: [UInt32: String]) -> [UInt32: AXWindow]?
    ) -> [UInt32: CGRect] {
        var byPid: [Int32: [UInt32: String]] = [:]
        for (wid, entry) in entries where entry.pid != me && isOnCurrentSpace(entry, current: current) {
            byPid[entry.pid, default: [:]][wid] = entry.title
        }

        var frames: [UInt32: CGRect] = [:]
        for (pid, candidates) in byPid {
            guard let listed = listing(pid, candidates) else { continue }
            let hidden = candidates.keys.contains { entries[$0]?.appHidden == true }
            for wid in candidates.keys {
                if let window = listed[wid] {
                    entries[wid]?.axVerified = true
                    entries[wid]?.axListed = true
                    if !window.title.isEmpty { entries[wid]?.fullTitle = window.title }
                    if let frame = window.frame { frames[wid] = frame }
                } else if !(hidden && listed.isEmpty) {
                    entries[wid]?.axVerified = false
                }
            }
        }
        return frames
    }

    /// Gives each unresolved collapsed window AX's frame, else its frame
    /// from a past poll, and drops the ones with neither.
    static func resolveCollapsed(_ sweep: inout Sweep, axFrames: [UInt32: CGRect], lastFrames: [UInt32: WindowFrame]) {
        for wid in sweep.unresolved {
            if let rect = axFrames[wid], isWindowSized(rect) {
                sweep.entries[wid]?.frame = frame(rect)
            } else if let known = lastFrames[wid] {
                sweep.entries[wid]?.frame = known
            } else {
                sweep.entries[wid] = nil
            }
        }
        sweep.unresolved = []
    }

    /// Gives a window AX didn't see this poll the whole title AX gave it
    /// before, while its CG title is unchanged.
    static func carryFullTitles(_ entries: inout [UInt32: WindowEntry], known: [UInt32: (cg: String, ax: String)]) {
        for (wid, entry) in entries where entry.fullTitle == nil {
            if let seen = known[wid], seen.cg == entry.title {
                entries[wid]?.fullTitle = seen.ax
            }
        }
    }

    /// Drops untitled stand-ins that sit exactly over another app's window,
    /// like the remote view System Settings shows Login Items through.
    static func dropProxies(_ entries: inout [UInt32: WindowEntry], facts: [Int32: AppFacts]) {
        let owners = entries.values.filter { $0.hasTitle && $0.axVerified }
        for (wid, entry) in entries where !entry.hasTitle {
            guard entry.spaceIds.isEmpty || facts[entry.pid]?.isRegular == false else { continue }
            if owners.contains(where: { $0.pid != entry.pid && sameFrame($0.frame, entry.frame) }) {
                entries[wid] = nil
            }
        }
    }

    private static func isWindowSized(_ rect: CGRect) -> Bool {
        rect.width >= minWindowSide && rect.height >= minWindowSide
    }

    private static func frame(_ rect: CGRect) -> WindowFrame {
        WindowFrame(x: Double(rect.origin.x), y: Double(rect.origin.y), w: Double(rect.width), h: Double(rect.height))
    }

    private static func sameFrame(_ a: WindowFrame, _ b: WindowFrame) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.w - b.w) <= 2 && abs(a.h - b.h) <= 2
    }

    // MARK: - Poll caches

    /// Caches kept between polls. Polls run on main and on the switch queue,
    /// so these are read and written under `cacheLock`.
    private let cacheLock = NSLock()
    /// Each app's last AX answer.
    private var axAnswers: [Int32: AXAnswer] = [:]
    /// Each window's frame last poll, for a collapsed window with no other.
    private var lastFrames: [UInt32: WindowFrame] = [:]
    /// Each window's whole AX title, with the CG title it had then.
    private var fullTitles: [UInt32: (cg: String, ax: String)] = [:]
    /// The windows AX has listed, for while they're on a desktop it can't see.
    private var axListed: Set<UInt32> = []

    /// How many times AX is asked about the same candidates before an
    /// unverified window stays so. AX can list a new window a beat after CG.
    private static let axAsks = 3

    private struct AXAnswer {
        let candidates: [UInt32: String]
        let windows: [UInt32: AXWindow]?
        let asks: Int

        /// Every candidate verified, or asked enough.
        var settled: Bool {
            if asks >= DesktopModel.axAsks { return true }
            guard let windows else { return false }
            return candidates.keys.allSatisfy { windows[$0] != nil }
        }
    }

    /// AX's windows for `pid`, asked again only when its candidates change
    /// or the last answer hasn't settled.
    private func axWindows(pid: Int32, candidates: [UInt32: String]) -> [UInt32: AXWindow]? {
        cacheLock.lock()
        let last = axAnswers[pid]
        cacheLock.unlock()
        if let last, last.candidates == candidates, last.settled { return last.windows }

        let windows = Self.queryAXWindows(pid: pid)
        let asks = last.map { $0.candidates == candidates ? $0.asks + 1 : 1 } ?? 1
        cacheLock.lock()
        axAnswers[pid] = AXAnswer(candidates: candidates, windows: windows, asks: asks)
        cacheLock.unlock()
        return windows
    }

    /// Keeps this poll's frames, whole titles and AX listings for the next,
    /// and forgets windows and apps that are gone.
    private func remember(_ entries: [UInt32: WindowEntry], asked: Set<Int32>) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        lastFrames = entries.mapValues(\.frame)
        fullTitles = entries.compactMapValues { entry in
            entry.fullTitle.map { (cg: entry.title, ax: $0) }
        }
        axListed = Set(entries.values.filter(\.axListed).map(\.wid))
        axAnswers = axAnswers.filter { asked.contains($0.key) }
    }

    /// The windows AX lists for `pid` by window number, or nil when AX
    /// doesn't answer. Any subrole counts: Calculator's and System Settings'
    /// main windows are AXDialog.
    private static func queryAXWindows(pid: Int32) -> [UInt32: AXWindow]? {
        let app = AXUIElementCreateApplication(pid)
        // Set a timeout so unresponsive apps (video calls, etc.) don't block the poll
        AXUIElementSetMessagingTimeout(app, 0.3)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        let attributes = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var windows: [UInt32: AXWindow] = [:]
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &wid) == .success, wid != 0 else { continue }
            AXUIElementSetMessagingTimeout(axWindow, 0.3)

            var valuesRef: CFArray?
            AXUIElementCopyMultipleAttributeValues(axWindow, attributes, AXCopyMultipleAttributeOptions(), &valuesRef)
            let values = valuesRef as? [AnyObject] ?? []
            var origin = CGPoint.zero
            var size = CGSize.zero
            var frame: CGRect?
            if values.count == 3,
               CFGetTypeID(values[1]) == AXValueGetTypeID(), AXValueGetValue(values[1] as! AXValue, .cgPoint, &origin),
               CFGetTypeID(values[2]) == AXValueGetTypeID(), AXValueGetValue(values[2] as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: origin, size: size)
            }
            windows[wid] = AXWindow(title: values.first as? String ?? "", frame: frame)
        }
        return windows
    }

    private func finishPoll(_ fresh: [UInt32: WindowEntry], revision: Int) -> [WindowEntry] {
        let focusedWid = resolveFocusedWindowID(in: fresh)
        let interactionTime = Date()
        let sorted = Array(fresh.values).sorted { $0.zIndex < $1.zIndex }

        // Diff and publish run entirely on main — every field counts, since a
        // Space switch flips `isOnScreen` and reorders `zIndex` without
        // touching titles, frames, or the window set. Recurring scans and
        // `refreshNow()` can run off main. Reject an older queued publication
        // if an explicit main-thread refresh has already published newer truth.
        let apply = {
            guard revision > self.publishedRevision else { return }
            self.publishedRevision = revision
            self.lastPollTime = Date()

            let oldKeys = Set(self.windows.keys)
            let newKeys = Set(fresh.keys)
            let added = Array(newKeys.subtracting(oldKeys))
            let removed = Array(oldKeys.subtracting(newKeys))

            let changed = self.windows != fresh
            let focusedChanged = focusedWid != self.lastFocusedWindowID

            var interactions = self.interactionDates.filter { fresh[$0.key] != nil }
            // Seed newly-discovered windows so the inventory's LAST SEEN column
            // is populated from first paint. interactionDates is in-memory only
            // and resets on app restart; on the very first poll every visible
            // wid lands in `added`, which gives the user a baseline.
            for wid in added where interactions[wid] == nil {
                interactions[wid] = interactionTime
            }
            if focusedChanged, let focusedWid {
                interactions[focusedWid] = interactionTime
            }
            // Only publish if something actually changed — avoids unnecessary SwiftUI re-renders
            if changed || focusedChanged {
                self.windows = fresh
                self.interactionDates = interactions
            }
            if self.focusedWindowID != focusedWid {
                self.focusedWindowID = focusedWid
            }
            self.lastFocusedWindowID = focusedWid

            if changed {
                EventBus.shared.post(.windowsChanged(
                    windows: Array(fresh.values),
                    added: added,
                    removed: removed
                ))
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }

        return sorted
    }

    private func resolveFocusedWindowID(in windows: [UInt32: WindowEntry]) -> UInt32? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !LatticesRuntime.isLatticesBundleIdentifier(app.bundleIdentifier) else {
            return nil
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 0.2)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedWindow = focusedRef else {
            return nil
        }

        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focusedWindow as! AXUIElement, &wid) == .success,
              wid != 0 else {
            return nil
        }

        let id = UInt32(wid)
        return windows[id] == nil ? nil : id
    }
}
