import Foundation

/// One scan at a time; slow external queries cannot grow an obsolete backlog.
final class BackgroundPollWorker {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }
    private let lock = NSLock()
    private var running = false

    @discardableResult
    func request(_ scan: @escaping () -> Void) -> Bool {
        lock.lock()
        guard !running else { lock.unlock(); return false }
        running = true
        lock.unlock()
        queue.async {
            autoreleasepool { scan() }
            self.lock.lock()
            self.running = false
            self.lock.unlock()
        }
        return true
    }
}
