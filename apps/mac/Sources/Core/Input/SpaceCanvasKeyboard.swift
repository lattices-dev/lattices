import AppKit

/// The chooser has no text input and need not borrow another app's key
/// focus. Its existing event tap owns plain keys only for the visible
/// session. Press tails stay owned after close, but cannot reach a new view.
final class SpaceCanvasKeyboard {
    static let shared = SpaceCanvasKeyboard()
    typealias Receiver = (_ key: Int64, _ pressed: Bool, _ repeated: Bool) -> Void

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var receiver: Receiver?
    private var presses: [Int64: UInt64] = [:]
    private var hyperTransportHeld = false
    private let enqueue: (@escaping () -> Void) -> Void

    init(enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.enqueue = enqueue
    }

    func begin(_ receiver: @escaping Receiver) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        self.receiver = receiver
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        receiver = nil
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        receiver = nil
        presses.removeAll()
        hyperTransportHeld = false
    }

    /// Returns true only when the event must not reach the foreground app.
    /// Ctrl navigation keeps its existing route; Command/Option shortcuts
    /// keep their system/app routing. Arrow hardware Fn/numpad bits are fine.
    func handle(key: Int64, pressed: Bool, repeated: Bool, flags: CGEventFlags) -> Bool {
        // Caps/F18 must reach the Hyper remapper even when this newer
        // head-inserted tap sees the raw transport key first.
        lock.lock()
        if key == CapsLockHIDTransportController.transportKeyCode {
            hyperTransportHeld = pressed
            lock.unlock()
            return false
        }
        if key == 57 { lock.unlock(); return false }
        let owner: UInt64
        if !pressed {
            guard let existing = presses.removeValue(forKey: key) else { lock.unlock(); return false }
            owner = existing
        } else if repeated, let existing = presses[key] {
            owner = existing
        } else {
            guard receiver != nil, !repeated, !hyperTransportHeld,
                  flags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty else {
                lock.unlock(); return false
            }
            owner = generation
            presses[key] = owner
        }
        let deliver = receiver != nil && owner == generation
        lock.unlock()
        if deliver {
            let received = CACurrentMediaTime()
            enqueue { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let callback = self.generation == owner ? self.receiver : nil
                self.lock.unlock()
                guard let callback else { return }
                callback(key, pressed, repeated)
                if pressed && !repeated {
                    DiagnosticLog.shared.info("SpaceCanvas: key=\(key) readyMs=\(String(format: "%.2f", (CACurrentMediaTime() - received) * 1000))")
                }
            }
        }
        return true
    }
}
