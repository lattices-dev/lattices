#if LATTICES_VOICE && canImport(HudsonVoice)
import Darwin
import Foundation
import HudsonVoice

/// Resolves the voice runtime Lattices should use.
///
/// Preferred path: the Lattices-hosted capability file written at boot by
/// `LatticesVoiceRuntime` (`HUDSON_VOICE_RUNTIME_PATH` → Application Support/
/// Lattices/Voice/hudson-voice-runtime.json) over private IPC.
///
/// Fallbacks exist for dev (external voxd / env overrides) but normal product
/// operation does not require an external daemon.
enum HudsonVoiceRuntimeResolver {
    private struct RuntimeFile: Decodable {
        let host: String?
        let port: UInt16?
        let pid: Int?
        let serviceName: String?
        let service: String?
        let transport: String?
        let webSocketUrl: String?
        let authToken: String?
    }

    static func resolve(
        clientId: String = "lattices",
        mode: HudVoiceMode? = nil
    ) -> (endpoint: HudVoxEndpoint, options: HudVoxLiveSessionOptions, source: String, pid: Int?, authToken: String?, capabilityPath: String?)? {
        // 1. Canonical Hudson capability (Lattices-hosted, auth token included).
        if let connection = try? HudsonVoiceRuntime.resolveConnection(
            clientId: clientId,
            mode: mode,
            metadata: ["hostApp": "lattices"]
        ), connection.endpoint.socketPath != nil || ProcessInfo.processInfo.environment["LATTICES_VOICE_ALLOW_LEGACY_TCP"] == "1" {
            return (
                endpoint: connection.endpoint,
                options: connection.options,
                source: "lattices-host",
                pid: connection.capability.pid.map(Int.init),
                authToken: connection.capability.authToken,
                capabilityPath: HudsonVoiceRuntime.runtimeURL().path
            )
        }

        // Legacy discovery is explicit. A missing/invalid private capability
        // must not silently route the microphone to another process.
        guard ProcessInfo.processInfo.environment["LATTICES_VOICE_ALLOW_LEGACY_TCP"] == "1" else { return nil }
        // 2. File / env discovery (legacy external voxd, tests).
        guard let runtime = resolvedRuntimeFallback() else { return nil }
        var options = HudVoxLiveSessionOptions(
            clientId: clientId,
            mode: mode ?? .pushToTalk,
            metadata: ["hostApp": "lattices"],
            authToken: runtime.authToken
        )
        // Keep options.authToken populated even if init signature drifts.
        options.authToken = runtime.authToken
        return (
            endpoint: HudVoxEndpoint(host: runtime.host, port: runtime.port),
            options: options,
            source: runtime.source,
            pid: runtime.pid,
            authToken: runtime.authToken,
            capabilityPath: runtime.path
        )
    }

    /// Explicit compatibility discovery for external TCP runtimes.
    private static func resolvedRuntimeFallback() -> (host: String, port: UInt16, source: String, pid: Int?, authToken: String?, path: String?)? {
        for candidate in runtimeFileCandidates() {
            guard let runtime = readRuntimeFile(candidate.url),
                  let port = runtime.port,
                  port > 0,
                  runtime.pid.map(processIsAlive) ?? true else { continue }

            let host = runtime.host
                ?? hostFromWebSocketURL(runtime.webSocketUrl)
                ?? LatticesLocalEndpoints.loopbackHost
            guard isLoopback(host) else { continue }

            return (
                host: host,
                port: port,
                source: candidate.source,
                pid: runtime.pid,
                authToken: nonEmpty(runtime.authToken),
                path: candidate.url.path
            )
        }

        let env = ProcessInfo.processInfo.environment
        if let rawPort = env["LATTICES_VOICE_PORT"] ?? env["VOX_PORT"] ?? env["HUDSON_VOICE_VOX_PORT"],
           let port = UInt16(rawPort), port > 0 {
            return (
                host: nonEmpty(env["VOX_HOST"]) ?? LatticesLocalEndpoints.loopbackHost,
                port: port,
                source: "env",
                pid: nil,
                authToken: nonEmpty(env["VOX_AUTH_TOKEN"]),
                path: nil
            )
        }

        return nil
    }

    private static func runtimeFileCandidates() -> [(url: URL, source: String)] {
        var candidates: [(URL, String)] = []
        let env = ProcessInfo.processInfo.environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        // Lattices-hosted capability first (set at boot via setenv).
        if let path = nonEmpty(env[HudsonVoiceRuntime.runtimePathEnvironmentKey]) {
            candidates.append((URL(fileURLWithPath: path), "lattices-host"))
        }
        candidates.append((
            support
                .appendingPathComponent("Lattices", isDirectory: true)
                .appendingPathComponent("Voice", isDirectory: true)
                .appendingPathComponent("hudson-voice-runtime.json"),
            "lattices-host"
        ))

        // Hudson Menu / shared Hudson capability (if user runs Hudson Voice separately).
        candidates.append((
            support
                .appendingPathComponent("Hudson", isDirectory: true)
                .appendingPathComponent("Vox", isDirectory: true)
                .appendingPathComponent("hudson-voice-runtime.json"),
            "hudson-voice"
        ))

        // Standalone voxd runtime registry.
        if let path = nonEmpty(env["VOX_RUNTIME_PATH"]) {
            candidates.append((URL(fileURLWithPath: path), "vox"))
        }
        candidates.append((
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vox", isDirectory: true)
                .appendingPathComponent("runtime.json"),
            "vox"
        ))

        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.0.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private static func readRuntimeFile(_ url: URL) -> RuntimeFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeFile.self, from: data)
    }

    private static func hostFromWebSocketURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), let host = url.host else { return nil }
        return host
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
    }

    private static func processIsAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
