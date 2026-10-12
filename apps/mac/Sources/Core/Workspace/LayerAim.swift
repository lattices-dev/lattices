import AppKit

/// A ⌘⌥ browse that moves nothing until you say so. While ⌘⌥ is held, the
/// arrows and digits aim at a layer: the pad lights its slot and draws a
/// map of where its windows would sit (`LayerForecast`); no window moves.
/// Letting go of ⌘⌥ asks: Return or the switch button switches to the
/// layer aimed at; Escape, the stay button, a click elsewhere, another key
/// or the wait running out (`Preferences.layerSwitchConfirmSeconds`) stay
/// on the layer you're on. A wait of 0 switches at once.
/// ⌘⌥ again goes on browsing from the layer aimed at. Escape, the middle
/// slot, or someone else's ⌘⌥ shortcut while held drops the aim.
///
/// Space mid-browse freezes on the layer aimed at (`LayerPreview`), which
/// takes the aim over; its Enter switches.
final class LayerAim {
    static let shared = LayerAim()

    private enum Phase { case aiming, deciding }

    /// The layer aimed at, while ⌘⌥ is held or the choice is open. Main
    /// thread only, the key tap's callback included.
    private(set) var target: Int?
    private var phase = Phase.aiming
    /// How many keys aimed in this hold. Aiming at the layer you're on as
    /// the only key offers to reconcile it, as ⌘⌥N always has; browsing
    /// back to it leaves it be.
    private var steps = 0
    private var watch: Timer?
    private var timeout: DispatchWorkItem?
    private var keyTap: CFMachPort?
    private var mouseMonitor: Any?
    private var decideStarted: CFTimeInterval = 0

    /// How long the choice waits before staying; nil waits for a key, 0
    /// doesn't ask.
    private static var decideLimit: TimeInterval? {
        let seconds = Preferences.shared.layerSwitchConfirmSeconds
        return seconds < 0 ? nil : seconds
    }

    private init() {}

    var isDeciding: Bool { target != nil && phase == .deciding }

    /// Where the next arrow steps from: the layer aimed at, else the one
    /// you're on.
    func origin(in workspace: WorkspaceManager) -> Int {
        let count = workspace.layers.count
        return min(max(target ?? workspace.activeLayerIndex, 0), max(count - 1, 0))
    }

    /// Aims at layer `index` and shows it on the pad. With ⌘⌥ already up,
    /// it asks at once.
    func aim(at index: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        let workspace = WorkspaceManager.shared
        guard workspace.layers.indices.contains(index) else { return }
        if phase == .deciding { endDeciding() }
        phase = .aiming
        target = index
        steps += 1
        guard Self.chordHeld() else {
            LayerBezel.shared.hold()
            if !letGo() { LayerBezel.shared.release(after: 0) }
            return
        }
        present()
        watchRelease()
    }

    /// A bump off the pad's edge, from the layer aimed at.
    func bump(_ direction: LayerSlots.Direction) {
        let workspace = WorkspaceManager.shared
        guard target != nil else {
            let current = origin(in: workspace)
            workspace.showBezel(for: current, in: workspace.layers, edge: direction)
            return
        }
        present(edge: direction)
    }

