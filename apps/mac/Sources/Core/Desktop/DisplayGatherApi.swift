import AppKit

extension DisplayGather {
    static func registerEndpoints(_ api: LatticesApi) {
        let display = Param(name: "display", type: "int|string", required: true, description: "Display index (spaces.list) or part of its name")

        api.register(Endpoint(
            method: "displays.list",
            description: "The displays, with how many windows each shows and what a gather took off any of them",
            access: .read,
            params: [],
            returns: .custom("Object with 'displays' (index, id, name, main, width, height, windows) and 'gathered' (display name and id, window count, gatheredTo)"),
            handler: { _ in
                try Self.onMain {
                    let screens = Self.screens()
                    let inventory = DesktopModel.shared.allWindows()
                    let shared = DisplayGather.shared
                    return .object([
                        "displays": .array(screens.map { screen in
                            .object([
                                "index": .int(screen.index),
                                "id": .string(screen.id),
                                "name": .string(screen.name),
                                "main": .bool(screen.isMain),
                                "width": .int(Int(screen.frame.width)),
                                "height": .int(Int(screen.frame.height)),
                                "windows": .int(Self.windows(on: screen, among: screens, from: inventory).count),
                            ])
                        }),
                        "gathered": .array(shared.stashes.values.sorted { $0.at < $1.at }.map { stash in
                            .object([
                                "display": .string(stash.displayName),
                                "id": .string(stash.displayId),
                                "windows": .int(stash.windows.count),
                                "gatheredTo": .string(stash.gatheredTo),
                                "here": .bool(screens.contains { $0.id == stash.displayId }),
                            ])
                        }),
                    ])
                }
            }
        ))

        api.register(Endpoint(
            method: "display.gather",
            description: "Move every window one display shows onto another, laid out as it was, and remember where they came from (display.restore puts them back)",
            access: .mutate,
            params: [
                display,
                Param(name: "to", type: "int|string", required: false, description: "The display to gather onto (default: the main display, or the first other one)"),
            ],
            returns: .custom("Object with 'moved', 'from' and 'to'"),
            handler: { params in
                try Self.onMain {
                    let source = try Self.resolve(params?["display"], "display")
                    let target: Screen
                    if let to = params?["to"], to != .null {
                        target = try Self.resolve(to, "to")
                    } else {
                        let others = Self.screens().filter { $0.id != source.id }
                        guard let pick = others.first(where: \.isMain) ?? others.first else {
                            throw RouterError.custom("No other display to gather onto")
                        }
                        target = pick
                    }
                    guard target.id != source.id else { throw RouterError.custom("Can't gather a display onto itself") }
                    let moved = DisplayGather.shared.gather(from: source.id, to: target)
                    return .object(["ok": .bool(true), "moved": .int(moved), "from": .string(source.name), "to": .string(target.name)])
                }
            }
        ))

        api.register(Endpoint(
            method: "display.restore",
            description: "Put back what display.gather took off a display, where it sat. Without a display, restores every gathered display that's here",
            access: .mutate,
            params: [Param(name: "display", type: "int|string", required: false, description: "Display index or part of its name")],
            returns: .custom("Object with 'restored' (display name and window count each)"),
            handler: { params in
                try Self.onMain {
                    let shared = DisplayGather.shared
                    let ids: [String]
                    if let value = params?["display"], value != .null {
                        ids = [try Self.resolve(value, "display").id]
                    } else {
                        let here = Set(Self.screens().map(\.id))
                        ids = shared.stashes.keys.filter { here.contains($0) }
                    }
                    var restored: [JSON] = []
                    for id in ids {
                        let name = shared.stashes[id]?.displayName ?? id
                        guard let moved = shared.restore(id) else { continue }
                        restored.append(.object(["display": .string(name), "moved": .int(moved)]))
                    }
                    return .object(["ok": .bool(true), "restored": .array(restored)])
                }
            }
        ))

        api.register(Endpoint(
            method: "display.lend",
            description: "Lending a display: ask on the other displays whether to gather its windows there, as when it leaves. For a monitor whose input switches without telling the Mac",
            access: .mutate,
            params: [display],
            returns: .custom("Object with 'asking' and the display's 'name'"),
            handler: { params in
                try Self.onMain {
                    let source = try Self.resolve(params?["display"], "display")
                    DisplayGather.shared.ask(gathering: source.id)
                    return .object(["ok": .bool(true), "asking": .bool(DisplayPrompt.shared.isAsking), "name": .string(source.name)])
                }
            }
        ))
    }

    static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    static func resolve(_ value: JSON?, _ name: String, among all: [Screen]? = nil) throws -> Screen {
        let query: String
        switch value {
        case .int(let index): query = String(index)
        case .double(let index) where index.isFinite && index.rounded() == index && index >= 0 && index < Double(Int.max): query = String(Int(index))
        case .string(let text) where !text.isEmpty: query = text
        default: throw RouterError.missingParam(name)
        }
        guard let screen = screen(named: query, among: all ?? screens()) else { throw RouterError.notFound("display \(query)") }
        return screen
    }
}
