import AppKit

/// A layer browse that moves nothing until you say so. ⌃⌥⇧ arrows or
/// ⌘⌥ digits aim at a layer and show where its windows would sit. Letting
/// go asks: Return or the switch button switches; Escape, the stay button,
/// another key, a click elsewhere or the wait running out stays put.
/// A wait of 0 switches at once. Either chord resumes browsing; Space
/// freezes the aimed layer in `LayerPreview`, whose Enter switches.
final class LayerAim {
    static let shared = LayerAim()

    private enum Phase { case aiming, deciding }

    /// The layer aimed at, while a browse chord is held or the choice is open. Main
    /// thread only, the key tap's callback included.
    private(set) var target: Int?
    private var phase = Phase.aiming
    private var customShortcut = false
    private var browseChord = LayerChordState.BrowseChord.direct
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
    var ownsShortcutDecision: Bool { isDeciding && customShortcut }

    /// Where the next arrow steps from: the layer aimed at, else the one
    /// you're on.
    func origin(in workspace: WorkspaceManager) -> Int {
        let count = workspace.layers.count
        return min(max(target ?? workspace.activeLayerIndex, 0), max(count - 1, 0))
    }

    /// Aims at layer `index` and shows it on the pad. With its browse chord
    /// already up, or a shortcut using other modifiers, it asks at once.
    func aim(at index: Int, binding: KeyBinding? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let workspace = WorkspaceManager.shared
        guard workspace.layers.indices.contains(index) else { return }
        if phase == .deciding { endDeciding() }
        phase = .aiming
        target = index
        customShortcut = Self.isCustomShortcut(binding)
        browseChord = Self.browseChord(for: binding) ?? .direct
        steps += 1
        let entry = Self.entry(for: CGEventSource.flagsState(.combinedSessionState), binding: binding)
        guard entry == .browse else {
            if entry == .cancel {
                cancel()
                LayerBezel.shared.release(after: 0)
                return
            }
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

    /// The browse chord came up. True when it now asks, keeping the pad up; false when
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

    /// A browse chord went down again while asking: browse on from the
    /// layer aimed at. True when there was a choice open.
    func resume(with chord: LayerChordState.BrowseChord) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isDeciding, !ownsShortcutDecision else { return false }
        endDeciding()
        phase = .aiming
        browseChord = chord
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
        customShortcut = false
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
            guard let self else { return }
            let mode = LayerChordState.mode(CGEventSource.flagsState(.combinedSessionState), for: self.browseChord)
            guard mode != .browse else { return }
            if mode == .cancel {
                self.cancel()
                LayerBezel.shared.release(after: 0)
                return
            }
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

    /// On the main run loop. Return and Escape are the choice's; layer keys go
    /// through to the hotkeys, which browse on; any other key stays and
    /// goes through.
    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        let aim = LayerAim.shared
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if aim.isDeciding, let tap = aim.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, aim.isDeciding else { return Unmanaged.passUnretained(event) }
        switch choice(for: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .confirm:
            DispatchQueue.main.async { aim.confirm() }
            return nil
        case .cancel:
            DispatchQueue.main.async { aim.cancel() }
            return nil
        case .cancelAndPass:
            DispatchQueue.main.async { aim.cancel() }
            return Unmanaged.passUnretained(event)
        }
    }

    enum Choice: Equatable { case pass, confirm, cancel, cancelAndPass }

    enum Entry: Equatable { case browse, decide, cancel }

    static func entry(for flags: CGEventFlags, binding: KeyBinding?) -> Entry {
        // The dispatched action identifies an intentional custom shortcut.
        // Looking only at current flags mistakes its Shift/Control for a
        // modifier added to an existing browse.
        guard let chord = browseChord(for: binding) else { return .decide }
        switch LayerChordState.mode(flags, for: chord) {
        case .browse: return .browse
        case .release: return .decide
        case .cancel: return .cancel
        }
    }

    static func isCustomShortcut(_ binding: KeyBinding?) -> Bool {
        browseChord(for: binding) == nil
    }

    static func browseChord(for binding: KeyBinding?) -> LayerChordState.BrowseChord? {
        guard let binding else { return .direct } // Fixed keypad/direct actions.
        let chord: LayerChordState.BrowseChord
        switch binding.carbonModifiers {
        case KeyBinding.carbonModifiers(from: [.control, .option, .shift]): chord = .arrows
        case KeyBinding.carbonModifiers(from: [.command, .option]): chord = .direct
        default: return nil
        }
        return chord.accepts(key: Int64(binding.keyCode)) ? chord : nil
    }

    static func choice(for key: Int64, flags: CGEventFlags) -> Choice {
        if let chord = LayerChordState.browseChord(for: flags) {
            return chord.accepts(key: key) ? .pass : .cancelAndPass
        }
        let modifiers = LayerChordState.modifiers(flags)
        if key == 53, modifiers == .maskShift { return .cancel }
        guard modifiers.isEmpty else { return .cancelAndPass }
        switch key {
        case 36, 76: return .confirm
        case 53: return .cancel
        default: return .cancelAndPass
        }
    }
}
