import Foundation

/// Closed Editor API: reads plus explicitly injected, confirmation-gated actions. The injected capture seam lets tests
/// exercise every call without starting the app, observing the desktop or writing.
final class EditorBridge {
    struct Snapshot {
        let subject: EditorSubject
        let projection: [String: Any]
    }
    static let methods = ["subject.read", "preview.project", "events.subscribe"]
    let subscriptionId = UUID().uuidString
    var onEvent: (([String: Any]) -> Void)?
    let hostChrome: Bool
    var selectedLayerIds: () -> [String] = { [] }
    var actionCapture: (() throws -> Snapshot)?
    var actions: EditorActions?
    var assistantSend: ((String, String, Snapshot) throws -> Void)?
    var assistantState: ((String?) -> [String: Any])?
    var onUIState: ((EditorUIState) -> Void)?
    private let capture: () throws -> Snapshot
    private var subscribed = false
    private var lastRevision: String?
    private var lastSnapshot: String?
    private var readFailed = false

    init(hostChrome: Bool = false, capture: @escaping () throws -> Snapshot) {
        self.hostChrome = hostChrome
        self.capture = capture
    }

    func sendUICommand(_ command: String, value: String? = nil) {
        guard hostChrome,
              (command == "arrangement" && EditorUIState.arrangements.contains(value ?? ""))
                || (command == "view" && EditorUIState.views.contains(value ?? ""))
                || (command == "togglePanel" && EditorUIState.panelIDs.contains(value ?? ""))
                || (command == "toggleSource" && value == nil) else { return }
        var payload: [String: Any] = ["command": command]
        if let value { payload["value"] = value }
        onEvent?(envelope(revision: lastRevision as Any? ?? NSNull(), kind: "ui.command", payload: payload))
    }

    func publishAssistantState(layerId: String? = nil) {
        guard let state = assistantState?(layerId) else { return }
        onEvent?(envelope(revision: lastRevision as Any? ?? NSNull(), kind: "assistant.state", payload: state))
    }

    func selectLayers(_ ids: [String]) {
        guard hostChrome else { return }
        onEvent?(envelope(revision: lastRevision as Any? ?? NSNull(), kind: "ui.command",
                          payload: ["command": "selectLayers", "value": ids]))
    }

    private func envelope(requestId: Any = NSNull(), revision: Any = NSNull(), kind: String,
                          payload: [String: Any]) -> [String: Any] {
        ["v": 1, "requestId": requestId, "subjectId": EditorSubject.id,
         "revision": revision, "kind": kind, "payload": payload]
    }

    @discardableResult
    private func observe() throws -> Snapshot {
        let snapshot: Snapshot
        do { snapshot = try capture() }
        catch {
            if !readFailed, subscribed {
                onEvent?(envelope(revision: lastRevision as Any? ?? NSNull(), kind: "config.changed", payload: [
                    "subscriptionId": subscriptionId, "at": ISO8601DateFormatter().string(from: Date())
                ]))
            }
            readFailed = true
            throw error
        }
        let revision = snapshot.subject.revision
        let inventory = snapshot.projection["snapshotId"] as? String
        let configChanged = readFailed || (lastRevision != nil && lastRevision != revision)
        readFailed = false
        let windowsChanged = lastSnapshot != nil && lastSnapshot != inventory
        lastRevision = revision
        lastSnapshot = inventory
        if subscribed {
            let payload: [String: Any] = ["subscriptionId": subscriptionId,
                                          "at": ISO8601DateFormatter().string(from: Date())]
            if configChanged { onEvent?(envelope(revision: revision, kind: "config.changed", payload: payload)) }
            if windowsChanged { onEvent?(envelope(revision: revision, kind: "windows.changed", payload: payload)) }
        }
        return snapshot
    }

    func poll() {
        // observe emits one invalidation per failure/recovery transition. The
        // ensuing subject.read reports the error while the UI retains its view.
        _ = try? observe()
    }

