import AppKit
import Combine
import CoreGraphics

/// Keeps native desktop navigation available whenever the interceptor cannot
/// own it. Dependencies are injectable so failure paths need no real event tap.
struct SpaceSwitchInputOwnership {
    var makeTapReady: () -> Bool
    var removeTap: () -> Void
    var disableSystemHotkeys: () -> Void
    var restoreSystemHotkeys: () -> Void

    func reconcile(isRunning: Bool, featureEnabled: Bool, accessibilityGranted: Bool, breakerArmed: Bool) {
        guard isRunning, featureEnabled, accessibilityGranted, breakerArmed,
              makeTapReady() else {
            removeTap()
            restoreSystemHotkeys()
            return
        }
        disableSystemHotkeys()
    }
}

/// Intercepts Ctrl+← / Ctrl+→ before Mission Control sees them and routes the
/// press through `WindowTiler.performSpaceSwitch` — a synthetic Dock swipe
/// under a screen-update freeze, so the Space cuts over instead of sliding. A small
/// `SpaceSwitchBezel` pill confirms the move.
///
/// The keydown is swallowed at the HID event tap. Hardware presses also reach
/// Mission Control's symbolic hotkey ahead of the tap, so
/// `SpaceSwitchHotkeys` unregisters that binding while this feature is on —
/// without it the slide animation still plays on top of the instant switch.
/// Presses that arrive while a switch is running merge into one pending
/// offset, so a burst or a held key drives toward the latest target instead
/// of replaying every step. Synthetic chords tagged with
/// `spaceShortcutSyntheticMarker` pass through untouched.
///
/// Only bare Ctrl+arrows are claimed, plus Ctrl+Shift+arrows for the Space
/// landscape. Ctrl+Opt+arrows stay owned by tiling. Hyper and Command chords
/// pass straight through. While the strip is showing, Ctrl+− and Ctrl+= also
/// zoom its aperture out and back in, as do Ctrl+↓/↑ and Ctrl+Option+scroll.
final class SpaceSwitchInterceptor: ObservableObject {
    static let shared = SpaceSwitchInterceptor()

    /// Live breaker state for the settings surface.
    @Published private(set) var breakerState: EventTapBreaker.State = .armed

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var subscriptions: Set<AnyCancellable> = []
    private var installedObservers = false
    private var isRunning = false
    private let breaker = EventTapBreaker(label: "SpaceSwitch")
    private lazy var inputOwnership = SpaceSwitchInputOwnership(
        makeTapReady: { [weak self] in self?.makeEventTapReady() ?? false },
        removeTap: { [weak self] in self?.removeEventTap() },
        disableSystemHotkeys: SpaceSwitchHotkeys.disable,
        restoreSystemHotkeys: SpaceSwitchHotkeys.restore
    )
    /// Serializes the actual Space swap. `switchToSpace` can poll the CGS
    /// display list for ~0.45s on a miss — that must never run on the tap
    /// thread or on main.
    private let switchQueue = DispatchQueue(label: "dev.lattices.space-switch", qos: .userInitiated)

    private lazy var navigator = SpaceSwitchNavigator(queue: switchQueue)
    /// Guarded by pendingLock, including teardown on main. Consume key-up
    /// even if Ctrl went up first; discard ownership when the tap is removed.
    private var ownedArrows: Set<Int64> = []
    /// Ctrl+− / Ctrl+= claimed while the strip was up. Their key-ups never
    /// land a selection; only Ctrl's release does.
    private var ownedZoomKeys: Set<Int64> = []
    /// Invalidates queued key callbacks when their event tap is torn down.
    /// Guarded by pendingLock, like the owned key sets.
    private var zoomInputGeneration: UInt64 = 0
    private var zoomScroll = SpaceZoomScroll()
    private let pendingLock = NSLock()
    private var pendingOffset = 0
    private var pendingPoint: CGPoint?
    private var pendingLandscape = false
    private var drainScheduled = false
    /// A switch in this drain missed its verification window. Read and
    /// written only on `switchQueue`.
    private var missedSinceSettle = false

    private init() {
        breaker.onStateChanged = { [weak self] newState in
            self?.breakerState = newState
            self?.refresh()
        }
    }

    func start() {
        if !isRunning { SpaceZoomInput.recover() }
        isRunning = true
        installObserversIfNeeded()
        refresh()
    }

    func stop() {
        isRunning = false
        refresh()
    }

    /// Both mouse entry points use the same retained inventory and navigator.
    func openCanvas(from point: CGPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning, Preferences.shared.spaceSwitchKeysEnabled else { return }
        cancelPlacementPreview()
        if !SpaceZoomInput.engaged { navigator.cancel() }
        navigator.zoom(out: true, point: point)
    }

