import AVFoundation
import Foundation
import HudsonUI
import HudsonUIAudio

extension Notification.Name {
    static let speechCredentialsDidChange = Notification.Name("lattices.speech.credentialsDidChange")
}

enum SpeechVoiceCatalogState: Equatable {
    case loading
    case ready([SpeechVoiceInfo])
    case empty(String)
    case unavailable(String)
    case failed(String)

    var voices: [SpeechVoiceInfo] {
        if case .ready(let voices) = self { return voices }
        return []
    }
}

/// Loads picker catalogs from the real system, HudTTS, ElevenLabs, Kokoro and
/// Phonon sources. Does not invent display names. OpenAI lists only the HudTTS default.
@MainActor
struct SpeechVoiceCatalogLoader {
    var credentialSource: LatticesSpeechCredentialSource
    var session: URLSession
    var kokoro: any SpeechLocalSynthesizing
    var phonon: any SpeechLocalSynthesizing
    var elevenLabsFetch: (String) async throws -> [SpeechVoiceInfo]

    init(
        credentialSource: LatticesSpeechCredentialSource = LatticesSpeechCredentialSource(),
        session: URLSession = .shared,
        kokoro: (any SpeechLocalSynthesizing)? = nil,
        phonon: (any SpeechLocalSynthesizing)? = nil,
        elevenLabsFetch: ((String) async throws -> [SpeechVoiceInfo])? = nil
    ) {
        self.credentialSource = credentialSource
        self.session = session
        self.kokoro = kokoro ?? SpeechKokoro.shared
        self.phonon = phonon ?? SpeechPhonon.shared
        self.elevenLabsFetch = elevenLabsFetch ?? { key in
            try await SpeechElevenLabsVoiceCatalog.fetch(apiKey: key, session: session)
        }
    }

    func load(provider: String) async -> SpeechVoiceCatalogState {
        switch provider {
        case SpeechProviders.system:
            return .ready(Self.systemVoices())
        case SpeechProviders.openai:
            return .ready(Self.openaiVoices())
        case SpeechProviders.elevenlabs:
            return await loadElevenLabs()
        case SpeechProviders.kokoro:
            guard SpeechKokoro.isCompiledIn else {
                return .unavailable(SpeechLocalStatus.kokoroCompiledOut.detail ?? "Kokoro is unavailable.")
            }
            return await loadLocal(kokoro, name: "Kokoro")
        case SpeechProviders.phonon:
            guard SpeechPhonon.isCompiledIn else {
                return .unavailable(SpeechLocalStatus.phononCompiledOut.detail ?? "Phonon is unavailable.")
            }
            return await loadLocal(phonon, name: "Phonon")
        default:
            return .unavailable("Unknown speech provider.")
        }
    }

    static func systemVoices() -> [SpeechVoiceInfo] {
        let defaultSystem = HudSystemSpeechDefaults.defaultVoiceIdentifier
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        if voices.isEmpty {
            return [SpeechVoiceInfo(
                id: defaultSystem,
                label: "System",
                provider: SpeechProviders.system,
                available: true,
                isDefault: true
            )]
        }
        return voices.map { voice in
            SpeechVoiceInfo(
                id: voice.identifier,
                label: voice.name,
                provider: SpeechProviders.system,
                available: true,
                isDefault: voice.identifier == defaultSystem
            )
        }
    }

    /// OpenAI has no voices endpoint, so only the HudTTS adapter default is known.
    static func openaiVoices() -> [SpeechVoiceInfo] {
        let adapter = HudTTSProviders.OpenAI()
        return [SpeechVoiceInfo(
            id: adapter.defaultVoice,
            label: adapter.defaultVoice.capitalized,
            provider: SpeechProviders.openai,
            available: true,
            isDefault: true
        )]
    }

