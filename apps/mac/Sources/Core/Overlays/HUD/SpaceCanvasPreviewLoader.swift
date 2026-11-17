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
    private var atlas: SpaceCanvasAtlasSession?

    /// Decoded bytes owned by the atlas, including its separate detail tier.
    var atlasCachedBytes: Int { atlas?.cachedBytes ?? 0 }

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
        guard !stopped, atlas == nil else { return }
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
        guard !stopped, atlas == nil else { return }
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

    /// Capture visible desktops and deliver the complete resident atlas without
    /// replacing the camera or its layers. The optional selected desktop gets
    /// sharper captures while other desktops keep their small atlas images.
    func loadAtlas(cards: [SpaceFilmstripCard], visible: [Int], selected: Int?,
                   atlasPixelSize: CGSize, displayPixelSize: CGSize? = nil,
                   receive: @escaping (Images) -> Void) {
        guard !stopped else { return }
        if atlas == nil {
            // Atlas and legacy selected-only loading do not speculate in
            // parallel or retain two independent full cache budgets.
            generation &+= 1
            task?.cancel()
            task = nil
            suspendSelection()
            ordered = []
            predicted = []
            current = []
            cache = [:]
            cachedBytes = 0
            atlas = SpaceCanvasAtlasSession(maximumBytes: maximumBytes,
                capture: capture, detailCapture: detailCapture)
        }
        atlas?.load(cards: cards, visible: visible, selected: selected,
            atlasPixelSize: atlasPixelSize, displayPixelSize: displayPixelSize, receive: receive)
    }

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
        atlas?.stop()
        atlas = nil
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

/// A session has two bounded tiers. Small photographs stay resident across
/// selection changes; display-density photographs never evict that atlas.
/// Only one batch (at most two SCK captures) runs at a time, off the main actor.
@MainActor
private final class SpaceCanvasAtlasSession {
    typealias Images = SpaceCanvasPreviewLoader.Images
    typealias Capture = SpaceCanvasPreviewLoader.Capture
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
    private let atlasBudget: Int
    private let detailBudget: Int
    private var previews: [Identity: Cached] = [:]
    private var details: [Identity: Cached] = [:]
    private var previewAttempts: [Identity: CGFloat] = [:]
    private var detailAttempts: [Identity: CGFloat] = [:]
    private var previewTargets: [Identity: CGFloat] = [:]
    private var detailTargets: [Identity: CGFloat] = [:]
    private var valid = Set<Identity>()
    private var demanded: [Identity] = []
    private var selected = Set<Identity>()
    private var receiver: ((Images) -> Void)?
    private var lastDelivered: [CGWindowID: ObjectIdentifier]?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var touch = 0
    private var stopped = false
    private var previewBytes = 0
    private var detailBytes = 0
    var cachedBytes: Int { previewBytes + detailBytes }

    init(maximumBytes: Int, capture: @escaping Capture, detailCapture: @escaping Capture) {
        atlasBudget = maximumBytes * 2 / 3
        detailBudget = maximumBytes - atlasBudget
        self.capture = capture
        self.detailCapture = detailCapture
    }

    deinit { task?.cancel() }

    func load(cards: [SpaceFilmstripCard], visible: [Int], selected: Int?,
              atlasPixelSize: CGSize, displayPixelSize: CGSize?,
              receive: @escaping (Images) -> Void) {
        guard !stopped else { return }
        let all = unique(cards.flatMap(\.allWindows))
        valid = Set(all.map(identity))
        let detailWindows = selected.flatMap { cards.indices.contains($0) ? cards[$0].allWindows : nil } ?? []
        let oldSelection = self.selected
        self.selected = Set(detailWindows.map(identity))
        var indices: [Int] = []
        if let selected, cards.indices.contains(selected) { indices.append(selected) }
        indices += visible.filter { cards.indices.contains($0) && $0 != selected }
        let windows = unique(indices.flatMap { cards[$0].allWindows })
        let next = windows.map(identity)
        let oldDemand = Set(demanded)
        let changed = next != demanded || receiver == nil
        demanded = next
        receiver = receive
        // Budget against the full atlas, not just the current viewport, so
        // navigating around the map does not steadily increase its resolution.
        previewTargets = limits(all, pixels: atlasPixelSize, maximum: 640, budget: atlasBudget)
        detailTargets = displayPixelSize.map {
            limits(unique(detailWindows), pixels: $0, maximum: 4096, budget: detailBudget)
        } ?? [:]
        for id in next where !oldDemand.contains(id) && previews[id] == nil {
            // A failed capture has no cache entry too. Only evictions become
            // retryable; failure markers remain until this canvas is closed.
            if evicted.remove(id) != nil { previewAttempts.removeValue(forKey: id) }
        }
        for id in self.selected where !oldSelection.contains(id) && details[id] == nil {
            if detailEvicted.remove(id) != nil { detailAttempts.removeValue(forKey: id) }
        }
        removeObsolete()
        if changed { lastDelivered = nil }
        deliver()
        startNext()
    }