    private func cancelPlacementPreview() {
        TilePointerController.shared.cancelApply()
        #if LATTICES_BUNDLE
        SpatialLensController.shared.resetForSystemInputBoundary(reason: "desktop canvas gesture")
        #endif
    }

    func resetForSystemInputBoundary(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        refresh()
        DiagnosticLog.shared.warn("SpaceSwitch: reset for \(reason)")
    }

    /// Re-enable the tap after a breaker trip, clearing trip history.
    func reArmAfterBreakerTrip() {
        dispatchPrecondition(condition: .onQueue(.main))
        breaker.reset()
        refresh()
    }

    private func installObserversIfNeeded() {
        guard !installedObservers else { return }
        installedObservers = true

        Preferences.shared.$spaceSwitchKeysEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        PermissionChecker.shared.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        inputOwnership.reconcile(
            isRunning: isRunning,
            featureEnabled: Preferences.shared.spaceSwitchKeysEnabled,
            accessibilityGranted: PermissionChecker.shared.accessibility,
            breakerArmed: breaker.state == .armed
        )
    }

    private func makeEventTapReady() -> Bool {
        if let eventTap, !CFMachPortIsValid(eventTap) {
            removeEventTap()
        }
        if eventTap == nil {
            installEventTap()
        }
        guard let eventTap, let runLoopSource, CFRunLoopSourceIsValid(runLoopSource) else { return false }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    private func installEventTap() {
        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.scrollWheel.rawValue

        // HID first — that is the only insertion point that reliably beats the
        // Mission Control symbolic hotkey. Session is a degraded fallback.
        let tapCandidates: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "HID"),
            (.cgSessionEventTap, "session"),
        ]
        var installedLabel = "unknown"
        let tap = EventTapInstallation.firstAvailable(tapCandidates) { location, label -> CFMachPort? in
            let candidate = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.eventTapCallback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            if candidate != nil { installedLabel = label }
            return candidate
        }

        guard let tap else {
            DiagnosticLog.shared.warn("SpaceSwitch: failed to install keyboard event tap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            DiagnosticLog.shared.warn("SpaceSwitch: failed to install keyboard event tap source")
            return
        }
        eventTap = tap
        runLoopSource = source

        EventTapThread.overlay.add(source: source)
        DiagnosticLog.shared.info("SpaceSwitch: keyboard event tap installed (\(installedLabel))")
    }