    private func loadElevenLabs() async -> SpeechVoiceCatalogState {
        let adapter = HudTTSProviders.ElevenLabs()
        guard let keyName = adapter.credentialKey else {
            return .unavailable("ElevenLabs is missing a credential key.")
        }
        let data: Data?
        do {
            data = try credentialSource.vault.get(keyName)
        } catch {
            return .failed("Could not read Keychain. Try reopening Settings.")
        }
        guard SpeechCredentialAvailability.isAvailable(credentialKey: keyName, data: data),
              let data,
              let apiKey = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return .unavailable("Save an API key to load voices from ElevenLabs.")
        }

        do {
            let voices = try await elevenLabsFetch(apiKey)
            if voices.isEmpty {
                return .empty("ElevenLabs returned no voices for this key.")
            }
            return .ready(voices)
        } catch {
            return .failed(SpeechErrorRedactor.message(from: error))
        }
    }

    private func loadLocal(_ engine: any SpeechLocalSynthesizing, name: String) async -> SpeechVoiceCatalogState {
        let status = await engine.probe()
        guard status.available else {
            return .unavailable(status.detail ?? "\(name) is unavailable.")
        }
        let voices = engine.cachedVoices()
        if voices.isEmpty {
            return .empty("\(name) reported no voices.")
        }
        return .ready(voices)
    }
}

enum SpeechElevenLabsVoiceCatalog {
    /// GET /v2/voices, first page only (`page_size=100`).
    static func fetch(apiKey: String, session: URLSession) async throws -> [SpeechVoiceInfo] {
        var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")
        components?.queryItems = [URLQueryItem(name: "page_size", value: "100")]
        guard let url = components?.url else {
            throw SpeechQueueError.providerFailed("Could not build the ElevenLabs voices URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpeechQueueError.providerFailed("ElevenLabs voices returned no HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SpeechQueueError.providerFailed(
                body.isEmpty
                    ? "ElevenLabs voices failed (HTTP \(http.statusCode))."
                    : SpeechErrorRedactor.redact(body)
            )
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["voices"] as? [[String: Any]]
        else {
            throw SpeechQueueError.providerFailed("ElevenLabs voices response was not a voice list.")
        }
        let defaultID = HudTTSProviders.ElevenLabs().defaultVoice
        let parsed: [SpeechVoiceInfo] = raw.compactMap { voice in
            guard let id = voice["voice_id"] as? String, !id.isEmpty else { return nil }
            let name = (voice["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechVoiceInfo(
                id: id,
                label: (name?.isEmpty == false) ? name! : id,
                provider: SpeechProviders.elevenlabs,
                available: true,
                isDefault: id == defaultID
            )
        }
        if parsed.contains(where: \.isDefault) { return parsed }
        return parsed.enumerated().map { index, voice in
            SpeechVoiceInfo(
                id: voice.id,
                label: voice.label,
                provider: voice.provider,
                available: voice.available,
                isDefault: index == 0
            )
        }
    }
}

@MainActor
final class SpeechVoiceCatalogStore: ObservableObject {
    static let shared = SpeechVoiceCatalogStore()

    @Published private(set) var states: [String: SpeechVoiceCatalogState] = [:]

    private var loader: SpeechVoiceCatalogLoader

    init(loader: SpeechVoiceCatalogLoader? = nil) {
        self.loader = loader ?? SpeechVoiceCatalogLoader()
    }

    func replaceLoader(_ loader: SpeechVoiceCatalogLoader) {
        self.loader = loader
    }

    func state(for provider: String) -> SpeechVoiceCatalogState? {
        states[provider]
    }

    func refresh(provider: String) async {
        states[provider] = .loading
        states[provider] = await loader.load(provider: provider)
    }

    func refreshListedProviders() async {
        var providers = [SpeechProviders.system, SpeechProviders.openai, SpeechProviders.elevenlabs]
        if SpeechKokoro.isCompiledIn {
            providers.append(SpeechProviders.kokoro)
        }
        if SpeechPhonon.isCompiledIn {
            providers.append(SpeechProviders.phonon)
        }
        for provider in providers {
            await refresh(provider: provider)
        }
    }
}
