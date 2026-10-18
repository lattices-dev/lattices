import AppKit

enum SpaceZoomKey {
    /// Either vertical arrow enters the full overview from the filmstrip.
    /// Inside the overview the same arrows control camera distance.
    static func zoomsOut(keyCode: Int64, canvas: Bool) -> Bool {
        if !canvas && (keyCode == 125 || keyCode == 126) { return true }
        return keyCode == 27 || keyCode == 125
    }

    /// Ctrl+↓ on a canvas already at its smallest zoom leaves it, as Escape
    /// does. Only a fresh press of the chord: a press that reaches the minimum
    /// just zooms, and bare arrows, −, scroll and pinch stay clamped.
    static func exitsAtMinimum(keyCode: Int64) -> Bool { keyCode == 125 }
}

/// A held zoom is elapsed-time motion, independent of keyboard repeat. The
/// first discrete step belongs to the caller; this drive starts just after
/// that step and returns changes in log scale for a continuous camera.
struct SpaceCanvasZoomDrive {
    private struct Press {
        var key: Int64
        var readyAt: TimeInterval
    }

    private var presses: [Press] = []
    private var lastTime: TimeInterval?
    private var boundaryDirection = 0
    private(set) var velocity: Double = 0

    static let speed: Double = 2.5
    static let accelerationTime: TimeInterval = 0.06
    static let brakingTime: TimeInterval = 0.035
    static let stopSpeed: Double = 0.025
    static let maximumTick: TimeInterval = 0.05

    var active: Bool { !presses.isEmpty || velocity != 0 }
    var atBoundary: Bool { direction != 0 && boundaryDirection == direction }
    var direction: Int {
        guard let key = presses.last?.key else { return 0 }
        return SpaceZoomKey.zoomsOut(keyCode: key, canvas: true) ? -1 : 1
    }
    var driving: Bool {
        guard let press = presses.last, let lastTime else { return false }
        return lastTime >= press.readyAt
    }

    /// Latest fresh key wins. Auto-repeat never resets the initial delay or
    /// acceleration, and reversing an underway drive needs no new delay.
    @discardableResult
    mutating func press(_ key: Int64, at time: TimeInterval, delay: TimeInterval = 0.14) -> Bool {
        guard [24, 27, 125, 126].contains(key), time.isFinite,
              !presses.contains(where: { $0.key == key }) else { return false }
        let underway = velocity != 0 || (presses.last.map { time >= $0.readyAt } ?? false)
        let previous = direction
        presses.append(Press(key: key, readyAt: time + (underway ? 0 : max(0, delay))))
        lastTime = time
        if direction != previous { boundaryDirection = 0 }
        return true
    }

    /// Releasing the newest key resumes an older key that is still held.
    /// With no keys left, a short brake removes the last velocity smoothly.
    mutating func release(_ key: Int64) {
        let previous = direction
        presses.removeAll { $0.key == key }
        if direction != previous { boundaryDirection = 0 }
    }

    mutating func reset() { self = SpaceCanvasZoomDrive() }

    /// Keep ownership of the press at a limit, without accumulating motion
    /// against it. The next opposite direction can respond immediately.
    mutating func stopAtBoundary() {
        velocity = 0
        boundaryDirection = direction
    }

    mutating func advance(to time: TimeInterval) -> Double {
        guard time.isFinite else { return 0 }
        guard let previous = lastTime else { lastTime = time; return 0 }
        guard time > previous else { return 0 }
        lastTime = time
        guard active else { return 0 }
        let start = max(previous, time - Self.maximumTick)
        guard let press = presses.last else { return integrate(time - start, toward: 0) }
        guard boundaryDirection != direction else { return 0 }
        // A frame may straddle the tap delay. Integrate each side exactly,
        // so 30, 60 and 120 Hz produce the same distance and velocity.
        let ready = min(max(press.readyAt, start), time)
        var delta = integrate(ready - start, toward: 0)
        delta += integrate(time - ready, toward: Double(direction) * Self.speed)
        return delta
    }

    private mutating func integrate(_ duration: TimeInterval, toward target: Double) -> Double {
        guard duration > 0 else { return 0 }
        let initial = velocity
        let tau = target == 0 ? Self.brakingTime : Self.accelerationTime
        var elapsed = duration
        if target == 0 {
            guard abs(initial) > Self.stopSpeed else { velocity = 0; return 0 }
            elapsed = min(elapsed, tau * log(abs(initial) / Self.stopSpeed))
        }
        let decay = exp(-elapsed / tau)
        let delta = target * elapsed + (initial - target) * tau * (1 - decay)
        velocity = target + (initial - target) * decay
        if target == 0, elapsed < duration || abs(velocity) <= Self.stopSpeed * (1 + 1e-12) {
            velocity = 0
        }
        return delta
    }
}

/// Who holds the runtime shortcut lease. A claimed zoom key keeps it until
/// its key-up, so closing the canvas mid-press can't hand the still-held
/// chord's repeats to Mission Control or App Exposé.
struct SpaceZoomEngagement: Equatable {
    var strip = false
    var canvas = false
    var heldKeys: Set<Int64> = []

    /// New chords are claimed only while a surface is up.
    var engaged: Bool { strip || canvas }
    var leased: Bool { engaged || !heldKeys.isEmpty }
}

/// A deliberate upward pull claims the chooser once. A different first
/// direction stays with the existing mouse shortcuts for the whole stroke.
struct SpaceCanvasPull {
    private(set) var opened = false
    private(set) var rejected = false

