import AVFoundation
import Foundation
import HudsonUI
import HudsonUIAudio

/// Wraps the existing Lattices voice vault. Same service as chat/voice
/// credentials (`dev.lattices.app.voice`). Never logs secret values.
struct LatticesSpeechCredentialSource: HudTTSCredentialSource {
    var vault: HudVault

    init(vault: HudVault = HudVault(service: "dev.lattices.app.voice")) {
        self.vault = vault
    }

    func get(_ key: String) async throws -> Data? {
        try vault.get(key)
    }
}

@MainActor
final class HudsonSpeechSynthesizer: SpeechSynthesizing {
    private let tts: HudTTS
    private let cache: HudSpeechCache
    private let kokoro: any SpeechLocalSynthesizing
    private let phonon: any SpeechLocalSynthesizing

    init(
        tts: HudTTS,
        cache: HudSpeechCache,
        kokoro: (any SpeechLocalSynthesizing)? = nil,
        phonon: (any SpeechLocalSynthesizing)? = nil
    ) {
        self.tts = tts
        self.cache = cache
        self.kokoro = kokoro ?? SpeechKokoro.shared
        self.phonon = phonon ?? SpeechPhonon.shared
    }

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAudioPayload {
        let providerID = HudTTSProviderID(rawValue: request.provider)
        let settings = request.voiceSettings.map {
            HudTTSVoiceSettings(
                stability: $0.stability,
                similarityBoost: $0.similarityBoost,
                style: $0.style,
                useSpeakerBoost: $0.useSpeakerBoost
            )
        }
        let local: (any SpeechLocalSynthesizing)? = switch request.provider {
        case SpeechProviders.kokoro: kokoro
        case SpeechProviders.phonon: phonon
        default: nil
        }
        let defaultVoice = request.provider == SpeechProviders.system
            ? HudSystemSpeechDefaults.defaultVoiceIdentifier
            : local?.cachedStatus().voiceId
        // Local renders are cached under the engine's model id. Renders from
        // the retired mlx-audio engine, cached without one, never replay.
        var model = request.model
        if let local,
           (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model?.lowercased().contains(request.provider) == true {
            model = local.cachedStatus().modelId
        }
        let synthesis = HudTTSRequest(
            text: request.text,
            voice: request.voice ?? defaultVoice,
            rate: request.rate,
            model: model,
            instructions: request.instructions,
            voiceSettings: settings
        )
        let result = try await cache.synthesize(
            synthesis, providerID: providerID, namespace: "dev.lattices.app.voice",
            policy: request.cachePolicy == .fresh ? .fresh : .reuse
        ) { [tts, local] input, provider in
            if let local {
                return try await local.synthesize(
                    text: input.text,
                    voice: input.voice,
                    rate: input.rate,
                    model: input.model
                )
            }
            return try await tts.synthesize(input.text, providerID: provider,
                                           voice: input.voice, rate: input.rate,
                                           model: input.model, instructions: input.instructions,
                                           voiceSettings: input.voiceSettings)
        }
        let format: SpeechAudioFormat
        switch result.format {
        case .mp3: format = .mp3
        case .wav: format = .wav
        case .caf: format = .caf
        }
        return SpeechAudioPayload(
            data: result.audioData,
            format: format,
            provider: result.providerID.rawValue,
            voice: result.voice
        )
    }
}

@MainActor
final class HudsonSpeechPlayerAdapter: SpeechPlaying {
    private let player: HudSpeechPlayer
    private var paused = false

    init(player: HudSpeechPlayer? = nil) {
        self.player = player ?? HudSpeechPlayer()
    }

    var isPlaying: Bool { player.isPlaying }
    var currentTime: TimeInterval { player.currentTime }
    var duration: TimeInterval { player.duration }

    func play(data: Data, format: SpeechAudioFormat, failure: ((Error) -> Void)?, completion: (() -> Void)?) throws {
        paused = false
        let hudFormat: HudTTSAudioFormat
        switch format {
        case .mp3: hudFormat = .mp3
        case .wav: hudFormat = .wav
        case .caf: hudFormat = .caf
        }
        try player.play(data: data, format: hudFormat, failure: failure, completion: completion)
    }

    func pause() {
        guard player.isPlaying else { return }
        player.pauseOrResume()
        paused = !player.isPlaying
    }

    func resume() {
        guard paused || !player.isPlaying else { return }
        if !player.isPlaying {
            player.pauseOrResume()
        }
        paused = false
    }

    func seek(to time: TimeInterval) -> Bool {
        player.seek(to: time)
    }

    func stop() {
        paused = false
        player.stop()
    }
}

@MainActor
final class HudsonSpeechVoiceCatalog: SpeechVoiceListing {
    private let credentialSource: LatticesSpeechCredentialSource
    private let adapters: [any HudTTSProviderAdapter]
    private let kokoro: any SpeechLocalSynthesizing
    private let phonon: any SpeechLocalSynthesizing

    init(
        credentialSource: LatticesSpeechCredentialSource = LatticesSpeechCredentialSource(),
        adapters: [any HudTTSProviderAdapter] = SpeechProviders.cloudAdapters(),
        kokoro: (any SpeechLocalSynthesizing)? = nil,
        phonon: (any SpeechLocalSynthesizing)? = nil
    ) {
        self.credentialSource = credentialSource
        self.adapters = adapters
        self.kokoro = kokoro ?? SpeechKokoro.shared
        self.phonon = phonon ?? SpeechPhonon.shared
    }

