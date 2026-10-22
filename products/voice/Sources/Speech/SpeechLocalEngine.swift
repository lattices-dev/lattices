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
}

@MainActor
protocol SpeechLocalSynthesizing: AnyObject {
    func cachedStatus() -> SpeechLocalStatus
    func cachedVoices() -> [SpeechVoiceInfo]
    func probe() async -> SpeechLocalStatus
    func synthesize(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult
}
