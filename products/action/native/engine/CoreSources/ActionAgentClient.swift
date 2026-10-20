import CryptoKit
import Darwin
import Foundation

public enum ActionAgentClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Action TCP access requires explicit ACTION_ALLOW_TCP=1 and loopback"
        case .invalidResponse: return "ActionAgent returned an invalid response"
        }
    }
}

private final class ActionSocketConnection: @unchecked Sendable {
    private var descriptor: Int32
    private let lock = NSLock()
    private let token: String
    init(host: String, port: UInt16) throws {
        token = try ActionPrivateIPC.readToken(at: ActionPrivateIPC.tokenFile)
        let tcp = ActionPrivateIPC.usesTCP
        descriptor = socket(tcp ? AF_INET : AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ActionPrivateIPC.failure("Cannot create Action connection") }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        do {
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw ActionPrivateIPC.failure("Cannot protect Action connection descriptor")
            }
            let status: Int32
            if tcp {
                guard ["localhost", "127.0.0.1"].contains(host) else { throw ActionAgentClientError.invalidURL }
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let path = Array(ActionPrivateIPC.socketPath.utf8) + [0]
                guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ActionPrivateIPC.failure("Action socket path is too long") }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                if status == 0 {
                    var uid: uid_t = 0; var gid: gid_t = 0
                    guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { throw ActionPrivateIPC.failure("Action socket peer must be the current user") }
                }
            }
            guard status == 0 else { throw ActionPrivateIPC.failure("Action private runtime is unavailable") }
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let authority = tcp ? "\(host):\(port)" : "localhost"
            try write(Data("GET / HTTP/1.1\r\nHost: \(authority)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\nx-lattices-token: \(token)\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 16_384 else { throw ActionPrivateIPC.failure("Oversized Action handshake") }
                header.append(try read(1))
            }
            let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
                  lines.contains(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") && $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == accept }) else {
                throw ActionPrivateIPC.failure("Action authentication handshake rejected")
            }
            timeout.tv_sec = 120
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        } catch { Darwin.close(descriptor); descriptor = -1; throw error }
    }
    func close() { lock.lock(); defer { lock.unlock() }; if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw ActionPrivateIPC.failure("Action connection write failed") }
                offset += count
            }
        }
    }
    private func read(_ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = Darwin.recv(descriptor, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                guard count > 0 else { throw ActionPrivateIPC.failure("Action connection closed or timed out") }
                offset += count
            }
        }
        return data
    }
    private func frame(_ data: Data, opcode: UInt8 = 1) throws {
        var header = Data([0x80 | opcode])
        if data.count < 126 { header.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65535 { header.append(0x80 | 126); var n = UInt16(data.count).bigEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        else { header.append(0x80 | 127); var n = UInt64(data.count).bigEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        header.append(contentsOf: mask)
        header.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(header)
    }
    func send(_ request: ActionAgentRequest) throws {
        var params = request.params
        params["authToken"] = token; params["protocolVersion"] = "2"
        try frame(JSONEncoder().encode(ActionAgentRequest(id: request.id, method: request.method, params: params)))
    }
    func receive() throws -> ActionAgentResponse {
        var message = Data()
        while true {
            let h = [UInt8](try read(2))
            let opcode = h[0] & 0x0f
            guard h[1] & 0x80 == 0, h[0] & 0x70 == 0 else { throw ActionAgentClientError.invalidResponse }
            var length = UInt64(h[1] & 0x7f)
            if length == 126 { length = try read(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            guard length <= 16_777_216, UInt64(message.count) + length <= 16_777_216 else { throw ActionPrivateIPC.failure("Oversized Action response") }
            let payload = try read(Int(length))
            if opcode == 8 { throw ActionPrivateIPC.failure("Action connection closed") }
            if opcode == 9 { guard length <= 125 else { throw ActionAgentClientError.invalidResponse }; try frame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard opcode == 0 || opcode == 1 || opcode == 2 else { throw ActionAgentClientError.invalidResponse }
            message.append(payload)
            if h[0] & 0x80 != 0 { return try JSONDecoder().decode(ActionAgentResponse.self, from: message) }
        }
    }
}

public final class ActionAgentDispatchHandle: @unchecked Sendable {
    private let connection: ActionSocketConnection
    fileprivate init(connection: ActionSocketConnection) { self.connection = connection }
    public func close() { connection.close() }
    deinit { close() }
}
public actor ActionAgentClient {
    private let host: String
    private let port: UInt16
    public init(host: String = ActionAgentDefaults.host, port: UInt16 = ActionAgentDefaults.port, session: URLSession = .shared) { self.host = host; self.port = port }
    public func send(method: ActionAgentMethod, params: [String: String] = [:]) async throws -> ActionAgentResponse { try await send(request: ActionAgentRequest(method: method.rawValue, params: params)) }
    public func dispatch(method: ActionAgentMethod, params: [String: String] = [:]) async throws { try await dispatch(request: ActionAgentRequest(method: method.rawValue, params: params)) }
    public func open(method: ActionAgentMethod, params: [String: String] = [:]) async throws -> ActionAgentDispatchHandle { try await open(request: ActionAgentRequest(method: method.rawValue, params: params)) }
    public func send(request: ActionAgentRequest) async throws -> ActionAgentResponse {
        let host = host, port = port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { let connection = try ActionSocketConnection(host: host, port: port); defer { connection.close() }; try connection.send(request); continuation.resume(returning: try connection.receive()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func dispatch(request: ActionAgentRequest) async throws { let handle = try await open(request: request); handle.close() }
    public func open(request: ActionAgentRequest) async throws -> ActionAgentDispatchHandle {
        let host = host, port = port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { let connection = try ActionSocketConnection(host: host, port: port); try connection.send(request); continuation.resume(returning: ActionAgentDispatchHandle(connection: connection)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