    func stop() {
        stopped = true
        generation &+= 1
        task?.cancel()
        task = nil
        receiver = nil
        lastDelivered = nil
        previews = [:]
        details = [:]
        previewBytes = 0
        detailBytes = 0
    }

    private var evicted = Set<Identity>()
    private var detailEvicted = Set<Identity>()

    private func identity(_ window: SpaceFilmstripWindow) -> Identity {
        Identity(wid: window.wid, pid: window.pid)
    }

    private func unique(_ windows: [SpaceFilmstripWindow]) -> [SpaceFilmstripWindow] {
        var seen = Set<CGWindowID>()
        return windows.filter { $0.wid != 0 && seen.insert($0.wid).inserted }
    }

    private func limits(_ windows: [SpaceFilmstripWindow], pixels: CGSize,
                        maximum: CGFloat, budget: Int) -> [Identity: CGFloat] {
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0, budget > 0 else { return [:] }
        let sizes: [(Identity, CGFloat, CGFloat)] = windows.compactMap { window in
            guard window.contentsRect.width > 0, window.contentsRect.height > 0 else { return nil }
            let width = window.rect.width * pixels.width / window.contentsRect.width
            let height = window.rect.height * pixels.height / window.contentsRect.height
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return (identity(window), min(maximum, max(width, height)), min(width, height) / max(width, height))
        }
        let bytes = sizes.reduce(CGFloat(0)) { $0 + $1.1 * $1.1 * $1.2 * 4 }
        // Leave room for row alignment and capture rounding. Very large maps
        // reduce image dimensions before eviction is necessary.
        let factor = min(1, sqrt(CGFloat(budget) * 0.85 / max(1, bytes)))
        return Dictionary(uniqueKeysWithValues: sizes.map { ($0.0, max(1, floor($0.1 * factor))) })
    }

    private func removeObsolete() {
        for id in Array(previews.keys) where !valid.contains(id) {
            previewBytes -= previews.removeValue(forKey: id)?.bytes ?? 0
        }
        for id in Array(details.keys) where !valid.contains(id) {
            detailBytes -= details.removeValue(forKey: id)?.bytes ?? 0
        }
        previewAttempts = previewAttempts.filter { valid.contains($0.key) }
        detailAttempts = detailAttempts.filter { valid.contains($0.key) }
        evicted.formIntersection(valid)
        detailEvicted.formIntersection(valid)
    }

    private func startNext() {
        guard !stopped, task == nil else { return }
        let missing = demanded.filter { id in
            guard let target = previewTargets[id] else { return false }
            return (previewAttempts[id] ?? 0) + 1 < target
                && CGFloat(max(previews[id]?.image.width ?? 0, previews[id]?.image.height ?? 0)) + 1 < target
        }
        if let first = missing.first, let target = previewTargets[first] {
            // Batch similar sizes so a narrow window does not inherit its
            // neighbor's much larger texture allocation.
            let batch = Array(missing.filter { abs((previewTargets[$0] ?? 0) - target) < 32 }.prefix(2))
            let maximum = batch.compactMap { previewTargets[$0] }.max() ?? target
            for id in batch { previewAttempts[id] = maximum }
            startCapture(batch, maximum: maximum, detail: false)
            return
        }
        if let id = demanded.first(where: { id in
            guard selected.contains(id), let preview = previews[id], let target = detailTargets[id] else { return false }
            let existing = details[id]?.image ?? preview.image
            return CGFloat(max(existing.width, existing.height)) + 1 < target
                && (detailAttempts[id] ?? 0) + 1 < target
        }), let target = detailTargets[id] {
            detailAttempts[id] = target
            startCapture([id], maximum: target, detail: true)
        }
    }

