import AppKit

// MARK: - Intent Engine

final class IntentEngine {
    static let shared = IntentEngine()

    private var intents: [String: IntentDef] = [:]
    private var intentOrder: [String] = []

    private init() {
        registerBuiltins()
    }

    func register(_ intent: IntentDef) {
        intents[intent.name] = intent
        if !intentOrder.contains(intent.name) {
            intentOrder.append(intent.name)
        }
    }

    func definitions() -> [IntentDef] {
        intentOrder.compactMap { intents[$0] }
    }

    // MARK: - Execution

    func execute(_ request: IntentRequest) throws -> JSON {
        // 1. Direct match by intent name
        if let def = intents[request.intent] {
            return try def.handler(request)
        }

        // 2. Fuzzy match by intent name (handle voice transcription typos)
        let normalized = request.intent.lowercased().replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if let def = intents[normalized] {
            return try def.handler(request)
        }

        // 3. No match
        throw IntentError.unknownIntent(request.intent, available: Array(intents.keys).sorted())
    }

    // MARK: - Discovery

    func catalog() -> JSON {
        .array(intentOrder.compactMap { name in
            guard let def = intents[name] else { return nil }
            return .object([
                "intent": .string(def.name),
                "description": .string(def.description),
                "examples": .array(def.examples.map { .string($0) }),
                "slots": .array(def.slots.map { slot in
                    var obj: [String: JSON] = [
                        "name": .string(slot.name),
                        "type": .string(slot.type),
                        "required": .bool(slot.required),
                        "description": .string(slot.description),
                    ]
                    if let vals = slot.enumValues {
                        obj["values"] = .array(vals.map { .string($0) })
                    }
                    return .object(obj)
                })
            ])
        })
    }

    // MARK: - AI-output Normalization

    /// Tokens that mean "arrange several windows into a grid" rather than tiling one
    /// window. When the model returns these as a tile_window position we remap to distribute.
    private static let gridPositionTokens: Set<String> = [
        "grid", "grid-2x2", "2x2", "grid-2x3", "2x3", "grid-3x3", "3x3",
        "two-by-two", "two by two", "twobytwo", "quad", "quadrant"
    ]

    /// Shorthand the model commonly emits for position-style slots, mapped to the
    /// canonical TilePosition raw values the executor accepts.
    private static let slotValueAliases: [String: String] = [
        "tl": "top-left", "tr": "top-right", "bl": "bottom-left", "br": "bottom-right",
        "top left": "top-left", "top right": "top-right",
        "bottom left": "bottom-left", "bottom right": "bottom-right",
        "topleft": "top-left", "topright": "top-right",
        "bottomleft": "bottom-left", "bottomright": "bottom-right",
        "upper-left": "top-left", "upper-right": "top-right",
        "lower-left": "bottom-left", "lower-right": "bottom-right",
        "max": "maximize", "full": "maximize", "fullscreen": "maximize", "full-screen": "maximize",
        "centre": "center", "centered": "center", "middle": "center"
    ]

    /// Normalize and validate an AI-resolved intent before execution. AI passes produce
    /// free-form text; this maps common shorthand onto the catalog vocabulary and rejects
    /// values the executor would silently fail on, with a message that names the valid set.
    /// - Returns: the corrected intent name and slots, ready to execute.
    /// - Throws: `IntentError.unknownIntent` / `.invalidSlot` (descriptive) on unrecoverable mismatch.
    func normalizeResolved(intentName rawIntent: String, slots rawSlots: [String: JSON]) throws -> (intent: String, slots: [String: JSON]) {
        var intent = canonicalIntentName(rawIntent)
        var slots = rawSlots

        // "tile my four iTerms two-by-two" frequently resolves to
        // tile_window(position: grid-2x2). A grid of N windows is a distribute.
        if intent == "tile_window",
           let pos = slots["position"]?.stringValue,
           Self.gridPositionTokens.contains(pos.lowercased()) {
            intent = "distribute"
            slots["position"] = nil
        }

        guard let def = intents[intent] else {
            throw IntentError.unknownIntent(rawIntent, available: intentOrder)
        }

        for slot in def.slots {
            guard let raw = slots[slot.name]?.stringValue,
                  let allowed = slot.enumValues, !allowed.isEmpty else { continue }
            if allowed.contains(raw) { continue }
            if let mapped = Self.slotValueAliases[raw.lowercased()], allowed.contains(mapped) {
                slots[slot.name] = .string(mapped)
                continue
            }
            if slot.type == "position", let placement = PlacementSpec(string: raw) {
                slots[slot.name] = .string(placement.wireValue)
                continue
            }
            throw IntentError.invalidSlot("Invalid \(slot.name) '\(raw)'. Valid: \(allowed.joined(separator: ", "))")
        }

        return (intent, slots)
    }

