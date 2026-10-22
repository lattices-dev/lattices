import XCTest
import SwiftUI
import AppKit
@testable import SpeechAppRuntime

@MainActor
final class SpeechQueueTests: XCTestCase {
    func testNextAfterFullHistoryGeneratesTheCorrectQueuedJob() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        for index in 0..<SpeechQueueLimits.default.maxRecentJobs {
            let job = try queue.enqueue(Self.request("history \(index)"))
            await waitUntil(queue) { $0.snapshot.current?.id == job.id && player.isPlaying }
            player.finish()
        }
        let first = try queue.enqueue(Self.request("skip this"))
        let second = try queue.enqueue(Self.request("play this"))
        await waitUntil(queue) { $0.snapshot.current?.id == first.id && player.isPlaying }
        _ = try queue.next(jobId: first.id)
        await waitUntil(queue) { $0.snapshot.current?.id == second.id && player.isPlaying }
        XCTAssertEqual(queue.snapshot.current?.text, "play this")
        XCTAssertEqual(queue.snapshot.current?.state, .playing)
        _ = try queue.stop()
    }

    func testExpiredConfirmationDoesNotPlayAfterNarration() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        let first = try queue.enqueue(Self.request("narration"))
        await waitUntil(queue) { $0.snapshot.current?.id == first.id && player.isPlaying }
        let cue = try queue.enqueue(Self.request("Done."), playbackDeadline: Date.distantPast)
        player.finish()
        XCTAssertEqual(queue.snapshot.recent.first { $0.id == cue.id }?.state, .cancelled)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertNil(queue.snapshot.current)
    }

    func testExternalPlaybackResumesOnlyItsOwnPause() async throws {
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: FakeSpeechSynthesizer(), player: player)
        let job = try queue.enqueue(Self.request("narration"))
        await waitUntil(queue) { $0.snapshot.current?.id == job.id && player.isPlaying }
        let owner = UUID()
        try queue.reserveExternalPlayback(owner: owner)
        XCTAssertFalse(player.isPlaying)
        XCTAssertThrowsError(try queue.resume())
        queue.releaseExternalPlayback(owner: UUID())
        XCTAssertFalse(player.isPlaying)
        queue.releaseExternalPlayback(owner: owner)
        XCTAssertTrue(player.isPlaying)
        _ = try queue.pause()
        try queue.reserveExternalPlayback(owner: owner)
        queue.releaseExternalPlayback(owner: owner)
        XCTAssertFalse(player.isPlaying, "A manual pause must survive external speech")
        _ = try queue.stop()
    }

    func testExternalPlaybackDefersGenerationAndStopPreventsResurrection() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.hold = true
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        _ = try queue.enqueue(Self.request("narration"))
        await waitUntil(queue) { $0.snapshot.current?.state == .generating }
        let owner = UUID()
        try queue.reserveExternalPlayback(owner: owner)
        synth.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(player.playCount, 0)
        _ = try queue.stop()
        queue.releaseExternalPlayback(owner: owner)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertNil(queue.snapshot.current)
    }

    func testUICueUsesSharedQueueAndCanBeStopped() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        let job = try SpeechRuntime.enqueueUICue("Focused.", queue: queue)
        XCTAssertEqual(job.provider, "system")
        XCTAssertEqual(job.cachePolicy, .reuse)
        XCTAssertEqual(job.source?.kind, "ui")
        await waitUntil(queue) { $0.snapshot.current?.id == job.id && player.isPlaying }
        XCTAssertEqual(SpeechHUDPresentation.action(for: queue.snapshot), .hide)
        XCTAssertEqual(SpeechHUDPresentation.action(for: queue.snapshot, openedFromMenu: true), .show)
        _ = try queue.stop(jobId: job.id)
        XCTAssertEqual(SpeechHUDPresentation.action(for: queue.snapshot, openedFromMenu: true), .hide)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(queue.snapshot.recent.first { $0.id == job.id }?.state, .cancelled)
    }

    func testPlaybackFailureAdvancesQueueAndIgnoresLateFailure() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        let first = try queue.enqueue(Self.request("first"))
        let second = try queue.enqueue(Self.request("second"))
        await waitUntil(queue) { $0.snapshot.current?.id == first.id && player.isPlaying }
        let failFirst = player.failure
        failFirst?(NSError(domain: "SpeechTest", code: 1))
        await waitUntil(queue) { $0.snapshot.current?.id == second.id && player.isPlaying }
        XCTAssertEqual(queue.snapshot.recent.first { $0.id == first.id }?.state, .failed)
        XCTAssertEqual(queue.snapshot.failure?.id, first.id)
        XCTAssertEqual(SpeechHUDPresentation.action(for: queue.snapshot), .show)
        queue.dismissFailure()
        XCTAssertNil(queue.snapshot.failure)
        XCTAssertEqual(queue.snapshot.current?.id, second.id)
        XCTAssertTrue(player.isPlaying)
        failFirst?(NSError(domain: "SpeechTest", code: 2))
        XCTAssertEqual(queue.snapshot.current?.id, second.id)
        XCTAssertTrue(player.isPlaying)
        player.finish()
        await waitUntil(queue) { $0.snapshot.recent.last?.state == .completed }
        XCTAssertNil(queue.snapshot.current, "An older failure must not replace the completed job")
        _ = try queue.stop()
    }

    func testRepeatedFailuresRemainBoundedWithoutStaleIndexAccess() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.failWith = NSError(domain: "SpeechTest", code: 1)
        let queue = makeQueue(synth: synth, player: FakeSpeechPlayer())
        for index in 0..<20 {
            let job = try queue.enqueue(Self.request("failure \(index)"))
            await waitUntil(queue) { $0.snapshot.recent.contains { $0.id == job.id && $0.state == .failed } }
        }
        XCTAssertLessThanOrEqual(queue.snapshot.recent.count, SpeechQueueLimits.default.maxRecentJobs)
    }

    func testFailureHUDHasRoomForMessage() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.failWith = NSError(domain: "SpeechTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Speech could not be generated. Check the provider configuration and try again."
        ])
        let queue = makeQueue(synth: synth, player: FakeSpeechPlayer())
        _ = try queue.enqueue(Self.request("A longer speech message that needs enough room to remain readable while the playback controls are visible."))
        await waitUntil(queue) { $0.snapshot.current?.state == .failed }
        let hosting = NSHostingView(rootView: SpeechPlaybackHUDView(queue: queue))
        let size = hosting.fittingSize
        XCTAssertEqual(size.width, SpeechHUDPresentation.panelSize.width, accuracy: 1)
        XCTAssertGreaterThan(size.height, SpeechHUDPresentation.panelSize.height)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["LATTICES_RENDER_SPEECH_HUD"] == "1",
           let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lattices-speech-hud-failure.png"))
        }
    }

    func testStopDismissesFailureWithoutChangingHistory() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.failWith = NSError(domain: "SpeechTest", code: 1)
        let queue = makeQueue(synth: synth, player: FakeSpeechPlayer())
        let job = try queue.enqueue(Self.request("failure"))
        await waitUntil(queue) { $0.snapshot.current?.state == .failed }
        _ = try queue.stop(jobId: job.id)
        XCTAssertNil(queue.snapshot.current)
        XCTAssertEqual(queue.snapshot.recent.last?.state, .failed)
        XCTAssertThrowsError(try queue.stop(jobId: job.id))
    }

    func testEnqueueDoesNotReportCompleted() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.hold = true
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let job = try queue.enqueue(Self.request("one"))
        XCTAssertNotEqual(job.state, .completed)
        XCTAssertTrue(job.state == .queued || job.state == .generating)
        XCTAssertEqual(player.playCount, 0)

        await waitUntil(queue) { $0.snapshot.current?.state == .generating }
        XCTAssertNotEqual(queue.snapshot.current?.state, .completed)
        XCTAssertEqual(player.playCount, 0)
        synth.release()
    }

    func testQueueOrdering() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let a = try queue.enqueue(Self.request("alpha"))
        let b = try queue.enqueue(Self.request("beta"))
        let c = try queue.enqueue(Self.request("gamma"))

        await waitUntil(queue) { $0.snapshot.current?.id == a.id && $0.snapshot.current?.state == .playing }
        XCTAssertEqual(queue.snapshot.queued.map(\.id), [b.id, c.id])
        XCTAssertEqual(synth.requests.map(\.text), ["alpha"])

        player.finish()
        await waitUntil(queue) { $0.snapshot.current?.id == b.id && $0.snapshot.current?.state == .playing }
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == a.id })?.state, .completed)
        XCTAssertEqual(queue.snapshot.queued.map(\.id), [c.id])
        XCTAssertEqual(synth.requests.map(\.text), ["alpha", "beta"])

        player.finish()
        await waitUntil(queue) { $0.snapshot.current?.id == c.id && $0.snapshot.current?.state == .playing }
        player.finish()
        await waitUntil(queue) { $0.snapshot.recent.contains(where: { $0.id == c.id && $0.state == .completed }) }
        XCTAssertNil(queue.snapshot.current)
        XCTAssertTrue(queue.snapshot.queued.isEmpty)
    }

    func testCancelDuringSynthesisDropsLateResult() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.hold = true
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let job = try queue.enqueue(Self.request("held"))
        await waitUntil(queue) { $0.snapshot.current?.state == .generating }
        _ = try queue.stop(jobId: job.id)
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .cancelled)

        synth.release()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertNotEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .completed)
        XCTAssertNotEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .playing)
    }

    func testLatePlaybackCallbackDoesNotCompleteCancelledJob() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let job = try queue.enqueue(Self.request("late"))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }
        let late = player.completion
        _ = try queue.stop(jobId: job.id)
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .cancelled)
        late?()
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .cancelled)
        XCTAssertFalse(queue.snapshot.recent.contains(where: { $0.id == job.id && $0.state == .completed }))
    }

    func testPauseResumeSeek() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let job = try queue.enqueue(Self.request("controls"))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }

        let paused = try queue.pause(jobId: job.id)
        XCTAssertEqual(paused.current?.state, .paused)
        XCTAssertEqual(player.pauseCount, 1)

        let resumed = try queue.resume(jobId: job.id)
        XCTAssertEqual(resumed.current?.state, .playing)
        XCTAssertEqual(player.resumeCount, 1)

        let sought = try queue.seek(seconds: 1.25, jobId: job.id)
        XCTAssertEqual(player.seekTimes, [1.25])
        XCTAssertEqual(sought.current?.currentTime, 1.25)
        XCTAssertEqual(sought.current?.state, .playing)
    }

    func testResumeRestartsProgressUpdates() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        let job = try queue.enqueue(Self.request("progress"))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }
        _ = try queue.pause(jobId: job.id)
        _ = try queue.resume(jobId: job.id)
        player.currentTime = 1.5
        await waitUntil(queue) { $0.snapshot.current?.currentTime == 1.5 }
        _ = try queue.stop()
    }

    func testInstallingRuntimeStopsPreviousPlayerAndCancelsJobs() async throws {
        let synth = FakeSpeechSynthesizer()
        let previous = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: previous)
        let job = try queue.enqueue(Self.request("old runtime"))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }
        let replacement = FakeSpeechPlayer()
        queue.install(synthesizer: FakeSpeechSynthesizer(), player: replacement,
                      voiceCatalog: StaticSpeechVoiceCatalog())
        XCTAssertFalse(previous.isPlaying)
        XCTAssertGreaterThan(previous.stopCount, 0)
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertNil(queue.snapshot.current)
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == job.id })?.state, .cancelled)
    }

    func testProviderFailureSurfacesAndContinuesQueue() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.failWith = SpeechQueueError.providerFailed("missing openai_key")
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)

        let failing = try queue.enqueue(Self.request("nope", provider: "openai"))
        await waitUntil(queue) { $0.snapshot.recent.contains(where: { $0.id == failing.id && $0.state == .failed }) }
        XCTAssertEqual(queue.snapshot.recent.first(where: { $0.id == failing.id })?.error, "missing openai_key")
        XCTAssertEqual(player.playCount, 0)

        synth.failWith = nil
        let next = try queue.enqueue(Self.request("ok"))
        await waitUntil(queue) { $0.snapshot.current?.id == next.id && $0.snapshot.current?.state == .playing }
        XCTAssertEqual(player.playCount, 1)
    }

    func testCachePolicyReachesSynthesisOwner() async throws {
        let synth = FakeSpeechSynthesizer()
        let player = FakeSpeechPlayer()
        let queue = makeQueue(synth: synth, player: player)
        _ = try queue.enqueue(Self.request("fresh", cachePolicy: .fresh))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }
        XCTAssertEqual(synth.requests.last?.cachePolicy, .fresh)
        player.finish()
        _ = try queue.enqueue(Self.request("reuse", cachePolicy: .reuse))
        await waitUntil(queue) { $0.snapshot.current?.state == .playing }
        XCTAssertEqual(synth.requests.last?.cachePolicy, .reuse)
        XCTAssertEqual(player.playCount, 2)
    }

}

