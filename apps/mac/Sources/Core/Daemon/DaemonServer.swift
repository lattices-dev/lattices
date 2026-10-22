import Foundation
import CommonCrypto

// MARK: - POSIX WebSocket Server
// NWListener is broken on macOS 26 (Tahoe) — EINVAL on any listener creation.
// Authenticated WebSocket protocol over a private same-user Unix socket.

final class DaemonServer: ObservableObject {
    static let shared = DaemonServer()

    @Published var clientCount: Int = 0
    @Published var isListening: Bool = false

    private let port: UInt16?
    private let socketPath: String?
    private let tokenURL: URL
    private var endpointLease: PrivateLocalEndpoint?
    private var authToken = ""
    private let handshakeQueue = DispatchQueue(label: "lattices.daemon.admission", attributes: .concurrent)
    private let handshakeSlots = DispatchSemaphore(value: 16)
    private let speechCapabilityURL: URL
    private let speechEndpoint: URL?
    private let eventBus: EventBus
    private var subscribedToEventBus = false
    private(set) var listeningPort: UInt16 = 0

    init(port: UInt16? = nil, socketPath: String? = nil, tokenURL: URL? = nil, speechCapabilityURL: URL = SpeechCompanionConnection.capabilityURL, speechEndpoint: URL? = nil, eventBus: EventBus = .shared) {
        let compatibility = ProcessInfo.processInfo.environment["LATTICES_ALLOW_LOOPBACK_TCP"] == "1"
        self.port = port ?? (compatibility ? LatticesLocalEndpoints.agentAPIPort : nil)
        self.socketPath = self.port == nil ? (socketPath ?? LatticesLocalEndpoints.agentSocketPath) : nil
        self.tokenURL = tokenURL ?? LatticesLocalEndpoints.agentTokenURL
        self.speechCapabilityURL = speechCapabilityURL
        self.speechEndpoint = speechEndpoint
        self.eventBus = eventBus
    }

    private var generation = UUID()
    private var serverFd: Int32 = -1
    private var clients: [UUID: WebSocketClient] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lattices.daemon", qos: .userInitiated)
    private let blockingRequestQueue = DispatchQueue(
        label: "lattices.daemon.blocking-requests",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let blockingMethods: Set<String> = [
        "windows.pick",
        // DDC round trips to a monitor take 100–250 ms, seconds for capabilities.
        "display.input.get",
        "display.input.set",
        "sessions.launch",
        // Relocation and undo can carry windows across Spaces, taking seconds.
        "windows.move",
        "windows.place",
        "windows.present",
        "actions.execute",
        "history.undo",
        // Frames must not queue behind input handlers that sleep.
        "capture.still",
        "capture.stream.start",
        "capture.stream.ack",
        "capture.stream.keyframe",
        "capture.stream.stop",
    ]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var acceptSource: DispatchSourceRead?

    func start() { queue.sync { startOnQueue() } }

    private func startOnQueue() {
        let diag = DiagnosticLog.shared

        guard serverFd < 0 else { return }
        do {
            endpointLease = try PrivateLocalEndpoint(socketPath: socketPath, tokenURL: tokenURL)
        } catch {
            diag.error("DaemonServer: private endpoint unavailable — \(error.localizedDescription)")
            return
        }
        // Default transport is a filesystem-protected, same-user Unix socket.
        serverFd = socket(socketPath == nil ? AF_INET : AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            diag.error("DaemonServer: socket() failed — errno \(errno)")
            endpointLease = nil
            return
        }
        guard PrivateLocalEndpoint.preventInheritance(serverFd) else {
            diag.error("DaemonServer: cannot protect socket descriptor — errno \(errno)")
            close(serverFd); serverFd = -1; endpointLease = nil
            return
        }

        // SO_REUSEADDR so we can restart quickly
        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        do {
            if let socketPath {
                try endpointLease!.bindSocket(serverFd, path: socketPath)
            } else if let port {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(serverFd, $0, &length) } }
                listeningPort = UInt16(bigEndian: bound.sin_port)
                diag.warn("DaemonServer: loopback TCP on port \(listeningPort); any local process can reach it with the token. Unset LATTICES_ALLOW_LOOPBACK_TCP to return to the socket.")
            }
            authToken = try endpointLease!.publishToken(at: tokenURL)
        } catch {
            diag.error("DaemonServer: endpoint setup failed — \(error.localizedDescription)")
            close(serverFd); serverFd = -1; endpointLease = nil
            return
        }

