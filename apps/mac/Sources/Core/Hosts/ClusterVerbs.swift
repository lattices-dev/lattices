import AppKit

/// Composes the established operations; injected inventory keeps tests off the desktop.
enum ClusterVerbs {
    static func register(_ api: LatticesApi, screens: @escaping () -> [DisplayGather.Screen] = DisplayGather.screens) {
        let display = Param(name: "display", type: "int|string", required: true, description: "Display number or case-insensitive name fragment")
        func alias(_ name: String, _ method: String, params: [Param], transform: @escaping (JSON?) -> JSON? = { $0 }) {
            api.register(Endpoint(method: name, description: "Cluster shortcut for \(method)", access: .mutate,
                                  params: params, returns: .ok, handler: { try api.dispatch(method: method, params: transform($0)) }))
        }
        alias("home", "mouse.home", params: [])
        for name in ["elsewhere", "here"] {
            alias(name, "visit.elsewhere", params: [display, Param(name: "name", type: "string", required: false, description: "Machine shown on the display")]) { p in
                var values: [String: JSON] = ["screen": p?["display"] ?? .null, "on": .bool(name == "elsewhere")]
                if let machine = p?["name"] { values["name"] = machine }
                return .object(values)
            }
        }
        api.register(Endpoint(method: "main", description: "Make a display main for a 15-second trial; keep accepts immediately", access: .mutate,
            params: [display, Param(name: "keep", type: "bool", required: false, description: "Accept immediately")], returns: .ok,
            handler: { p in
                let result = try api.dispatch(method: "visit.main", params: .object(["screen": p?["display"] ?? .null]))
                if p?["keep"]?.boolValue == true { _ = try api.dispatch(method: "visit.arrangement.keep", params: nil) }
                return result
            }))
        api.register(Endpoint(method: "bring", description: "Gather every other display onto this display; undo restores gathered windows", access: .mutate,
            params: [Param(name: "display", type: "int|string", required: false, description: "Target display"), Param(name: "undo", type: "bool", required: false, description: "Restore")], returns: .custom("Gather results or restore results"),
            handler: { p in
                if p?["undo"]?.boolValue == true { return try api.dispatch(method: "display.restore", params: nil) }
                return try DisplayGather.onMain {
                    let all = screens()
                    let target = try DisplayGather.resolve(p?["display"], "display", among: all)
                    let results = try all.filter { $0.id != target.id }.map { source in
                        try api.dispatch(method: "display.gather", params: .object(["display": .int(source.index), "to": .int(target.index)]))
                    }
                    return .object(["ok": .bool(true), "gathered": .array(results)])
                }
            }))
        api.register(Endpoint(method: "visit.start", description: "Visit a paired machine at the midpoint of its touching span", access: .mutate,
            params: [Param(name: "host", type: "string", required: true, description: "Paired machine name")], returns: .ok,
            handler: { p in
                guard let name = p?["host"]?.stringValue else { throw RouterError.missingParam("host") }
                return try DisplayGather.onMain {
                    try VisitController.shared.start(machine: name)
                    return .object(["ok": .bool(true)])
                }
            }))
        api.register(Endpoint(method: "host.describe", description: "Mac identity, build, displays and supported methods", access: .read,
            params: [], returns: .custom("Host identity"), handler: { _ in
                DisplayGather.onMain {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    return .object([
                        "platform": .string("macos"), "hostname": .string(VisitTrust.Host.localName),
                        "version": version.map(JSON.string) ?? .null,
                        "build": .object(["version": version.map(JSON.string) ?? .null, "commit": LatticesRuntime.buildRevision.map(JSON.string) ?? .null]),
                        "capabilities": .array([.string("windows.read"), .string("windows.place"), .string("spaces.read")]),
                        "methods": .array(api.endpoints.keys.sorted().map(JSON.string)),
                        "displays": .array(screens().map { s in .object([
                            "index": .int(s.index), "name": .string(s.name), "main": .bool(s.isMain),
                            "frame": .object(["x": .double(s.frame.minX), "y": .double(s.frame.minY), "w": .double(s.frame.width), "h": .double(s.frame.height)])
                        ]) })
                    ])
                }
            }))
    }

    static func run(_ method: String, _ params: JSON? = nil) {
        do { _ = try LatticesApi.shared.dispatch(method: method, params: params) }
        catch {
            let alert = NSAlert(); alert.messageText = "\(error.localizedDescription)"; alert.runModal()
        }
    }
}
