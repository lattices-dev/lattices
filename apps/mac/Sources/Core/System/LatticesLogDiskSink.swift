import Foundation
import HudsonObservability

/// Persists `HudLogger` / `HudLogStore` events to `~/.lattices/lattices.log`.
/// Installed alongside `HudLogStore.shared` at app boot so Lattices keeps its
/// on-disk trail while the in-memory inspector is HudsonKit-native.
final class LatticesLogDiskSink: HudLogSink {
    static let shared = LatticesLogDiskSink()

    private let logFile: URL
    private let fileHandle: FileHandle?
    private let diskQueue = DispatchQueue(label: "com.lattices.log-writer")

    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lattices")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A remote app bundle is a second process on the same executable; two
        // writers on one file overwrite each other's lines.
        logFile = dir.appendingPathComponent(RemoteAppBundles.currentDefinition.map { "remote-app-\($0).log" } ?? "lattices.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            let prev = dir.appendingPathComponent("lattices.log.1")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: logFile, to: prev)
        }

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()

        let header = "\n──── Lattices launched \(ISO8601DateFormatter().string(from: Date())) ────\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    deinit {
        fileHandle?.closeFile()
    }

    func capture(_ entry: HudLogEntry) {
        diskQueue.async { [weak self] in
            guard let self else { return }
            let ts = Self.timeFmt.string(from: entry.timestamp)
            let level = Self.diskLevel(for: entry)
            let icon = Self.icon(for: level)
            let line = "\(ts) \(icon) [\(level)] \(entry.message)\n"
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }

    private static func diskLevel(for entry: HudLogEntry) -> String {
        if entry.metadata["outcome"] == "success" {
            return "success"
        }
        switch entry.level {
        case .warning:
            return "warning"
        case .error, .fault:
            return "error"
        default:
            return "info"
        }
    }

    private static func icon(for level: String) -> String {
        switch level {
        case "success": return "✓"
        case "warning": return "⚠"
        case "error":   return "✗"
        default:        return "›"
        }
    }
}