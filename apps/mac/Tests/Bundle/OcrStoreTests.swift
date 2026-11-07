import Foundation
import XCTest
@testable import Lattices

final class OcrStoreTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    private func withStore(
        retentionDays: @escaping () -> Int = { 7 },
        now: (() -> Date)? = nil,
        queue: DispatchQueue = DispatchQueue(label: "test.ocrstore"),
        _ body: (OcrStore, String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ocr.db").path
        let store = OcrStore(dbPath: path, retentionDays: retentionDays,
                             now: now ?? { self.fixedNow }, scheduleMaintenance: false, queue: queue)
        store.open()
        defer { store.close() }
        try body(store, path)
    }

    private func result(_ text: String, age: TimeInterval = 0, wid: UInt32 = 42) -> OcrWindowResult {
        OcrWindowResult(wid: wid, app: "Fixture", title: "Fixture window",
                        frame: WindowFrame(x: 0, y: 0, w: 100, h: 100), texts: [],
                        fullText: text, timestamp: fixedNow.addingTimeInterval(-age), source: .ocr)
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    func testRetentionBoundaryIsAppliedToEveryReadWithoutMaintenance() throws {
        try withStore { store, _ in
            let gate = ScreenTextScanGate()
            store.insert(results: [
                result("fixture expired", age: 7 * 86400 + 1),
                result("fixture boundary", age: 7 * 86400),
                result("fixture recent"),
            ], gate: gate, permit: gate.current())
            // A synchronous query drains the queued insert, and the retention
            // predicate applies even though no maintenance has run since it.
            let expected: Set<String> = ["fixture boundary", "fixture recent"]
            XCTAssertEqual(Set(store.search(query: "fixture").map(\.fullText)), expected)
            XCTAssertEqual(Set(store.search(query: "fixture", app: "Fixture").map(\.fullText)), expected)
            XCTAssertEqual(Set(store.history(wid: 42).map(\.fullText)), expected)
            XCTAssertEqual(Set(store.recent().map(\.fullText)), expected)
        }
    }

    func testChangingRetentionAndClockTakesEffectOnNextRead() throws {
        var days = 7
        var instant = fixedNow
        try withStore(retentionDays: { days }, now: { instant }) { store, _ in
            let gate = ScreenTextScanGate()
            store.insert(results: [result("fixture retained", age: 2 * 86400)], gate: gate, permit: gate.current())
            XCTAssertEqual(store.recent().count, 1)
            days = 1
            XCTAssertTrue(store.search(query: "fixture").isEmpty)
            XCTAssertTrue(store.history(wid: 42).isEmpty)
            XCTAssertTrue(store.recent().isEmpty)
            days = 7
            instant = instant.addingTimeInterval(6 * 86400)
            XCTAssertTrue(store.recent().isEmpty)
        }
    }

    func testQueuedWritesCannotCommitAfterScanPermitIsInvalidated() throws {
        let queue = DispatchQueue(label: "test.ocrstore.cancelled-write")
        try withStore(queue: queue) { store, _ in
            let gate = ScreenTextScanGate()
            store.insert(results: [result("existing history")], gate: gate, permit: gate.current())
            XCTAssertEqual(store.recent().count, 1)
            queue.suspend()
            store.insert(results: [result("cancelled scan")], gate: gate, permit: gate.current())
            gate.invalidate()
            queue.resume()
            XCTAssertEqual(store.recent().map(\.fullText), ["existing history"])
            store.insert(results: [result("new policy scan")], gate: gate, permit: gate.current())
            XCTAssertEqual(Set(store.recent().map(\.fullText)), ["existing history", "new policy scan"])
        }
    }

    func testClearRemovesRowsAndSearchTermsAfterPendingInserts() throws {
        try withStore { store, _ in
            let gate = ScreenTextScanGate()
            store.insert(results: [result("fixture clear me")], gate: gate, permit: gate.current())
            store.clear()
            XCTAssertTrue(store.search(query: "fixture").isEmpty)
            XCTAssertTrue(store.history(wid: 42).isEmpty)
            XCTAssertTrue(store.recent().isEmpty)
            store.insert(results: [result("fresh fixture")], gate: gate, permit: gate.current())
            XCTAssertEqual(store.search(query: "fixture").map(\.fullText), ["fresh fixture"])
        }
    }

    func testDatabaseAndSidecarsArePrivateBeforeSubsequentWrites() throws {
        try withStore { store, path in
            let directory = (path as NSString).deletingLastPathComponent
            XCTAssertEqual(try mode(directory), 0o755, "Existing parent permissions must be left alone")
            for suffix in ["", "-wal", "-shm"] {
                XCTAssertEqual(try mode(path + suffix), 0o600)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path + suffix)
            }
            let gate = ScreenTextScanGate()
            store.insert(results: [result("fixture private")], gate: gate, permit: gate.current())
            XCTAssertEqual(store.recent().count, 1)
            for suffix in ["", "-wal", "-shm"] {
                XCTAssertEqual(try mode(path + suffix), 0o600)
            }
            store.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            store.open()
            XCTAssertEqual(try mode(path), 0o600)
            XCTAssertEqual(store.recent().count, 1)
        }
    }

    func testNegativeLimitIsEmptyAndFullWidthWindowIDsRoundTrip() throws {
        try withStore { store, _ in
            let gate = ScreenTextScanGate()
            store.insert(results: [result("fixture identifier", wid: UInt32.max)], gate: gate, permit: gate.current())
            XCTAssertEqual(store.history(wid: UInt32.max).first?.wid, UInt32.max)
            XCTAssertTrue(store.recent(limit: -1).isEmpty)
            XCTAssertTrue(store.history(wid: UInt32.max, limit: -1).isEmpty)
            XCTAssertTrue(store.search(query: "fixture", limit: -1).isEmpty)
        }
    }

    func testSymbolicLinkInParentPathCanOpenTheDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("real-directory")
        let alias = root.appendingPathComponent("directory-link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let store = OcrStore(dbPath: alias.appendingPathComponent("ocr.db").path,
                             now: { self.fixedNow }, scheduleMaintenance: false)
        store.open()
        defer { store.close() }
        let gate = ScreenTextScanGate()
        store.insert(results: [result("fixture parent link")], gate: gate, permit: gate.current())
        XCTAssertEqual(store.recent().map(\.fullText), ["fixture parent link"])
        XCTAssertEqual(try mode(target.appendingPathComponent("ocr.db").path), 0o600)
    }

    func testDatabaseFilenameLinksAreRefusedWithoutChangingTheirTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated.txt")
        let original = Data("must remain unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let symbolic = root.appendingPathComponent("symbolic.db")
        let hard = root.appendingPathComponent("hard.db")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        try FileManager.default.linkItem(at: target, to: hard)
        for path in [symbolic, hard] {
            let store = OcrStore(dbPath: path.path, now: { self.fixedNow }, scheduleMaintenance: false)
            store.open()
            let gate = ScreenTextScanGate()
            store.insert(results: [result("rejected fixture")], gate: gate, permit: gate.current())
            XCTAssertTrue(store.recent().isEmpty)
            store.close()
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try mode(target.path), 0o644)
        }
    }
}