        // 3. Listen
        guard listen(serverFd, 8) == 0 else {
            diag.error("DaemonServer: listen() failed — errno \(errno)")
            close(serverFd)
            serverFd = -1
            endpointLease = nil
            return
        }

        // Non-blocking
        let flags = fcntl(serverFd, F_GETFL)
        _ = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)

        // 4. GCD dispatch source for accepting connections
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        let listeningFD = serverFd
        source.setCancelHandler { close(listeningFD) }
        source.resume()
        acceptSource = source

        DispatchQueue.main.async { self.isListening = true }
        diag.success("DaemonServer: listening on \(socketPath ?? "authenticated loopback port \(listeningPort)")")

        // The bus outlives a listener restart. Subscribe once per server so
        // every model event is delivered once after stop/start cycles.
        if !subscribedToEventBus {
            subscribedToEventBus = true
            eventBus.subscribe { [weak self] event in self?.broadcastEvent(event) }
        }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        generation = UUID()
        acceptSource?.cancel()
        acceptSource = nil
        serverFd = -1
        endpointLease = nil
        authToken = ""
        lock.lock()
        let closing = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        for client in closing {
            let speech = client.speechConnection
            Task { await speech?.close() }
            client.closeSocket()
        }
        DispatchQueue.main.async {
            self.clientCount = 0
            self.isListening = false
        }
    }

    func broadcast(_ event: DaemonEvent) {
        guard let data = try? encoder.encode(event),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let snapshot = clients
        lock.unlock()
        for (_, client) in snapshot where EventSubscriptions.wants(client.subscribedEvents, event: event.event) {
            sendWebSocketText(text, to: client)
        }
    }

    // MARK: - Accept

    private func acceptConnection() {
        var clientAddr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        guard PrivateLocalEndpoint.preventInheritance(clientFd) else { close(clientFd); return }
        guard socketPath == nil || PrivateLocalEndpoint.sameUser(clientFd), handshakeSlots.wait(timeout: .now()) == .success else {
            close(clientFd); return
        }

        // A client can disconnect immediately after a large response. On Darwin,
        // writing to that socket can otherwise raise SIGPIPE and terminate the app.
        var noSigPipe: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let id = UUID()
        let client = WebSocketClient(id: id, fd: clientFd)

        let acceptedGeneration = generation
        let token = authToken
        let admissionPort = socketPath == nil ? listeningPort : nil
        // Read the HTTP upgrade request
        handshakeQueue.async { [weak self] in
            guard let self else { close(clientFd); return }
            defer { self.handshakeSlots.signal() }
            self.performHandshake(client: client, token: token, port: admissionPort, generation: acceptedGeneration)
        }
    }

    // MARK: - WebSocket Handshake

    private func performHandshake(client: WebSocketClient, token: String, port: UInt16?, generation: UUID) {
        let diag = DiagnosticLog.shared

        // Ensure blocking mode for handshake read
        let curFlags = fcntl(client.fd, F_GETFL)
        if curFlags & O_NONBLOCK != 0 {
            _ = fcntl(client.fd, F_SETFL, curFlags & ~O_NONBLOCK)
        }

        // Bound admission time and bytes. Slow or fragmented clients cannot
        // stall the serial RPC queue or cause an unbounded header allocation.
        let deadline = Date().addingTimeInterval(2)
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 8192 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { close(client.fd); return }
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: min(1024, 8192 - data.count))
            let count = read(client.fd, &bytes, bytes.count)
            guard count > 0 else { close(client.fd); return }
            data.append(contentsOf: bytes.prefix(count))
        }
        let request = String(data: data, encoding: .utf8) ?? ""
        guard DaemonAdmission.allows(request, token: token, port: port) else {
            let denial = Array("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            denial.withUnsafeBytes { _ = write(client.fd, $0.baseAddress, $0.count) }
            close(client.fd); return
        }

        // Extract Sec-WebSocket-Key
        guard let keyLine = request.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }) else {
            close(client.fd)
            return
        }
        let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)

        // Compute accept key: Base64(SHA1(key + magic))
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let acceptKey = sha1Base64(combined)

        // Send HTTP 101 response
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        guard client.writeRaw(Data(response.utf8)) else {
            client.closeSocket()
            return
        }

        client.speechAuthorized = SpeechCompanionConnection.authorizes(handshake: request, tokenFile: speechCapabilityURL)
        client.caller = CaptureCaller.parse(handshake: request)

        // Admission runs off the serial queue; recheck the lifecycle before
        // registering, so a late handshake cannot survive stop/restart.
        queue.async {
            guard self.serverFd >= 0, self.generation == generation else { close(client.fd); return }
            self.lock.lock()
            self.clients[client.id] = client
            let count = self.clients.count
            self.lock.unlock()
            DispatchQueue.main.async { self.clientCount = count }
            diag.info("DaemonServer: client connected (\(count) total)")
            self.readLoop(client: client)
        }
    }

    // MARK: - WebSocket Frame I/O

    private func readLoop(client: WebSocketClient) {
        // Make non-blocking and use a dispatch source
        let flags = fcntl(client.fd, F_GETFL)
        _ = fcntl(client.fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: client.fd, queue: queue)
        client.readSource = source
        source.setEventHandler { [weak self] in
            self?.readFrame(client: client)
        }
        source.setCancelHandler { [weak self] in
            self?.removeClient(client)
        }
        source.resume()
    }

    private func readFrame(client: WebSocketClient) {
        // Read available data into client buffer
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(client.fd, &buf, buf.count)
        if n < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return }
        if n <= 0 {
            client.readSource?.cancel()
            return
        }
        guard client.buffer.count + n <= 16 * 1024 * 1024 else { client.readSource?.cancel(); return }
        client.buffer.append(contentsOf: buf[..<n])

        // Process complete frames
        while let frame = parseFrame(&client.buffer) {
            switch frame.opcode {
            case 0x1: // Text
                if let text = String(bytes: frame.payload, encoding: .utf8),
                   let data = text.data(using: .utf8) {
                    handleMessage(data, client: client)
                }
            case 0x8: // Close
                // Send close frame back
                sendFrame(opcode: 0x8, payload: [], to: client)
                client.readSource?.cancel()
                return
            case 0x9: // Ping → Pong
                sendFrame(opcode: 0xA, payload: frame.payload, to: client)
            case 0xA: // Pong — ignore
                break
            default:
                break
            }
        }
    }

    private struct WSFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private func parseFrame(_ buffer: inout [UInt8]) -> WSFrame? {
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[0]
        let byte1 = buffer[1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = UInt64(byte1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLen = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            offset = 4
        } else if payloadLen == 127 {
            guard buffer.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | UInt64(buffer[2 + i]) }
            offset = 10
        }

        guard payloadLen <= 16 * 1024 * 1024, masked, byte0 & 0x70 == 0, byte0 & 0x80 != 0, [1, 8, 9, 10].contains(opcode), (opcode < 8 || payloadLen <= 125) else {
            // Return a close frame for malformed or oversized input without
            // converting an attacker-controlled UInt64 to Int.
            buffer.removeAll(); return WSFrame(opcode: 0x8, payload: [])
        }
        let maskSize = masked ? 4 : 0
        let totalNeeded = offset + maskSize + Int(payloadLen)
        guard buffer.count >= totalNeeded else { return nil }

        var payload: [UInt8]
        if masked {
            let mask = Array(buffer[offset..<(offset + 4)])
            let dataStart = offset + 4
            payload = Array(buffer[dataStart..<(dataStart + Int(payloadLen))])
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        } else {
            payload = Array(buffer[offset..<(offset + Int(payloadLen))])
        }

        buffer.removeFirst(totalNeeded)
        return WSFrame(opcode: opcode, payload: payload)
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8], to client: WebSocketClient) {
        client.send(opcode: opcode, payload: Data(payload))
    }

    private func sendWebSocketText(_ text: String, to client: WebSocketClient) {
        client.send(opcode: 0x1, payload: Data(text.utf8))
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data, client: WebSocketClient) {
        guard let request = try? decoder.decode(DaemonRequest.self, from: data) else {
            let errResponse = DaemonResponse(id: "?", result: nil, error: "Invalid request JSON")
            sendResponse(errResponse, to: client)
            return
        }

        if EventSubscriptions.methods.contains(request.method) {
            client.subscribedEvents = EventSubscriptions.apply(
                method: request.method,
                params: request.params,
                to: client.subscribedEvents
            )
            sendResponse(
                DaemonResponse(id: request.id, result: EventSubscriptions.result(client.subscribedEvents), error: nil),
                to: client
            )
            return
        }

        if request.method == "voice.status" {
            handleVoiceStatus(request, client: client)
            return
        }

        if VoiceHelperRouting.isHelperVerb(request.method) {
            handleVoiceHelperVerb(request, client: client)
            return
        }

        // These handlers can sleep or wait for the user. Keep them off the
        // serial socket queue so other clients, events, and RPCs still flow.
        let context = DaemonContext(connection: client)
        if Self.blockingMethods.contains(MethodAliases.canonical(request.method)) {
            blockingRequestQueue.async { [weak self] in
                let response = context.run { LatticesApi.shared.handle(request) }
                self?.queue.async { [weak self] in
                    defer { context.replied() }
                    guard let self, self.isConnected(client) else { return }
                    self.sendResponse(response, to: client)
                }
            }
            return
        }

        let response = context.run { LatticesApi.shared.handle(request) }
        sendResponse(response, to: client)
        context.replied()
        if CaptureAudit.methods.contains(request.method), response.error == nil {
            CaptureAudit.record(method: request.method, caller: client.caller, result: response.result)
        }
    }

    // MARK: - Voice helper routing (LAT-012)

    /// `voice.*` output verbs and direct `speech.*` calls go to the Voice
    /// helper. Only clients that presented the helper capability may use them.
    private func handleVoiceHelperVerb(_ request: DaemonRequest, client: WebSocketClient) {
        guard client.speechAuthorized else {
            let error = request.method == "voice.stop" && AudioLayer.shared.isListening
                ? VoiceHelperRouting.stopListeningHintError
                : voiceUnavailableError(installed: VoiceHelperRouting.isInstalled())
            sendResponse(DaemonResponse(id: request.id, result: nil, error: error), to: client)
            return
        }

        if request.method == VoiceHelperRouting.releaseMethod {
            let connection = client.speechConnection
            client.speechConnection = nil
            Task { [weak self, weak client] in
                let released = await connection?.release() ?? false
                self?.queue.async { [weak self, weak client] in
                    guard let self, let client, self.isConnected(client) else { return }
                    self.sendResponse(DaemonResponse(id: request.id, result: .object([
                        "ok": .bool(true),
                        "released": .bool(released),
                    ]), error: nil), to: client)
                }
            }
            return
        }

        guard let helperMethod = VoiceHelperRouting.helperMethod(for: request.method) else { return }
        let forwarded = VoiceHelperRouting.renamed(request, to: helperMethod)

        // One-release hint: voice.stop used to stop listening. When the daemon
        // is listening and Voice is not speaking, point at voice.stopListening
        // instead of silently stopping nothing.
        if request.method == "voice.stop", AudioLayer.shared.isListening {
            callHelper("speech.status", client: client) { [weak self] status in
                guard let self else { return }
                if status.error == nil, VoiceHelperRouting.isSpeaking(status.result) {
                    self.forwardToHelper(forwarded, client: client)
                } else {
                    self.sendResponse(DaemonResponse(id: request.id, result: nil, error: VoiceHelperRouting.stopListeningHintError), to: client)
                }
            }
            return
        }

        forwardToHelper(forwarded, client: client)
    }

    /// `voice.status`: the daemon's listening state plus the Voice helper's
    /// `speech.status`, or why the helper could not be asked.
    private func handleVoiceStatus(_ request: DaemonRequest, client: WebSocketClient) {
        let base = LatticesApi.shared.handle(request)
        guard base.error == nil, case .object(var object)? = base.result else {
            sendResponse(base, to: client)
            return
        }
        let finish: (JSON) -> Void = { [weak self] helper in
            guard let self else { return }
            object["helper"] = helper
            self.sendResponse(DaemonResponse(id: request.id, result: .object(object), error: nil), to: client)
        }
        guard client.speechAuthorized else {
            let installed = VoiceHelperRouting.isInstalled()
            finish(VoiceHelperRouting.helperStatus(
                installed: installed,
                authorized: false,
                status: nil,
                error: voiceUnavailableError(installed: installed)
            ))
            return
        }
        callHelper("speech.status", client: client) { status in
            if status.error == nil {
                finish(VoiceHelperRouting.helperStatus(installed: true, authorized: true, status: status.result ?? .null, error: nil))
            } else {
                let error = status.error ?? VoiceHelperRouting.unreachableError
                let installed = error == VoiceHelperRouting.notInstalledError ? false : VoiceHelperRouting.isInstalled()
                finish(VoiceHelperRouting.helperStatus(installed: installed, authorized: true, status: nil, error: error))
            }
        }
    }

    /// Why a client without the helper capability can't use Voice.
    private func voiceUnavailableError(installed: Bool) -> String {
        VoiceHelperRouting.unauthorizedReason(
            capabilityPresent: FileManager.default.fileExists(atPath: speechCapabilityURL.path),
            installed: installed
        )
    }

    private func helperConnection(for client: WebSocketClient) -> SpeechCompanionConnection {
        if let connection = client.speechConnection { return connection }
        // A nil endpoint selects Speech's private socket and transport token.
        // The legacy capability is only for an explicitly supplied TCP endpoint.
        let connection = SpeechCompanionConnection(endpoint: speechEndpoint, tokenFile: speechEndpoint == nil ? nil : speechCapabilityURL, response: { [weak self, weak client] result in
            self?.queue.async { [weak self, weak client] in
                guard let self, let client, self.isConnected(client) else { return }
                if result.id.hasPrefix(VoiceHelperRouting.internalIdPrefix) {
                    client.helperCallbacks.removeValue(forKey: result.id)?(self.mappedHelperResponse(result))
                    return
                }
                self.sendResponse(self.mappedHelperResponse(result), to: client)
            }
        }, event: { [weak self, weak client] update in
            self?.queue.async { [weak self, weak client] in
                guard let self, let client, self.isConnected(client) else { return }
                for event in VoiceHelperRouting.clientEvents(for: update) {
                    guard let data = try? self.encoder.encode(event), let text = String(data: data, encoding: .utf8) else { continue }
                    self.sendWebSocketText(text, to: client)
                }
            }
        })
        client.speechConnection = connection
        return connection
    }

    /// A helper connection failure means Voice is missing or not running.
    private func mappedHelperResponse(_ response: DaemonResponse) -> DaemonResponse {
        guard response.error == VoiceHelperRouting.unreachableError, !VoiceHelperRouting.isInstalled() else { return response }
        return DaemonResponse(id: response.id, result: nil, error: VoiceHelperRouting.notInstalledError)
    }

    private func forwardToHelper(_ request: DaemonRequest, client: WebSocketClient) {
        let connection = helperConnection(for: client)
        Task { await connection.forward(request) }
    }

    /// Ask the helper something on the daemon's behalf. The reply comes back on
    /// `queue`; after 2 s the call fails as unreachable.
    private func callHelper(_ method: String, client: WebSocketClient, completion: @escaping (DaemonResponse) -> Void) {
        let id = VoiceHelperRouting.internalIdPrefix + UUID().uuidString
        client.helperCallbacks[id] = completion
        forwardToHelper(DaemonRequest(id: id, method: method, params: nil), client: client)
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak client] in
            guard let self, let client, let callback = client.helperCallbacks.removeValue(forKey: id) else { return }
            callback(self.mappedHelperResponse(DaemonResponse(id: id, result: nil, error: VoiceHelperRouting.unreachableError)))
        }
    }

    private func isConnected(_ client: WebSocketClient) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clients[client.id] === client
    }

    private func sendResponse(_ response: DaemonResponse, to client: WebSocketClient) {
        guard let data = try? encoder.encode(response),
              let text = String(data: data, encoding: .utf8) else { return }
        sendWebSocketText(text, to: client)
    }

    // MARK: - Client Management

    private func removeClient(_ client: WebSocketClient) {
        let speech = client.speechConnection
        Task { await speech?.close() }
        client.closeSocket()
        lock.lock()
        if clients[client.id] === client { clients.removeValue(forKey: client.id) }
        let count = clients.count
        lock.unlock()
        DispatchQueue.main.async { self.clientCount = count }
        DiagnosticLog.shared.info("DaemonServer: client disconnected (\(count) total)")
    }

    // MARK: - Crypto Helper

    private func sha1Base64(_ string: String) -> String {
        let data = Array(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &hash)
        return Data(hash).base64EncodedString()
    }

    // MARK: - Event Broadcasting

    private func broadcastEvent(_ event: ModelEvent) {
        let daemonEvent: DaemonEvent
        switch event {
        case .windowsChanged(let windows, let added, let removed):
            daemonEvent = DaemonEvent(
                event: "windows.changed",
                data: .object([
                    "windowCount": .int(windows.count),
                    "added": .array(added.map { .int(Int($0)) }),
                    "removed": .array(removed.map { .int(Int($0)) })
                ])
            )
        case .tmuxChanged(let sessions):
            daemonEvent = DaemonEvent(
                event: "tmux.changed",
                data: .object([
                    "sessionCount": .int(sessions.count),
                    "sessions": .array(sessions.map { .string($0.name) })
                ])
            )
        case .layerSwitched(let index):
            daemonEvent = DaemonEvent(
                event: "layer.switched",
                data: .object(["index": .int(index)])
            )
        case .processesChanged(let interesting):
            daemonEvent = DaemonEvent(
                event: "processes.changed",
                data: .object([
                    "interestingCount": .int(interesting.count),
                    "pids": .array(interesting.map { .int($0) })
                ])
            )
        case .ocrScanComplete(let windowCount, let totalBlocks):
            daemonEvent = DaemonEvent(
                event: "ocr.scanComplete",
                data: .object([
                    "windowCount": .int(windowCount),
                    "totalBlocks": .int(totalBlocks)
                ])
            )
        case .voiceCommand(let text, let confidence):
            daemonEvent = DaemonEvent(
                event: "voice.command",
                data: .object([
                    "text": .string(text),
                    "confidence": .double(confidence)
                ])
            )
        }
        broadcast(daemonEvent)
    }
}

