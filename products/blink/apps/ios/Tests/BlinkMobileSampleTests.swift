import BlinkCore
import XCTest
@testable import BlinkMobile

@MainActor
final class BlinkMobileSampleTests: XCTestCase {
    func testSamplesPreserveSavedBytesAndPeerMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snapshot.json")
        let cache = BlinkSnapshotCache(fileURL: fileURL)
        let saved = personalSnapshot()
        let syncedAt = Date(timeIntervalSince1970: 1_787_000_000)
        _ = try await cache.apply(saved, sourceIdentity: "approved-mac", syncedAt: syncedAt)
        let before = try Data(contentsOf: fileURL)
        var identityRequests = 0
        let model = BlinkMobileModel(cache: cache, makeClient: {
            identityRequests += 1
            throw TestError.unexpectedIdentityRequest
        })
        try await waitUntil { model.cacheState == .ready }

        model.showSampleNotes()
        XCTAssertTrue(model.isShowingSamples)
        XCTAssertEqual(model.snapshot, BlinkSampleNotes.snapshot)
        XCTAssertNil(model.lastSyncedAt)
        XCTAssertEqual(model.savedNoteCount, 1)
        let refreshed = await model.refresh()
        XCTAssertFalse(refreshed)
        await model.clearOfflineNotes()
        model.retryCacheLoad()
        model.startDiscovery()
        model.retryDiscovery()
        model.disconnect()
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(identityRequests, 0)
        XCTAssertEqual(model.connectionState, .disconnected)

        model.exitSampleNotes()
        XCTAssertEqual(model.snapshot, saved)
        XCTAssertEqual(model.lastSyncedAt, syncedAt)
        let record = try await cache.loadRecord()
        XCTAssertEqual(record?.sourceIdentity, "approved-mac")
        XCTAssertEqual(record?.lastSuccessfulSyncAt, syncedAt)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testFreshSamplesNeedNoCacheFileOrIdentityUntilConnectionOpens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snapshot.json")
        var identityRequests = 0
        let model = BlinkMobileModel(cache: BlinkSnapshotCache(fileURL: fileURL), makeClient: {
            identityRequests += 1
            throw TestError.unexpectedIdentityRequest
        })
        try await waitUntil { model.cacheState == .ready }
        XCTAssertEqual(identityRequests, 0)
        model.showSampleNotes()
        model.deactivate()
        model.activate()
        model.startDiscovery()
        model.retryDiscovery()
        await model.clearOfflineNotes()
        XCTAssertEqual(identityRequests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        model.exitSampleNotes()
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.cacheState, .ready)
        model.activate()
        XCTAssertEqual(identityRequests, 0)
        model.startDiscovery()
        XCTAssertEqual(identityRequests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDelayedCacheLoadCannotReplaceSamplesOrLoseSavedNotes() async throws {
        let saved = personalSnapshot()
        let cache = SuspendedCache(snapshot: saved, suspendLoad: true)
        let model = BlinkMobileModel(cache: cache, makeClient: { throw TestError.unexpectedIdentityRequest })
        model.showSampleNotes()
        try await waitUntilAsync { await cache.isLoading }
        await cache.finishLoading()
        try await waitUntil { model.savedNoteCount == 1 }
        XCTAssertEqual(model.snapshot, BlinkSampleNotes.snapshot)
        XCTAssertEqual(model.cacheState, .ready)
        model.exitSampleNotes()
        XCTAssertEqual(model.snapshot, saved)
        let writes = await cache.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testSampleEntryWaitsForPendingRemoval() async throws {
        let cache = SuspendedCache(snapshot: personalSnapshot(), suspendLoad: false)
        let model = BlinkMobileModel(cache: cache, makeClient: { throw TestError.unexpectedIdentityRequest })
        try await waitUntil { model.cacheState == .ready }
        let removal = Task { await model.clearOfflineNotes() }
        try await waitUntilAsync { await cache.isRemoving }
        XCTAssertFalse(model.canShowSampleNotes)
        model.showSampleNotes()
        XCTAssertFalse(model.isShowingSamples)
        await cache.finishRemoving()
        await removal.value
        model.showSampleNotes()
        XCTAssertTrue(model.isShowingSamples)
        await model.clearOfflineNotes()
        model.exitSampleNotes()
        XCTAssertNil(model.snapshot)
        let writes = await cache.writeCount
        XCTAssertEqual(writes, 1)
    }

    private func personalSnapshot() -> BlinkSnapshot {
        var saved = BlinkSampleNotes.snapshot
        saved.etag = "personal-cache-revision"
        saved.notes = [saved.notes[0]]
        saved.notes[0].id = "personal-note"
        saved.notes[0].title = "Personal fixture"
        saved.notes[0].markdown = "# Personal fixture\n\nKeep these exact bytes."
        return saved
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        try await waitUntilAsync { condition() }
    }

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the controlled cache operation")
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum TestError: Error {
    case unexpectedIdentityRequest
    case timeout
}

private actor SuspendedCache: BlinkMobileCache {
    private let record: BlinkSnapshotCacheRecord
    private let suspendLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private(set) var isLoading = false
    private(set) var isRemoving = false
    private(set) var writeCount = 0

    init(snapshot: BlinkSnapshot, suspendLoad: Bool) {
        self.record = BlinkSnapshotCacheRecord(sourceIdentity: "saved-peer", lastSuccessfulSyncAt: nil, snapshot: snapshot)
        self.suspendLoad = suspendLoad
    }

    func loadRecord() async throws -> BlinkSnapshotCacheRecord? {
        isLoading = true
        if suspendLoad {
            await withCheckedContinuation { loadContinuation = $0 }
        }
        return record
    }

    func finishLoading() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func apply(_ incoming: BlinkSnapshot, sourceIdentity: String?, syncedAt: Date?) async throws -> BlinkSnapshot {
        writeCount += 1
        return incoming
    }

    func recordSuccessfulSync(sourceIdentity: String, at date: Date) async throws -> Bool {
        writeCount += 1
        return true
    }

    func removeAll() async throws {
        isRemoving = true
        await withCheckedContinuation { removalContinuation = $0 }
        writeCount += 1
    }

    func finishRemoving() {
        removalContinuation?.resume()
        removalContinuation = nil
    }
}
