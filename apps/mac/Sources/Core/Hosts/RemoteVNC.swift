import AppKit
import Darwin
import Foundation
import Network

/// VNC is a separate, explicitly chosen connection. Gateway RPC addresses
/// (especially local forwards) are never assumed to be VNC endpoints.
struct RemoteVNCSettings: Codable, Equatable {
    var address: String
    var port = 5900
    var throughSSH: Bool
    var startLinuxServer: Bool

    static func initial(host: String, address: String, platform: String?) -> Self {
        .init(address: MachineInventory.isLoopback(address) ? host : address,
              throughSSH: platform == "linux", startLinuxServer: platform == "linux")
    }

    func validate() throws {
        guard (1...65535).contains(port) else { throw RemoteVNCError.message("Enter a VNC port between 1 and 65535.") }
        let pattern = throughSSH ? "^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9_\\[][A-Za-z0-9_.:%\\[\\]-]*$"
            : "^[A-Za-z0-9_\\[][A-Za-z0-9_.:%\\[\\]-]*$"
        guard address.range(of: pattern, options: .regularExpression) != nil else {
            throw RemoteVNCError.message(throughSSH ? "Enter an SSH host or user@host from your SSH configuration."
                : "Enter a hostname or IP address, without a URL or port.")
        }
        if !throughSSH { _ = try Self.url(address: address, port: port) }
    }

    static func url(address: String, port: Int) throws -> URL {
        guard (1...65535).contains(port), !address.isEmpty,
              !address.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) else {
            throw RemoteVNCError.message("Invalid VNC address.")
        }
        var parts = URLComponents()
        parts.scheme = "vnc"
        parts.host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        parts.port = port
        guard let url = parts.url, url.host != nil else { throw RemoteVNCError.message("Invalid VNC address.") }
        return url
    }

    func sshArguments(localPort: Int? = nil) throws -> [String] {
        try validate()
        var args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if let localPort {
            guard (1...65535).contains(localPort) else { throw RemoteVNCError.message("Invalid local VNC port.") }
            args += ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(port)"]
        }
        return args + [address]
    }

    func startCommand(displayIndex: Int?) throws -> String {
        try validate()
        guard throughSSH else { throw RemoteVNCError.message("Start WayVNC through SSH.") }
        if let displayIndex, displayIndex < 0 { throw RemoteVNCError.message("Invalid display.") }
        // Only validated integers enter the remote shell command. No editable
        // host, command or path is interpolated here.
        let display = displayIndex.map { ",\"displayIndex\":\($0)" } ?? ""
        return "PATH=\"$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\" lats call capture.live '{\"port\":\(port)\(display)}'"
    }
}

