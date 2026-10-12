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
/// pass straight through.
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

    /// Presses not yet handed to the switch queue. Guarded by `pendingLock`;
    /// written on the tap thread, drained on `switchQueue`.
    private let pendingLock = NSLock()
    private var pendingOffset = 0
    private var pendingPoint: CGPoint?
    private var pendingLandscape = false
    private var drainScheduled = false

    private init() {
        breaker.onStateChanged = { [weak self] newState in
            self?.breakerState = newState
            self?.refresh()
        }
    }

    func start() {
        isRunning = true
        installObserversIfNeeded()
        refresh()
    }

    func stop() {
        isRunning = false
        refresh()
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

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        // Our own re-posted fallback chord and synthetic keys from the remap
        // layer pass straight through.
        if event.getIntegerValueField(.eventSourceUserData) == WindowTiler.spaceShortcutSyntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 123 || keyCode == 124 else {
            return Unmanaged.passUnretained(event)
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
            enqueue(offset: keyCode == 123 ? -1 : 1, point: point == .zero ? nil : point, landscape: landscape)
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
                return
            }
            pendingLock.unlock()
            performSwitch(offset: offset, point: point, landscape: landscape)
        }
    }

    private func performSwitch(offset: Int, point: CGPoint?, landscape: Bool) {
        guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: offset, from: point) else { return }

        guard landscape else {
            let direction = plan.offset < 0 ? -1 : 1
            let glide = { (edge: Bool) in
                DispatchQueue.main.async {
                    SpaceSwitchGlide.shared.fire(direction: direction, steps: abs(plan.offset), edge: edge)
                }
            }

            // The target is known before the swipe runs, so confirm it now
            // rather than after the ~150ms+ switch; correct only on a miss.
            WindowTiler.presentSpaceSwitchBezel(for: plan, switched: !plan.isEdge)
            if plan.isEdge {
                glide(true)
                return
            }

            // Streaks start once the cut is on screen — fired earlier, the
            // update freeze would swallow their first frames.
            var fired = false
            let switched = WindowTiler.performSpaceSwitch(plan) {
                fired = true
                glide(false)
            }
            if !switched {
                WindowTiler.presentSpaceSwitchBezel(for: plan, switched: false)
            } else if !fired {
                glide(false)
            }
            return
        }

        // Space membership doesn't change when the switch lands, so the
        // strip can paint from a WindowServer read taken now, with the
        // target highlighted, instead of waiting out the switch.
        let windows = DesktopModel.shared.spaceMembershipSnapshot()
        showLandscape(plan: plan, activeSpaceId: plan.targetSpaceId ?? plan.currentSpaceId, edge: plan.isEdge, windows: windows)
        if !plan.isEdge, !WindowTiler.performSpaceSwitch(plan) {
            showLandscape(plan: plan, activeSpaceId: plan.currentSpaceId, edge: true, windows: windows)
        }
    }

    private func showLandscape(plan: WindowTiler.SpaceSwitchPlan, activeSpaceId: Int, edge: Bool, windows: [WindowEntry]) {
        DispatchQueue.main.async {
            SpaceNumberMark.shared.refresh()
            SpaceSwitchBezel.shared.dismiss()
            SpaceLandscape.shared.show(
                direction: plan.offset < 0 ? -1 : 1,
                display: plan.display,
                activeSpaceId: activeSpaceId,
                edge: edge,
                windows: windows,
                on: WindowTiler.screen(for: plan)
            )
        }
    }
}
