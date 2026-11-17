import AppKit

/// Keeps an opaque, click-through canvas from exposing the real desktop while
/// Mission Control carries a window. Only the carry's marked pointer events
/// pass. Swallowed button presses retain their matching up after the lease.
final class SpaceCanvasPointerProtection {
    final class Lease {
        private let lock = NSLock()
        private var owner: SpaceCanvasPointerProtection?
        private let id: UUID

        fileprivate init(owner: SpaceCanvasPointerProtection, id: UUID) {
            self.owner = owner
            self.id = id
        }

        func end() {
            lock.lock()
            let owner = self.owner
            self.owner = nil
            lock.unlock()
            owner?.release(id)
        }

        deinit { end() }
    }

    /// Pure event ownership, independently testable without installing a tap.
    struct Policy {
        var leases: Set<UUID> = []
        private(set) var buttons: Set<Int64> = []
        var needsTap: Bool { !leases.isEmpty || !buttons.isEmpty }

        static let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]

        mutating func consumes(_ type: CGEventType, marker: Int64, button: Int64 = 0) -> Bool {
            guard marker != WindowSpaceCarry.pointerEventMarker,
                  Self.eventTypes.contains(type) else { return false }
            let button: Int64 = switch type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged: 0
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: 1
            default: button
            }
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                guard !leases.isEmpty else { return false }
                buttons.insert(button)
                return true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                let owned = buttons.remove(button) != nil
                return !leases.isEmpty || owned
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                return !leases.isEmpty || buttons.contains(button)
            case .mouseMoved:
                return needsTap
            default:
                return !leases.isEmpty
            }
        }
    }

    private static let shared = SpaceCanvasPointerProtection()
    private let lock = NSLock()
    private var policy = Policy()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Acquire before making the panel ignore input. If installation fails,
    /// leave the panel interactive and reject the move rather than expose it.
    static func acquire() -> Lease? {
        precondition(Thread.isMainThread)
        return shared.begin()
    }

    private func begin() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        if tap == nil {
            let mask = Policy.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let locations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
            guard let tap = EventTapInstallation.firstAvailable(locations, create: { location in
                CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: mask, callback: Self.callback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque())
            }) else { return nil }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                return nil
            }
            self.tap = tap
            self.source = source
            EventTapThread.overlay.add(source: source)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        let id = UUID()
        policy.leases.insert(id)
        return Lease(owner: self, id: id)
    }

    private func release(_ id: UUID) {
        lock.lock()
        policy.leases.remove(id)
        lock.unlock()
        if Thread.isMainThread { removeIfIdle() }
        else { DispatchQueue.main.async { self.removeIfIdle() } }
    }

    private func removeIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard !policy.needsTap else { return }
        if let source { EventTapThread.overlay.remove(source: source) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<SpaceCanvasPointerProtection>.fromOpaque(context).takeUnretainedValue()
        owner.lock.lock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            owner.lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let consume = owner.policy.consumes(type,
            marker: event.getIntegerValueField(.eventSourceUserData),
            button: event.getIntegerValueField(.mouseEventButtonNumber))
        let idle = !owner.policy.needsTap
        owner.lock.unlock()
        if idle { DispatchQueue.main.async { owner.removeIfIdle() } }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
