import Foundation
import Security

#if LATTICES_VOICE && canImport(HudsonVoice)
import HudsonVoice
import VoxService
#endif

/// Boot/shutdown owner for Lattices' embedded voice runtime.
///
/// Lattices is the permission and lifecycle owner: the menu bar process starts
/// an in-process Vox live-session server on a private Unix socket, writes a
/// private Hudson capability file, and tears it down on quit.
///
/// Clients (Workspace Assistant mic, Hands-Off, voice commands) resolve through
/// `HudsonVoiceRuntimeResolver` → that capability file — they do not depend on
/// an external `voxd` being up.
enum LatticesVoiceRuntime {
    static func start() {
        #if LATTICES_VOICE && canImport(HudsonVoice)
        do {
            try Host.shared.start()
            let endpoint = Host.shared.endpointURL
            DiagnosticLog.shared.success(
                "HudsonVoice: embedded runtime started at \(endpoint) (capability \(Host.shared.capabilityURL.path))"
            )
        } catch {
            DiagnosticLog.shared.warn(
                "HudsonVoice: embedded runtime failed to start — \(error.localizedDescription)"
            )
        }
        #else
        DiagnosticLog.shared.info(
            "HudsonVoice: runtime host skipped because HudsonVoice is not compiled into this build"
        )
        #endif
    }

    /// Start if needed (e.g. boot failed earlier, or first capture after idle).
    /// Safe to call repeatedly; no-ops when already hosting.
    @discardableResult
    static func ensureRunning() -> Bool {
        #if LATTICES_VOICE && canImport(HudsonVoice)
        if Host.shared.isRunning { return true }
        start()
        return Host.shared.isRunning
        #else
        return false
        #endif
    }

    static func stop() {
        #if LATTICES_VOICE && canImport(HudsonVoice)
        Host.shared.stop()
        DiagnosticLog.shared.info("HudsonVoice: embedded runtime stopped")
        #endif
    }

    /// Drop any orphaned live capture session owned by the embedded runtime.
    /// Used when Vox reports `live_session_busy` after a dropped client handle.
    static func resetEmbeddedRuntime() {
        #if LATTICES_VOICE && canImport(HudsonVoice)
        stop()
        _ = ensureRunning()
        #endif
    }

    #if LATTICES_VOICE && canImport(HudsonVoice)
    /// True when this process is currently hosting the voice WebSocket.
    static var isRunning: Bool { Host.shared.isRunning }

    static var endpointDescription: String? {
        guard Host.shared.isRunning else { return nil }
        return Host.shared.endpointURL
    }
    #else
    static var isRunning: Bool { false }
    #endif
}

#if LATTICES_VOICE && canImport(HudsonVoice)

// MARK: - In-process host

/// Lattices-owned Vox host. Modeled on the former HudsonKit
/// `HudsonVoiceRuntimeHost`, with private IPC owned by Lattices.
private final class Host: @unchecked Sendable {
    static let shared = Host()

    private let lock = NSRecursiveLock()
    private let bindAddress = LatticesLocalEndpoints.loopbackHost
    private let port: UInt16 = 0
    private let socketPath = LatticesLocalEndpoints.voiceSocketPath
    private let tokenURL = LatticesLocalEndpoints.voiceTokenURL
    private let runtimeHomeURL: URL
    private let runtimeCapabilityURL: URL
    private let voxRuntimeURL: URL
    private var runtimeService: VoxRuntimeService?
    private var ownsCapability = false

    private(set) var isRunning = false

    var capabilityURL: URL { runtimeCapabilityURL }

    var endpointURL: String {
        "unix:\(socketPath)"
    }

