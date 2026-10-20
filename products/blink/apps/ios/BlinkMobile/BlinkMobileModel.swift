import BlinkCore
import BlinkPeer
import CryptoKit
import Foundation
import Security
import UIKit

// Keep the persistence boundary injectable so sample-mode tests use disposable
// storage and can hold a cache operation in flight without touching real notes.
protocol BlinkMobileCache: Sendable {
    func loadRecord() async throws -> BlinkSnapshotCacheRecord?
    func apply(_ incoming: BlinkSnapshot, sourceIdentity: String?, syncedAt: Date?) async throws -> BlinkSnapshot
    func recordSuccessfulSync(sourceIdentity: String, at date: Date) async throws -> Bool
    func removeAll() async throws
}

extension BlinkSnapshotCache: BlinkMobileCache {}

@MainActor
final class BlinkMobileModel: ObservableObject {
    enum CacheState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum DiscoveryState: Equatable {
        case searching
        case found
        case noPeers
        case failed(String)
    }

    enum ConnectionState: Equatable {
        case disconnected
        case requestingAccess(String)
        case connected(BlinkPeerHost)

        var host: BlinkPeerHost? {
            guard case .connected(let host) = self else { return nil }
            return host
        }
    }

    @Published private var savedSnapshot: BlinkSnapshot?
    @Published private(set) var isShowingSamples = false
    @Published private(set) var nearbyPeers: [BlinkLANPeerCandidate] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isSyncing = false
    @Published private var savedCacheState: CacheState = .loading
    @Published private var isRemovingOfflineNotes = false
    @Published private var isConnecting = false
    @Published private(set) var discoveryState: DiscoveryState = .searching
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published var presentedError: String?

    private var client: BlinkLANPeerClient?
    private let cache: any BlinkMobileCache
    private let makeClient: () throws -> BlinkLANPeerClient
    private var hasRequestedDiscovery = false
    private var discoveryTask: Task<Void, Never>?
    private var hasLoadedCache = false
    private var discoveryStartedAt = Date()
    private var cacheGeneration = 0
    private var cacheSourceIdentity: String?
    private var connectionGeneration = 0

