import CoreGraphics
import Foundation
import QuartzCore

/// Session snapshots, captured a few at a time after the canvas is on screen.
/// Approaching a desktop refines its photographs once at display density;
/// the completed snapshots remain stable without starting a live stream.
@MainActor
final class SpaceCanvasPreviewLoader {
    typealias Images = [CGWindowID: CGImage]
    typealias Capture = @Sendable ([CGWindowID], CGFloat) async -> Images

    nonisolated static let maximumWindows = 6
    nonisolated static let batchSize = 2
    nonisolated static let maximumPixelSize: CGFloat = 1440
    nonisolated static let maximumCacheBytes = 48 * 1024 * 1024

    private struct Identity: Hashable {
        let wid: CGWindowID
        let pid: Int32
    }
    private struct Cached {
        let image: CGImage
        let bytes: Int
        var touched: Int
    }

    private let capture: Capture
    private let detailCapture: Capture
    private let maximumBytes: Int
    private let estimatedWindowBytes: Int
    private var ordered: [Identity] = []
    private var predicted: [Identity] = []
    private var current: Set<Identity> = []
    private var demanded: [Identity] = []
    private var receiver: ((Images) -> Void)?
    private var detailTargets: [Identity: CGFloat] = [:]
    private var detailAttempts: [Identity: CGFloat] = [:]
    private var attempted = Set<Identity>()
    private var settled = Set<Identity>()
    private var evicted = Set<Identity>()
    private var cache: [Identity: Cached] = [:]
    private(set) var cachedBytes = 0
    private var touch = 0
    private var generation = 0
    private var task: Task<Void, Never>?
    private var stopped = false
    private var lastDeliveredImages: [CGWindowID: ObjectIdentifier]?

    init(maximumBytes: Int = SpaceCanvasPreviewLoader.maximumCacheBytes,
         estimatedWindowBytes: Int = 1440 * 1440 * 4,
         capture: @escaping Capture = { ids, maximum in
             await WindowCapture.thumbnails(windowIDs: ids, maximumPixelSize: maximum, ignoreShadows: true)
         },
         detailCapture: @escaping Capture = { ids, maximum in
             await WindowCapture.thumbnails(windowIDs: ids, maximumPixelSize: maximum, ignoreShadows: true, nativeResolution: true)
         }) {
        self.maximumBytes = max(0, maximumBytes)
        self.estimatedWindowBytes = max(1, estimatedWindowBytes)
        self.capture = capture
        self.detailCapture = detailCapture
    }

    deinit { task?.cancel() }

    /// Start with the likely destination, then its neighbors, and put the
    /// desktop already visible on the physical monitor last.
    func prepare(cards: [SpaceFilmstripCard], selected: Int, current: Int) {
        guard !stopped else { return }
        let near = min(max(selected, 0), max(0, cards.count - 1))
        let indices = cards.indices.sorted {
            if $0 == current { return false }
            if $1 == current { return true }
            let left = abs($0 - near), right = abs($1 - near)
            return left == right ? $0 < $1 : left < right
        }
        self.current = cards.indices.contains(current) ? Set(identities(cards[current].windows)) : []
        let target = near != current && cards.indices.contains(near) ? identities(cards[near].windows) : []
        if target != predicted {
            predicted = target
            permitEvictedRetry(target)
        }
        var seen = Set<Identity>()
        ordered = indices.flatMap { identities(cards[$0].windows) }.filter { seen.insert($0).inserted }
        startNext()
    }

    /// Supply cached photographs immediately, then deliver once any missing
    /// requested windows settle. Repeated calls never recapture a failed shot.
    func load(windows: [SpaceFilmstripWindow], displayPixelSize: CGSize? = nil,
              receive: @escaping (Images) -> Void) {
        guard !stopped else { return }
        let next = identities(windows)
        guard !next.isEmpty else { suspendSelection(); return }
        let changed = next != demanded || receiver == nil
        demanded = next
        let limits = displayPixelSize.map {
            Self.detailPixelLimits(windows: windows, displayPixelSize: $0, maximumBytes: maximumBytes)
        } ?? [:]
        detailTargets = Dictionary(uniqueKeysWithValues: next.compactMap { id in
            limits[id.wid].map { (id, $0) }
        })
        receiver = receive
        if changed {
            lastDeliveredImages = nil
            permitEvictedRetry(next)
            deliver()
        }
        startNext()
    }

    /// Hide details without throwing away the session's stable snapshots or
    /// interrupting predictive preparation for neighboring desktops.
    func suspendSelection() {
        demanded = []
        detailTargets = [:]
        receiver = nil
        lastDeliveredImages = nil
    }

