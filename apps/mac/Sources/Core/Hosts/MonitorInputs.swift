import AppKit
import Foundation

/// Which machine a shared monitor is showing. A monitor cabled to several
/// hosts reports its current input over DDC (VCP 0x60); a per-monitor map,
/// set once by the user, says which input belongs to which machine. Reads
/// happen when the Machines page asks, writes only on an explicit switch.
@MainActor
final class MonitorInputs: ObservableObject {
    static let shared = MonitorInputs()
    /// This Mac, in the input map.
    nonisolated static let here = "@here"

    struct State: Equatable {
        var input: MonitorDDC.Input?
        var inputs: [MonitorDDC.Input]
    }

    @Published private(set) var states: [String: State] = [:]
    /// Monitor key → machine → input code.
    @Published private(set) var map: [String: [String: Int]]
    /// This Mac's displays by monitor key.
    @Published private(set) var local: [CGDirectDisplayID: String] = [:]
    @Published private(set) var working: Set<String> = []
    @Published var error: String?

    private enum Reach: Hashable { case here, host(String) }
    private let defaults: UserDefaults
    private static let mapKey = "monitors.inputs"
    /// Routes tried for each key since the page appeared, so each route is
    /// read once per visit and a host that connects later still gets its turn.
    private var tried: [String: Set<Reach>] = [:]
    /// Routes that have answered DDC for each key. Writes go only through
    /// these: an I2C ack from a route that can't read proves nothing.
    private var answered: [String: Set<Reach>] = [:]
    /// The route that last answered, tried first next time: many monitors
    /// only answer DDC on the input they are showing.
    private var last: [String: Reach] = [:]
    /// Bumped by each switch, so a read that started earlier can't undo it.
    private var generation: [String: Int] = [:]
    /// Linux re-detects before a write and serializes ddcutil calls.
    private static let readTimeout: TimeInterval = 20
    private static let writeTimeout: TimeInterval = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        map = defaults.dictionary(forKey: Self.mapKey) as? [String: [String: Int]] ?? [:]
    }

    // MARK: Pure

    /// The machine whose input is current.
    nonisolated static func owner(of code: Int?, in inputs: [String: Int]) -> String? {
        guard let code else { return nil }
        return inputs.filter { $0.value == code }.map(\.key).sorted().first
    }

    /// One input per machine and one machine per input.
    nonisolated static func assigning(_ code: Int, to machine: String, in inputs: [String: Int]) -> [String: Int] {
        var next = inputs.filter { $0.value != code && !same($0.key, machine) }
        next[machine] = code
        return next
    }

    /// Machine names compare as the inventory does, ignoring case.
    nonisolated static func same(_ a: String, _ b: String) -> Bool { MachineInventory.key(a) == MachineInventory.key(b) }

    nonisolated static func code(of machine: String, in inputs: [String: Int]) -> Int? {
        inputs.first { same($0.key, machine) }?.value
    }

    nonisolated static func result(_ reply: [String: Any], key: String) -> MonitorDDC.Result {
        func input(_ value: Any?) -> MonitorDDC.Input? {
            ((value as? [String: Any])?["code"] as? NSNumber).map { MonitorDDC.Input(code: $0.intValue) }
        }
        return MonitorDDC.Result(key: key, ddc: reply["ddc"] as? Bool ?? false, input: input(reply["input"]),
                                 inputs: (reply["inputs"] as? [Any] ?? []).compactMap(input))
    }

    // MARK: Reading

    func owner(_ key: String) -> String? { Self.owner(of: states[key]?.input?.code, in: map[key] ?? [:]) }

    /// Whether `machine` is on screen; nil when the monitor or the machine's input is unknown.
    func showing(_ key: String?, machine: String) -> Bool? {
        guard let key, let current = states[key]?.input?.code, let mine = Self.code(of: machine, in: map[key] ?? [:]) else { return nil }
        return current == mine
    }

    /// Each visit starts from fresh reads; nothing from the last one shows as live.
    func appear() {
        states = [:]
        error = nil
        tried = [:]
        refreshLocal()
        readNew()
    }

    func refreshLocal() {
        var next: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let key = MonitorIdentity.forDisplay(id)?.key, !key.isEmpty else { continue }
            next[id] = key
        }
        if next != local { local = next }
    }

    /// Reads each monitor through any route not yet tried since the page appeared.
    func readNew() {
        for key in reachable().sorted() {
            let fresh = reaches(key).filter { !(tried[key]?.contains($0) ?? false) }
            guard !fresh.isEmpty, states[key] == nil || fresh.count < reaches(key).count else { continue }
            Task { await read(key, via: fresh) }
        }
    }

    func readAll() {
        error = nil
        tried = [:]
        refreshLocal()
        for key in reachable().sorted() { Task { await read(key, via: reaches(key)) } }
    }

    private func reachable() -> Set<String> {
        var keys = Set(local.values)
        for host in RemoteHostsModel.shared.hosts where readable(host) {
            keys.formUnion(host.monitors.compactMap(\.key))
        }
        return keys
    }

    private func readable(_ host: RemoteHostsModel.Host) -> Bool {
        host.status == .online && host.capabilities.contains("display.input")
    }

    private func reaches(_ key: String) -> [Reach] {
        var list: [Reach] = local.values.contains(key) ? [.here] : []
        for host in RemoteHostsModel.shared.hosts where readable(host) && host.monitors.contains(where: { $0.key == key }) {
            list.append(.host(host.name))
        }
        if let first = last[key], let i = list.firstIndex(of: first) { list.insert(list.remove(at: i), at: 0) }
        return list
    }

    private func read(_ key: String, via routes: [Reach]) async {
        guard !working.contains(key) else { return }
        let started = generation[key, default: 0]
        tried[key, default: []].formUnion(routes)
        for reach in routes {
            guard let result = await get(key, via: reach) else { continue }
            guard generation[key, default: 0] == started else { return }
            guard result.ddc else { continue }
            states[key] = State(input: result.input, inputs: result.inputs)
            answered[key, default: []].insert(reach)
            last[key] = reach
            reconcile(key)
            return
        }
        // Every route was asked and none answered: nothing known is live.
        if generation[key, default: 0] == started, Set(routes) == Set(reaches(key)) { states[key] = nil }
    }

    private func get(_ key: String, via reach: Reach) async -> MonitorDDC.Result? {
        switch reach {
        case .here:
            return await MonitorDDC.input(key: key)
        case .host(let name):
            guard let reply = try? await RemoteHostsModel.shared.call(name, "display.input.get", params: ["key": key], timeout: Self.readTimeout) as? [String: Any] else { return nil }
            return Self.result(reply, key: key)
        }
    }

    // MARK: Acting

    /// Switches the monitor to `code`. Only from an explicit click, and only
    /// through routes that have read this monitor.
    func show(_ key: String, input code: Int) {
        guard !working.contains(key) else { return }
        let routes = reaches(key).filter { answered[key]?.contains($0) ?? false }
        guard !routes.isEmpty else { error = "Nothing can reach that monitor's input right now"; return }
        working.insert(key)
        generation[key, default: 0] += 1
        error = nil
        Task {
            defer { working.remove(key) }
            for reach in routes {
                let input: MonitorDDC.Input?
                if let done = await set(key, code, via: reach) {
                    guard done.ok else { continue }
                    input = done.input ?? MonitorDDC.Input(code: code)
                } else {
                    // No reply in time: the write may still have landed, so look before writing again.
                    guard let seen = await get(key, via: reach), seen.ddc, seen.input?.code == code else { continue }
                    input = seen.input
                }
                states[key, default: State(input: nil, inputs: [])].input = input
                last[key] = reach
                reconcile(key)
                return
            }
            error = "Couldn't switch the monitor to \(MonitorDDC.inputName(code))"
        }
    }

    func show(_ key: String, machine: String) {
        if let code = Self.code(of: machine, in: map[key] ?? [:]) { show(key, input: code) }
    }

    private func set(_ key: String, _ code: Int, via reach: Reach) async -> MonitorDDC.SetResult? {
        switch reach {
        case .here:
            return await MonitorDDC.setInput(key: key, code: code)
        case .host(let name):
            guard let reply = try? await RemoteHostsModel.shared.call(name, "display.input.set", params: ["key": key, "code": code], timeout: Self.writeTimeout) as? [String: Any] else { return nil }
            let input = ((reply["input"] as? [String: Any])?["code"] as? NSNumber).map { MonitorDDC.Input(code: $0.intValue) }
            return MonitorDDC.SetResult(ok: reply["ok"] as? Bool ?? false, input: input)
        }
    }

    /// Records that the monitor's current input belongs to `machine`.
    func assign(_ key: String, machine: String) {
        guard let code = states[key]?.input?.code else { return }
        map[key] = Self.assigning(code, to: machine, in: map[key] ?? [:])
        defaults.set(map, forKey: Self.mapKey)
        reconcile(key)
    }

    /// Keeps this Mac's own view in step: a local display showing another
    /// machine is Elsewhere and labelled with it, one showing this Mac is here.
    /// With only this Mac's input known, another input is Elsewhere, unlabelled.
    private func reconcile(_ key: String) {
        guard let current = states[key]?.input?.code else { return }
        let inputs = map[key] ?? [:]
        let owner = Self.owner(of: current, in: inputs)
        let away: Bool
        if let owner { away = !Self.same(owner, Self.here) }
        else if let mine = Self.code(of: Self.here, in: inputs) { away = current != mine }
        else { return }
        let label = away ? owner : nil
        let visit = VisitController.shared
        for screen in VisitController.screens() where local[screen.displayID] == key {
            if screen.elsewhere != away { visit.setElsewhere(screen.number, away) }
            if screen.machine != label { _ = visit.setDisplayMachine(screen.number, name: label) }
        }
    }
}