    static func accepts(button: Int64, flags: CGEventFlags) -> Bool {
        button == 1 && flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
    }

    mutating func update(delta: CGPoint, flags: CGEventFlags) -> Bool {
        guard !opened, !rejected else { return false }
        guard Self.accepts(button: 1, flags: flags) else { rejected = true; return false }
        guard max(abs(delta.x), abs(delta.y)) >= 44 else { return false }
        guard -delta.y >= 44, -delta.y > abs(delta.x) * 1.25 else {
            rejected = true
            return false
        }
        opened = true
        return true
    }
}

/// One zoom step per wheel burst or trackpad gesture. Momentum is consumed,
/// but cannot accidentally advance from the aperture into the canvas.
struct SpaceZoomScroll {
    private var total: Double = 0
    private var lastTime: TimeInterval = -.infinity
    private var fired = false

    mutating func consumeTail(began: Bool, momentum: Bool, time: TimeInterval) -> Bool {
        guard fired else { return false }
        if began || (!momentum && time - lastTime > 0.25) {
            self = SpaceZoomScroll()
            return false
        }
        lastTime = time
        return true
    }

    mutating func step(delta: Double, precise: Bool, began: Bool, momentum: Bool, time: TimeInterval) -> Bool? {
        guard !momentum else { return nil }
        if began || time - lastTime > 0.25 {
            total = 0
            fired = false
        }
        lastTime = time
        guard !fired else { return nil }
        // Reversing before the threshold starts a fresh intention.
        if total * delta < 0 { total = 0 }
        total += delta
        guard abs(total) >= (precise ? 24 : 1) else { return nil }
        fired = true
        return total < 0
    }
}

/// Temporary runtime ownership; never changes the user's shortcut plist.
/// The durable snapshot is only for recovering an interrupted gesture.
final class SpaceZoomHotkeyLease {
    private let read: (Int32) -> Bool
    private let write: (Int32, Bool) -> Bool
    private let load: () -> [String: Bool]?
    private let save: ([String: Bool]?) -> Void
    private let lock = NSLock()
    private var held = false
    private var terminating = false

    init(read: @escaping (Int32) -> Bool, write: @escaping (Int32, Bool) -> Bool,
         load: @escaping () -> [String: Bool]?, save: @escaping ([String: Bool]?) -> Void) {
        self.read = read; self.write = write; self.load = load; self.save = save
    }

    func setActive(_ active: Bool, terminating: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.terminating = self.terminating || terminating
        if active && !self.terminating {
            guard !held else { return }
            held = true
            var original = load() ?? [:]
            for id: Int32 in [32, 33] { if original[String(id)] == nil { original[String(id)] = read(id) } }
            save(original)
            for id: Int32 in [32, 33] { _ = write(id, false) }
        } else {
            held = false
            guard let original = load() else { return }
            var pending = original
            for id: Int32 in [32, 33] {
                if let enabled = original[String(id)], write(id, enabled) { pending.removeValue(forKey: String(id)) }
            }
            save(pending.isEmpty ? nil : pending)
        }
    }
}

enum SpaceZoomInput {
    private static let lock = NSLock()
    private static var state = SpaceZoomEngagement()
    /// Main-thread callback, installed only by the active canvas: zoom out
    /// or in, and whether this press may leave a canvas at its minimum.
    static var onCanvasZoom: ((_ out: Bool, _ exitsAtMinimum: Bool) -> Void)?
    /// The native chooser owns a held-key drive, including physical key-up.
    /// Other canvases can retain the discrete onCanvasZoom callback.
    static var onCanvasZoomKey: ((_ key: Int64, _ pressed: Bool, _ opening: Bool) -> Void)?

    static var engaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.engaged
    }
    static var canvasEngaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.canvas && !state.strip
    }

    static func setStrip(_ active: Bool) { update { $0.strip = active } }
    static func setCanvas(_ active: Bool) { update { $0.canvas = active } }
    /// Main thread: a claimed zoom key went down, or came up.
    static func setKeyHeld(_ keyCode: Int64, _ held: Bool) {
        update { if held { $0.heldKeys.insert(keyCode) } else { $0.heldKeys.remove(keyCode) } }
    }
    static func releaseHeldKeys() { update { $0.heldKeys.removeAll() } }

    private static func update(_ change: (inout SpaceZoomEngagement) -> Void) {
        lock.lock(); change(&state); let leased = state.leased; lock.unlock()
        lease?.setActive(leased)
    }
    static func recover() { lease?.setActive(false) }
    static func terminate() { lease?.setActive(false, terminating: true) }

    private static let lease: SpaceZoomHotkeyLease? = {
        // SkyLight signatures also documented by CGSInternal/CGSHotKeys.h.
        typealias Read = @convention(c) (Int32) -> Bool
        typealias Write = @convention(c) (Int32, Bool) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let getter = dlsym(handle, "CGSIsSymbolicHotKeyEnabled"),
              let setter = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        let read = unsafeBitCast(getter, to: Read.self)
        let write = unsafeBitCast(setter, to: Write.self)
        let key = "spaceZoom.runtimeHotkeyBackup"
        return SpaceZoomHotkeyLease(read: { read($0) }, write: {
            let result = write($0, $1)
            if result != 0 { DiagnosticLog.shared.warn("SpaceZoom: shortcut ownership failed id=\($0) error=\(result)") }
            return result == 0
        },
            load: { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] },
            save: { if let value = $0 { UserDefaults.standard.set(value, forKey: key) }
                    else { UserDefaults.standard.removeObject(forKey: key) } })
    }()
}
