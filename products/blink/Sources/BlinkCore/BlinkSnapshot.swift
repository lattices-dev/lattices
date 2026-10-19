import CryptoKit
import Foundation

/// One exact note payload in a coherent peer snapshot. `markdown` includes the
/// complete frontmatter block so foreign metadata survives transport verbatim.
public struct BlinkSnapshotNote: Codable, Equatable, Sendable {
    public var id: String
    public var revision: String
    public var markdown: String
    public var title: String
    public var updatedAt: Date
    public var tags: [String]
    public var pinned: Bool
    public var presentation: NotePresentation

    public init(
        id: String,
        revision: String,
        markdown: String,
        title: String,
        updatedAt: Date,
        tags: [String],
        pinned: Bool,
        presentation: NotePresentation
    ) {
        self.id = id
        self.revision = revision
        self.markdown = markdown
        self.title = title
        self.updatedAt = updatedAt
        self.tags = tags
        self.pinned = pinned
        self.presentation = presentation
    }
}

/// Durable deletion evidence reserved for later incremental replication. Full
/// snapshots remain authoritative today, but recording deletions now avoids an
/// identity and conflict-model migration when writes arrive.
public struct BlinkSnapshotTombstone: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deletedAt: Date
    public var revision: String

    public init(id: String, deletedAt: Date, revision: String) {
        self.id = id
        self.deletedAt = deletedAt
        self.revision = revision
    }
}

/// A file that was deliberately withheld from the snapshot. Quarantine is part
/// of the wire contract so a malformed or identity-divergent note never becomes
/// an accidental deletion on the phone.
public struct BlinkSnapshotIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case unreadable
        case invalidUTF8
        case invalidFrontmatter
        case identityMismatch
    }

    public var code: Code
    public var fileName: String
    public var expectedID: String?
    public var claimedID: String?

    public init(
        code: Code,
        fileName: String,
        expectedID: String? = nil,
        claimedID: String? = nil
    ) {
        self.code = code
        self.fileName = fileName
        self.expectedID = expectedID
        self.claimedID = claimedID
    }
}

/// An authoritative, replace-in-one-step view of Blink's file-backed truth.
/// `etag` excludes `generatedAt`, so an unchanged note corpus produces 304s.
public struct BlinkSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var etag: String
    public var notes: [BlinkSnapshotNote]
    public var tombstones: [BlinkSnapshotTombstone]
    public var issues: [BlinkSnapshotIssue]

    public init(
        version: Int = BlinkSnapshot.currentVersion,
        generatedAt: Date,
        etag: String,
        notes: [BlinkSnapshotNote],
        tombstones: [BlinkSnapshotTombstone],
        issues: [BlinkSnapshotIssue]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.etag = etag
        self.notes = notes
        self.tombstones = tombstones
        self.issues = issues
    }
}

public enum BlinkSnapshotFetchResult: Codable, Equatable, Sendable {
    case notModified(etag: String)
    case snapshot(BlinkSnapshot)
}

/// The iOS surface depends on this app-level boundary, never on a concrete LAN,
/// Tailscale, Noise, TLS, or managed-relay client.
public protocol BlinkPeerTransport: Sendable {
    func fetchSnapshot(ifNoneMatch etag: String?) async throws -> BlinkSnapshotFetchResult
}

public enum BlinkSnapshotBuilderError: Error, LocalizedError, Equatable, Sendable {
    case unstableDirectory(attempts: Int)
    case directoryReadFailed(String)
    case revisionEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unstableDirectory(let attempts):
            return "Canvas notes changed during \(attempts) consecutive snapshot reads."
        case .directoryReadFailed(let detail):
            return "Canvas could not read the notes directory: \(detail)"
        case .revisionEncodingFailed(let detail):
            return "Canvas could not encode the snapshot revision: \(detail)"
        }
    }
}

/// Builds a stable full snapshot by requiring two identical consecutive reads.
/// Atomic note writes guarantee each individual read is untorn; the second pass
/// ensures the directory set did not move underneath the multi-file snapshot.
public struct BlinkSnapshotBuilder: Sendable {
    public let notesDirectory: URL
    public let maxStabilityAttempts: Int
    private let clock: @Sendable () -> Date

    public init(
        notesDirectory: URL,
        maxStabilityAttempts: Int = 4,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notesDirectory = notesDirectory
        self.maxStabilityAttempts = max(2, maxStabilityAttempts)
        self.clock = clock
    }

    public func build(
        tombstones: [BlinkSnapshotTombstone] = []
    ) throws -> BlinkSnapshot {
        var previous: [RawSnapshotFile]?
        var lastReadError: Error?

        for _ in 0..<maxStabilityAttempts {
            do {
                let current = try captureFiles()
                if current == previous {
                    return try makeSnapshot(from: current, tombstones: tombstones)
                }
                previous = current
                lastReadError = nil
            } catch {
                previous = nil
                lastReadError = error
            }
        }

        if let lastReadError {
            throw BlinkSnapshotBuilderError.directoryReadFailed(lastReadError.localizedDescription)
        }
        throw BlinkSnapshotBuilderError.unstableDirectory(attempts: maxStabilityAttempts)
    }

