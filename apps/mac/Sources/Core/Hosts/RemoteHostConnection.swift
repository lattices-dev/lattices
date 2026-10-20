import CryptoKit
import Darwin
import DeckKit
import Foundation

/// A signed WebSocket to another host's gateway: the daemon envelope
/// `{id, method, params}` out, `{id, result, error}` and `{event, data}` back.
///
/// URLSession performs the standard WebSocket upgrade. Plain ws:// remote
/// access is admitted only by the gateway on its verified Tailscale binding.
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
    private var connection: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionDelegate: GatewaySessionDelegate?
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 0
    private var closed = false
    private let credentialDirectory: URL
    private let handshakeTimeout: TimeInterval
    private var handshakeDeadline: DispatchWorkItem?

    init(address: String, port: UInt16, credentialDirectory: URL = RemoteHostGatewayCredentials.directory,
         handshakeTimeout: TimeInterval = 15) {
        self.address = address
        self.port = port
        self.credentialDirectory = credentialDirectory
        self.handshakeTimeout = handshakeTimeout
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        guard !closed, connection == nil else { return }
        let headers: [String: String]
        do {
            headers = try RemoteHostGatewayCredentials.headers(address: address, port: port, directory: credentialDirectory)
        } catch {
            finish(error.localizedDescription)
            return
        }
        guard let url = RemoteHostGatewayCredentials.gatewayURL(address: address, port: port) else {
            finish("Bad address \(address)")
            return
        }
        var request = URLRequest(url: url)
        // The explicit deadline below owns upgrade timeouts and their error.
        request.timeoutInterval = max(60, handshakeTimeout + 5)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let delegate = GatewaySessionDelegate(owner: self)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        let connection = session.webSocketTask(with: request)
        // Stills come back as base64 in one frame.
        connection.maximumMessageSize = 64 * 1024 * 1024
        self.session = session
        self.sessionDelegate = delegate
        self.connection = connection
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish("Gateway handshake timed out. Check gateway availability and Tailscale access.")
        }
        handshakeDeadline = deadline
        queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: deadline)
        connection.resume()
    }

    func cancel() {
        // Owners cancel and immediately remove this connection from their model.
        // Retain it until shutdown has reached the serial queue.
        queue.async { [self] in finish(nil) }
    }

    deinit { session?.invalidateAndCancel() }

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
                connection.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                    if let error {
                        self?.queue.async { [weak self] in self?.finish(error.localizedDescription) }
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(method))
                }
            }
        }
    }

    // MARK: - Private (on `queue`)

    private func opened(_ task: URLSessionWebSocketTask) {
        guard !closed, task === connection else { return }
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        receive(on: task)
        DispatchQueue.main.async { [weak self] in self?.onReady?() }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, !self.closed, task === self.connection else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    if !self.closed { self.receive(on: task) }
                case .failure(let error):
                    self.finish("Gateway connection failed: \(error.localizedDescription). Check gateway pairing and Tailscale access.")
                }
            }
        }
    }

    /// URLSession retains its delegate until invalidation. A weak owner keeps
    /// that lifecycle from retaining the remote-host model or connection.
    private final class GatewaySessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: RemoteHostConnection?
        init(owner: RemoteHostConnection) { self.owner = owner }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            owner?.opened(webSocketTask)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            owner?.finish("Gateway closed the connection (\(closeCode.rawValue)). Check whether this client was revoked.")
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                owner?.finish("Gateway connection failed: \(error.localizedDescription). Check gateway pairing and Tailscale access.")
            } else { owner?.finish(nil) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // The credentials authenticate one configured gateway. Never send
            // signed upgrade headers to an endpoint selected by a redirect.
            completionHandler(nil)
            owner?.finish("Gateway redirects are not allowed. Check the configured gateway address.")
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
            continuation.resume(throwing: Failure.remote(Self.gatewayError(error)))
        } else {
            continuation.resume(returning: object["result"] ?? NSNull())
        }
    }

    static func gatewayError(_ message: String) -> String {
        if message.hasPrefix("pairing_required:") { return "Gateway pairing required. Pair this Mac with lats --host <name> pair --read-only." }
        if message.hasPrefix("scope_denied:") { return "Gateway permission denied: \(message.dropFirst("scope_denied:".count).trimmingCharacters(in: .whitespaces))" }
        if message.hasPrefix("method_denied:") { return "This operation is unavailable through the gateway: \(message.dropFirst("method_denied:".count).trimmingCharacters(in: .whitespaces))" }
        return message
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        for continuation in pending.values { continuation.resume(throwing: Failure.closed) }
        pending.removeAll()
        connection?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        connection = nil
        session = nil
        sessionDelegate = nil
        DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
    }
}