    func cancel() { suspendSelection() }

    /// Closing the canvas releases all pictures and rejects late SCK results.
    func stop() {
        stopped = true
        generation &+= 1
        task?.cancel()
        task = nil
        suspendSelection()
        ordered = []
        predicted = []
        current = []
        attempted = []
        settled = []
        evicted = []
        detailAttempts = [:]
        cache = [:]
        cachedBytes = 0
    }

    /// Size for the final on-screen pixels, including the portion outside a
    /// clipped display. Share the existing cache budget across selected windows
    /// rather than allocating six unbounded 4K photographs. Leave room for row
    /// alignment, and never ask for detail below the existing preview quality.
    nonisolated static func detailPixelLimits(windows: [SpaceFilmstripWindow], displayPixelSize: CGSize,
                                              maximumBytes: Int = maximumCacheBytes) -> [CGWindowID: CGFloat] {
        guard displayPixelSize.width > 0, displayPixelSize.height > 0,
              displayPixelSize.width.isFinite, displayPixelSize.height.isFinite else { return [:] }
        var seen = Set<CGWindowID>()
        var sizes: [(id: CGWindowID, length: CGFloat, base: CGFloat, aspect: CGFloat)] = []
        for window in windows where window.wid != 0 {
            guard seen.insert(window.wid).inserted,
                  window.contentsRect.width > 0, window.contentsRect.height > 0 else { continue }
            let width = window.rect.width * displayPixelSize.width / window.contentsRect.width
            let height = window.rect.height * displayPixelSize.height / window.contentsRect.height
            guard width > 0, height > 0, width.isFinite, height.isFinite else { continue }
            let longest = max(width, height)
            let length = min(4096, longest)
            sizes.append((window.wid, length, min(maximumPixelSize, length), min(width, height) / longest))
            if sizes.count == maximumWindows { break }
        }
        let baseBytes = sizes.reduce(CGFloat(0)) { $0 + $1.base * $1.base * $1.aspect * 4 }
        let extraBytes = sizes.reduce(CGFloat(0)) { $0 + ($1.length * $1.length - $1.base * $1.base) * $1.aspect * 4 }
        let fraction = min(1, max(0, CGFloat(maximumBytes) * 0.92 - baseBytes) / max(1, extraBytes))
        return Dictionary(uniqueKeysWithValues: sizes.map {
            ($0.id, floor(sqrt($0.base * $0.base + ($0.length * $0.length - $0.base * $0.base) * fraction)))
        })
    }

    private func identities(_ windows: [SpaceFilmstripWindow]) -> [Identity] {
        var seen = Set<CGWindowID>()
        var result: [Identity] = []
        // Eager iteration is deliberate: lazy collection bounds may evaluate
        // a stateful uniqueness filter more than once and erase its output.
        for window in windows where window.wid != 0 {
            guard seen.insert(window.wid).inserted else { continue }
            result.append(Identity(wid: window.wid, pid: window.pid))
            if result.count == Self.maximumWindows { break }
        }
        return result
    }

    /// Only a real selection change or close look reclaims evicted pixels.
    /// Consume the marker before scheduling, so repeated preparation cannot
    /// recapture a resident/in-flight image. Failed shots remain settled.
    private func permitEvictedRetry(_ identities: [Identity]) {
        for id in identities where cache[id] == nil {
            guard evicted.remove(id) != nil else { continue }
            attempted.remove(id)
            settled.remove(id)
            detailAttempts.removeValue(forKey: id)
        }
    }

