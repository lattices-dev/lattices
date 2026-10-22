import Foundation
import HudsonUIAudio

@MainActor
protocol SpeechSynthesizing: AnyObject {
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAudioPayload
}

@MainActor
protocol SpeechPlaying: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func play(data: Data, format: SpeechAudioFormat, failure: ((Error) -> Void)?, completion: (() -> Void)?) throws
    func pause()
    func resume()
    func seek(to time: TimeInterval) -> Bool
    func stop()
}

@MainActor
protocol SpeechVoiceListing: AnyObject {
    func voices() -> [SpeechVoiceInfo]
}

@MainActor
final class UnconfiguredSpeechSynthesizer: SpeechSynthesizing {
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAudioPayload {
        throw SpeechQueueError.runtimeUnavailable
    }
}

@MainActor
final class NullSpeechPlayer: SpeechPlaying {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    func play(data: Data, format: SpeechAudioFormat, failure: ((Error) -> Void)?, completion: (() -> Void)?) throws {
        throw SpeechQueueError.runtimeUnavailable
    }

    func pause() {}
    func resume() {}
    func seek(to time: TimeInterval) -> Bool { false }
    func stop() {}
}

@MainActor
final class StaticSpeechVoiceCatalog: SpeechVoiceListing {
    var items: [SpeechVoiceInfo]

    init(items: [SpeechVoiceInfo] = []) {
        self.items = items
    }

    func voices() -> [SpeechVoiceInfo] {
        items
    }
}

enum SpeechCredentialAvailability {
    /// Matches Hudson adapter `isAvailable`: missing key is available only when
    /// the adapter has no credential. Empty or whitespace-only vault values are
    /// unavailable.
    static func isAvailable(credentialKey: String?, data: Data?) -> Bool {
        guard credentialKey != nil else { return true }
        guard let data else { return false }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !value.isEmpty
    }
}

enum SpeechProviders {
    static let system = "system"
    static let openai = "openai"
    static let elevenlabs = "elevenlabs"
    static let phonon = "phonon"

    /// Display and reporting order.
    static let all = [system, openai, elevenlabs, phonon]

    static let supported = Set(all)

    /// Cloud TTS adapters Lattices registers for Speech. Groq and Gemini exist
    /// in HudsonUIAudio but are not Speech catalog choices.
    static func cloudAdapters() -> [any HudTTSProviderAdapter] {
        [
            HudTTSProviders.OpenAI(),
            HudTTSProviders.ElevenLabs(),
        ]
    }

    static func normalize(_ raw: String?) throws -> String {
        let value = (raw ?? system).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return system }
        guard supported.contains(value) else {
            throw SpeechQueueError.unknownProvider(value)
        }
        return value
    }
}
