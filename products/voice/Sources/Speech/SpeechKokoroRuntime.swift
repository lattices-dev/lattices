#if canImport(FluidAudio)
import Foundation
import FluidAudio
import HudsonUIAudio
import NaturalLanguage

/// Kokoro 82M renders in-process on the Neural Engine through FluidAudio's
/// KokoroAne chain. Nothing loads until the first Kokoro request; the model
/// then stays resident.
enum SpeechKokoroRuntime {
    static let modelID = "FluidInference/kokoro-82m-coreml"
    static let voiceID = KokoroAneConstants.defaultVoice
    /// American voices only. FluidAudio's English frontend phonemizes en-US,
    /// so a British voice would still speak with American pronunciation.
    static let voiceIDs = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole",
        "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa",
    ]
    /// Fixed, so probing Kokoro never loads the model or touches the network.
    static let status = SpeechLocalStatus(
        available: true, modelId: modelID, voiceId: voiceID, detail: nil,
        voices: voiceIDs.map {
            SpeechVoiceInfo(id: $0, label: $0, provider: SpeechProviders.kokoro,
                            available: true, isDefault: $0 == voiceID)
        }
    )
    private static let engine = SpeechKokoroEngine()

    static func synthesizeKokoro(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard selectedModel.isEmpty || selectedModel.lowercased().contains("kokoro") else {
            throw SpeechQueueError.providerFailed("Kokoro requires a Kokoro model")
        }
        let requested = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedVoice = requested.isEmpty ? voiceID : requested
        guard voiceIDs.contains(selectedVoice) else {
            throw SpeechQueueError.unknownVoice(selectedVoice, provider: SpeechProviders.kokoro, listedUnder: nil)
        }
        let audio: Data
        do {
            audio = try await engine.synthesize(text: text, voice: selectedVoice, speed: Float(rate))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechQueueError {
            throw error
        } catch {
            throw SpeechQueueError.providerFailed("Kokoro failed: " + SpeechErrorRedactor.message(from: error))
        }
        return HudTTSResult(audioData: audio, format: .wav,
            providerID: HudTTSProviderID(rawValue: SpeechProviders.kokoro), voice: selectedVoice)
    }
}

/// Owns the KokoroAne chain. The first request downloads the model and lexicon
/// if needed (about 90 MB) and loads them. The loaded chain holds about 600 MB, so it
/// unloads after `idle` without requests; reloading takes a few seconds.
/// A failed load is retried on the next request.
actor SpeechKokoroEngine {
    private let manager = KokoroAneManager()
    private let idle: Duration
    private var loading: Task<URL, Error>?
    private var active = 0
    private var generation = 0
    private var idleTimer: Task<Void, Never>?

    init(idle: Duration = .seconds(300)) {
        self.idle = idle
    }

    var isLoaded: Bool { loading != nil }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        idleTimer?.cancel()
        active += 1
        generation += 1
        defer {
            active -= 1
            if active == 0 { scheduleUnload() }
        }
        let repository = try await loadedRepository()
        try Task.checkCancellation()
        try await provision(voice: voice, repository: repository)
        let speed = min(max(speed, 0.25), 4)
        var phonemes: [String] = []
        for sentence in SpeechKokoroChunker.sentences(in: text) {
            try Task.checkCancellation()
            let ipa = try await manager.phonemes(for: sentence).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ipa.isEmpty { phonemes.append(ipa) }
        }
        var clips: [[Float]] = []
        for chunk in SpeechKokoroChunker.pack(phonemes, budget: SpeechKokoroChunker.budget(speed: speed)) {
            try Task.checkCancellation()
            clips += try await render(chunk, voice: voice, speed: speed)
        }
        let samples = SpeechKokoroChunker.join(clips, sampleRate: KokoroAneConstants.sampleRate)
        guard !samples.isEmpty else {
            throw SpeechQueueError.providerFailed("Kokoro found nothing to speak")
        }
        // Peak-normalized, the same as FluidAudio's own English WAV output.
        return try AudioWAV.data(from: samples, sampleRate: Double(KokoroAneConstants.sampleRate), normalize: true)
    }

    /// Renders one chunk, halving it when the chain's frame cap rejects it.
    private func render(_ phonemes: String, voice: String, speed: Float) async throws -> [[Float]] {
        do {
            let result = try await manager.synthesizeFromPhonemesDetailed(phonemes, voice: voice, speed: speed)
            return [result.samples]
        } catch {
            guard SpeechKokoroChunker.isTooLong(error), let (head, tail) = SpeechKokoroChunker.halve(phonemes) else {
                throw error
            }
            let first = try await render(head, voice: voice, speed: speed)
            try Task.checkCancellation()
            return try await first + render(tail, voice: voice, speed: speed)
        }
    }

    private func scheduleUnload() {
        let token = generation
        idleTimer = Task { [idle] in
            guard (try? await Task.sleep(for: idle)) != nil else { return }
            await unloadIfIdle(token)
        }
    }

    /// A request that started after the timer was set keeps the chain loaded.
    private func unloadIfIdle(_ token: Int) async {
        guard token == generation, active == 0, loading != nil else { return }
        loading = nil
        await manager.cleanup()
    }

    private func loadedRepository() async throws -> URL {
        if let loading { return try await loading.value }
        let manager = manager
        let task = Task { () throws -> URL in
            let repository = try await KokoroAneResourceDownloader.ensureModels()
            try await manager.initialize()
            return repository
        }
        loading = task
        do {
            return try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }

    /// FluidAudio publishes only af_heart as a `.bin` voice pack. Other voices
    /// are converted once from the repo's JSON and cached beside it.
    private func provision(voice: String, repository: URL) async throws {
        let pack = repository.appendingPathComponent("\(voice).bin")
        guard !FileManager.default.fileExists(atPath: pack.path) else { return }
        let url = try ModelRegistry.resolveModel(Repo.kokoroAne.remotePath, "voices/\(voice).json")
        let json = try await AssetDownloader.fetchData(from: url, description: "Kokoro voice \(voice)")
        try SpeechKokoroVoicePack.binary(fromJSON: json).write(to: pack, options: .atomic)
    }
}

