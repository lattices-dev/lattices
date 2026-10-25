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
        XCTAssertEqual(try SpeechProviders.normalize("Phonon"), "phonon")
        XCTAssertThrowsError(try SpeechProviders.normalize("kokoro")) { error in
            XCTAssertEqual(error as? SpeechQueueError, .unknownProvider("kokoro"))
        }
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

    func testVoiceCatalogOmitsGroqGeminiAndReportsPhononFromLiveProbeOnly() {
        let availablePhonon = FakeSpeechLocalEngine(status: SpeechLocalStatus(
            available: true,
            modelId: "gradium/phonon-31m-en",
            voiceId: "Edwin",
            detail: nil
        ))
        let unavailablePhonon = FakeSpeechLocalEngine(status: SpeechLocalStatus(
            available: false,
            modelId: "gradium/phonon-31m-en",
            voiceId: "Edwin",
            detail: "Phonon reported no voices."
        ))

        let available = HudsonSpeechVoiceCatalog(
            credentialSource: LatticesSpeechCredentialSource(
                vault: HudVault(service: "dev.lattices.app.voice.speech-provider-test")
            ),
            adapters: SpeechProviders.cloudAdapters(),
            phonon: availablePhonon
        ).voices()
        let providers = Set(available.map { $0.provider })
        XCTAssertTrue(providers.contains("system"))
        XCTAssertTrue(providers.contains("openai"))
        XCTAssertTrue(providers.contains("elevenlabs"))
        XCTAssertFalse(providers.contains("groq"))
        XCTAssertFalse(providers.contains("gemini"))

        if SpeechPhonon.isCompiledIn {
            XCTAssertEqual(available.first(where: { $0.provider == "phonon" })?.available, true)
            XCTAssertEqual(available.first(where: { $0.provider == "phonon" })?.id, "Edwin")

            let hidden = HudsonSpeechVoiceCatalog(
                credentialSource: LatticesSpeechCredentialSource(
                    vault: HudVault(service: "dev.lattices.app.voice.speech-provider-test")
                ),
                adapters: SpeechProviders.cloudAdapters(),
                phonon: unavailablePhonon
            ).voices()
            XCTAssertEqual(hidden.first(where: { $0.provider == "phonon" })?.available, false)
        } else {
            XCTAssertNil(available.first(where: { $0.provider == "phonon" }))
        }
    }

    func testPhononSynthesisUsesPhononEngineAndDoesNotFallBack() async throws {
        let phonon = FakeSpeechLocalEngine(status: SpeechLocalStatus(
            available: true,
            modelId: "gradium/phonon-31m-en",
            voiceId: "Edwin",
            detail: nil
        ))
        phonon.result = HudTTSResult(
            audioData: Data([0x52, 0x49, 0x46, 0x46]),
            format: .wav,
            providerID: HudTTSProviderID(rawValue: "phonon"),
            voice: "Edwin"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattices-phonon-select-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synth = HudsonSpeechSynthesizer(
            tts: HudTTS(
                credentialSource: EmptySpeechCredentials(),
                adapters: SpeechProviders.cloudAdapters()
            ),
            cache: HudSpeechCache(directory: directory),
            phonon: phonon
        )
        let payload = try await synth.synthesize(SpeechSynthesisRequest(
            text: "Phonon selection",
            provider: "phonon",
            model: nil,
            voice: nil,
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .fresh
        ))
        XCTAssertEqual(payload.provider, "phonon")
        XCTAssertEqual(payload.voice, "Edwin")
        XCTAssertEqual(phonon.synthesizeCount, 1)
        XCTAssertEqual(phonon.lastModel, "gradium/phonon-31m-en")

        phonon.result = nil
        phonon.error = SpeechQueueError.providerFailed("Phonon failed: offline")
        do {
            _ = try await synth.synthesize(SpeechSynthesisRequest(
                text: "Should fail",
                provider: "phonon",
                model: nil,
                voice: nil,
                rate: 1,
                instructions: nil,
                voiceSettings: nil,
                cachePolicy: .fresh
            ))
            XCTFail("Unavailable Phonon must not fall back to system or cloud speech")
        } catch let error as SpeechQueueError {
            XCTAssertEqual(error, .providerFailed("Phonon failed: offline"))
        }
    }

    func testPhononRequestsAreCachedUnderTheEngineModel() async throws {
        let phonon = FakeSpeechLocalEngine(status: SpeechLocalStatus(
            available: true,
            modelId: "gradium/phonon-31m-en",
            voiceId: "Edwin",
            detail: nil
        ))
        phonon.result = HudTTSResult(
            audioData: Data([0x52, 0x49, 0x46, 0x46]),
            format: .wav,
            providerID: HudTTSProviderID(rawValue: "phonon"),
            voice: "Edwin"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattices-phonon-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HudSpeechCache(directory: directory)
        let synth = HudsonSpeechSynthesizer(
            tts: HudTTS(credentialSource: EmptySpeechCredentials(), adapters: SpeechProviders.cloudAdapters()),
            cache: cache,
            phonon: phonon
        )
        for model in [nil, " ", "Phonon-31M"] as [String?] {
            let payload = try await synth.synthesize(SpeechSynthesisRequest(
                text: "Cached before", provider: "phonon", model: model, voice: nil, rate: 1,
                instructions: nil, voiceSettings: nil, cachePolicy: .reuse
            ))
            XCTAssertEqual(payload.data, Data([0x52, 0x49, 0x46, 0x46]))
            XCTAssertEqual(phonon.lastModel, "gradium/phonon-31m-en")
        }
        XCTAssertEqual(phonon.synthesizeCount, 1, "Every Phonon model spelling shares one cache entry")

        _ = try? await synth.synthesize(SpeechSynthesisRequest(
            text: "Cached before", provider: "phonon", model: "tts-1", voice: nil, rate: 1,
            instructions: nil, voiceSettings: nil, cachePolicy: .reuse
        ))
        XCTAssertEqual(phonon.lastModel, "tts-1", "A non-Phonon model reaches the engine, which rejects it")
    }
}

@MainActor
private final class FakeSpeechLocalEngine: SpeechLocalSynthesizing {
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
        throw SpeechQueueError.providerFailed("fake engine has no audio")
    }
}

private struct EmptySpeechCredentials: HudTTSCredentialSource {
    func get(_ key: String) async throws -> Data? { nil }
}
