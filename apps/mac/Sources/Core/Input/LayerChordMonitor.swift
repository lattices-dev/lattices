import AppKit
import Combine

/// Shows the layer pad while ⌃⌥⇧ (arrows) or ⌘⌥ (direct slots) is held.
/// A layer key lights its slot (`LayerAim`), and letting go asks whether
/// to switch there: Return switches, Escape stays. Either chord browses on.
///
/// The pad waits a beat to skip unrelated shortcuts. A key outside the
/// held chord's layer keys drops the aim, Escape included. A read-only
/// tap: nothing is consumed here.
final class LayerChordMonitor {
    static let shared = LayerChordMonitor()

    /// Long enough to skip a ⌘⌥ shortcut typed in one motion.
    private static let showDelay: TimeInterval = 0.12
    /// How long the pad stays after letting go, when a flip happened.
    private static let lingerAfterFlip: TimeInterval = 0.9

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
        if let held = chord.activeChord, LayerAim.shared.resume(with: held) {
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
        guard let held = chord.activeChord, LayerChordState.mode(flags, for: held) == .browse else {
            cancelled()
            return
        }
        if held.accepts(key: code), code != 49 {
            // The hotkey shows the bezel itself; don't show it twice.
            flipped = true
            pending?.cancel()
        } else if !held.accepts(key: code) {
            // Someone else's shortcut, or Escape: nothing moves.
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
            DiagnosticLog.shared.warn("LayerChord: couldn't install the layer shortcut monitor")
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

/// The two layer chords have distinct keys. A release removes modifiers
/// from the held chord; adding a foreign modifier cancels its aim.
struct LayerChordState {
    enum Mode: Equatable { case browse, cancel, release }
    enum Change: Equatable { case pressed, cancelled, released }
    enum BrowseChord: CaseIterable, Equatable {
        case arrows, direct

        var modifiers: CGEventFlags {
            switch self {
            case .arrows: return [.maskControl, .maskAlternate, .maskShift]
            case .direct: return [.maskCommand, .maskAlternate]
            }
        }

        func accepts(key: Int64) -> Bool {
            if key == 49 { return true } // Space freezes either browse.
            switch self {
            case .arrows: return [123, 124, 125, 126].contains(key)
            case .direct:
                return [18, 19, 20, 21, 23, 22, 26, 28, 25, // 1–9
                        83, 84, 85, 86, 87, 88, 89, 91, 92, // numpad 1–9
                        29, 82, 6].contains(key)             // Classic, undo
            }
        }
    }

    private(set) var activeChord: BrowseChord?
    var holding: Bool { activeChord != nil }

    static func modifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
    }

    static func browseChord(for flags: CGEventFlags) -> BrowseChord? {
        BrowseChord.allCases.first { $0.modifiers == modifiers(flags) }
    }

    static func mode(_ flags: CGEventFlags, for expected: BrowseChord? = nil) -> Mode {
        let modifiers = modifiers(flags)
        if let expected {
            if modifiers == expected.modifiers { return .browse }
            return modifiers.subtracting(expected.modifiers).isEmpty ? .release : .cancel
        }
        if browseChord(for: flags) != nil { return .browse }
        return BrowseChord.allCases.contains { modifiers.subtracting($0.modifiers).isEmpty } ? .release : .cancel
    }

    mutating func update(_ flags: CGEventFlags, preservingShortcutDecision: Bool = false) -> Change? {
        // Carbon can dispatch a custom action before an earlier modifier
        // event reaches main. Its decision owns the bezel until resolved.
        if preservingShortcutDecision { activeChord = nil; return nil }
        if let activeChord {
            switch Self.mode(flags, for: activeChord) {
            case .browse: return nil
            case .cancel:
                self.activeChord = nil
                return .cancelled
            case .release:
                self.activeChord = nil
                return .released
            }
        }
        if let next = Self.browseChord(for: flags) {
            activeChord = next
            return .pressed
        }
        // A frozen preview can still be open after the chord came up.
        return Self.mode(flags) == .cancel ? .cancelled : nil
    }

    mutating func cancel() { activeChord = nil }
}
