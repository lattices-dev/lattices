import Foundation
import Darwin

/// A launcher carries only this record's ID. Targets stay in the local store,
/// rather than accepting an application or remote address from an incoming URL.
struct ApplicationShortcut: Codable, Equatable, Identifiable, Sendable {
    struct Destination: Codable, Equatable, Sendable {
        var hostName: String
        var address: String
        var port: UInt16
        var gatewayFingerprint: String
    }

    var id: UUID
    var name: String
    var appName: String
    var bundleIdentifier: String?
    var destination: Destination?
    var opensViewer: Bool

    init(id: UUID = UUID(), name: String, appName: String, bundleIdentifier: String?,
         destination: Destination? = nil, opensViewer: Bool = true) {
        self.id = id
        self.name = name
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.destination = destination
        self.opensViewer = opensViewer
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, appName, bundleIdentifier, destination, opensViewer
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        appName = try values.decode(String.self, forKey: .appName)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        destination = try values.decodeIfPresent(Destination.self, forKey: .destination)
        opensViewer = try values.decodeIfPresent(Bool.self, forKey: .opensViewer) ?? true
        try validate()
    }

    var url: URL { URL(string: "lattices://shortcut/\(id.uuidString.lowercased())")! }

    static func id(from url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "lattices", parts.host == "shortcut",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath
        guard path.count == 37, path.first == "/",
              let id = UUID(uuidString: String(path.dropFirst())),
              path.dropFirst().lowercased() == id.uuidString.lowercased() else { return nil }
        return id
    }

    var suggestedFileName: String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "Application Shortcut" : String(cleaned.prefix(100))
        return base.lowercased().hasSuffix(".app") ? base : base + ".app"
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplicationShortcutError.invalidTarget("Choose an application and a shortcut name.")
        }
        if let destination {
            guard !destination.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !destination.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  destination.port > 0,
                  !destination.gatewayFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ApplicationShortcutError.invalidTarget("Reconnect to this machine before creating its shortcut.")
            }
        }
        if let bundleIdentifier, bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ApplicationShortcutError.invalidTarget("The application identifier is empty.")
        }
    }
}

enum ApplicationShortcutError: LocalizedError {
    case invalidTarget(String)
    case existingDestination
    case invalidApplication
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let message): return message
        case .existingDestination: return "An item already exists at this location. Choose another shortcut name."
        case .invalidApplication: return "The shortcut application could not be created."
        case .toolFailed(let message): return message
        }
    }
}

@MainActor
final class ApplicationShortcutStore {
    static let shared = ApplicationShortcutStore(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lattices/app-shortcuts.json"))

    let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws -> [ApplicationShortcut] {
        // Missing is the only recoverable read failure. Corrupt records must not
        // be silently replaced when the user saves a different shortcut.
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let shortcuts = try JSONDecoder().decode([ApplicationShortcut].self, from: data)
        guard Set(shortcuts.map(\.id)).count == shortcuts.count else {
            throw ApplicationShortcutError.invalidTarget("The shortcut store contains duplicate identifiers.")
        }
        return shortcuts
    }

    func lookup(_ id: UUID) throws -> ApplicationShortcut? {
        try load().first { $0.id == id }
    }

    func save(_ shortcut: ApplicationShortcut) throws {
        try shortcut.validate()
        var shortcuts = try load()
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        try write(shortcuts)
    }

    func remove(_ id: UUID) throws {
        let shortcuts = try load()
        guard shortcuts.contains(where: { $0.id == id }) else { return }
        try write(shortcuts.filter { $0.id != id })
    }

    private func write(_ shortcuts: [ApplicationShortcut]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(shortcuts)
        let temporary = directory.appendingPathComponent(".app-shortcuts-\(UUID().uuidString).json")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0, Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
