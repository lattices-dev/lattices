import Foundation
import HudsonUIAudio

extension SpeechLocalStatus {
    static let phononCompiledOut = SpeechLocalStatus(
        available: false,
        modelId: "gradium/phonon-31m-en",
        voiceId: "default",
        detail: "Phonon is unavailable because PhononTTS is not compiled into this build."
    )
}

enum SpeechPhonon {
    static var isCompiledIn: Bool {
        #if canImport(PhononTTS)
        true
        #else
        false
        #endif
    }

    @MainActor
    static var shared: any SpeechLocalSynthesizing {
        #if canImport(PhononTTS)
        LiveSpeechPhonon.shared
        #else
        UnavailableSpeechPhonon.shared
        #endif
    }
}

@MainActor
final class UnavailableSpeechPhonon: SpeechLocalSynthesizing {
    static let shared = UnavailableSpeechPhonon()

    func cachedStatus() -> SpeechLocalStatus { .phononCompiledOut }

    func cachedVoices() -> [SpeechVoiceInfo] { [] }

    func probe() async -> SpeechLocalStatus { .phononCompiledOut }

    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        throw SpeechQueueError.providerFailed(SpeechLocalStatus.phononCompiledOut.detail ?? "Phonon is unavailable")
    }
}

#if canImport(PhononTTS)
@MainActor
final class LiveSpeechPhonon: SpeechLocalSynthesizing {
    static let shared = LiveSpeechPhonon()

    func cachedStatus() -> SpeechLocalStatus { SpeechPhononRuntime.status }

    func cachedVoices() -> [SpeechVoiceInfo] { SpeechPhononRuntime.status.voices }

    func probe() async -> SpeechLocalStatus { SpeechPhononRuntime.status }

    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        try await SpeechPhononRuntime.synthesizePhonon(
            text: text, voice: voice, rate: rate, model: model
        )
    }
}
#endif
