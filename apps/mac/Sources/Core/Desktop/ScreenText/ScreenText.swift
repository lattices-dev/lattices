import AppKit
import Combine
import Vision

// MARK: - Data Types

enum TextSource: String {
    case accessibility
    case ocr
}

struct OcrTextBlock {
    let text: String
    let confidence: Float         // 0.0–1.0
    let boundingBox: CGRect       // normalized coordinates within window
}

struct OcrWindowResult {
    let wid: UInt32
    let app: String
    let title: String
    let frame: WindowFrame
    let texts: [OcrTextBlock]
    let fullText: String
    let timestamp: Date
    let source: TextSource
}

struct OcrSearchResult {
    let id: Int64
    let wid: UInt32
    let app: String
    let title: String
    let frame: WindowFrame
    let fullText: String
    let snippet: String
    let timestamp: Date
    let source: TextSource
}

// MARK: - Screen Text Index

/// The live screen-text index: periodic OCR of on-screen windows, held in
/// memory. Core installs `OcrModel` at boot.
protocol ScreenTextIndex: AnyObject {
    var changes: ObservableObjectPublisher { get }
    var results: [UInt32: OcrWindowResult] { get }
    var isScanning: Bool { get }
    var enabled: Bool { get }
    var lastReviewedAt: Date? { get }

    func setEnabled(_ on: Bool)
    func setExcludedBundleIDs(_ bundleIDs: Set<String>)
    func cancelPendingScans()
    func scan()
    func scanSingle(wid: UInt32)
}

/// Where scanned text is kept once it leaves the live index. The bundle
/// installs the SQLite store behind `ocr.search`; the free build keeps none.
protocol ScreenTextHistory: AnyObject {
    func insert(results: [OcrWindowResult], gate: ScreenTextScanGate, permit: UInt64)
    func clear()
}

/// Core's view of screen text. Views observe `ScreenText.shared`; one-shot
/// recognition of a single image (capture analysis) needs no index.
final class ScreenText: ObservableObject {
    static let shared = ScreenText()

    private(set) var index: ScreenTextIndex?
    private(set) var history: ScreenTextHistory?
    private var forward: AnyCancellable?

    func installHistory(_ history: ScreenTextHistory) {
        self.history = history
    }

    /// Hands freshly scanned windows to the history, when there is one.
    func record(_ results: [OcrWindowResult], gate: ScreenTextScanGate, permit: UInt64) {
        history?.insert(results: results, gate: gate, permit: permit)
    }

    /// Explicitly forget saved history. Turning scanning off only stops collection.
    func clearHistory() {
        index?.cancelPendingScans()
        history?.clear()
    }

    func install(_ index: ScreenTextIndex) {
        self.index = index
        forward = index.changes.sink { [weak self] in self?.objectWillChange.send() }
        objectWillChange.send()
    }

    var isAvailable: Bool { index != nil }
    var results: [UInt32: OcrWindowResult] { index?.results ?? [:] }
    var isScanning: Bool { index?.isScanning ?? false }
    var enabled: Bool { index?.enabled ?? false }
    var lastReviewedAt: Date? { index?.lastReviewedAt }

    func setEnabled(_ on: Bool) { index?.setEnabled(on) }
    func setExcludedBundleIDs(_ bundleIDs: Set<String>) { index?.setExcludedBundleIDs(bundleIDs) }
    func scan() { index?.scan() }
    func scanSingle(wid: UInt32) { index?.scanSingle(wid: wid) }

    // MARK: - Vision OCR

    static func recognize(in image: CGImage, accuracy: String? = nil) -> [OcrTextBlock] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (accuracy ?? Preferences.shared.ocrAccuracy) == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = true

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OcrTextBlock(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: obs.boundingBox
            )
        }
    }
}
