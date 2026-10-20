import Foundation

// MARK: - Data Models

struct ProcessEntry {
    let pid: Int
    let ppid: Int
    let pgid: Int
    let tty: String        // "ttys003" or "??"
    let comm: String       // basename, e.g. "node"
    let args: String       // full command line
    var cwd: String?       // filled by batchCWD
}

// MARK: - Query

enum ProcessQuery {

    /// Process names we care about for developer workspace enrichment
    static let interestingCommands: Set<String> = [
        "claude", "node", "bun", "deno", "python", "python3",
        "ruby", "go", "cargo", "nvim", "vim", "npm", "npx",
        "pnpm", "swift", "make", "git"
    ]

    static let interactiveShellCommands: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash"
    ]

    static func isInteractiveShell(_ command: String) -> Bool {
        interactiveShellCommands.contains(
            command.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        )
    }

    /// Snapshot the full process table in a single `ps` call.
    /// Returns [pid: ProcessEntry].
    static func snapshot() -> [Int: ProcessEntry] {
        let raw = shell([
            "/bin/ps", "-eo", "pid,ppid,pgid,tty,comm,args"
        ])
        guard !raw.isEmpty else { return [:] }

        var table: [Int: ProcessEntry] = [:]
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.dropFirst() { // skip header
            let str = String(line)
            // Columns are whitespace-separated; args can contain spaces.
            // Format: "  PID  PPID  PGID TTY      COMM             ARGS"
            let trimmed = str.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6 else { continue }

            guard let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let pgid = Int(parts[2]) else { continue }

            let tty = String(parts[3])
            let commFull = String(parts[4])
            let args = String(parts[5])

            // comm from ps is the full path; take basename
            let comm = (commFull as NSString).lastPathComponent

            table[pid] = ProcessEntry(
                pid: pid, ppid: ppid, pgid: pgid,
                tty: tty, comm: comm, args: args, cwd: nil
            )
        }

        return table
    }

    /// Batch-resolve working directories for a set of PIDs via a single `lsof` call.
    /// Returns [pid: cwdPath].
    static func batchCWD(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }

        let pidList = pids.map(String.init).joined(separator: ",")
        let raw = shell([
            "/usr/sbin/lsof", "-a", "-d", "cwd", "-p", pidList, "-Fn"
        ])
        guard !raw.isEmpty else { return [:] }

        var result: [Int: String] = [:]
        var currentPid: Int?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.hasPrefix("p") {
                currentPid = Int(s.dropFirst())
            } else if s.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(s.dropFirst())
            }
        }

        return result
    }

    /// Filter a process table down to interesting developer processes.
    static func filterInteresting(_ table: [Int: ProcessEntry]) -> [ProcessEntry] {
        table.values.filter { interestingCommands.contains($0.comm) }
    }

    // MARK: - Shell helper

    /// Run a command and capture stdout using posix_spawn + waitpid.
    /// Avoids Process/NSTask's waitUntilExit() which deadlocks on macOS 26
    /// when called from GUI apps (CFRunLoop issue).
    static func shell(_ args: [String]) -> String {
        guard !args.isEmpty else { return "" }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return "" }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return "" }
        // Set up stdout pipe
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else { return "" }

        // File actions: stdout → write end of pipe, stderr → /dev/null
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&fileActions, pipeFds[0])
        posix_spawn_file_actions_addclose(&fileActions, pipeFds[1])

        // Build C strings
        let cPath = args[0]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.compactMap({ $0 }).forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = cPath.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attributes, cArgs, environ)
        }
        posix_spawn_file_actions_destroy(&fileActions)

        // Close write end in parent
        close(pipeFds[1])

        guard spawnResult == 0 else {
            close(pipeFds[0])
            return ""
        }

        // Read all stdout
        var data = Data()
        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = read(pipeFds[0], &buf, bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        close(pipeFds[0])

        // Wait for child
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        guard status == 0 else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Run a command with stdout/stderr discarded using posix_spawn + waitpid.
    /// Returns true when the process exits with status 0.
    static func run(_ args: [String]) -> Bool {
        guard !args.isEmpty else { return false }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return false }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let cPath = args[0]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.compactMap({ $0 }).forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = cPath.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attributes, cArgs, environ)
        }
        posix_spawn_file_actions_destroy(&fileActions)

        guard spawnResult == 0 else {
            return false
        }

        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else {
            return false
        }
        return status == 0
    }
}