    private func removeEventTap() {
        navigator.cancel(force: true)
        SpaceCanvasKeyboard.shared.reset()
        pendingLock.lock()
        ownedArrows.removeAll()
        ownedZoomKeys.removeAll()
        zoomInputGeneration &+= 1
        zoomScroll = SpaceZoomScroll()
        pendingLock.unlock()
        SpaceZoomInput.releaseHeldKeys()
        if let source = runLoopSource {
            EventTapThread.overlay.remove(source: source)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<SpaceSwitchInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Same contract as KeyboardRemap: the common path does no locking,
        // logging, or store reads — a few ms here stalls all keyboard input.
        if type == .tapDisabledByTimeout {
            breaker.recordTrip()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel { return handleZoomScroll(event) }

        if type == .flagsChanged {
            if !event.flags.contains(.maskControl) {
                pendingLock.lock()
                zoomScroll = SpaceZoomScroll()
                pendingLock.unlock()
                DispatchQueue.main.async { [weak self] in self?.navigator.release() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        // Our own re-posted fallback chord and synthetic keys from the remap
        // layer pass straight through.
        if event.getIntegerValueField(.eventSourceUserData) == WindowTiler.spaceShortcutSyntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if SpaceCanvasKeyboard.shared.handle(key: keyCode, pressed: type == .keyDown,
            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags) {
            return nil
        }
        if [27, 24, 125, 126].contains(keyCode) {
            return handleZoomKey(type: type, event: event, keyCode: keyCode)
        }
        guard keyCode == 123 || keyCode == 124 else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            pendingLock.lock()
            let owned = ownedArrows.remove(keyCode) != nil
            let released = ownedArrows.isEmpty
            pendingLock.unlock()
            if owned {
                if released { DispatchQueue.main.async { [weak self] in self?.navigator.release(control: false) } }
                return nil
            }
        }

        // Releasing Ctrl commits selection, but the arrow is still ours until
        // key-up. Don't leak its remaining repeats into the foreground app.
        if type == .keyDown, !event.flags.contains(.maskControl),
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            pendingLock.lock()
            let owned = ownedArrows.contains(keyCode)
            pendingLock.unlock()
            if owned { return nil }
        }

        // Bare Ctrl switches. Ctrl+Shift is the same switch plus the landscape
        // of every Space. Ctrl+Opt stays the tiling chord. maskSecondaryFn and
        // maskNumericPad are NOT rejected — real arrow keys carry them.
        let flags = event.flags
        guard flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              !flags.contains(.maskAlternate) else {
            return Unmanaged.passUnretained(event)
        }
        let landscape = flags.contains(.maskShift)

        // Swallow both halves of the press so Mission Control never sees it.
        if type == .keyDown {
            // Keyboard events normally carry the cursor location; if one
            // arrives empty, nil falls through to the live mouse position.
            let point = event.location
            if landscape {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.navigator.cancel() else { return }
                    self.enqueue(offset: keyCode == 123 ? -1 : 1,
                                 point: point == .zero ? nil : point, landscape: true)
                }
            } else {
                pendingLock.lock()
                ownedArrows.insert(keyCode)
                pendingLock.unlock()
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let received = CACurrentMediaTime()
                DispatchQueue.main.async { [weak self] in
                    let started = CACurrentMediaTime()
                    self?.navigator.press(offset: keyCode == 123 ? -1 : 1, repeated: repeated,
                                          point: point == .zero ? nil : point)
                    DiagnosticLog.shared.info("SpaceFilmstrip: inputQueueMs=\(String(format: "%.2f", (started - received) * 1000)) readyMs=\(String(format: "%.2f", (CACurrentMediaTime() - received) * 1000)) repeated=\(repeated)")
                }
            }
        }
        return nil
    }

    /// Ctrl+↓/↑ enter the canvas from the strip, then zoom out/in within it.
    /// Ctrl+−/= zoom out/in. Claimed only while engaged and never with Shift,
    /// Option or Command, so Ctrl+_ and app shortcuts pass untouched.
    private func handleZoomKey(type: CGEventType, event: CGEvent, keyCode: Int64) -> Unmanaged<CGEvent>? {
        // Capture before checking engagement: teardown first dismisses the
        // surface, then invalidates this generation under the same lock.
        pendingLock.lock()
        let generation = zoomInputGeneration
        pendingLock.unlock()
        if type == .keyUp {
            pendingLock.lock()
            let owned = ownedZoomKeys.remove(keyCode) != nil
            pendingLock.unlock()
            // The shortcut lease outlives a canvas closed mid-press until here.
            if owned {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentZoomInput(generation) else { return }
                    SpaceZoomInput.setKeyHeld(keyCode, false)
                    SpaceZoomInput.onCanvasZoomKey?(keyCode, false, false)
                }
            }
            return owned ? nil : Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            pendingLock.lock()
            let owned = ownedZoomKeys.contains(keyCode)
            pendingLock.unlock()
            if owned { return nil }
        }
        let flags = event.flags
        guard flags.contains(.maskControl), !flags.contains(.maskCommand),
              !flags.contains(.maskAlternate), !flags.contains(.maskShift),
              SpaceZoomInput.engaged else {
            return Unmanaged.passUnretained(event)
        }
        pendingLock.lock()
        ownedZoomKeys.insert(keyCode)
        pendingLock.unlock()
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
        let point = event.location
        let received = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentZoomInput(generation) else { return }
            let started = CACurrentMediaTime()
            defer {
                DiagnosticLog.shared.info("SpaceZoom: inputQueueMs=\(String(format: "%.2f", (started - received) * 1000)) readyMs=\(String(format: "%.2f", (CACurrentMediaTime() - received) * 1000)) key=\(keyCode)")
            }
            SpaceZoomInput.setKeyHeld(keyCode, true)
            let canvas = SpaceZoomInput.canvasEngaged
            let out = SpaceZoomKey.zoomsOut(keyCode: keyCode, canvas: canvas)
            DiagnosticLog.shared.info("SpaceZoom: key=\(keyCode) canvas=\(canvas) out=\(out)")
            if canvas {
                if let zoomKey = SpaceZoomInput.onCanvasZoomKey { zoomKey(keyCode, true, false) }
                else { SpaceZoomInput.onCanvasZoom?(out, SpaceZoomKey.exitsAtMinimum(keyCode: keyCode)) }
            } else if SpaceSwitchBezel.acceptsZoom {
                self.navigator.zoom(out: out, point: point == .zero ? nil : point)
                SpaceZoomInput.onCanvasZoomKey?(keyCode, true, true)
            }
        }
        return nil
    }

