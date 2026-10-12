import DeckKit
import Foundation

/// The `/visit` WebSocket to a paired host (docs/visit.md): the upgrade is
/// signed like any bridge request, every frame after it is sealed with the
/// device's key, AAD naming the direction and its sequence number. Pings
/// every 2s while open; 6s without a frame from the host ends it.
final class VisitChannel: NSObject, URLSessionWebSocketDelegate {
    static let pingEvery: TimeInterval = 2
    static let silence: TimeInterval = 6
    /// Moves are added up and sent at most this often.
    static let moveEvery: TimeInterval = 0.008

    private let crypto: DeckBridgeClientCrypto
    private let request: URLRequest
    private let nonce: String
    private let queue = DispatchQueue(label: "com.arach.lattices.visit-channel", qos: .userInteractive)
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var up: UInt64 = 0
    private var down: UInt64 = 0
    private var heard = Date()
    private var ticker: DispatchSourceTimer?
    private var pending: (dx: Double, dy: Double)?
    private var flushQueued = false
    private var opened = false
    private var buffered: [[String: Any]] = []
    private var closed = false

    /// Called on the channel's queue.
    var onMessage: (([String: Any]) -> Void)?
    /// Called once, on the channel's queue, with why it closed.
    var onClose: ((String) -> Void)?

    init(host: VisitTrust.Host, crypto: DeckBridgeClientCrypto) throws {
        guard let url = URL(string: "ws://\(host.address)/visit") else { throw VisitTrust.Failure.bad("Bad address \(host.address)") }
        let signed = try crypto.sign(method: "GET", path: "/visit", plaintext: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        for (name, value) in signed.headers { request.setValue(value, forHTTPHeaderField: name) }
        self.crypto = crypto
        self.request = request
        self.nonce = signed.nonce
        super.init()
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: operations)
    }

    func open() {
        queue.async {
            let task = self.session.webSocketTask(with: self.request)
            self.task = task
            task.resume()
            self.receive()
        }
    }

    /// Sends now, or once the socket opens.
    func send(_ message: [String: Any]) {
        queue.async { self.write(message) }
    }

    func move(dx: Double, dy: Double) {
        queue.async {
            let sum = self.pending ?? (0, 0)
            self.pending = (sum.dx + dx, sum.dy + dy)
            guard !self.flushQueued else { return }
            self.flushQueued = true
            self.queue.asyncAfter(deadline: .now() + Self.moveEvery) { self.flushMove() }
        }
    }

    /// Sends anything held back, `leave` if asked, then closes.
    func close(leaving: Bool) {
        queue.async {
            self.flushMove()
            if leaving { self.write(["t": "leave"]) }
            self.finish("closed here", code: .normalClosure)
        }
    }

    // MARK: Queue only

    private func flushMove() {
        flushQueued = false
        guard let move = pending else { return }
        pending = nil
        write(["t": "move", "dx": move.dx, "dy": move.dy])
    }

    private func write(_ message: [String: Any]) {
        guard !closed else { return }
        guard opened, let task else { buffered.append(message); return }
        do {
            let plaintext = try JSONSerialization.data(withJSONObject: message)
            let frame = try crypto.sealFrame(plaintext, direction: .up, upgradeNonce: nonce, seq: up)
            up += 1
            task.send(.data(frame)) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async { self.finish("send failed: \(error.localizedDescription)") }
            }
        } catch {
            finish("couldn't seal a frame")
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure(let error):
                    self.finish(error.localizedDescription)
                case .success(.data(let frame)):
                    guard let plaintext = try? self.crypto.openFrame(frame, direction: .down, upgradeNonce: self.nonce, seq: self.down),
                          let message = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else {
                        self.finish("bad frame from host", code: .policyViolation)
                        return
                    }
                    self.down += 1
                    self.heard = Date()
                    self.onMessage?(message)
                    self.receive()
                case .success:
                    self.finish("unexpected text frame", code: .policyViolation)
                }
            }
        }
    }

    private func finish(_ reason: String, code: URLSessionWebSocketTask.CloseCode = .goingAway) {
        guard !closed else { return }
        closed = true
        ticker?.cancel()
        ticker = nil
        task?.cancel(with: code, reason: nil)
        session.finishTasksAndInvalidate()
        onClose?(reason)
        onClose = nil
        onMessage = nil
    }

    // MARK: URLSessionWebSocketDelegate (on the queue)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened = true
        heard = Date()
        let held = buffered
        buffered = []
        held.forEach(write)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.heard) > Self.silence { self.finish("host went quiet"); return }
            self.write(["t": "ping"])
        }
        ticker = timer
        timer.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish("host closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        finish(status.map { "upgrade refused (\($0))" } ?? error?.localizedDescription ?? "ended")
    }
}
