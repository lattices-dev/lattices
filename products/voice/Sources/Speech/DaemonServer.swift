import Foundation
import CommonCrypto
import Darwin

// MARK: - POSIX WebSocket Server
// Authenticated WebSocket RPC over a private Unix socket.
// TCP is a deliberate compatibility opt-in, never the default transport.

final class SpeechServer: ObservableObject {
    static let shared = SpeechServer()

    @Published var clientCount: Int = 0
    @Published var isListening: Bool = false

    private let port: UInt16?
    private let socketURL: URL
    private let tokenURL: URL
    private var boundSocketIdentity: (dev_t, ino_t)?
    private let api: SpeechApi
    private let speechQueue: SpeechQueue
    private let capabilityURL: URL
    private(set) var listeningPort: UInt16 = 0

    init(port: UInt16? = nil,
         socketURL: URL = SpeechEndpoints.socketURL,
         tokenURL: URL? = nil,
         capabilityURL: URL = SpeechRPCCapability.fileURL,
         api: SpeechApi = .shared,
         speechQueue: SpeechQueue = .shared) {
        self.speechQueue = speechQueue
        self.api = api
        self.port = port
        self.capabilityURL = capabilityURL
        self.socketURL = socketURL
        self.tokenURL = tokenURL ?? (port == nil ? SpeechEndpoints.tokenURL : capabilityURL.deletingLastPathComponent().appendingPathComponent("speech.token"))
    }

