#if canImport(PhononTTS)
import AVFoundation
import XCTest
@testable import SpeechAppRuntime

final class SpeechPhononRuntimeTests: XCTestCase {
    func testCatalogIsTheBundleVoicesWithEdwinDefault() {
        let status = SpeechPhononRuntime.status
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.modelId, "gradium/phonon-31m-en")
        XCTAssertEqual(status.voiceId, "Edwin")
        XCTAssertEqual(status.voices.count, 38)
        XCTAssertEqual(status.voices.map(\.id), SpeechPhononRuntime.voiceIDs)
        XCTAssertEqual(status.voices.filter(\.isDefault).map(\.id), ["Edwin"])
        XCTAssertTrue(status.voices.allSatisfy { $0.provider == "phonon" && $0.available })
    }

    func testRejectsOtherModelsAndUnlistedVoicesBeforeLoading() async {
        do {
            _ = try await SpeechPhononRuntime.synthesizePhonon(text: "Hi", voice: nil, rate: 1, model: "tts-1")
            XCTFail("A non-Phonon model must be rejected")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .providerFailed("Phonon requires a Phonon model"))
        }
        do {
            _ = try await SpeechPhononRuntime.synthesizePhonon(text: "Hi", voice: "af_heart", rate: 1, model: nil)
            XCTFail("A Kokoro voice is not in the Phonon catalog")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .unknownVoice("af_heart", provider: "phonon", listedUnder: nil))
        }
    }

    func testWAVIsSixteenBitMonoAndPeakNormalized() throws {
        let samples: [Float] = [0, 0.25, -0.5, 0.1]
        let data = SpeechWAV.data(from: samples, sampleRate: 24_000)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.format.sampleRate, 24_000)
        XCTAssertEqual(player.format.channelCount, 1)
        let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(pcm[2], -Int16(0.95 * Float(Int16.max)), "The peak is scaled to 0.95")
        XCTAssertEqual(SpeechWAV.data(from: [0, 0], sampleRate: 24_000).dropFirst(44), Data(count: 4))
    }

    // MARK: - Live (VOICE_PHONON_LIVE=1)

    /// Downloads the model on first run. VOICE_PHONON_LIVE_OUT=<dir> keeps the WAVs.
    func testLiveRendersOnTheNeuralEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VOICE_PHONON_LIVE"] == "1", "Set VOICE_PHONON_LIVE=1 to render with the real model")
        let output = environment["VOICE_PHONON_LIVE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }

        func render(_ name: String, _ text: String, voice: String? = nil) async throws -> (seconds: Double, audio: Double) {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await SpeechPhononRuntime.synthesizePhonon(text: text, voice: voice, rate: 1, model: nil)
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let audio = try AVAudioPlayer(data: result.audioData).duration
            print(String(format: "phonon %@ (%@): %.2f s for %.2f s of audio, RTF %.3f",
                         name, result.voice, seconds, audio, seconds / audio))
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try result.audioData.write(to: output.appendingPathComponent("\(name).wav"))
            }
            XCTAssertEqual(result.voice, voice ?? "Edwin")
            XCTAssertEqual(result.format, .wav)
            return (seconds, audio)
        }

        _ = try await render("cold", "Voice is ready.")
        let warm = try await render("warm", "The build finished with two warnings and no failures.")
        XCTAssertLessThan(warm.seconds, warm.audio, "Warm synthesis runs faster than real time")
        let paragraph = try await render("paragraph", """
            Lattices finished the release build in 4 minutes and 12 seconds. Two warnings came from \
            the voice package, both about unused variables in the settings view. The test suite passed on \
            the first run, including the socket integration tests that usually flake when the machine is \
            busy. Next, the companion app needs a new build for the iPad, and the release notes still \
            mention the old speech engine. When you are ready, say ship it, and I will tag the release and \
            open the pull request for review.
            """)
        XCTAssertGreaterThan(paragraph.audio, 20, "Every sentence of a long paragraph is spoken")
        for voice in ["Harper", "Hugh", "Maeve", "Miles", "Imogen", "default"] {
            _ = try await render(voice, "The tideline build is green. Three agents are waiting for review.", voice: voice)
        }
    }
}
#endif
