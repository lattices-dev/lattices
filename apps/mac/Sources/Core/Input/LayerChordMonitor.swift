import AppKit
import Combine

/// Shows the layer pad as soon as ⌘⌥ goes down, before any arrow, and keeps
/// it up while the chord is held (`LayerBezel.hold`). An arrow or digit
/// lights the slot it aims at (`LayerAim`), and letting go asks whether to
/// switch there: Return switches, Escape stays. ⌘⌥ again browses on.
///
/// Apps own plenty of ⌘⌥ shortcuts (⌘⌥I, ⌘⌥Esc), so the pad waits a beat
/// before showing, and any key that isn't a layer key (arrows, 1–9, Space)
/// takes it down and drops the aim, Escape included. A read-only tap:
/// nothing is consumed here.
final class LayerChordMonitor {
    static let shared = LayerChordMonitor()

    /// Long enough to skip a ⌘⌥ shortcut typed in one motion.
    private static let showDelay: TimeInterval = 0.12
    /// How long the pad stays after letting go, when a flip happened.
    private static let lingerAfterFlip: TimeInterval = 0.9

    private static let layerKeys: Set<Int64> = [
        123, 124, 125, 126,                     // arrows
        18, 19, 20, 21, 23, 22, 26, 28, 25,     // 1–9
        83, 84, 85, 86, 87, 88, 89, 91, 92,     // numpad 1–9
        49,                                     // Space, which freezes the preview
        29, 82,                                 // 0 and numpad 0: Classic
        6,                                      // Z: undo
    ]
    private static let arrowsAndDigits = layerKeys.subtracting([49])

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var subscription: AnyCancellable?

    // Main thread only.
    private var chord = LayerChordState()
    private var flipped = false
    private var pending: DispatchWorkItem?

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard subscription == nil else { return }
        subscription = PermissionChecker.shared.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                if trusted { self?.installTap() }
            }
    }

    // MARK: Chord

    private func modifiersChanged(_ flags: CGEventFlags) {
        let preservesDecision = LayerAim.shared.ownsShortcutDecision
        let change = chord.update(flags, preservingShortcutDecision: preservesDecision)
        if preservesDecision { clearTracking() }
        switch change {
        case .pressed: pressed()
        case .released: released()
        case .cancelled: cancelled()
        case nil: break
        }
    }

    private func pressed() {
        if LayerAim.shared.resume() {
            flipped = true
            LayerPreview.shared.arm()
            return
        }
        flipped = false
        LayerBezel.shared.hold()
        // Space works from the first moment, not once the pad shows.
        LayerPreview.shared.arm()
        let show = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if LayerAim.shared.ownsShortcutDecision { self.clearTracking(); return }
            guard self.chord.holding, !self.flipped, !LayerPreview.shared.holdsKeys() else { return }
            HotkeyBootstrap.showCurrentLayer()
        }
        pending = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: show)
    }

    private func released() {
        pending?.cancel()
        pending = nil
        // Asking keeps the pad up until Return or Escape.
        if LayerAim.shared.letGo() { return }
        LayerBezel.shared.release(after: flipped ? Self.lingerAfterFlip : 0)
    }

    private func clearTracking() {
        chord.cancel()
        flipped = false
        pending?.cancel()
        pending = nil
    }

    private func cancelled() {
        clearTracking()
        LayerAim.shared.cancel()
        LayerPreview.shared.dismiss()
        LayerBezel.shared.release(after: 0)
    }

    private func key(_ code: Int64, flags: CGEventFlags) {
        if LayerAim.shared.ownsShortcutDecision { clearTracking(); return }
        guard chord.holding else { return }
        // A missed flagsChanged must not let a tiling key extend the aim.
        guard LayerChordState.mode(flags) == .browse else {
            cancelled()
            return
        }
        if Self.arrowsAndDigits.contains(code) {
            // The hotkey shows the bezel itself; don't show it twice.
            flipped = true
            pending?.cancel()
        } else if !Self.layerKeys.contains(code) {
            // Someone else's ⌘⌥ shortcut, or Escape: nothing moves.
            cancelled()
        }
    }

    // MARK: Tap

    private func installTap() {
        guard eventTap == nil else { return }
        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            DiagnosticLog.shared.warn("LayerChord: couldn't install the ⌘⌥ monitor")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        if let source { EventTapThread.overlay.add(source: source) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<LayerChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags
            DispatchQueue.main.async { monitor.modifiersChanged(flags) }
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            DispatchQueue.main.async { monitor.key(code, flags: flags) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

/// The layer chord owns exactly ⌘⌥. Adding Shift hands arrows to tiling;
/// adding Control hands them to another shortcut. Neither is a release
/// that can confirm a layer switch.
struct LayerChordState {
    enum Mode: Equatable { case browse, cancel, release }
    enum Change: Equatable { case pressed, cancelled, released }

    private(set) var holding = false

    static func hasBaseModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskAlternate)
    }

    static func mode(_ flags: CGEventFlags) -> Mode {
        if !flags.intersection([.maskShift, .maskControl]).isEmpty { return .cancel }
        return hasBaseModifiers(flags) ? .browse : .release
    }

    mutating func update(_ flags: CGEventFlags, preservingShortcutDecision: Bool = false) -> Change? {
        // Carbon can dispatch a custom action before an earlier modifier
        // event reaches main. Its decision owns the bezel until resolved.
        if preservingShortcutDecision { holding = false; return nil }
        switch Self.mode(flags) {
        case .browse:
            guard !holding else { return nil }
            holding = true
            return .pressed
        case .cancel:
            // A frozen preview can still be open after the chord came up.
            guard holding || Self.hasBaseModifiers(flags) else { return nil }
            holding = false
            return .cancelled
        case .release:
            guard holding else { return nil }
            holding = false
            return .released
        }
    }

    mutating func cancel() { holding = false }
}
