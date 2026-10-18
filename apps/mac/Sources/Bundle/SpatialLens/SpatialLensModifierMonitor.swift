import AppKit
import Combine
import CoreGraphics

/// Pure state for the physical Control+Option hold that opens Spatial Lens.
/// Command or Shift deliberately exclude the Caps-to-Hyper chord, whose
/// synthesized flags contain all four modifiers.
struct SpatialLensModifierState {
    enum Transition: Equatable {
        case pressed(generation: UInt64)
        case chorded(generation: UInt64)
        case released(generation: UInt64)
        case cancelled(generation: UInt64)
    }

    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var blockedUntilPairReleased = false

    mutating func flagsChanged(
        control: Bool,
        option: Bool,
        command: Bool,
        shift: Bool
    ) -> Transition? {
        let hasPair = control && option
        let isExactPair = hasPair && !command && !shift

        if let generation = activeGeneration {
            if isExactPair {
                return nil
            }

            activeGeneration = nil
            if hasPair {
                blockedUntilPairReleased = true
                return .chorded(generation: generation)
            }

            blockedUntilPairReleased = false
            return .released(generation: generation)
        }

        if !hasPair {
            blockedUntilPairReleased = false
            return nil
        }

        guard isExactPair, !blockedUntilPairReleased else { return nil }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return .pressed(generation: nextGeneration)
    }

    mutating func keyDown() -> Transition? {
        guard let generation = activeGeneration else { return nil }
        activeGeneration = nil
        blockedUntilPairReleased = true
        return .chorded(generation: generation)
    }

    mutating func cancel() -> Transition? {
        guard let generation = activeGeneration else { return nil }
        activeGeneration = nil
        blockedUntilPairReleased = true
        return .cancelled(generation: generation)
    }
}

/// A read-only event tap for the exact physical Control+Option hold. It never
/// rewrites or consumes input, so existing Control+Option shortcuts keep their
/// normal behavior. Any key chord cancels the lens until both modifiers lift.
final class SpatialLensModifierMonitor {
    static let shared = SpatialLensModifierMonitor()

    typealias Event = SpatialLensModifierState.Transition

    private let stateLock = NSLock()
    private var state = SpatialLensModifierState()
    private var handler: ((Event) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false

    private init() {}

    func start(handler: @escaping (Event) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        self.handler = handler
        stateLock.unlock()

        guard !running else {
            refresh()
            return
        }
        running = true

        Preferences.shared.$ctrlOptionHoldMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        PermissionChecker.shared.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        refresh()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        running = false
        subscriptions.removeAll()
        removeEventTap()
        reset()
        stateLock.lock()
        handler = nil
        stateLock.unlock()
    }

    func reset() {
        let transition: Event?
        stateLock.lock()
        transition = state.cancel()
        stateLock.unlock()
        deliver(transition)
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running,
              Preferences.shared.spatialLensEnabled,
              PermissionChecker.shared.accessibility else {
            removeEventTap()
            reset()
            return
        }

        if eventTap == nil {
            installEventTap()
        } else if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func installEventTap() {
        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            DiagnosticLog.shared.warn("SpatialLens: failed to install Control+Option monitor")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        if let source {
            EventTapThread.keyboard.add(source: source)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        DiagnosticLog.shared.info("SpatialLens: Control+Option monitor ready")
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            EventTapThread.keyboard.remove(source: source)
        }
        runLoopSource = nil
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<SpatialLensModifierMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.reset()
            DispatchQueue.main.async { [weak monitor] in monitor?.refresh() }
            return Unmanaged.passUnretained(event)
        }

        let transition: Event?
        monitor.stateLock.lock()
        switch type {
        case .flagsChanged:
            let flags = event.flags
            if SpaceZoomInput.engaged {
                transition = monitor.state.cancel()
                break
            }
            transition = monitor.state.flagsChanged(
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate),
                command: flags.contains(.maskCommand),
                shift: flags.contains(.maskShift)
            )
        case .keyDown:
            transition = monitor.state.keyDown()
        default:
            transition = nil
        }
        monitor.stateLock.unlock()
        monitor.deliver(transition)
        return Unmanaged.passUnretained(event)
    }

    private func deliver(_ transition: Event?) {
        guard let transition else { return }
        let currentHandler: ((Event) -> Void)?
        stateLock.lock()
        currentHandler = handler
        stateLock.unlock()
        guard let currentHandler else { return }
        DispatchQueue.main.async {
            currentHandler(transition)
        }
    }
}