/// Reads the CLI's gateway trust; companion VisitTrust credentials are a
/// separate identity and never grant daemon access. This reader never creates
/// keys, pairs implicitly, or falls back to an unsigned connection.
enum RemoteHostGatewayCredentials {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices", isDirectory: true)

    struct StoredHost: Decodable {
        let host: String
        let hostPublicKey: String
        let hostFingerprint: String
    }
    private struct Identity: Decodable {
        let id: String
        let privateKey: JWK
    }
    private struct JWK: Decodable {
        let kty: String
        let crv: String
        let d: String
        let x: String
    }
    enum Failure: LocalizedError {
        case unpaired
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .unpaired: return "Gateway pairing required. Pair this Mac with lats --host <name> pair --read-only; companion pairing is separate."
            case .invalid(let detail): return "Gateway credentials are invalid: \(detail). Pair this Mac again with the gateway."
            }
        }
    }

    static func gatewayURL(address: String, port: UInt16) -> URL? {
        guard !address.isEmpty, port > 0,
              !address.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) else { return nil }
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        guard let parts = URLComponents(string: "ws://\(host):\(port)/"),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.path == "/", parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    static func pairedHost(address: String, port: UInt16, hosts: [String: StoredHost]) -> StoredHost? {
        if let exact = hosts["\(address):\(port)"] { return exact }
        let short = address.split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        let matches = hosts.filter { $0.key.hasSuffix(":\(port)") && $0.value.host.lowercased() == short }
        // An ambiguous alias must not pick an unrelated host's key.
        return matches.count == 1 ? matches.first?.value : nil
    }

    static func headers(address: String, port: UInt16, directory: URL = directory,
                        now: Date = Date(), nonce: String = UUID().uuidString.lowercased()) throws -> [String: String] {
        guard let url = gatewayURL(address: address, port: port), let validatedHost = url.host else { throw Failure.invalid("bad gateway address") }
        let hostsURL = directory.appendingPathComponent("paired-hosts.json")
        guard FileManager.default.fileExists(atPath: hostsURL.path) else { throw Failure.unpaired }
        let hosts: [String: StoredHost]
        do { hosts = try JSONDecoder().decode([String: StoredHost].self, from: readPrivate(hostsURL)) }
        catch let error as Failure { throw error }
        catch { throw Failure.invalid("cannot read paired-hosts.json") }
        guard let host = pairedHost(address: address, port: port, hosts: hosts) else { throw Failure.unpaired }
        guard DeckBridgeClientCrypto.fingerprint(publicKeyBase64: host.hostPublicKey) == host.hostFingerprint else {
            throw Failure.invalid("gateway fingerprint mismatch")
        }
        do {
            let identity = try JSONDecoder().decode(Identity.self, from: readPrivate(directory.appendingPathComponent("client.json")))
            guard !identity.id.isEmpty, identity.id.utf8.count <= 128,
                  identity.id.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
                  identity.privateKey.kty == "OKP", identity.privateKey.crv == "X25519",
                  let raw = base64URL(identity.privateKey.d), raw.count == 32,
                  let publicRaw = base64URL(identity.privateKey.x), publicRaw.count == 32 else {
                throw Failure.invalid("malformed client identity")
            }
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
            guard key.publicKey.rawRepresentation == publicRaw else { throw Failure.invalid("client public key mismatch") }
            var headers = try DeckBridgeClientCrypto(privateKey: key, deviceID: identity.id, bridgePublicKey: host.hostPublicKey)
                .sign(method: "GET", path: "/", plaintext: nil, encrypt: false, now: now, nonce: nonce).headers
            // The gateway requires the complete, explicitly allowed authority,
            // independent of the transport's generated Host header.
            let authorityHost = validatedHost.contains(":") && !validatedHost.hasPrefix("[") ? "[\(validatedHost)]" : validatedHost
            headers["Host"] = "\(authorityHost):\(port)"
            return headers
        } catch let error as Failure { throw error }
        catch { throw Failure.invalid("cannot read the X25519 client identity") }
    }

    private static func base64URL(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private static func readPrivate(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalid("cannot open \(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= 1024 * 1024 else {
            throw Failure.invalid("\(url.lastPathComponent) must be an owned private regular file")
        }
        guard let data = try handle.read(upToCount: 1024 * 1024 + 1), data.count <= 1024 * 1024 else {
            throw Failure.invalid("credential file too large")
        }
        return data
    }
}
