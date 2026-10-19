import CryptoKit
import Darwin
import Foundation

public enum BlinkTombstoneStoreError: Error, LocalizedError, Equatable, Sendable {
    case decodingFailed(String)
    case encodingFailed(String)
    case lockingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decodingFailed(let detail):
            return "Canvas tombstones could not be decoded: \(detail)"
        case .encodingFailed(let detail):
            return "Canvas tombstones could not be encoded: \(detail)"
        case .lockingFailed(let detail):
            return "Canvas tombstones could not be locked: \(detail)"
        }
    }
}

/// Atomic durable deletion journal. It is intentionally separate from note
/// files because a deleted note can no longer carry its own replication state.
public actor BlinkTombstoneStore {
    private struct FileContents: Codable {
        var version: Int = 1
        var tombstones: [BlinkSnapshotTombstone]
    }

    public let fileURL: URL
    private let clock: @Sendable () -> Date

    public init(
        fileURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.clock = clock
    }

    @discardableResult
    public func recordDeletion(id: String, at date: Date? = nil) throws -> BlinkSnapshotTombstone {
        let deletedAt = date ?? clock()
        let revisionMaterial = Data("\(id)\u{0}\(deletedAt.timeIntervalSince1970)".utf8)
        let revision = SHA256.hash(data: revisionMaterial)
            .map { String(format: "%02x", $0) }
            .joined()
        let tombstone = BlinkSnapshotTombstone(
            id: id,
            deletedAt: deletedAt,
            revision: revision
        )

        try withFileLock(operation: LOCK_EX) {
            var byID = Dictionary(
                try loadUnlocked().map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            byID[id] = tombstone
            try persist(Array(byID.values))
        }
        return tombstone
    }

    public func all() throws -> [BlinkSnapshotTombstone] {
        try withFileLock(operation: LOCK_SH) {
            try loadUnlocked().sorted {
                if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
                return $0.id < $1.id
            }
        }
    }

    public func remove(id: String) throws {
        try withFileLock(operation: LOCK_EX) {
            let remaining = try loadUnlocked().filter { $0.id != id }
            try persist(remaining)
        }
    }

    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> Int {
        try withFileLock(operation: LOCK_EX) {
            let existing = try loadUnlocked()
            let remaining = existing.filter { $0.deletedAt >= cutoff }
            try persist(remaining)
            return existing.count - remaining.count
        }
    }

    private func loadUnlocked() throws -> [BlinkSnapshotTombstone] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(FileContents.self, from: data).tombstones
        } catch {
            throw BlinkTombstoneStoreError.decodingFailed(error.localizedDescription)
        }
    }

    private func withFileLock<T>(
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw BlinkTombstoneStoreError.lockingFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, operation) == 0 else {
            throw BlinkTombstoneStoreError.lockingFailed(String(cString: strerror(errno)))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func persist(_ tombstones: [BlinkSnapshotTombstone]) throws {
        let contents = FileContents(
            tombstones: tombstones.sorted {
                if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
                return $0.id < $1.id
            }
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(contents)
        } catch {
            throw BlinkTombstoneStoreError.encodingFailed(error.localizedDescription)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
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
    }
}
