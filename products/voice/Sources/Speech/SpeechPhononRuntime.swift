#if canImport(PhononTTS)
import CryptoKit
import Foundation
import HudsonUIAudio
import PhononTTS

/// Phonon 31m (Gradium, Apache 2.0) renders in-process, its flow model on the
/// Neural Engine. Nothing downloads or loads until the first Phonon request;
/// the model then stays resident, using about 95 MB.
enum SpeechPhononRuntime {
    static let modelID = "gradium/phonon-31m-en"
    static let voiceID = "Edwin"
    /// The voices in the release's model bundle. Fixed, so probing Phonon
    /// never downloads or loads the model.
    static let voiceIDs = [
        "Alfie", "Azgorath", "Bryony", "Captain Silas Blackwater", "Delia", "Easton", "Edwin",
        "Elodie-Rose", "Everly", "Fairy Godmother", "Fennick the Young Elf", "Freya",
        "Grub the Ogre", "Hadley", "Harper", "Hugh", "Imogen", "Juniper", "Lottie", "Maeve",
        "Master Aldric", "Micah", "Miles", "Morwenna of the Deep", "Old Mortlake", "Pippa",
        "Preston", "Russell", "Sir Bramwell", "Spencer", "Teddy", "The Snow Queen",
        "The Thing Under the Stairs", "Toby", "Trevor", "Vyrmathrax the Ancient", "Zoey", "default",
    ]
    static let status = SpeechLocalStatus(
        available: true, modelId: modelID, voiceId: voiceID, detail: nil,
        voices: voiceIDs.map {
            SpeechVoiceInfo(id: $0, label: $0, provider: SpeechProviders.phonon,
                            available: true, isDefault: $0 == voiceID)
        }
    )
    private static let engine = SpeechPhononEngine()

    /// Phonon's speaking rate is fixed when the model is exported, so `rate` is not applied.
    static func synthesizePhonon(text: String, voice: String?, rate: Double, model: String?) async throws -> HudTTSResult {
        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard selectedModel.isEmpty || selectedModel.lowercased().contains("phonon") else {
            throw SpeechQueueError.providerFailed("Phonon requires a Phonon model")
        }
        let requested = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedVoice = requested.isEmpty ? voiceID : requested
        guard voiceIDs.contains(selectedVoice) else {
            throw SpeechQueueError.unknownVoice(selectedVoice, provider: SpeechProviders.phonon, listedUnder: nil)
        }
        let audio: Data
        do {
            audio = try await engine.synthesize(text: text, voice: selectedVoice)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechQueueError {
            throw error
        } catch {
            throw SpeechQueueError.providerFailed("Phonon failed: " + SpeechErrorRedactor.message(from: error))
        }
        return HudTTSResult(audioData: audio, format: .wav,
            providerID: HudTTSProviderID(rawValue: SpeechProviders.phonon), voice: selectedVoice)
    }
}

/// Owns the loaded model. The first request downloads Gradium's Core ML bundle
/// (137 MB), checks it against a pinned SHA-256, unpacks it and loads it.
/// The first load compiles the models for this Mac. A failed load is retried
/// on the next request.
actor SpeechPhononEngine {
    static let release = "0.4.0"
    static let bundleURL = URL(string: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip")!
    static let bundleSHA256 = "10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436"
    static let bundleFolder = "phonon-31m-en-coreml"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speech/Phonon/\(release)", isDirectory: true)
    }

    private var loading: Task<Phonon, Error>?

    func synthesize(text: String, voice: String) async throws -> Data {
        let tts = try await loaded()
        try Task.checkCancellation()
        if tts.voice != voice { try await tts.setVoice(voice) }
        let samples = try await tts.synthesize(text)
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw SpeechQueueError.providerFailed("Phonon found nothing to speak")
        }
        return SpeechWAV.data(from: samples, sampleRate: Int(Phonon.sampleRate))
    }

    private func loaded() async throws -> Phonon {
        if let loading { return try await loading.value }
        let task = Task { () throws -> Phonon in
            let models = try await Self.installedModels()
            return try await Phonon.load(models: models, language: .english)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }

    /// The unpacked bundle, downloading it first when it is missing or incomplete.
    static func installedModels() async throws -> URL {
        let models = directory.appendingPathComponent(bundleFolder, isDirectory: true)
        if PhononModels.isInstalled(at: models) { return models }
        let fm = FileManager.default
        let (archive, response) = try await URLSession.shared.download(from: bundleURL)
        defer { try? fm.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpeechQueueError.providerFailed("Phonon model download failed: HTTP \(http.statusCode)")
        }
        guard try sha256(of: archive) == bundleSHA256 else {
            throw SpeechQueueError.providerFailed("Phonon model download did not match its checksum")
        }
        // Unpacked beside the destination, so the final move is a rename on one volume.
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try unzip(archive, into: staging)
        let unpacked = staging.appendingPathComponent(bundleFolder, isDirectory: true)
        guard PhononModels.isInstalled(at: unpacked) else {
            throw SpeechQueueError.providerFailed("Phonon model bundle is incomplete")
        }
        try? fm.removeItem(at: models)
        try fm.moveItem(at: unpacked, to: models)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        return models
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SpeechQueueError.providerFailed("Phonon model bundle could not be unpacked")
        }
    }
}
#endif

/// 16-bit mono PCM WAV, peak-normalized.
enum SpeechWAV {
    static func data(from samples: [Float], sampleRate: Int) -> Data {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain: Float = peak > 0 ? 0.95 / peak : 1
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample * gain)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }
}
