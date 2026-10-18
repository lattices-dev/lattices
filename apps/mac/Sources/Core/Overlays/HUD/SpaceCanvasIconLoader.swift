import AppKit

/// Small, session-owned icons. IconServices and image decoding run away from
/// the main thread; closing the canvas cancels queued work and releases its
/// cache. A late result never retains or rebuilds a discarded window zone.
@MainActor
final class SpaceCanvasIconLoader {
    typealias Lookup = @Sendable (Int32) -> CGImage?
    private let lookup: Lookup
    private var images: [Int32: CGImage] = [:]
    private var attempted = Set<Int32>()
    private var receivers: [Int32: [(CGImage?) -> Void]] = [:]
    private var tasks: [Int32: Task<Void, Never>] = [:]

    init(lookup: @escaping Lookup = { pid in
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }) {
        self.lookup = lookup
    }

    deinit { tasks.values.forEach { $0.cancel() } }

    func load(pid: Int32, into layer: CALayer) {
        if let image = images[pid] { layer.contents = image; return }
        guard !attempted.contains(pid) else { return }
        receivers[pid, default: []].append { [weak layer] image in layer?.contents = image }
        guard tasks[pid] == nil else { return }
        tasks[pid] = Task.detached(priority: .utility) { [lookup, weak self] in
            guard !Task.isCancelled else { return }
            let image = autoreleasepool { lookup(pid) }
            guard !Task.isCancelled else { return }
            await self?.complete(pid: pid, image: image)
        }
    }

    private func complete(pid: Int32, image: CGImage?) {
        tasks.removeValue(forKey: pid)
        attempted.insert(pid)
        images[pid] = image
        let callbacks = receivers.removeValue(forKey: pid) ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        callbacks.forEach { $0(image) }
        CATransaction.commit()
    }
}