enum RemoteVNCError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Owns only the SSH children it launches. No shell on this Mac, no password
/// in arguments/defaults, no automatic SSH trust or gateway grant changes.
@MainActor
final class RemoteVNCConnections: ObservableObject {
    static let shared = RemoteVNCConnections()
    @Published private(set) var connected: Set<String> = []
    private var tunnels: [String: (process: Process, directory: URL, url: URL)] = [:]
    private let defaults: UserDefaults
    private let openURL: (URL) -> Bool
    private let settingsKey = "remoteView.vnc.connections"
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.openURL = openURL
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disconnectAll() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        for tunnel in tunnels.values { if tunnel.process.isRunning { tunnel.process.terminate() } }
    }

    func settings(host: String, address: String, platform: String?) -> RemoteVNCSettings {
        storedSettings()[host] ?? .initial(host: host, address: address, platform: platform)
    }

    private func storedSettings() -> [String: RemoteVNCSettings] {
        guard let data = defaults.data(forKey: settingsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RemoteVNCSettings].self, from: data)) ?? [:]
    }

    func connect(host: String, settings: RemoteVNCSettings, displayIndex: Int?) async throws {
        try settings.validate()
        DiagnosticLog.shared.info("RemoteVNC: connect transport=\(settings.throughSSH ? "ssh" : "direct") port=\(settings.port)")
        if !settings.throughSSH {
            let ready = await RemoteVNCProbe.check(address: settings.address, port: settings.port)
            try Task.checkCancellation()
            guard ready else {
                DiagnosticLog.shared.warn("RemoteVNC: direct probe failed; Screen Sharing was not opened")
                throw RemoteVNCError.message("No VNC server answered at \(settings.address):\(settings.port). Direct VNC requires an already running, reachable server. For a Lattices Linux host, choose Through SSH and enable Start WayVNC on this machine.")
            }
            DiagnosticLog.shared.info("RemoteVNC: direct RFB banner verified")
        }
        try Task.checkCancellation()
        disconnect(host)
        var destination = try RemoteVNCSettings.url(address: settings.throughSSH ? "127.0.0.1" : settings.address, port: settings.port)
        if settings.throughSSH {
            if settings.startLinuxServer {
                let result = try await runSSH(try settings.sshArguments() + [settings.startCommand(displayIndex: displayIndex)])
                guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                      object["running"] as? Bool == true,
                      object["host"] as? String == "127.0.0.1", object["port"] as? Int == settings.port else {
                    throw RemoteVNCError.message("The Linux host did not start VNC on the requested loopback port. Update its Lattices host or start VNC yourself.")
                }
            }
            try Task.checkCancellation()
            let localPort = try Self.availablePort()
            let (process, directory) = try launchSSH(try settings.sshArguments(localPort: localPort))
            do {
                var ready = false
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if !process.isRunning { throw RemoteVNCError.message(Self.failure(in: directory)) }
                    ready = await RemoteVNCProbe.check(address: "127.0.0.1", port: localPort, timeout: 0.25)
                    if ready { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard ready else { throw RemoteVNCError.message("VNC did not answer through SSH. Check that a VNC server is listening on port \(settings.port) on the remote machine.") }
                try Task.checkCancellation()
                destination = try RemoteVNCSettings.url(address: "127.0.0.1", port: localPort)
                DiagnosticLog.shared.info("RemoteVNC: SSH RFB banner verified localPort=\(localPort)")
                tunnels[host] = (process, directory, destination)
                connected.insert(host)
                process.terminationHandler = { [weak self, weak process] _ in
                    Task { @MainActor in
                        guard let self, self.tunnels[host]?.process === process else { return }
                        self.disconnect(host)
                    }
                }
                guard process.isRunning else { throw RemoteVNCError.message(Self.failure(in: directory)) }
            } catch {
                disconnect(host)
                Self.stop(process, directory: directory)
                throw error
            }
        }
        if Task.isCancelled { disconnect(host); throw CancellationError() }
        guard openURL(destination) else {
            disconnect(host)
            throw RemoteVNCError.message("Could not open Screen Sharing on this Mac.")
        }
        DiagnosticLog.shared.info("RemoteVNC: opened Screen Sharing; authentication is handled by the client")
        var saved = storedSettings(); saved[host] = settings
        defaults.set(try JSONEncoder().encode(saved), forKey: settingsKey)
    }

    func disconnect(_ host: String) {
        connected.remove(host)
        if let tunnel = tunnels.removeValue(forKey: host) { Self.stop(tunnel.process, directory: tunnel.directory) }
    }

    private func disconnectAll() { for host in Array(tunnels.keys) { disconnect(host) } }

    private func runSSH(_ arguments: [String]) async throws -> Data {
        let (process, directory) = try launchSSH(arguments)
        defer { Self.stop(process, directory: directory) }
        for _ in 0..<150 {
            try Task.checkCancellation()
            if !process.isRunning {
                guard process.terminationStatus == 0 else { throw RemoteVNCError.message(Self.failure(in: directory)) }
                return try Data(contentsOf: directory.appendingPathComponent("stdout"))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RemoteVNCError.message("SSH timed out while starting VNC.")
    }

    private func launchSSH(_ arguments: [String]) throws -> (Process, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lattices-vnc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            var handles: [FileHandle] = []
            defer { for handle in handles { try? handle.close() } }
            for name in ["stdout", "stderr"] {
                let url = directory.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: url); handles.append(handle)
                if name == "stdout" { process.standardOutput = handle } else { process.standardError = handle }
            }
            try process.run()
            return (process, directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private static func failure(in directory: URL) -> String {
        let raw = (try? String(contentsOf: directory.appendingPathComponent("stderr"), encoding: .utf8)) ?? ""
        let detail = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        return detail.isEmpty ? "SSH could not connect. Check your SSH configuration and keys." : detail
    }

    private static func stop(_ process: Process, directory: URL) {
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteVNCError.message("Could not reserve a local VNC port.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw RemoteVNCError.message("Could not reserve a local VNC port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

}

/// A bounded, cancellable readiness check, including DNS resolution. It reads
/// only the RFB greeting; credentials and authentication remain in Screen Sharing.
final class RemoteVNCProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.lattices.vnc-probe")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    private init(address: String, port: UInt16) {
        let host = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
    }

    static func check(address: String, port: Int, timeout: TimeInterval = 5) async -> Bool {
        guard (1...65535).contains(port) else { return false }
        return await RemoteVNCProbe(address: address, port: UInt16(port)).run(timeout: timeout)
    }

    private func run(timeout: TimeInterval) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !self.finished else { continuation.resume(returning: false); return }
                    self.continuation = continuation
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] data, _, _, _ in
                                let banner = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                                self?.finish(banner.range(of: "^RFB [0-9]{3}\\.[0-9]{3}\\n$", options: .regularExpression) != nil)
                            }
                        case .failed, .cancelled: self.finish(false)
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(false) }
        }
    }

    private func finish(_ result: Bool) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: result)
        continuation = nil
    }
}
