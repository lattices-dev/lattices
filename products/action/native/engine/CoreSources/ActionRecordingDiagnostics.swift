import Foundation

/// Waits without occupying the caller's executor, including an AppKit main actor.
public enum ActionRecordingStopSignal {
    public static func wait(at path: String) async throws {
        while !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }
}

/// Incoming ScreenCaptureKit delivery evidence, not a claim about encoded or
/// visually distinct frames. The caller serializes access on its sample queue.
public struct ActionRecordingFrameTiming: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let index: Int
        public let presentationTimeSeconds: Double?
        public let arrivalHostTimeSeconds: Double
        public let status: Int?
        public let displayTimeTicks: UInt64?
        public let valid: Bool
    }

    public let schemaVersion: Int
    public let startedAt: String
    public let startedHostTimeSeconds: Double
    public let clock: String
    public let displayTimeClock: String
    public let machTimebaseNumerator: UInt32
    public let machTimebaseDenominator: UInt32
    public private(set) var totalSamples = 0
    public private(set) var truncatedSamples = 0
    public private(set) var samples: [Sample] = []
    private let maximumSamples: Int

    public init(
        startedAt: String,
        startedHostTimeSeconds: Double,
        machTimebaseNumerator: UInt32,
        machTimebaseDenominator: UInt32,
        maximumSamples: Int = 180_000
    ) {
        self.schemaVersion = 1
        self.clock = "ProcessInfo.systemUptime"
        self.displayTimeClock = "mach_absolute_time ticks"
        self.startedAt = startedAt
        self.startedHostTimeSeconds = startedHostTimeSeconds
        self.machTimebaseNumerator = machTimebaseNumerator
        self.machTimebaseDenominator = machTimebaseDenominator
        self.maximumSamples = max(maximumSamples, 0)
    }

    public mutating func append(
        presentationTimeSeconds: Double,
        arrivalHostTimeSeconds: Double,
        status: Int?,
        displayTimeTicks: UInt64?,
        valid: Bool
    ) {
        let index = totalSamples
        totalSamples += 1
        guard samples.count < maximumSamples else {
            truncatedSamples += 1
            return
        }
        samples.append(Sample(
            index: index,
            presentationTimeSeconds: presentationTimeSeconds.isFinite ? presentationTimeSeconds : nil,
            arrivalHostTimeSeconds: arrivalHostTimeSeconds,
            status: status,
            displayTimeTicks: displayTimeTicks,
            valid: valid
        ))
    }
}
