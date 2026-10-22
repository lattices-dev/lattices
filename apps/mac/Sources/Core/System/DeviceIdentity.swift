import CryptoKit
import Darwin
import Foundation

/// One identity per machine (docs/security-identity.md). Every lattices role
/// that needs a key uses this one X25519 key: the companion bridge as a server,
/// and gateway pairing and visit as clients. The CLI and gateway read and write
/// the same file (packages/desktop-client/device-identity.ts).
///
///     ~/.lattices/identity/device.json, 0600, in a 0700 directory:
///     {"version":1,"id":"<uuid>","name":"<host>","privateKey":{"kty":"OKP","crv":"X25519","x":"…","d":"…"}}
///
/// The first run adopts a key from the per-role files that came before it,
/// then removes those files.
struct DeviceIdentity {
    let id: String
    let name: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    static let defaultBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices", isDirectory: true)

    /// This machine's identity, loaded or created once per process.
    static let current: Result<DeviceIdentity, Error> = Result { try load() }

    enum Failure: LocalizedError {
        case unsafe(String)
        case malformed(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .unsafe(let path): return "Unsafe device identity: \(path)"
            case .malformed(let path): return "Malformed device identity: \(path)"
            case .io(let detail): return "Cannot write the device identity: \(detail)"
            }
        }
    }

    private struct Stored: Codable {
        struct JWK: Codable {
            var kty: String
            var crv: String
            var x: String
            var d: String
        }
        var version: Int
        var id: String
        var name: String
        var privateKey: JWK
    }

    private static let maxBytes = 64 * 1024

    static func path(base: URL = defaultBase) -> URL {
        base.appendingPathComponent("identity", isDirectory: true).appendingPathComponent("device.json")
    }

    /// The stored identity, or nil when none exists yet. Never creates one.
    static func read(base: URL = defaultBase) throws -> DeviceIdentity? {
        let url = path(base: base)
        guard let data = try readPrivate(url, strict: true) else { return nil }
        return try decode(data, path: url.path)
    }

    /// This machine's identity, created on first use. Creation never replaces
    /// an existing file: it writes a private temporary file and hard-links it
    /// in, so the app and the CLI racing at first launch agree on one key.
    static func load(base: URL = defaultBase) throws -> DeviceIdentity {
        if let existing = try read(base: base) { return existing }
        let url = path(base: base)
        try privateDirectory(url.deletingLastPathComponent())

        let adopted = adoptLegacy(base: base)
        let stored = Stored(version: 1, id: adopted.id, name: adopted.name, privateKey: .init(
            kty: "OKP", crv: "X25519",
            x: base64URL(adopted.key.publicKey.rawRepresentation),
            d: base64URL(adopted.key.rawRepresentation)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(stored)
        data.append(0x0A)

        let temporary = url.path + ".\(getpid()).\(UUID().uuidString)"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { unlink(temporary); throw Failure.io("short write") }
        let linked = link(temporary, url.path) == 0
        let linkError = errno
        // Drop the temporary name first: the identity must have one link.
        unlink(temporary)
        if linked {
            removeLegacyKeys(base: base)
        } else if linkError != EEXIST {
            throw Failure.io(String(cString: strerror(linkError)))
        }
        guard let identity = try read(base: base) else { throw Failure.io("identity vanished") }
        return identity
    }

    // MARK: - Legacy per-role keys

    /// Per-role key files from before the device identity.
    struct LegacyFiles {
        let gatewayKey, gatewayClients, companionKey, hostBridgeKey, client, visitKey: URL

        init(base: URL) {
            gatewayKey = base.appendingPathComponent("gateway/gateway-key.json")
            gatewayClients = base.appendingPathComponent("gateway/gateway-clients.json")
            companionKey = base.appendingPathComponent("companion/bridge.key")
            hostBridgeKey = base.appendingPathComponent("host/bridge-key.json")
            client = base.appendingPathComponent("client.json")
            visitKey = base.appendingPathComponent("visit/device-key")
        }

        var keys: [URL] { [gatewayKey, companionKey, hostBridgeKey, client, visitKey] }
    }

    /// The key, id and name a first run starts from. The gateway key comes
    /// first only when a client has pinned it; then the companion bridge key,
    /// which the iPad and visiting Macs pin.
    static func adoptLegacy(base: URL) -> (key: Curve25519.KeyAgreement.PrivateKey, id: String, name: String, source: String) {
        let files = LegacyFiles(base: base)
        let client = (try? readPrivate(files.client, strict: false)).flatMap { $0 }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let gateway = { keyFromJWK(jsonObject(files.gatewayKey)) }
        let candidates: [(String, () -> Curve25519.KeyAgreement.PrivateKey?)] = [
            ("gateway", { hasGatewayClients(files.gatewayClients) ? gateway() : nil }),
            ("companion", { keyFromRaw(files.companionKey) }),
            ("host-bridge", { keyFromJWK(jsonObject(files.hostBridgeKey)) }),
            ("gateway", gateway),
            ("client", { keyFromJWK(client?["privateKey"]) }),
            ("visit", { keyFromRaw(files.visitKey) }),
        ]
        let id = (client?["id"] as? String).flatMap { validID($0) ? $0 : nil } ?? UUID().uuidString.lowercased()
        let host = ProcessInfo.processInfo.hostName
        let name = (client?["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? (host.hasSuffix(".local") ? String(host.dropLast(6)) : host)
        for (source, load) in candidates {
            if let key = load() { return (key, id, name, source) }
        }
        return (Curve25519.KeyAgreement.PrivateKey(), id, name, "new")
    }

    /// Removes the per-role key files the identity replaced. Never follows a link.
    static func removeLegacyKeys(base: URL) {
        for url in LegacyFiles(base: base).keys {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFREG || type == S_IFLNK { unlink(url.path) }
        }
    }

    // MARK: - Files

    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw Failure.unsafe(url.path)
        }
        chmod(url.path, 0o700)
    }

    /// An owned regular file with one link, or nil when it is absent. Strict
    /// reads also require 0600 and throw; legacy files from older builds may be
    /// looser and are skipped when unsafe.
    private static func readPrivate(_ url: URL, strict: Bool) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || (!strict && errno == ELOOP) { return nil }
            if strict { throw Failure.unsafe(url.path) }
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let safe = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
            && info.st_uid == geteuid() && info.st_size <= maxBytes
        guard safe, !strict || info.st_mode & 0o077 == 0 else {
            if strict { throw Failure.unsafe(url.path) }
            return nil
        }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            if strict { throw Failure.unsafe(url.path) }
            return nil
        }
        return data
    }

    private static func jsonObject(_ url: URL) -> Any? {
        guard let data = (try? readPrivate(url, strict: false)) ?? nil else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func hasGatewayClients(_ url: URL) -> Bool {
        guard let clients = jsonObject(url) as? [Any] else { return false }
        return !clients.isEmpty
    }

    private static func keyFromRaw(_ url: URL) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let data = (try? readPrivate(url, strict: false)) ?? nil, data.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private static func keyFromJWK(_ value: Any?) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let jwk = value as? [String: Any], jwk["kty"] as? String == "OKP", jwk["crv"] as? String == "X25519",
              let d = (jwk["d"] as? String).flatMap(fromBase64URL), d.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d)
    }

    private static func decode(_ data: Data, path: String) throws -> DeviceIdentity {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              validID(stored.id),
              stored.privateKey.kty == "OKP", stored.privateKey.crv == "X25519",
              let d = fromBase64URL(stored.privateKey.d), d.count == 32,
              let x = fromBase64URL(stored.privateKey.x), x.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d),
              key.publicKey.rawRepresentation == x else {
            throw Failure.malformed(path)
        }
        return DeviceIdentity(id: stored.id, name: stored.name, privateKey: key)
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func fromBase64URL(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }
}
