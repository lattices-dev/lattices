import XCTest
@testable import Lattices

@MainActor
final class VoiceCaptureLifecycleTests: XCTestCase {
    func testCancelDiscardsCaptureInsteadOfRequestingTranscription() {
        let audio = AudioLayer.shared
        let previous = audio.provider
        let provider = CaptureProvider()
        audio.provider = provider
        defer { audio.cancelVoiceCommand(); audio.provider = previous }
        let voice = VoiceCommandState()

        voice.startListening()
        XCTAssertEqual(provider.starts, 1)
        voice.cancelListening()

        XCTAssertEqual(provider.stops, 0, "Cancel must not commit a recording for transcription")
        XCTAssertEqual(provider.cancels, 1)
        XCTAssertFalse(audio.isListening)
    }

    func testAnotherStartCannotReuseAProcessingCapture() {
        let audio = AudioLayer.shared
        let previous = audio.provider
        let provider = CaptureProvider()
        audio.provider = provider
        defer { audio.cancelVoiceCommand(); audio.provider = previous }

        audio.startVoiceCommand()
        audio.stopVoiceCommand()
        audio.startVoiceCommand()

        XCTAssertEqual(provider.starts, 1, "The current transcript must finish or be cancelled first")
        XCTAssertEqual(provider.stops, 1)
        provider.completeStop?(nil)
    }

    func testCancelledCaptureCannotChangeTheNextCapture() async {
        let audio = AudioLayer.shared
        let previous = audio.provider
        let provider = CaptureProvider()
        audio.provider = provider
        defer { audio.cancelVoiceCommand(); audio.provider = previous }
        let voice = VoiceCommandState()

        voice.startListening()
        let oldTranscript = provider.transcripts[0]
        voice.cancelListening()
        voice.startListening()
        oldTranscript(Transcription(text: "stale preview", confidence: 0.5, source: "test", isPartial: true, durationMs: nil))
        oldTranscript(Transcription(text: "", confidence: 0, source: "test", isPartial: false, durationMs: nil))
        // AudioLayer delivers provider callbacks on the next main-queue turn.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertTrue(audio.isListening)
        XCTAssertNil(audio.lastTranscript)
        voice.cancelListening()
    }

    func testCancelProcessingDiscardsThePendingResult() async {
        let audio = AudioLayer.shared
        let previous = audio.provider
        let provider = CaptureProvider()
        audio.provider = provider
        defer { audio.cancelVoiceCommand(); audio.provider = previous }
        let voice = VoiceCommandState()
        voice.startListening()
        voice.stopListening()
        let oldCompletion = provider.completeStop
        XCTAssertTrue(audio.isTranscribing)

        voice.cancelProcessing()
        voice.startListening()
        oldCompletion?(Transcription(text: "stale command", confidence: 1, source: "test", isPartial: false, durationMs: nil))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(provider.cancels, 1)
        XCTAssertEqual(provider.starts, 2)
        XCTAssertTrue(audio.isListening)
        XCTAssertFalse(audio.isTranscribing)
        XCTAssertNil(audio.lastTranscript)
        XCTAssertNil(audio.matchedIntent)
    }

    func testOldHealthReplyCannotStartTheNextCapture() {
        let audio = AudioLayer.shared
        let previous = audio.provider
        let provider = CaptureProvider()
        provider.deferHealthChecks = true
        audio.provider = provider
        defer { audio.cancelVoiceCommand(); audio.provider = previous }
        let voice = VoiceCommandState()

        voice.startListening()
        voice.cancelProcessing()
        voice.startListening()
        provider.healthChecks[0](true)
        XCTAssertEqual(provider.starts, 0)
        XCTAssertEqual(voice.phase, .connecting)

        provider.deferHealthChecks = false
        provider.healthChecks[1](true)
        XCTAssertEqual(provider.starts, 1)
        XCTAssertEqual(voice.phase, .listening)
    }

    func testColdModelGetsStartupTimeThenTheNormalInferenceDeadline() {
        let start = Date(timeIntervalSince1970: 0)
        var deadline = VoiceTranscriptionDeadline(startedAt: start)
        XCTAssertFalse(deadline.hasExpired(at: start.addingTimeInterval(12), modelReady: false))
        XCTAssertFalse(deadline.hasExpired(at: start.addingTimeInterval(70), modelReady: true))
        XCTAssertFalse(deadline.hasExpired(at: start.addingTimeInterval(79), modelReady: true))
        XCTAssertTrue(deadline.hasExpired(at: start.addingTimeInterval(80), modelReady: true))
    }

    func testColdModelStartupRemainsBounded() {
        let start = Date(timeIntervalSince1970: 0)
        var deadline = VoiceTranscriptionDeadline(startedAt: start)
        XCTAssertTrue(deadline.hasExpired(at: start.addingTimeInterval(180), modelReady: false))
    }

    func testReadyAndUnknownModelsKeepTheNormalDeadline() {
        let start = Date(timeIntervalSince1970: 0)
        var ready = VoiceTranscriptionDeadline(startedAt: start)
        XCTAssertFalse(ready.hasExpired(at: start, modelReady: true))
        XCTAssertTrue(ready.hasExpired(at: start.addingTimeInterval(10), modelReady: true))
        var unknown = VoiceTranscriptionDeadline(startedAt: start)
        XCTAssertTrue(unknown.hasExpired(at: start.addingTimeInterval(10), modelReady: nil))
    }
}

private final class CaptureProvider: AudioProvider {
    var isAvailable = true
    var isListening = false
    var lastErrorMessage: String?
    var starts = 0
    var stops = 0
    var cancels = 0
    var transcripts: [(Transcription) -> Void] = []
    var completeStop: ((Transcription?) -> Void)?
    var deferHealthChecks = false
    var healthChecks: [(Bool) -> Void] = []

    func checkHealth(completion: @escaping (Bool) -> Void) {
        if deferHealthChecks { healthChecks.append(completion) }
        else { completion(true) }
    }
    func startListening(onTranscript: @escaping (Transcription) -> Void) {
        starts += 1
        isListening = true
        transcripts.append(onTranscript)
    }
    func stopListening(completion: @escaping (Transcription?) -> Void) {
        stops += 1
        isListening = false
        completeStop = completion
    }
    func cancelListening() {
        cancels += 1
        isListening = false
    }
}
