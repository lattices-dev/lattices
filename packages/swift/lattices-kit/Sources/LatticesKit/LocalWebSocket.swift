import CryptoKit
import Darwin
import Foundation

/// Private Unix socket locally; URLSession only for an explicitly supplied remote URL.
final class LocalWebSocket: @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private var remote: URLSessionWebSocketTask?
    private var local: UnixWebSocket?
    private var startupError: Error?

    init(endpoint: URL, session: URLSession) { self.endpoint = endpoint; self.session = session }
    func resume() {
        if !endpoint.isFileURL {
            remote = session.webSocketTask(with: endpoint); remote?.resume(); return
        }
        do { local = try UnixWebSocket(endpoint: endpoint) } catch { startupError = error }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if let startupError { throw startupError }
        if let remote { try await remote.send(message); return }
        guard let local else { throw LatticesError.disconnected }
        switch message {
        case .string(let text): try await local.send(Data(text.utf8), opcode: 1)
        case .data(let data): try await local.send(data, opcode: 2)
        @unknown default: throw LatticesError.invalidMessage
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let startupError { throw startupError }
        if let remote { return try await remote.receive() }
        guard let local else { throw LatticesError.disconnected }
        return .data(try await local.receive())
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        remote?.cancel(with: code, reason: reason); local?.cancel()
    }
}

/// Blocking POSIX I/O runs on dedicated queues, never on an actor executor.
/// Keep the descriptor allocated until queued reads/writes finish; shutdown
/// interrupts them without risking a close/reuse race with another descriptor.
private final class UnixWebSocket: @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "lattices.ipc.read")
    private let writeQueue = DispatchQueue(label: "lattices.ipc.write")
    private let ready = DispatchGroup()
    private let stateLock = NSLock()
    private let frameLock = NSLock()
    private var cancelled = false
    private var connectionError: Error?
    private static let maximumMessage = 64 * 1024 * 1024

    init(endpoint: URL) throws {
        var attributes = stat()
        let directory = endpoint.deletingLastPathComponent().path
        guard lstat(directory, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0,
              lstat(endpoint.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFSOCK,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            throw LatticesError.daemonError("Unsafe private IPC endpoint")
        }
        let credential = endpoint.deletingPathExtension().appendingPathExtension("token")
        let tokenFD = open(credential.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard tokenFD >= 0 else { throw LatticesError.daemonError("Lattices local credential is unavailable") }
        defer { Darwin.close(tokenFD) }
        guard fstat(tokenFD, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1, attributes.st_mode & 0o077 == 0,
              attributes.st_size >= 32, attributes.st_size <= 256 else {
            throw LatticesError.daemonError("Unsafe private IPC credential")
        }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(tokenFD, &bytes, bytes.count)
        guard count >= 32 else { throw LatticesError.daemonError("Invalid private IPC credential") }
        let token = String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count >= 32, token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43,47,61,95,45].contains($0) }) else {
            throw LatticesError.daemonError("Invalid private IPC credential")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LatticesError.disconnected }
        // Keep local credentials and connections out of children created by
        // embedding apps through posix_spawn/exec.
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw LatticesError.disconnected
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        ready.enter()
        writeQueue.async {
            defer { self.ready.leave() }
            do { try self.connect(path: endpoint.path, token: token) }
            catch { self.connectionError = error; self.cancel() }
        }
    }

    private func connect(path: String, token: String) throws {
        try checkActive()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LatticesError.daemonError("IPC socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard status == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw LatticesError.disconnected }
        try checkActive()
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try writeAll(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\nx-lattices-token: \(token)\r\n\r\n".utf8))
        var header = Data()
        let deadline = Date().addingTimeInterval(3)
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192, Date() < deadline else { throw LatticesError.invalidResponse }
            header.append(try readExactly(1))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accepts = lines.filter { $0.lowercased().hasPrefix("sec-websocket-accept:") }
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true, accepts.count == 1,
              accepts[0].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == accept else {
            throw LatticesError.daemonError("Lattices authentication handshake rejected")
        }
        // Event subscriptions may legitimately remain idle indefinitely.
        var idleTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idleTimeout, socklen_t(MemoryLayout.size(ofValue: idleTimeout)))
    }

    func send(_ payload: Data, opcode: UInt8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    if let error = self.connectionError { throw error }
                    try self.checkActive(); try self.writeFrame(payload, opcode: opcode)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                self.ready.wait()
                do {
                    if let error = self.connectionError { throw error }
                    try self.checkActive()
                    continuation.resume(returning: try self.readMessage())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func cancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        if !cancelled { cancelled = true; shutdown(fd, SHUT_RDWR) }
    }
    deinit { Darwin.close(fd) }
    private func checkActive() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        if cancelled { throw LatticesError.disconnected }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let read = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw LatticesError.disconnected }
                offset += read
            }
        }
        return data
    }
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw LatticesError.disconnected }
                offset += written
            }
        }
    }
    private func writeFrame(_ payload: Data, opcode: UInt8) throws {
        guard payload.count <= Self.maximumMessage else { throw LatticesError.invalidMessage }
        frameLock.lock(); defer { frameLock.unlock() }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 { frame.append(0x80 | 126); var n = UInt16(payload.count).bigEndian; withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) } }
        else { frame.append(0x80 | 127); var n = UInt64(payload.count).bigEndian; withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) } }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try writeAll(frame)
    }
    private func readMessage() throws -> Data {
        var message = Data()
        var fragmented = false
        while true {
            let header = [UInt8](try readExactly(2))
            let opcode = header[0] & 0x0f, final = header[0] & 0x80 != 0
            guard header[1] & 0x80 == 0, header[0] & 0x70 == 0 else { throw LatticesError.invalidMessage }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 { length = try readExactly(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try readExactly(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            guard length <= UInt64(Self.maximumMessage), UInt64(message.count) + length <= UInt64(Self.maximumMessage) else { throw LatticesError.invalidMessage }
            if opcode >= 8 { guard final, length <= 125 else { throw LatticesError.invalidMessage } }
            let payload = try readExactly(Int(length))
            switch opcode {
            case 8: throw LatticesError.disconnected
            case 9: try writeFrame(payload, opcode: 10); continue
            case 10: continue
            case 0: guard fragmented else { throw LatticesError.invalidMessage }
            case 1, 2: guard !fragmented else { throw LatticesError.invalidMessage }; fragmented = true
            default: throw LatticesError.invalidMessage
            }
            message.append(payload)
            if final { return message }
        }
    }
}
