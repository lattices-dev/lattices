import Darwin
import Foundation

/// Newline JSON-RPC. Private filesystem access plus an OS-reported peer UID
/// authenticate local callers. This does not sandbox other same-user processes.
public final class BlinkSocketServer: @unchecked Sendable {
    public final class Client: @unchecked Sendable {
        let fd: Int32
        var buffer = Data()
        var output = Data()
        private let subscriptionLock = NSLock()
        private var subscription = false
        public var subscribed: Bool {
            get { subscriptionLock.lock(); defer { subscriptionLock.unlock() }; return subscription }
            set { subscriptionLock.lock(); subscription = newValue; subscriptionLock.unlock() }
        }
        var source: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        init(_ fd: Int32) { self.fd = fd }
    }

    private let path: URL
    private let queue = DispatchQueue(label: "dev.arach.blink.socket")
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var identity: (dev_t, ino_t)?
    private var clients: [Int32: Client] = [:]
    private let handler: @MainActor @Sendable (Data, Client) async -> Void

    public init(path: URL = BlinkPaths.socket(), handler: @escaping @MainActor @Sendable (Data, Client) async -> Void) {
        self.path = path; self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        try BlinkPrivateIPC.prepareDirectory(path.deletingLastPathComponent())
        lockFD = try BlinkPrivateIPC.acquireLock(path)
        var started = false
        defer { if !started { releaseLock() } }
        try BlinkPrivateIPC.removeStaleSocket(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
            var address = try BlinkPrivateIPC.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw POSIXError(.EADDRINUSE) }
            var info = stat()
            guard chmod(path.path, 0o600) == 0, lstat(path.path, &info) == 0,
                  info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_mode & 0o777 == 0o600 else { throw POSIXError(.EACCES) }
            identity = (info.st_dev, info.st_ino)
            guard listen(fd, 16) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(fd) }
            source.setCancelHandler { close(fd) }
            listener = source; source.resume()
            started = true
        } catch { close(fd); removeOwnedSocket(); throw error }
    }

    public func stop() {
        queue.sync {
            for client in clients.values { client.writer?.cancel(); client.source?.cancel() }
            clients.removeAll()
            listener?.cancel(); listener = nil
        }
        removeOwnedSocket()
        releaseLock()
    }

    private func releaseLock() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    private func removeOwnedSocket() {
        guard let identity else { return }
        var info = stat()
        if lstat(path.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(path.path) }
        self.identity = nil
    }

    private func accept(_ listenerFD: Int32) {
        let fd = Darwin.accept(listenerFD, nil, nil); guard fd >= 0 else { return }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              clients.count < 64, BlinkPrivateIPC.sameUserPeer(fd) else { close(fd); return }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { close(fd); return }
        let client = Client(fd)
        clients[fd] = client
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        client.source = source
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(client)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func disconnect(_ client: Client) {
        guard clients[client.fd] === client else { return }
        clients[client.fd] = nil
        client.writer?.cancel(); client.source?.cancel()
    }

    private func read(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(client.fd, &bytes, bytes.count)
        if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return }
        guard count > 0 else { disconnect(client); return }
        client.buffer.append(contentsOf: bytes.prefix(count))
        guard client.buffer.count <= 1_048_576 else { disconnect(client); return }
        while let newline = client.buffer.firstIndex(of: 0x0a) {
            let data = Data(client.buffer.prefix(upTo: newline))
            client.buffer.removeSubrange(...newline)
            Task { @MainActor [handler] in await handler(data, client) }
        }
    }

    public func send(_ object: [String: Any], to client: Client) {
        guard JSONSerialization.isValidJSONObject(object), var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0a)
        let payload = data
        queue.async { [weak self] in
            guard let self, self.clients[client.fd] === client else { return }
            guard client.output.count + payload.count <= 4_194_304 else { self.disconnect(client); return }
            client.output.append(payload); self.flush(client)
        }
    }

    private func flush(_ client: Client) {
        guard clients[client.fd] === client else { return }
        while !client.output.isEmpty {
            let count = client.output.withUnsafeBytes { Darwin.write(client.fd, $0.baseAddress!, $0.count) }
            if count > 0 { client.output.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if client.writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
                    source.setEventHandler { [weak self, weak client] in if let client { self?.flush(client) } }
                    client.writer = source; source.resume()
                }
                return
            }
            disconnect(client); return
        }
        client.writer?.cancel(); client.writer = nil
    }

    public func publish(method: String, params: [String: Any]) {
        // Serialize before entering the sendable queue closure.
        guard let payload = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params]) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.subscribed {
                guard client.output.count + payload.count + 1 <= 4_194_304 else { self.disconnect(client); continue }
                client.output.append(payload); client.output.append(0x0a); self.flush(client)
            }
        }
    }
}
