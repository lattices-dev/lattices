import Darwin
import Foundation

public enum BlinkPrivateIPC {
    static func acquireLock(_ socketURL: URL) throws -> Int32 {
        let fd = open(socketURL.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    /// Creates the last directory privately and rejects symlinks at every component.
    public static func prepareDirectory(_ url: URL) throws {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { throw POSIXError(.EACCES) }
        for (index, part) in parts.enumerated() {
            if mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw POSIXError(.EACCES) }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.ELOOP) }
            close(fd); fd = next
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == geteuid(),
                  info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw POSIXError(.EACCES) }
            if index == parts.count - 1 {
                guard info.st_uid == geteuid(),
                      fchmod(fd, 0o700) == 0 else { throw POSIXError(.EACCES) }
            }
        }
    }

    public static func validateSocket(_ url: URL) throws {
        var parent = stat(); var info = stat()
        guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
              parent.st_uid == geteuid(), parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o077 == 0,
              lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
    }

    public static func sameUserPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    static func address(_ url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        guard url.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in url.path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) } }
        return address
    }

    static func removeStaleSocket(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }; throw POSIXError(.EACCES)
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EACCES) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = try address(url)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result != 0, errno == ECONNREFUSED else { throw POSIXError(.EADDRINUSE) }
        guard unlink(url.path) == 0 else { throw POSIXError(.EACCES) }
    }
}
