import AppKit
import Combine
import Carbon
import CoreGraphics

private enum MouseGestureAccessory {
    case mic

    var usesDesktopStatusSurface: Bool {
        switch self {
        case .mic:
            return true
        }
    }
}

private enum MouseGestureOverlayStyle: Equatable {
    case drawing
    case thinLine
    case thickLine
}

private enum MouseGestureVisualPhase: String {
    case started
    case updated
    case recognized
    case completed
}

/// Captured CGEvent fields safe to ferry across an async dispatch boundary.
/// CGEvent itself is reference-counted; the tap callback only borrows the
/// event for the duration of its return, so we copy what we need into a
/// value type before hopping to main.
private struct MouseEventSnapshot {
    let location: CGPoint
    let flags: CGEventFlags
    let buttonNumber: Int64
    let sourcePID: Int64

    var isHardwareHandoffChord: Bool {
        MouseHandoffGesture.qualifies(button: buttonNumber, flags: flags, sourcePID: sourcePID)
    }
}

private struct MouseGestureOverlayTheme {
    let graphite: NSColor
    let graphiteDark: NSColor
    let accent: NSColor
    let highlight: NSColor
    let failure: NSColor

    static let technical = MouseGestureOverlayTheme(
        graphite: NSColor(calibratedRed: 0.66, green: 0.69, blue: 0.73, alpha: 1.0),
        graphiteDark: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1.0),
        accent: NSColor(calibratedRed: 0.34, green: 0.78, blue: 1.0, alpha: 1.0),
        highlight: NSColor(calibratedRed: 0.82, green: 0.94, blue: 1.0, alpha: 1.0),
        failure: NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.42, alpha: 1.0)
    )

    static let sober = MouseGestureOverlayTheme(
        graphite: NSColor(calibratedRed: 0.70, green: 0.72, blue: 0.75, alpha: 1.0),
        graphiteDark: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1.0),
        accent: NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.92, alpha: 1.0),
        highlight: NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1.0),
        failure: NSColor(calibratedRed: 0.92, green: 0.45, blue: 0.38, alpha: 1.0)
    )

    static func theme(for style: MouseGestureHUDStyle) -> MouseGestureOverlayTheme {
        switch style {
        case .technical:
            return .technical
        case .sober, .ink:
            return .sober
        }
    }
}

private struct MouseGestureSystemCaption: Equatable {
    let title: String
    let detail: String
}

final class MouseGestureController: ObservableObject {
    static let shared = MouseGestureController()

    /// Live state of the event-tap circuit breaker. SettingsView observes
    /// this to surface "paused" / "disabled" status and a re-arm button.
    @Published private(set) var breakerState: EventTapBreaker.State = .armed

    private var windowMoveInProgress = false

    private struct GestureOutcome {
        let label: String
        let success: Bool
        let accessory: MouseGestureAccessory?
        let caption: MouseGestureSystemCaption?

        init(
            label: String,
            success: Bool,
            accessory: MouseGestureAccessory?,
            caption: MouseGestureSystemCaption? = nil
        ) {
            self.label = label
            self.success = success
            self.accessory = accessory
            self.caption = caption
        }
    }

    private final class GestureSession {
        let buttonNumber: Int64
        let startPoint: CGPoint
        private let makeOverlay: () -> MouseGestureOverlay
        private var existingOverlay: MouseGestureOverlay?
        var overlay: MouseGestureOverlay {
            if let existingOverlay { return existingOverlay }
            let created = makeOverlay()
            created.inkMenu = inkMenu
            existingOverlay = created
            return created
        }

        func dismissOverlay(immediately: Bool = false) {
            existingOverlay?.dismiss(immediately: immediately)
        }
        var currentPoint: CGPoint
        var lockedDirection: MouseGestureDirection?
        var pathPoints: [GesturePathPoint]
        var visual: MouseShortcutVisualDefinition?
        var handoffCandidate = false
        var handoffEligible = false
        var initialFlags: CGEventFlags = []
        var moveTarget: WindowEntry?
        var moveSourceSpaces: [Int] = []
        var inkMenu: MouseGestureInkMenu?
        var inkRecognizedCount = 0
        var canvasPull: SpaceCanvasPull?
        var hasShortcutRules = false

        init(buttonNumber: Int64, startPoint: CGPoint, makeOverlay: @escaping () -> MouseGestureOverlay) {
            self.buttonNumber = buttonNumber
            self.startPoint = startPoint
            self.makeOverlay = makeOverlay
            self.currentPoint = startPoint
            self.lockedDirection = nil
            self.pathPoints = [
                GesturePathPoint(point: startPoint, timestamp: Date().timeIntervalSinceReferenceDate)
            ]
            self.visual = nil
        }

        func recordPoint(_ point: CGPoint) {
            if let last = pathPoints.last {
                let dx = point.x - last.x
                let dy = point.y - last.y
                guard sqrt(dx * dx + dy * dy) >= 2 else { return }
            }
            pathPoints.append(GesturePathPoint(point: point, timestamp: Date().timeIntervalSinceReferenceDate))
        }
    }