@MainActor
final class SpeechRpcTests: XCTestCase {
    func testParseRejectsRemoteAudioAndLinks() throws {
        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "audioUrl": .string("https://example.com/a.mp3"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .remoteAudioForbidden)
        }

        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "source": .object(["label": .string("https://example.com/job")]),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .sourceLinkForbidden)
        }
    }

    func testParseBoundsTextAndUnknownProvider() throws {
        let long = String(repeating: "a", count: SpeechQueueLimits.default.maxTextCharacters + 1)
        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object(["text": .string(long)]))) { error in
            guard let speechError = error as? SpeechQueueError,
                  case .textTooLong = speechError else {
                return XCTFail("expected textTooLong, got \(error)")
            }
        }

        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "provider": .string("speakeasy"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("speakeasy"))
        }

        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "provider": .string("groq"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("groq"))
        }

        XCTAssertThrowsError(try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "provider": .string("gemini"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("gemini"))
        }

        let phonon = try SpeechRpc.parseEnqueue(.object([
            "text": .string("hi"),
            "provider": .string("phonon"),
        ]))
        XCTAssertEqual(phonon.provider, "phonon")
    }

    func testEnqueueRpcReturnsActualGeneratingState() async throws {
        let synth = FakeSpeechSynthesizer()
        synth.hold = true
        let player = FakeSpeechPlayer()
        let queue = SpeechQueue(
            synthesizer: synth,
            player: player,
            voiceCatalog: StaticSpeechVoiceCatalog(items: [
                SpeechVoiceInfo(id: "system", label: "System", provider: "system", available: true, isDefault: true),
            ]),
            preferredVoiceForProvider: { _ in nil }
        )

        let result = try SpeechRpc.enqueue(.object([
            "text": .string("from rpc"),
            "provider": .string("system"),
            "cachePolicy": .string("reuse"),
            "source": .object(["kind": .string("task"), "label": .string("review")]),
        ]), queue: queue)

        XCTAssertEqual(result["state"]?.stringValue, "generating")
        XCTAssertNotEqual(result["state"]?.stringValue, "completed")
        XCTAssertNotNil(result["id"]?.stringValue)
        synth.release()
    }

    func testErrorRedactorStripsSecrets() {
        let redacted = SpeechErrorRedactor.redact("Bearer sk-abc123 failed")
        XCTAssertFalse(redacted.contains("sk-abc123"))
        XCTAssertTrue(redacted.contains("[redacted]"))
    }
}

