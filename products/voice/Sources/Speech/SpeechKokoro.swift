import Foundation
import HudsonUIAudio

struct SpeechLocalStatus: Equatable, Sendable {
    var available: Bool
    var modelId: String
    var voiceId: String
    var detail: String?
    var voices: [SpeechVoiceInfo]

    init(
        available: Bool,
        modelId: String,
        voiceId: String,
        detail: String?,
        voices: [SpeechVoiceInfo] = []
    ) {
        self.available = available
        self.modelId = modelId
        self.voiceId = voiceId
        self.detail = detail
        self.voices = voices
    }

    static let kokoroCompiledOut = SpeechLocalStatus(
        available: false,
        modelId: "FluidInference/kokoro-82m-coreml",
        voiceId: "af_heart",
        detail: "Kokoro is unavailable because FluidAudio is not compiled into this build."
    )
}

@MainActor
protocol SpeechLocalSynthesizing: AnyObject {
    func cachedStatus() -> SpeechLocalStatus
    func cachedVoices() -> [SpeechVoiceInfo]
    func probe() async -> SpeechLocalStatus
    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult
}

enum SpeechKokoro {
    static var isCompiledIn: Bool {
        #if canImport(FluidAudio)
        true
        #else
        false
        #endif
    }

    @MainActor
    static var shared: any SpeechLocalSynthesizing {
        #if canImport(FluidAudio)
        LiveSpeechKokoro.shared
        #else
        UnavailableSpeechKokoro.shared
        #endif
    }
}

@MainActor
final class UnavailableSpeechKokoro: SpeechLocalSynthesizing {
    static let shared = UnavailableSpeechKokoro()

    func cachedStatus() -> SpeechLocalStatus { .kokoroCompiledOut }

    func cachedVoices() -> [SpeechVoiceInfo] { [] }

    func probe() async -> SpeechLocalStatus { .kokoroCompiledOut }

    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        throw SpeechQueueError.providerFailed(SpeechLocalStatus.kokoroCompiledOut.detail ?? "Kokoro is unavailable")
    }
}

#if canImport(FluidAudio)
@MainActor
final class LiveSpeechKokoro: SpeechLocalSynthesizing {
    static let shared = LiveSpeechKokoro()

    func cachedStatus() -> SpeechLocalStatus { SpeechKokoroRuntime.status }

    func cachedVoices() -> [SpeechVoiceInfo] { SpeechKokoroRuntime.status.voices }

    func probe() async -> SpeechLocalStatus { SpeechKokoroRuntime.status }

    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        try await SpeechKokoroRuntime.synthesizeKokoro(
            text: text, voice: voice, rate: rate, model: model
        )
    }
}
#endif