    private func captureFiles() throws -> [RawSnapshotFile] {
        guard FileManager.default.fileExists(atPath: notesDirectory.path) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return entries
            .filter { url in
                let name = url.lastPathComponent
                return name.hasSuffix(".md") && !name.hasPrefix(".")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                RawSnapshotFile(
                    fileName: url.lastPathComponent,
                    data: try? Data(contentsOf: url)
                )
            }
    }

    private func makeSnapshot(
        from files: [RawSnapshotFile],
        tombstones: [BlinkSnapshotTombstone]
    ) throws -> BlinkSnapshot {
        var notes: [BlinkSnapshotNote] = []
        var issues: [BlinkSnapshotIssue] = []

        for file in files {
            let fileID = String(file.fileName.dropLast(3))
            guard let data = file.data else {
                issues.append(
                    BlinkSnapshotIssue(
                        code: .unreadable,
                        fileName: file.fileName,
                        expectedID: fileID
                    )
                )
                continue
            }
            guard let markdown = String(data: data, encoding: .utf8) else {
                issues.append(
                    BlinkSnapshotIssue(
                        code: .invalidUTF8,
                        fileName: file.fileName,
                        expectedID: fileID
                    )
                )
                continue
            }
            guard let note = try? Frontmatter.decode(markdown) else {
                issues.append(
                    BlinkSnapshotIssue(
                        code: .invalidFrontmatter,
                        fileName: file.fileName,
                        expectedID: fileID
                    )
                )
                continue
            }

            guard !fileID.isEmpty, note.id == fileID else {
                issues.append(
                    BlinkSnapshotIssue(
                        code: .identityMismatch,
                        fileName: file.fileName,
                        expectedID: fileID,
                        claimedID: note.id
                    )
                )
                continue
            }

            notes.append(
                BlinkSnapshotNote(
                    id: note.id,
                    revision: Self.sha256Hex(data),
                    markdown: markdown,
                    title: note.title,
                    updatedAt: note.updatedAt,
                    tags: note.tags,
                    pinned: note.pinned,
                    presentation: note.presentation
                )
            )
        }

        notes.sort { $0.id < $1.id }
        issues.sort {
            if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
            return $0.code.rawValue < $1.code.rawValue
        }
        // Any present source file suppresses an older deletion marker, even if
        // that file is temporarily quarantined. Otherwise a failed tombstone
        // cleanup plus a transient parse error could erase the cache's last
        // known-good copy instead of preserving it.
        let presentIDs = Set(notes.map(\.id)).union(issues.compactMap(\.expectedID))
        let visibleTombstones = tombstones
            .filter { !presentIDs.contains($0.id) }
            .sorted {
                if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
                return $0.id < $1.id
            }
        let etag = try Self.snapshotETag(
            notes: notes,
            tombstones: visibleTombstones,
            issues: issues
        )

        return BlinkSnapshot(
            generatedAt: clock(),
            etag: etag,
            notes: notes,
            tombstones: visibleTombstones,
            issues: issues
        )
    }

    private static func snapshotETag(
        notes: [BlinkSnapshotNote],
        tombstones: [BlinkSnapshotTombstone],
        issues: [BlinkSnapshotIssue]
    ) throws -> String {
        let manifest = SnapshotRevisionManifest(
            version: BlinkSnapshot.currentVersion,
            notes: notes.map { SnapshotRevisionNote(id: $0.id, revision: $0.revision) },
            tombstones: tombstones,
            issues: issues
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let digest = sha256Hex(try encoder.encode(manifest))
            return "\"sha256-\(digest)\""
        } catch {
            throw BlinkSnapshotBuilderError.revisionEncodingFailed(error.localizedDescription)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Serializes peer fetches and turns an exact ETag match into an authenticated
/// transport-level not-modified response.
public actor BlinkSnapshotService {
    private let builder: BlinkSnapshotBuilder
    private let tombstoneStore: BlinkTombstoneStore?

    public init(
        builder: BlinkSnapshotBuilder,
        tombstoneStore: BlinkTombstoneStore? = nil
    ) {
        self.builder = builder
        self.tombstoneStore = tombstoneStore
    }

    public func fetchSnapshot(ifNoneMatch etag: String?) async throws -> BlinkSnapshotFetchResult {
        let tombstones = try await tombstoneStore?.all() ?? []
        let snapshot = try builder.build(tombstones: tombstones)
        if etag == snapshot.etag {
            return .notModified(etag: snapshot.etag)
        }
        return .snapshot(snapshot)
    }
}

private struct RawSnapshotFile: Equatable {
    var fileName: String
    var data: Data?
}

private struct SnapshotRevisionNote: Codable {
    var id: String
    var revision: String
}

private struct SnapshotRevisionManifest: Codable {
    var version: Int
    var notes: [SnapshotRevisionNote]
    var tombstones: [BlinkSnapshotTombstone]
    var issues: [BlinkSnapshotIssue]
}
