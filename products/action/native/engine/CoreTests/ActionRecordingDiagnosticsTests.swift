import Foundation
import Testing
@testable import ActionCore

struct ActionRecordingDiagnosticsTests {
    @Test @MainActor
    func stopWaitKeepsMainActorAvailable() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var mainActorAdvanced = false
        let marker = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(15))
            mainActorAdvanced = true
            try Data().write(to: path)
        }
        // A separate executor bounds the test even if the wait regresses to a
        // blocking sleep; it must not be the event that releases a correct wait.
        let fallback = Task.detached {
            try await Task.sleep(for: .seconds(1))
            try Data().write(to: path)
        }
        defer { fallback.cancel(); marker.cancel() }
        try await ActionRecordingStopSignal.wait(at: path.path)
        #expect(mainActorAdvanced)
    }

    @Test
    func stopWaitCanBeCancelledWithoutAFile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let waiting = Task { try await ActionRecordingStopSignal.wait(at: path) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func incomingDiagnosticsPreserveClockAndStatusWithoutInventingFrames() throws {
        var timing = ActionRecordingFrameTiming(
            startedAt: "2026-10-25T19:00:00Z", startedHostTimeSeconds: 20,
            machTimebaseNumerator: 125, machTimebaseDenominator: 3, maximumSamples: 3
        )
        timing.append(presentationTimeSeconds: 10, arrivalHostTimeSeconds: 20.01, status: 0, displayTimeTicks: 100, valid: true)
        timing.append(presentationTimeSeconds: 10.14, arrivalHostTimeSeconds: 20.16, status: 1, displayTimeTicks: 200, valid: true)
        timing.append(presentationTimeSeconds: .nan, arrivalHostTimeSeconds: 20.17, status: nil, displayTimeTicks: nil, valid: false)
        timing.append(presentationTimeSeconds: 10.18, arrivalHostTimeSeconds: 20.18, status: 0, displayTimeTicks: 300, valid: true)
        #expect(timing.totalSamples == 4)
        #expect(timing.truncatedSamples == 1)
        #expect(timing.samples.count == 3)
        #expect(timing.samples[1].presentationTimeSeconds == 10.14)
        #expect(timing.samples[1].status == 1)
        #expect(timing.samples[2].presentationTimeSeconds == nil)
        let encoded = try JSONEncoder().encode(timing)
        let decoded = try JSONDecoder().decode(ActionRecordingFrameTiming.self, from: encoded)
        #expect(decoded.samples.map(\.index) == [0, 1, 2])
        #expect(decoded.machTimebaseNumerator == 125)
        #expect(decoded.machTimebaseDenominator == 3)
    }
}
