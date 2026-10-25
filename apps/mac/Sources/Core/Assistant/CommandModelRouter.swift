import Foundation

/// Command inference has its own preference; it never changes the chat model.
enum CommandModelPreference: String, CaseIterable {
    case automatic, codex, claude, grok, flash, api
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .codex: return "Codex · Luna"
        case .claude: return "Claude Code · Haiku"
        case .grok: return "Grok via Pi"
        case .flash: return "Flash via Pi"
        case .api: return "API connection"
        }
    }
}

struct CommandModelRoute: Equatable {
    let kind: CommandModelPreference
    let executable: URL
    let model: String
    var provider: String? = nil
    var label: String { provider.map { "\($0) · \(model)" } ?? "\(kind.label)" }

    func arguments(output: URL) -> [String] {
        switch kind {
        case .codex:
            return ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--skip-git-repo-check", "--sandbox", "read-only", "--model", model,
                    "-c", "model_reasoning_effort=\"none\"", "-c", "approval_policy=\"never\"",
                    "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "apps",
                    "--disable", "hooks", "--disable", "multi_agent", "--disable", "browser_use",
                    "--enable", "skip_host_skill_discovery", "--output-last-message", output.path, "-"]
        case .claude:
            return ["--print", "--model", model, "--output-format", "text", "--tools", "",
                    "--restricted", "--strict-mcp-config", "--disable-slash-commands",
                    "--no-session-persistence", "--settings", "{\"disableAllHooks\":true}"]
        default:
            return ["--print", "--provider", provider ?? "", "--model", model, "--thinking", kind == .grok ? "minimal" : "off",
                    "--no-tools", "--no-extensions", "--no-mcp", "--no-skills",
                    "--no-prompt-templates", "--no-context-files", "--no-session", "--no-approve"]
        }
    }
}

enum CommandInferenceError: LocalizedError {
    case unavailable, failed, timedOut, empty
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Connect Codex, Claude Code, a Pi provider, or an API key for command intelligence."
        case .failed: return "The command model could not complete the request. Check its connection."
        case .timedOut: return "The command model timed out."
        case .empty: return "The command model returned no answer."
        }
    }
}

