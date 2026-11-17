import Foundation

/// A remote app kept by name: which app on which host opens as its own window
/// here. One file per definition in ~/.lattices/apps, so an agent can write one
/// as readily as the daemon can.
struct RemoteAppDefinition: Codable, Equatable {
    var id: String
    var host: String
    var app: String
    var name: String
    /// The window's first size; the window remembers its own frame after that.
    var width: Int?
    var height: Int?

    /// "Spotify" on "archie" is spotify-archie.
    static func slug(app: String, host: String) -> String {
        let raw = "\(app)-\(host)".lowercased()
        let parts = raw.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return parts.joined(separator: "-")
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var json: JSON {
        var object: [String: JSON] = ["id": .string(id), "host": .string(host), "app": .string(app), "name": .string(name)]
        if let width, let height { object["width"] = .int(width); object["height"] = .int(height) }
        return .object(object)
    }
}

enum RemoteAppDefinitions {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/apps", isDirectory: true)
    }

    static func all(in directory: URL = directory) -> [RemoteAppDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      var definition = try? JSONDecoder().decode(RemoteAppDefinition.self, from: data) else { return nil }
                // The file name is the id; a hand-edited id inside it doesn't win.
                definition.id = url.deletingPathExtension().lastPathComponent
                return definition
            }
            .sorted { $0.id < $1.id }
    }

    static func get(_ id: String, in directory: URL = directory) -> RemoteAppDefinition? {
        all(in: directory).first { $0.id == id }
    }

    static func save(_ definition: RemoteAppDefinition, in directory: URL = directory) throws {
        guard RemoteAppDefinition.validID(definition.id) else { throw Failure.badID(definition.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: directory.appendingPathComponent("\(definition.id).json"), options: .atomic)
    }

    @discardableResult
    static func remove(_ id: String, in directory: URL = directory) -> Bool {
        guard RemoteAppDefinition.validID(id) else { return false }
        return (try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))) != nil
    }

    enum Failure: LocalizedError {
        case badID(String)
        var errorDescription: String? {
            switch self {
            case .badID(let id): "\"\(id)\" is not a usable id: letters, digits, - and _ only"
            }
        }
    }
}

/// Remote apps this Mac has moved onto a headless display and not yet
/// returned. Written as each opens and closes, so a quit, crash or kill
/// that skips the close can be finished at the next launch.
enum RemoteAppLedger {
    struct Entry: Codable, Equatable {
        let host: String
        let wid: Int
        let display: String
        /// The process that holds it; a live one is still using the display.
        var pid: Int32?
    }

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices/remote-apps-open.json")
    }

    static func entries(at file: URL = file) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func add(_ entry: Entry, at file: URL = file) {
        write(entries(at: file).filter { $0 != entry } + [entry], at: file)
    }

    static func remove(_ entry: Entry, at file: URL = file) {
        write(entries(at: file).filter { $0 != entry }, at: file)
    }

    private static func write(_ entries: [Entry], at file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            }
        } catch {
            DiagnosticLog.shared.warn("RemoteApp: could not write \(file.path): \(error.localizedDescription)")
        }
    }
}
