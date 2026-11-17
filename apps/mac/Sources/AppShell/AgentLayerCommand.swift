import Darwin
import Foundation

struct AgentLayerCommandError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct AgentLayerReply: Decodable, Sendable {
    struct Layer: Decodable, Sendable {
        struct Preview: Decodable, Sendable { let pip: Bool? }
        let active: Bool
        let layer: Preview?
    }
    struct Workspace: Decodable, Sendable {
        let workspace: String
        let layer: Layer
    }
    let ok: Bool
    let error: String?
    let workspaces: [Workspace]?
    let layer: Layer?

    func requireSuccess() throws {
        guard ok else { throw AgentLayerCommandError(message: error ?? "Action could not complete the request") }
    }

    func activeWorkspaces() throws -> [String] {
        try requireSuccess()
        guard let workspaces else { throw AgentLayerCommandError(message: "Action returned an invalid workspace list") }
        return workspaces.filter { $0.layer.active }.map(\.workspace)
    }

    func requireVisiblePreview() throws {
        try requireSuccess()
        guard layer?.active == true, layer?.layer?.pip == true else {
            throw AgentLayerCommandError(message: "Action did not confirm a visible preview. Click to try again.")
        }
    }
}

enum AgentLayerCommand {
    static func run(_ args: [String]) async throws -> AgentLayerReply {
        try await Task.detached(priority: .utility) {
            guard let bun = LatticesRuntime.bunPath, let root = LatticesRuntime.cliRoot,
                  FileManager.default.fileExists(atPath: root + "/bin/lattices.ts") else {
                throw AgentLayerCommandError(message: "Install Bun and a matching Lattices CLI to show agent layers")
            }
            let result = try capture(executable: bun, arguments: [root + "/bin/lattices.ts", "action"] + args,
                                     environment: environment(bun: bun), timeout: 10)
            return try decode(stdout: result.stdout, stderr: result.stderr, status: result.status)
        }.value
    }

    static func environment(bun: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited
        env.removeValue(forKey: "CLAUDECODE")
        // Both lats and the product script launch Bun again by name.
        let bin = URL(fileURLWithPath: bun).deletingLastPathComponent().path
        env["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    static func decode(stdout: Data, stderr: Data, status: Int32) throws -> AgentLayerReply {
        // Skip only the known Bun script echo; arbitrary logs are not JSON.
        let text = String(decoding: stdout, as: UTF8.self)
        let json = text.split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("$ ") })
            .joined(separator: "\n")
        if let reply = try? JSONDecoder().decode(AgentLayerReply.self, from: Data(json.utf8)) {
            try reply.requireSuccess()
            guard status == 0 else { throw AgentLayerCommandError(message: "Action exited unsuccessfully (status \(status))") }
            return reply
        }
        let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentLayerCommandError(message: detail.isEmpty
            ? "Action returned invalid JSON (status \(status))"
            : "Action failed: \(detail.prefix(500))")
    }

    struct Output {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    /// Run off the main actor. Nonblocking pipes and waitpid avoid the GUI
    /// CFRunLoop dependency of Process.waitUntilExit. Bound both time and output.
    static func capture(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> Output {
        var stdout: [Int32] = [0, 0]
        var stderr: [Int32] = [0, 0]
        guard pipe(&stdout) == 0 else { throw posixError() }
        defer { close(stdout[0]) }
        guard pipe(&stderr) == 0 else { close(stdout[1]); throw posixError() }
        defer { close(stderr[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO)
        for fd in stdout + stderr { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(stdout[1])
        close(stderr[1])
        guard result == 0 else { throw posixError(result) }
        var reaped = false
        defer {
            if !reaped {
                // Only this command's process group, including nested Bun children.
                // Keep its leader unreaped until after signaling, preventing PID reuse.
                kill(-pid, SIGKILL)
                while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
            }
        }
        for fd in [stdout[0], stderr[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw posixError() }
        }
        var output = [Data(), Data()]
        var eof = [false, false]
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AgentLayerCommandError(message: "Action timed out. Click to try again.")
            }
            for (index, fd) in [stdout[0], stderr[0]].enumerated() where !eof[index] {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard output[index].count + count <= 1_048_576 else {
                        throw AgentLayerCommandError(message: "Action returned too much output")
                    }
                    output[index].append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    eof[index] = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw posixError()
                }
            }
            if eof.allSatisfy({ $0 }) {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid {
                    reaped = true
                    let signal = status & 0x7f
                    let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                    return Output(stdout: output[0], stderr: output[1], status: exitStatus)
                }
                if waited == -1 && errno != EINTR { throw posixError() }
            }
            var descriptors = [pollfd(fd: eof[0] ? -1 : stdout[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: eof[1] ? -1 : stderr[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
        }
    }

    private static func posixError(_ code: Int32 = errno) -> AgentLayerCommandError {
        AgentLayerCommandError(message: "Could not run Action: \(String(cString: strerror(code)))")
    }
}
