import AppKit
import Foundation

/// Pure identity merging. Addresses compare without their service ports; names
/// are case insensitive. Connected aliases merge transitively across sources.
enum MachineInventory {
    struct Source {
        var name: String
        var address: String
        var visit: VisitTrust.Host? = nil
        var remote: String? = nil
    }
    struct Machine: Identifiable {
        var sources: [Source]
        var id: String { sources.map { MachineInventory.key($0.name) }.sorted().joined(separator: "|") }
        var name: String { visit?.name ?? sources[0].name }
        var address: String { visit?.address ?? sources[0].address }
        var visit: VisitTrust.Host? { sources.compactMap(\.visit).first }
        var remote: String? { sources.compactMap(\.remote).first }
    }
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func addressKey(_ value: String) -> String {
        let value = key(value)
        let url = URLComponents(string: value.contains("://") ? value : "http://\(value)")
        return (url?.host ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }
    static func merge(_ sources: [Source]) -> [Machine] {
        var groups: [(aliases: Set<String>, sources: [Source])] = []
        for source in sources {
            var aliases = Set([key(source.name), addressKey(source.address)].filter { !$0.isEmpty })
            var members = [source]
            var index = 0
            while index < groups.count {
                if !groups[index].aliases.isDisjoint(with: aliases) {
                    let group = groups.remove(at: index)
                    aliases.formUnion(group.aliases)
                    members += group.sources
                    index = 0
                } else { index += 1 }
            }
            groups.append((aliases, members))
        }
        return groups.map { Machine(sources: $0.sources) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class MachinesModel: ObservableObject {
    @Published var visit = VisitController.Status(armed: false, visiting: nil, hosts: [])
    @Published var screens: [VisitController.Screen] = []
    @Published var reachable: [String: Bool] = [:]
    @Published var builds: [String: MachineBuild] = [:]
    @Published var error: String?
    private var visible = false
    private var generation = 0
    private var probes: [URLSessionDataTask] = []
    private var descriptions: [RemoteHostConnection] = []

    func appear() { visible = true; refresh() }
    func disappear() {
        visible = false
        generation += 1
        probes.forEach { $0.cancel() }
        probes.removeAll()
        descriptions.forEach { $0.cancel() }; descriptions.removeAll()
    }
    func refresh() {
        guard visible else { return }
        generation += 1
        let version = generation
        probes.forEach { $0.cancel() }
        probes.removeAll()
        descriptions.forEach { $0.cancel() }; descriptions.removeAll()
        VisitController.shared.refreshLayout()
        visit = VisitController.shared.status()
        screens = VisitController.screens()
        for host in visit.hosts {
            guard let base = VisitTrust.bridgeURL(host.address) else { reachable[host.name] = false; continue }
            if let address = base.host {
                let connection = RemoteHostConnection(address: address, port: 9399)
                connection.onReady = { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    Task { @MainActor in
                        defer { connection.cancel() }
                        guard let info = try? await connection.call("host.describe", timeout: 3) as? [String: Any],
                              self.visible, self.generation == version else { return }
                        self.builds[host.name] = MachineBuild(info)
                        MachineArrangementStore.cache(MachineArrangementStore.parseMonitors(info["displays"]), for: host.name)
                        VisitController.shared.refreshLayout()
                        self.objectWillChange.send()
                    }
                }
                descriptions.append(connection); connection.start()
                Task { @MainActor [weak connection] in
                    try? await Task.sleep(for: .seconds(4))
                    connection?.cancel()
                }
            }
            let url = base.appendingPathComponent(VisitTrust.healthPath)
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                let online = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                DispatchQueue.main.async {
                    guard let self, self.visible, self.generation == version else { return }
                    self.reachable[host.name] = online
                }
            }
            probes.append(task)
            task.resume()
        }
    }
    func machines(_ hosts: [RemoteHostsModel.Host]) -> [MachineInventory.Machine] {
        MachineInventory.merge(
            visit.hosts.map { .init(name: $0.name, address: $0.address, visit: $0) }
            + hosts.map { .init(name: $0.name, address: $0.address, remote: $0.name) }
        )
    }
    func perform(_ method: String, _ params: JSON? = nil) {
        do { _ = try LatticesApi.shared.dispatch(method: method, params: params); error = nil; refresh() }
        catch { self.error = error.localizedDescription }
    }
    func move(_ name: String, to side: VisitTrust.Side) {
        do { try VisitTrust.shared.setSide(name, side); error = nil; refresh() }
        catch { self.error = String(describing: error) }
    }
    func forget(_ name: String) {
        if visit.visiting == name { VisitController.shared.end(because: "forgotten") }
        _ = VisitTrust.shared.forget(name)
        refresh()
    }

}