/// Fresh, bounded inference sessions: no shared assistant history or execution authority.
/// Successful routes remain preferred until a transport failure or preference change.
actor CommandModelRouter {
    private var selected: CommandModelRoute?
    private var preference: CommandModelPreference = .automatic
    private var preferenceGeneration = 0
    private var piRoutes: [CommandModelRoute]?

    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
                ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
    }
    static func executable(_ name: String) -> URL? {
        searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static var hasRuntime: Bool { ["codex", "claude", "pi"].contains { executable($0) != nil } }

    static func routes(fromPiCatalog catalog: String, executable: URL) -> [CommandModelRoute] {
        var routes: [CommandModelRoute] = []
        for line in catalog.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 5 else { continue }
            let provider = columns[0], model = columns[1]
            let kind: CommandModelPreference
            if model.lowercased().contains("grok") { kind = .grok }
            else if (model.lowercased().contains("gemini") || model.lowercased().contains("deepseek")), model.lowercased().contains("flash") { kind = .flash }
            else { continue }
            routes.append(CommandModelRoute(kind: kind, executable: executable, model: model, provider: provider))
        }
        // Prefer newer versions within each family, preserving the requested family order.
        let sorted = routes.sorted {
            if $0.kind != $1.kind { return $0.kind == .grok }
            return $0.model.compare($1.model, options: .numeric) == .orderedDescending
        }
        var families = Set<String>()
        return sorted.filter { families.insert("\($0.provider ?? "")|\($0.kind.rawValue)").inserted }
    }

    static func eligibleStickyRoute(_ route: CommandModelRoute?, apiProviders: [String]) -> CommandModelRoute? {
        guard let route else { return nil }
        if route.kind == .api, !apiProviders.contains(route.provider ?? "") { return nil }
        return route
    }

    static func ordered(_ routes: [CommandModelRoute], preference: CommandModelPreference,
                        selected: CommandModelRoute?) -> [CommandModelRoute] {
        var result = preference == .automatic ? routes : routes.filter { $0.kind == preference }
        if let selected, let index = result.firstIndex(of: selected) {
            result.remove(at: index)
            result.insert(selected, at: 0)
        }
        return result
    }

    func complete(prompt: String, preference requested: CommandModelPreference,
                  apiProviders: [String] = [],
                  inferAPI: (String, String, TimeInterval) async throws -> String) async throws -> (String, String) {
        if requested != preference { selected = nil; preference = requested; preferenceGeneration += 1 }
        let generation = preferenceGeneration
        var routes: [CommandModelRoute] = []
        if let binary = Self.executable("codex") {
            routes.append(.init(kind: .codex, executable: binary, model: "gpt-6-luna"))
        }
        if apiProviders.contains("openai") {
            routes.append(.init(kind: .api, executable: URL(fileURLWithPath: "/"), model: "gpt-6-luna", provider: "openai"))
        }
        if let binary = Self.executable("claude") {
            routes.append(.init(kind: .claude, executable: binary, model: "haiku"))
        }
        if apiProviders.contains("anthropic") {
            routes.append(.init(kind: .api, executable: URL(fileURLWithPath: "/"), model: "claude-haiku-5-5", provider: "anthropic"))
        }
        let deadline = Date().addingTimeInterval(45)
        // Discovery is lazy: the common Codex/Claude path pays no Pi startup cost.
        var lastError: Error = CommandInferenceError.unavailable
        let preferred = Self.eligibleStickyRoute(selected, apiProviders: apiProviders)
        var attempted = Set<String>()
        for phase in 0...1 {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw CommandInferenceError.timedOut }
            if phase == 1, [.automatic, .grok, .flash].contains(requested), let pi = Self.executable("pi") {
                if piRoutes == nil {
                    let catalog = try? await CommandInferenceProcess.run(executable: pi,
                        arguments: ["--list-models"], prompt: "", timeout: min(8, deadline.timeIntervalSinceNow))
                    try Task.checkCancellation()
                    piRoutes = catalog.map { Self.routes(fromPiCatalog: $0, executable: pi) }
                }
                routes += piRoutes ?? []
            }
            if phase == 1, apiProviders.contains("openrouter") {
                routes.append(.init(kind: .api, executable: URL(fileURLWithPath: "/"),
                                    model: "google/gemini-2.5-flash", provider: "openrouter"))
            }
            // A working Pi route must remain first on subsequent requests too.
            if phase == 0, let preferred, preferred.provider != nil {
                // API credentials/provider selection can change between requests.
                // Only Pi needs early insertion; eligible API routes are already
                // constructed from this request's available providers.
                if preferred.kind != .api {
                    routes.insert(preferred, at: 0)
                } else if let provider = preferred.provider, apiProviders.contains(provider),
                          !routes.contains(preferred) {
                    routes.insert(preferred, at: 0)
                }
            }
            for route in Self.ordered(routes, preference: requested, selected: preferred) {
                let key = "\(route.executable.path)|\(route.provider ?? "")|\(route.model)"
                guard attempted.insert(key).inserted else { continue }
                try Task.checkCancellation()
                guard deadline.timeIntervalSinceNow > 0 else { throw CommandInferenceError.timedOut }
                do {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw CommandInferenceError.timedOut }
                    let text: String
                    if route.kind == .api {
                        text = try await inferAPI(route.provider!, route.model, min(15, remaining))
                    } else {
                        text = try await CommandInferenceProcess.infer(route: route, prompt: prompt, timeout: min(15, remaining))
                    }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandInferenceError.empty }
                    try Task.checkCancellation()
                    guard deadline.timeIntervalSinceNow > 0 else { throw CommandInferenceError.timedOut }
                    if generation == preferenceGeneration { selected = route }
                    return (text, route.label)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    lastError = error
                    if generation == preferenceGeneration, selected == route { selected = nil }
                    // Log route and error category only: CLI stderr can contain user data.
                    DiagnosticLog.shared.warn("Command inference failed via \(route.label)")
                }
            }
        }
        throw lastError
    }
}

/// File-backed stdio avoids pipe deadlocks. All waiting occurs on a worker queue;
/// a deadline terminates and then kills a child that ignores termination.
enum CommandInferenceProcess {
    static func infer(route: CommandModelRoute, prompt: String, timeout: TimeInterval = 15) async throws -> String {
        try await run(executable: route.executable, arguments: [], prompt: prompt, timeout: timeout, route: route)
    }

    static func run(executable: URL, arguments: [String], prompt: String, timeout: TimeInterval,
                    route: CommandModelRoute? = nil) async throws -> String {
        let job = CommandInferenceJob()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run(executable: executable, arguments: arguments,
                        prompt: prompt, timeout: timeout, route: route) })
                }
            }
        } onCancel: { job.cancel() }
    }
}

private final class CommandInferenceJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
    func run(executable: URL, arguments: [String], prompt: String, timeout: TimeInterval,
             route: CommandModelRoute?) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattices-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
        let answer = root.appendingPathComponent("answer")
        try Data(prompt.utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: input), stdout = try FileHandle(forWritingTo: output)
        defer { try? stdin.close(); try? stdout.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = route?.arguments(output: answer) ?? arguments
        child.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CommandModelRouter.searchPath
        child.environment = env
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        var stoppedAt: Date?
        while child.isRunning {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled || Date() >= deadline {
                if let stoppedAt {
                    if Date().timeIntervalSince(stoppedAt) > 1 { kill(child.processIdentifier, SIGKILL) }
                } else { stoppedAt = Date(); child.terminate() }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        child.waitUntilExit() // worker queue only; reaps after exit
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if stoppedAt != nil { throw CommandInferenceError.timedOut }
        guard child.terminationStatus == 0 else { throw CommandInferenceError.failed }
        let resultURL = route?.kind == .codex ? answer : output
        let text = try String(contentsOf: resultURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommandInferenceError.empty }
        return text
    }
}
