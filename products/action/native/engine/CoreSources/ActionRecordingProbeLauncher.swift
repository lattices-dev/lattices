import CoreGraphics
import Foundation

private struct ActionRecordingProbeResponse: Decodable {
    let status: String
    let outputPath: String?
    let detail: String?
}

public enum ActionRecordingProbeLauncher {
    public static func launchRegion(
        rect: CGRect,
        outputPath: String,
        stopSignalPath: String?,
        finishedSignalPath: String?,
        debugLogPath: String?,
        fps: Double,
        scale: Double,
        includeSupervisionOverlay: Bool,
        frameTimingPath: String? = nil
    ) async throws -> [String: String] {
        var arguments = [
            "recording-probe",
            "--x", String(describing: rect.origin.x),
            "--y", String(describing: rect.origin.y),
            "--width", String(describing: rect.size.width),
            "--height", String(describing: rect.size.height),
            "--output", outputPath,
            "--fps", String(describing: fps),
            "--scale", String(describing: scale),
            "--include-supervision-overlay", String(includeSupervisionOverlay),
        ]

        if let stopSignalPath, !stopSignalPath.isEmpty {
            arguments.append(contentsOf: ["--stop-file", stopSignalPath])
        }

        if let finishedSignalPath, !finishedSignalPath.isEmpty {
            arguments.append(contentsOf: ["--finished-file", finishedSignalPath])
        }

        if let debugLogPath, !debugLogPath.isEmpty {
            arguments.append(contentsOf: ["--debug-log", debugLogPath])
        }

        if let frameTimingPath, !frameTimingPath.isEmpty {
            arguments.append(contentsOf: ["--frame-timing-file", frameTimingPath])
        }

        return try await launch(arguments: arguments, outputPath: outputPath)
    }

    public static func launchAppWindow(
        bundleId: String,
        outputPath: String,
        stopSignalPath: String?,
        finishedSignalPath: String?,
        debugLogPath: String?,
        frameTimingPath: String? = nil
    ) async throws -> [String: String] {
        var arguments = [
            "recording-probe",
            "--bundle-id", bundleId,
            "--output", outputPath,
        ]

        if let stopSignalPath, !stopSignalPath.isEmpty {
            arguments.append(contentsOf: ["--stop-file", stopSignalPath])
        }

        if let finishedSignalPath, !finishedSignalPath.isEmpty {
            arguments.append(contentsOf: ["--finished-file", finishedSignalPath])
        }

        if let debugLogPath, !debugLogPath.isEmpty {
            arguments.append(contentsOf: ["--debug-log", debugLogPath])
        }

        if let frameTimingPath, !frameTimingPath.isEmpty {
            arguments.append(contentsOf: ["--frame-timing-file", frameTimingPath])
        }

        return try await launch(arguments: arguments, outputPath: outputPath, detail: bundleId)
    }

    private static func launch(
        arguments: [String],
        outputPath: String,
        detail: String? = nil
    ) async throws -> [String: String] {
        let bundleURL = try resolveAppBundleURL()
        let replyFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-recording-probe-\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: replyFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path, "--args"] + arguments + ["--reply-file", replyFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "ActionRecordingProbeLauncher",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to launch recording probe via open(1)"]
            )
        }

        let response = try await waitForProbeReply(at: replyFile)
        if response.status == "error" {
            throw NSError(
                domain: "ActionRecordingProbeLauncher",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.detail ?? "Recording probe failed to start"]
            )
        }

        var result: [String: String] = [
            "status": response.status,
            "outputPath": response.outputPath ?? outputPath,
        ]
        if let detail {
            result["detail"] = detail
        }
        return result
    }

    private static func waitForProbeReply(at replyFile: URL) async throws -> ActionRecordingProbeResponse {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: replyFile), !data.isEmpty {
                return try JSONDecoder().decode(ActionRecordingProbeResponse.self, from: data)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw NSError(
            domain: "ActionRecordingProbeLauncher",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Recording probe did not acknowledge launch"]
        )
    }

    private static func resolveAppBundleURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        var fallbackAppBundleURL: URL?

        func inspect(candidate: URL) -> URL? {
            guard candidate.pathExtension == "app" else {
                return nil
            }
            if fallbackAppBundleURL == nil {
                fallbackAppBundleURL = candidate
            }
            if candidate.lastPathComponent == "Action.app" {
                return candidate
            }
            return nil
        }

        if let resolved = inspect(candidate: bundleURL) {
            return resolved
        }

        if let executableURL = Bundle.main.executableURL {
            var candidate = executableURL.deletingLastPathComponent()
            while candidate.path != "/" {
                if let resolved = inspect(candidate: candidate) {
                    return resolved
                }
                candidate.deleteLastPathComponent()
            }
        }

        if let fallbackAppBundleURL {
            return fallbackAppBundleURL
        }

        throw NSError(
            domain: "ActionRecordingProbeLauncher",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Unable to resolve Action.app bundle URL for recording probe"]
        )
    }
}
