import Darwin
import Foundation

/// Key files readable only by this user. A new file is created 0600 before any
/// key bytes reach it and then renamed into place, so the key is never briefly
/// world-readable. Files left looser by older builds are tightened on load.
enum PrivateKeyFile {
    /// Writes `data` to `url` through a 0600 temporary file in the same directory.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let temporary = url.path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlink(temporary) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return written == data.count && fsync(fd) == 0 && rename(temporary, url.path) == 0
    }

    /// Removes group and other access from an existing regular file this user
    /// owns. Returns false when the file is missing or could not be tightened.
    @discardableResult
    static func tighten(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 == 0 { return true }
        return chmod(url.path, 0o600) == 0
    }
}
