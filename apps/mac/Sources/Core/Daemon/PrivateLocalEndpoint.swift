import Foundation
import Darwin
import Security

/// A per-user endpoint lease. The lock prevents a second process from replacing
/// a live socket or rotating its credential. This is not a same-user sandbox.
final class PrivateLocalEndpoint {
    private var lockFD: Int32 = -1
    private var socketPath: String?
    private var credentialPath: String?

    static func prepareDirectory(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw failure("inspect IPC directory") }
            let parent = (path as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: parent) { try prepareDirectory(parent) }
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw failure("create IPC directory") }
            guard lstat(path, &info) == 0 else { throw failure("inspect IPC directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw failure("IPC directory must be owned by this user with mode 0700")
        }
    }

    /// `lockPath` defaults to the credential path plus `.lock`. Endpoints that
    /// share a credential pass their own lock so their leases stay separate.
    init(socketPath: String?, tokenURL: URL, lockPath: String? = nil) throws {
        let directory = tokenURL.deletingLastPathComponent().path
        try Self.prepareDirectory(directory)
        let lockPath = lockPath ?? tokenURL.path + ".lock"
        guard (lockPath as NSString).deletingLastPathComponent == directory else { throw Self.failure("IPC lock and credential must share a private directory") }
        lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Self.failure("open IPC lock") }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1
            throw Self.failure("IPC endpoint already running or lock is not private")
        }
        // Do not remove files we do not own or follow a symlink.
        if let socketPath {
            guard (socketPath as NSString).deletingLastPathComponent == directory else { throw Self.failure("IPC socket and credential must share a private directory") }
            var existing = stat()
            if lstat(socketPath, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw Self.failure("unsafe existing IPC path") }
                guard unlink(socketPath) == 0 else { throw Self.failure("remove stale IPC socket") }
            } else if errno != ENOENT { throw Self.failure("inspect IPC socket") }
        }
    }

    func bindSocket(_ fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Self.failure("IPC socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw Self.failure("bind IPC socket") }
        socketPath = path
        // The enclosing 0700 directory protects the socket during creation.
        guard chmod(path, 0o600) == 0 else { throw Self.failure("protect IPC socket") }
    }

    /// Write a fresh credential, replacing any previous one atomically.
    /// A shared credential (`removeOnClose: false`) outlives this lease
    /// because other endpoints and processes admit with it.
    func publishToken(at url: URL, removeOnClose: Bool = true) throws -> String {
        let token = try Self.writeToken(at: url, replace: true)
        if removeOnClose { credentialPath = url.path }
        return token
    }

    /// Remove a pre-consolidation per-service credential. Call only while this
    /// lease is held, so no live endpoint still owns the file.
    func removeLegacyToken(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK else { return }
        unlink(url.path)
    }

    private static func writeToken(at url: URL, replace: Bool) throws -> String {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw failure("generate IPC capability") }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let temporary = url.path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create IPC capability") }
        defer { close(fd); unlink(temporary) }
        let data = Array(token.utf8)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count, fsync(fd) == 0 else {
            throw failure("publish IPC capability")
        }
        if replace {
            guard rename(temporary, url.path) == 0 else { throw failure("publish IPC capability") }
        } else {
            // link() never replaces a credential another endpoint published.
            guard link(temporary, url.path) == 0 || errno == EEXIST else { throw failure("publish IPC capability") }
        }
        return token
    }

    /// The current shared credential, created if absent. Endpoints that share
    /// `lattices.token` call this at each admission, so a rotation by any
    /// writer, or a replacement to revoke, applies everywhere at once.
    static func currentToken(at url: URL) throws -> String {
        if let token = try readToken(at: url) { return token }
        try prepareDirectory(url.deletingLastPathComponent().path)
        _ = try writeToken(at: url, replace: false)
        guard let token = try readToken(at: url) else { throw failure("read IPC capability") }
        return token
    }

    /// Nil when the file does not exist. Refuses links and non-private files.
    static func readToken(at url: URL) throws -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("open IPC capability")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 256 else {
            throw failure("IPC capability must be a private, user-owned regular file")
        }
        var bytes = [UInt8](repeating: 0, count: 257)
        let count = read(fd, &bytes, 256)
        guard count > 0 else { throw failure("read IPC capability") }
        let token = String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count >= 32, token.utf8.count <= 256 else { throw failure("invalid IPC capability") }
        return token
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Darwin does not provide SOCK_CLOEXEC/accept4. Apply this immediately
    /// after creating or accepting a socket, before publishing its descriptor.
    static func preventInheritance(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    func closeLease() {
        if let socketPath { unlink(socketPath); self.socketPath = nil }
        if let credentialPath { unlink(credentialPath); self.credentialPath = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    deinit { closeLease() }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LatticesPrivateIPC", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum DaemonAdmission {
    static func allows(_ request: String, token: String, port: UInt16?) -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard lines.first == "GET / HTTP/1.1", request.hasSuffix("\r\n\r\n"), !token.isEmpty else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
            let name = String(fields[0]).lowercased()
            guard headers[name] == nil else { return false }
            headers[name] = fields[1].trimmingCharacters(in: .whitespaces)
        }
        let hosts: Set<String> = port.map { ["127.0.0.1:\($0)", "localhost:\($0)", "[::1]:\($0)"] } ?? ["localhost"]
        guard headers["origin"] == nil, hosts.contains(headers["host"] ?? ""),
              headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13",
              Data(base64Encoded: headers["sec-websocket-key"] ?? "")?.count == 16,
              headers["transfer-encoding"] == nil, headers["content-length"] == nil,
              let supplied = headers["x-lattices-token"], supplied.utf8.count == token.utf8.count else { return false }
        return zip(supplied.utf8, token.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Admission for the private HTTP companion bridge. Device pairing/signatures
/// are still checked by the inner route after this local gateway capability.
enum LocalHTTPAdmission {
    static func allows(_ headers: [String: String], token: String) -> Bool {
        guard !token.isEmpty, headers["host"] == "localhost", headers["origin"] == nil,
              headers["transfer-encoding"] == nil, let supplied = headers["x-lattices-token"],
              supplied.utf8.count == token.utf8.count else { return false }
        return zip(supplied.utf8, token.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
