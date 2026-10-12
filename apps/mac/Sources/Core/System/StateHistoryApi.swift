import Foundation

extension StateHistory {
    static func registerEndpoints(_ api: LatticesApi) {
        api.register(Endpoint(
            method: "states.list",
            description: "Recorded desktop maps, newest first: one after each change settles, kept for 72 hours",
            access: .read,
            params: [
                Param(name: "since", type: "string", required: false, description: "Only maps newer than this: seconds, or a duration like 30m, 2h, 1d"),
                Param(name: "limit", type: "int", required: false, description: "At most this many (default 50)"),
                Param(name: "named", type: "bool", required: false, description: "Only maps saved with a name"),
            ],
            returns: .custom("Object with 'states' (id, taken, name, displays, desktops, windows) and 'total'"),
            handler: { params in
                let history = StateHistory.shared
                var ids = history.ids()
                let total = ids.count
                if let since = params?["since"]?.stringValue ?? params?["since"]?.intValue.map(String.init) {
                    guard let seconds = duration(since) else { throw RouterError.custom("since: expected seconds or 30m, 2h, 1d") }
                    let floor = StateMap.id(for: Date().addingTimeInterval(-seconds))
                    ids = ids.filter { String($0.prefix(19)) >= floor }
                }
                if params?["named"]?.boolValue == true { ids = ids.filter { $0.count > 19 } }
                ids = Array(ids.prefix(params?["limit"]?.intValue ?? 50))
                return .object([
                    "total": .int(total),
                    "states": .array(ids.compactMap { id in
                        guard let map = try? history.load(id) else { return nil }
                        return summary(map)
                    }),
                ])
            }
        ))

        api.register(Endpoint(
            method: "states.get",
            description: "One recorded desktop map in full: displays, their desktops, and every window's frame and desktop",
            access: .read,
            params: [Param(name: "id", type: "string", required: false, description: "A map id from states.list (default: the latest)")],
            returns: .custom("StateMap object"),
            handler: { params in
                let history = StateHistory.shared
                let map: StateMap
                if let ref = params?["id"]?.stringValue {
                    guard let id = history.resolve(ref), let found = try? history.load(id) else { throw RouterError.notFound("state \(ref)") }
                    map = found
                } else {
                    guard let found = try? history.latest() else { throw RouterError.notFound("no states recorded") }
                    map = found
                }
                return try json(map)
            }
        ))

        api.register(Endpoint(
            method: "states.save",
            description: "Record the desktop now under a name, e.g. before a risky change. Named maps are never dropped to make room, only after 72 hours",
            access: .mutate,
            params: [Param(name: "name", type: "string", required: true, description: "A short name")],
            returns: .custom("The new map's summary"),
            handler: { params in
                guard let name = params?["name"]?.stringValue, !name.isEmpty else { throw RouterError.missingParam("name") }
                let map = Thread.isMainThread
                    ? StateHistory.shared.record(name: name)
                    : DispatchQueue.main.sync { StateHistory.shared.record(name: name) }
                guard let map else { throw RouterError.custom("could not record") }
                return summary(map)
            }
        ))

        api.register(Endpoint(
            method: "states.restore",
            description: "Put windows back on the desktops and frames a recorded map has them at. Records the current state as 'before-restore' first, so it can be undone. Never changes display settings. Carries across desktops go through Mission Control and finish after this returns",
            access: .mutate,
            params: [
                Param(name: "id", type: "string", required: true, description: "A map id, id prefix or name from states.list"),
                Param(name: "plan", type: "bool", required: false, description: "Only say what would move (default false)"),
            ],
            returns: .custom("Object with 'id', 'moves' (wid, app, title, carryTo, frame), 'missing', 'notes', 'started'"),
            handler: { params in
                guard let ref = params?["id"]?.stringValue else { throw RouterError.missingParam("id") }
                let history = StateHistory.shared
                guard let id = history.resolve(ref), let map = try? history.load(id) else { throw RouterError.notFound("state \(ref)") }
                let onlyPlan = params?["plan"]?.boolValue == true
                let work = { () -> StateRestore.Plan in
                    let plan = StateRestore.plan(map, live: StateRestore.live())
                    if !onlyPlan && !plan.moves.isEmpty { StateRestore.apply(plan, map: map) }
                    return plan
                }
                let plan = Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
                return .object([
                    "id": .string(map.id),
                    "started": .bool(!onlyPlan && !plan.moves.isEmpty),
                    "moves": .array(plan.moves.map { move in
                        .object([
                            "wid": .int(Int(move.wid)),
                            "app": .string(move.app),
                            "title": .string(move.title),
                            "carryTo": move.carryTo.map(JSON.int) ?? .null,
                            "frame": .object(["x": .double(move.frame.x), "y": .double(move.frame.y), "w": .double(move.frame.w), "h": .double(move.frame.h)]),
                        ])
                    }),
                    "missing": .array(plan.missing.map(JSON.string)),
                    "notes": .array(plan.notes.map(JSON.string)),
                ])
            }
        ))
    }

    static func summary(_ map: StateMap) -> JSON {
        .object([
            "id": .string(map.id),
            "taken": .string(ISO8601DateFormatter().string(from: map.taken)),
            "name": map.name.map(JSON.string) ?? .null,
            "displays": .int(map.displays.count),
            "desktops": .int(map.displays.reduce(0) { $0 + $1.desktops.count }),
            "windows": .int(map.windows.count),
        ])
    }

    static func json(_ map: StateMap) throws -> JSON {
        try decoder.decode(JSON.self, from: encoder.encode(map))
    }

    /// "90", "30m", "2h", "1d" → seconds.
    static func duration(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last else { return nil }
        let scale: Double
        switch unit {
        case "s": scale = 1
        case "m": scale = 60
        case "h": scale = 3600
        case "d": scale = 86400
        default: return Double(text)
        }
        return Double(text.dropLast()).map { $0 * scale }
    }
}