    func reply(to body: Any) -> [String: Any] {
        let request = body as? [String: Any] ?? [:]
        let requestId = request["requestId"] as? String
        do {
            guard let v = request["v"] as? Int, v == 1,
                  let requestId, !requestId.isEmpty,
                  let kind = request["kind"] as? String,
                  request["payload"] is [String: Any],
                  (request["revision"] is NSNull || request["revision"] is String),
                  (request["subjectId"] is NSNull || request["subjectId"] is String) else {
                throw EditorBridgeError("invalid_request", "Expected a v1 Editor request envelope.")
            }
            let actionMethods = actions == nil ? [] : ["action.plan", "action.confirm", "action.reveal", "actions.list"] + (actions?.supportsUndo == true ? ["action.undo"] : [])
            let assistantMethods = assistantSend == nil ? [] : ["assistant.send", "assistant.state"]
            guard kind == "capabilities" || Self.methods.contains(kind) || actionMethods.contains(kind)
                || assistantMethods.contains(kind) || (hostChrome && kind == "ui.state") else {
                throw EditorBridgeError("unsupported", "This Editor is read-only; method is not supported.")
            }
            guard kind == "capabilities" || request["subjectId"] as? String == EditorSubject.id else {
                throw EditorBridgeError("invalid_request", "Unknown Editor subject.")
            }
            // Discovery works even if workspace.json is malformed, so the UI can
            // distinguish an unavailable subject from an incompatible host.
            if kind == "capabilities" {
                let snapshot = try? observe()
                let revision: Any = snapshot?.subject.revision as Any? ?? NSNull()
                let subject: [String: Any] = ["id": EditorSubject.id, "kind": "lattices.workspace-layers",
                                             "label": "Workspace Layers", "revision": revision]
                var payload: [String: Any] = [
                    "readOnly": actions == nil, "methods": Self.methods + actionMethods + assistantMethods + (hostChrome ? ["ui.state"] : []),
                    "subject": subject, "terminal": false
                ]
                if hostChrome { payload["chrome"] = "host"; payload["selectedLayerIds"] = selectedLayerIds() }
                return envelope(requestId: requestId, revision: revision, kind: "capabilities.result", payload: payload)
            }
            if kind == "ui.state" {
                let state = try EditorUIState(payload: request["payload"] as! [String: Any])
                onUIState?(state)
                return envelope(requestId: requestId, revision: lastRevision as Any? ?? NSNull(),
                                kind: "ui.state.result", payload: [:])
            }
            let payload = request["payload"] as! [String: Any]
            if kind == "assistant.state", let assistantState {
                return envelope(requestId: requestId, revision: lastRevision as Any? ?? NSNull(),
                                kind: "assistant.state.result", payload: assistantState(payload["layerId"] as? String))
            }
            if kind == "actions.list", let actions {
                return envelope(requestId: requestId, revision: lastRevision as Any? ?? NSNull(),
                                kind: "actions.list.result", payload: actions.history())
            }
            if kind == "action.confirm" || kind == "action.reveal" || kind == "action.undo", let actions {
                let result: [String: Any]
                if kind == "action.confirm" {
                    guard let id = payload["planId"] as? String, !id.isEmpty else { throw EditorBridgeError("invalid_plan", "A planId is required.") }
                    result = actions.confirm(id, snapshot: actionCapture ?? capture)
                } else if kind == "action.undo" {
                    guard let id = payload["actionId"] as? String else { throw EditorBridgeError("invalid_request", "An actionId is required.") }
                    result = actions.undo(id)
                } else { result = actions.showAll() }
                onEvent?(envelope(revision: lastRevision as Any? ?? NSNull(), kind: "action.result", payload: result))
                return envelope(requestId: requestId, revision: lastRevision as Any? ?? NSNull(),
                                kind: kind + ".result", payload: result)
            }
            if kind == "action.plan", let actions {
                let snapshot = try (actionCapture ?? capture)()
                return envelope(requestId: requestId, revision: snapshot.subject.revision, kind: "action.plan.result",
                                payload: try actions.plan(payload, snapshot: snapshot))
            }
            if kind == "assistant.send", let assistantSend {
                guard let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 16000, let layerId = payload["layerId"] as? String else {
                    throw EditorBridgeError("invalid_request", "Expected a question and layer ID.")
                }
                let snapshot = try observe()
                guard snapshot.subject.layers.contains(where: { $0.id == layerId }) else { throw EditorBridgeError("invalid_request", "Unknown layer.") }
                try assistantSend(text, layerId, snapshot)
                return envelope(requestId: requestId, revision: snapshot.subject.revision, kind: "assistant.send.result", payload: [:])
            }
            // Register before capture. Events may precede this reply; the client
            // installs its listener before sending events.subscribe.
            if kind == "events.subscribe" {
                subscribed = true
                // Subscription survives an unreadable initial file; recovery
                // must arrive without requiring a reload or a new webview.
                _ = try? observe()
                publishAssistantState()
                return envelope(requestId: requestId, revision: lastRevision as Any? ?? NSNull(),
                                kind: "events.subscribe.result", payload: ["subscriptionId": subscriptionId])
            }
            let snapshot = try observe()
            let subject = snapshot.subject
            let result: [String: Any]
            switch kind {
            case "subject.read":
                result = ["subject": subject.descriptor, "source": ["text": subject.source, "language": "json"]]
            case "preview.project":
                guard let revision = request["revision"] as? String else {
                    throw EditorBridgeError("invalid_request", "preview.project requires a revision.")
                }
                guard revision == subject.revision else {
                    throw EditorBridgeError("stale_revision", "Workspace changed. Read the latest subject before projecting.")
                }
                result = snapshot.projection
            default: result = ["subscriptionId": subscriptionId]
            }
            return envelope(requestId: requestId, revision: subject.revision, kind: kind + ".result", payload: result)
        } catch {
            let failure = error as? EditorBridgeError ?? EditorBridgeError("unavailable", error.localizedDescription)
            return envelope(requestId: requestId as Any? ?? NSNull(), revision: lastRevision as Any? ?? NSNull(),
                            kind: "error", payload: ["code": failure.code, "message": failure.message])
        }
    }

