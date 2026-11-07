import Foundation

struct FocusIntent: LatticeIntent {
    static let name = "focus"
    static let title = "Focus and raise a window"

    static let phrases = [
        // Primary operator: show
        "show {app}",
        "show me {app}",
        "show me the {app}",
        // focus
        "focus {app}",
        "focus on {app}",
        "focus the {app}",
        // switch / go
        "switch to {app}",
        "switch over to {app}",
        "go to {app}",
        "go back to {app}",
        // bring / raise / pull
        "bring up {app}",
        "bring up the {app}",
        "bring forward {app}",
        "raise {app}",
        "raise the {app}",
        "pull up {app}",
        "pull up the {app}",
        // natural
        "i want to see {app}",
        "let me see {app}",
        "take me to {app}",
        "give me {app}",
        "give me the {app}",
        // activate / jump
        "activate {app}",
        "activate the {app}",
        "jump to {app}",
    ]

    static let slots = [
        SlotDef(name: "app", type: .app, required: true),
    ]

    func perform(slots: [String: JSON]) throws -> JSON {
        guard let app = slots["app"]?.stringValue else {
            throw IntentError.missingSlot("app")
        }

        // Use unified search — single source of truth
        let result = try LatticesApi.shared.dispatch(
            method: "search.query",
            params: .object([
                "query": .string(app),
                "sources": .array([.string("titles"), .string("apps"), .string("sessions"), .string("cwd"), .string("tmux")]),
            ])
        )
        if case .array(let items) = result, let first = items.first,
           let wid = first["wid"]?.uint32Value {
            let pid = first["pid"]?.intValue ?? Int(DesktopModel.shared.snapshot.windows[wid]?.pid ?? 0)
            try LatticesApi.onMain {
                WindowTiler.focusWindow(wid: wid, pid: Int32(pid))
            }
            var receipt: [String: JSON] = [
                "ok": .bool(true),
                "requested": .string(app),
                "wid": .int(Int(wid)),
                "pid": .int(pid),
                "targetResolution": .string("search"),
            ]
            if let entry = DesktopModel.shared.snapshot.windows[wid] {
                receipt["app"] = .string(entry.app)
                receipt["title"] = .string(entry.title)
                if let session = entry.latticesSession {
                    receipt["session"] = .string(session)
                    receipt["latticesSession"] = .string(session)
                }
            } else {
                receipt["focused"] = .string(app)
            }
            return .object(receipt)
        }

        return .object(["ok": .bool(false), "reason": .string("No window found for '\(app)'")])
    }
}
