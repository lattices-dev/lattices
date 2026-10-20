import Foundation
import Security
import Darwin

/// A local, per-daemon capability. Never included in RPC parameters or events.
final class SpeechRPCCapability {
    static let header = "x-lattices-speech-token"
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speech/RPC/capability")
    }
    private let token: String
    private let url: URL
    private let headerName: String

    init(url: URL = SpeechRPCCapability.fileURL, header: String = SpeechRPCCapability.header) throws {
        self.headerName = header
        self.url = url
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        token = Data(bytes).base64EncodedString()
        let directory = url.deletingLastPathComponent()
        try SpeechPrivateIPC.prepareDirectory(directory)
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_uid == geteuid(), existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_nlink == 1 else { throw POSIXError(.EACCES) }
        } else if errno != ENOENT { throw POSIXError(.EACCES) }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd); unlink(temporary.path) }
        let encoded = Array(token.utf8)
        guard encoded.withUnsafeBytes({ write(fd, $0.baseAddress!, $0.count) }) == encoded.count,
              fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    func authorizes(handshake: String) -> Bool {
        let lines = handshake.components(separatedBy: "\r\n")
        var tokens: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "origin" { return false }
            if name == headerName { tokens.append(pair[1].trimmingCharacters(in: .whitespaces)) }
        }
        guard tokens.count == 1 else { return false }
        let supplied = Array(tokens[0].utf8), expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= supplied[index] ^ expected[index] }
        return difference == 0
    }

    func remove() {
        guard (try? String(contentsOf: url, encoding: .utf8)) == token else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
