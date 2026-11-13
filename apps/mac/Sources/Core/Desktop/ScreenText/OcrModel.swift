import AppKit
import Combine
import CryptoKit

/// Main-thread scan scheduling and publication; workers only receive immutable
/// snapshots. The cancellation permit also follows results into persistence.
final class OcrModel: ObservableObject {
    static let shared = OcrModel()

    @Published private var indexedResults: [UInt32: OcrWindowResult] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var lastReviewedAt: Date?
    @Published private(set) var lastReviewedWindowCount = 0
    @Published var interval: TimeInterval = 60
    @Published private(set) var enabled = false

    private let snapshotLock = NSLock()
    private var resultSnapshot: [UInt32: OcrWindowResult] = [:]
    var results: [UInt32: OcrWindowResult] {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return resultSnapshot
    }

    private var timer: Timer?
    private var deepTimer: Timer?
    private var preferencesSubscription: AnyCancellable?
    private var imageHashes: [UInt32: Data] = [:]
    private var lastScanned: [UInt32: Date] = [:]
    private struct WindowIdentity: Equatable {
        let pid: Int32
        let bundleID: String?
        init(_ window: WindowEntry) { pid = window.pid; bundleID = window.bundleId }
    }
    private var resultIdentities: [UInt32: WindowIdentity] = [:]
    private let gate = ScreenTextScanGate()
    private let myPid = ProcessInfo.processInfo.processIdentifier
    private let maxInMemoryResults = 100
    private var prefs: Preferences { Preferences.shared }