    /// Freeze every external resolver source before projecting. In particular,
    /// never use keepRebinds, activation, reloadConfig or any editing primitive.
    static func liveSnapshot(includeGeometry: Bool = true) throws -> Snapshot {
        let manager = WorkspaceManager.shared
        let url = URL(fileURLWithPath: manager.configPath)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            data = Data("{\"layers\":[]}".utf8)
        }
        let subject = try EditorSubject(data: data)
        let windows = DesktopModel.shared.allWindows()
        let groups = Dictionary(subject.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var companions: [String: [LayerProject]] = [:]
        var running: [Int32: Bool] = [:]
        let defaults = LayerMembership.Sources()
        for entry in subject.layers.flatMap(\.projects) {
            if let path = entry.path, companions[path] == nil { companions[path] = manager.projectWindows(at: path) }
            for pin in entry.pins ?? [] {
                if let pid = pin.pid, running[pid] == nil { running[pid] = defaults.isRunning(pid) }
            }
        }
        let sources = LayerMembership.Sources(group: { groups[$0] }, projectWindows: { companions[$0] ?? [] },
                                              isContent: DesktopModel.isContent, isRunning: { running[$0] ?? false })
        // Sidebar counts need membership only. Building placement geometry
        // queries every app through AX and must not run on its 500ms timer.
        let geometry = includeGeometry ? EditorGeometry.live(windows: windows.filter(DesktopModel.isContent)) : nil
        return Snapshot(subject: subject, projection: try subject.project(windows: windows, sources: sources, geometry: geometry))
    }
}


/// UI-only state. Never enters the subject revision, workspace or resolver.
struct EditorUIState: Equatable {
    static let views = ["overview", "workspace"]
    static let arrangements = ["single", "columns", "rows", "grid"]
    static let panelIDs = ["chat", "preview", "history", "source"]
    let selectedLayerIds: [String]?
    let view: String
    let arrangement: String
    let panels: [String]
    let sourceOpen: Bool

    init(payload: [String: Any]) throws {
        // An older bundle only has the panel workspace, not an Overview.
        let view = payload["view"] ?? "workspace"
        guard let view = view as? String, Self.views.contains(view),
              let arrangement = payload["arrangement"] as? String,
              Self.arrangements.contains(arrangement),
              let panels = payload["panels"] as? [String],
              Set(panels).count == panels.count,
              panels.allSatisfy(Self.panelIDs.contains),
              let sourceOpen = payload["sourceOpen"] as? Bool,
              sourceOpen == panels.contains("source") else {
            throw EditorBridgeError("invalid_request", "Invalid Editor UI state.")
        }
        if let raw = payload["selectedLayerIds"] {
            guard let ids = raw as? [String], Set(ids).count == ids.count else {
                throw EditorBridgeError("invalid_request", "Invalid layer selection.")
            }
            selectedLayerIds = ids
        } else { selectedLayerIds = nil }
        self.view = view
        self.arrangement = arrangement
        self.panels = panels
        self.sourceOpen = sourceOpen
    }
}
