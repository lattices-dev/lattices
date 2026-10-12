import Foundation
import Network

/// One WebSocket to another lattices host (LAT-013): the daemon envelope
/// `{id, method, params}` out, `{id, result, error}` and `{event, data}` back.
///
/// Network.framework rather than URLSession: the host is a tailnet name or a
/// 100.x address over plain ws://, which ATS would otherwise refuse.
final class RemoteHostConnection: @unchecked Sendable {
    enum Failure: LocalizedError {
        case closed
        case timedOut(String)
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .closed: return "Connection closed"
            case .timedOut(let method): return "\(method) timed out"
            case .remote(let message): return message
            }
        }
    }

    let address: String
    let port: UInt16

    /// Called on the main queue.
    var onReady: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var onClose: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "com.arach.lattices.remote-host")
    private var connection: NWConnection?
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 0
    private var closed = false

    init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    func start() {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        // Stills come back as base64 in one frame.
        options.maximumMessageSize = 64 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        guard let url = URL(string: "ws://\(address):\(port)") else {
            finish("Bad address \(address)")
            return
        }
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.onReady?() }
            case .failed(let error):
                self?.finish(error.localizedDescription)
            case .waiting(let error):
                // Unreachable host: report it instead of waiting forever.
                self?.finish(error.localizedDescription)
            case .cancelled:
                self?.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    func cancel() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }

    func call(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 10) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed, let connection else {
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                nextID += 1
                let id = "mac-\(nextID)"
                var request: [String: Any] = ["id": id, "method": method]
                if let params { request["params"] = params }
                guard let data = try? JSONSerialization.data(withJSONObject: request) else {
                    continuation.resume(throwing: Failure.remote("Unencodable params for \(method)"))
                    return
                }
                pending[id] = continuation
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: method, metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(method))
                }
            }
        }
    }

    // MARK: - Private (on `queue`)

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if let error {
                self.finish(error.localizedDescription)
                return
            }
            if !self.closed { self.receive(on: connection) }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let event = object["event"] as? String {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            return
        }
        guard let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? String, !error.isEmpty {
            continuation.resume(throwing: Failure.remote(error))
        } else {
            continuation.resume(returning: object["result"] ?? NSNull())
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        for continuation in pending.values { continuation.resume(throwing: Failure.closed) }
        pending.removeAll()
        connection?.cancel()
        DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
    }
}
