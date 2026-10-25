import XCTest
import HudsonUI
import HudsonUIAudio
@testable import SpeechAppRuntime

@MainActor
final class SpeechVoicePickerTests: XCTestCase {
    func testPreferredVoiceIsUsedWhenEnqueueOmitsVoice() throws {
        let queue = SpeechQueue(
            synthesizer: FakeSpeechSynthesizer(),
            player: FakeSpeechPlayer(),
            preferredVoiceForProvider: { provider in
                provider == "openai" ? "coral" : nil
            }
        )
        let job = try queue.enqueue(SpeechEnqueueRequest(
            text: "No voice override",
            provider: "openai",
            model: nil,
            voice: nil,
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .reuse,
            source: nil
        ))
        XCTAssertEqual(job.voice, "coral")
        _ = try queue.stop()
    }

    func testExplicitVoiceOverrideBeatsStoredPreference() throws {
        let queue = SpeechQueue(
            synthesizer: FakeSpeechSynthesizer(),
            player: FakeSpeechPlayer(),
            preferredVoiceForProvider: { _ in "alloy" }
        )
        let job = try queue.enqueue(SpeechEnqueueRequest(
            text: "MCP named a voice",
            provider: "openai",
            model: nil,
            voice: "echo",
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .reuse,
            source: nil
        ))
        XCTAssertEqual(job.voice, "echo")
        let parsed = try SpeechRpc.parseEnqueue(.object([
            "text": .string("MCP named a voice"),
            "provider": .string("openai"),
            "voice": .string("echo"),
        ]))
        XCTAssertEqual(parsed.voice, "echo")
        _ = try queue.stop()
    }

    func testWhitespaceVoiceIsTreatedAsNoOverride() throws {
        let queue = SpeechQueue(
            synthesizer: FakeSpeechSynthesizer(),
            player: FakeSpeechPlayer(),
            preferredVoiceForProvider: { _ in "nova" }
        )
        let job = try queue.enqueue(SpeechEnqueueRequest(
            text: "blank voice",
            provider: "openai",
            model: nil,
            voice: "  ",
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .reuse,
            source: nil
        ))
        XCTAssertEqual(job.voice, "nova")
        _ = try queue.stop()
    }

    func testOpenAICatalogListsOnlyTheHudTTSDefault() {
        let voices = SpeechVoiceCatalogLoader.openaiVoices()
        XCTAssertEqual(voices.map(\.id), [HudTTSProviders.OpenAI().defaultVoice])
        XCTAssertEqual(voices.map(\.provider), ["openai"])
        XCTAssertEqual(voices.first?.isDefault, true)
    }

    func testElevenLabsMissingKeyDoesNotInventVoices() async {
        let loader = SpeechVoiceCatalogLoader(
            credentialSource: LatticesSpeechCredentialSource(
                vault: HudVault(service: "dev.lattices.app.voice.speech-voice-empty")
            ),
            elevenLabsFetch: { _ in
                XCTFail("ElevenLabs must not be fetched without a key")
                return []
            }
        )
        let state = await loader.load(provider: "elevenlabs")
        XCTAssertEqual(state, .unavailable("Save an API key to load voices from ElevenLabs."))
        XCTAssertTrue(state.voices.isEmpty)
    }

    func testElevenLabsEmptyAndFailedResultsStayHonest() async {
        let vault = HudVault(service: "dev.lattices.app.voice.speech-voice-el")
        try? vault.set("elevenlabs_key", Data("sk-test".utf8))
        defer { try? vault.delete("elevenlabs_key") }

        let emptyLoader = SpeechVoiceCatalogLoader(
            credentialSource: LatticesSpeechCredentialSource(vault: vault),
            elevenLabsFetch: { _ in [] }
        )
        let empty = await emptyLoader.load(provider: "elevenlabs")
        XCTAssertEqual(empty, .empty("ElevenLabs returned no voices for this key."))

        let failedLoader = SpeechVoiceCatalogLoader(
            credentialSource: LatticesSpeechCredentialSource(vault: vault),
            elevenLabsFetch: { _ in throw SpeechQueueError.providerFailed("ElevenLabs voices failed (HTTP 401).") }
        )
        let failed = await failedLoader.load(provider: "elevenlabs")
        XCTAssertEqual(failed, .failed("ElevenLabs voices failed (HTTP 401)."))
    }

    func testPhononCatalogUsesProbedVoicesOnly() async {
        let phonon = FakeSpeechLocalEngine(status: SpeechLocalStatus(
            available: true,
            modelId: "gradium/phonon-31m-en",
            voiceId: "Edwin",
            detail: nil,
            voices: [
                SpeechVoiceInfo(id: "Edwin", label: "Edwin", provider: "phonon", available: true, isDefault: true),
                SpeechVoiceInfo(id: "Maeve", label: "Maeve", provider: "phonon", available: true, isDefault: false),
            ]
        ))
        let loader = SpeechVoiceCatalogLoader(phonon: phonon)
        guard SpeechPhonon.isCompiledIn else {
            let state = await loader.load(provider: "phonon")
            XCTAssertEqual(state, .unavailable(SpeechLocalStatus.phononCompiledOut.detail ?? ""))
            return
        }
        let state = await loader.load(provider: "phonon")
        XCTAssertEqual(state.voices.map(\.id), ["Edwin", "Maeve"])
    }

    func testPreviewEnqueueUsesExplicitVoiceAndDoesNotHideAsUICue() throws {
        let queue = SpeechQueue(
            synthesizer: FakeSpeechSynthesizer(),
            player: FakeSpeechPlayer(),
            preferredVoiceForProvider: { _ in "alloy" }
        )
        let job = try SpeechRuntime.enqueuePreview(provider: "openai", voice: "echo", queue: queue)
        XCTAssertEqual(job.voice, "echo")
        XCTAssertEqual(job.text, SpeechVoicePreferences.previewPhrase)
        XCTAssertEqual(job.source?.kind, "preview")
        XCTAssertEqual(SpeechHUDPresentation.action(for: queue.snapshot), .show)
        _ = try queue.stop()
    }

    func testResolvedVoiceHelperKeepsExplicitMCPOverride() {
        let defaults = UserDefaults(suiteName: "speech-voice-pref-\(UUID().uuidString)")!
        let prefs = SpeechVoicePreferences(defaults: defaults)
        prefs.setPreferredVoice("alloy", for: "openai")
        XCTAssertEqual(prefs.resolvedVoice(explicit: "coral", provider: "openai"), "coral")
        XCTAssertEqual(prefs.resolvedVoice(explicit: nil, provider: "openai"), "alloy")
        XCTAssertEqual(prefs.resolvedVoice(explicit: "  ", provider: "openai"), "alloy")
    }
}

@MainActor
private final class FakeSpeechLocalEngine: SpeechLocalSynthesizing {
    var status: SpeechLocalStatus

    init(status: SpeechLocalStatus) {
        self.status = status
    }

    func cachedStatus() -> SpeechLocalStatus { status }
    func cachedVoices() -> [SpeechVoiceInfo] { status.voices }
    func probe() async -> SpeechLocalStatus { status }
    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        throw SpeechQueueError.providerFailed("fake engine has no audio")
    }
}