    /// ⌘⌥ came up. True when it now asks, keeping the pad up; false when
    /// there was nothing to ask, and the pad can go.
    @discardableResult
    func letGo() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = target, phase == .aiming, !LayerPreview.shared.isFrozen else { return false }
        stopWatch()
        let workspace = WorkspaceManager.shared
        guard workspace.layers.indices.contains(index), index != workspace.activeLayerSelection else {
            // ⌘⌥N on the layer you're on puts it back in order, as it always
            // has; browsing back to it leaves it be.
            let reconcile = steps == 1 && workspace.layers.indices.contains(index)
            reset()
            if reconcile { workspace.focusLayer(index: index) }
            return false
        }
        if Self.decideLimit == 0 {
            reset()
            workspace.focusLayer(index: index)
            return false
        }
        phase = .deciding
        decideStarted = CACurrentMediaTime()
        present()
        listenForChoice()
        return true
    }

    /// ⌘⌥ went down again while asking: browse on from the layer aimed at.
    /// True when there was a choice open.
    func resume() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isDeciding else { return false }
        endDeciding()
        phase = .aiming
        present()
        watchRelease()
        return true
    }

    /// Return: switch to the layer aimed at.
    func confirm() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = target else { return }
        reset()
        LayerBezel.shared.release(after: 0)
        let workspace = WorkspaceManager.shared
        guard workspace.layers.indices.contains(index) else { return }
        workspace.focusLayer(index: index)
    }

    /// Stay where you are: no window moves.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard target != nil else { return }
        let wasDeciding = phase == .deciding
        reset()
        if wasDeciding { LayerBezel.shared.release(after: 0) }
        DiagnosticLog.shared.info("LayerAim: stayed; nothing moved")
    }

    /// Hands the aim to a freeze, which shows that layer.
    func take() -> Int? {
        defer { reset() }
        return target
    }

    // MARK: Showing

    private func present(edge: LayerSlots.Direction? = nil) {
        let workspace = WorkspaceManager.shared
        let layers = workspace.layers
        guard let index = target, layers.indices.contains(index) else { return }
        let current = workspace.activeLayer?.label
        guard let forecast = workspace.forecast(for: index) else {
            workspace.showBezel(for: index, in: layers, edge: edge)
            return
        }
        let decision = phase == .deciding ? LayerBezelView.Decision(
            target: layers[index].label, current: current ?? "the desktop",
            limit: Self.decideLimit, started: decideStarted,
            choose: { [weak self] choice in
                switch choice {
                case .go: self?.confirm()
                case .stay: self?.cancel()
                }
            }
        ) : nil
        LayerBezel.shared.showForecast(
            label: layers[index].label, index: index, total: layers.count,
            forecast: forecast, edge: edge, decision: decision
        )
    }

    // MARK: State

    private func reset() {
        target = nil
        steps = 0
        phase = .aiming
        stopWatch()
        endDeciding()
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
    }

    /// A release the chord monitor misses (no tap, a key that came in after
    /// its release) still asks.
    private func watchRelease() {
        guard watch == nil else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, !Self.chordHeld() else { return }
            if LayerPreview.shared.isFrozen {
                self.stopWatch()
                return
            }
            if !self.letGo() { LayerBezel.shared.release(after: 0) }
        }
    }

    // MARK: The choice

    private func listenForChoice() {
        LayerBezel.shared.hold()
        installKeyTap()
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.cancel()
            }
        }
        timeout?.cancel()
        timeout = nil
        guard let limit = Self.decideLimit else { return }
        let stay = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = stay
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: stay)
    }

    private func endDeciding() {
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        timeout?.cancel()
        timeout = nil
    }

    private func installKeyTap() {
        guard keyTap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: nil
        ) else {
            DiagnosticLog.shared.warn("LayerAim: couldn't listen for Return/Escape")
            return
        }
        keyTap = tap
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// On the main run loop. Return and Escape are the choice's; ⌘⌥ keys go
    /// through to the hotkeys, which browse on; any other key stays and
    /// goes through.
    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        let aim = LayerAim.shared
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if aim.isDeciding, let tap = aim.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, aim.isDeciding else { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        if flags.contains(.maskCommand), flags.contains(.maskAlternate) { return Unmanaged.passUnretained(event) }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 36, 76:
            DispatchQueue.main.async { aim.confirm() }
            return nil
        case 53:
            DispatchQueue.main.async { aim.cancel() }
            return nil
        default:
            DispatchQueue.main.async { aim.cancel() }
            return Unmanaged.passUnretained(event)
        }
    }

    private static func chordHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskCommand) && flags.contains(.maskAlternate)
    }
}