    private func startCapture(_ batch: [Identity], maximum: CGFloat, detail: Bool) {
        let mine = generation
        let capture = detail ? detailCapture : self.capture
        task = Task.detached(priority: .utility) { [weak self] in
            let started = CACurrentMediaTime()
            let images = await capture(batch.map(\.wid), maximum)
            guard !Task.isCancelled else { return }
            await self?.finish(images, batch: batch, generation: mine, detail: detail,
                               milliseconds: (CACurrentMediaTime() - started) * 1000)
        }
    }

    private func finish(_ images: Images, batch: [Identity], generation mine: Int,
                        detail: Bool, milliseconds: Double) {
        guard !stopped, mine == generation else { return }
        task = nil
        for id in batch where valid.contains(id) {
            if detail, !selected.contains(id) {
                detailAttempts.removeValue(forKey: id)
                continue
            }
            guard let image = images[id.wid] else { continue }
            let bytes = image.bytesPerRow * image.height
            guard bytes <= (detail ? detailBudget : atlasBudget) else { continue }
            touch &+= 1
            let value = Cached(image: image, bytes: bytes, touched: touch)
            if detail {
                let previous = details[id]?.image ?? previews[id]?.image
                guard previous.map({ image.width * image.height > $0.width * $0.height }) ?? true else { continue }
                detailBytes -= details[id]?.bytes ?? 0
                details[id] = value
                detailBytes += bytes
                detailEvicted.remove(id)
            } else {
                previewBytes -= previews[id]?.bytes ?? 0
                previews[id] = value
                previewBytes += bytes
                evicted.remove(id)
            }
        }
        trim()
        deliver()
        DiagnosticLog.shared.info("SpaceCanvasAtlas: quality=\(detail ? "detail" : "atlas") ids=\(batch.map(\.wid)) cachedBytes=\(cachedBytes) captureMs=\(String(format: "%.1f", milliseconds))")
        startNext()
    }

    private func trim() {
        let visible = Set(demanded)
        while previewBytes > atlasBudget {
            let distant = previews.keys.filter { !visible.contains($0) }
            let choices = distant.isEmpty ? Array(previews.keys) : distant
            guard let victim = choices.min(by: { previews[$0]!.touched < previews[$1]!.touched }),
                  let old = previews.removeValue(forKey: victim) else { break }
            previewBytes -= old.bytes
            evicted.insert(victim)
        }
        while detailBytes > detailBudget {
            let distant = details.keys.filter { !selected.contains($0) }
            let choices = distant.isEmpty ? Array(details.keys) : distant
            guard let victim = choices.min(by: { details[$0]!.touched < details[$1]!.touched }),
                  let old = details.removeValue(forKey: victim) else { break }
            detailBytes -= old.bytes
            detailEvicted.insert(victim)
        }
    }

    private func deliver() {
        guard let receiver else { return }
        var images: Images = [:]
        // The demand describes the camera's destination. Outgoing desktops
        // can remain on screen during travel, so absence means eviction or
        // invalidation, never merely that a desktop left the goal viewport.
        // Only demanded entries are touched below to retain meaningful LRU.
        for (id, cached) in previews where valid.contains(id) {
            images[id.wid] = cached.image
        }
        for id in demanded {
            if selected.contains(id), var cached = details[id] {
                touch &+= 1
                cached.touched = touch
                details[id] = cached
                images[id.wid] = cached.image
            } else if var cached = previews[id] {
                touch &+= 1
                cached.touched = touch
                previews[id] = cached
                images[id.wid] = cached.image
            }
        }
        let delivered = images.mapValues { ObjectIdentifier($0) }
        guard delivered != lastDelivered else { return }
        lastDelivered = delivered
        receiver(images)
    }
}