    private func isCurrentZoomInput(_ generation: UInt64) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return generation == zoomInputGeneration
    }

    private func handleZoomScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        guard flags.contains([.maskControl, .maskAlternate]),
              !flags.contains(.maskCommand), !flags.contains(.maskShift) else { return Unmanaged.passUnretained(event) }
        let began = event.getIntegerValueField(.scrollWheelEventScrollPhase) & 1 != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let time = ProcessInfo.processInfo.systemUptime
        if SpaceZoomInput.canvasEngaged {
            // The gesture that opened the canvas must finish before its
            // remaining deltas can start moving the new canvas camera.
            pendingLock.lock()
            let tail = zoomScroll.consumeTail(began: began, momentum: momentum, time: time)
            pendingLock.unlock()
            return tail ? nil : Unmanaged.passUnretained(event)
        }
        let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let delta = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
        pendingLock.lock()
        let step = zoomScroll.step(delta: delta, precise: precise, began: began, momentum: momentum, time: time)
        pendingLock.unlock()
        // Cancel an armed placement hold even before crossing the threshold.
        // Releasing a tiny scroll must never apply a window-placement preview.
        DispatchQueue.main.async { [weak self] in self?.cancelPlacementPreview() }
        if let out = step {
            let point = event.location
            DispatchQueue.main.async { [weak self] in
                if out { self?.openCanvas(from: point) }
            }
        }
        return nil
    }

    private func enqueue(offset: Int, point: CGPoint?, landscape: Bool) {
        pendingLock.lock()
        pendingOffset += offset
        pendingPoint = point
        pendingLandscape = pendingLandscape || landscape
        let schedule = !drainScheduled
        drainScheduled = true
        pendingLock.unlock()
        if schedule {
            switchQueue.async { [weak self] in self?.drainPending() }
        }
    }

    private func drainPending() {
        while true {
            pendingLock.lock()
            let offset = pendingOffset
            let point = pendingPoint
            let landscape = pendingLandscape
            pendingOffset = 0
            pendingLandscape = false
            if offset == 0 {
                drainScheduled = false
                pendingLock.unlock()
                // Correct a miss once the queue is idle, never mid-burst:
                // the next merged press already plans from where we are.
                if missedSinceSettle {
                    missedSinceSettle = false
                    DispatchQueue.main.async { SpaceSwitchBezel.shared.settleOnCurrentSpace() }
                }
                return
            }
            pendingLock.unlock()
            // A held chord can keep this work item alive for seconds. Release
            // temporary Cocoa objects per drain, not when the queue goes idle.
            autoreleasepool {
                performSwitch(offset: offset, point: point, landscape: landscape)
            }
        }
    }

    private func performSwitch(offset: Int, point: CGPoint?, landscape: Bool) {
        let started = ProcessInfo.processInfo.systemUptime
        guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: offset, from: point),
              !plan.isEdge else { return }
        defer {
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            DiagnosticLog.shared.info("SpaceSwitch: offset=\(offset) elapsedMs=\(Int(ms))")
        }

        guard landscape else {
            let direction = plan.offset < 0 ? -1 : 1
            let glide = {
                DispatchQueue.main.async {
                    SpaceSwitchGlide.shared.fire(direction: direction, steps: abs(plan.offset))
                }
            }

            // The target is known before the swipe runs, so confirm it now
            // rather than after the ~150ms+ switch; correct only on a miss.
            WindowTiler.presentSpaceSwitchBezel(for: plan, switched: true, holding: true)
            defer {
                DispatchQueue.main.async { SpaceSwitchBezel.shared.finishSwitch() }
            }

            // Streaks start once the cut is on screen — fired earlier, the
            // update freeze would swallow their first frames.
            var fired = false
            let switched = WindowTiler.performSpaceSwitch(plan) {
                fired = true
                glide()
            }
            // A slow landing can post its system Space change after the
            // switch returns; keep that from reading as a foreign switch.
            WindowTiler.noteProgrammaticSwitch()
            if !switched {
                // Most misses are late landings. Showing the mid-transition
                // Space now yanked the strip back, then forward again.
                missedSinceSettle = true
            } else if !fired {
                glide()
            }
            return
        }

        // Space membership doesn't change when the switch lands, so the
        // strip can paint from a WindowServer read taken now, with the
        // target highlighted, instead of waiting out the switch.
        let windows = DesktopModel.shared.spaceMembershipSnapshot()
        showLandscape(plan: plan, activeSpaceId: plan.targetSpaceId ?? plan.currentSpaceId, windows: windows)
        if !plan.isEdge, !WindowTiler.performSpaceSwitch(plan) {
            showLandscape(plan: plan, activeSpaceId: plan.currentSpaceId, windows: windows)
        }
    }

    private func showLandscape(plan: WindowTiler.SpaceSwitchPlan, activeSpaceId: Int, windows: [WindowEntry]) {
        DispatchQueue.main.async {
            SpaceNumberMark.shared.refresh()
            SpaceSwitchBezel.shared.dismiss()
            SpaceLandscape.shared.show(
                direction: plan.offset < 0 ? -1 : 1,
                display: plan.display,
                activeSpaceId: activeSpaceId,
                windows: windows,
                on: WindowTiler.screen(for: plan)
            )
        }
    }
}
