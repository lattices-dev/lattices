import Foundation

public enum BlinkSnapshotCacheError: Error, LocalizedError, Equatable, Sendable {
    case decodingFailed(String)
    case encodingFailed(String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decodingFailed(let detail):
            return "Canvas's offline notes could not be decoded: \(detail)"
        case .encodingFailed(let detail):
            return "Canvas's offline notes could not be encoded: \(detail)"
        case .persistenceFailed(let detail):
            return "Canvas's offline notes could not be stored safely: \(detail)"
        }
    }
}

/// The snapshot and the authenticated peer identity that produced it are one
/// atomic cache record. Keeping this metadata beside the notes prevents a
/// crash between two separate writes from making one Mac's cache look like
/// another Mac's cache.
public struct BlinkSnapshotCacheRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sourceIdentity: String?
    public var lastSuccessfulSyncAt: Date?
    public var snapshot: BlinkSnapshot

    public init(
        version: Int = BlinkSnapshotCacheRecord.currentVersion,
        sourceIdentity: String?,
        lastSuccessfulSyncAt: Date?,
        snapshot: BlinkSnapshot
    ) {
        self.version = version
        self.sourceIdentity = sourceIdentity
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.snapshot = snapshot
    }
}

/// A replaceable mobile cache for peer snapshots. The server's snapshot is
/// authoritative except for quarantined IDs: when a source file is unreadable
/// or identity-divergent, the last known-good note remains visible until the
/// source recovers or a durable tombstone explicitly deletes it.
public actor BlinkSnapshotCache {
    public let fileURL: URL
    private let excludeFromBackup: Bool

    public init(fileURL: URL, excludeFromBackup: Bool = false) {
        self.fileURL = fileURL
        self.excludeFromBackup = excludeFromBackup
    }

    public func load() throws -> BlinkSnapshot? {
        try loadRecord()?.snapshot
    }

    public func loadRecord() throws -> BlinkSnapshotCacheRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            do {
                try markExcludedFromBackupIfNeeded(fileURL)
            } catch {
                if excludeFromBackup {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                throw error
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let data = try Data(contentsOf: fileURL)
            if let record = try? decoder.decode(BlinkSnapshotCacheRecord.self, from: data) {
                guard record.version == BlinkSnapshotCacheRecord.currentVersion else {
                    throw BlinkSnapshotCacheError.decodingFailed(
                        "Unsupported cache version \(record.version)."
                    )
                }
                return record
            }

            // Before cache records carried a peer identity, the file contained
            // a bare snapshot. Load it once as unbound data; the mobile client
            // will force a full authenticated fetch before reusing it.
            let legacy = try decoder.decode(BlinkSnapshot.self, from: data)
            return BlinkSnapshotCacheRecord(
                sourceIdentity: nil,
                lastSuccessfulSyncAt: nil,
                snapshot: legacy
            )
        } catch {
            if let cacheError = error as? BlinkSnapshotCacheError {
                throw cacheError
            }
            throw BlinkSnapshotCacheError.decodingFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func apply(
        _ incoming: BlinkSnapshot,
        sourceIdentity: String? = nil,
        syncedAt: Date? = nil
    ) throws -> BlinkSnapshot {
        let previousRecord = try loadRecord()
        let previous = previousRecord?.sourceIdentity == sourceIdentity
            ? previousRecord?.snapshot
            : nil
        let deletedIDs = Set(incoming.tombstones.map(\.id))
        let quarantinedIDs = Set(incoming.issues.compactMap(\.expectedID))
        var notesByID = Dictionary(
            incoming.notes.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        if let previous {
            for note in previous.notes
                where quarantinedIDs.contains(note.id)
                    && !deletedIDs.contains(note.id)
                    && notesByID[note.id] == nil {
                notesByID[note.id] = note
            }
        }
        for id in deletedIDs {
            notesByID[id] = nil
        }

        var cached = incoming
        cached.notes = notesByID.values.sorted { $0.id < $1.id }
        try persist(
            BlinkSnapshotCacheRecord(
                sourceIdentity: sourceIdentity,
                lastSuccessfulSyncAt: syncedAt,
                snapshot: cached
            )
        )
        return cached
    }

    /// Record an authenticated not-modified response without splitting the
    /// sync timestamp from its peer-bound snapshot.
    @discardableResult
    public func recordSuccessfulSync(sourceIdentity: String, at date: Date) throws -> Bool {
        guard var record = try loadRecord(), record.sourceIdentity == sourceIdentity else {
            return false
        }
        record.lastSuccessfulSyncAt = date
        try persist(record)
        return true
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func persist(_ record: BlinkSnapshotCacheRecord) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw BlinkSnapshotCacheError.encodingFailed(error.localizedDescription)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        do {
            try markExcludedFromBackupIfNeeded(tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        do {
            try markExcludedFromBackupIfNeeded(fileURL)
        } catch {
            if excludeFromBackup {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw error
        }
    }

    private func markExcludedFromBackupIfNeeded(_ url: URL) throws {
        guard excludeFromBackup else { return }
        do {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        } catch {
            throw BlinkSnapshotCacheError.persistenceFailed(error.localizedDescription)
        }
    }
}
