import Combine
import Foundation

/// Reads Action status on page/focus changes and on click, never on a timer.
/// Showing a preview never prepares or releases a display.
@MainActor
final class AgentLayerShortcut: ObservableObject {
    static let shared = AgentLayerShortcut()
    typealias Command = @Sendable ([String]) async throws -> AgentLayerReply

    @Published private(set) var activeWorkspaces: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var refreshing = false
    @Published private(set) var lastError: String?

    // An empty or failed snapshot must still allow a click to check again.
    var canShow: Bool { !busy }

    private let command: Command
    private var operation: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingShow = false

    init(command: @escaping Command = { try await AgentLayerCommand.run($0) }) {
        self.command = command
    }

    func refresh() {
        guard operation == nil else {
            pendingRefresh = true
            return
        }
        start(show: false)
    }

    func show() {
        guard !busy else { return }
        busy = true
        guard operation == nil else {
            pendingShow = true
            return
        }
        start(show: true)
    }

    private func start(show: Bool) {
        refreshing = true
        operation = Task {
            do {
                let active = try await command(["layer", "list"]).activeWorkspaces()
                activeWorkspaces = active
                lastError = nil
                if show {
                    if active.isEmpty { lastError = "No agent task is running. Click to check again." }
                    var failures: [String] = []
                    for workspace in active {
                        do {
                            let reply = try await command(["layer", "pip", "--workspace", workspace])
                            try reply.requireVisiblePreview()
                        } catch {
                            failures.append("\(workspace): \(error.localizedDescription)")
                        }
                    }
                    if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
                }
            } catch {
                // A failed read is unknown status, not a successful empty list.
                lastError = error.localizedDescription
            }
            if let lastError { DiagnosticLog.shared.warn("Agent layer: \(lastError)") }
            refreshing = false
            if show { busy = false }
            operation = nil
            // Serialize requests and replay changes received during a read.
            // A queued click always does its own fresh list before showing.
            if pendingShow {
                pendingShow = false
                pendingRefresh = false
                start(show: true)
            } else if pendingRefresh {
                pendingRefresh = false
                start(show: false)
            }
        }
    }
}
