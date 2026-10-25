import Combine
import XCTest
@testable import SpeechAppRuntime

@MainActor
final class SpeechPreferredVoiceRpcTests: XCTestCase {
    private var suiteName = ""
    private var preferences: SpeechVoicePreferences!
    private var queue: SpeechQueue!
    private var api: SpeechApi!

    override func setUp() async throws {
        suiteName = "speech-preferred-voice-rpc-\(UUID().uuidString)"
        let prefs = SpeechVoicePreferences(defaults: UserDefaults(suiteName: suiteName)!)
        preferences = prefs
        queue = SpeechQueue(
            synthesizer: FakeSpeechSynthesizer(),
            player: FakeSpeechPlayer(),
            voiceCatalog: StaticSpeechVoiceCatalog(items: [
                SpeechVoiceInfo(id: "com.apple.voice.Samantha", label: "Samantha", provider: "system", available: true, isDefault: true),
                SpeechVoiceInfo(id: "alloy", label: "Alloy", provider: "openai", available: false, isDefault: true),
                SpeechVoiceInfo(id: "coral", label: "Coral", provider: "openai", available: false, isDefault: false),
            ]),
            preferredVoiceForProvider: { prefs.preferredVoice(for: $0) }
        )
        api = SpeechApi()
        SpeechRpc.register(on: api, queue: queue, preferences: prefs)
    }

    override func tearDown() async throws {
        _ = try? queue.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testSetPersistsThroughPreferencesAndEnqueueUsesIt() throws {
        let result = try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("coral"), "provider": .string("openai"),
        ]))
        XCTAssertEqual(result, .object([
            "provider": .string("openai"),
            "voice": .string("coral"),
            "label": .string("Coral"),
            "available": .bool(false),
        ]))
        XCTAssertEqual(preferences.preferredVoice(for: "openai"), "coral")

        let job = try queue.enqueue(SpeechEnqueueRequest(
            text: "No voice named", provider: "openai", model: nil, voice: nil, rate: 1,
            instructions: nil, voiceSettings: nil, cachePolicy: .reuse, source: nil
        ))
        XCTAssertEqual(job.voice, "coral")
    }

    func testProviderDefaultsToSystem() throws {
        let result = try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("  com.apple.voice.Samantha "),
        ]))
        XCTAssertEqual(result["provider"]?.stringValue, "system")
        XCTAssertEqual(result["voice"]?.stringValue, "com.apple.voice.Samantha")
        XCTAssertEqual(preferences.preferredVoice(for: "system"), "com.apple.voice.Samantha")
    }

    func testUnknownVoiceIsRejectedAndKeepsPreviousChoice() throws {
        preferences.setPreferredVoice("alloy", for: "openai")

        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("nova"), "provider": .string("openai"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownVoice("nova", provider: "openai", listedUnder: nil))
            XCTAssertEqual(error.localizedDescription, "Unknown openai voice: nova. Choose an id from the voice list")
        }
        XCTAssertEqual(preferences.preferredVoice(for: "openai"), "alloy")

        // Without a provider the system catalog is checked; point at the owner.
        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("coral"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownVoice("coral", provider: "system", listedUnder: "openai"))
            XCTAssertTrue(error.localizedDescription.contains("pass provider \"openai\""))
        }
        XCTAssertNil(preferences.preferredVoice(for: "system"))
    }

    func testProviderWithoutListedVoicesAndBadParamsAreRejected() {
        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("Edwin"), "provider": .string("phonon"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .noVoices(provider: "phonon"))
        }
        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("alloy"), "provider": .string("groq"),
        ]))) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("groq"))
        }
        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([:]))) { error in
            XCTAssertEqual(error.localizedDescription, "Missing parameter: voice")
        }
        XCTAssertThrowsError(try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .int(3),
        ]))) { error in
            XCTAssertEqual(error.localizedDescription, "voice must be a string")
        }
        XCTAssertNil(preferences.preferredVoice(for: "phonon"))
    }

    func testEmptyVoiceClearsTheChoice() throws {
        preferences.setPreferredVoice("alloy", for: "openai")
        let result = try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string(""), "provider": .string("openai"),
        ]))
        XCTAssertEqual(result, .object(["provider": .string("openai"), "voice": .null]))
        XCTAssertNil(preferences.preferredVoice(for: "openai"))
    }

    func testStatusReportsPreferredVoicesPerProvider() throws {
        XCTAssertEqual(try api.dispatch(method: "speech.status", params: nil)["preferredVoices"], .array([]))

        _ = try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("coral"), "provider": .string("openai"),
        ]))
        _ = try api.dispatch(method: "speech.preferredVoice.set", params: .object([
            "voice": .string("com.apple.voice.Samantha"),
        ]))
        let expected: JSON = .array([
            .object(["provider": .string("system"), "voice": .string("com.apple.voice.Samantha")]),
            .object(["provider": .string("openai"), "voice": .string("coral")]),
        ])
        let status = try api.dispatch(method: "speech.status", params: nil)
        XCTAssertEqual(status["preferredVoices"], expected)
        XCTAssertNotNil(status["queued"]?.arrayValue)

        // Every SpeechStatus result carries the field, not only speech.status.
        XCTAssertEqual(try api.dispatch(method: "speech.stop", params: nil)["preferredVoices"], expected)

        let fields = api.models["SpeechStatus"]?.fields.map(\.name) ?? []
        XCTAssertTrue(fields.contains("preferredVoices"))
        XCTAssertNotNil(api.models["SpeechPreferredVoice"])
        XCTAssertNotNil(api.endpoints["speech.preferredVoice.set"])
    }

    func testPreferenceChangesNotifyObservers() {
        var changes = 0
        let subscription = preferences.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        preferences.setPreferredVoice("coral", for: "openai")
        preferences.setPreferredVoice(nil, for: "openai")
        XCTAssertEqual(changes, 2)
    }
}