    func voices() -> [SpeechVoiceInfo] {
        var items: [SpeechVoiceInfo] = []
        items.append(contentsOf: marked(SpeechVoiceCatalogLoader.systemVoices()))
        items.append(contentsOf: marked(SpeechVoiceCatalogLoader.openaiVoices()))

        let elevenLabs = SpeechVoiceCatalogStore.shared.state(for: SpeechProviders.elevenlabs)?.voices ?? []
        if elevenLabs.isEmpty {
            let adapter = adapters.first(where: { $0.providerID.rawValue == SpeechProviders.elevenlabs })
            let key = adapter?.credentialKey
            let data = key.flatMap { try? credentialSource.vault.get($0) }
            let available = SpeechCredentialAvailability.isAvailable(credentialKey: key, data: data)
            if let adapter {
                items.append(contentsOf: marked([SpeechVoiceInfo(
                    id: adapter.defaultVoice,
                    label: "\(adapter.displayName) default",
                    provider: adapter.providerID.rawValue,
                    available: available,
                    isDefault: true
                )]))
            }
        } else {
            items.append(contentsOf: marked(elevenLabs))
        }

        if SpeechKokoro.isCompiledIn {
            items.append(contentsOf: localVoices(kokoro, label: "Kokoro", provider: SpeechProviders.kokoro))
        }
        if SpeechPhonon.isCompiledIn {
            items.append(contentsOf: localVoices(phonon, label: "Phonon", provider: SpeechProviders.phonon))
        }
        return items
    }

    private func localVoices(_ engine: any SpeechLocalSynthesizing, label: String, provider: String) -> [SpeechVoiceInfo] {
        let cached = engine.cachedVoices()
        guard cached.isEmpty else { return marked(cached) }
        let status = engine.cachedStatus()
        return marked([SpeechVoiceInfo(
            id: status.voiceId,
            label: label,
            provider: provider,
            available: status.available,
            isDefault: true
        )])
    }

    private func marked(_ voices: [SpeechVoiceInfo]) -> [SpeechVoiceInfo] {
        guard let provider = voices.first?.provider else { return voices }
        let preferred = SpeechVoicePreferences.shared.preferredVoice(for: provider)
        return voices.map { voice in
            var copy = voice
            if let preferred {
                copy.isDefault = copy.id == preferred
            }
            return copy
        }
    }
}

enum SpeechRuntime {
    /// Local confirmations share playback controls and exact-text audio caching
    /// with agent speech. System output does not require cloud credentials.
    @MainActor
    @discardableResult
    static func enqueueUICue(_ text: String, queue: SpeechQueue = .shared) throws -> SpeechJob {
        try queue.enqueue(SpeechEnqueueRequest(
            text: text, provider: "system", model: nil, voice: nil, rate: 1,
            instructions: nil, voiceSettings: nil, cachePolicy: .reuse,
            source: SpeechSourceMetadata(kind: "ui", label: "Voice", taskId: nil, sessionId: nil)
        ), playbackDeadline: Date().addingTimeInterval(2))
    }

    @MainActor
    static func start(queue: SpeechQueue = .shared, presentHUD: Bool = true, refreshVoices: Bool = true) {
        let vault = HudVault(service: "dev.lattices.app.voice")
        let credentials = LatticesSpeechCredentialSource(vault: vault)
        let adapters = SpeechProviders.cloudAdapters()
        let tts = HudTTS(credentialSource: credentials, adapters: adapters)
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lattices/Speech", isDirectory: true)
        let speechCache = HudSpeechCache(directory: cacheDirectory)
        queue.install(
            synthesizer: HudsonSpeechSynthesizer(tts: tts, cache: speechCache),
            player: HudsonSpeechPlayerAdapter(),
            voiceCatalog: HudsonSpeechVoiceCatalog(
                credentialSource: credentials,
                adapters: adapters
            )
        )
        queue.onSnapshotChange = { snapshot in
            if presentHUD { SpeechPlaybackHUD.shared.reflect(snapshot) }
            SpeechServer.shared.broadcast(DaemonEvent(event: "speech.changed", data: snapshot.json()))
        }
        if presentHUD { SpeechPlaybackHUD.shared.bind(queue) }
        DiagnosticLog.shared.info("Speech runtime ready (HudsonUIAudio with shared speech cache)")
        if refreshVoices { Task { await SpeechVoiceCatalogStore.shared.refreshListedProviders() } }
    }

    @MainActor
    @discardableResult
    static func enqueuePreview(
        provider: String,
        voice: String?,
        queue: SpeechQueue = .shared
    ) throws -> SpeechJob {
        let job = try queue.enqueue(SpeechEnqueueRequest(
            text: SpeechVoicePreferences.previewPhrase,
            provider: provider,
            model: nil,
            voice: voice,
            rate: 1,
            instructions: nil,
            voiceSettings: nil,
            cachePolicy: .reuse,
            source: SpeechSourceMetadata(
                kind: "preview", label: "Voice Settings", taskId: nil, sessionId: nil
            )
        ))
        SpeechPlaybackHUD.shared.showFromMenu()
        return job
    }
}
