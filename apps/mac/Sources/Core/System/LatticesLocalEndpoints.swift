import Foundation

/// Per-user runtime endpoints. Normal local traffic uses private Unix sockets;
/// numeric ports are retained only for explicit compatibility or gateway use.
enum LatticesLocalEndpoints {
    static var runtimeDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LATTICES_RUNTIME_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/run", isDirectory: true)
    }
    static var agentSocketPath: String { runtimeDirectory.appendingPathComponent("lattices.sock").path }
    /// The one per-user Lattices credential. The daemon socket, the companion
    /// bridge and the gateway admin socket all admit with it. Speech, the Vox
    /// voice runtime and Action keep their own tokens.
    static var agentTokenURL: URL { runtimeDirectory.appendingPathComponent("lattices.token") }
    static var speechCompanionSocketPath: String { runtimeDirectory.appendingPathComponent("speech.sock").path }
    static var speechCompanionTokenURL: URL { runtimeDirectory.appendingPathComponent("speech.token") }
    static var companionSocketPath: String { runtimeDirectory.appendingPathComponent("companion.sock").path }
    static var voiceSocketPath: String { runtimeDirectory.appendingPathComponent("voice.sock").path }
    static var voiceTokenURL: URL { runtimeDirectory.appendingPathComponent("voice.token") }
    /// Loopback bind host for explicit compatibility mode.
    static let loopbackHost = "127.0.0.1"

    /// Separate Speech app, owned by its own process.
    static let speechCompanionPort: UInt16 = 9397
    static var speechCompanionURL: URL { URL(string: "ws://\(loopbackHost):\(speechCompanionPort)")! }

    /// Agent API / daemon WebSocket (`DaemonServer`).
    static let agentAPIPort: UInt16 = 9399

    /// Lattices-hosted Hudson Voice / Vox live-session WebSocket.
    ///
    /// Adjacent to the agent API (9399) so the Lattices local port family is
    /// self-describing: `939x` = Lattices process-owned loopback services.
    ///
    /// Override only for tests/dev with `LATTICES_VOICE_PORT` (preferred) or
    /// the legacy `HUDSON_VOICE_VOX_PORT` env var.
    static let voiceRuntimePort: UInt16 = 9398

    static var agentAPIWebSocketURL: String {
        "ws://\(loopbackHost):\(agentAPIPort)"
    }

    static var voiceRuntimeWebSocketURL: String {
        "ws://\(loopbackHost):\(resolvedVoiceRuntimePort)"
    }

    /// Effective voice port after env override (still always loopback).
    static var resolvedVoiceRuntimePort: UInt16 {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["LATTICES_VOICE_PORT"] ?? env["HUDSON_VOICE_VOX_PORT"],
           let value = UInt16(raw), value > 0 {
            return value
        }
        return voiceRuntimePort
    }
}