    private var serverFd: Int32 = -1
    private var lockFD: Int32 = -1
    private var clients: [UUID: WebSocketClient] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lattices.daemon", qos: .userInitiated)
    private let blockingRequestQueue = DispatchQueue(
        label: "lattices.daemon.blocking-requests",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let blockingMethods: Set<String> = [
        "window.pick.start",
        "session.launch",
    ]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var speechCapability: SpeechRPCCapability?
    private var transportCapability: SpeechRPCCapability?
    private var extraTCPSource: DispatchSourceRead?
    private var acceptSource: DispatchSourceRead?

    func start() {
        let diag = DiagnosticLog.shared
        guard serverFd < 0 else { return }

        do {
            // Fail closed before opening either listener if private state is unsafe.
            if port == nil {
                try SpeechPrivateIPC.prepareDirectory(socketURL.deletingLastPathComponent())
                lockFD = try SpeechPrivateIPC.acquireLock(socketURL)
                // Check for another live helper before rotating its capabilities.
                try SpeechPrivateIPC.removeStaleSocket(socketURL)
            }
            speechCapability = try SpeechRPCCapability(url: capabilityURL)
            transportCapability = try SpeechRPCCapability(url: tokenURL, header: "x-lattices-token")
            serverFd = try makeListener(tcpPort: port)
            acceptSource = acceptSource(for: serverFd, isUnix: port == nil)
            if port == nil, ProcessInfo.processInfo.environment["LATTICES_SPEECH_TCP"] == "1" {
                let tcp = try makeListener(tcpPort: SpeechEndpoints.rpcPort)
                extraTCPSource = acceptSource(for: tcp, isUnix: false)
            }
            DispatchQueue.main.async { self.isListening = true }
            diag.info(port == nil ? "Speech server listening on private IPC" : "Speech compatibility server listening on loopback")
        } catch {
            diag.error("SpeechServer: private listener unavailable: \(error.localizedDescription)")
            stop()
        }
    }

    private func makeListener(tcpPort: UInt16?) throws -> Int32 {
        let fd = socket(tcpPort == nil ? AF_UNIX : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
            if let tcpPort {
                var yes: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EIO) }
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = tcpPort.bigEndian
                addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard result == 0 else { throw POSIXError(.EADDRINUSE) }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
                }
                listeningPort = UInt16(bigEndian: addr.sin_port)
            } else {
                try SpeechPrivateIPC.removeStaleSocket(socketURL)
                var addr = sockaddr_un()
                addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                addr.sun_family = sa_family_t(AF_UNIX)
                guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
                withUnsafeMutableBytes(of: &addr.sun_path) { dest in socketURL.path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0 else { throw POSIXError(.EADDRINUSE) }
                var info = stat()
                guard chmod(socketURL.path, 0o600) == 0, lstat(socketURL.path, &info) == 0,
                      info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
                      info.st_mode & 0o777 == 0o600 else { throw POSIXError(.EACCES) }
                boundSocketIdentity = (info.st_dev, info.st_ino)
            }
            guard listen(fd, 16) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            return fd
        } catch { close(fd); throw error }
    }

    private func acceptSource(for fd: Int32, isUnix: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection(listener: fd, isUnix: isUnix) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            extraTCPSource?.cancel(); extraTCPSource = nil
            serverFd = -1
            listeningPort = 0
            lock.lock()
            let snapshot = Array(clients.values)
            clients.removeAll()
            lock.unlock()
            for client in snapshot { client.handshakeTimeout?.cancel(); client.readSource?.cancel() }
        }
        if let identity = boundSocketIdentity {
            var info = stat()
            if lstat(socketURL.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(socketURL.path) }
            boundSocketIdentity = nil
        }
        speechCapability?.remove(); speechCapability = nil
        transportCapability?.remove(); transportCapability = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        DispatchQueue.main.async { self.clientCount = 0; self.isListening = false }
    }

    func broadcast(_ event: DaemonEvent) {
        guard let data = try? encoder.encode(event),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let snapshot = clients
        lock.unlock()
        for (_, client) in snapshot {
            if !client.speechAuthorized { continue }
            sendWebSocketText(text, to: client)
        }
    }

    // MARK: - Accept

    private func acceptConnection(listener: Int32, isUnix: Bool) {
        let clientFd = accept(listener, nil, nil)
        guard clientFd >= 0 else { return }
        lock.lock(); let atLimit = clients.count >= 64; lock.unlock()
        guard !atLimit, !isUnix || SpeechPrivateIPC.sameUserPeer(clientFd) else { close(clientFd); return }
        var yes: Int32 = 1
        let flags = fcntl(clientFd, F_GETFL)
        guard fcntl(clientFd, F_SETFD, FD_CLOEXEC) == 0,
              flags >= 0, fcntl(clientFd, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(clientFd); return }
        let client = WebSocketClient(id: UUID(), fd: clientFd)
        client.isUnix = isUnix
        lock.lock(); clients[client.id] = client; lock.unlock()
        // Incremental nonblocking handshake: one idle peer cannot stall other clients.
        readLoop(client: client)
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + 3)
        timeout.setEventHandler { [weak client] in client?.readSource?.cancel() }
        client.handshakeTimeout = timeout
        timeout.resume()
    }

    private func performHandshake(client: WebSocketClient) -> Bool {
        guard let end = (client.buffer.count >= 4 ? (0...(client.buffer.count - 4)).first(where: { Array(client.buffer[$0..<($0 + 4)]) == [13, 10, 13, 10] }) : nil) else {
            if client.buffer.count > 8192 { client.readSource?.cancel() }
            return false
        }
        let headerLength = end + 4
        guard headerLength <= 8192, let request = String(bytes: client.buffer.prefix(headerLength), encoding: .utf8) else { client.readSource?.cancel(); return false }
        let lines = request.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { client.readSource?.cancel(); return false }
            let name = String(pair[0]).lowercased()
            guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespaces), headers[name] == nil else { client.readSource?.cancel(); return false }
            headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let hosts: Set<String> = client.isUnix ? ["localhost", "127.0.0.1"] : ["localhost:\(listeningPort)", "127.0.0.1:\(listeningPort)"]
        let authorized = transportCapability?.authorizes(handshake: request) == true || speechCapability?.authorizes(handshake: request) == true
        guard lines.first == "GET / HTTP/1.1", headers["origin"] == nil,
              let host = headers["host"], hosts.contains(host.lowercased()),
              headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13", authorized,
              let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            let denied = Array("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            _ = denied.withUnsafeBytes { write(client.fd, $0.baseAddress!, $0.count) }
            client.readSource?.cancel()
            return false
        }
        let acceptKey = sha1Base64(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        client.buffer.removeFirst(headerLength)
        client.speechAuthorized = true
        client.handshakeTimeout?.cancel(); client.handshakeTimeout = nil
        client.pendingOutput.append(contentsOf: response.utf8)
        flushOutput(client)
        lock.lock(); let count = clients.values.filter(\.speechAuthorized).count; lock.unlock()
        DispatchQueue.main.async { self.clientCount = count }
        return true
    }

    // MARK: - WebSocket Frame I/O

    private func readLoop(client: WebSocketClient) {
        let source = DispatchSource.makeReadSource(fileDescriptor: client.fd, queue: queue)
        client.readSource = source
        source.setEventHandler { [weak self] in
            self?.readFrame(client: client)
        }
        let speechQueue = self.speechQueue
        source.setCancelHandler { [weak self] in
            // Descriptor cleanup must survive the server being released after stop().
            client.handshakeTimeout?.cancel(); client.handshakeTimeout = nil
            client.writeSource?.cancel(); client.writeSource = nil
            client.readSource = nil
            client.pendingOutput.removeAll()
            close(client.fd)
            Task { @MainActor in speechQueue.releaseExternalPlayback(owner: client.id) }
            self?.removeClient(client)
        }
        source.resume()
    }

    private func readFrame(client: WebSocketClient) {
        // Read available data into client buffer
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(client.fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        if n <= 0 {
            client.readSource?.cancel()
            return
        }
        client.buffer.append(contentsOf: buf[..<n])

        if !client.speechAuthorized, !performHandshake(client: client) { return }
        guard client.buffer.count <= 1_048_590 else { client.readSource?.cancel(); return }
        // Validate lengths as UInt64 before any Int conversion or allocation.
        do { while let frame = try parseFrame(&client.buffer) {
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
        } } catch { client.readSource?.cancel() }
    }

    private struct WSFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private func parseFrame(_ buffer: inout [UInt8]) throws -> WSFrame? {
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[0]
        let byte1 = buffer[1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        guard byte0 & 0x80 != 0, byte0 & 0x70 == 0, masked,
              [UInt8(1), 8, 9, 10].contains(opcode) else { throw POSIXError(.EPROTO) }
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

        guard payloadLen <= 1_048_576, opcode < 8 || payloadLen <= 125 else { throw POSIXError(.EMSGSIZE) }
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
        var frame: [UInt8] = [0x80 | opcode] // FIN + opcode

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)

        // All frame writes and pending bytes belong to the socket queue.
        // Nonblocking sockets may accept only a prefix; retain the rest until writable.
        let bytes = frame
        queue.async { [weak self] in
            guard let self, self.isConnected(client) else { return }
            guard client.pendingOutput.count + bytes.count <= 4 * 1024 * 1024 else {
                client.readSource?.cancel()
                return
            }
            client.pendingOutput.append(contentsOf: bytes)
            self.flushOutput(client)
        }
    }

    private func flushOutput(_ client: WebSocketClient) {
        guard isConnected(client) else { return }
        while !client.pendingOutput.isEmpty {
            let written = client.pendingOutput.withUnsafeBytes { bytes in
                write(client.fd, bytes.baseAddress!, bytes.count)
            }
            if written > 0 {
                client.pendingOutput.removeFirst(written)
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if client.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
                    client.writeSource = source
                    source.setEventHandler { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.flushOutput(client)
                    }
                    source.resume()
                }
                return
            }
            client.readSource?.cancel()
            return
        }
        client.writeSource?.cancel()
        client.writeSource = nil
    }

    private func sendWebSocketText(_ text: String, to client: WebSocketClient) {
        let payload = Array(text.utf8)
        sendFrame(opcode: 0x1, payload: payload, to: client)
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data, client: WebSocketClient) {
        guard let request = try? decoder.decode(DaemonRequest.self, from: data) else {
            let errResponse = DaemonResponse(id: "?", result: nil, error: "Invalid request JSON")
            sendResponse(errResponse, to: client)
            return
        }

        if !client.speechAuthorized {
            sendResponse(DaemonResponse(id: request.id, result: nil, error: "Speech access requires the local capability"), to: client)
            return
        }

        // Reservations belong to this connection, not to caller-supplied IDs.
        if request.method == "speech.playback.reserve" {
            do {
                try SpeechRpc.runOnMain { try speechQueue.reserveExternalPlayback(owner: client.id) }
                sendResponse(DaemonResponse(id: request.id, result: .bool(true), error: nil), to: client)
            } catch {
                sendResponse(DaemonResponse(id: request.id, result: nil, error: error.localizedDescription), to: client)
            }
            return
        }

        // These handlers can sleep or wait for the user. Keep them off the
        // serial socket queue so other clients, events, and RPCs still flow.
        if Self.blockingMethods.contains(request.method) {
            blockingRequestQueue.async { [weak self] in
                guard let self else { return }
                let response = self.api.handle(request)
                self.queue.async { [weak self] in
                    guard let self, self.isConnected(client) else { return }
                    self.sendResponse(response, to: client)
                }
            }
            return
        }

        let response = api.handle(request)
        sendResponse(response, to: client)
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
        lock.lock()
        clients.removeValue(forKey: client.id)
        let count = clients.count
        lock.unlock()
        DispatchQueue.main.async { self.clientCount = count }
        DiagnosticLog.shared.info("SpeechServer: client disconnected (\(count) total)")
    }

    // MARK: - Crypto Helper

    private func sha1Base64(_ string: String) -> String {
        let data = Array(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &hash)
        return Data(hash).base64EncodedString()
    }

    // MARK: - Event Broadcasting


}

// MARK: - Client State

final class WebSocketClient {
    let id: UUID
    let fd: Int32
    var speechAuthorized = false
    var isUnix = false
    var handshakeTimeout: DispatchSourceTimer?
    var buffer: [UInt8] = []
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var pendingOutput = Data()

    init(id: UUID, fd: Int32) {
        self.id = id
        self.fd = fd
    }
}