    private func startNext() {
        guard !stopped, task == nil else { return }
        let requested = demanded.filter { !attempted.contains($0) }
        // Keep the inexpensive photographs in place while one near window is
        // resolved at display density. Never put full-size work on the camera
        // loop, and never recapture the same quality on repeated zooms.
        if requested.isEmpty, let id = demanded.first(where: { id in
            guard let image = cache[id]?.image, let target = detailTargets[id] else { return false }
            return CGFloat(max(image.width, image.height)) + 1 < target
                && (detailAttempts[id] ?? 0) + 1 < target
        }), let target = detailTargets[id] {
            detailAttempts[id] = target
            startCapture([id], maximum: target, detail: true)
            return
        }
        let currentOnly = !requested.isEmpty && requested.allSatisfy { current.contains($0) }
        let priority = (currentOnly ? [] : requested) + predicted.filter { !attempted.contains($0) }
        var seen = Set<Identity>()
        var order = (priority + ordered + requested)
            .filter { !attempted.contains($0) && seen.insert($0).inserted }
        guard !order.isEmpty else { return }
        // Reserve worst-case pixels before speculative work; do not capture
        // the entire map merely to evict each image on arrival.
        let room = max(0, maximumBytes - cachedBytes) / estimatedWindowBytes
        // The real current desktop stays last among speculative work, but
        // a full cache must not permanently starve an explicit close look.
        // A new selection is meaningful before its pixels are visible. Make
        // room for just that desktop even when distant snapshots fill the
        // cache; outward speculation still stops at the memory reservation.
        let priorityCount = min(Self.batchSize, Set(priority).count)
        if room == 0, priorityCount == 0, !requested.isEmpty { order = requested }
        let currentDemand = room == 0 && priorityCount == 0 ? min(Self.batchSize, requested.count) : 0
        let count = max(priorityCount, max(currentDemand, min(Self.batchSize, room)))
        guard count > 0 else { return }
        let batch = Array(order.prefix(count))
        attempted.formUnion(batch)
        startCapture(batch, maximum: Self.maximumPixelSize, detail: false)
    }

    private func startCapture(_ batch: [Identity], maximum: CGFloat, detail: Bool) {
        let mine = generation
        let capture = detail ? detailCapture : self.capture
        let ids = batch.map(\.wid)
        task = Task.detached(priority: .utility) { [weak self] in
            let started = CACurrentMediaTime()
            let images = await capture(ids, maximum)
            guard !Task.isCancelled else { return }
            await self?.finish(images, batch: batch, generation: mine, detail: detail,
                               milliseconds: (CACurrentMediaTime() - started) * 1000)
        }
    }

    private func finish(_ images: Images, batch: [Identity], generation mine: Int, detail: Bool, milliseconds: Double) {
        guard mine == generation, !stopped else { return }
        task = nil
        settled.formUnion(batch)
        for id in batch {
            if detail, !demanded.contains(id) {
                detailAttempts.removeValue(forKey: id)
                continue
            }
            guard let image = images[id.wid] else { continue }
            // A late sharp image for an abandoned selection must not evict
            // useful neighbors. A failed or smaller result keeps the warm shot.
            if detail {
                guard demanded.contains(id), let old = cache[id],
                      image.width * image.height > old.image.width * old.image.height else { continue }
            }
            let bytes = image.bytesPerRow * image.height
            guard bytes <= maximumBytes else { continue }
            if detail {
                let otherSelectedBytes = demanded.filter { $0 != id }.reduce(0) { $0 + (cache[$1]?.bytes ?? 0) }
                guard bytes + otherSelectedBytes <= maximumBytes else { continue }
            }
            touch &+= 1
            if let old = cache[id] { cachedBytes -= old.bytes }
            cache[id] = Cached(image: image, bytes: bytes, touched: touch)
            cachedBytes += bytes
        }
        trimCache()
        DiagnosticLog.shared.info("SpaceCanvasPreview: quality=\(detail ? "detail" : "preview") sizes=\(batch.compactMap { images[$0.wid].map { "\($0.width)x\($0.height)" } }) ids=\(batch.map(\.wid)) images=\(batch.filter { images[$0.wid] != nil }.count) cachedBytes=\(cachedBytes) captureMs=\(String(format: "%.1f", milliseconds))")
        deliver()
        startNext()
    }

    private func trimCache() {
        let protected = Set(demanded)
        let priority = Dictionary(ordered.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        while cachedBytes > maximumBytes {
            let unprotected = cache.keys.filter { !protected.contains($0) }
            let choices = unprotected.isEmpty ? Array(cache.keys) : unprotected
            guard let victim = choices.max(by: { a, b in
                let left = priority[a] ?? Int.max, right = priority[b] ?? Int.max
                return left == right ? cache[a]!.touched > cache[b]!.touched : left < right
            }), let removed = cache.removeValue(forKey: victim) else { break }
            cachedBytes -= removed.bytes
            evicted.insert(victim)
        }
    }

    private func deliver() {
        guard let receiver, !demanded.isEmpty else { return }
        var images: Images = [:]
        for id in demanded {
            guard var cached = cache[id] else { continue }
            touch &+= 1
            cached.touched = touch
            cache[id] = cached
            images[id.wid] = cached.image
        }
        // Empty-on-entry must not wipe a warm view before capture settles.
        let delivered = images.mapValues { ObjectIdentifier($0) }
        if (!images.isEmpty || demanded.allSatisfy({ settled.contains($0) })), delivered != lastDeliveredImages {
            lastDeliveredImages = delivered
            receiver(images)
        }
    }
}