// MARK: - Client State

/// The socket a request arrived on. Safe from any thread: writes are
/// serialized per connection, so encoders can push without the daemon queue.
protocol DaemonConnection: AnyObject {
    var connectionID: UUID { get }
    var isOpen: Bool { get }
    /// False once the connection is gone; a failed write closes it.
    @discardableResult func sendBinary(_ data: Data) -> Bool
    @discardableResult func sendEvent(_ event: DaemonEvent) -> Bool
    /// Runs once, off the caller's thread, when the connection closes (at once if it already has).
    func onClose(_ handler: @escaping () -> Void)
}

/// Per-request state handlers can reach while they run on the daemon's
/// queues: who called, and work to do once the reply is on the wire.
final class DaemonContext {
    let connection: DaemonConnection
    private let lock = NSLock()
    private var afterReplyHandlers: [() -> Void] = []
    private var didReply = false
    private static let key = "lattices.daemon.context"

    init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The request being handled on this thread, nil for in-process dispatch.
    static var current: DaemonContext? {
        Thread.current.threadDictionary[key] as? DaemonContext
    }

    func run<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.key]
        dictionary[Self.key] = self
        defer { dictionary[Self.key] = previous }
        return try body()
    }

    /// After the response is written, or now when there is no request.
    static func afterReply(_ handler: @escaping () -> Void) {
        guard let context = current else {
            DispatchQueue.global(qos: .userInitiated).async(execute: handler)
            return
        }
        context.lock.lock()
        if context.didReply {
            context.lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async(execute: handler)
            return
        }
        context.afterReplyHandlers.append(handler)
        context.lock.unlock()
    }

    func replied() {
        lock.lock()
        didReply = true
        let handlers = afterReplyHandlers
        afterReplyHandlers = []
        lock.unlock()
        handlers.forEach { $0() }
    }
}

