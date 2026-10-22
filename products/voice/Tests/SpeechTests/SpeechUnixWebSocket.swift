import CommonCrypto
import Darwin
import Foundation
import Security

/// The Voice helper's local client. Runs all descriptor and framing operations
/// on its own queue; no temporary TCP bridge or network listener is involved.
final class SpeechUnixWebSocket: @unchecked Sendable {
    private let path: String
    private let tokenFile: URL
    private let queue = DispatchQueue(label: "dev.lattices.speech.private-client")
    private let receive: @Sendable (Data) -> Void
    private let failed: @Sendable () -> Void
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var timeout: DispatchSourceTimer?
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var input = Data()
    private var output = Data()
    private var expectedAccept = ""
    private var upgraded = false
    private var closed = false

    init(path: String, tokenFile: URL, receive: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) {
        self.path = path; self.tokenFile = tokenFile; self.receive = receive; self.failed = failed
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pendingConnect = continuation
                do { try self.open() } catch { self.finish(error: error) }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, self.upgraded else { continuation.resume(throwing: POSIXError(.ENOTCONN)); return }
                do { try self.frame(data, opcode: 1); continuation.resume() }
                catch { self.finish(error: error); continuation.resume(throwing: error) }
            }
        }
    }

    func close() { queue.async { self.finish(error: nil) } }

    private func open() throws {
        guard !closed else { throw POSIXError(.ENOTCONN) }
        var info = stat(); var parent = stat()
        guard lstat((path as NSString).deletingLastPathComponent, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(), parent.st_mode & 0o077 == 0,
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
        let tokenFD = Darwin.open(tokenFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard tokenFD >= 0 else { throw POSIXError(.EACCES) }
        let token: String
        do {
            defer { Darwin.close(tokenFD) }
            guard fstat(tokenFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
                  info.st_size > 0, info.st_size <= 4096 else { throw POSIXError(.EACCES) }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            guard Darwin.read(tokenFD, &bytes, bytes.count) == bytes.count,
                  let value = String(bytes: bytes, encoding: .utf8), !value.contains("\r"), !value.contains("\n") else { throw POSIXError(.EACCES) }
            token = value
        }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw POSIXError(.EACCES) }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw POSIXError(.EIO) }
        let key = Data(random).base64EncodedString()
        let hashInput = Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(hashInput, CC_LONG(hashInput.count), &digest)
        expectedAccept = Data(digest).base64EncodedString()
        output = Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\nx-lattices-token: \(token)\r\n\r\n".utf8)
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { Darwin.close(descriptor) }
        reader = source; source.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self] in self?.finish(error: POSIXError(.ETIMEDOUT)) }
        timeout = timer; timer.resume()
        flush()
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return }
        guard count > 0 else { finish(error: POSIXError(.ECONNRESET)); return }
        input.append(contentsOf: bytes.prefix(count))
        do {
            if !upgraded {
                guard let range = input.range(of: Data([13, 10, 13, 10])) else {
                    if input.count > 8192 { throw POSIXError(.EMSGSIZE) }; return
                }
                guard range.upperBound <= 8192, let header = String(data: input.prefix(upTo: range.upperBound), encoding: .utf8) else { throw POSIXError(.EPROTO) }
                let lines = header.components(separatedBy: "\r\n")
                var fields: [String: String] = [:]
                for line in lines.dropFirst() where !line.isEmpty {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2 else { throw POSIXError(.EPROTO) }
                    let name = String(pair[0]).lowercased()
                    guard fields[name] == nil else { throw POSIXError(.EPROTO) }
                    fields[name] = pair[1].trimmingCharacters(in: .whitespaces)
                }
                guard lines.first == "HTTP/1.1 101 Switching Protocols", fields["sec-websocket-accept"] == expectedAccept,
                      fields["upgrade"]?.lowercased() == "websocket", fields["connection"]?.lowercased() == "upgrade" else { throw POSIXError(.EACCES) }
                input.removeSubrange(..<range.upperBound)
                upgraded = true; timeout?.cancel(); timeout = nil
                pendingConnect?.resume(); pendingConnect = nil
            }
            guard input.count <= 4_194_318 else { throw POSIXError(.EMSGSIZE) }
            while input.count >= 2 {
                let bytes = [UInt8](input.prefix(10))
                let opcode = bytes[0] & 15
                guard bytes[0] & 0x80 != 0, bytes[0] & 0x70 == 0, bytes[1] & 0x80 == 0 else { throw POSIXError(.EPROTO) }
                var length = UInt64(bytes[1] & 127); var offset = 2
                if length == 126 {
                    guard input.count >= 4 else { return }
                    length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
                } else if length == 127 {
                    guard input.count >= 10 else { return }
                    length = 0
                    for byte in bytes[2..<10] { length = length << 8 | UInt64(byte) }; offset = 10
                }
                guard length <= 4_194_304, opcode < 8 || length <= 125 else { throw POSIXError(.EMSGSIZE) }
                guard input.count >= offset + Int(length) else { return }
                let payload = Data(input.dropFirst(offset).prefix(Int(length)))
                input.removeFirst(offset + Int(length))
                switch opcode {
                case 1: receive(payload)
                case 8: finish(error: POSIXError(.ECONNRESET)); return
                case 9: try frame(payload, opcode: 10)
                case 10: break
                default: throw POSIXError(.EPROTO)
                }
            }
        } catch { finish(error: error) }
    }

    private func frame(_ payload: Data, opcode: UInt8) throws {
        guard payload.count <= 1_048_576, output.count + payload.count + 14 <= 4_194_304 else { throw POSIXError(.EMSGSIZE) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            frame.append(contentsOf: [0xFE, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        } else {
            frame.append(0xFF)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask) == errSecSuccess else { throw POSIXError(.EIO) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        output.append(frame); flush()
    }

    private func flush() {
        guard !closed else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count > 0 { output.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source; source.resume()
                }
                return
            }
            finish(error: POSIXError(.EPIPE)); return
        }
        writer?.cancel(); writer = nil
    }

    private func finish(error: Error?) {
        guard !closed else { return }; closed = true
        timeout?.cancel(); timeout = nil
        writer?.cancel(); writer = nil
        if let reader { reader.cancel(); self.reader = nil } else if fd >= 0 { Darwin.close(fd) }
        fd = -1
        pendingConnect?.resume(throwing: error ?? POSIXError(.ECANCELED)); pendingConnect = nil
        if error != nil { failed() }
    }
}