    private init() {
        let home = Self.defaultRuntimeHomeURL()
        runtimeHomeURL = home
        runtimeCapabilityURL = home.appendingPathComponent("hudson-voice-runtime.json")
        voxRuntimeURL = home.appendingPathComponent("vox-runtime.json")
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        if runtimeService != nil, isRunning, HudsonVoiceRuntime.isAvailable() {
            return
        }

        // Tear down a half-started previous attempt before retrying.
        runtimeService?.stop()
        runtimeService = nil
        removeRuntimeCapability()

        let authToken = try Self.generateCapabilityToken()
        try configureEnvironment(authToken: authToken)
        try persistPreferences()

        let (asrEngine, ttsEngine, defaultSynthesisModelId) = try LatticesVoiceEngineLoader.loadEngines(
            runtimeHome: runtimeHomeURL
        )
        DiagnosticLog.shared.info(
            "HudsonVoice: synthesis default \(defaultSynthesisModelId) (\(LatticesVoiceEngineLoader.kokoroVoiceId))"
        )

        let service = VoxRuntimeService(
            port: port,
            bindAddress: bindAddress,
            engine: asrEngine,
            ttsEngine: ttsEngine,
            defaultSynthesisModelId: defaultSynthesisModelId,
            authToken: authToken,
            socketPath: socketPath
        )
        do {
            try service.start()
            try VoxPrivateIPC.writePrivateFile(Data(authToken.utf8), to: tokenURL)
            ownsCapability = true
            try writeRuntimeCapability(authToken: authToken, startedAt: Date())
            runtimeService = service
            isRunning = true
        } catch {
            service.stop()
            removeRuntimeCapability()
            isRunning = false
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        runtimeService?.stop()
        runtimeService = nil
        removeRuntimeCapability()
        isRunning = false
    }

    private func configureEnvironment(authToken: String) throws {
        try VoxPrivateIPC.prepareDirectory(runtimeHomeURL)
        setenv("VOX_HOME", runtimeHomeURL.path, 1)
        setenv("VOX_RUNTIME_PATH", voxRuntimeURL.path, 1)
        setenv("VOX_HOST", bindAddress, 1)
        unsetenv("VOX_PORT")
        setenv("VOX_SOCKET_PATH", socketPath, 1)
        setenv("VOX_AUTH_TOKEN", authToken, 1)
        // Point HudsonVoice's capability reader at Lattices' file (not Hudson Menu's).
        setenv(HudsonVoiceRuntime.runtimePathEnvironmentKey, runtimeCapabilityURL.path, 1)
        unsetenv("LATTICES_VOICE_PORT")
    }

    private func persistPreferences() throws {
        var preferences = (try? HudsonVoicePreferences.load()) ?? HudsonVoicePreferences()
        if preferences.preferredSynthesisModelId?.isEmpty != false {
            preferences.preferredSynthesisModelId = LatticesVoiceEngineLoader.kokoroModelId
        }
        try preferences.normalized().save()
    }

    private func writeRuntimeCapability(authToken: String, startedAt: Date) throws {
        let document = RuntimeCapabilityDocument(
            host: bindAddress,
            port: port,
            authToken: authToken,
            pid: getpid(),
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            voxRuntimePath: voxRuntimeURL.path,
            socketPath: socketPath,
            tokenPath: tokenURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try VoxPrivateIPC.writePrivateFile(data, to: runtimeCapabilityURL)
    }

    private func removeRuntimeCapability() {
        guard ownsCapability else { return }
        try? FileManager.default.removeItem(at: runtimeCapabilityURL)
        try? FileManager.default.removeItem(at: tokenURL)
        ownsCapability = false
    }

    private static func defaultRuntimeHomeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Lattices-owned home — separate from Hudson Menu's Application Support/Hudson/Vox.
        return base
            .appendingPathComponent("Lattices", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
    }

    private static func generateCapabilityToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let byteCount = bytes.count
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: "LatticesVoiceRuntime",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not generate voice capability token."]
            )
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Wire format expected by `HudsonVoiceRuntime` (schemaVersion 1, service hudson-voice).
private struct RuntimeCapabilityDocument: Encodable {
    let schemaVersion = 1
    let service = "hudson-voice"
    let transport = "unix+ws+json-rpc"
    let host: String
    let port: UInt16
    let webSocketUrl: String
    let authToken: String
    let pid: Int32
    let startedAt: String
    let voxRuntimePath: String
    let socketPath: String
    let tokenPath: String

    init(
        host: String,
        port: UInt16,
        authToken: String,
        pid: Int32,
        startedAt: String,
        voxRuntimePath: String,
        socketPath: String,
        tokenPath: String
    ) {
        self.host = host
        self.port = port
        self.webSocketUrl = URL(fileURLWithPath: socketPath).absoluteString
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.authToken = authToken
        self.pid = pid
        self.startedAt = startedAt
        self.voxRuntimePath = voxRuntimePath
    }
}

#endif