    private enum ScanKind { case quick, deep, single(UInt32) }
    private struct ScanOutput {
        var results: [UInt32: OcrWindowResult]
        var hashes: [UInt32: Data]
        var lastScanned: [UInt32: Date]
        var changed: [OcrWindowResult] = []
    }

    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    func start(interval: TimeInterval? = nil) {
        onMain {
            if preferencesSubscription == nil {
                preferencesSubscription = prefs.$ocrEnabled.combineLatest(prefs.$ocrExcludedBundleIDs)
                    .dropFirst().receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.reconcilePreferences() }
            }
            enabled = prefs.ocrEnabled
            guard enabled, timer == nil else { return }
            self.interval = max(1, interval ?? prefs.ocrQuickInterval)
            timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
                self?.quickScan()
            }
            deepTimer = Timer.scheduledTimer(withTimeInterval: max(1, prefs.ocrDeepInterval), repeats: true) { [weak self] _ in
                self?.scan()
            }
            let permit = gate.current()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.gate.isCurrent(permit) else { return }
                self.quickScan()
            }
        }
    }

    func stop() {
        onMain {
            gate.invalidate()
            timer?.invalidate(); timer = nil
            deepTimer?.invalidate(); deepTimer = nil
            isScanning = false
        }
    }

    func setEnabled(_ on: Bool) {
        onMain {
            prefs.ocrEnabled = on
            if on {
                prefs.clearDismissal(Capability.screenSearch.rawValue)
                PermissionChecker.shared.requestScreenRecording()
            }
            reconcilePreferences()
        }
    }

    func setExcludedBundleIDs(_ bundleIDs: Set<String>) {
        onMain {
            gate.invalidate()
            prefs.ocrExcludedBundleIDs = bundleIDs
            reconcilePreferences()
        }
    }

    func cancelPendingScans() { onMain { gate.invalidate(); isScanning = false } }

    private func reconcilePreferences() {
        stop()
        enabled = prefs.ocrEnabled
        // Exclusions/off apply to the live index immediately. Saved history is
        // retained until its configured expiry or explicit Clear History.
        let identities = Dictionary(uniqueKeysWithValues: enumerateWindows(policy: policy).map { ($0.wid, WindowIdentity($0)) })
        let eligible = Set(identities.keys)
        publish(results.filter { identities[$0.key] != nil && identities[$0.key] == resultIdentities[$0.key] })
        resultIdentities = resultIdentities.filter { results[$0.key] != nil }
        imageHashes = imageHashes.filter { eligible.contains($0.key) }
        lastScanned = lastScanned.filter { eligible.contains($0.key) }
        if enabled { start() }
    }

    private var policy: ScreenTextPolicy {
        ScreenTextPolicy(enabled: prefs.ocrEnabled, excludedBundleIDs: prefs.ocrExcludedBundleIDs)
    }

    /// All indexing entry points obey the same opt-in and app policy.
    func scanSingle(wid: UInt32) { begin(.single(wid)) }
    func quickScan() { begin(.quick) }
    func scan() { begin(.deep) }

    private func begin(_ kind: ScanKind) {
        onMain {
            let policy = self.policy
            guard policy.enabled, !isScanning else { return }
            let allWindows = enumerateWindows(policy: policy)
            let allIdentities = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.wid, WindowIdentity($0)) })
            let previous = results.filter { allIdentities[$0.key] != nil && allIdentities[$0.key] == resultIdentities[$0.key] }
            let windows: [WindowEntry]
            switch kind {
            case .single(let wid): windows = allWindows.filter { $0.wid == wid }
            case .quick: windows = Array(allWindows.prefix(max(0, prefs.ocrQuickLimit)))
            case .deep: windows = Array(allWindows.prefix(max(0, prefs.ocrDeepLimit)))
            }
            guard !windows.isEmpty else {
                publish(previous)
                return
            }
            isScanning = true
            let permit = gate.current()
            let hashes = imageHashes
            let scanned = lastScanned
            let budget = max(0, prefs.ocrDeepBudget)
            let accuracy = prefs.ocrAccuracy
            let history = ScreenText.shared.history
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let output = await self.collect(kind: kind, windows: windows, previous: previous,
                                                hashes: hashes, scanned: scanned, budget: budget,
                                                accuracy: accuracy, permit: permit)
                DispatchQueue.main.async {
                    guard self.gate.isCurrent(permit), self.prefs.ocrEnabled else { return }
                    // Re-evaluate identity/eligibility before publishing: a closed
                    // window or changed exclusion must not re-enter the index.
                    let eligible = self.enumerateWindows(policy: self.policy)
                    let identities = Dictionary(uniqueKeysWithValues: eligible.map { ($0.wid, WindowIdentity($0)) })
                    let live = output.results.filter { wid, _ in
                        guard let identity = identities[wid] else { return false }
                        return allIdentities[wid] == identity
                    }
                    let retained = Dictionary(uniqueKeysWithValues: live.values
                        .sorted { $0.timestamp > $1.timestamp }.prefix(self.maxInMemoryResults).map { ($0.wid, $0) })
                    self.imageHashes = output.hashes.filter { retained[$0.key] != nil }
                    self.lastScanned = output.lastScanned.filter { retained[$0.key] != nil }
                    self.resultIdentities = identities.filter { retained[$0.key] != nil }
                    self.publish(retained)
                    self.lastReviewedAt = Date()
                    self.lastReviewedWindowCount = windows.count
                    self.isScanning = false
                    history?.insert(results: output.changed.filter { retained[$0.wid] != nil },
                                    gate: self.gate, permit: permit)
                    EventBus.shared.post(.ocrScanComplete(windowCount: retained.count,
                        totalBlocks: retained.values.reduce(0) { $0 + $1.texts.count }))
                }
            }
        }
    }

    private func collect(kind: ScanKind, windows: [WindowEntry], previous: [UInt32: OcrWindowResult],
                         hashes: [UInt32: Data], scanned: [UInt32: Date], budget: Int,
                         accuracy: String, permit: UInt64) async -> ScanOutput {
        var output = ScanOutput(results: previous, hashes: hashes, lastScanned: scanned)
        switch kind {
        case .quick, .single:
            let extractor = AccessibilityTextExtractor()
            for window in windows {
                guard gate.isCurrent(permit) else { return output }
                // An available but now-empty AX tree must replace old live
                // text. Only an actual extraction failure keeps the cache.
                guard let text = extractor.extract(pid: window.pid, wid: window.wid, minChars: 0) else { continue }
                guard gate.isCurrent(permit) else { return output }
                let blocks = text.texts.map { OcrTextBlock(text: $0, confidence: 1, boundingBox: .zero) }
                let result = makeResult(window, blocks: blocks, source: .accessibility)
                if previous[window.wid]?.fullText != result.fullText { output.changed.append(result) }
                output.results[window.wid] = result
            }
        case .deep:
            // Rank stale windows first. Capture each window at most once per
            // pass; do not advance its hash until its text was recognized.
            let ordered = windows.sorted { (scanned[$0.wid] ?? .distantPast) < (scanned[$1.wid] ?? .distantPast) }
            var recognized = 0
            for window in ordered {
                guard gate.isCurrent(permit), recognized < budget else { break }
                guard let image = await WindowCapture.image(listOption: .optionIncludingWindow,
                    windowID: CGWindowID(window.wid), imageOption: [.boundsIgnoreFraming, .bestResolution]) else { continue }
                guard gate.isCurrent(permit) else { return output }
                let hash = imageHash(image)
                if hash == hashes[window.wid], previous[window.wid]?.source == .ocr {
                    output.lastScanned[window.wid] = Date()
                    continue
                }
                let blocks = ScreenText.recognize(in: image, accuracy: accuracy)
                guard gate.isCurrent(permit) else { return output }
                let result = makeResult(window, blocks: blocks, source: .ocr)
                if previous[window.wid]?.fullText != result.fullText { output.changed.append(result) }
                output.results[window.wid] = result
                output.hashes[window.wid] = hash
                output.lastScanned[window.wid] = Date()
                recognized += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return output
    }

    private func makeResult(_ window: WindowEntry, blocks: [OcrTextBlock], source: TextSource) -> OcrWindowResult {
        OcrWindowResult(wid: window.wid, app: window.app, title: window.title, frame: window.frame,
            texts: blocks, fullText: blocks.map(\.text).joined(separator: "\n"), timestamp: Date(), source: source)
    }

    private func publish(_ value: [UInt32: OcrWindowResult]) {
        snapshotLock.lock()
        resultSnapshot = value
        snapshotLock.unlock()
        indexedResults = value
    }

    private func enumerateWindows(policy: ScreenTextPolicy) -> [WindowEntry] {
        guard policy.enabled,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let wid = info[kCGWindowNumber as String] as? UInt32,
                  let app = info[kCGWindowOwnerName as String] as? String,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { return nil }
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard policy.allows(bundleID: bundleID, isOwnProcess: pid == myPid, isOnScreen: true,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                width: Double(rect.width), height: Double(rect.height)) else { return nil }
            return WindowEntry(wid: wid, app: app, pid: pid,
                title: info[kCGWindowName as String] as? String ?? "",
                frame: WindowFrame(x: rect.origin.x, y: rect.origin.y, w: rect.width, h: rect.height),
                spaceIds: [], isOnScreen: true, latticesSession: nil, bundleId: bundleID)
        }
    }

    private func imageHash(_ image: CGImage) -> Data {
        guard let data = image.dataProvider?.data else { return Data() }
        return Data(SHA256.hash(data: data as Data))
    }

    func recognizeText(in image: CGImage) -> [OcrTextBlock] { ScreenText.recognize(in: image) }
}

extension OcrModel: ScreenTextIndex {
    var changes: ObservableObjectPublisher { objectWillChange }
}
