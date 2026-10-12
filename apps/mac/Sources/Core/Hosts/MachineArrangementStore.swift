import Foundation

/// Placement for hosts without a visit pairing, plus cached monitor geometry.
enum MachineArrangementStore {
    static func placement(_ name: String) -> MachineGeometry.Placement? {
        guard let data = UserDefaults.standard.data(forKey: "machines.placement.\(name)") else { return nil }
        return try? JSONDecoder().decode(MachineGeometry.Placement.self, from: data)
    }
    static func rect(for host: VisitTrust.Host) -> CGRect? {
        guard host.unplaced != true, let placement = host.placement else { return nil }
        let monitors = monitors(host.name)
        guard !monitors.isEmpty else { return placement.rect }
        return CGRect(origin: placement.rect.origin, size: monitors.reduce(CGRect.null) { $0.union($1.frame.rect) }.size)
    }
    static func side(for host: VisitTrust.Host, displays: [CGRect]) -> VisitTrust.Side? {
        guard let rect = rect(for: host) else { return nil }
        return displays.flatMap { MachineGeometry.contacts(display: $0, machine: rect) }.first?.side
    }
    static func place(_ name: String, _ rect: CGRect) throws {
        let value = MachineGeometry.Placement(rect)
        guard value.valid else { throw VisitTrust.Failure.bad("Invalid placement") }
        if VisitTrust.shared.host(named: name) != nil { try VisitTrust.shared.setPlacement(name, value) }
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "machines.placement.\(name)")
        let labels = UserDefaults.standard.dictionary(forKey: "visit.displayMachines") as? [String: String] ?? [:]
        UserDefaults.standard.set(labels.filter { $0.value.caseInsensitiveCompare(name) != .orderedSame }, forKey: "visit.displayMachines")
        DispatchQueue.main.async {
            VisitController.shared.refreshLayout()
            NotificationCenter.default.post(name: VisitController.changed, object: nil)
        }
    }
    struct Monitor: Codable, Equatable {
        var name: String
        var frame: MachineGeometry.Placement
    }
    static func monitors(_ name: String) -> [Monitor] {
        guard let data = UserDefaults.standard.data(forKey: "machines.monitors.\(name)") else { return [] }
        return (try? JSONDecoder().decode([Monitor].self, from: data)) ?? []
    }
    static func parseMonitors(_ value: Any?) -> [Monitor] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let f = item["frame"] as? [String: Any], let w = f["w"] as? Double,
                  let h = f["h"] as? Double else { return nil }
            let frame = MachineGeometry.Placement(x: f["x"] as? Double ?? 0, y: f["y"] as? Double ?? 0, width: w, height: h)
            guard frame.valid else { return nil }
            return Monitor(name: item["displayId"] as? String ?? item["name"] as? String ?? "Display", frame: frame)
        }
    }
    static func cache(_ monitors: [Monitor], for name: String) {
        guard !monitors.isEmpty, let data = try? JSONEncoder().encode(monitors) else { return }
        UserDefaults.standard.set(data, forKey: "machines.monitors.\(name)")
    }
    static func addHost(name: String, address: String, port: UInt16 = 9399, file: URL = RemoteHostsModel.hostsFile) throws {
        guard !name.isEmpty, name != "local", !address.isEmpty, port > 0 else { throw VisitTrust.Failure.bad("Name and address are required") }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw VisitTrust.Failure.bad("Invalid hosts.json")
            }
            root = parsed
        }
        if root["hosts"] != nil && !(root["hosts"] is [String: Any]) { throw VisitTrust.Failure.bad("Invalid hosts.json hosts object") }
        var hosts = root["hosts"] as? [String: Any] ?? [:]
        hosts[name] = ["address": address, "port": Int(port)]
        root["hosts"] = hosts
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
