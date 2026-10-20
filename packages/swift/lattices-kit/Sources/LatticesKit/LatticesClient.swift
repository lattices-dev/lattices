import Foundation

public enum LatticesError: LocalizedError, Equatable, Sendable {
    case daemonError(String)
    case disconnected
    case invalidMessage
    case invalidResponse
    case timeout(method: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .daemonError(let message):
            return message
        case .disconnected:
            return "The Lattices daemon connection closed."
        case .invalidMessage:
            return "The Lattices daemon sent an invalid WebSocket message."
        case .invalidResponse:
            return "The Lattices daemon sent an invalid RPC response."
        case .timeout(let method):
            return "The Lattices daemon request timed out: \(method)"
        case .cancelled:
            return "The Lattices daemon request was cancelled."
        }
    }
}

public struct LatticesEvent: Codable, Equatable, Sendable {
    public var event: String
    public var data: JSONValue

    public init(event: String, data: JSONValue) {
        self.event = event
        self.data = data
    }
}

public final class LatticesClient: @unchecked Sendable {
    public static var defaultEndpoint: URL {
        let directory = ProcessInfo.processInfo.environment["LATTICES_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/run")
        return directory.appendingPathComponent("lattices.sock")
    }

    private let transport: LatticesTransport

    public let windows: LatticesWindows
    public let projects: LatticesProjects
    public let tmux: LatticesTmux
    public let sessions: LatticesSessions
    public let accessibility: LatticesAccessibility
    public let input: LatticesInput
    public let layout: LatticesLayout

    public var events: AsyncStream<LatticesEvent> {
        transport.events
    }

    public init(
        endpoint: URL = LatticesClient.defaultEndpoint,
        defaultTimeout: TimeInterval = 15
    ) {
        let transport = LatticesTransport(endpoint: endpoint, defaultTimeout: defaultTimeout)
        self.transport = transport
        self.windows = LatticesWindows(transport: transport)
        self.projects = LatticesProjects(transport: transport)
        self.tmux = LatticesTmux(transport: transport)
        self.sessions = LatticesSessions(transport: transport)
        self.accessibility = LatticesAccessibility(transport: transport)
        self.input = LatticesInput(transport: transport)
        self.layout = LatticesLayout(transport: transport)
    }

    public func connect() async {
        await transport.connect()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    @discardableResult
    public func call(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        try await transport.call(method, params: params, timeout: timeout)
    }

    public func decode<T: Decodable>(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        let result = try await call(method, params: params, timeout: timeout)
        return try result.decoded(as: type)
    }

    public func status() async throws -> LatticesDaemonStatus {
        try await decode("daemon.status")
    }

    public func isDaemonRunning() async -> Bool {
        do {
            _ = try await status()
            return true
        } catch {
            return false
        }
    }

    public func apiSchema() async throws -> LatticesAPISchema {
        try await decode("api.schema")
    }
}

private struct DaemonRequest: Encodable {
    let id: String
    let method: String
    let params: JSONValue?
}

private struct DaemonResponse: Decodable {
    let id: String
    let result: JSONValue?
    let error: String?
}

actor LatticesTransport {
    nonisolated let events: AsyncStream<LatticesEvent>

    private let endpoint: URL
    private let defaultTimeout: TimeInterval
    private let session: URLSession
    private let eventContinuation: AsyncStream<LatticesEvent>.Continuation
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var task: LocalWebSocket?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingTimeouts: [String: Task<Void, Never>] = [:]

    init(endpoint: URL, defaultTimeout: TimeInterval) {
        self.endpoint = endpoint
        self.defaultTimeout = defaultTimeout
        self.session = URLSession(configuration: .default)

        var continuation: AsyncStream<LatticesEvent>.Continuation!
        self.events = AsyncStream<LatticesEvent> { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation
    }

    func connect() {
        guard task == nil else { return }
        let nextTask = LocalWebSocket(endpoint: endpoint, session: session)
        task = nextTask
        nextTask.resume()
        receiveTask = Task { await receiveLoop(task: nextTask) }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAll(error: LatticesError.disconnected)
    }

    func call(_ method: String, params: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        do {
            return try await send(method, params: params, timeout: timeout)
        } catch {
            guard LegacyMethodNames.isUnknownMethod(error, method: method),
                  let legacy = LegacyMethodNames.fallback(for: method, params: params) else {
                throw error
            }
            return try await send(legacy, params: params, timeout: timeout)
        }
    }

    private func send(_ method: String, params: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        connect()

        guard let task else {
            throw LatticesError.disconnected
        }

        let id = UUID().uuidString
        let request = DaemonRequest(id: id, method: method, params: params ?? .null)
        let data = try encoder.encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LatticesError.invalidMessage
        }

        let deadline = timeout ?? defaultTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation

                if deadline > 0 {
                    pendingTimeouts[id] = Task { [weak self] in
                        let nanoseconds = UInt64(deadline * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        await self?.failPending(id: id, error: LatticesError.timeout(method: method))
                    }
                }

                Task { [weak self] in
                    do {
                        try await task.send(.string(text))
                    } catch {
                        await self?.failPending(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(id: id, error: LatticesError.cancelled)
            }
        }
    }

    private func receiveLoop(task: LocalWebSocket) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else {
                        throw LatticesError.invalidMessage
                    }
                    text = value
                @unknown default:
                    throw LatticesError.invalidMessage
                }
                route(text)
            } catch {
                handleDisconnect(task: task, error: error)
                return
            }
        }
    }

    private func route(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }

        if let event = try? decoder.decode(LatticesEvent.self, from: data), !event.event.isEmpty {
            eventContinuation.yield(event)
            return
        }

        guard let response = try? decoder.decode(DaemonResponse.self, from: data) else {
            return
        }

        guard let continuation = pending.removeValue(forKey: response.id) else {
            return
        }
        pendingTimeouts.removeValue(forKey: response.id)?.cancel()

        if let error = response.error {
            continuation.resume(throwing: LatticesError.daemonError(error))
        } else {
            continuation.resume(returning: response.result ?? .null)
        }
    }

    private func handleDisconnect(task disconnectedTask: LocalWebSocket, error: Error) {
        guard task === disconnectedTask else { return }
        task = nil
        receiveTask = nil
        failAll(error: error)
    }

    private func failPending(id: String, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else {
            return
        }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: error)
    }

    private func failAll(error: Error) {
        let continuations = pending.values
        pending.removeAll()
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
