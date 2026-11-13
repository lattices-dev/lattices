import Combine
import Foundation
import XCTest
@testable import Lattices

final class ScreenTextLifecycleTests: XCTestCase {
    func testClearHistoryCancelsInFlightScanBeforeClearingAndAllowsFreshScan() {
        let screenText = ScreenText()
        let index = IndexFixture()
        let history = HistoryFixture()
        screenText.install(index)
        screenText.installHistory(history)

        screenText.record([result("previously saved")], gate: index.gate, permit: index.gate.current())
        XCTAssertEqual(history.saved.map(\.fullText), ["previously saved"])

        screenText.scan()
        let inFlightPermit = index.gate.current()
        XCTAssertTrue(screenText.isScanning)
        var cancelledBeforeClear = false
        history.beforeClear = {
            cancelledBeforeClear = !index.gate.isCurrent(inFlightPermit)
        }

        screenText.clearHistory()

        XCTAssertTrue(cancelledBeforeClear, "Invalidate in-flight scans before entering the history clear barrier")
        XCTAssertEqual(index.cancellationCount, 1)
        XCTAssertFalse(screenText.isScanning)
        XCTAssertEqual(history.clearCount, 1)
        XCTAssertTrue(history.saved.isEmpty)

        // Extraction may finish after Clear History. Its old permit must not
        // repopulate the store when the result finally reaches the facade.
        screenText.record([result("late pre-clear result")], gate: index.gate, permit: inFlightPermit)
        XCTAssertTrue(history.saved.isEmpty)
        XCTAssertEqual(history.rejectedWriteCount, 1)

        screenText.scan()
        let freshPermit = index.gate.current()
        XCTAssertNotEqual(freshPermit, inFlightPermit)
        screenText.record([result("new scan result")], gate: index.gate, permit: freshPermit)
        XCTAssertEqual(history.saved.map(\.fullText), ["new scan result"])
        XCTAssertEqual(history.rejectedWriteCount, 1)
    }

    private func result(_ text: String) -> OcrWindowResult {
        OcrWindowResult(
            wid: 42, app: "Fixture", title: "Fixture window",
            frame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
            texts: [OcrTextBlock(text: text, confidence: 1, boundingBox: .zero)],
            fullText: text, timestamp: Date(timeIntervalSince1970: 1), source: .accessibility
        )
    }

    private final class IndexFixture: ScreenTextIndex {
        let changes = ObservableObjectPublisher()
        let gate = ScreenTextScanGate()
        var results: [UInt32: OcrWindowResult] = [:]
        var isScanning = false
        var enabled = true
        var lastReviewedAt: Date?
        var cancellationCount = 0

        func setEnabled(_ on: Bool) { enabled = on }
        func setExcludedBundleIDs(_ bundleIDs: Set<String>) {}
        func cancelPendingScans() {
            cancellationCount += 1
            gate.invalidate()
            isScanning = false
        }
        func scan() { isScanning = true }
        func scanSingle(wid: UInt32) { scan() }
    }

    private final class HistoryFixture: ScreenTextHistory {
        var saved: [OcrWindowResult] = []
        var clearCount = 0
        var rejectedWriteCount = 0
        var beforeClear: (() -> Void)?

        func insert(results: [OcrWindowResult], gate: ScreenTextScanGate, permit: UInt64) {
            if !gate.commit(permit, { saved.append(contentsOf: results) }) {
                rejectedWriteCount += 1
            }
        }

        func clear() {
            beforeClear?()
            clearCount += 1
            saved.removeAll()
        }
    }
}
