import Darwin
import Foundation
import Security

public enum ActionPrivateIPC {
    public static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["LATTICES_RUNTIME_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/run", isDirectory: true)
    }
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["ACTION_SOCKET_PATH"] ?? directory.appendingPathComponent("action.sock").path
    }
    public static var tokenFile: URL { directory.appendingPathComponent("action.token") }
    public static var usesTCP: Bool { ProcessInfo.processInfo.environment["ACTION_ALLOW_TCP"] == "1" }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ActionPrivateIPC", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func secureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("Cannot inspect private IPC directory") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw failure("Cannot inspect private IPC directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw failure("Private IPC directory must be owned by the current user and cannot be a symlink") }
        guard chmod(url.path, 0o700) == 0 else { throw failure("Cannot secure private IPC directory") }
    }
    static func readToken(at url: URL) throws -> String {
        var directoryInfo = stat()
        guard lstat(url.deletingLastPathComponent().path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else { throw failure("Action token directory must be private and user-owned") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Action private token is unavailable; start the current Action runtime") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size < 1024 else {
            throw failure("Action token must be a user-owned regular file with mode 0600")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { throw failure("Cannot read Action token") }
        let token = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { throw failure("Invalid Action token") }
        return token
    }
    static func createToken(in root: URL) throws -> (String, URL) {
        try secureDirectory(root)
        let url = root.appendingPathComponent("action.token")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw failure("Cannot create Action token") }
            return (try readToken(at: url), url)
        }
        defer { Darwin.close(fd) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Cannot generate Action token") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let data = Array((token + "\n").utf8)
        guard Darwin.write(fd, data, data.count) == data.count else { throw failure("Cannot write Action token") }
        return (token, url)
    }
    static func authorize(headers: [(name: String, value: String)], authentication: ActionAgentAuthentication, port: UInt16?) -> Bool {
        let grouped = Dictionary(grouping: headers, by: { $0.name.lowercased() })
        guard grouped["origin"] == nil,
              let tokens = grouped["x-lattices-token"], tokens.count == 1,
              authentication.matches(tokens[0].value),
              let hosts = grouped["host"], hosts.count == 1 else { return false }
        let allowed = port.map { ["localhost:\($0)", "127.0.0.1:\($0)", "[::1]:\($0)"] } ?? ["localhost"]
        return allowed.contains(hosts[0].value.lowercased())
    }
}

/// A lifetime lock prevents a second agent from unlinking an active endpoint.
final class ActionPrivateSocketLease {
    private let fd: Int32
    private var ownsEndpoint = false
    let path: String
    init(path: String) throws {
        self.path = path
        try ActionPrivateIPC.secureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        fd = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ActionPrivateIPC.failure("Cannot lock Action socket") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw ActionPrivateIPC.failure("Action socket is already owned by another runtime")
        }
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                Darwin.close(fd)
                throw ActionPrivateIPC.failure("Refusing to replace a non-socket Action endpoint")
            }
            guard unlink(path) == 0 else { Darwin.close(fd); throw ActionPrivateIPC.failure("Cannot remove stale Action socket") }
        }
        ownsEndpoint = true
    }
    deinit { if ownsEndpoint { unlink(path); Darwin.close(fd) } }
}