final class WebSocketClient: DaemonConnection {
    var speechAuthorized = false
    var caller: CaptureCaller?
    var speechConnection: SpeechCompanionConnection?
    /// Replies to requests the daemon sent the Voice helper itself. Touched only on the daemon queue.
    var helperCallbacks: [String: (DaemonResponse) -> Void] = [:]
    /// Events this client asked for (`events.subscribe`); nil means all. Read from
    /// the broadcast path and written on the daemon queue, so it is locked.
    var subscribedEvents: Set<String>? {
        get { subscriptionLock.lock(); defer { subscriptionLock.unlock() }; return _subscribedEvents }
        set { subscriptionLock.lock(); _subscribedEvents = newValue; subscriptionLock.unlock() }
    }
    private var _subscribedEvents: Set<String>?
    private let subscriptionLock = NSLock()
    let id: UUID
    let fd: Int32
    var buffer: [UInt8] = []
    var readSource: DispatchSourceRead?

    /// Guards the fd for writes and close, so whole frames from any thread
    /// never interleave and nothing writes to a reused descriptor.
    private let writeLock = NSLock()
    private var closed = false
    private var closeHandlers: [() -> Void] = []
    /// How long one frame may wait on a full socket before the client is dropped.
    static let writeTimeout: TimeInterval = 2