    /// Resolve an AI-supplied intent name to a registered one, tolerating casing,
    /// spaces, and hyphens. Returns the raw string unchanged when nothing matches so
    /// the caller can surface a precise unknown-intent error.
    private func canonicalIntentName(_ raw: String) -> String {
        if intents[raw] != nil { return raw }
        let normalized = raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if intents[normalized] != nil { return normalized }
        if let alias = Self.intentAliases[raw.lowercased()] ?? Self.intentAliases[normalized] {
            return alias
        }
        return raw
    }

    /// Intent-name shorthand the model emits that maps to a real intent.
    private static let intentAliases: [String: String] = [
        "grid": "distribute", "arrange": "distribute", "tile_all": "distribute",
        "spread": "distribute", "organize": "distribute"
    ]

    // MARK: - Built-in Intents

    /// Track recently tiled wids so batch operations (e.g. "tile iTerm left, iTerm right")
    /// don't pick the same window twice. Resets after 2 seconds.
    private static var recentlyTiledWids: Set<UInt32> = []
    private static var recentlyTiledTimer: Timer?

    private static func markTiled(_ wid: UInt32) {
        recentlyTiledWids.insert(wid)
        recentlyTiledTimer?.invalidate()
        recentlyTiledTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            recentlyTiledWids.removeAll()
        }
    }

    private func registerBuiltins() {

        // ── Window Tiling ───────────────────────────────────────

        register(IntentDef(
            name: "tile_window",
            description: "Tile a window to a screen position",
            examples: [
                "tile this left",
                "snap to the right half",
                "maximize the window",
                "put it in the top left corner",
                "center the window",
                "make it full screen"
            ],
            slots: [
                IntentSlot(name: "position", type: "position", required: true,
                           description: "Target tile position. Named positions, canonical 0-based grid:CxR:C,R, or compact 1-based CxR:C,R syntax.",
                           enumValues: TilePosition.allCases.map(\.rawValue)),
                IntentSlot(name: "app", type: "string", required: false,
                           description: "Target app name (defaults to frontmost)", enumValues: nil),
                IntentSlot(name: "wid", type: "int", required: false,
                           description: "Target window ID", enumValues: nil),
                IntentSlot(name: "session", type: "string", required: false,
                           description: "Target session name", enumValues: nil),
                IntentSlot(name: "selection", type: "bool", required: false,
                           description: "Apply to the active multi-window selection instead of a single window", enumValues: nil),
            ],
            handler: { req in
                guard let posStr = req.slots["position"]?.stringValue else {
                    throw IntentError.missingSlot("position")
                }
                guard let placement = PlacementSpec(string: posStr) else {
                    throw IntentError.invalidSlot("Unknown position: \(posStr)")
                }

                // Resolve target: explicit session, wid, app name, or frontmost
                if let session = req.slots["session"]?.stringValue {
                    return try LatticesApi.shared.dispatch(
                        method: "windows.place",
                        params: .object(["session": .string(session), "placement": placement.jsonValue])
                    )
                }

                // For wid/app/frontmost: use WindowTiler directly
                func tileEntry(_ entry: WindowEntry) throws {
                    try LatticesApi.onMain {
                        IntentEngine.markTiled(entry.wid)
                        let screen = WindowTiler.screenForWindowFrame(entry.frame)
                        WindowTiler.tileWindowById(wid: entry.wid, pid: entry.pid, to: placement, on: screen)
                    }
                }

                if let wid = req.slots["wid"]?.uint32Value,
                   let entry = DesktopModel.shared.snapshot.windows[wid] {
                    try tileEntry(entry)
                    return .object(["ok": .bool(true), "wid": .int(Int(wid)), "position": .string(posStr)])
                }

                if let app = req.slots["app"]?.stringValue {
                    // Skip windows already tiled in this batch (e.g. two iTerm windows side by side)
                    let alreadyTiled = try LatticesApi.onMain { IntentEngine.recentlyTiledWids }
                    if let entry = DesktopModel.shared.snapshot.windows.values.first(where: {
                        $0.app.localizedCaseInsensitiveContains(app) && !alreadyTiled.contains($0.wid)
                    }) {
                        try tileEntry(entry)
                        return .object(["ok": .bool(true), "app": .string(entry.app), "wid": .int(Int(entry.wid)), "position": .string(posStr)])
                    }
                    throw IntentError.targetNotFound("No window found for app '\(app)'")
                }

                if req.slots["selection"]?.boolValue == true {
                    let selectionIds = try LatticesApi.onMain { WindowSelectionStore.shared.windowIds }
                    guard !selectionIds.isEmpty else {
                        throw IntentError.targetNotFound("No active window selection")
                    }

                    if selectionIds.count == 1,
                       let wid = selectionIds.first,
                       let entry = DesktopModel.shared.snapshot.windows[wid] {
                        try tileEntry(entry)
                        return .object([
                            "ok": .bool(true),
                            "target": .string("selection"),
                            "wid": .int(Int(wid)),
                            "position": .string(posStr)
                        ])
                    }

                    return try LatticesApi.shared.dispatch(
                        method: "spaces.optimize",
                        params: .object([
                            "scope": .string("selection"),
                            "windowIds": .array(selectionIds.map { .int(Int($0)) }),
                            "region": .string(posStr)
                        ])
                    )
                }

                // Default: tile frontmost window
                try LatticesApi.onMain {
                    WindowTiler.tileFrontmostViaAX(to: placement)
                }
                return .object(["ok": .bool(true), "target": .string("frontmost"), "position": .string(posStr)])
            }
        ))

        // ── Focus Window / App ──────────────────────────────────

        register(IntentDef(
            name: "focus",
            description: "Focus a window, app, or session",
            examples: [
                "switch to Chrome",
                "focus the terminal",
                "go to my frontend project",
                "show Slack"
            ],
            slots: [
                IntentSlot(name: "app", type: "string", required: false,
                           description: "App name to focus", enumValues: nil),
                IntentSlot(name: "session", type: "string", required: false,
                           description: "Session name to focus", enumValues: nil),
                IntentSlot(name: "wid", type: "int", required: false,
                           description: "Window ID to focus", enumValues: nil),
            ],
            handler: { req in
                func focusEntry(_ entry: WindowEntry, resolution: String, requested: String? = nil) throws -> JSON {
                    let response = try LatticesApi.shared.dispatch(
                        method: "windows.focus",
                        params: .object(["wid": .int(Int(entry.wid))])
                    )
                    guard case .object(var obj) = response else { return response }
                    obj["targetResolution"] = obj["targetResolution"] ?? .string(resolution)
                    if let requested {
                        obj["requested"] = .string(requested)
                    }
                    if obj["app"] == nil { obj["app"] = .string(entry.app) }
                    if obj["title"] == nil { obj["title"] = .string(entry.title) }
                    if obj["pid"] == nil { obj["pid"] = .int(Int(entry.pid)) }
                    if let session = entry.latticesSession {
                        if obj["session"] == nil { obj["session"] = .string(session) }
                        if obj["latticesSession"] == nil { obj["latticesSession"] = .string(session) }
                    }
                    return .object(obj)
                }

                if let session = req.slots["session"]?.stringValue {
                    return try LatticesApi.shared.dispatch(
                        method: "windows.focus",
                        params: .object(["session": .string(session)])
                    )
                }
                if let wid = req.slots["wid"]?.intValue {
                    return try LatticesApi.shared.dispatch(
                        method: "windows.focus",
                        params: .object(["wid": .int(wid)])
                    )
                }
                if let app = req.slots["app"]?.stringValue {
                    if let entry = DesktopModel.shared.windowForApp(app: app, title: nil) {
                        return try focusEntry(entry, resolution: "app", requested: app)
                    }

                    let searchResult = try? LatticesApi.shared.dispatch(
                        method: "search.query",
                        params: .object([
                            "query": .string(app),
                            "sources": .array([
                                .string("titles"),
                                .string("apps"),
                                .string("sessions"),
                                .string("cwd"),
                                .string("tmux")
                            ]),
                        ])
                    )
                    if case .array(let items) = searchResult,
                       let wid = items.first?["wid"]?.uint32Value,
                       let entry = DesktopModel.shared.snapshot.windows[wid] {
                        return try focusEntry(entry, resolution: "search", requested: app)
                    }

                    if NSWorkspace.shared.launchApplication(app) {
                        return .object([
                            "ok": .bool(true),
                            "launched": .string(app),
                            "requested": .string(app),
                            "targetResolution": .string("app-launch"),
                        ])
                    }
                    throw IntentError.targetNotFound("No window or app found for '\(app)'")
                }
                throw IntentError.missingSlot("app, session, or wid")
            }
        ))

        // ── Launch Session ──────────────────────────────────────

        register(IntentDef(
            name: "launch",
            description: "Launch a project session",
            examples: [
                "open my frontend project",
                "launch the API",
                "start working on lattices",
                "open the backend"
            ],
            slots: [
                IntentSlot(name: "project", type: "string", required: true,
                           description: "Project name or path", enumValues: nil),
            ],
            handler: { req in
                guard let project = req.slots["project"]?.stringValue else {
                    throw IntentError.missingSlot("project")
                }

                // Try matching by name against discovered projects
                let projects = try LatticesApi.shared.dispatch(method: "projects.list", params: nil)
                if case .array(let list) = projects {
                    for p in list {
                        let name = p["name"]?.stringValue ?? ""
                        let path = p["path"]?.stringValue ?? ""
                        if name.localizedCaseInsensitiveContains(project) ||
                           path.localizedCaseInsensitiveContains(project) {
                            return try LatticesApi.shared.dispatch(
                                method: "sessions.launch",
                                params: .object(["path": .string(path)])
                            )
                        }
                    }
                }
                // Fall back to an installed/running app of that name. Require a
                // strong match (word-prefix or better) so a weak fuzzy hit never
                // auto-launches the wrong app.
                if let app = AppIndex.shared.match(project, limit: 1).first, app.score >= 85 {
                    AppIndex.shared.launch(app.entry)
                    return .object(["ok": .bool(true), "launched": .string(app.entry.name)])
                }
                throw IntentError.targetNotFound("No project or app matching '\(project)'")
            }
        ))

        // ── Switch Layer ────────────────────────────────────────

        register(IntentDef(
            name: "switch_layer",
            description: "Switch to a workspace layer",
            examples: [
                "switch to the web layer",
                "go to mobile",
                "layer 2",
                "switch to review"
            ],
            slots: [
                IntentSlot(name: "layer", type: "string", required: true,
                           description: "Layer name or index", enumValues: nil),
            ],
            handler: { req in
                guard let layer = req.slots["layer"]?.stringValue else {
                    throw IntentError.missingSlot("layer")
                }

                if let index = Int(layer) {
                    return try LatticesApi.shared.dispatch(
                        method: "layers.switch",
                        params: .object(["index": .int(index)])
                    )
                }
                return try LatticesApi.shared.dispatch(
                    method: "layers.switch",
                    params: .object(["name": .string(layer)])
                )
            }
        ))

        // ── Search Windows ─────────────────────────────────────

        register(IntentDef(
            name: "search",
            description: "Search for windows by app name, title, session, or screen text",
            examples: [
                "find the error message",
                "search for TODO",
                "find all terminal windows",
                "find chrome",
                "where does it say build failed",
                "look for port 3000"
            ],
            slots: [
                IntentSlot(name: "query", type: "query", required: true,
                           description: "Text to search for", enumValues: nil),
            ],
            handler: { req in
                return try SearchIntent().perform(slots: req.slots)
            }
        ))

        // ── List Windows ────────────────────────────────────────

        register(IntentDef(
            name: "list_windows",
            description: "List all visible windows",
            examples: [
                "what windows are open",
                "show me all windows",
                "what's on screen"
            ],
            slots: [],
            handler: { _ in
                try LatticesApi.shared.dispatch(method: "windows.list", params: nil)
            }
        ))

        // ── List Sessions ───────────────────────────────────────

        register(IntentDef(
            name: "list_sessions",
            description: "List active terminal sessions",
            examples: [
                "what sessions are running",
                "show my projects",
                "list sessions"
            ],
            slots: [],
            handler: { _ in
                try LatticesApi.shared.dispatch(method: "tmux.list", params: nil)
            }
        ))

        // ── Distribute Windows ──────────────────────────────────

        register(IntentDef(
            name: "distribute",
            description: "Distribute windows evenly in a grid, optionally filtered by app or window type and constrained to a screen region",
            examples: [
                "spread out the windows",
                "distribute everything",
                "organize the windows",
                "clean up the layout",
                "grid the terminals on the right",
                "tile all iTerm windows on the left half",
                "arrange my chrome windows in the bottom"
            ],
            slots: [
                IntentSlot(name: "app", type: "string", required: false,
                           description: "Filter to windows of this app (e.g. 'iTerm2', 'Google Chrome')", enumValues: nil),
                IntentSlot(name: "type", type: "string", required: false,
                           description: "Filter to a window type (e.g. 'terminal', 'browser', 'editor')",
                           enumValues: AppType.allCases.map(\.rawValue)),
                IntentSlot(name: "region", type: "position", required: false,
                           description: "Constrain the grid to a screen region. Uses tile position names.",
                           enumValues: ["left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right",
                                        "left-third", "center-third", "right-third"]),
                IntentSlot(name: "selection", type: "bool", required: false,
                           description: "Use the active selected windows instead of all visible windows", enumValues: nil),
            ],
            handler: { req in
                var params: [String: JSON] = [:]
                if let app = req.slots["app"]?.stringValue {
                    params["app"] = .string(app)
                }
                if let type = req.slots["type"]?.stringValue {
                    params["type"] = .string(type)
                }
                if let region = req.slots["region"]?.stringValue {
                    params["region"] = .string(region)
                }
                if req.slots["selection"]?.boolValue == true {
                    let selectionIds = try LatticesApi.onMain { WindowSelectionStore.shared.windowIds }
                    guard !selectionIds.isEmpty else {
                        throw IntentError.targetNotFound("No active window selection")
                    }
                    params["scope"] = .string("selection")
                    params["windowIds"] = .array(selectionIds.map { .int(Int($0)) })
                    return try LatticesApi.shared.dispatch(
                        method: "spaces.optimize",
                        params: .object(params)
                    )
                }
                return try LatticesApi.shared.dispatch(
                    method: "layout.distribute",
                    params: params.isEmpty ? nil : .object(params)
                )
            }
        ))

        // ── Create Layer ────────────────────────────────────────

        register(IntentDef(
            name: "create_layer",
            description: "Save the windows on screen as a new layer",
            examples: [
                "save this layout as review",
                "create a layer called deploy",
                "make a new layer"
            ],
            slots: [
                IntentSlot(name: "name", type: "string", required: true,
                           description: "Name for the new layer", enumValues: nil),
                IntentSlot(name: "capture_visible", type: "bool", required: false,
                           description: "Save the windows on screen into it (default true)", enumValues: nil),
            ],
            handler: { req in
                guard let name = req.slots["name"]?.stringValue else {
                    throw IntentError.missingSlot("name")
                }
                return try LatticesApi.shared.dispatch(
                    method: "layers.create",
                    params: .object([
                        "name": .string(name),
                        "visible": .bool(req.slots["capture_visible"]?.boolValue ?? true)
                    ])
                )
            }
        ))

        // ── Kill Session ────────────────────────────────────────

        register(IntentDef(
            name: "kill",
            description: "Kill a terminal session",
            examples: [
                "stop the frontend session",
                "kill the API",
                "shut down that project"
            ],
            slots: [
                IntentSlot(name: "session", type: "string", required: true,
                           description: "Session name or project name", enumValues: nil),
            ],
            handler: { req in
                guard let session = req.slots["session"]?.stringValue else {
                    throw IntentError.missingSlot("session")
                }

                // Try direct name first
                let sessions = try LatticesApi.shared.dispatch(method: "tmux.list", params: nil)
                if case .array(let list) = sessions {
                    for s in list {
                        let name = s["name"]?.stringValue ?? ""
                        if name.localizedCaseInsensitiveContains(session) {
                            return try LatticesApi.shared.dispatch(
                                method: "sessions.kill",
                                params: .object(["name": .string(name)])
                            )
                        }
                    }
                }
                throw IntentError.targetNotFound("No session matching '\(session)'")
            }
        ))

        // ── Scan (trigger OCR) ──────────────────────────────────

        register(IntentDef(
            name: "scan",
            description: "Trigger an immediate screen text scan",
            examples: [
                "scan the screen",
                "read what's on screen",
                "update OCR"
            ],
            slots: [],
            handler: { _ in
                try LatticesApi.shared.dispatch(method: "ocr.scan", params: nil)
            }
        ))

        // ── Swap Windows ───────────────────────────────────────

        register(IntentDef(
            name: "swap",
            description: "Swap the positions of two windows",
            examples: [
                "swap Chrome and iTerm",
                "switch those two",
                "swap the left and right windows"
            ],
            slots: [
                IntentSlot(name: "wid_a", type: "int", required: true,
                           description: "Window ID of the first window", enumValues: nil),
                IntentSlot(name: "wid_b", type: "int", required: true,
                           description: "Window ID of the second window", enumValues: nil),
            ],
            handler: { req in
                guard let widA = req.slots["wid_a"]?.uint32Value,
                      let widB = req.slots["wid_b"]?.uint32Value else {
                    throw IntentError.missingSlot("wid_a and wid_b")
                }
                guard let entryA = DesktopModel.shared.snapshot.windows[widA],
                      let entryB = DesktopModel.shared.snapshot.windows[widB] else {
                    throw IntentError.targetNotFound("One or both windows not found")
                }

                // Read current CG frames (top-left origin) directly from CGWindowList
                guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                    throw IntentError.targetNotFound("Couldn't read window list")
                }
                var cgFrames: [UInt32: CGRect] = [:]
                for info in windowList {
                    guard let num = info[kCGWindowNumber as String] as? UInt32,
                          (num == widA || num == widB),
                          let dict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
                    var rect = CGRect.zero
                    if CGRectMakeWithDictionaryRepresentation(dict, &rect) {
                        cgFrames[num] = rect
                    }
                }
                guard let frameA = cgFrames[widA], let frameB = cgFrames[widB] else {
                    throw IntentError.targetNotFound("Couldn't read window frames")
                }

                // Swap: move A to B's frame, B to A's frame
                let moves: [(wid: UInt32, pid: Int32, frame: CGRect)] = [
                    (wid: widA, pid: entryA.pid, frame: frameB),
                    (wid: widB, pid: entryB.pid, frame: frameA),
                ]
                try LatticesApi.onMain {
                    WindowTiler.batchMoveAndRaiseWindows(moves)
                }
                return .object([
                    "ok": .bool(true),
                    "swapped": .array([.int(Int(widA)), .int(Int(widB))]),
                ])
            }
        ))

        // ── Hide / Minimize ────────────────────────────────────

        register(IntentDef(
            name: "hide",
            description: "Hide or minimize a window or app",
            examples: [
                "hide Slack",
                "minimize that",
                "put away Messages",
                "hide the browser"
            ],
            slots: [
                IntentSlot(name: "app", type: "string", required: false,
                           description: "App name to hide", enumValues: nil),
                IntentSlot(name: "wid", type: "int", required: false,
                           description: "Window ID to minimize", enumValues: nil),
            ],
            handler: { req in
                // Hide by wid — minimize just that window via AX
                if let wid = req.slots["wid"]?.uint32Value,
                   let entry = DesktopModel.shared.snapshot.windows[wid] {
                    let appRef = AXUIElementCreateApplication(entry.pid)
                    var windowsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                       let axWindows = windowsRef as? [AXUIElement] {
                        for axWin in axWindows {
                            var windowId: CGWindowID = 0
                            if _AXUIElementGetWindow(axWin, &windowId) == .success, windowId == wid {
                                AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                                return .object(["ok": .bool(true), "action": .string("minimized"), "wid": .int(Int(wid))])
                            }
                        }
                    }
                    throw IntentError.targetNotFound("Couldn't find AX window for wid \(wid)")
                }

                // Hide by app name — hide the entire app
                if let appName = req.slots["app"]?.stringValue {
                    let apps = NSWorkspace.shared.runningApplications
                    if let app = apps.first(where: {
                        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
                    }) {
                        app.hide()
                        return .object(["ok": .bool(true), "action": .string("hidden"), "app": .string(app.localizedName ?? appName)])
                    }
                    throw IntentError.targetNotFound("No running app matching '\(appName)'")
                }

                throw IntentError.missingSlot("app or wid")
            }
        ))

        // ── Highlight ──────────────────────────────────────────

        register(IntentDef(
            name: "highlight",
            description: "Flash a window's border to identify it visually",
            examples: [
                "which one is the lattices terminal",
                "highlight Chrome",
                "show me that window",
                "flash the iTerm window"
            ],
            slots: [
                IntentSlot(name: "wid", type: "int", required: false,
                           description: "Window ID to highlight", enumValues: nil),
                IntentSlot(name: "app", type: "string", required: false,
                           description: "App name to highlight", enumValues: nil),
            ],
            handler: { req in
                if let wid = req.slots["wid"]?.uint32Value {
                    try LatticesApi.onMain {
                        WindowTiler.highlightWindowById(wid: wid)
                    }
                    return .object(["ok": .bool(true), "wid": .int(Int(wid))])
                }

                if let appName = req.slots["app"]?.stringValue {
                    if let entry = DesktopModel.shared.snapshot.windows.values.first(where: {
                        $0.app.localizedCaseInsensitiveContains(appName)
                    }) {
                        try LatticesApi.onMain {
                            WindowTiler.highlightWindowById(wid: entry.wid)
                        }
                        return .object(["ok": .bool(true), "wid": .int(Int(entry.wid)), "app": .string(entry.app)])
                    }
                    throw IntentError.targetNotFound("No window found for app '\(appName)'")
                }

                throw IntentError.missingSlot("wid or app")
            }
        ))

        // ── Move to Display ────────────────────────────────────

        register(IntentDef(
            name: "move_to_display",
            description: "Move a window to another monitor/display, optionally positioning it",
            examples: [
                "put this on the vertical monitor",
                "move Chrome to the second display",
                "send iTerm to the other screen",
                "move that to my main monitor"
            ],
            slots: [
                IntentSlot(name: "wid", type: "int", required: false,
                           description: "Window ID to move", enumValues: nil),
                IntentSlot(name: "app", type: "string", required: false,
                           description: "App name to move", enumValues: nil),
                IntentSlot(name: "display", type: "int", required: true,
                           description: "Target display index (0 = main, 1 = second, etc.)", enumValues: nil),
                IntentSlot(name: "position", type: "position", required: false,
                           description: "Tile position on the target display (e.g. 'left', 'maximize')",
                           enumValues: ["left", "right", "top", "bottom", "maximize", "center",
                                        "top-left", "top-right", "bottom-left", "bottom-right"]),
            ],
            handler: { req in
                guard let display = req.slots["display"]?.intValue else {
                    throw IntentError.missingSlot("display")
                }

                // Resolve window target
                let wid: UInt32
                if let w = req.slots["wid"]?.uint32Value {
                    wid = w
                } else if let appName = req.slots["app"]?.stringValue,
                          let entry = DesktopModel.shared.snapshot.windows.values.first(where: {
                              $0.app.localizedCaseInsensitiveContains(appName)
                          }) {
                    wid = entry.wid
                } else {
                    // Frontmost window
                    guard let frontApp = NSWorkspace.shared.frontmostApplication,
                          !LatticesRuntime.isLatticesBundleIdentifier(frontApp.bundleIdentifier) else {
                        throw IntentError.targetNotFound("No frontmost window")
                    }
                    let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
                    var focusedRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else {
                        throw IntentError.targetNotFound("No focused window")
                    }
                    var frontWid: CGWindowID = 0
                    guard _AXUIElementGetWindow(focusedRef as! AXUIElement, &frontWid) == .success else {
                        throw IntentError.targetNotFound("Couldn't get frontmost window ID")
                    }
                    wid = frontWid
                }

                // Use window.present with display + optional position
                var params: [String: JSON] = [
                    "wid": .int(Int(wid)),
                    "display": .int(display),
                ]
                if let pos = req.slots["position"]?.stringValue {
                    params["position"] = .string(pos)
                }
                return try LatticesApi.shared.dispatch(method: "windows.present", params: .object(params))
            }
        ))

        // ── Find / Summon Mouse ────────────────────────────────

        register(IntentDef(
            name: "find_mouse",
            description: "Show a sonar pulse at the current mouse cursor position",
            examples: [
                "where's my mouse",
                "find the cursor",
                "I lost my mouse",
                "find mouse",
                "show cursor"
            ],
            slots: [],
            handler: { _ in
                try LatticesApi.onMain { MouseFinder.shared.find() }
                let pos = NSEvent.mouseLocation
                return .object(["ok": .bool(true), "x": .int(Int(pos.x)), "y": .int(Int(pos.y))])
            }
        ))

        register(IntentDef(
            name: "summon_mouse",
            description: "Warp the mouse cursor to the center of the screen",
            examples: [
                "summon mouse",
                "bring the cursor here",
                "center the mouse",
                "mouse come here",
                "bring mouse back"
            ],
            slots: [],
            handler: { _ in
                try LatticesApi.onMain { MouseFinder.shared.summon() }
                return .object(["ok": .bool(true)])
            }
        ))

        // ── Undo / Restore ─────────────────────────────────────

        register(IntentDef(
            name: "undo",
            description: "Undo the last window move — restore windows to their previous positions",
            examples: [
                "put it back",
                "undo that",
                "restore the windows",
                "that was wrong, undo"
            ],
            slots: [],
            handler: { _ in
                let history = try LatticesApi.onMain { HandsOffSession.shared.frameHistory }
                guard !history.isEmpty else {
                    throw IntentError.targetNotFound("No window moves to undo")
                }

                let restores = history.map { (wid: $0.wid, pid: $0.pid, frame: $0.frame) }
                try LatticesApi.onMain {
                    WindowTiler.batchRestoreWindows(restores)
                    HandsOffSession.shared.clearFrameHistory()
                }
                return .object([
                    "ok": .bool(true),
                    "restored": .int(restores.count),
                ])
            }
        ))
    }
}

// MARK: - Errors

enum IntentError: LocalizedError {
    case unknownIntent(String, available: [String])
    case missingSlot(String)
    case invalidSlot(String)
    case targetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unknownIntent(let name, let available):
            return "Unknown intent '\(name)'. Available: \(available.joined(separator: ", "))"
        case .missingSlot(let name):
            return "Missing required slot: \(name)"
        case .invalidSlot(let detail):
            return detail
        case .targetNotFound(let detail):
            return detail
        }
    }
}

struct ResolvedIntent {
    let intent: String
    let slots: [String: JSON]
}