/// Fits text to the chain's limits: at most 510 phonemes and 2,000 acoustic
/// frames per call. Slower speech takes more frames per phoneme, so the
/// budget shrinks with speed.
enum SpeechKokoroChunker {
    /// About 2.8 frames per phoneme at speed 1; 571 leaves room for 3.5.
    static func budget(speed: Float) -> Int {
        min(400, max(1, Int(571 * speed)))
    }

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    /// Packs phonemized sentences into as few chunks as the budget allows.
    static func pack(_ sentences: [String], budget: Int) -> [String] {
        greedy(sentences.flatMap { split($0, budget: budget) }, budget: budget)
    }

    /// Splits one phoneme string at word gaps. A word longer than the budget is cut.
    static func split(_ phonemes: String, budget: Int) -> [String] {
        guard phonemes.count > budget else { return [phonemes] }
        let words = phonemes.split(separator: " ").flatMap { word in
            stride(from: 0, to: word.count, by: budget).map { start in
                String(word.dropFirst(start).prefix(budget))
            }
        }
        return greedy(words, budget: budget)
    }

    /// Cuts a chunk at the word gap nearest its middle, or at the middle if it has none.
    static func halve(_ phonemes: String) -> (String, String)? {
        let characters = Array(phonemes)
        guard characters.count > 1 else { return nil }
        let middle = characters.count / 2
        let gap = characters.indices
            .filter { characters[$0] == " " && $0 > 0 && $0 < characters.count - 1 }
            .min { abs($0 - middle) < abs($1 - middle) }
        let head = String(characters[..<(gap ?? middle)]).trimmingCharacters(in: .whitespaces)
        let tail = String(characters[(gap.map { $0 + 1 } ?? middle)...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return (head, tail)
    }

    static func isTooLong(_ error: Error) -> Bool {
        guard let error = error as? KokoroAneError else { return false }
        switch error {
        case .acousticFramesExceedCap, .phonemeSequenceTooLong: return true
        default: return false
        }
    }

    /// Kokoro pads each render with about 0.3 s of lead silence and 0.5 s of
    /// tail. Joins shorten both so seams sound like sentence pauses. The first
    /// lead and last tail stay, so an output device waking up eats silence,
    /// not speech.
    static func join(_ clips: [[Float]], sampleRate: Int) -> [Float] {
        let keepTail = sampleRate * 12 / 100
        let keepLead = sampleRate * 6 / 100
        let gap = sampleRate * 15 / 100
        let spoken = clips.compactMap { clip in speechBounds(clip).map { (clip, $0) } }
        var joined: [Float] = []
        for (index, (clip, speech)) in spoken.enumerated() {
            let start = index == 0 ? 0 : max(0, speech.lowerBound - keepLead)
            let end = index == spoken.count - 1 ? clip.count : min(clip.count, speech.upperBound + keepTail)
            if index > 0 { joined += repeatElement(Float(0), count: gap) }
            joined += clip[start..<end]
        }
        return joined
    }

    /// The span louder than 1% of the clip's peak. Kokoro's padding is digital silence.
    static func speechBounds(_ clip: [Float]) -> Range<Int>? {
        let peak = clip.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return nil }
        let threshold = peak / 100
        guard let first = clip.firstIndex(where: { abs($0) > threshold }),
              let last = clip.lastIndex(where: { abs($0) > threshold })
        else { return nil }
        return first..<(last + 1)
    }

    private static func greedy(_ pieces: [String], budget: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for piece in pieces where !piece.isEmpty {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= budget {
                current += " " + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Voice JSON holds an `embedding` plus rows "1"..."510" of 256 floats.
/// KokoroAne reads those rows as one flat native fp32 file.
enum SpeechKokoroVoicePack {
    static func binary(fromJSON json: Data) throws -> Data {
        let rows = try JSONDecoder().decode([String: [Float]].self, from: json)
        let count = KokoroAneConstants.voicePackRows, width = KokoroAneConstants.voicePackCols
        var binary = Data(capacity: count * width * MemoryLayout<Float>.size)
        for row in 1...count {
            guard let values = rows[String(row)], values.count == width else {
                throw KokoroAneError.invalidVoicePack("row \(row) is missing or not \(width) floats wide")
            }
            values.withUnsafeBytes { binary.append(contentsOf: $0) }
        }
        return binary
    }
}
#endif
