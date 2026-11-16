import Foundation

/// "Show agent layer": brings back Action's floating preview of a running
/// agent task. It reads `lats action layer list` once when asked (page change
/// or click), never on a timer, and never prepares or releases a display.
@MainActor
final class AgentLayerShortcut: ObservableObject {
    static let shared = AgentLayerShortcut()

    /// Workspaces with an agent task attached right now.
    @Published private(set) var activeWorkspaces: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private var refreshing = false

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let result = Self.run(["layer", "list"])
            let active = result.flatMap(Self.activeWorkspaces(in:)) ?? []
            await MainActor.run {
                self.activeWorkspaces = active
                self.refreshing = false
            }
        }
    }

    func show() {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let active = Self.run(["layer", "list"]).flatMap(Self.activeWorkspaces(in:)) ?? []
            var error: String? = active.isEmpty ? "No agent task is running" : nil
            for workspace in active {
                guard let reply = Self.run(["layer", "pip", "--workspace", workspace]) else {
                    error = "Action did not answer"; continue
                }
                if reply["ok"] as? Bool != true {
                    error = reply["error"] as? String ?? "Action could not show the layer"
                }
            }
            if let error { DiagnosticLog.shared.warn("Show agent layer: \(error)") }
            await MainActor.run {
                self.activeWorkspaces = active
                self.lastError = error
                self.busy = false
            }
        }
    }

    nonisolated static func activeWorkspaces(in list: [String: Any]) -> [String]? {
        guard let workspaces = list["workspaces"] as? [[String: Any]] else { return nil }
        return workspaces.compactMap { entry in
            guard let layer = entry["layer"] as? [String: Any], layer["active"] as? Bool == true else { return nil }
            return entry["workspace"] as? String
        }
    }

    /// `lats action <args>` → the JSON object it prints (after the `$ …` echo).
    nonisolated private static func run(_ args: [String]) -> [String: Any]? {
        let proc = Process()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        proc.environment = env
        if let bun = LatticesRuntime.bunPath, let root = LatticesRuntime.cliRoot,
           FileManager.default.fileExists(atPath: root + "/bin/lattices.ts") {
            proc.executableURL = URL(fileURLWithPath: bun)
            proc.arguments = [root + "/bin/lattices.ts", "action"] + args
        } else if let cli = LatticesRuntime.cliExecutablePath {
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["action"] + args
        } else { return nil }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any]
        else { return nil }
        return json
    }
}