    init(
        cache: (any BlinkMobileCache)? = nil,
        makeClient: (() throws -> BlinkLANPeerClient)? = nil
    ) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.cache = cache ?? BlinkSnapshotCache(
            fileURL: support
                .appendingPathComponent("Blink", isDirectory: true)
                .appendingPathComponent("snapshot.json", isDirectory: false),
            excludeFromBackup: true
        )
        self.makeClient = makeClient ?? {
            let credential = try BlinkDeviceCredentialSeed.loadOrCreate()
            return BlinkLANPeerClient(
                identity: BlinkPeerClientIdentity(
                    credential: credential,
                    name: BlinkDeviceCredentialSeed.displayName(for: credential)
                )
            )
        }
        activate()
    }

    // Samples are a display overlay, never the source for a cache write or ETag.
    var snapshot: BlinkSnapshot? { isShowingSamples ? BlinkSampleNotes.snapshot : savedSnapshot }
    var cacheState: CacheState { isShowingSamples ? .ready : savedCacheState }
    var savedNoteCount: Int { savedSnapshot?.notes.count ?? 0 }
    var hasSavedSnapshot: Bool { savedSnapshot != nil }
    var savedLastSyncedAt: Date? { lastSuccessfulSyncAt ?? savedSnapshot?.generatedAt }

    var canShowSampleNotes: Bool { !isSyncing && !isConnecting && !isRemovingOfflineNotes }
    var canRemoveOfflineNotes: Bool { !isShowingSamples && !isSyncing && !isRemovingOfflineNotes }

    func showSampleNotes() {
        guard canShowSampleNotes else { return }
        isShowingSamples = true
    }

    func exitSampleNotes() {
        isShowingSamples = false
    }

    var notes: [BlinkSnapshotNote] {
        snapshot?.notes.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        } ?? []
    }

    var lastSyncedAt: Date? { isShowingSamples ? nil : lastSuccessfulSyncAt ?? savedSnapshot?.generatedAt }

    func activate() {
        if !hasLoadedCache {
            hasLoadedCache = true
            cacheGeneration += 1
            let generation = cacheGeneration
            Task { await loadCache(generation: generation) }
        }
        if hasRequestedDiscovery { startDiscovery() }
    }

    /// Opening Connection is the first action that may access identity or LAN.
    func startDiscovery() {
        guard !isShowingSamples else { return }
        hasRequestedDiscovery = true
        guard discoveryTask == nil else { return }
        guard configureClientIfNeeded(), let client else { return }
        discoveryStartedAt = Date()
        discoveryState = .searching
        client.startBrowsing()
        discoveryTask = Task { [weak self, client] in
            while !Task.isCancelled {
                guard let self else { return }
                self.nearbyPeers = client.availablePeers()
                if let failure = client.browsingFailure {
                    self.discoveryState = .failed(failure)
                } else if !self.nearbyPeers.isEmpty {
                    self.discoveryState = .found
                } else if Date().timeIntervalSince(self.discoveryStartedAt) >= 5 {
                    self.discoveryState = .noPeers
                } else {
                    self.discoveryState = .searching
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func deactivate() {
        client?.stopBrowsing()
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func retryDiscovery() {
        guard !isShowingSamples else { return }
        deactivate()
        startDiscovery()
    }

    func connect(to candidate: BlinkLANPeerCandidate) async -> Bool {
        guard !isShowingSamples, !isRemovingOfflineNotes, !isConnecting,
              let client, !isSyncing else { return false }
        isConnecting = true
        defer { isConnecting = false }
        connectionGeneration += 1
        let connection = connectionGeneration
        connectionState = .requestingAccess(candidate.name)
        do {
            let host = try await client.connect(to: candidate.id)
            guard connection == connectionGeneration else {
                client.disconnect()
                return false
            }
            let refreshed = await sync(host: host, connection: connection)
            guard connection == connectionGeneration else { return false }
            guard refreshed else {
                client.disconnect()
                connectionGeneration += 1
                connectionState = .disconnected
                return false
            }
            connectionState = .connected(host)
            return true
        } catch {
            guard connection == connectionGeneration else { return false }
            client.disconnect()
            connectionGeneration += 1
            connectionState = .disconnected
            presentedError = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        guard !isShowingSamples else { return }
        connectionGeneration += 1
        client?.disconnect()
        connectionState = .disconnected
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isShowingSamples, !isRemovingOfflineNotes,
              let host = connectionState.host, !isSyncing else { return false }
        return await sync(host: host, connection: connectionGeneration)
    }

    private func sync(host: BlinkPeerHost, connection: Int) async -> Bool {
        guard !isShowingSamples, !isRemovingOfflineNotes, let client, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        let generation = cacheGeneration
        let sourceIdentity = host.publicKey
        let isSameHost = cacheSourceIdentity == sourceIdentity
        do {
            switch try await client.fetchSnapshot(ifNoneMatch: isSameHost ? savedSnapshot?.etag : nil) {
            case .notModified:
                guard connection == connectionGeneration,
                      client.pairedHost?.publicKey == sourceIdentity
                else { return false }
                let syncedAt = Date()
                guard try await cache.recordSuccessfulSync(
                    sourceIdentity: sourceIdentity,
                    at: syncedAt
                ) else {
                    throw BlinkSnapshotCacheError.decodingFailed(
                        "The peer-bound cache is missing. Sync again to restore it."
                    )
                }
                guard generation == cacheGeneration else { return false }
                lastSuccessfulSyncAt = syncedAt
                return connection == connectionGeneration
                    && client.pairedHost?.publicKey == sourceIdentity
            case .snapshot(let incoming):
                guard connection == connectionGeneration,
                      client.pairedHost?.publicKey == sourceIdentity
                else { return false }
                let syncedAt = Date()
                let cached = try await cache.apply(
                    incoming,
                    sourceIdentity: sourceIdentity,
                    syncedAt: syncedAt
                )
                guard generation == cacheGeneration else { return false }
                savedSnapshot = cached
                cacheSourceIdentity = sourceIdentity
                lastSuccessfulSyncAt = syncedAt
                savedCacheState = .ready
                return connection == connectionGeneration
                    && client.pairedHost?.publicKey == sourceIdentity
            }
        } catch {
            if connection == connectionGeneration {
                presentedError = error.localizedDescription
            }
            if (error as? BlinkPeerError) == .unauthorized {
                disconnect()
            }
            return false
        }
    }

    func clearOfflineNotes() async {
        guard canRemoveOfflineNotes else { return }
        isRemovingOfflineNotes = true
        defer { isRemovingOfflineNotes = false }
        // Removing offline notes is also a connection boundary. Cancelling the
        // live or pending peer operation prevents an automatic refresh from
        // recreating the cache after the person confirms removal.
        disconnect()
        do {
            cacheGeneration += 1
            let generation = cacheGeneration
            try await cache.removeAll()
            guard generation == cacheGeneration else { return }
            savedSnapshot = nil
            cacheSourceIdentity = nil
            lastSuccessfulSyncAt = nil
            savedCacheState = .ready
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func retryCacheLoad() {
        guard !isShowingSamples, !isRemovingOfflineNotes, !isSyncing else { return }
        savedCacheState = .loading
        cacheGeneration += 1
        let generation = cacheGeneration
        Task { await loadCache(generation: generation) }
    }

    private func loadCache(generation: Int) async {
        do {
            let record = try await cache.loadRecord()
            guard generation == cacheGeneration else { return }
            savedSnapshot = record?.snapshot
            cacheSourceIdentity = record?.sourceIdentity
            lastSuccessfulSyncAt = record?.lastSuccessfulSyncAt
            savedCacheState = .ready
        } catch {
            guard generation == cacheGeneration else { return }
            savedCacheState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func configureClientIfNeeded() -> Bool {
        if client != nil { return true }
        do {
            let client = try makeClient()
            client.observeConnection { [weak self] isConnected in
                guard !isConnected else { return }
                Task { @MainActor [weak self] in
                    self?.handleTransportDisconnect()
                }
            }
            self.client = client
            return true
        } catch {
            discoveryState = .failed(
                "Secure device identity is unavailable: \(error.localizedDescription) Unlock Keychain, then try again."
            )
            return false
        }
    }

    private func handleTransportDisconnect() {
        connectionGeneration += 1
        connectionState = .disconnected
    }
}

private enum BlinkDeviceCredentialSeed {
    private static let service = "dev.arach.blink.mobile.peer"
    private static let account = "device-seed"
    private static let legacyDefaultsKey = "blink.peer.device-credential"

    static func loadOrCreate() throws -> String {
        // The old UserDefaults value is intentionally not migrated: defaults
        // can travel in a device backup and clone an already approved identity.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)

        if let saved = try readExisting() { return saved }
        let generated = UUID().uuidString.lowercased()
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(generated.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return generated }
        if status == errSecDuplicateItem, let saved = try readExisting() { return saved }
        throw BlinkDeviceCredentialSeedError.keychain(status)
    }

    @MainActor
    static func displayName(for seed: String) -> String {
        let trimmed = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let base = trimmed.isEmpty ? fallback : trimmed
        let suffix = SHA256.hash(data: Data(seed.utf8)).prefix(2)
            .map { String(format: "%02X", $0) }
            .joined()
        return "\(base) · \(suffix)"
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func readExisting() throws -> String? {
        var item: CFTypeRef?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            if let data = item as? Data,
               let saved = String(data: data, encoding: .utf8),
               UUID(uuidString: saved) != nil {
                return saved.lowercased()
            }
            let deleted = SecItemDelete(baseQuery as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw BlinkDeviceCredentialSeedError.keychain(deleted)
            }
            return nil
        default:
            throw BlinkDeviceCredentialSeedError.keychain(status)
        }
    }
}

private enum BlinkDeviceCredentialSeedError: Error, LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return (SecCopyErrorMessageString(status, nil) as String?)
                ?? "Keychain error \(status)."
        }
    }
}