@MainActor
private extension SpeechQueueTests {
    static func request(
        _ text: String,
        provider: String = "system",
        cachePolicy: SpeechCachePolicy = .reuse
    ) -> SpeechEnqueueRequest {
        SpeechEnqueueRequest(
            text: text,
            provider: provider,
            model: nil,
            voice: nil,
            rate: 1.0,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: cachePolicy,
            source: SpeechSourceMetadata(kind: "test", label: text, taskId: nil, sessionId: nil)
        )
    }

    func makeQueue(synth: FakeSpeechSynthesizer, player: FakeSpeechPlayer) -> SpeechQueue {
        SpeechQueue(
            synthesizer: synth,
            player: player,
            voiceCatalog: StaticSpeechVoiceCatalog(),
            preferredVoiceForProvider: { _ in nil }
        )
    }

    func waitUntil(
        _ queue: SpeechQueue,
        timeout: TimeInterval = 1.0,
        _ predicate: (SpeechQueue) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(queue) {
            if Date() > deadline {
                XCTFail("timed out waiting for speech queue state: current=\(String(describing: queue.snapshot.current?.state)) queued=\(queue.snapshot.queued.count)")
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    var hold = false
    var failWith: Error?
    var requests: [SpeechSynthesisRequest] = []
    var payload = SpeechAudioPayload(data: Data([1, 2, 3]), format: .wav, provider: "system", voice: "test")
    private var continuation: CheckedContinuation<Void, Never>?

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAudioPayload {
        requests.append(request)
        if hold {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                continuation = cont
            }
        }
        try Task.checkCancellation()
        if let failWith {
            throw failWith
        }
        return payload
    }

    func release() {
        hold = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FakeSpeechPlayer: SpeechPlaying {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 2
    var playCount = 0
    var pauseCount = 0
    var resumeCount = 0
    var stopCount = 0
    var seekTimes: [TimeInterval] = []
    var lastData: Data?
    var completion: (() -> Void)?
    var failure: ((Error) -> Void)?

    func play(data: Data, format: SpeechAudioFormat, failure: ((Error) -> Void)?, completion: (() -> Void)?) throws {
        lastData = data
        playCount += 1
        isPlaying = true
        currentTime = 0
        self.completion = completion
        self.failure = failure
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func resume() {
        resumeCount += 1
        isPlaying = true
    }

    func seek(to time: TimeInterval) -> Bool {
        seekTimes.append(time)
        currentTime = min(max(0, time), duration)
        return true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
        currentTime = 0
        completion = nil
    }

    func finish() {
        isPlaying = false
        currentTime = duration
        let done = completion
        completion = nil
        done?()
    }
}
