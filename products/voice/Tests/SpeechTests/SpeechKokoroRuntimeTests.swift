#if canImport(FluidAudio)
import AVFoundation
import FluidAudio
import XCTest
@testable import SpeechAppRuntime

final class SpeechKokoroRuntimeTests: XCTestCase {
    func testCatalogIsTwentyAmericanVoicesWithAfHeartDefault() {
        let status = SpeechKokoroRuntime.status
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.modelId, "FluidInference/kokoro-82m-coreml")
        XCTAssertEqual(status.voiceId, "af_heart")
        XCTAssertEqual(status.voices.count, 20)
        XCTAssertEqual(status.voices.map(\.id), SpeechKokoroRuntime.voiceIDs)
        XCTAssertEqual(status.voices.map(\.label), SpeechKokoroRuntime.voiceIDs)
        XCTAssertEqual(status.voices.filter(\.isDefault).map(\.id), ["af_heart"])
        XCTAssertTrue(status.voices.allSatisfy { $0.provider == "kokoro" && $0.available })
        XCTAssertTrue(status.voices.allSatisfy { $0.id.hasPrefix("af_") || $0.id.hasPrefix("am_") })
    }

    func testRejectsOtherModelsAndUnlistedVoicesBeforeLoading() async {
        do {
            _ = try await SpeechKokoroRuntime.synthesizeKokoro(text: "Hi", voice: nil, rate: 1, model: "tts-1")
            XCTFail("A non-Kokoro model must be rejected")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .providerFailed("Kokoro requires a Kokoro model"))
        }
        do {
            _ = try await SpeechKokoroRuntime.synthesizeKokoro(text: "Hi", voice: "bf_emma", rate: 1, model: nil)
            XCTFail("A British voice is not in the catalog")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .unknownVoice("bf_emma", provider: "kokoro", listedUnder: nil))
        }
        do {
            _ = try await SpeechKokoroRuntime.synthesizeKokoro(text: "Hi", voice: "../vocab", rate: 1, model: nil)
            XCTFail("A voice id must never reach the file system unchecked")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .unknownVoice("../vocab", provider: "kokoro", listedUnder: nil))
        }
    }

    func testBudgetShrinksWithSpeedAndStaysUnderThePhonemeCap() {
        XCTAssertEqual(SpeechKokoroChunker.budget(speed: 1), 400)
        XCTAssertEqual(SpeechKokoroChunker.budget(speed: 4), 400)
        XCTAssertEqual(SpeechKokoroChunker.budget(speed: 0.5), 285)
        XCTAssertEqual(SpeechKokoroChunker.budget(speed: 0.25), 142)
        XCTAssertEqual(SpeechKokoroChunker.budget(speed: 0), 1)
        for speed: Float in [0.25, 0.5, 1, 2, 4] {
            XCTAssertLessThanOrEqual(SpeechKokoroChunker.budget(speed: speed), KokoroAneConstants.maxPhonemeLength)
        }
    }

    func testSentencesSplitOnSentenceBoundaries() {
        XCTAssertEqual(
            SpeechKokoroChunker.sentences(in: "  The build passed. Ship it?\n\nYes!  "),
            ["The build passed.", "Ship it?", "Yes!"]
        )
        XCTAssertEqual(SpeechKokoroChunker.sentences(in: " \n "), [])
    }

    func testSplitBreaksAtWordGapsAndCutsOverlongWords() {
        XCTAssertEqual(SpeechKokoroChunker.split("aa bb", budget: 5), ["aa bb"])
        XCTAssertEqual(SpeechKokoroChunker.split("aa bb cc", budget: 5), ["aa bb", "cc"])
        XCTAssertEqual(SpeechKokoroChunker.split("abcdefghij", budget: 4), ["abcd", "efgh", "ij"])
    }

    func testPackFillsChunksUpToTheBudgetWithoutLosingPhonemes() {
        XCTAssertEqual(
            SpeechKokoroChunker.pack(["ab cd", "ef", "gh ij kl"], budget: 8),
            ["ab cd ef", "gh ij kl"]
        )
        let sentences = (0..<40).map { index in
            (0...(index % 7)).map { word in String(repeating: "ə", count: 1 + (index + word) % 9) }
                .joined(separator: " ")
        }
        for budget in [3, 10, 57, 400] {
            let chunks = SpeechKokoroChunker.pack(sentences, budget: budget)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= budget }, "budget \(budget)")
            XCTAssertEqual(
                chunks.joined().filter { $0 != " " },
                sentences.joined().filter { $0 != " " },
                "budget \(budget)"
            )
        }
    }

    func testHalveCutsAtTheGapNearestTheMiddle() {
        XCTAssertEqual(SpeechKokoroChunker.halve("ab cd ef").map { [$0.0, $0.1] }, ["ab cd", "ef"])
        XCTAssertEqual(SpeechKokoroChunker.halve("abc def").map { [$0.0, $0.1] }, ["abc", "def"])
        XCTAssertEqual(SpeechKokoroChunker.halve("abcdef").map { [$0.0, $0.1] }, ["abc", "def"])
        XCTAssertNil(SpeechKokoroChunker.halve("a"))
        XCTAssertNil(SpeechKokoroChunker.halve(" a"))
    }

    func testOnlyLengthErrorsAreRetriedAsHalves() {
        XCTAssertTrue(SpeechKokoroChunker.isTooLong(KokoroAneError.phonemeSequenceTooLong(600)))
        XCTAssertTrue(SpeechKokoroChunker.isTooLong(KokoroAneError.acousticFramesExceedCap(have: 2_100, cap: 2_000)))
        XCTAssertFalse(SpeechKokoroChunker.isTooLong(KokoroAneError.downloadFailed("offline")))
        XCTAssertFalse(SpeechKokoroChunker.isTooLong(CancellationError()))
    }

    func testJoinKeepsOuterSilenceAndShortensSeams() {
        let rate = 24_000
        // 0.3 s lead, 0.2 s of speech, 0.5 s tail: Kokoro's shape.
        let clip = [Float](repeating: 0, count: 7_200)
            + [Float](repeating: 0.5, count: 4_800)
            + [Float](repeating: 0, count: 12_000)
        let silent = [Float](repeating: 0, count: 2_400)
        XCTAssertEqual(SpeechKokoroChunker.speechBounds(clip), 7_200..<12_000)
        XCTAssertNil(SpeechKokoroChunker.speechBounds(silent))

        XCTAssertEqual(SpeechKokoroChunker.join([clip], sampleRate: rate), clip)
        let joined = SpeechKokoroChunker.join([clip, silent, clip, silent], sampleRate: rate)
        // First clip keeps its lead and 0.12 s of tail; a 0.15 s gap; the
        // last spoken clip keeps 0.06 s of lead and its whole tail.
        XCTAssertEqual(joined.count, (12_000 + 2_880) + 3_600 + (24_000 - 5_760))
        XCTAssertEqual(Array(joined.prefix(7_200)), [Float](repeating: 0, count: 7_200))
        XCTAssertEqual(joined.suffix(12_000).max(), 0)
        XCTAssertEqual(joined.filter { $0 != 0 }.count, 2 * 4_800, "No speech is trimmed")
        XCTAssertEqual(SpeechKokoroChunker.join([silent, silent], sampleRate: rate), [])
    }

    func testVoicePackBinaryIsRowsOneThroughFiveTenAsFloat32() throws {
        var rows: [String: [Float]] = ["embedding": [Float](repeating: -1, count: 256)]
        for row in 1...510 {
            rows[String(row)] = (0..<256).map { Float(row) + Float($0) / 1_000 }
        }
        let binary = try SpeechKokoroVoicePack.binary(fromJSON: JSONEncoder().encode(rows))
        XCTAssertEqual(binary.count, 522_240)
        let floats = binary.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(floats[0], 1)
        XCTAssertEqual(floats[255], 1.255, accuracy: 1e-6)
        XCTAssertEqual(floats[256], 2)
        XCTAssertEqual(floats[509 * 256 + 3], 510.003, accuracy: 1e-4)
        XCTAssertFalse(floats.contains(-1), "The embedding row is not part of the pack")

        var missing = rows
        missing["7"] = nil
        XCTAssertThrowsError(try SpeechKokoroVoicePack.binary(fromJSON: JSONEncoder().encode(missing))) { error in
            guard case KokoroAneError.invalidVoicePack(let detail)? = error as? KokoroAneError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(detail.contains("row 7"))
        }
        var narrow = rows
        narrow["3"] = [Float](repeating: 0, count: 255)
        XCTAssertThrowsError(try SpeechKokoroVoicePack.binary(fromJSON: JSONEncoder().encode(narrow)))
    }

    // MARK: - Live (VOICE_KOKORO_LIVE=1)

    /// Downloads the model on first run. VOICE_KOKORO_LIVE_OUT=<dir> keeps the WAVs.
    func testLiveRendersOnTheNeuralEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VOICE_KOKORO_LIVE"] == "1", "Set VOICE_KOKORO_LIVE=1 to render with the real model")
        let output = environment["VOICE_KOKORO_LIVE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        print(String(format: "kokoro footprint before load: %.0f MB", Self.footprintMegabytes()))

        func render(_ name: String, _ text: String, voice: String? = nil, rate: Double = 1) async throws -> (seconds: Double, audio: Double) {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await SpeechKokoroRuntime.synthesizeKokoro(text: text, voice: voice, rate: rate, model: nil)
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let audio = try AVAudioPlayer(data: result.audioData).duration
            print(String(format: "kokoro %@ (%@): %.2f s for %.2f s of audio, RTF %.3f, footprint %.0f MB",
                         name, result.voice, seconds, audio, seconds / audio, Self.footprintMegabytes()))
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try result.audioData.write(to: output.appendingPathComponent("\(name).wav"))
            }
            XCTAssertEqual(result.voice, voice ?? "af_heart")
            XCTAssertEqual(result.format, .wav)
            return (seconds, audio)
        }

        _ = try await render("cold", "Voice is ready.")
        let warm = try await render("warm", "The build finished with two warnings and no failures.")
        XCTAssertLessThan(warm.seconds, warm.audio, "Warm synthesis runs faster than real time")
        let paragraph = try await render("paragraph", """
            Lattices finished the release build in four minutes and twelve seconds. Two warnings came from \
            the voice package, both about unused variables in the settings view. The test suite passed on \
            the first run, including the socket integration tests that usually flake when the machine is \
            busy. Next, the companion app needs a new build for the iPad, and the release notes still \
            mention the old speech engine. When you are ready, say ship it, and I will tag the release and \
            open the pull request for review.
            """)
        XCTAssertGreaterThan(paragraph.audio, 20, "Every chunk of a long paragraph is spoken")
        _ = try await render("slow", "Slow speech takes more frames per phoneme.", rate: 0.5)
        _ = try await render("af_nova", "A second voice is provisioned on first use.", voice: "af_nova")
        _ = try await render("am_michael", "So is a male voice.", voice: "am_michael")
    }

    func testLiveEngineUnloadsWhenIdleAndReloads() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICE_KOKORO_LIVE"] == "1", "Set VOICE_KOKORO_LIVE=1 to render with the real model")
        let engine = SpeechKokoroEngine(idle: .milliseconds(500))
        let clock = ContinuousClock()
        _ = try await engine.synthesize(text: "Loaded.", voice: "af_heart", speed: 1)
        var loaded = await engine.isLoaded
        XCTAssertTrue(loaded)
        let resident = Self.footprintMegabytes()
        try await Task.sleep(for: .seconds(2))
        loaded = await engine.isLoaded
        XCTAssertFalse(loaded, "The chain unloads once idle")
        let unloaded = Self.footprintMegabytes()
        let start = clock.now
        let audio = try await engine.synthesize(text: "Reloaded.", voice: "af_heart", speed: 1)
        let reload = start.duration(to: clock.now)
        XCTAssertFalse(audio.isEmpty)
        loaded = await engine.isLoaded
        XCTAssertTrue(loaded)
        print(String(format: "kokoro idle unload: %.0f MB loaded, %.0f MB unloaded, reload + render %.2f s",
                     resident, unloaded, Double(reload.components.seconds) + Double(reload.components.attoseconds) / 1e18))
    }

    /// The only published `.bin` pack is af_heart; its JSON must convert to the same bytes.
    func testLiveVoicePackConversionMatchesThePublishedPack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICE_KOKORO_LIVE"] == "1", "Set VOICE_KOKORO_LIVE=1 to fetch voice packs")
        let repository = try await KokoroAneResourceDownloader.ensureModels()
        let published = try Data(contentsOf: repository.appendingPathComponent("af_heart.bin"))
        let url = try ModelRegistry.resolveModel(Repo.kokoroAne.remotePath, "voices/af_heart.json")
        let json = try await AssetDownloader.fetchData(from: url, description: "Kokoro voice af_heart")
        XCTAssertEqual(try SpeechKokoroVoicePack.binary(fromJSON: json), published)
    }

    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
#endif