    init(id: UUID, fd: Int32) {
        self.id = id
        self.fd = fd
    }

    var connectionID: UUID { id }

    var isOpen: Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        return !closed
    }

    @discardableResult
    func sendBinary(_ data: Data) -> Bool { send(opcode: 0x2, payload: data) }

    @discardableResult
    func sendEvent(_ event: DaemonEvent) -> Bool {
        guard let data = try? JSONEncoder().encode(event) else { return false }
        return send(opcode: 0x1, payload: data)
    }

    func onClose(_ handler: @escaping () -> Void) {
        writeLock.lock()
        if closed {
            writeLock.unlock()
            DispatchQueue.global(qos: .userInitiated).async(execute: handler)
            return
        }
        closeHandlers.append(handler)
        writeLock.unlock()
    }

    /// One unfragmented frame. A frame that can't be written whole poisons
    /// the stream, so the socket is shut down and the read source reaps it.
    @discardableResult
    func send(opcode: UInt8, payload: Data) -> Bool {
        let header = Self.frameHeader(opcode: opcode, length: payload.count)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        let deadline = Date().addingTimeInterval(Self.writeTimeout)
        if writeAll(header, deadline: deadline), writeAll(payload, deadline: deadline) { return true }
        shutdown(fd, SHUT_RDWR)
        return false
    }

    /// Bytes outside WebSocket framing (the upgrade response).
    func writeRaw(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return !closed && writeAll(data, deadline: Date().addingTimeInterval(Self.writeTimeout))
    }

    func closeSocket() {
        writeLock.lock()
        guard !closed else { writeLock.unlock(); return }
        closed = true
        close(fd)
        let handlers = closeHandlers
        closeHandlers = []
        writeLock.unlock()
        for handler in handlers { DispatchQueue.global(qos: .userInitiated).async(execute: handler) }
    }

    static func frameHeader(opcode: UInt8, length: Int) -> Data {
        var header = Data([0x80 | opcode])
        if length < 126 {
            header.append(UInt8(length))
        } else if length < 65536 {
            header.append(126)
            header.append(UInt8((length >> 8) & 0xFF))
            header.append(UInt8(length & 0xFF))
        } else {
            header.append(127)
            for i in (0..<8).reversed() { header.append(UInt8((length >> (i * 8)) & 0xFF)) }
        }
        return header
    }

    /// Loops over partial writes; waits out EAGAIN on the non-blocking fd until the deadline.
    private func writeAll(_ data: Data, deadline: Date) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, remaining) < 0, errno != EINTR { return false }
            }
            return true
        }
    }
}