    private static let syntheticMarker: Int64 = 0x4C474D47

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installedEventMask: CGEventMask = 0
    private var session: GestureSession?
    private var retainedOverlays: [ObjectIdentifier: MouseGestureOverlay] = [:]
    private var staleSessionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var installedObservers = false
    private var frontmostApplicationObserver: NSObjectProtocol?
    private var healthTimer: Timer?
    private var lastObservedTapHealth: TapHealth?
    private let eventActivityLock = NSLock()
    private var lastEventReceivedAt: CFAbsoluteTime?
    private let shapeRecognizer = ShapeRecognizer()
    private let breaker = EventTapBreaker(label: "MouseGesture")
    private let budgetMeter = TapBudgetMeter(label: "MouseGesture")
    private let appStateLock = NSLock()
    private var frontmostBundleID: String?
    private let browserGestureIgnoredBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
    ]

    private struct TapHealth: Equatable {
        let installed: Bool
        let valid: Bool
        let enabled: Bool

        var summary: String {
            "installed=\(installed) valid=\(valid) enabled=\(enabled)"
        }
    }

    private struct TapTrackingState {
        let buttonNumber: Int64
        let startPoint: CGPoint
        let dragThreshold: CGFloat
        let axisBias: CGFloat
        let startedAt: CFAbsoluteTime
        let canvasCandidate: Bool
    }

    // Tap-thread-side mirror of "which button (if any) is currently being
    // tracked as a gesture". The tap callback runs on EventTapThread; main
    // owns the full GestureSession but the tap thread needs a fast,
    // synchronous answer to "should I consume this drag/up event?". Lock
    // protects cross-thread access (tap thread reads/writes; main writes
    // via clearSession(clearTracking:) or processMouseDownConsume's bail path).
    private let trackingLock = NSLock()
    private var tapTrackingState: TapTrackingState?
    private var lastTrackingStaleLogAt: CFAbsoluteTime = 0
    private let maxTapThreadTrackingDuration: TimeInterval = 3.0

    private func currentTrackingState() -> TapTrackingState? {
        trackingLock.lock()
        defer { trackingLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if let state = tapTrackingState,
           now - state.startedAt > maxTapThreadTrackingDuration,
           !(state.canvasCandidate && CGEventSource.buttonState(.combinedSessionState, button: .right)) {
            let staleButton = state.buttonNumber
            tapTrackingState = nil
            if now - lastTrackingStaleLogAt > 1 {
                lastTrackingStaleLogAt = now
                DispatchQueue.main.async {
                    DiagnosticLog.shared.warn("MouseGesture: stale tap-side tracking cleared for button=\(staleButton)")
                }
            }
            return nil
        }
        return tapTrackingState
    }

    private func setTrackingButton(
        _ value: Int64?,
        startPoint: CGPoint = .zero,
        tuning: MouseShortcutTuning = .defaults,
        canvasCandidate: Bool = false
    ) {
        trackingLock.lock()
        if let value {
            tapTrackingState = TapTrackingState(
                buttonNumber: value,
                startPoint: startPoint,
                dragThreshold: tuning.dragThreshold,
                axisBias: tuning.axisBias,
                startedAt: CFAbsoluteTimeGetCurrent(),
                canvasCandidate: canvasCandidate
            )
        } else {
            tapTrackingState = nil
        }
        trackingLock.unlock()
    }

    private init() {
        breaker.onStateChanged = { [weak self] newState in
            self?.breakerState = newState
        }
    }

    func start() {
        installObserversIfNeeded()
        refresh()
        startHealthMonitoring()
        if LogitechDeviceHandoff.isEnabled {
            DiagnosticLog.shared.info("Device handoff enabled: Control + right-drag left/right at least 68pt, release button and Control; paired channels cycle 1-2-3")
            LogitechDeviceHandoff.shared.inspectHardware()
        }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        clearSession()
        removeEventTap()
    }

    func resetForSystemInputBoundary(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let healthBeforeReset = currentTapHealth()
        clearSession()
        // Match KeyboardRemap: do not re-arm a tripped breaker on app activation
        // or Secure Event Input flaps — that reintroduces multi-second freezes.
        switch breaker.state {
        case .armed:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            } else {
                refresh()
            }
        case .paused, .disabled:
            DiagnosticLog.shared.warn(
                "MouseGesture: boundary '\(reason)' ignored re-arm — breaker is \(breaker.state) (before: \(healthBeforeReset.summary))"
            )
            return
        }
        let healthAfterReset = currentTapHealth()
        DiagnosticLog.shared.warn(
            "MouseGesture: reset for \(reason) (before: \(healthBeforeReset.summary); after: \(healthAfterReset.summary))"
        )
    }

    static func resolveDirection(
        delta: CGPoint,
        threshold: CGFloat = 68,
        axisBias: CGFloat = 1.2
    ) -> MouseGestureDirection? {
        let absX = abs(delta.x)
        let absY = abs(delta.y)
        guard max(absX, absY) >= threshold else { return nil }

        if absX >= absY * axisBias {
            return delta.x >= 0 ? .right : .left
        }

        if absY >= absX * axisBias {
            return delta.y >= 0 ? .down : .up
        }

        return nil
    }

    private func installObserversIfNeeded() {
        guard !installedObservers else { return }
        installedObservers = true

        Preferences.shared.$mouseGesturesEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        Preferences.shared.$spaceSwitchKeysEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        PermissionChecker.shared.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        MouseInputEventViewer.shared.$isCaptureActive
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        updateFrontmostApplicationSnapshot(NSWorkspace.shared.frontmostApplication)
        frontmostApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontmostApplicationSnapshot(app)
        }
    }

    private func refresh() {
        let shouldCapture = MouseInputEventViewer.shared.isCaptureActive || Preferences.shared.mouseGesturesEnabled
            || Preferences.shared.spaceSwitchKeysEnabled
        guard shouldCapture, PermissionChecker.shared.accessibility else {
            clearSession()
            removeEventTap()
            return
        }

        let desiredMask = desiredEventMask()
        // Never re-enable a tripped mouse tap from a casual refresh.
        switch breaker.state {
        case .paused, .disabled:
            return
        case .armed:
            break
        }
        if eventTap == nil {
            installEventTap(mask: desiredMask)
        } else if let eventTap {
            if installedEventMask != desiredMask {
                removeEventTap()
                installEventTap(mask: desiredMask)
            } else {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        }
    }

    private func startHealthMonitoring() {
        guard healthTimer == nil else { return }
        lastObservedTapHealth = currentTapHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.recordTapHealthIfChanged()
        }
    }

    private func currentTapHealth() -> TapHealth {
        guard let eventTap else {
            return TapHealth(installed: false, valid: false, enabled: false)
        }
        return TapHealth(
            installed: true,
            valid: CFMachPortIsValid(eventTap),
            enabled: CGEvent.tapIsEnabled(tap: eventTap)
        )
    }

    private func recordTapHealthIfChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        let health = currentTapHealth()
        guard health != lastObservedTapHealth else { return }
        let idleDescription: String
        eventActivityLock.lock()
        let lastEventReceivedAt = lastEventReceivedAt
        eventActivityLock.unlock()
        if let lastEventReceivedAt {
            idleDescription = String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - lastEventReceivedAt)
        } else {
            idleDescription = "no events observed"
        }
        DiagnosticLog.shared.warn(
            "MouseGesture: tap health changed -> \(health.summary); last event \(idleDescription) ago; breaker=\(breakerState)"
        )
        lastObservedTapHealth = health
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

    private func desiredEventMask() -> CGEventMask {
        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.rightMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseUp.rawValue
        return mask
    }

    private func installEventTap(mask: CGEventMask) {
        // Fresh install is a clean slate — drop any stale trip history so
        // the new tap's first failure is judged on its own merits.
        breaker.reset()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            DiagnosticLog.shared.warn("MouseGesture: failed to install mouse shortcut event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        installedEventMask = mask

        if let source {
            EventTapThread.mouse.add(source: source)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        breaker.rearm = { [weak self] in
            guard let self, let tap = self.eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        DiagnosticLog.shared.info("MouseGesture: mouse shortcut event tap installed")
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            EventTapThread.mouse.remove(source: source)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        installedEventMask = 0
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<MouseGestureController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let started = CFAbsoluteTimeGetCurrent()
        eventActivityLock.lock()
        lastEventReceivedAt = started
        eventActivityLock.unlock()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
            budgetMeter.record(durationMs: elapsedMs)
        }

        if type == .tapDisabledByTimeout {
            // OS killed the tap because a callback was too slow. Run through
            // the breaker — it backs off in escalating cooldowns rather than
            // re-enabling immediately and getting killed again.
            breaker.recordTrip()
            DispatchQueue.main.async {
                DiagnosticLog.shared.warn("MouseGesture: tap disabled by timeout — breaker tripped")
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            // User-driven disable (rare). Re-enable directly, no cooldown.
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        if isEmergencyMouseReset(type: type, event: event) {
            setTrackingButton(nil)
            DispatchQueue.main.async { [weak self] in
                self?.clearSession()
                InputCaptureResetCenter.reset(reason: "Hyper mouse click")
            }
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        if buttonNumber < 1 {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown, .otherMouseDown:
            return handleMouseDown(event, buttonNumber: buttonNumber)
        case .rightMouseDragged, .otherMouseDragged:
            return handleMouseDragged(event, buttonNumber: buttonNumber)
        case .rightMouseUp, .otherMouseUp:
            return handleMouseUp(event, buttonNumber: buttonNumber)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Tap-thread dispatch
    //
    // handle* methods run on EventTapThread. They compute the consume/pass
    // verdict from cheap, thread-safe reads, capture the event into a
    // MouseEventSnapshot, and hand the heavy work to main async — so a slow
    // main thread never adds latency to mouse events at the head-insert tap.

    private func isEmergencyMouseReset(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .otherMouseDown:
            return event.flags.intersection(.latticesHyper) == .latticesHyper
        default:
            return false
        }
    }

    private func updateFrontmostApplicationSnapshot(_ app: NSRunningApplication?) {
        appStateLock.lock()
        frontmostBundleID = app?.bundleIdentifier
        appStateLock.unlock()
    }

    private func frontmostAppShouldBypassGestures() -> Bool {
        appStateLock.lock()
        defer { appStateLock.unlock() }
        guard let frontmostBundleID else { return false }
        return browserGestureIgnoredBundleIDs.contains(frontmostBundleID)
    }

    private func handleMouseDown(_ event: CGEvent, buttonNumber: Int64) -> Unmanaged<CGEvent>? {
        let snapshot = MouseEventSnapshot(
            location: event.location,
            flags: event.flags,
            buttonNumber: buttonNumber,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )
        // NSScreen.screens reads are safe off-main; Preferences/Store snapshot
        // reads are lock-protected (see MouseShortcutStore).
        let tuning = MouseShortcutStore.shared.tuning
        let canvasCandidate = Preferences.shared.spaceSwitchKeysEnabled && !SpaceZoomInput.canvasEngaged
            && SpaceCanvasPull.accepts(button: buttonNumber, flags: snapshot.flags)
        let canRecognize = canvasCandidate || (Preferences.shared.mouseGesturesEnabled
            && (MouseShortcutStore.shared.watchedButtonNumbers.contains(buttonNumber)
                || (LogitechDeviceHandoff.isEnabled && snapshot.isHardwareHandoffChord)))
        let onScreen = (screen(containing: snapshot.location) != nil)

        if !onScreen {
            DispatchQueue.main.async { [weak self] in
                self?.processMouseDownPassthrough(snapshot: snapshot, reason: .offScreen)
            }
            return Unmanaged.passUnretained(event)
        }
        if !canRecognize {
            DispatchQueue.main.async { [weak self] in
                self?.processMouseDownPassthrough(snapshot: snapshot, reason: .notMapped)
            }
            return Unmanaged.passUnretained(event)
        }

        // Browser apps own side-button navigation and middle-click tab
        // behavior. Consume the stroke like anywhere else; if it releases
        // without a direction, processMouseUp replays a synthetic click via
        // replayMouseClick. (Passing the real down through and balancing it
        // with a synthetic up on lock proved fatal: the injected up moves the
        // OS button state to "released", so the physical release is deduped
        // and never reaches this tap — the gesture can only go stale.)
        let ignoredFrontmostApp = frontmostAppShouldBypassGestures()

        // Mark this button as actively tracked before the OS sees a follow-up
        // drag/up — the tap thread reads this on subsequent events to decide
        // whether to consume them.
        setTrackingButton(
            buttonNumber,
            startPoint: snapshot.location,
            tuning: tuning,
            canvasCandidate: canvasCandidate
        )
        DispatchQueue.main.async { [weak self] in
            self?.processMouseDownConsume(
                snapshot: snapshot,
                ignoredFrontmostApp: ignoredFrontmostApp,
                canvasCandidate: canvasCandidate
            )
        }
        return nil
    }

    private enum MouseDownPassthroughReason {
        case offScreen
        case notMapped
        case ignoredApp
    }

    private func processMouseDownPassthrough(snapshot: MouseEventSnapshot, reason: MouseDownPassthroughReason) {
        dispatchPrecondition(condition: .onQueue(.main))
        let button = MouseShortcutButton(rawButtonNumber: Int(snapshot.buttonNumber))
        let appInfo = currentAppInfo()
        switch reason {
        case .offScreen:
            DiagnosticLog.shared.info("MouseGesture: ignored click at \(format(snapshot.location)) (off-screen)")
            recordObservedEvent(
                phase: "down",
                button: button,
                location: snapshot.location,
                delta: .zero,
                modifiers: snapshot.flags,
                candidate: nil,
                match: nil,
                note: "off-screen",
                appInfo: appInfo
            )
            clearSession()
        case .notMapped:
            recordObservedEvent(
                phase: "down",
                button: button,
                location: snapshot.location,
                delta: .zero,
                modifiers: snapshot.flags,
                candidate: nil,
                match: nil,
                note: "button not mapped",
                appInfo: appInfo
            )
        case .ignoredApp:
            recordObservedEvent(
                phase: "down",
                button: button,
                location: snapshot.location,
                delta: .zero,
                modifiers: snapshot.flags,
                candidate: nil,
                match: nil,
                note: "frontmost app ignored",
                appInfo: appInfo
            )
            DiagnosticLog.shared.info("MouseGesture: bypassed \(button.triggerToken) for \(appInfo.bundleId ?? "unknown app")")
        }
    }

    private func processMouseDownConsume(snapshot: MouseEventSnapshot, ignoredFrontmostApp: Bool, canvasCandidate: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        MouseShortcutStore.shared.reloadIfNeeded()
        let button = MouseShortcutButton(rawButtonNumber: Int(snapshot.buttonNumber))
        let appInfo = currentAppInfo()

        guard let screen = screen(containing: snapshot.location) else {
            // Screens changed between tap-thread verdict and main; treat as
            // off-screen and clear the tap-side tracking we eagerly set.
            setTrackingButton(nil)
            recordObservedEvent(
                phase: "down",
                button: button,
                location: snapshot.location,
                delta: .zero,
                modifiers: snapshot.flags,
                candidate: nil,
                match: nil,
                note: "off-screen (post-dispatch)",
                appInfo: appInfo
            )
            clearSession()
            return
        }

        clearSession(clearTracking: false)
        // Ordinary right-clicks and canvas pulls never need an ink window.
        // Allocate it only once an existing shortcut actually draws feedback.
        let hudStyle = Preferences.shared.mouseGestureHUDStyle
        let newSession = GestureSession(buttonNumber: snapshot.buttonNumber, startPoint: snapshot.location) { [weak self] in
            let overlay = MouseGestureOverlay(screen: screen, hudStyle: hudStyle)
            overlay.onDismiss = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.releaseOverlay(overlay)
            }
            return overlay
        }
        newSession.handoffCandidate = LogitechDeviceHandoff.isEnabled && snapshot.isHardwareHandoffChord
        newSession.handoffEligible = newSession.handoffCandidate
        newSession.initialFlags = snapshot.flags
        if snapshot.flags.contains(.maskShift) {
            newSession.moveTarget = DesktopModel.shared.liveFrontWindow(at: snapshot.location)
            if let target = newSession.moveTarget {
                newSession.moveSourceSpaces = WindowTiler.getSpacesForWindow(target.wid)
            }
        }
        newSession.canvasPull = canvasCandidate ? SpaceCanvasPull() : nil
        newSession.hasShortcutRules = Preferences.shared.mouseGesturesEnabled
            && MouseShortcutStore.shared.watchedButtonNumbers.contains(snapshot.buttonNumber)
        newSession.visual = MouseShortcutStore.shared.visualHint(for: button)
        if Preferences.shared.mouseGestureHUDStyle == .ink {
            let menu = MouseGestureInkMenu.build(
                rules: MouseShortcutStore.shared.enabledRules,
                button: button,
                device: nil,
                threshold: MouseShortcutStore.shared.tuning.dragThreshold,
                flags: snapshot.flags
            )
            newSession.inkMenu = menu
        }
        session = newSession
        scheduleStaleSessionCleanup(for: newSession)
        DiagnosticLog.shared.info("MouseGesture: began at \(format(snapshot.location)) button=\(snapshot.buttonNumber)")
        recordObservedEvent(
            phase: "down",
            button: button,
            location: snapshot.location,
            delta: .zero,
            modifiers: snapshot.flags,
            candidate: nil,
            match: nil,
            note: ignoredFrontmostApp ? "tracking; browser click replays on release" : "tracking",
            appInfo: appInfo
        )
    }

    private func handleMouseDragged(_ event: CGEvent, buttonNumber: Int64) -> Unmanaged<CGEvent>? {
        guard let trackingState = currentTrackingState(),
              trackingState.buttonNumber == buttonNumber else {
            return Unmanaged.passUnretained(event)
        }
        let snapshot = MouseEventSnapshot(
            location: event.location,
            flags: event.flags,
            buttonNumber: buttonNumber,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )

        DispatchQueue.main.async { [weak self] in
            self?.processMouseDragged(snapshot: snapshot)
        }
        return nil
    }

    private func processMouseDragged(snapshot: MouseEventSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session, session.buttonNumber == snapshot.buttonNumber else {
            return
        }
        MouseShortcutStore.shared.reloadIfNeeded()

        session.currentPoint = snapshot.location
        session.handoffEligible = session.handoffEligible && snapshot.isHardwareHandoffChord
        session.recordPoint(snapshot.location)
        scheduleStaleSessionCleanup(for: session)
        let button = MouseShortcutButton(rawButtonNumber: Int(snapshot.buttonNumber))
        let delta = CGPoint(
            x: snapshot.location.x - session.startPoint.x,
            y: snapshot.location.y - session.startPoint.y
        )
        if session.canvasPull?.update(delta: delta, flags: snapshot.flags) == true {
            session.dismissOverlay(immediately: true)
            DiagnosticLog.shared.info("SpaceCanvas: right pull opened at \(format(session.startPoint))")
            SpaceSwitchInterceptor.shared.openCanvas(from: session.startPoint)
        }
        if session.canvasPull?.opened == true { return }
        // The plain right-button candidate is silent until it becomes a
        // deliberate pull. Existing mapped strokes keep their own feedback.
        if session.canvasPull != nil && !session.hasShortcutRules { return }
        let tuning = MouseShortcutStore.shared.tuning
        let direction = Self.resolveDirection(delta: delta, threshold: tuning.dragThreshold, axisBias: tuning.axisBias)
        updateInkCandidate(for: session)

        if direction != session.lockedDirection {
            session.lockedDirection = direction
            if let direction {
                let triggerEvent = MouseShortcutTriggerEvent(button: button, kind: .drag, direction: direction, device: nil)
                let match = MouseShortcutStore.shared.match(for: triggerEvent)
                DiagnosticLog.shared.info("MouseGesture: locked \(label(for: direction)) via \(triggerEvent.triggerName)")
                recordObservedEvent(
                    phase: "drag",
                    button: button,
                    location: snapshot.location,
                    delta: delta,
                    modifiers: snapshot.flags,
                    candidate: triggerEvent.triggerName,
                    match: match,
                    note: match == nil ? "no rule" : "candidate",
                    appInfo: currentAppInfo()
                )
            }
        }

        if let direction {
            let dominantDistance = max(abs(delta.x), abs(delta.y))
            let previewProgress = previewProgress(
                dominantDistance: dominantDistance,
                threshold: tuning.dragThreshold
            )
            session.overlay.track(
                origin: session.startPoint,
                direction: direction,
                label: nil,
                style: overlayStyle(for: button),
                visual: session.visual,
                visualPhase: .updated,
                shape: nil,
                success: nil,
                pathPoints: session.pathPoints,
                progress: previewProgress
            )
        } else {
            session.overlay.track(
                origin: session.startPoint,
                direction: nil,
                label: nil,
                style: overlayStyle(for: button),
                visual: session.visual,
                visualPhase: .updated,
                shape: nil,
                success: nil,
                pathPoints: session.pathPoints,
                progress: 0
            )
        }
    }

    /// Ink names the shape while it is drawn: confirmed once the recognizer
    /// would fire it, a guess from the first strokes before that.
    private func updateInkCandidate(for session: GestureSession) {
        guard let menu = session.inkMenu, !menu.shapes.isEmpty,
              session.pathPoints.count - session.inkRecognizedCount >= 2 else { return }
        session.inkRecognizedCount = session.pathPoints.count
        let shape = shapeRecognizer.recognize(points: session.pathPoints).shape
        if let shape, menu.shapes[shape] != nil {
            session.overlay.inkCandidate = MouseGestureInkCandidate(shape: shape, confirmed: true)
        } else {
            let guess = MouseGestureInkPredictor.predict(points: session.pathPoints.map(\.cgPoint), menu: menu)
            session.overlay.inkCandidate = guess.map { MouseGestureInkCandidate(shape: $0, confirmed: false) }
        }
    }

    private func handleMouseUp(_ event: CGEvent, buttonNumber: Int64) -> Unmanaged<CGEvent>? {
        let snapshot = MouseEventSnapshot(
            location: event.location,
            flags: event.flags,
            buttonNumber: buttonNumber,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )
        guard let trackingState = currentTrackingState(),
              trackingState.buttonNumber == buttonNumber else {
            DispatchQueue.main.async { [weak self] in
                self?.processMouseUpNoSession(snapshot: snapshot)
                if self?.session != nil {
                    DiagnosticLog.shared.warn("MouseGesture: mouseUp for untracked button=\(buttonNumber) while a session is live — release escaped tracking")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Clear tap-side tracking so a subsequent drag/up for this button
        // falls through.
        setTrackingButton(nil)
        DispatchQueue.main.async { [weak self] in
            self?.processMouseUp(snapshot: snapshot)
        }
        return nil
    }

    private func processMouseUpNoSession(snapshot: MouseEventSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordObservedEvent(
            phase: "up",
            button: MouseShortcutButton(rawButtonNumber: Int(snapshot.buttonNumber)),
            location: snapshot.location,
            delta: .zero,
            modifiers: snapshot.flags,
            candidate: nil,
            match: nil,
            note: "no active session",
            appInfo: currentAppInfo()
        )
    }

    private func processMouseUp(snapshot: MouseEventSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        MouseShortcutStore.shared.reloadIfNeeded()
        let button = MouseShortcutButton(rawButtonNumber: Int(snapshot.buttonNumber))
        let appInfo = currentAppInfo()

        guard let session, session.buttonNumber == snapshot.buttonNumber else {
            // Session was cleared between the tap-thread dispatch and now.
            DiagnosticLog.shared.warn("MouseGesture: mouseUp dropped — session already cleared for button=\(snapshot.buttonNumber)")
            return
        }
        session.currentPoint = snapshot.location
        session.recordPoint(snapshot.location)

        let delta = CGPoint(
            x: snapshot.location.x - session.startPoint.x,
            y: snapshot.location.y - session.startPoint.y
        )
        let tuning = MouseShortcutStore.shared.tuning
        let direction = Self.resolveDirection(delta: delta, threshold: tuning.dragThreshold, axisBias: tuning.axisBias)
        self.session = nil
        staleSessionTimer?.invalidate()
        staleSessionTimer = nil

        if let pull = session.canvasPull {
            if pull.opened {
                session.dismissOverlay(immediately: true)
                // Consume release without choosing, replaying a context menu,
                // or firing a second configured gesture behind the canvas.
                return
            }
            if !session.hasShortcutRules {
                session.dismissOverlay(immediately: true)
                replayRightStroke(session: session, end: snapshot.location, flags: snapshot.flags)
                return
            }
        }

        if session.handoffCandidate {
            session.dismissOverlay(immediately: true)
            if session.handoffEligible && snapshot.isHardwareHandoffChord,
               let direction = MouseHandoffGesture.direction(delta: delta, threshold: tuning.dragThreshold) {
                // handleMouseUp already cleared tap tracking. Switch only after
                // physical release, never while right-button state is held.
                LogitechDeviceHandoff.shared.requestSwitch(direction: direction)
            } else {
                replayRightStroke(session: session, end: snapshot.location, flags: snapshot.flags)
            }
            return
        }

        let shapeResult = shapeRecognizer.recognize(points: session.pathPoints)
        if let shape = shapeResult.shape {
            let shapeTrigger = MouseShortcutTriggerEvent(button: button, kind: .shape, shape: shape)
            let shapeMatch = MouseShortcutStore.shared.match(for: shapeTrigger)
            if let shapeMatch {
                let commitDirection = shapeResult.segments.last?.direction ?? direction ?? .right
                let dismissBeforeAction = shouldDismissOverlayBeforeAction(match: shapeMatch)
                if dismissBeforeAction {
                    session.dismissOverlay(immediately: true)
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !dismissBeforeAction {
                        self.retainOverlay(session.overlay)
                    }
                    let outcome = await self.performAction(match: shapeMatch, session: session)
                    DiagnosticLog.shared.info("MouseGesture: \(shape.displayName) -> \(outcome.label) -> \(outcome.success ? "ok" : "blocked")")
                    self.recordObservedEvent(
                        phase: "up",
                        button: button,
                        location: snapshot.location,
                        delta: delta,
                        modifiers: snapshot.flags,
                        candidate: shapeTrigger.triggerName,
                        match: shapeMatch,
                        note: "shape fired confidence=\(String(format: "%.2f", Double(shapeResult.confidence)))",
                        appInfo: appInfo
                    )
                    if !dismissBeforeAction {
                        self.retainOverlay(session.overlay)
                        session.overlay.commit(
                            origin: session.startPoint,
                            direction: commitDirection,
                            label: outcome.label,
                            success: outcome.success,
                            style: self.overlayStyle(for: button),
                            visual: shapeMatch.rule.visual ?? session.visual,
                            visualPhase: .completed,
                            shape: shape,
                            segments: shapeResult.segments,
                            pathPoints: session.pathPoints,
                            accessory: outcome.accessory,
                            caption: outcome.caption
                        )
                    }
                }
                return
            }
        }

        guard let direction else {
            let clickTrigger = MouseShortcutTriggerEvent(button: button, kind: .click, direction: nil, device: nil)
            let clickMatch = MouseShortcutStore.shared.match(for: clickTrigger)
            DiagnosticLog.shared.info("MouseGesture: released without a gesture at \(format(snapshot.location))")
            recordObservedEvent(
                phase: "up",
                button: button,
                location: snapshot.location,
                delta: delta,
                modifiers: snapshot.flags,
                candidate: clickMatch != nil ? clickTrigger.triggerName : nil,
                match: clickMatch,
                note: clickMatch != nil ? "click action" : "replay click",
                appInfo: appInfo
            )
            if let clickMatch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    session.dismissOverlay(immediately: true)
                    let outcome = await self.performAction(match: clickMatch, session: session)
                    DiagnosticLog.shared.info("MouseGesture: \(outcome.label) -> \(outcome.success ? "ok" : "blocked")")
                }
            } else {
                Task { @MainActor [weak self] in
                    session.dismissOverlay()
                    self?.replayMouseClick(
                        buttonNumber: snapshot.buttonNumber,
                        at: session.startPoint,
                        flags: snapshot.flags
                    )
                }
            }
            return
        }

        let triggerEvent = MouseShortcutTriggerEvent(button: button, kind: .drag, direction: direction, device: nil)
        let match = MouseShortcutStore.shared.match(for: triggerEvent)
        let dismissBeforeAction = shouldDismissOverlayBeforeAction(match: match)
        if dismissBeforeAction {
            session.dismissOverlay(immediately: true)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !dismissBeforeAction {
                self.retainOverlay(session.overlay)
            }
            let outcome = await self.performAction(match: match, session: session)
            DiagnosticLog.shared.info("MouseGesture: \(outcome.label) -> \(outcome.success ? "ok" : "blocked")")
            self.recordObservedEvent(
                phase: "up",
                button: button,
                location: snapshot.location,
                delta: delta,
                modifiers: snapshot.flags,
                candidate: triggerEvent.triggerName,
                match: match,
                note: outcome.success ? "fired" : "blocked",
                appInfo: appInfo
            )
            if !dismissBeforeAction {
                self.retainOverlay(session.overlay)
                session.overlay.commit(
                    origin: session.startPoint,
                    direction: direction,
                    label: outcome.label,
                    success: outcome.success,
                    style: self.overlayStyle(for: button),
                    visual: match?.rule.visual ?? session.visual,
                    visualPhase: .completed,
                    shape: nil,
                    pathPoints: session.pathPoints,
                    accessory: outcome.accessory,
                    caption: outcome.caption
                )
            }
        }
    }

    @MainActor
    private func performAction(match: MouseShortcutMatchResult?, session: GestureSession) async -> GestureOutcome {
        guard let match else {
            return GestureOutcome(label: "No Shortcut Assigned", success: false, accessory: nil)
        }

        let steps = match.rule.effectiveActions
        let outcome = await executeSingleAction(steps[0], session: session)
        for step in steps.dropFirst() {
            await executeSingleAction(step, session: session)
        }
        return outcome
    }

    @MainActor
    @discardableResult
    private func executeSingleAction(_ action: MouseShortcutActionDefinition, session: GestureSession) async -> GestureOutcome {
        if let offset = MouseGestureSpaceMove.offset(for: action.type, flags: session.initialFlags) {
            return await moveWindowViaGesture(offset: offset, session: session)
        }
        let startPoint = session.startPoint
        switch action.type {
        case .spacePrevious:
            return switchSpaceViaGesture(offset: -1, label: "Previous Space", startPoint: startPoint)
        case .spaceNext:
            return switchSpaceViaGesture(offset: 1, label: "Next Space", startPoint: startPoint)
        case .screenMapToggle:
            ScreenMapWindowController.shared.showScreenMapOverview()
            return GestureOutcome(label: "Screen Map Overview", success: true, accessory: nil)
        case .dictationStart:
            let sent = sendVoiceCommandShortcut()
            let shouldRenderHUD = Preferences.shared.mouseGestureHUDVisualEnabled
            if sent, Preferences.shared.mouseGestureHUDAudioEnabled {
                AppFeedback.shared.playTapSound()
            }
            return GestureOutcome(
                label: sent ? "Dictation" : "Permission Needed",
                success: sent,
                accessory: sent && shouldRenderHUD ? .mic : nil,
                caption: shouldRenderHUD ? MouseGestureSystemCaption(
                    title: "MOUSE GESTURE · UP · MIDDLE CLICK",
                    detail: sent ? "ACTION INITIATED · DICTATION ENGINE" : "ACTION BLOCKED · PERMISSION REQUIRED"
                ) : nil
            )
        case .shortcutSend:
            let sent = sendShortcut(action.shortcut)
            return GestureOutcome(
                label: sent ? action.label : "Shortcut Blocked",
                success: sent,
                accessory: nil
            )
        case .appActivate:
            let activated = activateApplication(named: action.app)
            let appLabel = action.app?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GestureOutcome(
                label: activated ? "\(appLabel?.isEmpty == false ? appLabel! : "App") Focused" : "App Activation Blocked",
                success: activated,
                accessory: nil
            )
        }
    }

    @MainActor
    private func moveWindowViaGesture(offset: Int, session: GestureSession) async -> GestureOutcome {
        func blocked(_ label: String) -> GestureOutcome {
            GestureOutcome(label: label, success: false, accessory: nil)
        }
        guard !windowMoveInProgress else { return blocked("Window move in progress") }
        guard let window = session.moveTarget else { return blocked("No window under pointer") }
        let sourceSpaces = session.moveSourceSpaces
        guard sourceSpaces.count == 1,
              WindowTiler.getSpacesForWindow(window.wid) == sourceSpaces,
              let display = WindowTiler.getDisplaySpaces().first(where: { display in
                  display.spaces.contains(where: { $0.id == sourceSpaces[0] })
              }) else { return blocked("Window is no longer on its desktop") }
        guard let destination = MouseGestureSpaceMove.destination(
            in: display.spaces.map(\.id), sourceSpaces: sourceSpaces, offset: offset
        ) else { return blocked(offset > 0 ? "No next desktop" : "No previous desktop") }

        windowMoveInProgress = true
        defer { windowMoveInProgress = false }
        // Mission Control must not pick up the gesture HUD as a window.
        session.dismissOverlay(immediately: true)
        let result: Result<JSON, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result {
                    try ActionRuntime.shared.executeWindowMove(
                        params: .object(["wid": .int(Int(window.wid)), "spaceId": .int(destination)]),
                        source: "mouse-gesture", target: window, followWindow: true
                    )
                })
            }
        }
        switch result {
        case .success(let receipt):
            guard receipt["verified"]?.boolValue == true else {
                let reason = receipt["message"]?.stringValue ?? receipt["failureReason"]?.stringValue ?? "Window move blocked"
                DiagnosticLog.shared.warn("MouseGesture: window move blocked: \(reason)")
                return blocked(reason)
            }
            guard receipt["followed"]?.boolValue == true else {
                return blocked("Window moved, but desktop switch failed")
            }
            return GestureOutcome(label: offset > 0 ? "Moved to next desktop" : "Moved to previous desktop", success: true, accessory: nil)
        case .failure(let error):
            DiagnosticLog.shared.warn("MouseGesture: window move failed: \(error.localizedDescription)")
            return blocked("Window move failed")
        }
    }

    /// Space switches via gesture fire the same bezel as the Ctrl+arrow path so
    /// both entry points confirm where you landed. Edge bumps get the dimmed
    /// amber state instead of silently returning "No … Space".
    private func switchSpaceViaGesture(offset: Int, label: String, startPoint: CGPoint) -> GestureOutcome {
        let outcome = WindowTiler.switchToAdjacentSpaceWithOutcome(offset: offset, from: startPoint)
        guard let plan = outcome.plan, outcome.switched || plan.isEdge else {
            return GestureOutcome(label: "\(label) Blocked", success: false, accessory: nil)
        }
        WindowTiler.presentSpaceSwitchBezel(for: plan, switched: outcome.switched)
        return GestureOutcome(
            label: outcome.switched ? label : "No \(label)",
            success: outcome.switched,
            accessory: nil
        )
    }

    private func label(for direction: MouseGestureDirection) -> String {
        switch direction {
        case .left:
            return "Previous Space"
        case .right:
            return "Next Space"
        case .up:
            return "Up"
        case .down:
            return "Screen Map Overview"
        }
    }

    private func overlayStyle(for button: MouseShortcutButton) -> MouseGestureOverlayStyle {
        switch button {
        case .button4:
            return .thinLine
        case .button5:
            return .thickLine
        case .middle:
            return .drawing
        case .right, .number:
            return .drawing
        }
    }

    private func clearSession(clearTracking: Bool = true) {
        staleSessionTimer?.invalidate()
        staleSessionTimer = nil
        session?.dismissOverlay(immediately: true)
        session = nil
        // Keep tap-side tracking in sync with main-side session lifetime so a
        // subsequent drag/up isn't consumed for a session that no longer
        // exists.
        if clearTracking {
            setTrackingButton(nil)
        }
    }

    private func replayMouseClick(buttonNumber: Int64, at point: CGPoint, flags: CGEventFlags) {
        let types: [CGEventType] = buttonNumber == 1 ? [.rightMouseDown, .rightMouseUp] : [.otherMouseDown, .otherMouseUp]
        for type in types {
            guard let mouseButton = CGMouseButton(rawValue: UInt32(buttonNumber)) else { continue }
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            ) else { continue }

            event.setIntegerValueField(CGEventField.mouseEventButtonNumber, value: buttonNumber)
            event.setIntegerValueField(CGEventField.eventSourceUserData, value: Self.syntheticMarker)
            event.flags = flags
            event.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    private func replayRightStroke(session: GestureSession, end: CGPoint, flags: CGEventFlags) {
        var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.rightMouseDown, session.startPoint, session.initialFlags)]
        // Preserve an unrecognized stroke's path. The replay marker bypasses
        // this controller; a plain click has no intervening drag samples.
        events += session.pathPoints.dropFirst().map { (.rightMouseDragged, $0.cgPoint, flags) }
        events.append((.rightMouseUp, end, flags))
        for (type, point, modifiers) in events {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .right) else { continue }
            event.flags = modifiers
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func screen(containing cgPoint: CGPoint) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsPoint = NSPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        return NSScreen.screens.first(where: { $0.frame.contains(nsPoint) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func format(_ point: CGPoint) -> String {
        "\(Int(point.x)),\(Int(point.y))"
    }

    private func shouldDismissOverlayBeforeAction(match: MouseShortcutMatchResult?) -> Bool {
        false
    }

    private func previewProgress(dominantDistance: CGFloat, threshold: CGFloat) -> CGFloat {
        guard dominantDistance > threshold else { return 0 }
        let overshoot = dominantDistance - threshold
        let normalized = min(1, max(0, overshoot / 90))
        return 0.32 + normalized * 0.68
    }

    private func retainOverlay(_ overlay: MouseGestureOverlay) {
        retainedOverlays[ObjectIdentifier(overlay)] = overlay
    }

    private func releaseOverlay(_ overlay: MouseGestureOverlay) {
        retainedOverlays.removeValue(forKey: ObjectIdentifier(overlay))
    }

    private func scheduleStaleSessionCleanup(for session: GestureSession) {
        staleSessionTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, self.session === session else { return }
            if session.canvasPull != nil, CGEventSource.buttonState(.combinedSessionState, button: .right) {
                self.scheduleStaleSessionCleanup(for: session)
                return
            }
            DiagnosticLog.shared.warn("MouseGesture: stale gesture session dismissed")
            self.clearSession()
        }
        staleSessionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func currentAppInfo() -> (name: String?, bundleId: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    private func recordObservedEvent(
        phase: String,
        button: MouseShortcutButton,
        location: CGPoint,
        delta: CGPoint,
        modifiers: CGEventFlags,
        candidate: String?,
        match: MouseShortcutMatchResult?,
        note: String?,
        appInfo: (name: String?, bundleId: String?)
    ) {
        guard MouseInputEventViewer.shared.isCaptureActive else { return }
        let sourceState = Int(modifiers.rawValue)
        MouseInputEventViewer.shared.record(
            MouseShortcutObservedEvent(
                timestamp: Date(),
                phase: phase,
                buttonNumber: button.rawButtonNumber,
                location: location,
                delta: delta,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers.rawValue)),
                frontmostAppName: appInfo.name,
                frontmostBundleId: appInfo.bundleId,
                candidateTrigger: candidate,
                device: nil,
                matchedRuleSummary: match?.rule.summary,
                willFire: match != nil,
                note: note.map { "\($0) | flags=\(sourceState)" } ?? "flags=\(sourceState)"
            )
        )
    }

    private func sendShortcut(_ shortcut: MouseShortcutKeyStroke?) -> Bool {
        guard let shortcut else { return false }
        if sendShortcutWithCGEvent(shortcut) {
            return true
        }

        let modifiers = shortcut.modifiers.map(\.appleScriptToken).joined(separator: ", ")
        let command: String

        if let keyCode = shortcut.keyCode {
            command = modifiers.isEmpty
                ? "key code \(keyCode)"
                : "key code \(keyCode) using {\(modifiers)}"
        } else if let key = shortcut.key {
            command = modifiers.isEmpty
                ? "keystroke \"\(key)\""
                : "keystroke \"\(key)\" using {\(modifiers)}"
        } else {
            return false
        }

        let script = """
        tell application "System Events"
            \(command)
        end tell
        return "ok"
        """
        let result = ProcessQuery.shell(["/usr/bin/osascript", "-e", script])
        if result != "ok" {
            DiagnosticLog.shared.warn("MouseGesture: AppleScript shortcut send failed for \(shortcut.displayLabel)")
        }
        return result == "ok"
    }

    private func sendVoiceCommandShortcut() -> Bool {
        guard let binding = HotkeyStore.shared.bindings[.voiceCommand] else { return false }
        return sendShortcut(
            MouseShortcutKeyStroke(
                key: KeyBinding.keyName(for: binding.keyCode),
                keyCode: Int(binding.keyCode),
                modifiers: mouseModifiers(from: binding.carbonModifiers)
            )
        )
    }

    private func mouseModifiers(from carbonModifiers: UInt32) -> [MouseShortcutModifier] {
        var modifiers: [MouseShortcutModifier] = []
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.append(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.append(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.append(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.append(.command) }
        return modifiers
    }

    private func sendShortcutWithCGEvent(_ shortcut: MouseShortcutKeyStroke) -> Bool {
        guard let keyCode = shortcut.keyCode.map(CGKeyCode.init) ?? keyCode(for: shortcut.key) else {
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            DiagnosticLog.shared.warn("MouseGesture: CGEvent shortcut source unavailable for \(shortcut.displayLabel)")
            return false
        }

        let flags = cgEventFlags(for: shortcut.modifiers)
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func cgEventFlags(for modifiers: [MouseShortcutModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .shift:
                flags.insert(.maskShift)
            }
        }
        return flags
    }

    private func keyCode(for key: String?) -> CGKeyCode? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else {
            return nil
        }
        let codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36,
            "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
            "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53,
            "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return codes[key]
    }

    private func activateApplication(named appName: String?) -> Bool {
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: { app in
            app.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame
                || app.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) {
            return running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        let fileManager = FileManager.default
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appFilenames = trimmedName.hasSuffix(".app") ? [trimmedName] : [trimmedName + ".app", trimmedName]
        let roots = [
            "/Applications",
            "/System/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]

        for root in roots {
            for filename in appFilenames {
                let url = URL(fileURLWithPath: root).appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
        }

        _ = ProcessQuery.shell(["/usr/bin/open", "-a", trimmedName])
        return true
    }
}

private final class MouseGestureOverlay {
    private let committedHoldDuration: TimeInterval = 0.42
    private let fadeDuration: TimeInterval = 0.18
    private let accessoryCommittedHoldDuration: TimeInterval = 0.64
    private let accessoryAnimationDuration: TimeInterval = 0.38

    private let screen: NSScreen
    private let window: NSWindow
    private let overlayView: MouseGestureOverlayView
    private var fadeTimer: Timer?
    var onDismiss: (() -> Void)?

    init(screen: NSScreen, hudStyle: MouseGestureHUDStyle) {
        self.screen = screen
        self.window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.overlayView = MouseGestureOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            hudStyle: hudStyle
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = overlayView
        // Ordered in on first draw, not here: every gesture-button press
        // makes an overlay, and a plain click never draws.
    }

    deinit {
        window.orderOut(nil)
    }

    func track(
        origin: CGPoint,
        direction: MouseGestureDirection?,
        label: String?,
        style: MouseGestureOverlayStyle,
        visual: MouseShortcutVisualDefinition?,
        visualPhase: MouseGestureVisualPhase,
        shape: GestureShapeLabel?,
        success: Bool?,
        pathPoints: [GesturePathPoint],
        progress: CGFloat
    ) {
        fadeTimer?.invalidate()
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
        let localPath = localPath(from: pathPoints)
        if direction != nil || localPath.count > 1 {
            overlayView.state = .tracking(
                origin: localPoint(from: origin),
                direction: direction,
                label: label,
                style: style,
                visual: visual,
                visualPhase: visualPhase,
                shape: shape,
                success: success,
                path: localPath,
                progress: progress
            )
        } else {
            overlayView.state = .idle
        }
        overlayView.requestDisplay()
    }

    var inkMenu: MouseGestureInkMenu? {
        get { overlayView.inkMenu }
        set { overlayView.inkMenu = newValue }
    }

    var inkCandidate: MouseGestureInkCandidate? {
        get { overlayView.inkCandidate }
        set {
            guard overlayView.inkCandidate != newValue else { return }
            overlayView.inkCandidate = newValue
            overlayView.requestDisplay()
        }
    }

    func commit(
        origin: CGPoint,
        direction: MouseGestureDirection,
        label: String,
        success: Bool,
        style: MouseGestureOverlayStyle,
        visual: MouseShortcutVisualDefinition?,
        visualPhase: MouseGestureVisualPhase,
        shape: GestureShapeLabel?,
        segments: [DirectionSegment] = [],
        pathPoints: [GesturePathPoint],
        accessory: MouseGestureAccessory?,
        caption: MouseGestureSystemCaption?
    ) {
        fadeTimer?.invalidate()
        overlayView.inkSegments = segments
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
        overlayView.state = .committed(
            origin: localPoint(from: origin),
            direction: direction,
            label: label,
            success: success,
            style: style,
            visual: visual,
            visualPhase: visualPhase,
            shape: shape,
            path: localPath(from: pathPoints),
            accessory: accessory,
            caption: caption,
            accessoryAnimationDuration: accessoryAnimationDuration
        )
        overlayView.requestDisplay()

        let postReplayHoldDuration = accessory == nil ? committedHoldDuration : accessoryCommittedHoldDuration
        let totalVisibleDuration = overlayView.replayLeadInDuration + postReplayHoldDuration
        let timer = Timer(timeInterval: totalVisibleDuration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss(immediately: Bool = false) {
        fadeTimer?.invalidate()
        fadeTimer = nil

        if immediately {
            window.orderOut(nil)
            finishDismissal()
            return
        }

        guard window.isVisible else {
            finishDismissal()
            return
        }

        // The window is captured strongly: a click-replay overlay can be
        // freed mid-fade, and a window left ordered in at the maximum level
        // on every Space turns Mission Control's thumbnails into wallpaper.
        let window = window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.finishDismissal()
        })
    }

    private func localPoint(from cgPoint: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let nsY = primaryHeight - cgPoint.y
        return CGPoint(x: cgPoint.x - screen.frame.minX, y: nsY - screen.frame.minY)
    }

    private func localPath(from pathPoints: [GesturePathPoint]) -> [CGPoint] {
        pathPoints.map { localPoint(from: $0.cgPoint) }
    }

    private func finishDismissal() {
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

private final class MouseGestureOverlayView: NSView {
    private let hudStyle: MouseGestureHUDStyle
    private let theme: MouseGestureOverlayTheme

    enum State {
        case idle
        case tracking(
            origin: CGPoint,
            direction: MouseGestureDirection?,
            label: String?,
            style: MouseGestureOverlayStyle,
            visual: MouseShortcutVisualDefinition?,
            visualPhase: MouseGestureVisualPhase,
            shape: GestureShapeLabel?,
            success: Bool?,
            path: [CGPoint],
            progress: CGFloat
        )
        case committed(
            origin: CGPoint,
            direction: MouseGestureDirection,
            label: String,
            success: Bool,
            style: MouseGestureOverlayStyle,
            visual: MouseShortcutVisualDefinition?,
            visualPhase: MouseGestureVisualPhase,
            shape: GestureShapeLabel?,
            path: [CGPoint],
            accessory: MouseGestureAccessory?,
            caption: MouseGestureSystemCaption?,
            accessoryAnimationDuration: TimeInterval
        )
    }

    var state: State = .idle {
        didSet {
            if hudStyle == .ink {
                updateInkAnimation(from: oldValue)
                return
            }
            updateArrowAnimation(from: oldValue, to: state)
            updateAccessoryAnimation()
        }
    }
    var inkMenu: MouseGestureInkMenu?
    var inkCandidate: MouseGestureInkCandidate?
    var inkSegments: [DirectionSegment] = []
    private var inkLink: CADisplayLink?
    private var inkCommittedAt: CFTimeInterval?
    /// The last area ink painted, so the next redraw can clear it.
    private var inkPainted: CGRect = .null
    private var accessoryAnimationTimer: Timer?
    private var accessoryAnimationStartedAt: Date?
    private var accessoryAnimationDuration: TimeInterval = 0
    private var arrowAnimationTimer: Timer?
    private var arrowAnimationStartedAt: Date?
    private var arrowAnimationDuration: TimeInterval = 0
    private var committedStartProgress: CGFloat = 0
    private var accessoryAnimationDelay: TimeInterval = 0
    private let committedArrowAnimationDuration: TimeInterval = 0.20
    private let matrixCompletionAnimationDuration: TimeInterval = 0.46
    private let arrowAnimationDelay: TimeInterval = 0.04
    private let labelRevealThreshold: CGFloat = 0.74

    init(frame frameRect: NSRect, hudStyle: MouseGestureHUDStyle) {
        self.hudStyle = hudStyle
        self.theme = MouseGestureOverlayTheme.theme(for: hudStyle)
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var replayLeadInDuration: TimeInterval {
        if hudStyle == .ink {
            return MouseGestureInkRenderer.commitDrawDuration + 0.2
        }
        if case .committed(_, _, _, _, _, let visual, _, let shape, let path, _, _, _) = state,
           shape != nil,
           path.count > 1,
           shouldDrawMatrixCompletion(visual) {
            return matrixCompletionAnimationDuration + 0.05
        }
        if committedStartProgress >= labelRevealThreshold {
            return 0
        }
        let remainingProgress = max(0, 1 - committedStartProgress)
        return arrowAnimationDelay + committedArrowAnimationDuration * remainingProgress
    }

    override var isFlipped: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            arrowAnimationTimer?.invalidate()
            arrowAnimationTimer = nil
            accessoryAnimationTimer?.invalidate()
            accessoryAnimationTimer = nil
            inkLink?.invalidate()
            inkLink = nil
        }
    }

    /// Ink redraws only around the gesture, never the whole screen.
    func requestDisplay() {
        guard hudStyle == .ink else {
            needsDisplay = true
            return
        }
        let area: CGRect
        switch state {
        case .idle:
            area = .null
        case .tracking(let origin, _, _, _, _, _, _, _, let path, _),
             .committed(let origin, _, _, _, _, _, _, _, let path, _, _, _):
            area = MouseGestureInkRenderer.extent(origin: origin, path: path, menu: inkMenu).integral
        }
        let dirty = area.union(inkPainted)
        inkPainted = area
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    private var inkProgress: CGFloat {
        let elapsed = inkCommittedAt.map { CACurrentMediaTime() - $0 } ?? .infinity
        return CGFloat(min(1, elapsed / MouseGestureInkRenderer.commitDrawDuration))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        if hudStyle == .ink {
            drawInk(in: ctx)
            return
        }

        switch state {
        case .idle:
            break
        case .tracking(let origin, let direction, let label, let style, let visual, let visualPhase, let shape, let success, let path, let progress):
            drawOrigin(at: origin, in: ctx, alpha: 0.88)
            if path.count > 1 {
                drawGesturePath(
                    path,
                    fallbackOrigin: origin,
                    direction: direction,
                    label: label,
                    success: true,
                    committed: false,
                    style: style,
                    accessory: nil,
                    progressOverride: progress,
                    in: ctx
                )
                drawVisualPOCIfNeeded(
                    visual,
                    phase: visualPhase,
                    shape: shape,
                    success: success,
                    points: path,
                    label: label,
                    in: ctx
                )
            } else if let direction {
                drawArrow(
                    from: origin,
                    direction: direction,
                    label: label,
                    success: true,
                    committed: false,
                    style: style,
                    accessory: nil,
                    progressOverride: progress,
                    in: ctx
                )
            }
        case .committed(let origin, let direction, let label, let success, let style, let visual, let visualPhase, let shape, let path, let accessory, let caption, _):
            if path.count > 1 {
                if shape != nil, shouldDrawMatrixCompletion(visual) {
                    drawMatrixGestureCompletion(
                        path,
                        label: label,
                        success: success,
                        direction: direction,
                        accessory: accessory,
                        in: ctx
                    )
                } else {
                    drawOrigin(at: origin, in: ctx, alpha: 1.0)
                    drawGesturePath(
                        path,
                        fallbackOrigin: origin,
                        direction: direction,
                        label: label,
                        success: success,
                        committed: true,
                        style: style,
                        accessory: accessory,
                        progressOverride: nil,
                        in: ctx
                    )
                }
                drawVisualPOCIfNeeded(
                    visual,
                    phase: visualPhase,
                    shape: shape,
                    success: success,
                    points: path,
                    label: label,
                    in: ctx
                )
            } else {
                drawOrigin(at: origin, in: ctx, alpha: 1.0)
                drawArrow(
                    from: origin,
                    direction: direction,
                    label: label,
                    success: success,
                    committed: true,
                    style: style,
                    accessory: accessory,
                    progressOverride: nil,
                    in: ctx
                )
            }
            if let accessory, accessory.usesDesktopStatusSurface {
                drawDesktopStatusSurface(for: accessory, label: label, success: success, in: ctx)
            }
            if let caption {
                drawSystemCaption(caption, success: success, in: ctx)
            }
        }
    }

    private func drawInk(in ctx: CGContext) {
        switch state {
        case .idle:
            break
        case .tracking(let origin, let direction, _, _, _, _, _, _, let path, _):
            MouseGestureInkRenderer.drawTracking(
                in: ctx,
                bounds: bounds,
                origin: origin,
                path: path,
                menu: inkMenu ?? MouseGestureInkMenu(),
                armed: direction,
                candidate: inkCandidate
            )
        case .committed(let origin, let direction, let label, let success, _, _, _, let shape, let path, _, _, _):
            MouseGestureInkRenderer.drawCommitted(
                in: ctx,
                bounds: bounds,
                origin: origin,
                path: path,
                menu: inkMenu,
                direction: direction,
                label: label,
                success: success,
                shape: shape,
                segments: inkSegments,
                progress: inkProgress
            )
        }
    }

    private func updateInkAnimation(from oldState: State) {
        guard isCommitted(state: state) else {
            inkLink?.invalidate()
            inkLink = nil
            inkCommittedAt = nil
            return
        }
        guard !isCommitted(state: oldState) else { return }
        inkCommittedAt = CACurrentMediaTime()
        inkLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(inkFrame(_:)))
        link.add(to: .main, forMode: .common)
        inkLink = link
    }

    @objc private func inkFrame(_ link: CADisplayLink) {
        requestDisplay()
        guard let startedAt = inkCommittedAt,
              CACurrentMediaTime() - startedAt < MouseGestureInkRenderer.commitDrawDuration else {
            link.invalidate()
            inkLink = nil
            return
        }
    }

    private func drawOrigin(at point: CGPoint, in ctx: CGContext, alpha: CGFloat) {
        ctx.setFillColor(NSColor(calibratedRed: 0.48, green: 0.76, blue: 1.0, alpha: alpha * 0.18).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))

        ctx.setFillColor(NSColor(calibratedRed: 0.62, green: 0.84, blue: 1.0, alpha: alpha * 0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
    }

    private func drawArrow(
        from origin: CGPoint,
        direction: MouseGestureDirection,
        label: String?,
        success: Bool,
        committed: Bool,
        style: MouseGestureOverlayStyle,
        accessory: MouseGestureAccessory?,
        progressOverride: CGFloat?,
        in ctx: CGContext
    ) {
        let baseLength: CGFloat = 134
        let arrowProgress = progressOverride ?? currentArrowProgress(committed: committed)
        let clampedProgress = min(1, max(0, arrowProgress))
        let length = baseLength * (committed ? max(0.14, clampedProgress) : (0.34 + 0.66 * clampedProgress))
        let vector = arrowVector(for: direction, length: length)
        let end = CGPoint(x: origin.x + vector.x, y: origin.y + vector.y)
        let accent = success
            ? NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
            : NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.42, alpha: 1.0)
        let strokeAlpha = committed ? 0.92 : (0.48 + 0.44 * clampedProgress)
        let glowAlpha = committed ? 0.2 : (0.08 + 0.08 * clampedProgress)
        let metrics = arrowMetrics(for: style)

        ctx.saveGState()
        ctx.setLineCap(.round)

        let glowPath = CGMutablePath()
        glowPath.move(to: origin)
        glowPath.addLine(to: end)
        ctx.addPath(glowPath)
        ctx.setLineWidth(metrics.glowWidth)
        ctx.setStrokeColor(accent.withAlphaComponent(glowAlpha).cgColor)
        ctx.strokePath()

        let linePath = CGMutablePath()
        linePath.move(to: origin)
        linePath.addLine(to: end)
        ctx.addPath(linePath)
        ctx.setLineWidth(metrics.lineWidth)
        ctx.setStrokeColor(accent.withAlphaComponent(strokeAlpha).cgColor)
        ctx.strokePath()

        drawArrowHead(at: end, direction: direction, color: accent, size: metrics.headSize)
        let drawsDesktopStatus = accessory?.usesDesktopStatusSurface ?? false
        if let label, !drawsDesktopStatus, (!committed || clampedProgress >= labelRevealThreshold) {
            drawLabel(label, from: origin, to: end, direction: direction, color: accent)
        }
        if committed, let accessory, !accessory.usesDesktopStatusSurface, clampedProgress >= labelRevealThreshold {
            drawAccessory(accessory, from: origin, to: end, direction: direction, color: accent, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawGesturePath(
        _ points: [CGPoint],
        fallbackOrigin: CGPoint,
        direction: MouseGestureDirection?,
        label: String?,
        success: Bool,
        committed: Bool,
        style: MouseGestureOverlayStyle,
        accessory: MouseGestureAccessory?,
        progressOverride: CGFloat?,
        in ctx: CGContext
    ) {
        guard points.count > 1 else { return }
        let accent = success ? theme.accent : theme.failure
        let stroke = success ? theme.graphite : theme.failure
        let metrics = arrowMetrics(for: style)
        let pathProgress = progressOverride ?? currentArrowProgress(committed: committed)
        let clampedProgress = min(1, max(0, pathProgress))
        let strokeAlpha = committed ? 0.92 : (0.48 + 0.44 * clampedProgress)
        let glowAlpha = committed ? 0.28 : (0.12 + 0.12 * clampedProgress)
        let visiblePoints = visiblePathPoints(points, progress: committed ? clampedProgress : 1)
        guard visiblePoints.count > 1 else { return }

        let path = smoothedGesturePath(from: visiblePoints)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if !committed {
            drawGestureGuideDots(around: visiblePoints, accent: accent, in: ctx)
        }

        ctx.addPath(path)
        ctx.setLineWidth(metrics.glowWidth + 10)
        ctx.setStrokeColor(theme.graphiteDark.withAlphaComponent(committed ? 0.44 : 0.30).cgColor)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setLineWidth(metrics.glowWidth)
        ctx.setStrokeColor(accent.withAlphaComponent(glowAlpha).cgColor)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setLineWidth(metrics.lineWidth)
        ctx.setStrokeColor(stroke.withAlphaComponent(strokeAlpha).cgColor)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setLineWidth(max(1, metrics.lineWidth * 0.28))
        ctx.setStrokeColor((success ? theme.highlight : accent).withAlphaComponent(success ? strokeAlpha * 0.62 : strokeAlpha).cgColor)
        ctx.strokePath()

        let end = visiblePoints.last ?? fallbackOrigin
        let resolvedDirection = direction ?? pathDirection(from: visiblePoints)
        if let resolvedDirection {
            drawArrowHead(at: end, direction: resolvedDirection, color: stroke, size: metrics.headSize)
            let drawsDesktopStatus = accessory?.usesDesktopStatusSurface ?? false
            if let label, !drawsDesktopStatus, (!committed || clampedProgress >= labelRevealThreshold) {
                drawLabel(label, from: fallbackOrigin, to: end, direction: resolvedDirection, color: accent)
            }
            if committed, let accessory, !accessory.usesDesktopStatusSurface, clampedProgress >= labelRevealThreshold {
                drawAccessory(accessory, from: fallbackOrigin, to: end, direction: resolvedDirection, color: accent, in: ctx)
            }
        }
        ctx.restoreGState()
    }

    private func drawMatrixGestureCompletion(
        _ points: [CGPoint],
        label: String,
        success: Bool,
        direction: MouseGestureDirection,
        accessory: MouseGestureAccessory?,
        in ctx: CGContext
    ) {
        guard points.count > 1 else { return }
        let progress = min(1, max(0, currentArrowProgress(committed: true)))
        let cleanedPoints = cleanedMatrixGesturePoints(points)
        let matrixRect = matrixGestureRect(for: cleanedPoints)
        let transformedPoints = transformGesturePoints(cleanedPoints, into: matrixRect.insetBy(dx: 16, dy: 16))
        let visiblePoints = visiblePathPoints(transformedPoints, progress: progress)
        let accent = success ? theme.accent : theme.failure
        let activeCells = matrixCellsTouched(by: visiblePoints, in: matrixRect)
        let pulsePoint = visiblePoints.last ?? transformedPoints.last ?? CGPoint(x: matrixRect.midX, y: matrixRect.midY)
        let completionAlpha = min(1, max(0, (progress - 0.68) / 0.22))

        ctx.saveGState()

        let halo = NSBezierPath(roundedRect: matrixRect.insetBy(dx: -9, dy: -9), xRadius: 16, yRadius: 16)
        theme.graphiteDark.withAlphaComponent(0.20 + 0.14 * completionAlpha).setFill()
        halo.fill()

        drawMatrixCells(
            in: matrixRect,
            activeCells: activeCells,
            completionAlpha: completionAlpha,
            accent: accent,
            success: success,
            context: ctx
        )

        if visiblePoints.count > 1 {
            let replayPath = smoothedGesturePath(from: visiblePoints)
            ctx.addPath(replayPath)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(14)
            ctx.setStrokeColor(accent.withAlphaComponent(0.16 + 0.16 * completionAlpha).cgColor)
            ctx.strokePath()

            ctx.addPath(replayPath)
            ctx.setLineWidth(5)
            ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
            ctx.strokePath()

            ctx.addPath(replayPath)
            ctx.setLineWidth(1.8)
            ctx.setStrokeColor(theme.highlight.withAlphaComponent(0.86).cgColor)
            ctx.strokePath()
        }

        let pulseRadius = 8 + 10 * easeOut(progress)
        ctx.setFillColor(accent.withAlphaComponent(0.18 * (1 - completionAlpha * 0.45)).cgColor)
        ctx.fillEllipse(in: CGRect(
            x: pulsePoint.x - pulseRadius,
            y: pulsePoint.y - pulseRadius,
            width: pulseRadius * 2,
            height: pulseRadius * 2
        ))
        ctx.setFillColor(theme.highlight.withAlphaComponent(0.96).cgColor)
        ctx.fillEllipse(in: CGRect(x: pulsePoint.x - 3, y: pulsePoint.y - 3, width: 6, height: 6))

        if completionAlpha > 0.1 {
            drawMatrixConfirmationGlyph(in: matrixRect, alpha: completionAlpha, accent: accent, context: ctx)
        }

        if progress >= 0.76 {
            let labelAlpha = min(1, max(0, (progress - 0.76) / 0.18))
            drawMatrixLabel(label, near: matrixRect, alpha: labelAlpha, accent: accent)
        }

        if let accessory, !accessory.usesDesktopStatusSurface, progress >= labelRevealThreshold {
            drawAccessory(accessory, from: CGPoint(x: matrixRect.midX, y: matrixRect.midY), to: pulsePoint, direction: direction, color: accent, in: ctx)
        }

        ctx.restoreGState()
    }

    private func drawMatrixCells(
        in rect: CGRect,
        activeCells: Set<Int>,
        completionAlpha: CGFloat,
        accent: NSColor,
        success: Bool,
        context ctx: CGContext
    ) {
        let cellSize: CGFloat = 13
        let gap: CGFloat = 7
        let gridSize = cellSize * 3 + gap * 2
        let startX = rect.midX - gridSize / 2
        let startY = rect.midY - gridSize / 2
        let logoCells: Set<Int> = [0, 3, 6, 7, 8]

        for row in 0..<3 {
            for col in 0..<3 {
                let idx = row * 3 + col
                let x = startX + CGFloat(col) * (cellSize + gap)
                let y = startY + CGFloat(row) * (cellSize + gap)
                let cellRect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                let isActive = activeCells.contains(idx)
                let isLogoCell = logoCells.contains(idx)
                let baseAlpha: CGFloat = isLogoCell ? 0.20 : 0.11
                let activeAlpha: CGFloat = success ? 0.88 : 0.70
                let snapAlpha = isLogoCell ? completionAlpha * 0.36 : 0
                let fillAlpha = max(baseAlpha + snapAlpha, isActive ? activeAlpha : baseAlpha)
                let fill = isActive ? accent : theme.highlight

                let glow = NSBezierPath(roundedRect: cellRect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6)
                accent.withAlphaComponent(isActive ? 0.14 : snapAlpha * 0.16).setFill()
                glow.fill()

                let cell = NSBezierPath(roundedRect: cellRect, xRadius: 3, yRadius: 3)
                fill.withAlphaComponent(fillAlpha).setFill()
                cell.fill()
            }
        }
    }

    private func drawMatrixConfirmationGlyph(in rect: CGRect, alpha: CGFloat, accent: NSColor, context ctx: CGContext) {
        let path = CGMutablePath()
        let x0 = rect.midX + 23
        let y0 = rect.midY + 22
        path.move(to: CGPoint(x: x0, y: y0))
        path.addLine(to: CGPoint(x: x0, y: rect.midY - 24))
        path.addLine(to: CGPoint(x: rect.midX - 23, y: rect.midY - 24))

        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(accent.withAlphaComponent(0.54 * alpha).cgColor)
        ctx.strokePath()

        let arrow = NSBezierPath()
        let end = CGPoint(x: rect.midX - 23, y: rect.midY - 24)
        arrow.move(to: end)
        arrow.line(to: CGPoint(x: end.x + 8, y: end.y + 6))
        arrow.move(to: end)
        arrow.line(to: CGPoint(x: end.x + 8, y: end.y - 6))
        accent.withAlphaComponent(0.70 * alpha).setStroke()
        arrow.lineWidth = 2
        arrow.lineCapStyle = .round
        arrow.stroke()
    }

    private func drawMatrixLabel(_ label: String, near rect: CGRect, alpha: CGFloat, accent: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let display = labelComponents(for: label).title
        let attributed = NSAttributedString(
            string: display,
            attributes: [
                .font: font,
                .foregroundColor: theme.highlight.withAlphaComponent(0.94 * alpha),
            ]
        )
        let size = attributed.size()
        let bubbleRect = CGRect(
            x: rect.midX - (size.width + 16) / 2,
            y: rect.minY - size.height - 13,
            width: size.width + 16,
            height: size.height + 7
        )
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 8, yRadius: 8)
        theme.graphiteDark.withAlphaComponent(0.78 * alpha).setFill()
        bubble.fill()
        accent.withAlphaComponent(0.38 * alpha).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
        attributed.draw(in: CGRect(
            x: bubbleRect.minX + 8,
            y: bubbleRect.minY + 3.5,
            width: size.width,
            height: size.height
        ))
    }

    private func cleanedMatrixGesturePoints(_ points: [CGPoint]) -> [CGPoint] {
        let simplified = simplifyGesturePoints(points, minimumDistance: 5)
        guard simplified.count > 2 else { return simplified }

        var cleaned: [CGPoint] = []
        for index in simplified.indices {
            let previous = simplified[max(index - 1, simplified.startIndex)]
            let current = simplified[index]
            let next = simplified[min(index + 1, simplified.index(before: simplified.endIndex))]
            cleaned.append(CGPoint(
                x: (previous.x + current.x * 2 + next.x) / 4,
                y: (previous.y + current.y * 2 + next.y) / 4
            ))
        }
        return cleaned
    }

    private func simplifyGesturePoints(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var result = [last]
        for point in points.dropFirst() {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if sqrt(dx * dx + dy * dy) >= minimumDistance {
                result.append(point)
                last = point
            }
        }
        if let final = points.last, result.last != final {
            result.append(final)
        }
        return result
    }

    private func matrixGestureRect(for points: [CGPoint]) -> CGRect {
        let end = points.last ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let size = CGSize(width: 88, height: 88)
        var origin = CGPoint(x: end.x + 24, y: end.y + 18)

        if origin.x + size.width > bounds.width - 12 {
            origin.x = end.x - size.width - 24
        }
        if origin.y + size.height > bounds.height - 12 {
            origin.y = end.y - size.height - 18
        }
        origin.x = min(max(origin.x, 12), max(12, bounds.width - size.width - 12))
        origin.y = min(max(origin.y, 12), max(12, bounds.height - size.height - 12))

        return CGRect(origin: origin, size: size)
    }

    private func transformGesturePoints(_ points: [CGPoint], into rect: CGRect) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? minX
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? minY
        let sourceWidth = max(maxX - minX, 1)
        let sourceHeight = max(maxY - minY, 1)
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let scaledWidth = sourceWidth * scale
        let scaledHeight = sourceHeight * scale
        let offsetX = rect.midX - scaledWidth / 2
        let offsetY = rect.midY - scaledHeight / 2

        return points.map { point in
            CGPoint(
                x: offsetX + (point.x - minX) * scale,
                y: offsetY + (point.y - minY) * scale
            )
        }
    }

    private func matrixCellsTouched(by points: [CGPoint], in rect: CGRect) -> Set<Int> {
        guard !points.isEmpty else { return [] }
        let cellSize: CGFloat = 13
        let gap: CGFloat = 7
        let gridSize = cellSize * 3 + gap * 2
        let startX = rect.midX - gridSize / 2
        let startY = rect.midY - gridSize / 2
        let step = cellSize + gap

        var touched = Set<Int>()
        for point in points {
            let col = min(2, max(0, Int(round((point.x - startX - cellSize / 2) / step))))
            let row = min(2, max(0, Int(round((point.y - startY - cellSize / 2) / step))))
            touched.insert(row * 3 + col)
        }
        return touched
    }

    private func drawGestureGuideDots(around points: [CGPoint], accent: NSColor, in ctx: CGContext) {
        guard !points.isEmpty else { return }
        let minX = (points.map(\.x).min() ?? 0) - 34
        let maxX = (points.map(\.x).max() ?? 0) + 34
        let minY = (points.map(\.y).min() ?? 0) - 34
        let maxY = (points.map(\.y).max() ?? 0) + 34
        let spacing: CGFloat = 34
        let dotRadius: CGFloat = 2.2
        let startX = floor(minX / spacing) * spacing
        let startY = floor(minY / spacing) * spacing

        var y = startY
        while y <= maxY {
            var x = startX
            while x <= maxX {
                let point = CGPoint(x: x, y: y)
                let distance = nearestDistance(from: point, to: points)
                let closeness = max(0, 1 - min(distance / 96, 1))
                let alpha = 0.08 + closeness * 0.20
                let radius = dotRadius + closeness * 1.2
                ctx.setFillColor(accent.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }

    private func nearestDistance(from point: CGPoint, to points: [CGPoint]) -> CGFloat {
        points.reduce(CGFloat.greatestFiniteMagnitude) { nearest, candidate in
            let dx = point.x - candidate.x
            let dy = point.y - candidate.y
            return min(nearest, sqrt(dx * dx + dy * dy))
        }
    }

    private func drawVisualPOCIfNeeded(
        _ visual: MouseShortcutVisualDefinition?,
        phase: MouseGestureVisualPhase,
        shape: GestureShapeLabel?,
        success: Bool?,
        points: [CGPoint],
        label: String?,
        in ctx: CGContext
    ) {
        guard let visual, visual.isLottiePOC, let end = points.last else { return }
        let marker = visual.marker(phase: phase.rawValue, shape: shape, success: success) ?? fallbackMarker(phase: phase, success: success)
        let previous = points.dropLast().last ?? end
        let velocity = CGPoint(x: end.x - previous.x, y: end.y - previous.y)
        let speed = min(1, sqrt(velocity.x * velocity.x + velocity.y * velocity.y) / 42)
        let anchor = CGPoint(x: end.x + 28, y: end.y + 22 - speed * 8)
        drawLottieCatPOC(marker: marker, at: anchor, velocity: velocity, label: label, in: ctx)
    }

    private func fallbackMarker(phase: MouseGestureVisualPhase, success: Bool?) -> String {
        switch phase {
        case .started:
            return "curious"
        case .updated:
            return "follow"
        case .recognized:
            return "pounce"
        case .completed:
            return success == false ? "confused" : "celebrate"
        }
    }

    private func drawLottieCatPOC(
        marker: String,
        at center: CGPoint,
        velocity: CGPoint,
        label: String?,
        in ctx: CGContext
    ) {
        let mood = marker.lowercased()
        let bodyColor = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 0.92)
        let faceColor = theme.highlight.withAlphaComponent(0.94)
        let accent = mood.contains("confused") ? theme.failure : theme.accent
        let tilt = max(-0.34, min(0.34, velocity.x / 160))
        let hop: CGFloat = mood.contains("pounce") || mood.contains("celebrate") ? 7 : 0
        let headCenter = CGPoint(x: center.x, y: center.y + hop)
        let headRadius: CGFloat = mood.contains("pounce") ? 16 : 14

        ctx.saveGState()
        ctx.translateBy(x: headCenter.x, y: headCenter.y)
        ctx.rotate(by: tilt)
        ctx.translateBy(x: -headCenter.x, y: -headCenter.y)

        ctx.setFillColor(theme.graphiteDark.withAlphaComponent(0.24).cgColor)
        ctx.fillEllipse(in: CGRect(x: headCenter.x - 22, y: headCenter.y - 18, width: 44, height: 36))

        let leftEar = CGMutablePath()
        leftEar.move(to: CGPoint(x: headCenter.x - 12, y: headCenter.y + 9))
        leftEar.addLine(to: CGPoint(x: headCenter.x - 7, y: headCenter.y + 25))
        leftEar.addLine(to: CGPoint(x: headCenter.x - 1, y: headCenter.y + 11))
        leftEar.closeSubpath()
        ctx.addPath(leftEar)
        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillPath()

        let rightEar = CGMutablePath()
        rightEar.move(to: CGPoint(x: headCenter.x + 12, y: headCenter.y + 9))
        rightEar.addLine(to: CGPoint(x: headCenter.x + 7, y: headCenter.y + 25))
        rightEar.addLine(to: CGPoint(x: headCenter.x + 1, y: headCenter.y + 11))
        rightEar.closeSubpath()
        ctx.addPath(rightEar)
        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillPath()

        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius, width: headRadius * 2, height: headRadius * 2))
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius, width: headRadius * 2, height: headRadius * 2))

        let eyeY = headCenter.y + 2
        let blink = mood.contains("pounce") || mood.contains("celebrate")
        drawCatEye(at: CGPoint(x: headCenter.x - 5, y: eyeY), blink: blink, color: faceColor, in: ctx)
        drawCatEye(at: CGPoint(x: headCenter.x + 5, y: eyeY), blink: blink, color: faceColor, in: ctx)

        ctx.setStrokeColor(faceColor.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(1)
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: headCenter.x - 3, y: headCenter.y - 5))
        mouth.addQuadCurve(to: CGPoint(x: headCenter.x + 3, y: headCenter.y - 5), control: CGPoint(x: headCenter.x, y: headCenter.y - (mood.contains("confused") ? 2 : 8)))
        ctx.addPath(mouth)
        ctx.strokePath()

        if mood.contains("celebrate"), let label {
            drawCatToast(label, near: CGPoint(x: headCenter.x + 18, y: headCenter.y + 18), color: accent)
        }

        ctx.restoreGState()
    }

    private func drawCatEye(at point: CGPoint, blink: Bool, color: NSColor, in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        if blink {
            ctx.setLineWidth(1.4)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: point.x - 2.4, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 2.4, y: point.y))
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.fillEllipse(in: CGRect(x: point.x - 1.7, y: point.y - 1.7, width: 3.4, height: 3.4))
        }
    }

    private func drawCatToast(_ label: String, near point: CGPoint, color: NSColor) {
        let shortLabel = label.replacingOccurrences(of: " Focused", with: "!")
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let attributed = NSAttributedString(
            string: shortLabel,
            attributes: [
                .font: font,
                .foregroundColor: theme.highlight.withAlphaComponent(0.96),
            ]
        )
        let size = attributed.size()
        let rect = CGRect(x: point.x, y: point.y, width: size.width + 12, height: size.height + 7)
        let bubble = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        theme.graphiteDark.withAlphaComponent(0.72).setFill()
        bubble.fill()
        color.withAlphaComponent(0.5).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
        attributed.draw(in: CGRect(x: rect.minX + 6, y: rect.minY + 3.5, width: size.width, height: size.height))
    }

    private func smoothedGesturePath(from points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            if let last = points.last {
                path.addLine(to: last)
            }
            return path
        }

        for index in 0..<(points.count - 1) {
            let previous = points[max(index - 1, 0)]
            let current = points[index]
            let next = points[index + 1]
            let nextNext = points[min(index + 2, points.count - 1)]
            let tension: CGFloat = 0.34
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) * tension,
                y: current.y + (next.y - previous.y) * tension
            )
            let control2 = CGPoint(
                x: next.x - (nextNext.x - current.x) * tension,
                y: next.y - (nextNext.y - current.y) * tension
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        return path
    }

    private func visiblePathPoints(_ points: [CGPoint], progress: CGFloat) -> [CGPoint] {
        guard progress < 1, points.count > 2 else { return points }
        let clamped = min(1, max(0.04, progress))
        let count = max(2, Int(ceil(CGFloat(points.count) * clamped)))
        return Array(points.prefix(count))
    }

    private func pathDirection(from points: [CGPoint]) -> MouseGestureDirection? {
        guard points.count >= 2 else { return nil }
        let window = points.suffix(min(6, points.count))
        guard let first = window.first, let last = window.last else { return nil }
        let delta = CGPoint(x: last.x - first.x, y: last.y - first.y)
        return MouseGestureController.resolveDirection(delta: delta, threshold: 4, axisBias: 1.0)
    }

    private func arrowMetrics(for style: MouseGestureOverlayStyle) -> (lineWidth: CGFloat, glowWidth: CGFloat, headSize: CGFloat) {
        switch style {
        case .thinLine:
            return (2.4, 7, 10)
        case .thickLine:
            return (8.5, 20, 18)
        case .drawing:
            return (3.2, 10, 12)
        }
    }

    private func drawArrowHead(at end: CGPoint, direction: MouseGestureDirection, color: NSColor, size: CGFloat) {
        let path = NSBezierPath()

        switch direction {
        case .left:
            path.move(to: CGPoint(x: end.x - size, y: end.y))
            path.line(to: CGPoint(x: end.x + size * 0.2, y: end.y + size * 0.72))
            path.line(to: CGPoint(x: end.x + size * 0.2, y: end.y - size * 0.72))
        case .right:
            path.move(to: CGPoint(x: end.x + size, y: end.y))
            path.line(to: CGPoint(x: end.x - size * 0.2, y: end.y + size * 0.72))
            path.line(to: CGPoint(x: end.x - size * 0.2, y: end.y - size * 0.72))
        case .up:
            path.move(to: CGPoint(x: end.x, y: end.y + size))
            path.line(to: CGPoint(x: end.x - size * 0.72, y: end.y - size * 0.2))
            path.line(to: CGPoint(x: end.x + size * 0.72, y: end.y - size * 0.2))
        case .down:
            path.move(to: CGPoint(x: end.x, y: end.y - size))
            path.line(to: CGPoint(x: end.x - size * 0.72, y: end.y + size * 0.2))
            path.line(to: CGPoint(x: end.x + size * 0.72, y: end.y + size * 0.2))
        }

        path.close()
        color.withAlphaComponent(0.96).setFill()
        path.fill()
    }

    private func drawLabel(_ label: String, from origin: CGPoint, to end: CGPoint, direction: MouseGestureDirection, color: NSColor) {
        let display = labelComponents(for: label)
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .heavy)
        let kickerFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: theme.highlight.withAlphaComponent(0.98),
        ]
        let kickerAttributes: [NSAttributedString.Key: Any] = [
            .font: kickerFont,
            .foregroundColor: color.withAlphaComponent(0.84),
        ]
        let title = NSAttributedString(string: display.title, attributes: titleAttributes)
        let kicker = display.kicker.map { NSAttributedString(string: $0, attributes: kickerAttributes) }
        let titleSize = title.size()
        let kickerSize = kicker?.size() ?? .zero
        let gap: CGFloat = kicker == nil ? 0 : 2
        let textSize = CGSize(
            width: max(titleSize.width, kickerSize.width),
            height: titleSize.height + gap + kickerSize.height
        )
        let paddingX: CGFloat = 18
        let paddingY: CGFloat = 11
        let tickWidth: CGFloat = 8
        let bubbleSize = CGSize(
            width: textSize.width + paddingX * 2 + tickWidth,
            height: textSize.height + paddingY * 2
        )
        let bubbleOrigin = labelOrigin(from: origin, to: end, direction: direction, bubbleSize: bubbleSize)
        let rect = CGRect(
            x: bubbleOrigin.x,
            y: bubbleOrigin.y,
            width: bubbleSize.width,
            height: bubbleSize.height
        )

        ctxSaveForLabel(rotationDegrees: -4, around: CGPoint(x: rect.midX, y: rect.midY))

        let shadowRect = rect.insetBy(dx: -7, dy: -7)
        let shadow = NSBezierPath(roundedRect: shadowRect, xRadius: 17, yRadius: 17)
        theme.graphiteDark.withAlphaComponent(0.24).setFill()
        shadow.fill()

        let bg = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        theme.graphiteDark.withAlphaComponent(0.82).setFill()
        bg.fill()

        let border = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        theme.graphite.withAlphaComponent(0.46).setStroke()
        border.lineWidth = 1.2
        border.stroke()

        let tickRect = CGRect(
            x: rect.minX + 10,
            y: rect.midY - 8,
            width: 3,
            height: 16
        )
        let tick = NSBezierPath(roundedRect: tickRect, xRadius: 1.5, yRadius: 1.5)
        color.withAlphaComponent(0.82).setFill()
        tick.fill()

        let titleRect = CGRect(
            x: rect.minX + paddingX + tickWidth,
            y: rect.minY + paddingY + kickerSize.height + gap,
            width: titleSize.width,
            height: titleSize.height
        )
        title.draw(in: titleRect)

        if let kicker {
            let kickerRect = CGRect(
                x: rect.minX + paddingX + tickWidth + 1,
                y: rect.minY + paddingY,
                width: kickerSize.width,
                height: kickerSize.height
            )
            kicker.draw(in: kickerRect)
        }

        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func labelComponents(for label: String) -> (title: String, kicker: String?) {
        if label.hasSuffix(" Focused") {
            return (String(label.dropLast(" Focused".count)), "FOCUSED")
        }
        return (label, nil)
    }

    private func ctxSaveForLabel(rotationDegrees: CGFloat, around center: CGPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotationDegrees * .pi / 180)
        ctx.translateBy(x: -center.x, y: -center.y)
    }

    private func labelOrigin(from origin: CGPoint, to end: CGPoint, direction: MouseGestureDirection, bubbleSize: CGSize) -> CGPoint {
        let midpoint = CGPoint(x: (origin.x + end.x) / 2, y: (origin.y + end.y) / 2)
        let proposedOrigin: CGPoint

        switch direction {
        case .left, .right:
            proposedOrigin = CGPoint(x: midpoint.x - bubbleSize.width / 2, y: midpoint.y + 30)
        case .up, .down:
            proposedOrigin = CGPoint(x: midpoint.x + 30, y: midpoint.y - bubbleSize.height / 2)
        }

        let minX: CGFloat = 20
        let minY: CGFloat = 20
        let maxX = max(minX, bounds.width - bubbleSize.width - 20)
        let maxY = max(minY, bounds.height - bubbleSize.height - 20)

        return CGPoint(
            x: min(max(proposedOrigin.x, minX), maxX),
            y: min(max(proposedOrigin.y, minY), maxY)
        )
    }

    private func arrowVector(for direction: MouseGestureDirection, length: CGFloat) -> CGPoint {
        switch direction {
        case .left:
            return CGPoint(x: -length, y: 0)
        case .right:
            return CGPoint(x: length, y: 0)
        case .up:
            return CGPoint(x: 0, y: length)
        case .down:
            return CGPoint(x: 0, y: -length)
        }
    }

    private func updateArrowAnimation(from oldState: State, to newState: State) {
        let oldDirection = stateDirection(from: oldState)
        let newDirection = stateDirection(from: newState)
        let oldCommitted = isCommitted(state: oldState)
        let newCommitted = isCommitted(state: newState)

        if newCommitted, newDirection != nil {
            let shouldRestart = oldDirection != newDirection || !oldCommitted
            if shouldRestart {
                let previousProgress = trackingProgress(from: oldState)
                let isMatrixReplay = isCommittedShapeReplay(state: newState)
                committedStartProgress = isMatrixReplay ? 0 : max(0, min(1, previousProgress ?? 0))
                if committedStartProgress >= 0.94 {
                    arrowAnimationTimer?.invalidate()
                    arrowAnimationTimer = nil
                    arrowAnimationStartedAt = nil
                    arrowAnimationDuration = 0
                    committedStartProgress = 1
                } else {
                    let duration = isMatrixReplay ? matrixCompletionAnimationDuration : committedArrowAnimationDuration
                    startArrowAnimation(duration: duration)
                }
            }
            return
        }

        arrowAnimationTimer?.invalidate()
        arrowAnimationTimer = nil
        arrowAnimationStartedAt = nil
        arrowAnimationDuration = 0
        committedStartProgress = 0
    }

    private func startArrowAnimation(duration: TimeInterval) {
        arrowAnimationTimer?.invalidate()
        arrowAnimationStartedAt = Date()
        arrowAnimationDuration = duration

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.needsDisplay = true
            let elapsed = Date().timeIntervalSince(self.arrowAnimationStartedAt ?? Date())
            if elapsed >= self.replayLeadInDuration {
                timer.invalidate()
                self.arrowAnimationTimer = nil
            }
        }
        arrowAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func currentArrowProgress(committed: Bool) -> CGFloat {
        guard committed,
              let startedAt = arrowAnimationStartedAt,
              arrowAnimationDuration > 0 else {
            return committed ? (committedStartProgress > 0 ? committedStartProgress : 1) : 1
        }

        let delayedElapsed = Date().timeIntervalSince(startedAt) - arrowAnimationDelay
        guard delayedElapsed > 0 else { return committedStartProgress }
        let normalized = min(1, max(0, delayedElapsed / arrowAnimationDuration))
        let animated = easeOut(normalized)
        return committedStartProgress + (1 - committedStartProgress) * animated
    }

    private func updateAccessoryAnimation() {
        accessoryAnimationTimer?.invalidate()
        accessoryAnimationTimer = nil
        accessoryAnimationStartedAt = nil
        accessoryAnimationDuration = 0
        accessoryAnimationDelay = 0

        if case .committed(_, _, _, _, _, _, _, _, _, let accessory, _, let duration) = state, accessory != nil {
            accessoryAnimationStartedAt = Date()
            accessoryAnimationDuration = duration
            accessoryAnimationDelay = replayLeadInDuration * 0.86
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.needsDisplay = true
                let elapsed = Date().timeIntervalSince(self.accessoryAnimationStartedAt ?? Date())
                if elapsed >= self.accessoryAnimationDelay + self.accessoryAnimationDuration {
                    timer.invalidate()
                    self.accessoryAnimationTimer = nil
                }
            }
            accessoryAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func drawAccessory(
        _ accessory: MouseGestureAccessory,
        from origin: CGPoint,
        to end: CGPoint,
        direction: MouseGestureDirection,
        color: NSColor,
        in ctx: CGContext
    ) {
        guard let startedAt = accessoryAnimationStartedAt, accessoryAnimationDuration > 0 else { return }
        let delayedElapsed = Date().timeIntervalSince(startedAt) - accessoryAnimationDelay
        guard delayedElapsed > 0 else { return }
        let progress = min(1, max(0, delayedElapsed / accessoryAnimationDuration))
        let scale = 0.82 + 0.18 * easeOut(progress)
        let fadeStart: CGFloat = 0.58
        let alphaProgress = progress <= fadeStart ? 1 : 1 - ((progress - fadeStart) / (1 - fadeStart))
        let alpha = max(0, min(1, alphaProgress))
        guard alpha > 0 else { return }

        let center = accessoryCenter(from: end, direction: direction)
        let badgeDiameter: CGFloat = 34 * scale
        let badgeRect = CGRect(
            x: center.x - badgeDiameter / 2,
            y: center.y - badgeDiameter / 2,
            width: badgeDiameter,
            height: badgeDiameter
        )

        let badge = NSBezierPath(ovalIn: badgeRect)
        NSColor.black.withAlphaComponent(0.46 * alpha).setFill()
        badge.fill()

        color.withAlphaComponent(0.32 * alpha).setStroke()
        badge.lineWidth = 1
        badge.stroke()

        switch accessory {
        case .mic:
            drawMicGlyph(in: badgeRect.insetBy(dx: badgeDiameter * 0.26, dy: badgeDiameter * 0.2), color: color.withAlphaComponent(0.96 * alpha), in: ctx)
        }
    }

    private func accessoryCenter(from end: CGPoint, direction: MouseGestureDirection) -> CGPoint {
        switch direction {
        case .up:
            return CGPoint(x: end.x, y: end.y + 34)
        case .down:
            return CGPoint(x: end.x, y: end.y - 34)
        case .left:
            return CGPoint(x: end.x - 34, y: end.y)
        case .right:
            return CGPoint(x: end.x + 34, y: end.y)
        }
    }

    private func committedSurfaceAlpha() -> CGFloat {
        let progress = currentArrowProgress(committed: true)
        return min(1, max(0, (progress - 0.70) / 0.18))
    }

    private func accessorySurfaceAlpha() -> CGFloat {
        guard let startedAt = accessoryAnimationStartedAt else {
            return committedSurfaceAlpha()
        }
        let elapsed = Date().timeIntervalSince(startedAt) - accessoryAnimationDelay
        guard elapsed > 0 else { return 0 }
        return min(1, max(0, easeOut(CGFloat(elapsed / 0.22))))
    }

    private func drawDesktopStatusSurface(
        for accessory: MouseGestureAccessory,
        label: String,
        success: Bool,
        in ctx: CGContext
    ) {
        switch accessory {
        case .mic:
            let alpha = max(committedSurfaceAlpha(), accessorySurfaceAlpha())
            guard alpha > 0.01 else { return }

            let isSober = hudStyle == .sober
            let accent = success ? theme.accent : theme.failure
            let panelWidth = min(max(bounds.width * (isSober ? 0.24 : 0.30), isSober ? 280 : 320), min(isSober ? 360 : 420, bounds.width - 72))
            let panelHeight: CGFloat = isSober ? 50 : 58
            let topInset: CGFloat = isSober ? 48 : 38
            let radius: CGFloat = isSober ? 10 : 14
            let rect = CGRect(
                x: bounds.midX - panelWidth / 2,
                y: bounds.maxY - topInset - panelHeight,
                width: panelWidth,
                height: panelHeight
            )

            let shell = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            theme.graphiteDark.withAlphaComponent((isSober ? 0.48 : 0.54) * alpha).setFill()
            shell.fill()

            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
            theme.highlight.withAlphaComponent((isSober ? 0.026 : 0.045) * alpha).setFill()
            inner.fill()

            let border = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            accent.withAlphaComponent((isSober ? 0.16 : 0.28) * alpha).setStroke()
            border.lineWidth = 1
            border.stroke()

            let iconSize: CGFloat = isSober ? 24 : 30
            let iconBox = CGRect(x: rect.minX + 16, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
            let iconBg = NSBezierPath(ovalIn: iconBox)
            accent.withAlphaComponent((isSober ? 0.06 : 0.11) * alpha).setFill()
            iconBg.fill()
            accent.withAlphaComponent((isSober ? 0.14 : 0.24) * alpha).setStroke()
            iconBg.lineWidth = 1
            iconBg.stroke()
            drawMicGlyph(in: iconBox.insetBy(dx: iconSize * 0.27, dy: iconSize * 0.20), color: accent.withAlphaComponent((isSober ? 0.74 : 0.86) * alpha), in: ctx)

            let title = NSAttributedString(
                string: isSober ? label : label.uppercased(),
                attributes: [
                    .font: isSober ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: theme.highlight.withAlphaComponent((isSober ? 0.84 : 0.92) * alpha),
                ]
            )
            let detail = NSAttributedString(
                string: success ? (isSober ? "Listening" : "DICTATION ENGINE · READY") : (isSober ? "Permission needed" : "DICTATION ENGINE · BLOCKED"),
                attributes: [
                    .font: isSober ? NSFont.systemFont(ofSize: 10, weight: .regular) : NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium),
                    .foregroundColor: accent.withAlphaComponent((isSober ? 0.62 : 0.76) * alpha),
                ]
            )

            let textX = iconBox.maxX + 12
            title.draw(in: CGRect(x: textX, y: rect.midY + (isSober ? 1 : 2), width: rect.maxX - textX - 16, height: 16))
            detail.draw(in: CGRect(x: textX, y: rect.midY - (isSober ? 15 : 15), width: rect.maxX - textX - 16, height: 13))
        }
    }

    private func drawSystemCaption(_ caption: MouseGestureSystemCaption, success: Bool, in ctx: CGContext) {
        let alpha = committedSurfaceAlpha()
        guard alpha > 0.01 else { return }

        let isSober = hudStyle == .sober
        let accent = success ? theme.accent : theme.failure
        let titleFont = isSober ? NSFont.systemFont(ofSize: 11, weight: .semibold) : NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let detailFont = isSober ? NSFont.systemFont(ofSize: 10, weight: .regular) : NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let tagFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        let titleText = isSober ? "Middle-click up" : caption.title
        let detailText = isSober
            ? (success ? "Dictation started" : "Permission needed")
            : caption.detail
        let title = NSAttributedString(
            string: titleText,
            attributes: [
                .font: titleFont,
                .foregroundColor: theme.highlight.withAlphaComponent((isSober ? 0.82 : 0.88) * alpha),
            ]
        )
        let detail = NSAttributedString(
            string: detailText,
            attributes: [
                .font: detailFont,
                .foregroundColor: accent.withAlphaComponent((isSober ? 0.58 : 0.78) * alpha),
            ]
        )
        let tag = NSAttributedString(
            string: "LATTICES INPUT",
            attributes: [
                .font: tagFont,
                .foregroundColor: accent.withAlphaComponent(0.72 * alpha),
            ]
        )

        let titleSize = title.size()
        let detailSize = detail.size()
        let tagSize = tag.size()
        let contentWidth = isSober
            ? max(titleSize.width, detailSize.width) + 42
            : max(titleSize.width, detailSize.width) + tagSize.width + 48
        let panelWidth = min(max(contentWidth, isSober ? 260 : 430), bounds.width - 80)
        let panelHeight: CGFloat = isSober ? 40 : 46
        let radius: CGFloat = isSober ? 10 : 12
        let rect = CGRect(
            x: bounds.midX - panelWidth / 2,
            y: bounds.minY + 32,
            width: panelWidth,
            height: panelHeight
        )

        let panel = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        theme.graphiteDark.withAlphaComponent((isSober ? 0.42 : 0.50) * alpha).setFill()
        panel.fill()

        let border = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        theme.graphite.withAlphaComponent((isSober ? 0.16 : 0.24) * alpha).setStroke()
        border.lineWidth = 1
        border.stroke()

        let tickHeight: CGFloat = isSober ? 18 : 24
        let tick = NSBezierPath(roundedRect: CGRect(x: rect.minX + 12, y: rect.midY - tickHeight / 2, width: 2, height: tickHeight), xRadius: 1, yRadius: 1)
        accent.withAlphaComponent((isSober ? 0.42 : 0.62) * alpha).setFill()
        tick.fill()

        if isSober {
            let textX = rect.minX + 28
            title.draw(in: CGRect(x: textX, y: rect.midY + 1, width: rect.maxX - textX - 16, height: titleSize.height))
            detail.draw(in: CGRect(x: textX, y: rect.midY - detailSize.height - 2, width: rect.maxX - textX - 16, height: detailSize.height))
            return
        }

        let tagRect = CGRect(x: rect.minX + 24, y: rect.midY - tagSize.height / 2, width: tagSize.width, height: tagSize.height)
        tag.draw(in: tagRect)
        let dividerX = tagRect.maxX + 16
        ctx.setStrokeColor(theme.graphite.withAlphaComponent(0.22 * alpha).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: dividerX, y: rect.minY + 10))
        ctx.addLine(to: CGPoint(x: dividerX, y: rect.maxY - 10))
        ctx.strokePath()

        let textX = dividerX + 16
        title.draw(in: CGRect(x: textX, y: rect.midY + 2, width: rect.maxX - textX - 16, height: titleSize.height))
        detail.draw(in: CGRect(x: textX, y: rect.midY - detailSize.height - 3, width: rect.maxX - textX - 16, height: detailSize.height))
    }

    private func drawMicGlyph(in rect: CGRect, color: NSColor, in ctx: CGContext) {
        ctx.saveGState()
        color.setStroke()
        color.withAlphaComponent(0.22).setFill()

        let bodyWidth = rect.width * 0.42
        let bodyHeight = rect.height * 0.54
        let bodyRect = CGRect(
            x: rect.midX - bodyWidth / 2,
            y: rect.maxY - bodyHeight,
            width: bodyWidth,
            height: bodyHeight
        )
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: bodyWidth / 2, yRadius: bodyWidth / 2)
        body.lineWidth = 1.6
        body.fill()
        body.stroke()

        let stem = NSBezierPath()
        stem.move(to: CGPoint(x: rect.midX, y: bodyRect.minY))
        stem.line(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.24))
        stem.lineWidth = 1.8
        stem.lineCapStyle = .round
        stem.stroke()

        let arcRect = CGRect(
            x: rect.midX - rect.width * 0.28,
            y: rect.minY + rect.height * 0.18,
            width: rect.width * 0.56,
            height: rect.height * 0.42
        )
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: CGPoint(x: arcRect.midX, y: arcRect.midY + arcRect.height * 0.08),
            radius: arcRect.width / 2,
            startAngle: 200,
            endAngle: -20,
            clockwise: true
        )
        arc.lineWidth = 1.6
        arc.lineCapStyle = .round
        arc.stroke()

        let base = NSBezierPath()
        base.move(to: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.14))
        base.line(to: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.14))
        base.lineWidth = 1.6
        base.lineCapStyle = .round
        base.stroke()
        ctx.restoreGState()
    }

    private func easeOut(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 3)
    }

    private func stateDirection(from state: State) -> MouseGestureDirection? {
        switch state {
        case .idle:
            return nil
        case .tracking(_, let direction, _, _, _, _, _, _, _, _):
            return direction
        case .committed(_, let direction, _, _, _, _, _, _, _, _, _, _):
            return direction
        }
    }

    private func isCommitted(state: State) -> Bool {
        if case .committed = state {
            return true
        }
        return false
    }

    private func isCommittedShapeReplay(state: State) -> Bool {
        if case .committed(_, _, _, _, _, let visual, _, let shape, let path, _, _, _) = state {
            return shape != nil && path.count > 1 && shouldDrawMatrixCompletion(visual)
        }
        return false
    }

    private func shouldDrawMatrixCompletion(_ visual: MouseShortcutVisualDefinition?) -> Bool {
        guard let visual else { return false }
        return visual.renderer.localizedCaseInsensitiveCompare("matrix") == .orderedSame
            || visual.theme?.localizedCaseInsensitiveCompare("matrix") == .orderedSame
    }

    private func trackingProgress(from state: State) -> CGFloat? {
        if case .tracking(_, _, _, _, _, _, _, _, _, let progress) = state {
            return progress
        }
        return nil
    }
}
