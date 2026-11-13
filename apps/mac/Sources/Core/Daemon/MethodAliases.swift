import Foundation

/// Old method names kept as aliases for their LAT-012 names.
///
/// The daemon registers each endpoint under its domain name only
/// (`windows.place`, `sessions.launch`). Callers that still send an old name
/// are routed here: the router swaps in the new name and, for the few merges,
/// rewrites the params so the old call keeps its old behavior. `api.schema`
/// advertises only new names and lists the aliases under `aliases`.
enum MethodAliases {
    struct Alias: Sendable {
        let method: String
        let params: (@Sendable (JSON?) -> JSON?)?

        init(_ method: String, params: (@Sendable (JSON?) -> JSON?)? = nil) {
            self.method = method
            self.params = params
        }
    }

    static let table: [String: Alias] = [
        // windows
        "window.focus": Alias("windows.focus"),
        "window.move": Alias("windows.move"),
        "window.place": Alias("windows.place"),
        "window.present": Alias("windows.present"),
        "window.resolve": Alias("windows.resolve"),
        "window.pick.start": Alias("windows.pick"),
        // `window.tile` took a session and a position; `windows.place` takes both.
        "window.tile": Alias("windows.place", params: { params in
            guard case .object(var dict) = params else { return params }
            if dict["placement"] == nil { dict["placement"] = dict["position"] }
            return .object(dict)
        }),

        // layers, spaces
        "layer.activate": Alias("layers.activate"),
        "layer.switch": Alias("layers.switch"),
        "space.optimize": Alias("spaces.optimize"),

        // sessions, groups
        "session.launch": Alias("sessions.launch"),
        "session.kill": Alias("sessions.kill"),
        "session.detach": Alias("sessions.detach"),
        "session.sync": Alias("sessions.sync"),
        "session.restart": Alias("sessions.restart"),
        "group.launch": Alias("groups.launch"),
        "group.kill": Alias("groups.kill"),

        // tabs
        "tabStacks.list": Alias("tabs.list"),
        "tabStacks.create": Alias("tabs.stack"),
        "tabStacks.add": Alias("tabs.add"),
        "tabStacks.select": Alias("tabs.select"),
        "tabStacks.layout": Alias("tabs.layout"),
        "tabStacks.delete": Alias("tabs.unstack"),

        // search, solo (Focus Mode)
        "lattices.search": Alias("search.query"),
        "focus.status": Alias("solo.status"),
        "focus.enter": Alias("solo.enter"),
        "focus.exit": Alias("solo.exit"),
        "focus.toggle": Alias("solo.toggle"),

        // tmux
        "tmux.sessions": Alias("tmux.list"),
        "tmux.inventory": Alias("tmux.list", params: { params in
            var dict: [String: JSON] = [:]
            if case .object(let existing) = params { dict = existing }
            dict["includeOrphans"] = .bool(true)
            return .object(dict)
        }),

        // ocr: `ocr.history` without a wid is the cross-window timeline.
        "ocr.recent": Alias("ocr.history"),

        // intents, history
        "intents.execute": Alias("intents.run"),
        "actions.history": Alias("history.list"),
        "actions.undo": Alias("history.undo"),
    ]

    /// Whole domains accepted under a second name, as prefix pairs.
    ///
    /// `cua` is the computer-use domain's name. Its endpoints still register as
    /// `computer.*` until every host accepts `cua.*`; then the registrations
    /// flip and `computer.*` becomes the alias.
    static let domainAliases: [(alias: String, target: String)] = [
        (alias: "cua.", target: "computer."),
    ]

    /// `method` with a domain alias prefix swapped for its target, or itself.
    static func domainResolved(_ method: String) -> String {
        for pair in domainAliases where method.hasPrefix(pair.alias) {
            return pair.target + method.dropFirst(pair.alias.count)
        }
        return method
    }

    /// The registered method name for `method`: its alias target, or itself.
    static func canonical(_ method: String) -> String {
        let method = domainResolved(method)
        return table[method]?.method ?? method
    }

    /// The method and params to dispatch for a request sent as `method`.
    static func resolve(_ method: String, params: JSON?) -> (method: String, params: JSON?) {
        let method = domainResolved(method)
        guard let alias = table[method] else { return (method, params) }
        return (alias.method, alias.params?(params) ?? params)
    }

    /// Every alias `api.schema` advertises for the registered `methods`:
    /// table entries, plus one domain-alias name per registered method.
    static func advertised(for methods: some Collection<String>) -> [String: String] {
        let registered = Set(methods)
        var aliases = table.filter { registered.contains($0.value.method) }.mapValues(\.method)
        for method in registered {
            for pair in domainAliases where method.hasPrefix(pair.target) {
                aliases[pair.alias + method.dropFirst(pair.target.count)] = method
            }
        }
        return aliases
    }
}
