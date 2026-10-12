import AppKit
import Foundation

/// The other lattices hosts this Mac can see (LAT-013), each with a still of
/// its screen that refreshes when its windows or workspaces change.
///
/// Passive: sockets open only while something is showing the hosts, and a
/// still is taken only when the host says something changed, never on a timer.
@MainActor
final class RemoteHostsModel: ObservableObject {
    static let shared = RemoteHostsModel()

    struct Window: Identifiable, Equatable {
        let id: UInt32
        let app: String
        let title: String
        let space: Int?
        let isFocused: Bool
    }

    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
    }

    struct Host: Identifiable, Equatable {
        let name: String
        let address: String
        let port: UInt16
        var status: Status = .connecting
        var build = MachineBuild([:])
        var platform: String?
        var compositor: String?
        var capabilities: [String] = []
        var windows: [Window] = []
        var monitors: [MachineArrangementStore.Monitor] = []
        var still: NSImage?
        var stillAt: Date?
        /// Round trip of the last still, so a slow link shows itself.
        var stillMilliseconds: Int?
        var liveError: String?

        var id: String { name }
    }

    nonisolated static let hostsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lattices/hosts.json")

    @Published private(set) var hosts: [Host] = []

    private var connections: [String: RemoteHostConnection] = [:]
    private var refreshing: Set<String> = []
    private var dirty: Set<String> = []
    private var viewers = 0

    // MARK: - Lifecycle

    /// Each visible view calls this on appear and `release()` on disappear.
    func retain() {
        viewers += 1
        if viewers == 1 { connectAll() }
    }

    func release() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        dirty.removeAll()
    }

    func reconnect(_ name: String) {
        connections.removeValue(forKey: name)?.cancel()
        connect(name)
    }

    // MARK: - Config

    /// Same sources as `lats hosts`: ~/.lattices/hosts.json, then
    /// LATTICES_HOSTS (`name`, `name:port` or `name=address[:port]`).
    nonisolated static func configuredHosts(
        config: Data? = try? Data(contentsOf: hostsFile),
        env: String? = ProcessInfo.processInfo.environment["LATTICES_HOSTS"]
    ) -> [(name: String, address: String, port: UInt16)] {
        var hosts: [(name: String, address: String, port: UInt16)] = []
        func add(_ name: String, _ address: String, _ port: UInt16) {
            guard name != "local" else { return }
            hosts.removeAll { $0.name == name }
            hosts.append((name, address, port))
        }
        if let config,
           let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
           let entries = root["hosts"] as? [String: Any] {
            for name in entries.keys.sorted() {
                let entry = entries[name] as? [String: Any]
                let port = (entry?["port"] as? Int).flatMap { UInt16(exactly: $0) } ?? 9399
                add(name, entry?["address"] as? String ?? name, port)
            }
        }
        for spec in (env ?? "").split(separator: ",") {
            let trimmed = spec.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts.count == 2 ? parts[0] : String(trimmed.split(separator: ":")[0])
            let target = (parts.count == 2 ? parts[1] : trimmed).split(separator: ":").map(String.init)
            let port = target.count > 1 ? UInt16(target[1]) ?? 9399 : 9399
            add(name, target[0], port)
        }
        return hosts
    }

    // MARK: - Actions

    /// Starts the host's wayvnc and opens it in Screen Sharing.
    func openLive(_ name: String) {
        guard let connection = connections[name] else { return }
        update(name) { $0.liveError = nil }
        Task {
            do {
                let result = try await connection.call("capture.live", timeout: 15) as? [String: Any]
                guard let raw = result?["url"] as? String, let url = URL(string: raw) else {
                    throw RemoteHostConnection.Failure.remote("No live view URL")
                }
                NSWorkspace.shared.open(url)
            } catch {
                update(name) { $0.liveError = error.localizedDescription }
                DiagnosticLog.shared.warn("Hosts: live view on \(name) failed — \(error.localizedDescription)")
            }
        }
    }

    func refresh(_ name: String) {
        guard connections[name] != nil else { return }
        guard !refreshing.contains(name) else {
            dirty.insert(name)
            return
        }
        refreshing.insert(name)
        Task {
            // A terminal retitling itself fires events back to back; take at
            // most one still a second and fold the rest into the next one.
            repeat {
                await load(name)
                if dirty.contains(name) { try? await Task.sleep(for: .seconds(1)) }
            } while dirty.remove(name) != nil && connections[name] != nil
            refreshing.remove(name)
        }
    }

    // MARK: - Private

    func reload() {
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        if viewers > 0 { connectAll() }
    }

    private func connectAll() {
        var configured = Self.configuredHosts()
        for paired in VisitTrust.shared.list() {
            guard let address = VisitTrust.bridgeURL(paired.address)?.host else { continue }
            guard !configured.contains(where: { MachineInventory.key($0.name) == MachineInventory.key(paired.name) || MachineInventory.addressKey($0.address) == MachineInventory.addressKey(address) }) else { continue }
            configured.append((name: paired.name, address: address, port: 9399))
        }
        hosts = configured.map { entry in
            var host = hosts.first { $0.name == entry.name } ?? Host(name: entry.name, address: entry.address, port: entry.port)
            host.status = .connecting
            return host
        }
        for host in hosts { connect(host.name) }
    }

    private func connect(_ name: String) {
        guard viewers > 0, let host = hosts.first(where: { $0.name == name }) else { return }
        update(name) { $0.status = .connecting }
        let connection = RemoteHostConnection(address: host.address, port: host.port)
        connection.onReady = { [weak self] in
            guard let self, self.connections[name] === connection else { return }
            self.update(name) { $0.status = .online }
            Task {
                await self.describe(name)
                _ = try? await connection.call("events.subscribe", params: ["events": ["windows.changed", "spaces.changed"]])
                self.refresh(name)
            }
        }
        connection.onEvent = { [weak self] _ in
            guard let self, self.connections[name] === connection else { return }
            self.refresh(name)
        }
        connection.onClose = { [weak self] reason in
            guard let self, self.connections[name] === connection else { return }
            self.connections.removeValue(forKey: name)
            self.update(name) { $0.status = .offline(reason ?? "Disconnected") }
        }
        connections[name] = connection
        connection.start()
    }

    private func describe(_ name: String) async {
        guard let connection = connections[name],
              let result = try? await connection.call("host.describe") as? [String: Any] else { return }
        let monitors = MachineArrangementStore.parseMonitors(result["displays"])
        MachineArrangementStore.cache(monitors, for: name)
        if let remote = hosts.first(where: { $0.name == name }) {
            for paired in VisitTrust.shared.list() where paired.name.caseInsensitiveCompare(name) == .orderedSame || MachineInventory.addressKey(paired.address) == MachineInventory.addressKey(remote.address) {
                MachineArrangementStore.cache(monitors, for: paired.name)
            }
        }
        VisitController.shared.refreshLayout()
        update(name) {
            $0.monitors = monitors
            $0.build = MachineBuild(result)
            $0.platform = result["platform"] as? String
            $0.compositor = result["compositor"] as? String
            $0.capabilities = (result["capabilities"] as? [String]) ?? []
        }
    }

    private func load(_ name: String) async {
        guard let connection = connections[name] else { return }
        if let list = try? await connection.call("windows.list") as? [[String: Any]],
           connections[name] === connection {
            let windows = list.compactMap { item -> Window? in
                guard let wid = (item["wid"] as? NSNumber)?.uint32Value else { return nil }
                return Window(
                    id: wid,
                    app: item["app"] as? String ?? "",
                    title: item["title"] as? String ?? "",
                    space: (item["spaceIds"] as? [Int])?.first,
                    isFocused: item["isFocused"] as? Bool ?? false
                )
            }
            update(name) { $0.windows = windows }
        }
        guard connections[name] === connection,
              hosts.first(where: { $0.name == name })?.capabilities.contains("capture.still") == true else { return }
        let started = Date()
        do {
            let result = try await connection.call("capture.still", params: ["maxWidth": 1600, "quality": 70], timeout: 15) as? [String: Any]
            guard connections[name] === connection,
                  let encoded = result?["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let image = NSImage(data: data) else { return }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            update(name) {
                $0.still = image
                $0.stillAt = Date()
                $0.stillMilliseconds = elapsed
            }
        } catch {
            DiagnosticLog.shared.warn("Hosts: still from \(name) failed — \(error.localizedDescription)")
        }
    }

    private func update(_ name: String, _ change: (inout Host) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.name == name }) else { return }
        change(&hosts[index])
    }
}
