import XCTest
import HudsonUI
import HudsonUIAudio
@testable import SpeechAppRuntime

@MainActor
final class SpeechProviderSelectionTests: XCTestCase {
    func testRegisteredCloudAdaptersAreOpenAIAndElevenLabsOnly() {
        let ids = SpeechProviders.cloudAdapters().map { $0.providerID.rawValue }
        XCTAssertEqual(ids, ["openai", "elevenlabs"])
        XCTAssertFalse(ids.contains("groq"))
        XCTAssertFalse(ids.contains("gemini"))
        XCTAssertEqual(Set(ids), Set(ids.filter { SpeechProviders.supported.contains($0) }))
    }

    func testNormalizeAcceptsSpeechCatalogAndRejectsRemovedCloudProviders() throws {
        XCTAssertEqual(try SpeechProviders.normalize(nil), "system")
        XCTAssertEqual(try SpeechProviders.normalize("OpenAI"), "openai")
        XCTAssertEqual(try SpeechProviders.normalize("elevenlabs"), "elevenlabs")
        XCTAssertEqual(try SpeechProviders.normalize("kokoro"), "kokoro")
        XCTAssertEqual(try SpeechProviders.normalize("Phonon"), "phonon")
        XCTAssertThrowsError(try SpeechProviders.normalize("groq")) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("groq"))
        }
        XCTAssertThrowsError(try SpeechProviders.normalize("gemini")) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("gemini"))
        }
        XCTAssertThrowsError(try SpeechProviders.normalize("edge-read-aloud")) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("edge-read-aloud"))
        }
    }

    func testVoiceCatalogOmitsGroqGeminiAndReportsKokoroFromLiveProbeOnly() {
        let availableKokoro = FakeSpeechKokoro(status: SpeechLocalStatus(
            available: true,
            modelId: "FluidInference/kokoro-82m-coreml",
            voiceId: "af_heart",
            detail: nil
        ))
        let unavailableKokoro = FakeSpeechKokoro(status: SpeechLocalStatus(
            available: false,
            modelId: "FluidInference/kokoro-82m-coreml",
            voiceId: "af_heart",
            detail: "Kokoro reported no voices."
        ))

        let available = HudsonSpeechVoiceCatalog(
            credentialSource: LatticesSpeechCredentialSource(
                vault: HudVault(service: "dev.lattices.app.voice.speech-provider-test")
            ),
            adapters: SpeechProviders.cloudAdapters(),
            kokoro: availableKokoro
        ).voices()
        let providers = Set(available.map { $0.provider })
        XCTAssertTrue(providers.contains("system"))
        XCTAssertTrue(providers.contains("openai"))
        XCTAssertTrue(providers.contains("elevenlabs"))
        XCTAssertFalse(providers.contains("groq"))
        XCTAssertFalse(providers.contains("gemini"))

        if SpeechKokoro.isCompiledIn {
            XCTAssertEqual(available.first(where: { $0.provider == "kokoro" })?.available, true)
            XCTAssertEqual(available.first(where: { $0.provider == "kokoro" })?.id, "af_heart")

            let hidden = HudsonSpeechVoiceCatalog(
                credentialSource: LatticesSpeechCredentialSource(
                    vault: HudVault(service: "dev.lattices.app.voice.speech-provider-test")
                ),
                adapters: SpeechProviders.cloudAdapters(),
                kokoro: unavailableKokoro
            ).voices()
            XCTAssertEqual(hidden.first(where: { $0.provider == "kokoro" })?.available, false)
        } else {
            XCTAssertNil(available.first(where: { $0.provider == "kokoro" }))
        }
    }

    func testKokoroSynthesisUsesKokoroEngineAndDoesNotFallBack() async throws {
        let kokoro = FakeSpeechKokoro(status: SpeechLocalStatus(
            available: true,
            modelId: "FluidInference/kokoro-82m-coreml",
            voiceId: "af_heart",
            detail: nil
        ))
        kokoro.result = HudTTSResult(
            audioData: Data([0x52, 0x49, 0x46, 0x46]),
            format: .wav,
            providerID: HudTTSProviderID(rawValue: "kokoro"),
            voice: "af_heart"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattices-kokoro-select-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synth = HudsonSpeechSynthesizer(
            tts: HudTTS(
                credentialSource: EmptySpeechCredentials(),
                adapters: SpeechProviders.cloudAdapters()
            ),
            cache: HudSpeechCache(directory: directory),
            kokoro: kokoro
        )
        let payload = try await synth.synthesize(SpeechSynthesisRequest(
            text: "Kokoro selection",
            provider: "kokoro",
            model: nil,
            voice: nil,
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .fresh
        ))
        XCTAssertEqual(payload.provider, "kokoro")
        XCTAssertEqual(payload.voice, "af_heart")
        XCTAssertEqual(kokoro.synthesizeCount, 1)
        XCTAssertEqual(kokoro.lastModel, "FluidInference/kokoro-82m-coreml")

        kokoro.result = nil
        kokoro.error = SpeechQueueError.providerFailed("Kokoro failed: offline")
        do {
            _ = try await synth.synthesize(SpeechSynthesisRequest(
                text: "Should fail",
                provider: "kokoro",
                model: nil,
                voice: nil,
                rate: 1,
                instructions: nil,
                voiceSettings: nil,
                cachePolicy: .fresh
            ))
            XCTFail("Unavailable Kokoro must not fall back to system or cloud speech")
        } catch let error as SpeechQueueError {
            XCTAssertEqual(error, .providerFailed("Kokoro failed: offline"))
        }
    }

    func testKokoroRequestsAreCachedUnderTheEngineModel() async throws {
        let kokoro = FakeSpeechKokoro(status: SpeechLocalStatus(
            available: true,
            modelId: "FluidInference/kokoro-82m-coreml",
            voiceId: "af_heart",
            detail: nil
        ))
        kokoro.result = HudTTSResult(
            audioData: Data([0x52, 0x49, 0x46, 0x46]),
            format: .wav,
            providerID: HudTTSProviderID(rawValue: "kokoro"),
            voice: "af_heart"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattices-kokoro-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HudSpeechCache(directory: directory)
        let synth = HudsonSpeechSynthesizer(
            tts: HudTTS(credentialSource: EmptySpeechCredentials(), adapters: SpeechProviders.cloudAdapters()),
            cache: cache,
            kokoro: kokoro
        )
        // A render cached by the retired mlx-audio engine, which keyed Kokoro without a model.
        let stale = HudTTSRequest(text: "Cached before", voice: "af_heart", rate: 1, model: nil)
        _ = try await cache.synthesize(stale, providerID: HudTTSProviderID(rawValue: "kokoro"),
                                       namespace: "dev.lattices.app.voice", policy: .reuse) { _, provider in
            HudTTSResult(audioData: Data([0x00]), format: .wav, providerID: provider, voice: "af_heart")
        }
        let replayed = try await cache.synthesize(stale, providerID: HudTTSProviderID(rawValue: "kokoro"),
                                                  namespace: "dev.lattices.app.voice", policy: .reuse) { _, _ in
            throw SpeechQueueError.providerFailed("the stale render must replay from the cache")
        }
        XCTAssertTrue(replayed.cached)

        for model in [nil, " ", "mlx-community/Kokoro-82M-bf16"] as [String?] {
            let payload = try await synth.synthesize(SpeechSynthesisRequest(
                text: "Cached before", provider: "kokoro", model: model, voice: nil, rate: 1,
                instructions: nil, voiceSettings: nil, cachePolicy: .reuse
            ))
            XCTAssertEqual(payload.data, Data([0x52, 0x49, 0x46, 0x46]))
            XCTAssertEqual(kokoro.lastModel, "FluidInference/kokoro-82m-coreml")
        }
        XCTAssertEqual(kokoro.synthesizeCount, 1, "Every Kokoro model spelling shares one cache entry")

        _ = try? await synth.synthesize(SpeechSynthesisRequest(
            text: "Cached before", provider: "kokoro", model: "tts-1", voice: nil, rate: 1,
            instructions: nil, voiceSettings: nil, cachePolicy: .reuse
        ))
        XCTAssertEqual(kokoro.lastModel, "tts-1", "A non-Kokoro model reaches the engine, which rejects it")
    }
}

@MainActor
private final class FakeSpeechKokoro: SpeechLocalSynthesizing {
    var status: SpeechLocalStatus
    var result: HudTTSResult?
    var error: Error?
    var synthesizeCount = 0
    var lastModel: String?

    init(status: SpeechLocalStatus) {
        self.status = status
    }

    func cachedStatus() -> SpeechLocalStatus { status }

    func cachedVoices() -> [SpeechVoiceInfo] { status.voices }

    func probe() async -> SpeechLocalStatus { status }

    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        synthesizeCount += 1
        lastModel = model
        if let error { throw error }
        if let result { return result }
        throw SpeechQueueError.providerFailed("fake Kokoro has no audio")
    }
}

private struct EmptySpeechCredentials: HudTTSCredentialSource {
    func get(_ key: String) async throws -> Data? { nil }
}
