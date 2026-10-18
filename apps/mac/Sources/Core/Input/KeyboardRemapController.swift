import AppKit
import Combine
import CoreGraphics
import IOKit.hidsystem

final class KeyboardRemapController: ObservableObject {
    static let shared = KeyboardRemapController()

    /// Live state of the event-tap circuit breaker. SettingsView observes
    /// this to surface "paused" / "disabled" status and a re-arm button.
    @Published private(set) var breakerState: EventTapBreaker.State = .armed
    @Published private(set) var capsLockTransportActive = false

    private static let syntheticMarker: Int64 = 0x4C4B524D

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapLocation: CGEventTapLocation = .cghidEventTap
    private var subscriptions: Set<AnyCancellable> = []
    private var installedObservers = false
    private var capsLayerActive = false
    private var capsUsedAsModifier = false
    private var capsLayerActivatedAt: CFAbsoluteTime?
    private var capsLayerLastEventAt: CFAbsoluteTime?
    private var bypassUntil: CFAbsoluteTime = 0
    private var lastCapsLayerStaleLogAt: CFAbsoluteTime = 0
    private var pressedKeyCodes: [Int64: CFAbsoluteTime] = [:]
    private let capsLockTransport = CapsLockHIDTransportController()
    private let breaker = EventTapBreaker(label: "KeyboardRemap")
    private let budgetMeter = TapBudgetMeter(label: "KeyboardRemap")
    /// Tap-thread cache — never read KeyboardRemapStore (or take its lock) from
    /// the CGEventTap callback. Store access was showing up as multi-ms stalls
    /// on every keystroke and the OS then delayed *all* keyboard input.
    private let tapConfigLock = NSLock()
    private var tapHyperEnabled = false
    private var tapTransportActive = false
    private var tapCapsKeyCode: Int64 = 57 // Caps Lock
    private var tapAloneIsEscape = true
    private let maxCapsLayerIdleDuration: TimeInterval = 2.0
    private let maxCapsLayerHeldDuration: TimeInterval = 20.0
    private let maxTrackedKeyDownDuration: TimeInterval = 120.0
    private let emergencyBypassDuration: TimeInterval = 3.0

    private init() {
        capsLockTransport.onActiveChanged = { [weak self] active in
            guard let self else { return }
            self.capsLockTransportActive = active
            let rule = KeyboardRemapStore.shared.capsLockRule
            self.publishTapConfig(
                hyperEnabled: Preferences.shared.keyboardRemapsEnabled && rule?.toIfHeld == .hyper,
                transportActive: active,
                capsKeyCode: Int64(rule?.from.keyCode ?? 57),
                aloneEscape: rule?.toIfAlone == .escape
            )
        }
        breaker.onStateChanged = { [weak self] newState in
            self?.breakerState = newState
        }
    }

    /// Re-enable the tap after a breaker trip, clearing trip history.
    /// Settings UI calls this when the user explicitly chooses to recover
    /// from a `disabled` state.
    func reArmAfterBreakerTrip() {
        dispatchPrecondition(condition: .onQueue(.main))
        breaker.reset()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    @discardableResult
    func clearStuckCapsLockState() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        clearCapsLayer()
        pressedKeyCodes.removeAll()
        bypassUntil = CFAbsoluteTimeGetCurrent() + emergencyBypassDuration
        let cleared = clearCapsLockLatch(reason: "manual settings recovery")
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            refresh()
        }
        DiagnosticLog.shared.warn("KeyboardRemap: manual Caps Lock recovery \(cleared ? "succeeded" : "failed")")
        return cleared
    }

    func start() {
        installObserversIfNeeded()
        refresh()
    }

    func stop() {
        let hadCapsLayer = capsLayerActive
        let hyperEnabled = readTapConfig().hyper
        removeEventTap()
        capsLockTransport.disable()
        capsLockTransportActive = capsLockTransport.isActive
        clearCapsLayer()
        // clearCapsLayer() only resets process-local bookkeeping. The IOHID Caps
        // Lock latch is global state that outlives the process: tear down with it
        // set and it stays set, with no tap left to translate it into Hyper.
        // Synchronous on purpose — latchQueue will not drain during termination.
        if hyperEnabled || hadCapsLayer {
            clearCapsLockLatch(reason: "shutdown")
        }
    }

    /// Last-ditch cleanup for paths that bypass `applicationWillTerminate`
    /// (SIGTERM/SIGINT from a dev rebuild). Deliberately does one thing: drop
    /// the IOHID Caps Lock latch, which is a single IOKit call touching no
    /// shared mutable state and is therefore safe from a signal-source queue.
    ///
    /// The HID transport remap is *not* torn down here — `disable()` mutates
    /// non-atomic instance state with no queue guarantee, and racing it during
    /// termination risks a torn write to the system-wide mapping. It does not
    /// need us: ownership and the original mappings are persisted to
    /// UserDefaults, so the next launch restores them via `enable()`. The latch
    /// has no such recovery path, which is why it is the one thing worth doing
    /// on the way out.
    func flushGlobalStateForAbruptTermination() {
        clearCapsLockLatch(reason: "signal")
    }

    func resetForSystemInputBoundary(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        clearCapsLayer()
        pressedKeyCodes.removeAll()
        // Do not hard-reset the circuit breaker here. App-activation storms used
        // to re-arm a just-tripped HID tap and immediately freeze input again.
        // Only re-enable if the breaker is currently armed (healthy).
        switch breaker.state {
        case .armed:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            } else {
                refresh()
            }
        case .paused, .disabled:
            DiagnosticLog.shared.warn(
                "KeyboardRemap: boundary '\(reason)' ignored re-arm — breaker is \(breaker.state)"
            )
            return
        }
        DiagnosticLog.shared.warn("KeyboardRemap: reset for \(reason)")
    }

    private func installObserversIfNeeded() {
        guard !installedObservers else { return }
        installedObservers = true

        Preferences.shared.$keyboardRemapsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        KeyboardRemapStore.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        PermissionChecker.shared.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    private func refresh() {
        guard Preferences.shared.keyboardRemapsEnabled,
              PermissionChecker.shared.accessibility else {
            removeEventTap()
            capsLockTransport.disable()
            capsLockTransportActive = capsLockTransport.isActive
            publishTapConfig(hyperEnabled: false, transportActive: false, capsKeyCode: 57, aloneEscape: true)
            return
        }

        KeyboardRemapStore.shared.ensureConfigFile()
        let rule = KeyboardRemapStore.shared.capsLockRule
        let shouldUseCapsLockTransport = rule?.toIfHeld == .hyper
        capsLockTransport.setEnabled(shouldUseCapsLockTransport)
        capsLockTransportActive = capsLockTransport.isActive
        publishTapConfig(
            hyperEnabled: shouldUseCapsLockTransport,
            transportActive: capsLockTransport.isActive,
            capsKeyCode: Int64(rule?.from.keyCode ?? 57),
            aloneEscape: rule?.toIfAlone == .escape
        )

        // Never re-enable a breaker-paused or permanently disabled tap from a
        // casual refresh (prefs/accessibility churn). That re-introduces freezes.
        switch breaker.state {
        case .paused, .disabled:
            return
        case .armed:
            break
        }

        if eventTap == nil {
            installEventTap()
        } else if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func publishTapConfig(
        hyperEnabled: Bool,
        transportActive: Bool,
        capsKeyCode: Int64,
        aloneEscape: Bool
    ) {
        tapConfigLock.lock()
        tapHyperEnabled = hyperEnabled
        tapTransportActive = transportActive
        tapCapsKeyCode = capsKeyCode
        tapAloneIsEscape = aloneEscape
        tapConfigLock.unlock()
    }

    private func readTapConfig() -> (hyper: Bool, transport: Bool, capsKey: Int64, aloneEscape: Bool) {
        tapConfigLock.lock()
        defer { tapConfigLock.unlock() }
        return (tapHyperEnabled, tapTransportActive, tapCapsKeyCode, tapAloneIsEscape)
    }

    private func installEventTap() {
        // Fresh install is a clean slate — drop any stale trip history so
        // the new tap's first failure is judged on its own merits.
        breaker.reset()

        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue

        let tapCandidates: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "HID"),
            (.cgSessionEventTap, "session"),
        ]
        var installedLabel = "unknown"
        var installedLocation: CGEventTapLocation = .cghidEventTap
        let tap = EventTapInstallation.firstAvailable(tapCandidates) { location, label -> CFMachPort? in
            let candidate = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.eventTapCallback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            if candidate != nil {
                installedLabel = label
                installedLocation = location
            }
            return candidate
        }

        guard let tap else {
            DiagnosticLog.shared.warn("KeyboardRemap: failed to install keyboard event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapLocation = installedLocation
        runLoopSource = source

        if let source {
            EventTapThread.keyboard.add(source: source)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        breaker.rearm = { [weak self] in
            guard let self, let tap = self.eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        DiagnosticLog.shared.info("KeyboardRemap: keyboard event tap installed (\(installedLabel))")
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            EventTapThread.keyboard.remove(source: source)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        capsLockTransportActive = capsLockTransport.isActive
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<KeyboardRemapController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Intentionally no budgetMeter / logging on the common path — even a
        // few ms of bookkeeping on every keystroke was enough for the OS to
        // queue keyboard delivery system-wide (user-visible "Lattices ate my keys").

        if type == .tapDisabledByTimeout {
            clearCapsLayer()
            breaker.recordTrip()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            clearCapsLayer()
            // Do not auto re-enable here; honor breaker state via refresh/reArm.
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let started = CFAbsoluteTimeGetCurrent()
        if started < bypassUntil {
            return Unmanaged.passUnretained(event)
        }

        let config = readTapConfig()
        guard config.hyper else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // ── Fail-open fast path ─────────────────────────────────────────
        // Normal typing never needs store access, key-down tracking, or
        // reload checks. Only Caps/F18 and an active Hyper layer matter.
        if !capsLayerActive {
            if config.transport {
                if keyCode == CapsLockHIDTransportController.transportKeyCode {
                    return handleCapsLockTransportEvent(
                        type: type,
                        event: event,
                        aloneEscape: config.aloneEscape
                    )
                }
            }
            if type == .flagsChanged, keyCode == config.capsKey {
                return handleCapsLockFlagsChanged(event, aloneEscape: config.aloneEscape)
            }
            return Unmanaged.passUnretained(event)
        }

        // Hyper layer is down — inject Hyper and keep layer bookkeeping light.
        reconcileCapsLayer(event: event, type: type, now: started, transportActive: config.transport)
        guard capsLayerActive else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if keyCode == 53 {
                emergencyClear(now: started)
                return Unmanaged.passUnretained(event)
            }
            // F18 transport key while held: swallow, keep layer.
            if config.transport, keyCode == CapsLockHIDTransportController.transportKeyCode {
                return nil
            }
            capsUsedAsModifier = true
            capsLayerLastEventAt = started
            event.flags = normalizedFlags(event.flags).union(.latticesHyper)
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if config.transport, keyCode == CapsLockHIDTransportController.transportKeyCode {
                let shouldTap = !capsUsedAsModifier && config.aloneEscape
                clearCapsLayer()
                if shouldTap { scheduleKeyTap(keyCode: 53) }
                return nil
            }
            capsLayerLastEventAt = started
            event.flags = normalizedFlags(event.flags).union(.latticesHyper)
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            if keyCode == config.capsKey {
                return handleCapsLockFlagsChanged(event, aloneEscape: config.aloneEscape)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleCapsLockFlagsChanged(_ event: CGEvent, aloneEscape: Bool) -> Unmanaged<CGEvent>? {
        let isDown = event.flags.contains(.maskAlphaShift)
        if isDown {
            activateCapsLayer(now: CFAbsoluteTimeGetCurrent())
            scheduleCapsLockLatchRelease()
        } else {
            let shouldTap = capsLayerActive && !capsUsedAsModifier && aloneEscape
            clearCapsLayer()
            scheduleCapsLockLatchRelease()
            if shouldTap {
                scheduleKeyTap(keyCode: 53)
            }
        }

        return nil
    }

    private func handleCapsLockTransportEvent(
        type: CGEventType,
        event: CGEvent,
        aloneEscape: Bool
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                activateCapsLayer(now: CFAbsoluteTimeGetCurrent())
            }
            return nil
        case .keyUp:
            let shouldTap = capsLayerActive && !capsUsedAsModifier && aloneEscape
            clearCapsLayer()
            if shouldTap {
                scheduleKeyTap(keyCode: 53)
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func activateCapsLayer(now: CFAbsoluteTime) {
        guard !capsLayerActive else { return }
        capsLayerActive = true
        capsUsedAsModifier = false
        capsLayerActivatedAt = now
        capsLayerLastEventAt = now
    }

    private func clearCapsLayer() {
        capsLayerActive = false
        capsUsedAsModifier = false
        capsLayerActivatedAt = nil
        capsLayerLastEventAt = nil
    }

    private func reconcileCapsLayer(
        event: CGEvent,
        type: CGEventType,
        now: CFAbsoluteTime,
        transportActive: Bool
    ) {
        guard capsLayerActive else { return }

        // If a release event was dropped, later key events often arrive
        // without the physical Caps flag. Treat that as an input boundary and
        // fail open before rewriting the user's key.
        if !transportActive,
           type == .keyDown || type == .keyUp,
           !event.flags.contains(.maskAlphaShift) {
            clearCapsLayer(reason: "physical Caps flag cleared", now: now)
            return
        }

        if let lastEventAt = capsLayerLastEventAt,
           now - lastEventAt > maxCapsLayerIdleDuration {
            clearCapsLayer(reason: "idle", now: now)
            return
        }

        if let activatedAt = capsLayerActivatedAt,
           now - activatedAt > maxCapsLayerHeldDuration {
            clearCapsLayer(reason: "held too long", now: now)
        }
    }

    private func clearCapsLayer(reason: String, now: CFAbsoluteTime) {
        clearCapsLayer()
        if now - lastCapsLayerStaleLogAt > 1 {
            lastCapsLayerStaleLogAt = now
            let r = reason
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.shared.warn("KeyboardRemap: Caps Lock layer cleared (\(r))")
            }
        }
    }

    private func emergencyClear(now: CFAbsoluteTime) {
        clearCapsLayer()
        pressedKeyCodes.removeAll()
        bypassUntil = now + emergencyBypassDuration
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.shared.warn("KeyboardRemap: emergency bypass via Escape")
        }
    }

    private func normalizedFlags(_ flags: CGEventFlags) -> CGEventFlags {
        var normalized = flags
        normalized.remove(.maskAlphaShift)
        return normalized
    }

    /// IOHID latch clears + synthetic Escape must never run on the CGEventTap
    /// callback. They can take tens of ms and stall *all* keyboard (and under
    /// load, feel like the whole desktop is frozen).
    private func scheduleCapsLockLatchRelease() {
        let queue = Self.latchQueue
        queue.async { [weak self] in
            self?.clearCapsLockLatch(reason: "event")
        }
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.clearCapsLockLatch(reason: "settle")
        }
        queue.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.clearCapsLockLatch(reason: "deferred")
        }
    }

    private static let latchQueue = DispatchQueue(label: "dev.lattices.keyboard-remap.latch", qos: .userInitiated)

    @discardableResult
    private func clearCapsLockLatch(reason: String) -> Bool {
        let result = IOHIDSetModifierLockState(kIOMainPortDefault, Int32(kIOHIDCapsLockState), false)
        if result != kIOReturnSuccess {
            DiagnosticLog.shared.warn("KeyboardRemap: failed to clear Caps Lock latch (\(reason), \(result))")
            return false
        }
        return true
    }

    private func scheduleKeyTap(keyCode: CGKeyCode) {
        Self.latchQueue.async { [weak self] in
            self?.postKeyTap(keyCode: keyCode)
        }
    }

    private func postKeyTap(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
