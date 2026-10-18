import AppKit
import CoreGraphics
import Foundation

enum ComputerTreatment: String {
    case observe
    case stage
    case present
    case execute

    var focusesWindow: Bool {
        self == .present || self == .execute
    }

    var insertsText: Bool {
        self == .execute
    }

    var performsPointerAction: Bool {
        self == .execute
    }

    static func resolve(params: JSON?, defaultValue: ComputerTreatment) -> ComputerTreatment {
        if params?["dryRun"]?.boolValue == true || params?["dry-run"]?.boolValue == true {
            return .stage
        }
        let raw = params?["treatment"]?.stringValue
            ?? params?["mode"]?.stringValue
            ?? params?["phase"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "observe", "inspect":
            return .observe
        case "stage", "plan", "preview", "dry-run", "dryrun":
            return .stage
        case "present", "prepare", "focus":
            return .present
        case "execute", "type", "insert":
            return .execute
        default:
            return defaultValue
        }
    }
}

private struct ComputerBackgroundSafetyReceipt {
    let route: String
    let lane: String
    let session: String
    let backgroundSafe: Bool
    let cursorMoved: Bool
    let foregroundChanged: Bool

    var json: JSON {
        .object([
            "route": .string(route),
            "lane": .string(lane),
            "session": .string(session),
            "background_safe": .bool(backgroundSafe),
            "backgroundSafe": .bool(backgroundSafe),
            "cursor_moved": .bool(cursorMoved),
            "cursorMoved": .bool(cursorMoved),
            "foreground_changed": .bool(foregroundChanged),
            "foregroundChanged": .bool(foregroundChanged),
        ])
    }
}

private struct AXTextInsertionResult {
    let role: String
    let roleDescription: String?
    let frame: CGRect?
    let previousValue: String?
    let insertedValue: String
    let verifiedValue: String?
    let typedCharacters: Int?
    let typeIntervalMs: Double?

    var json: JSON {
        var object: [String: JSON] = [
            "role": .string(role),
            "insertedValue": .string(insertedValue),
            "verified": .bool(verifiedValue == insertedValue),
        ]
        if let roleDescription {
            object["roleDescription"] = .string(roleDescription)
        }
        if let previousValue {
            object["previousValue"] = .string(previousValue)
        }
        if let verifiedValue {
            object["verifiedValue"] = .string(verifiedValue)
        }
        if let typedCharacters {
            object["typedCharacters"] = .int(typedCharacters)
        }
        if let typeIntervalMs {
            object["typeIntervalMs"] = .double(typeIntervalMs)
        }
        if let frame {
            object["frame"] = .object([
                "x": .double(frame.origin.x),
                "y": .double(frame.origin.y),
                "w": .double(frame.width),
                "h": .double(frame.height),
            ])
        }
        return .object(object)
    }
}

private struct AXPressResult {
    let role: String
    let roleDescription: String?
    let title: String?
    let value: String?
    let description: String?
    let frame: CGRect?
    let action: String
    let performed: Bool

    var json: JSON {
        var object: [String: JSON] = [
            "role": .string(role),
            "action": .string(action),
            "performed": .bool(performed),
        ]
        if let roleDescription {
            object["roleDescription"] = .string(roleDescription)
        }
        if let title {
            object["title"] = .string(title)
        }
        if let value {
            object["value"] = .string(value)
        }
        if let description {
            object["description"] = .string(description)
        }
        if let frame {
            object["frame"] = .object([
                "x": .double(frame.origin.x),
                "y": .double(frame.origin.y),
                "w": .double(frame.width),
                "h": .double(frame.height),
            ])
        }
        return .object(object)
    }
}

private struct AXEditableCandidate {
    let element: AXUIElement
    let role: String
    let roleDescription: String?
    let frame: CGRect?
    let value: String?
    let score: Double
}

private struct AXPressCandidate {
    let element: AXUIElement
    let role: String
    let roleDescription: String?
    let title: String?
    let value: String?
    let description: String?
    let frame: CGRect?
    let score: Double
}

private struct AXSnapshotElement {
    let id: String
    let role: String
    let roleDescription: String?
    let title: String?
    let label: String?
    let value: String?
    let description: String?
    let help: String?
    let identifier: String?
    let frame: CGRect?
    let enabled: Bool?
    let selected: Bool?
    let focused: Bool?
    let actions: [String]
    let path: String
    let depth: Int
    let childCount: Int

    var json: JSON {
        var object: [String: JSON] = [
            "id": .string(id),
            "role": .string(role),
            "path": .string(path),
            "depth": .int(depth),
            "childCount": .int(childCount),
            "actions": .array(actions.map { .string($0) }),
        ]
        if let roleDescription {
            object["roleDescription"] = .string(roleDescription)
        }
        if let title {
            object["title"] = .string(title)
        }
        if let label {
            object["label"] = .string(label)
        }
        if let value {
            object["value"] = .string(value)
        }
        if let description {
            object["description"] = .string(description)
        }
        if let help {
            object["help"] = .string(help)
        }
        if let identifier {
            object["identifier"] = .string(identifier)
        }
        if let frame {
            object["frame"] = .object([
                "x": .double(frame.origin.x),
                "y": .double(frame.origin.y),
                "w": .double(frame.width),
                "h": .double(frame.height),
            ])
        }
        if let enabled {
            object["enabled"] = .bool(enabled)
        }
        if let selected {
            object["selected"] = .bool(selected)
        }
        if let focused {
            object["focused"] = .bool(focused)
        }
        return .object(object)
    }
}

private struct AXSnapshotContext {
    let maxDepth: Int
    let maxElements: Int
    let maxChildrenPerElement: Int
    let deadline: Date
    let messagingTimeout: Float
    var nextElementIndex = 1
    var elements: [AXSnapshotElement] = []
    var elementRefsById: [String: AXUIElement] = [:]
    var warnings: [String] = []
    var hitDepthLimit = false
    var hitElementLimit = false
    var hitTimeout = false
}

private struct AXWindowSnapshot {
    let id: String
    let window: WindowEntry
    let createdAt: Date
    let elementsById: [String: AXSnapshotElement]
    let elementRefsById: [String: AXUIElement]
}

final class ComputerUseController {
    static let shared = ComputerUseController()

    private let shellCommands: Set<String> = ["zsh", "bash", "fish", "sh", "dash"]
    private let riskyCommands: Set<String> = [
        "claude", "codex", "vim", "nvim", "emacs", "nano", "less", "more", "top",
        "ssh", "python", "python3", "node", "bun", "npm", "pnpm", "yarn", "swift",
    ]
    private let axSnapshotLock = NSLock()
    private let axSnapshotTTL: TimeInterval = 300
    private let maxAXSnapshotCacheCount = 30
    private var axSnapshotsById: [String: AXWindowSnapshot] = [:]

    private init() {}

    func demoTerminal(params: JSON?) throws -> JSON {
        try runTerminalText(
            params: params,
            title: "Terminal computer-use demo",
            defaultText: Self.defaultTypedText(),
            requireText: false,
            defaultTreatment: .execute
        )
    }

    func prepare(params: JSON?) throws -> JSON {
        try runTerminalText(
            params: params,
            title: "Prepare computer action",
            defaultText: nil,
            requireText: false,
            defaultTreatment: .observe
        )
    }

    func windowState(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let mode = try windowStateMode(params)
        let includeAX = mode == "ax" || mode == "both"
        let shouldCapture = params?["capture"]?.boolValue ?? (mode == "both" || mode == "screenshot")
        let maxDepth = max(1, min(params?["maxDepth"]?.intValue ?? 8, 14))
        let maxElements = max(1, min(params?["maxElements"]?.intValue ?? 250, 1_000))
        let timeoutMs = max(150, min(params?["timeoutMs"]?.intValue ?? 1_200, 5_000))
        let window = try CaptureController.shared.resolveWindow(params: params)
        let snapshotId = Self.snapshotId()
        var run: RunSession?

        do {
            if shouldCapture {
                let createdRun = try RunStore.shared.createRun(
                    title: "Window state \(window.app)",
                    source: source,
                    surfaces: [.window(window)]
                )
                run = createdRun
                _ = try RunStore.shared.markRunning(
                    id: createdRun.id,
                    summary: "Inspecting window state",
                    data: [
                        "action": .string("windowState"),
                        "snapshotId": .string(snapshotId),
                        "mode": .string(mode),
                        "wid": .int(Int(window.wid)),
                        "app": .string(window.app),
                    ]
                )
            }

            var elements: [AXSnapshotElement] = []
            var warnings: [String] = []
            if includeAX {
                let context = try axSnapshot(
                    window: window,
                    maxDepth: maxDepth,
                    maxElements: maxElements,
                    timeoutMs: timeoutMs
                )
                elements = context.elements
                storeAXSnapshot(
                    id: snapshotId,
                    window: window,
                    elements: context.elements,
                    elementRefsById: context.elementRefsById
                )
                warnings.append(contentsOf: context.warnings)
                if context.hitDepthLimit {
                    warnings.append("AX traversal reached maxDepth \(maxDepth)")
                }
                if context.hitElementLimit {
                    warnings.append("AX traversal reached maxElements \(maxElements)")
                }
                if context.hitTimeout {
                    warnings.append("AX traversal reached timeoutMs \(timeoutMs)")
                }
            } else {
                warnings.append("AX traversal skipped for mode \(mode)")
            }

            var artifact: JSON?
            if shouldCapture, let activeRun = run {
                let captured = try CaptureController.shared.screenshotWindow(params: .object([
                    "runId": .string(activeRun.id),
                    "source": .string(source),
                    "wid": .int(Int(window.wid)),
                    "filename": .string("window-state-\(window.wid)-\(Self.fileTimestamp()).png"),
                ]))
                artifact = captured["artifact"]
                let completed = try RunStore.shared.complete(
                    id: activeRun.id,
                    summary: "Captured window state",
                    data: [
                        "snapshotId": .string(snapshotId),
                        "mode": .string(mode),
                        "elementCount": .int(elements.count),
                        "captured": .bool(artifact != nil),
                    ]
                )
                run = completed
            }

            var object: [String: JSON] = [
                "ok": .bool(true),
                "snapshotId": .string(snapshotId),
                "target": Encoders.window(window),
                "mode": .string(mode),
                "elements": .array(elements.map(\.json)),
                "elementCount": .int(elements.count),
                "treeMarkdown": .string(treeMarkdown(for: elements)),
                "warnings": .array(warnings.map { .string($0) }),
            ]
            if let artifact {
                object["artifact"] = artifact
            }
            if let run {
                object["run"] = run.json
            }
            return .object(object)
        } catch {
            if let run {
                _ = try? RunStore.shared.fail(
                    id: run.id,
                    summary: "Window state inspection failed",
                    data: [
                        "snapshotId": .string(snapshotId),
                        "wid": .int(Int(window.wid)),
                        "error": .string(error.localizedDescription),
                    ]
                )
            }
            throw error
        }
    }

    func elementAction(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let wantsBackgroundSafe = backgroundSafeRequested(params)
        let snapshotId = try requiredString(params, keys: ["snapshotId", "snapshot-id", "snapshot"])
        let elementId = try requiredString(params, keys: ["elementId", "element-id", "id"])
        let requestedAction = try elementActionName(params)
        let snapshot = try axSnapshot(id: snapshotId)
        guard let element = snapshot.elementRefsById[elementId],
              let elementInfo = snapshot.elementsById[elementId] else {
            throw RouterError.notFound("element \(elementId) in snapshot \(snapshotId)")
        }

        let run = try RunStore.shared.createRun(
            title: "Element action \(requestedAction)",
            source: source,
            surfaces: [.window(snapshot.window)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved AX element action",
                data: [
                    "action": .string("elementAction"),
                    "treatment": .string(treatment.rawValue),
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "requestedAction": .string(requestedAction),
                    "backgroundSafe": .bool(wantsBackgroundSafe),
                    "wid": .int(Int(snapshot.window.wid)),
                    "app": .string(snapshot.window.app),
                ]
            )

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: snapshot.window.wid,
                prefix: "element-action-before"
            )

            var performed = false
            var focused = false
            var axAction: String?
            if treatment.focusesWindow && !wantsBackgroundSafe {
                focused = try focus(window: snapshot.window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused element target window",
                    data: ["wid": .int(Int(snapshot.window.wid)), "focused": .bool(focused)]
                )
            }

            if requestedAction == "focus" {
                if wantsBackgroundSafe && treatment.focusesWindow {
                    throw RouterError.custom("AX focus is not background-safe; omit backgroundSafe/noFocus to focus the element")
                }
                if treatment.focusesWindow {
                    try focusAXElement(element)
                    performed = true
                    _ = try RunStore.shared.appendTrace(
                        id: run.id,
                        kind: "computer.axFocused",
                        summary: "Focused AX element",
                        data: [
                            "snapshotId": .string(snapshotId),
                            "elementId": .string(elementId),
                        ]
                    )
                }
            } else if treatment.performsPointerAction {
                let action = try axActionName(for: requestedAction, elementInfo: elementInfo)
                axAction = action
                try performAXAction(element, action: action)
                performed = true
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.axElementAction",
                    summary: "Performed AX element action",
                    data: [
                        "snapshotId": .string(snapshotId),
                        "elementId": .string(elementId),
                        "requestedAction": .string(requestedAction),
                        "axAction": .string(action),
                    ]
                )
                usleep(180_000)
            }

            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: snapshot.window.wid,
                prefix: "element-action-after"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: performed ? "Completed AX element action" : "Staged AX element action",
                data: [
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "requestedAction": .string(requestedAction),
                    "performed": .bool(performed),
                    "focused": .bool(focused),
                    "backgroundSafe": .bool(wantsBackgroundSafe),
                ]
            )

            return elementActionResponse(
                run: completed,
                snapshot: snapshot,
                element: elementInfo,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                requestedAction: requestedAction,
                axAction: axAction,
                performed: performed,
                focused: focused
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "AX element action failed",
                data: [
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func typeElement(params: JSON?) throws -> JSON {
        try typeElement(params: params, actionName: "typeElement")
    }

    func setValue(params: JSON?) throws -> JSON {
        try typeElement(params: params, actionName: "setValue")
    }

    func pressKey(params: JSON?) throws -> JSON {
        try keyboardAction(params: params, actionName: "pressKey", requiresModifier: false)
    }

    func hotkey(params: JSON?) throws -> JSON {
        try keyboardAction(params: params, actionName: "hotkey", requiresModifier: true)
    }

    func verify(params: JSON?) throws -> JSON {
        let mode = params?["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? params?["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "ocr"
        if mode.hasPrefix("ax") || params?["snapshotId"]?.stringValue != nil || params?["snapshot-id"]?.stringValue != nil {
            return try verifyAX(params: params, mode: mode)
        }
        return try CaptureController.shared.verifyVisual(params: params)
    }

    private func typeElement(params: JSON?, actionName: String) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let wantsBackgroundSafe = backgroundSafeRequested(params)
        let append = params?["append"]?.boolValue ?? false
        let typeIntervalMs = axTypeIntervalMs(params: params)
        let snapshotId = try requiredString(params, keys: ["snapshotId", "snapshot-id", "snapshot"])
        let elementId = try requiredString(params, keys: ["elementId", "element-id", "id"])
        let text = try requiredValueString(params, keys: ["text", "value"])
        let snapshot = try axSnapshot(id: snapshotId)
        guard let element = snapshot.elementRefsById[elementId],
              let elementInfo = snapshot.elementsById[elementId] else {
            throw RouterError.notFound("element \(elementId) in snapshot \(snapshotId)")
        }

        let run = try RunStore.shared.createRun(
            title: actionName == "setValue" ? "Set element value" : "Type element text",
            source: source,
            surfaces: [.window(snapshot.window)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved AX text element",
                data: [
                    "action": .string(actionName),
                    "treatment": .string(treatment.rawValue),
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "characters": .int(text.count),
                    "append": .bool(append),
                    "backgroundSafe": .bool(wantsBackgroundSafe),
                    "wid": .int(Int(snapshot.window.wid)),
                    "app": .string(snapshot.window.app),
                ]
            )

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: snapshot.window.wid,
                prefix: "element-text-before"
            )

            var focused = false
            var result: AXTextInsertionResult?
            if treatment.focusesWindow && !wantsBackgroundSafe {
                focused = try focus(window: snapshot.window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused element text target window",
                    data: ["wid": .int(Int(snapshot.window.wid)), "focused": .bool(focused)]
                )
                try? focusAXElement(element)
            }

            if treatment.insertsText {
                result = try setElementValueViaAX(
                    text,
                    element: element,
                    elementInfo: elementInfo,
                    append: append,
                    typeIntervalMs: typeIntervalMs
                )
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.axElementTyped",
                    summary: actionName == "setValue" ? "Set AX element value" : "Typed AX element text",
                    data: [
                        "snapshotId": .string(snapshotId),
                        "elementId": .string(elementId),
                        "characters": .int(text.count),
                        "append": .bool(append),
                        "result": result?.json ?? .null,
                    ]
                )
                usleep(180_000)
            }

            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: snapshot.window.wid,
                prefix: "element-text-after"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: result == nil ? "Staged AX element text" : "Completed AX element text",
                data: [
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "typed": .bool(result != nil),
                    "focused": .bool(focused),
                    "append": .bool(append),
                    "backgroundSafe": .bool(wantsBackgroundSafe),
                ]
            )

            return elementTextResponse(
                actionName: actionName,
                run: completed,
                snapshot: snapshot,
                element: elementInfo,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                text: text,
                append: append,
                result: result,
                focused: focused
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "AX element text failed",
                data: [
                    "snapshotId": .string(snapshotId),
                    "elementId": .string(elementId),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    private func keyboardAction(params: JSON?, actionName: String, requiresModifier: Bool) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let allowGlobal = params?["allowGlobal"]?.boolValue == true
            || params?["allow-global"]?.boolValue == true
            || params?["global"]?.boolValue == true
        let request = try keyboardRequest(params: params, requiresModifier: requiresModifier)
        let count = max(1, min(params?["count"]?.intValue ?? 1, 20))
        let delayMs = max(0, min(params?["delayMs"]?.numericDouble ?? params?["delay-ms"]?.numericDouble ?? 80, 1_000))
        let hasExplicitTarget = hasKeyboardTarget(params)
        let window = hasExplicitTarget ? try CaptureController.shared.resolveWindow(params: params) : nil

        if treatment.focusesWindow, window == nil, !allowGlobal {
            throw RouterError.custom("computer.\(actionName) requires wid, app, or session for present/execute; pass allowGlobal true to post to the focused system target")
        }

        let shouldCapture = params?["capture"]?.boolValue ?? (window != nil)
        let surfaces: [RunSurface] = window.map { [.window($0)] } ?? []
        let title = actionName == "hotkey" ? "Send hotkey" : "Press key"
        let run = try RunStore.shared.createRun(title: title, source: source, surfaces: surfaces)

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved keyboard action",
                data: [
                    "action": .string(actionName),
                    "treatment": .string(treatment.rawValue),
                    "key": .string(request.key),
                    "modifiers": .array(request.modifiers.map { .string($0) }),
                    "count": .int(count),
                    "allowGlobal": .bool(allowGlobal),
                ]
            )

            let before = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "key-before"
                )
            }

            var focused = false
            if treatment.focusesWindow, let window {
                focused = try focus(window: window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused keyboard target window",
                    data: ["wid": .int(Int(window.wid)), "focused": .bool(focused)]
                )
                if treatment == .execute, !focused {
                    throw RouterError.custom("failed to focus window \(window.wid)")
                }
            }

            var sent = false
            var displayName = (request.modifiers + [request.key]).joined(separator: "+")
            if treatment == .execute {
                for index in 0..<count {
                    displayName = try CompanionKeyboardController.shared.send(
                        key: request.key,
                        modifiers: request.modifiers,
                        targetPid: window?.pid
                    )
                    if index < count - 1, delayMs > 0 {
                        usleep(UInt32(delayMs * 1_000))
                    }
                }
                sent = true
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.keySent",
                    summary: "Sent keyboard action",
                    data: [
                        "key": .string(request.key),
                        "modifiers": .array(request.modifiers.map { .string($0) }),
                        "display": .string(displayName),
                        "count": .int(count),
                        "global": .bool(window == nil),
                    ]
                )
                usleep(140_000)
            }

            let after = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "key-after"
                )
            }
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: sent ? "Completed keyboard action" : "Staged keyboard action without posting",
                data: [
                    "sent": .bool(sent),
                    "focused": .bool(focused),
                    "key": .string(request.key),
                    "modifiers": .array(request.modifiers.map { .string($0) }),
                    "count": .int(count),
                    "global": .bool(window == nil && allowGlobal),
                ]
            )

            return keyboardActionResponse(
                action: actionName,
                run: completed,
                target: window,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                key: request.key,
                modifiers: request.modifiers,
                displayName: displayName,
                count: count,
                delayMs: delayMs,
                sent: sent,
                focused: focused,
                global: window == nil && allowGlobal
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Keyboard action failed",
                data: [
                    "action": .string(actionName),
                    "key": .string(request.key),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    private struct ComputerVerificationExpectation {
        let kind: String
        let value: String

        var json: JSON {
            .object([
                "kind": .string(kind),
                "value": .string(value),
            ])
        }
    }

    private func verifyAX(params: JSON?, mode: String) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let expectation = try computerVerificationExpectation(params: params)
        let snapshotId = params?["snapshotId"]?.stringValue
            ?? params?["snapshot-id"]?.stringValue
            ?? params?["snapshot"]?.stringValue
        let elementId = params?["elementId"]?.stringValue
            ?? params?["element-id"]?.stringValue
            ?? params?["id"]?.stringValue

        let run: RunSession
        let target: WindowEntry?
        let text: String
        let elementJSON: JSON?
        let resolvedSnapshotId: String?

        if let snapshotId, !snapshotId.isEmpty {
            let snapshot = try axSnapshot(id: snapshotId)
            target = snapshot.window
            resolvedSnapshotId = snapshot.id
            run = try RunStore.shared.createRun(
                title: "Verify AX state",
                source: source,
                surfaces: [.window(snapshot.window)]
            )

            if let elementId, !elementId.isEmpty {
                guard let element = snapshot.elementsById[elementId] else {
                    throw RouterError.notFound("element \(elementId) in snapshot \(snapshotId)")
                }
                elementJSON = element.json
                text = [
                    element.value,
                    element.title,
                    element.label,
                    element.description,
                    element.help,
                    element.identifier,
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            } else {
                elementJSON = nil
                text = treeMarkdown(for: Array(snapshot.elementsById.values).sorted { $0.path < $1.path })
            }
        } else {
            let window = try CaptureController.shared.resolveWindow(params: params)
            target = window
            resolvedSnapshotId = nil
            run = try RunStore.shared.createRun(
                title: "Verify window accessibility text",
                source: source,
                surfaces: [.window(window)]
            )
            elementJSON = nil
            guard AXIsProcessTrusted() else {
                throw RouterError.custom("Accessibility permission is required for AX verification")
            }
            text = AccessibilityTextExtractor().extract(pid: window.pid, wid: window.wid, minChars: 0)?.fullText ?? ""
        }

        _ = try RunStore.shared.markRunning(
            id: run.id,
            summary: "Verifying AX state",
            data: [
                "mode": .string(mode),
                "expectation": expectation.json,
                "snapshotId": resolvedSnapshotId.map { .string($0) } ?? .null,
                "elementId": elementId.map { .string($0) } ?? .null,
            ]
        )

        let verified = evaluateComputerExpectation(expectation, fullText: text)
        let completed = try RunStore.shared.complete(
            id: run.id,
            summary: verified ? "AX verification passed" : "AX verification failed",
            data: [
                "verified": .bool(verified),
                "mode": .string("ax"),
                "characters": .int(text.count),
            ]
        )

        var object: [String: JSON] = [
            "ok": .bool(true),
            "verified": .bool(verified),
            "mode": .string("ax"),
            "expectation": expectation.json,
            "fullText": .string(text),
            "run": completed.json,
        ]
        if let target {
            object["target"] = Encoders.window(target)
        }
        if let resolvedSnapshotId {
            object["snapshotId"] = .string(resolvedSnapshotId)
        }
        if let elementId {
            object["elementId"] = .string(elementId)
        }
        if let elementJSON {
            object["element"] = elementJSON
        }
        return .object(object)
    }

    private func computerVerificationExpectation(params: JSON?) throws -> ComputerVerificationExpectation {
        if let value = params?["contains"]?.stringValue
            ?? params?["expected"]?.stringValue
            ?? params?["text"]?.stringValue
            ?? params?["value"]?.stringValue {
            return ComputerVerificationExpectation(kind: "contains", value: value)
        }
        if let value = params?["notContains"]?.stringValue
            ?? params?["not-contains"]?.stringValue
            ?? params?["absent"]?.stringValue {
            return ComputerVerificationExpectation(kind: "notContains", value: value)
        }
        throw RouterError.missingParam("contains, expected, value, or notContains")
    }

    private func evaluateComputerExpectation(
        _ expectation: ComputerVerificationExpectation,
        fullText: String
    ) -> Bool {
        let haystack = fullText.lowercased()
        let needle = expectation.value.lowercased()
        switch expectation.kind {
        case "notContains":
            return !haystack.contains(needle)
        default:
            return haystack.contains(needle)
        }
    }

    func typeText(params: JSON?) throws -> JSON {
        try runTerminalText(
            params: params,
            title: "Type text",
            defaultText: nil,
            requireText: true,
            defaultTreatment: .execute
        )
    }

    func focusWindow(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .present)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let window = try CaptureController.shared.resolveWindow(params: params)
        let run = try RunStore.shared.createRun(
            title: "Focus \(window.app)",
            source: source,
            surfaces: [.window(window)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved focus target",
                data: [
                    "action": .string("focusWindow"),
                    "treatment": .string(treatment.rawValue),
                    "wid": .int(Int(window.wid)),
                    "app": .string(window.app),
                ]
            )

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "focus-before"
            )

            if !treatment.focusesWindow {
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: "Planned window focus without presenting",
                    data: ["wid": .int(Int(window.wid)), "treatment": .string(treatment.rawValue)]
                )
                return focusResponse(
                    run: completed,
                    target: window,
                    before: before,
                    after: nil,
                    treatment: treatment,
                    focused: false
                )
            }

            let focused = try focus(window: window)
            guard focused else {
                throw RouterError.custom("failed to focus window \(window.wid)")
            }
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "computer.focused",
                summary: "Focused window",
                data: ["wid": .int(Int(window.wid)), "focused": .bool(true)]
            )

            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "focus-after"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: "Focused and verified window",
                data: ["wid": .int(Int(window.wid))]
            )

            return focusResponse(
                run: completed,
                target: window,
                before: before,
                after: after,
                treatment: treatment,
                focused: true
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Window focus failed",
                data: ["error": .string(error.localizedDescription), "wid": .int(Int(window.wid))]
            )
            throw error
        }
    }

    func showCursor(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .present)
        let appearance = CursorAppearance.resolve(params: params)
        let point = cursorPoint(params: params)
        let shouldShow = treatment == .present || treatment == .execute
        let run = try RunStore.shared.createRun(
            title: "Show cursor",
            source: source,
            surfaces: [.cursor(point)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved cursor target",
                data: [
                    "action": .string("showCursor"),
                    "treatment": .string(treatment.rawValue),
                    "x": .double(point.x),
                    "y": .double(point.y),
                    "appearance": appearance.json,
                ]
            )

            if shouldShow {
                if Thread.isMainThread {
                    MouseFinder.shared.showCursor(at: point, appearance: appearance)
                } else {
                    DispatchQueue.main.sync {
                        MouseFinder.shared.showCursor(at: point, appearance: appearance)
                    }
                }
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.cursor.shown",
                    summary: "Showed cursor appearance",
                    data: [
                        "x": .double(point.x),
                        "y": .double(point.y),
                        "appearance": appearance.json,
                    ]
                )
            }

            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: shouldShow ? "Presented cursor appearance" : "Planned cursor appearance without showing",
                data: [
                    "shown": .bool(shouldShow),
                    "treatment": .string(treatment.rawValue),
                    "x": .double(point.x),
                    "y": .double(point.y),
                ]
            )

            var object: [String: JSON] = [
                "ok": .bool(true),
                "action": .string("showCursor"),
                "treatment": .string(treatment.rawValue),
                "shown": .bool(shouldShow),
                "run": completed.json,
                "cursor": cursorJSON(point),
                "appearance": appearance.json,
            ]
            attachBackgroundSafety(
                backgroundSafetyReceipt(
                    route: shouldShow ? "overlay.cursor" : stagedRoute(for: treatment),
                    backgroundEligible: true
                ),
                to: &object
            )
            return .object(object)
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Cursor appearance failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func magicCursor(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .present)
        let appearance = CursorAppearance.resolve(params: markerDefaultParams(params))
        let text = params?["text"]?.stringValue
        let window = try? CaptureController.shared.resolveWindow(params: params)
        let endPoint = clickPoint(params: params, window: window) ?? cursorPointCG(params: params)
        let startPoint = startPoint(params: params, window: window, endPoint: endPoint)
        let shouldShow = treatment == .present || treatment == .execute
        let run = try RunStore.shared.createRun(
            title: "Magic cursor",
            source: source,
            surfaces: window.map { [.window($0), .cursor(endPoint)] } ?? [.cursor(endPoint)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved magic cursor path",
                data: [
                    "action": .string("magicCursor"),
                    "treatment": .string(treatment.rawValue),
                    "from": cursorJSON(startPoint),
                    "to": cursorJSON(endPoint),
                    "appearance": appearance.json,
                    "willUseAX": .bool(treatment.insertsText && text?.isEmpty == false),
                ]
            )

            if shouldShow {
                let overlayStart = overlayPoint(fromCGPoint: startPoint)
                let overlayEnd = overlayPoint(fromCGPoint: endPoint)
                let captionTopLeft = overlayCaptionTopLeft(
                    params: params,
                    window: window,
                    fallbackPoint: endPoint
                )
                try onMain {
                    MouseFinder.shared.animateCursor(
                        from: overlayStart,
                        to: overlayEnd,
                        appearance: appearance,
                        captionTopLeft: captionTopLeft
                    )
                }
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.cursor.animated",
                    summary: "Animated ghost cursor without moving the hardware pointer",
                    data: [
                        "from": cursorJSON(startPoint),
                        "to": cursorJSON(endPoint),
                        "overlayFrom": cursorJSON(overlayStart),
                        "overlayTo": cursorJSON(overlayEnd),
                    ]
                )
            }

            var typedText: String?
            var axResult: AXTextInsertionResult?
            if treatment.insertsText, let text, !text.isEmpty {
                guard let window else {
                    throw RouterError.custom("AX text insertion requires a target window")
                }
                let delaySeconds = max(0.25, min(1.8, appearance.duration * 0.72))
                usleep(UInt32(delaySeconds * 1_000_000))
                axResult = try setTextViaAX(
                    text,
                    window: window,
                    targetPoint: endPoint,
                    append: params?["append"]?.boolValue == true,
                    typeIntervalMs: axTypeIntervalMs(params: params)
                )
                typedText = text
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.axTextSet",
                    summary: "Set editable AX value without focusing the app",
                    data: [
                        "result": axResult?.json ?? .null
                    ]
                )
            }

            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: typedText == nil
                    ? "Presented magic cursor path"
                    : "Animated magic cursor and set AX text without focusing",
                data: [
                    "shown": .bool(shouldShow),
                    "typed": .bool(typedText != nil),
                    "focused": .bool(false),
                    "transport": .string(typedText == nil ? "overlay" : "ax"),
                ]
            )

            var object: [String: JSON] = [
                "ok": .bool(true),
                "action": .string("magicCursor"),
                "treatment": .string(treatment.rawValue),
                "shown": .bool(shouldShow),
                "focused": .bool(false),
                "run": completed.json,
                "from": cursorJSON(startPoint),
                "cursor": cursorJSON(endPoint),
                "appearance": appearance.json,
                "transport": .string(typedText == nil ? "overlay" : "ax"),
            ]
            if let window {
                object["target"] = Encoders.window(window)
            }
            if let typedText {
                object["typedText"] = .string(typedText)
            }
            if let axResult {
                object["ax"] = axResult.json
            }
            let route = typedText == nil
                ? (shouldShow ? "overlay.cursor" : stagedRoute(for: treatment))
                : "ax.setValue"
            attachBackgroundSafety(
                backgroundSafetyReceipt(
                    route: route,
                    backgroundEligible: true
                ),
                to: &object
            )
            return .object(object)
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Magic cursor action failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func launchApp(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .present)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let appName = try appNameParam(params)
        let title = params?["title"]?.stringValue
        let run = try RunStore.shared.createRun(
            title: "Launch \(appName)",
            source: source,
            surfaces: []
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved app launch target",
                data: [
                    "action": .string("launchApp"),
                    "app": .string(appName),
                    "treatment": .string(treatment.rawValue),
                ]
            )

            let existing = windowForApp(appName, title: title)
            if treatment == .observe || treatment == .stage {
                if let existing {
                    _ = try RunStore.shared.appendSurfaces(id: run.id, surfaces: [.window(existing)])
                }
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: existing == nil ? "Staged app launch" : "Observed running app",
                    data: [
                        "app": .string(appName),
                        "running": .bool(existing != nil),
                        "treatment": .string(treatment.rawValue),
                    ]
                )
                return appResponse(
                    action: "launchApp",
                    run: completed,
                    appName: appName,
                    target: existing,
                    before: nil,
                    after: nil,
                    treatment: treatment,
                    launched: false,
                    focused: false,
                    typedText: nil,
                    clicked: nil
                )
            }

            let launched = try openOrActivateApp(params: params, appName: appName)
            guard launched else {
                throw RouterError.custom("Unable to launch app '\(appName)'")
            }

            guard let window = waitForWindow(app: appName, title: title, timeout: 4.0) else {
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: "Launched app but no window was discovered yet",
                    data: ["app": .string(appName), "launched": .bool(true)]
                )
                return appResponse(
                    action: "launchApp",
                    run: completed,
                    appName: appName,
                    target: nil,
                    before: nil,
                    after: nil,
                    treatment: treatment,
                    launched: true,
                    focused: false,
                    typedText: nil,
                    clicked: nil
                )
            }
            _ = try RunStore.shared.appendSurfaces(id: run.id, surfaces: [.window(window)])

            let focused = try focus(window: window)
            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "app-launch"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: "Launched and focused app",
                data: [
                    "app": .string(appName),
                    "wid": .int(Int(window.wid)),
                    "focused": .bool(focused),
                ]
            )
            return appResponse(
                action: "launchApp",
                run: completed,
                appName: appName,
                target: window,
                before: nil,
                after: after?["artifact"],
                treatment: treatment,
                launched: true,
                focused: focused,
                typedText: nil,
                clicked: nil
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "App launch failed",
                data: ["app": .string(appName), "error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func typeWindowText(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .execute)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let shouldPressEnter = params?["enter"]?.boolValue ?? params?["send"]?.boolValue ?? false
        guard let text = params?["text"]?.stringValue, !text.isEmpty else {
            throw RouterError.missingParam("text")
        }
        let window = try CaptureController.shared.resolveWindow(params: params)
        let run = try RunStore.shared.createRun(
            title: "Type into \(window.app)",
            source: source,
            surfaces: [.window(window)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved app text target",
                data: [
                    "action": .string("typeWindowText"),
                    "treatment": .string(treatment.rawValue),
                    "wid": .int(Int(window.wid)),
                    "app": .string(window.app),
                    "characters": .int(text.count),
                ]
            )

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "app-type-before"
            )

            if !treatment.focusesWindow && !treatment.insertsText {
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: "Staged app text insertion without typing",
                    data: ["wid": .int(Int(window.wid)), "text": .string(text)]
                )
                return appResponse(
                    action: "typeWindowText",
                    run: completed,
                    appName: window.app,
                    target: window,
                    before: before?["artifact"],
                    after: nil,
                    treatment: treatment,
                    launched: false,
                    focused: false,
                    typedText: text,
                    clicked: nil
                )
            }

            let focused = try focus(window: window)
            guard focused else {
                throw RouterError.custom("failed to focus window \(window.wid)")
            }
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "computer.focused",
                summary: "Focused app window",
                data: ["wid": .int(Int(window.wid))]
            )

            if let point = clickPoint(params: params, window: window), treatment.insertsText {
                try postMouseClick(at: point, rawButton: params?["button"]?.stringValue)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.clicked",
                    summary: "Clicked app text target",
                    data: clickJSON(point, button: params?["button"]?.stringValue)
                )
                usleep(120_000)
            }

            if treatment.insertsText {
                let typedCharacters = try CompanionKeyboardController.shared.typeText(
                    text,
                    targetPid: window.pid
                )
                if shouldPressEnter {
                    _ = try CompanionKeyboardController.shared.send(
                        key: "enter",
                        modifiers: [],
                        targetPid: window.pid
                    )
                }
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.typed",
                    summary: shouldPressEnter ? "Typed app text and pressed Enter" : "Typed app text",
                    data: [
                        "wid": .int(Int(window.wid)),
                        "characters": .int(typedCharacters),
                        "pressedEnter": .bool(shouldPressEnter),
                    ]
                )
            }

            usleep(180_000)
            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "app-type-after"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: treatment.insertsText ? "Completed app text action" : "Presented app text target",
                data: [
                    "wid": .int(Int(window.wid)),
                    "typed": .bool(treatment.insertsText),
                    "pressedEnter": .bool(shouldPressEnter),
                ]
            )
            return appResponse(
                action: "typeWindowText",
                run: completed,
                appName: window.app,
                target: window,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                launched: false,
                focused: focused,
                typedText: text,
                clicked: nil
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "App text action failed",
                data: ["error": .string(error.localizedDescription), "wid": .int(Int(window.wid))]
            )
            throw error
        }
    }

    func click(params: JSON?) throws -> JSON {
        try clickAction(params: params, actionName: "click", buttonOverride: nil, countOverride: nil)
    }

    func doubleClick(params: JSON?) throws -> JSON {
        try clickAction(params: params, actionName: "doubleClick", buttonOverride: nil, countOverride: 2)
    }

    func rightClick(params: JSON?) throws -> JSON {
        try clickAction(params: params, actionName: "rightClick", buttonOverride: "right", countOverride: nil)
    }

    private func clickAction(
        params: JSON?,
        actionName: String,
        buttonOverride: String?,
        countOverride: Int?
    ) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let requestedTransport = clickTransport(params)
        let buttonName = buttonOverride ?? params?["button"]?.stringValue
        let clickCount = clickCount(params: params, defaultValue: countOverride ?? 1)
        let delayMs = pointerDelayMs(params: params, defaultValue: 90)
        let noFocus = params?["noFocus"]?.boolValue == true
            || params?["no-focus"]?.boolValue == true
            || requestedTransport == "ax"
            || requestedTransport == "accessibility"
        let window = try? CaptureController.shared.resolveWindow(params: params)
        let point = clickPoint(params: params, window: window) ?? cursorPoint(params: params)
        let run = try RunStore.shared.createRun(
            title: actionName == "doubleClick" ? "Double click" : actionName == "rightClick" ? "Right click" : "Click",
            source: source,
            surfaces: window.map { [.window($0), .cursor(point)] } ?? [.cursor(point)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved click target",
                data: [
                    "action": .string(actionName),
                    "treatment": .string(treatment.rawValue),
                    "point": cursorJSON(point),
                    "button": .string(normalizedMouseButton(buttonName)),
                    "count": .int(clickCount),
                    "transport": .string(requestedTransport),
                    "noFocus": .bool(noFocus),
                ]
            )

            let before = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "click-before"
                )
            }

            var clicked = false
            var focused = false
            var transportUsed = "none"
            var axResult: AXPressResult?
            if treatment.performsPointerAction {
                let canTryAX = window != nil
                    && normalizedMouseButton(buttonName) == "left"
                    && clickCount == 1
                    && requestedTransport != "pointer"
                    && requestedTransport != "mouse"

                if canTryAX, let targetWindow = window {
                    do {
                        axResult = try pressViaAX(
                            window: targetWindow,
                            targetPoint: point,
                            label: axPressLabel(params)
                        )
                        clicked = axResult?.performed == true
                        transportUsed = "ax"
                        _ = try RunStore.shared.appendTrace(
                            id: run.id,
                            kind: "computer.axPressed",
                            summary: "Performed AXPress without focusing or moving the hardware pointer",
                            data: [
                                "point": cursorJSON(point),
                                "result": axResult?.json ?? .null,
                            ]
                        )
                        usleep(180_000)
                    } catch {
                        if requestedTransport == "ax" || requestedTransport == "accessibility" || noFocus {
                            throw error
                        }
                        _ = try RunStore.shared.appendTrace(
                            id: run.id,
                            kind: "computer.axPress.skipped",
                            summary: "AXPress was unavailable; falling back to pointer click",
                            data: ["error": .string(error.localizedDescription)]
                        )
                    }
                }

                if !clicked {
                    if noFocus {
                        throw RouterError.custom("No AX press target was available and pointer fallback is disabled")
                    }
                    if let window, treatment.focusesWindow {
                        focused = try focus(window: window)
                        _ = try RunStore.shared.appendTrace(
                            id: run.id,
                            kind: "computer.focused",
                            summary: "Focused window before pointer click fallback",
                            data: ["wid": .int(Int(window.wid)), "focused": .bool(focused)]
                        )
                    }
                    try postMouseClick(at: point, rawButton: buttonName, count: clickCount, delayMs: delayMs)
                    clicked = true
                    transportUsed = "pointer"
                    _ = try RunStore.shared.appendTrace(
                        id: run.id,
                        kind: "computer.clicked",
                        summary: "Posted mouse click",
                        data: clickJSON(point, button: buttonName, count: clickCount)
                    )
                    usleep(180_000)
                }
            }

            let after = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "click-after"
                )
            }
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: clicked ? "Completed click action" : "Staged click without posting",
                data: [
                    "clicked": .bool(clicked),
                    "point": cursorJSON(point),
                    "focused": .bool(focused),
                    "transport": .string(transportUsed),
                    "button": .string(normalizedMouseButton(buttonName)),
                    "count": .int(clickCount),
                ]
            )
            return clickResponse(
                action: actionName,
                run: completed,
                target: window,
                point: point,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                clicked: clicked,
                button: buttonName,
                count: clickCount,
                transport: transportUsed,
                focused: focused,
                axResult: axResult
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Click action failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func scroll(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let window = try? CaptureController.shared.resolveWindow(params: params)
        let point = clickPoint(params: params, window: window) ?? cursorPoint(params: params)
        let delta = scrollDelta(params: params)
        let count = pointerCount(params: params, defaultValue: 1, maxValue: 30)
        let delayMs = pointerDelayMs(params: params, defaultValue: 80)
        let run = try RunStore.shared.createRun(
            title: "Scroll",
            source: source,
            surfaces: window.map { [.window($0), .cursor(point)] } ?? [.cursor(point)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved scroll target",
                data: [
                    "action": .string("scroll"),
                    "treatment": .string(treatment.rawValue),
                    "point": cursorJSON(point),
                    "delta": scrollJSON(delta),
                    "count": .int(count),
                ]
            )

            let before = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "scroll-before"
                )
            }

            var focused = false
            var scrolled = false
            if treatment.focusesWindow, let window {
                focused = try focus(window: window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused window before scroll",
                    data: ["wid": .int(Int(window.wid)), "focused": .bool(focused)]
                )
            }

            if treatment.performsPointerAction {
                try postMouseScroll(at: point, deltaX: delta.x, deltaY: delta.y, count: count, delayMs: delayMs)
                scrolled = true
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.scrolled",
                    summary: "Posted scroll wheel events",
                    data: [
                        "point": cursorJSON(point),
                        "delta": scrollJSON(delta),
                        "count": .int(count),
                    ]
                )
                usleep(160_000)
            }

            let after = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "scroll-after"
                )
            }
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: scrolled ? "Completed scroll action" : "Staged scroll without posting",
                data: [
                    "scrolled": .bool(scrolled),
                    "point": cursorJSON(point),
                    "delta": scrollJSON(delta),
                    "focused": .bool(focused),
                    "count": .int(count),
                ]
            )

            return pointerActionResponse(
                action: "scroll",
                run: completed,
                target: window,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                focused: focused,
                performedKey: "scrolled",
                performed: scrolled,
                point: point,
                from: nil,
                to: nil,
                delta: delta,
                button: nil,
                count: count,
                transport: "pointer"
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Scroll action failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func drag(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .stage)
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let window = try? CaptureController.shared.resolveWindow(params: params)
        let toPoint = dragEndPoint(params: params, window: window)
        let fromPoint = dragStartPoint(params: params, window: window, fallback: toPoint)
        let buttonName = params?["button"]?.stringValue
        let durationMs = dragDurationMs(params: params)
        let steps = dragSteps(params: params)
        let run = try RunStore.shared.createRun(
            title: "Drag",
            source: source,
            surfaces: window.map { [.window($0), .cursor(fromPoint), .cursor(toPoint)] } ?? [.cursor(fromPoint), .cursor(toPoint)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Resolved drag target",
                data: [
                    "action": .string("drag"),
                    "treatment": .string(treatment.rawValue),
                    "from": cursorJSON(fromPoint),
                    "to": cursorJSON(toPoint),
                    "button": .string(normalizedMouseButton(buttonName)),
                    "durationMs": .double(durationMs),
                    "steps": .int(steps),
                ]
            )

            let before = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "drag-before"
                )
            }

            var focused = false
            var dragged = false
            if treatment.focusesWindow, let window {
                focused = try focus(window: window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused window before drag",
                    data: ["wid": .int(Int(window.wid)), "focused": .bool(focused)]
                )
            }

            if treatment.performsPointerAction {
                try postMouseDrag(
                    from: fromPoint,
                    to: toPoint,
                    rawButton: buttonName,
                    durationMs: durationMs,
                    steps: steps
                )
                dragged = true
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.dragged",
                    summary: "Posted mouse drag",
                    data: [
                        "from": cursorJSON(fromPoint),
                        "to": cursorJSON(toPoint),
                        "button": .string(normalizedMouseButton(buttonName)),
                        "durationMs": .double(durationMs),
                        "steps": .int(steps),
                    ]
                )
                usleep(180_000)
            }

            let after = try window.flatMap { target in
                try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: target.wid,
                    prefix: "drag-after"
                )
            }
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: dragged ? "Completed drag action" : "Staged drag without posting",
                data: [
                    "dragged": .bool(dragged),
                    "from": cursorJSON(fromPoint),
                    "to": cursorJSON(toPoint),
                    "focused": .bool(focused),
                    "button": .string(normalizedMouseButton(buttonName)),
                ]
            )

            return pointerActionResponse(
                action: "drag",
                run: completed,
                target: window,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                focused: focused,
                performedKey: "dragged",
                performed: dragged,
                point: nil,
                from: fromPoint,
                to: toPoint,
                delta: nil,
                button: buttonName ?? "left",
                count: nil,
                transport: "pointer"
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Drag action failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func demoScout(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: .present)
        let appName = params?["app"]?.stringValue ?? params?["name"]?.stringValue ?? "Scout"
        let title = params?["title"]?.stringValue
        let text = params?["text"]?.stringValue
            ?? "Lattices demo warm-up: Scout is open, captured, and ready for memo recording."
        let shouldPressEnter = params?["enter"]?.boolValue ?? params?["send"]?.boolValue ?? false
        let shouldClickComposer = params?["click"]?.boolValue ?? treatment.insertsText
        let shouldCapture = params?["capture"]?.boolValue ?? (treatment != .stage && treatment != .observe)

        let run = try RunStore.shared.createRun(
            title: "Scout demo warm-up",
            source: source,
            surfaces: []
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Starting Scout demo warm-up",
                data: [
                    "app": .string(appName),
                    "treatment": .string(treatment.rawValue),
                    "willType": .bool(treatment.insertsText),
                    "willSend": .bool(shouldPressEnter && treatment.insertsText),
                ]
            )

            if treatment.focusesWindow || treatment.insertsText {
                guard try openOrActivateApp(params: params, appName: appName) else {
                    throw RouterError.custom("Unable to launch app '\(appName)'")
                }
            }

            guard let window = waitForWindow(app: appName, title: title, timeout: 4.0)
                ?? windowForApp(appName, title: title) else {
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: "Scout app launch staged; no window discovered",
                    data: ["app": .string(appName)]
                )
                return appResponse(
                    action: "demoScout",
                    run: completed,
                    appName: appName,
                    target: nil,
                    before: nil,
                    after: nil,
                    treatment: treatment,
                    launched: treatment.focusesWindow,
                    focused: false,
                    typedText: nil,
                    clicked: nil
                )
            }
            _ = try RunStore.shared.appendSurfaces(id: run.id, surfaces: [.window(window)])

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "scout-before"
            )

            var focused = false
            if treatment.focusesWindow || treatment.insertsText {
                focused = try focus(window: window)
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused Scout window",
                    data: ["wid": .int(Int(window.wid)), "focused": .bool(focused)]
                )
            }
            if treatment.insertsText && !focused {
                throw RouterError.custom("failed to focus Scout window \(window.wid)")
            }

            var clicked = false
            if shouldClickComposer && treatment.insertsText {
                let point = clickPoint(params: params, window: window)
                    ?? windowRelativePoint(window, xRatio: 0.5, yRatio: 0.86)
                try postMouseClick(at: point, rawButton: params?["button"]?.stringValue)
                clicked = true
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.clicked",
                    summary: "Clicked likely Scout composer area",
                    data: clickJSON(point, button: params?["button"]?.stringValue)
                )
                usleep(140_000)
            }

            if treatment.insertsText {
                let typedCharacters = try CompanionKeyboardController.shared.typeText(
                    text,
                    targetPid: window.pid
                )
                if shouldPressEnter {
                    _ = try CompanionKeyboardController.shared.send(
                        key: "enter",
                        modifiers: [],
                        targetPid: window.pid
                    )
                }
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.typed",
                    summary: shouldPressEnter ? "Typed Scout message and pressed Enter" : "Typed Scout message draft",
                    data: [
                        "characters": .int(typedCharacters),
                        "pressedEnter": .bool(shouldPressEnter),
                        "text": .string(text),
                    ]
                )
                usleep(220_000)
            }

            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: window.wid,
                prefix: "scout-after"
            )
            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: treatment.insertsText ? "Completed Scout demo warm-up" : "Presented Scout demo target",
                data: [
                    "app": .string(appName),
                    "wid": .int(Int(window.wid)),
                    "focused": .bool(focused),
                    "typed": .bool(treatment.insertsText),
                    "clicked": .bool(clicked),
                    "sent": .bool(shouldPressEnter && treatment.insertsText),
                ]
            )
            return appResponse(
                action: "demoScout",
                run: completed,
                appName: appName,
                target: window,
                before: before?["artifact"],
                after: after?["artifact"],
                treatment: treatment,
                launched: treatment.focusesWindow || treatment.insertsText,
                focused: focused,
                typedText: treatment.insertsText ? text : nil,
                clicked: clicked
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Scout demo warm-up failed",
                data: ["app": .string(appName), "error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    private func runTerminalText(
        params: JSON?,
        title: String,
        defaultText: String?,
        requireText: Bool,
        defaultTreatment: ComputerTreatment
    ) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let treatment = ComputerTreatment.resolve(params: params, defaultValue: defaultTreatment)
        let shouldPressEnter = params?["enter"]?.boolValue ?? false
        let shouldCapture = params?["capture"]?.boolValue ?? true
        let transportPreference = params?["transport"]?.stringValue?.lowercased() ?? "auto"
        let typedText = params?["text"]?.stringValue ?? defaultText ?? ""
        if requireText && typedText.isEmpty {
            throw RouterError.missingParam("text")
        }
        let candidates = terminalCandidates(preferredApp: params?["app"]?.stringValue)

        guard var selected = resolveTerminal(params: params, candidates: candidates) else {
            throw RouterError.notFound("safe terminal window")
        }
        selected = candidateWithTerminalSessionOverride(params: params, selected: selected)
        guard let wid = selected.instance.windowId,
              let window = DesktopModel.shared.windows[wid] else {
            throw RouterError.notFound("window for terminal \(selected.instance.displayName)")
        }
        guard !treatment.insertsText || selected.isSafeForTextInsertion else {
            throw RouterError.custom(
                "selected terminal is not an idle shell; use --dry-run or target a safe shell terminal"
            )
        }
        guard !treatment.insertsText || !shouldPressEnter || selected.isSafeForEnter else {
            throw RouterError.custom(
                "selected terminal is only safe for no-enter text insertion"
            )
        }

        let run = try RunStore.shared.createRun(
            title: title,
            source: source,
            surfaces: [.window(window)]
        )

        do {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Selected terminal target",
                data: [
                    "action": .string("typeText"),
                    "treatment": .string(treatment.rawValue),
                    "wid": .int(Int(wid)),
                    "tty": .string(selected.instance.tty),
                    "score": .int(selected.score),
                    "reason": .string(selected.reason),
                    "candidates": .array(candidates.prefix(8).map(\.json)),
                ]
            )

            let before = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: wid,
                prefix: "terminal-before"
            )

            if !treatment.focusesWindow && !treatment.insertsText {
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: treatment == .stage ? "Staged text insertion without typing" : "Observed terminal target",
                    data: [
                        "wid": .int(Int(wid)),
                        "text": .string(typedText),
                        "treatment": .string(treatment.rawValue),
                    ]
                )
                return response(
                    action: "typeText",
                    run: completed,
                    selected: selected,
                    candidates: candidates,
                    before: before?["artifact"],
                    after: nil,
                    typedText: typedText,
                    treatment: treatment,
                    pressedEnter: false,
                    transport: nil
                )
            }

            var focused = false
            let tmuxAvailable = canUseTmuxTransport(selected: selected, preference: transportPreference)
            if treatment == .present || (treatment == .execute && !tmuxAvailable) {
                focused = try focus(window: window)
                guard focused else {
                    throw RouterError.custom("failed to focus terminal window \(wid)")
                }
                _ = try RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "computer.focused",
                    summary: "Focused terminal window",
                    data: ["wid": .int(Int(wid)), "focused": .bool(true)]
                )
            }

            if !treatment.insertsText {
                let after = try maybeCaptureWindow(
                    shouldCapture: shouldCapture,
                    runId: run.id,
                    source: source,
                    wid: wid,
                    prefix: "terminal-present-after"
                )
                let completed = try RunStore.shared.complete(
                    id: run.id,
                    summary: "Presented terminal target without typing",
                    data: ["wid": .int(Int(wid)), "focused": .bool(focused)]
                )
                return response(
                    action: "typeText",
                    run: completed,
                    selected: selected,
                    candidates: candidates,
                    before: before?["artifact"],
                    after: after?["artifact"],
                    typedText: typedText,
                    treatment: treatment,
                    pressedEnter: false,
                    transport: nil
                )
            }

            let typed = try insertText(
                typedText,
                selected: selected,
                window: window,
                pressEnter: shouldPressEnter,
                transportPreference: transportPreference
            )
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "computer.typed",
                summary: shouldPressEnter ? "Typed text and pressed Enter" : "Typed text without pressing Enter",
                data: [
                    "wid": .int(Int(wid)),
                    "characters": .int(typed.characters),
                    "pressedEnter": .bool(shouldPressEnter),
                    "text": .string(typedText),
                    "transport": .string(typed.transport),
                ]
            )

            usleep(160_000)

            let after = try maybeCaptureWindow(
                shouldCapture: shouldCapture,
                runId: run.id,
                source: source,
                wid: wid,
                prefix: "terminal-after"
            )

            let completed = try RunStore.shared.complete(
                id: run.id,
                summary: "Completed terminal text action",
                data: [
                    "wid": .int(Int(wid)),
                    "typed": .bool(true),
                    "transport": .string(typed.transport),
                ]
            )

            return response(
                action: "typeText",
                run: completed,
                selected: selected,
                candidates: candidates,
                before: before?["artifact"],
                after: after?["artifact"],
                typedText: typedText,
                treatment: treatment,
                pressedEnter: shouldPressEnter,
                transport: typed.transport
            )
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Terminal computer-use demo failed",
                data: ["error": .string(error.localizedDescription), "wid": .int(Int(wid))]
            )
            throw error
        }
    }

    func terminalCandidates(preferredApp: String? = nil) -> [TerminalCandidate] {
        DesktopModel.shared.forcePoll()
        TmuxModel.shared.poll()
        ProcessModel.shared.poll()

        // ProcessModel.poll publishes on the main queue; give the current turn a
        // tiny chance to observe a fresh snapshot before synthesizing.
        if !Thread.isMainThread {
            DispatchQueue.main.sync {}
        }

        let terminals = ProcessModel.shared.synthesizeTerminals()
        let existingWindowIds = Set(terminals.compactMap(\.windowId))
        let candidates = terminals
            .filter { $0.windowId != nil }
            .map { candidate(for: $0, preferredApp: preferredApp) }
            + windowOnlyCandidates(excluding: existingWindowIds, preferredApp: preferredApp)

        return candidates.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.instance.displayName < b.instance.displayName
        }
    }

    private func resolveTerminal(params: JSON?, candidates: [TerminalCandidate]) -> TerminalCandidate? {
        if let terminalSessionId = terminalSessionIdParam(params) {
            if let match = candidates.first(where: { $0.instance.terminalSessionId == terminalSessionId }) {
                return match
            }
        }
        if let wid = params?["wid"]?.uint32Value {
            return candidates.first { $0.instance.windowId == wid }
        }
        if let tty = params?["tty"]?.stringValue {
            return candidates.first { $0.instance.tty == tty }
        }
        return candidates.first { $0.isSafeForTextInsertion }
            ?? candidates.first
    }

    private func terminalSessionIdParam(_ params: JSON?) -> String? {
        for key in ["terminalSessionId", "terminal-session-id", "itermSessionId", "iterm-session-id"] {
            if let value = params?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func candidateWithTerminalSessionOverride(
        params: JSON?,
        selected: TerminalCandidate
    ) -> TerminalCandidate {
        guard let terminalSessionId = terminalSessionIdParam(params) else {
            return selected
        }
        guard selected.instance.app == .iterm2 else {
            return selected
        }
        guard selected.instance.terminalSessionId != terminalSessionId else {
            return selected
        }

        let instance = TerminalInstance(
            tty: selected.instance.tty,
            app: selected.instance.app,
            windowIndex: selected.instance.windowIndex,
            tabIndex: selected.instance.tabIndex,
            isActiveTab: selected.instance.isActiveTab,
            tabTitle: selected.instance.tabTitle,
            terminalSessionId: terminalSessionId,
            processes: selected.instance.processes,
            shellPid: selected.instance.shellPid,
            cwd: selected.instance.cwd,
            tmuxSession: selected.instance.tmuxSession,
            tmuxPaneId: selected.instance.tmuxPaneId,
            windowId: selected.instance.windowId,
            windowTitle: selected.instance.windowTitle
        )

        return TerminalCandidate(
            instance: instance,
            score: selected.score,
            reason: selected.reason.isEmpty ? "iterm-session-override" : "\(selected.reason), iterm-session-override",
            activeCommand: selected.activeCommand
        )
    }

    private func candidate(for instance: TerminalInstance, preferredApp: String?) -> TerminalCandidate {
        var score = 0
        var reasons: [String] = []
        let appName = instance.app?.rawValue ?? ""
        let command = activeCommand(for: instance)

        if instance.windowId != nil {
            score += 25
            reasons.append("has-window")
        }
        if let wid = instance.windowId,
           let window = DesktopModel.shared.windows[wid] {
            if window.zIndex == 0 {
                score += 80
                reasons.append("frontmost-window")
            } else if window.zIndex <= 4 {
                score += 24
                reasons.append("near-front-window")
            }
            if window.isOnScreen {
                score += 8
                reasons.append("on-screen")
            }
        }
        if let preferredApp, !preferredApp.isEmpty, appName.localizedCaseInsensitiveContains(preferredApp) {
            score += 45
            reasons.append("preferred-app")
        } else if appName.localizedCaseInsensitiveContains("iterm") {
            score += 35
            reasons.append("iterm")
        } else if !appName.isEmpty {
            score += 16
            reasons.append(appName)
        }
        if instance.isActiveTab {
            score += 10
            reasons.append("active-tab")
        }
        if let session = instance.tmuxSession, !session.isEmpty {
            score += 14
            reasons.append("tmux:\(session)")
        }
        if let cwd = instance.cwd, cwd.contains("/Users/arach/dev") {
            score += 12
            reasons.append("dev-cwd")
        }
        if let command, shellCommands.contains(command) {
            score += 35
            reasons.append("idle-shell")
        }
        if titleSuggestsShell(instance.windowTitle), instance.processes.isEmpty {
            score += 32
            reasons.append("shell-title")
        }
        if instance.hasClaude {
            score -= 80
            reasons.append("avoid-claude")
        }
        if let command, riskyCommands.contains(command) {
            score -= 40
            reasons.append("avoid-\(command)")
        }

        return TerminalCandidate(
            instance: instance,
            score: score,
            reason: reasons.joined(separator: ", "),
            activeCommand: command
        )
    }

    private func windowOnlyCandidates(
        excluding existingWindowIds: Set<UInt32>,
        preferredApp: String?
    ) -> [TerminalCandidate] {
        DesktopModel.shared.windows.values
            .filter { existingWindowIds.contains($0.wid) == false }
            .filter { terminal(forWindowApp: $0.app) != nil }
            .map { window in
                let app = terminal(forWindowApp: window.app)
                let instance = TerminalInstance(
                    tty: "window:\(window.wid)",
                    app: app,
                    windowIndex: nil,
                    tabIndex: nil,
                    isActiveTab: window.zIndex == 0,
                    tabTitle: nil,
                    terminalSessionId: nil,
                    processes: [],
                    shellPid: nil,
                    cwd: cwdFromTerminalTitle(window.title),
                    tmuxSession: window.latticesSession,
                    tmuxPaneId: nil,
                    windowId: window.wid,
                    windowTitle: window.title
                )
                return candidate(for: instance, preferredApp: preferredApp)
            }
    }

    private func activeCommand(for instance: TerminalInstance) -> String? {
        if let session = instance.tmuxSession,
           let paneId = instance.tmuxPaneId,
           let pane = TmuxModel.shared.sessions
            .first(where: { $0.name == session })?
            .panes
            .first(where: { $0.id == paneId }) {
            return normalizeCommand(pane.currentCommand)
        }
        if let command = instance.processes.last?.comm {
            return normalizeCommand(command)
        }
        if let shellPid = instance.shellPid,
           let command = ProcessModel.shared.processTable[shellPid]?.comm {
            return normalizeCommand(command)
        }
        return nil
    }

    private func normalizeCommand(_ command: String) -> String {
        command.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func terminal(forWindowApp app: String) -> Terminal? {
        if app == "iTerm 2" { return .iterm2 }
        return Terminal(rawValue: app)
    }

    private func cwdFromTerminalTitle(_ title: String) -> String? {
        guard let colon = title.lastIndex(of: ":") else { return nil }
        let suffix = String(title[title.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return nil }
        if suffix == "~" { return NSHomeDirectory() }
        if suffix.hasPrefix("~/") {
            return NSHomeDirectory() + String(suffix.dropFirst())
        }
        if suffix.hasPrefix("/") {
            return suffix
        }
        return nil
    }

    private func titleSuggestsShell(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        if lowered.contains("claude") || lowered.contains("codex") || lowered.contains("vim") || lowered.contains("nvim") {
            return false
        }
        return title.contains("@") && title.contains(":") &&
            (title.contains("~/") || title.contains(":/") || title.hasSuffix(":~"))
    }

    private func focus(window: WindowEntry) throws -> Bool {
        if Thread.isMainThread {
            _ = WindowTiler.focusWindow(wid: window.wid, pid: window.pid)
        } else {
            DispatchQueue.main.sync {
                _ = WindowTiler.focusWindow(wid: window.wid, pid: window.pid)
            }
        }
        return waitForFocusedWindow(wid: window.wid, pid: window.pid)
    }

    private func waitForFocusedWindow(wid: UInt32, pid: Int32, timeout: TimeInterval = 1.4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if focusedWindowId(pid: pid) == wid {
                return true
            }
            usleep(50_000)
        } while Date() < deadline
        return false
    }

    private func focusedWindowId(pid: Int32) -> UInt32? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else {
            return nil
        }

        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focusedRef as! AXUIElement, &wid) == .success else {
            return nil
        }
        return UInt32(wid)
    }

    private func maybeCaptureWindow(
        shouldCapture: Bool,
        runId: String,
        source: String,
        wid: UInt32,
        prefix: String
    ) throws -> JSON? {
        guard shouldCapture else { return nil }
        return try CaptureController.shared.screenshotWindow(params: .object([
            "runId": .string(runId),
            "source": .string(source),
            "wid": .int(Int(wid)),
            "filename": .string("\(prefix)-\(wid)-\(Self.fileTimestamp()).png"),
        ]))
    }

    private func cursorPoint(params: JSON?) -> CGPoint {
        if let x = params?["x"]?.numericDouble,
           let y = params?["y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }
        return NSEvent.mouseLocation
    }

    private func cursorPointCG(params: JSON?) -> CGPoint {
        if let x = params?["x"]?.numericDouble,
           let y = params?["y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }
        return cgPoint(fromOverlayPoint: NSEvent.mouseLocation)
    }

    private func startPoint(params: JSON?, window: WindowEntry?, endPoint: CGPoint) -> CGPoint {
        if let x = params?["fromX"]?.numericDouble ?? params?["from-x"]?.numericDouble,
           let y = params?["fromY"]?.numericDouble ?? params?["from-y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }

        if let window {
            let rawXRatio = params?["fromXRatio"]?.numericDouble
                ?? params?["from-x-ratio"]?.numericDouble
                ?? params?["startXRatio"]?.numericDouble
                ?? params?["start-x-ratio"]?.numericDouble
            let rawYRatio = params?["fromYRatio"]?.numericDouble
                ?? params?["from-y-ratio"]?.numericDouble
                ?? params?["startYRatio"]?.numericDouble
                ?? params?["start-y-ratio"]?.numericDouble
            return windowRelativePoint(
                window,
                xRatio: CGFloat(max(0.0, min(1.0, rawXRatio ?? 0.18))),
                yRatio: CGFloat(max(0.0, min(1.0, rawYRatio ?? 0.26)))
            )
        }

        let current = cgPoint(fromOverlayPoint: NSEvent.mouseLocation)
        if current == endPoint {
            return CGPoint(x: endPoint.x - 320, y: endPoint.y - 180)
        }
        return current
    }

    private func cursorJSON(_ point: CGPoint) -> JSON {
        .object([
            "x": .double(point.x),
            "y": .double(point.y),
        ])
    }

    private func markerDefaultParams(_ params: JSON?) -> JSON {
        var dict: [String: JSON] = [:]
        if case .object(let existing) = params {
            dict = existing
        }
        if dict["style"] == nil && dict["appearance"] == nil && dict["cursorStyle"] == nil {
            dict["style"] = .string("marker")
        }
        if dict["durationMs"] == nil && dict["duration-ms"] == nil {
            dict["durationMs"] = .int(1800)
        }
        if dict["color"] == nil {
            dict["color"] = .string("pearl")
        }
        if dict["shape"] == nil {
            dict["shape"] = .string("arrow")
        }
        if dict["size"] == nil && dict["markerSize"] == nil && dict["cursorSize"] == nil {
            dict["size"] = .string("tiny")
        }
        return .object(dict)
    }

    private func overlayPoint(fromCGPoint point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func overlayCaptionTopLeft(
        params: JSON?,
        window: WindowEntry?,
        fallbackPoint: CGPoint
    ) -> CGPoint? {
        if let x = params?["captionX"]?.numericDouble ?? params?["caption-x"]?.numericDouble,
           let y = params?["captionY"]?.numericDouble ?? params?["caption-y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }

        guard let window else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let margin: Double = params?["captionMargin"]?.numericDouble
            ?? params?["caption-margin"]?.numericDouble
            ?? 18
        let estimatedWidth: Double = 388
        let estimatedHeight: Double = 138

        let ratioX = params?["captionXRatio"]?.numericDouble
            ?? params?["caption-x-ratio"]?.numericDouble
            ?? params?["captionLeftRatio"]?.numericDouble
            ?? params?["caption-left-ratio"]?.numericDouble
        let ratioY = params?["captionYRatio"]?.numericDouble
            ?? params?["caption-y-ratio"]?.numericDouble
            ?? params?["captionTopRatio"]?.numericDouble
            ?? params?["caption-top-ratio"]?.numericDouble
        if ratioX != nil || ratioY != nil {
            let xRatio = max(0, min(1, ratioX ?? 0.02))
            let yRatio = max(0, min(1, ratioY ?? 0.06))
            return CGPoint(
                x: window.frame.x + window.frame.w * xRatio,
                y: primaryHeight - (window.frame.y + window.frame.h * yRatio)
            )
        }

        let placement = (params?["captionPlacement"]?.stringValue
            ?? params?["caption-placement"]?.stringValue
            ?? "top-left")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch placement {
        case "top-right", "right-top":
            return CGPoint(
                x: window.frame.x + window.frame.w - estimatedWidth - margin,
                y: primaryHeight - window.frame.y - margin
            )
        case "bottom-left", "left-bottom":
            return CGPoint(
                x: window.frame.x + margin,
                y: primaryHeight - (window.frame.y + window.frame.h) + estimatedHeight + margin
            )
        case "bottom-right", "right-bottom":
            return CGPoint(
                x: window.frame.x + window.frame.w - estimatedWidth - margin,
                y: primaryHeight - (window.frame.y + window.frame.h) + estimatedHeight + margin
            )
        case "top-center", "top", "center-top":
            return CGPoint(
                x: window.frame.x + (window.frame.w - estimatedWidth) / 2,
                y: primaryHeight - window.frame.y - margin
            )
        case "center", "middle":
            return CGPoint(
                x: window.frame.x + (window.frame.w - estimatedWidth) / 2,
                y: primaryHeight - (window.frame.y + window.frame.h / 2) + estimatedHeight / 2
            )
        case "near-cursor", "cursor":
            let overlayPoint = overlayPoint(fromCGPoint: fallbackPoint)
            return CGPoint(x: overlayPoint.x + margin, y: overlayPoint.y + estimatedHeight / 2)
        default:
            return overlayCaptionTopLeft(for: window)
        }
    }

    private func overlayCaptionTopLeft(for window: WindowEntry) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(
            x: window.frame.x + 18,
            y: primaryHeight - window.frame.y - 18
        )
    }

    private func cgPoint(fromOverlayPoint point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func appNameParam(_ params: JSON?, defaultName: String? = nil) throws -> String {
        let raw = params?["app"]?.stringValue
            ?? params?["name"]?.stringValue
            ?? params?["bundleName"]?.stringValue
            ?? defaultName
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw RouterError.missingParam("app")
        }
        return value
    }

    private func openOrActivateApp(params: JSON?, appName: String) throws -> Bool {
        try onMain {
            if let running = NSWorkspace.shared.runningApplications.first(where: { app in
                app.localizedName?.localizedCaseInsensitiveContains(appName) == true
                    || app.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
            }) {
                return running.activate(options: [.activateAllWindows])
            }

            if let bundleId = params?["bundleId"]?.stringValue
                ?? params?["bundleIdentifier"]?.stringValue,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return true
            }

            if let path = params?["path"]?.stringValue
                ?? params?["appPath"]?.stringValue,
               FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return true
            }

            let fileManager = FileManager.default
            let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let filenames = trimmedName.hasSuffix(".app")
                ? [trimmedName]
                : ["\(trimmedName).app", trimmedName]
            let roots = [
                "/Applications",
                "/System/Applications",
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
                "/Users/arach/Applications",
            ]

            for root in roots {
                for filename in filenames {
                    let url = URL(fileURLWithPath: root).appendingPathComponent(filename)
                    guard fileManager.fileExists(atPath: url.path) else { continue }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }
            }

            return ProcessQuery.run(["/usr/bin/open", "-a", trimmedName])
        }
    }

    private func waitForWindow(app appName: String, title: String?, timeout: TimeInterval) -> WindowEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = windowForApp(appName, title: title) {
                return window
            }
            usleep(90_000)
        } while Date() < deadline
        return windowForApp(appName, title: title)
    }

    private func windowForApp(_ appName: String, title: String?) -> WindowEntry? {
        DesktopModel.shared.forcePoll()
        return DesktopModel.shared.windowForApp(app: appName, title: title)
    }

    private func clickPoint(params: JSON?, window: WindowEntry?) -> CGPoint? {
        if let x = params?["x"]?.numericDouble,
           let y = params?["y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }
        guard let window else { return nil }
        let xRatio = params?["xRatio"]?.numericDouble
            ?? params?["relativeX"]?.numericDouble
            ?? params?["windowX"]?.numericDouble
        let yRatio = params?["yRatio"]?.numericDouble
            ?? params?["relativeY"]?.numericDouble
            ?? params?["windowY"]?.numericDouble
        guard xRatio != nil || yRatio != nil else { return nil }
        return windowRelativePoint(
            window,
            xRatio: CGFloat(max(0.0, min(1.0, xRatio ?? 0.5))),
            yRatio: CGFloat(max(0.0, min(1.0, yRatio ?? 0.5)))
        )
    }

    private func dragEndPoint(params: JSON?, window: WindowEntry?) -> CGPoint {
        if let x = params?["toX"]?.numericDouble
            ?? params?["to-x"]?.numericDouble
            ?? params?["endX"]?.numericDouble
            ?? params?["end-x"]?.numericDouble,
           let y = params?["toY"]?.numericDouble
            ?? params?["to-y"]?.numericDouble
            ?? params?["endY"]?.numericDouble
            ?? params?["end-y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }

        if let window {
            let xRatio = params?["toXRatio"]?.numericDouble
                ?? params?["to-x-ratio"]?.numericDouble
                ?? params?["endXRatio"]?.numericDouble
                ?? params?["end-x-ratio"]?.numericDouble
            let yRatio = params?["toYRatio"]?.numericDouble
                ?? params?["to-y-ratio"]?.numericDouble
                ?? params?["endYRatio"]?.numericDouble
                ?? params?["end-y-ratio"]?.numericDouble
            if xRatio != nil || yRatio != nil {
                return windowRelativePoint(
                    window,
                    xRatio: CGFloat(max(0.0, min(1.0, xRatio ?? 0.5))),
                    yRatio: CGFloat(max(0.0, min(1.0, yRatio ?? 0.5)))
                )
            }
        }

        return clickPoint(params: params, window: window) ?? cursorPoint(params: params)
    }

    private func dragStartPoint(params: JSON?, window: WindowEntry?, fallback: CGPoint) -> CGPoint {
        if let x = params?["fromX"]?.numericDouble
            ?? params?["from-x"]?.numericDouble
            ?? params?["startX"]?.numericDouble
            ?? params?["start-x"]?.numericDouble,
           let y = params?["fromY"]?.numericDouble
            ?? params?["from-y"]?.numericDouble
            ?? params?["startY"]?.numericDouble
            ?? params?["start-y"]?.numericDouble {
            return CGPoint(x: x, y: y)
        }

        if let window {
            let xRatio = params?["fromXRatio"]?.numericDouble
                ?? params?["from-x-ratio"]?.numericDouble
                ?? params?["startXRatio"]?.numericDouble
                ?? params?["start-x-ratio"]?.numericDouble
            let yRatio = params?["fromYRatio"]?.numericDouble
                ?? params?["from-y-ratio"]?.numericDouble
                ?? params?["startYRatio"]?.numericDouble
                ?? params?["start-y-ratio"]?.numericDouble
            if xRatio != nil || yRatio != nil {
                return windowRelativePoint(
                    window,
                    xRatio: CGFloat(max(0.0, min(1.0, xRatio ?? 0.5))),
                    yRatio: CGFloat(max(0.0, min(1.0, yRatio ?? 0.5)))
                )
            }
        }

        let current = cursorPoint(params: nil)
        if current == fallback {
            return CGPoint(x: fallback.x - 240, y: fallback.y - 120)
        }
        return current
    }

    private func windowRelativePoint(_ window: WindowEntry, xRatio: CGFloat, yRatio: CGFloat) -> CGPoint {
        CGPoint(
            x: window.frame.x + window.frame.w * Double(xRatio),
            y: window.frame.y + window.frame.h * Double(yRatio)
        )
    }

    private func postMouseClick(at point: CGPoint, rawButton: String?) throws {
        try postMouseClick(at: point, rawButton: rawButton, count: 1, delayMs: 90)
    }

    private func postMouseClick(at point: CGPoint, rawButton: String?, count: Int, delayMs: Double) throws {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required to click")
        }
        let button = mouseButton(rawButton)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw RouterError.custom("Unable to create mouse click event")
        }

        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(point)
        usleep(35_000)
        for index in 0..<max(1, count) {
            guard let down = CGEvent(
                    mouseEventSource: source,
                    mouseType: button.downType,
                    mouseCursorPosition: point,
                    mouseButton: button.button
                  ),
                  let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: button.upType,
                    mouseCursorPosition: point,
                    mouseButton: button.button
                  ) else {
                CGAssociateMouseAndMouseCursorPosition(1)
                throw RouterError.custom("Unable to create mouse click event")
            }

            let clickState = Int64(index + 1)
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            down.post(tap: .cghidEventTap)
            usleep(28_000)
            up.post(tap: .cghidEventTap)
            if index < count - 1 {
                usleep(UInt32(max(0, min(delayMs, 1_000)) * 1_000))
            }
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postMouseScroll(at point: CGPoint, deltaX: Double, deltaY: Double, count: Int, delayMs: Double) throws {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required to scroll")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw RouterError.custom("Unable to create scroll event source")
        }

        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(point)
        usleep(35_000)
        for index in 0..<max(1, count) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(max(-8_000, min(8_000, deltaY)).rounded()),
                wheel2: Int32(max(-8_000, min(8_000, deltaX)).rounded()),
                wheel3: 0
            ) else {
                CGAssociateMouseAndMouseCursorPosition(1)
                throw RouterError.custom("Unable to create scroll event")
            }
            event.post(tap: .cghidEventTap)
            if index < count - 1 {
                usleep(UInt32(max(0, min(delayMs, 1_000)) * 1_000))
            }
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postMouseDrag(
        from start: CGPoint,
        to end: CGPoint,
        rawButton: String?,
        durationMs: Double,
        steps: Int
    ) throws {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required to drag")
        }
        let button = mouseButton(rawButton)
        let dragType = mouseDragType(button.button)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                mouseEventSource: source,
                mouseType: button.downType,
                mouseCursorPosition: start,
                mouseButton: button.button
              ) else {
            throw RouterError.custom("Unable to create drag event")
        }

        let boundedSteps = max(2, min(steps, 120))
        let stepDelay = UInt32(max(2, min(durationMs / Double(boundedSteps), 120)) * 1_000)
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(start)
        usleep(35_000)
        down.post(tap: .cghidEventTap)
        usleep(stepDelay)

        for index in 1...boundedSteps {
            let progress = CGFloat(index) / CGFloat(boundedSteps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            guard let drag = CGEvent(
                mouseEventSource: source,
                mouseType: dragType,
                mouseCursorPosition: point,
                mouseButton: button.button
            ) else {
                CGAssociateMouseAndMouseCursorPosition(1)
                throw RouterError.custom("Unable to create drag event")
            }
            drag.post(tap: .cghidEventTap)
            usleep(stepDelay)
        }

        guard let up = CGEvent(
            mouseEventSource: source,
            mouseType: button.upType,
            mouseCursorPosition: end,
            mouseButton: button.button
        ) else {
            CGAssociateMouseAndMouseCursorPosition(1)
            throw RouterError.custom("Unable to create drag release event")
        }
        up.post(tap: .cghidEventTap)
        CGWarpMouseCursorPosition(end)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func mouseButton(_ raw: String?) -> (button: CGMouseButton, downType: CGEventType, upType: CGEventType, label: String) {
        switch normalizedMouseButton(raw) {
        case "right":
            return (.right, .rightMouseDown, .rightMouseUp, "right")
        default:
            return (.left, .leftMouseDown, .leftMouseUp, "left")
        }
    }

    private func normalizedMouseButton(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "right", "secondary", "context":
            return "right"
        default:
            return "left"
        }
    }

    private func mouseDragType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .right:
            return .rightMouseDragged
        default:
            return .leftMouseDragged
        }
    }

    private func clickCount(params: JSON?, defaultValue: Int) -> Int {
        pointerCount(params: params, defaultValue: defaultValue, maxValue: 8)
    }

    private func pointerCount(params: JSON?, defaultValue: Int, maxValue: Int) -> Int {
        let raw = params?["count"]?.intValue
            ?? params?["clicks"]?.intValue
            ?? params?["clickCount"]?.intValue
            ?? params?["click-count"]?.intValue
            ?? defaultValue
        return max(1, min(raw, maxValue))
    }

    private func pointerDelayMs(params: JSON?, defaultValue: Double) -> Double {
        let raw: Double
        if let value = params?["delayMs"]?.numericDouble {
            raw = value
        } else if let value = params?["delay-ms"]?.numericDouble {
            raw = value
        } else if let value = params?["intervalMs"]?.numericDouble {
            raw = value
        } else if let value = params?["interval-ms"]?.numericDouble {
            raw = value
        } else {
            raw = defaultValue
        }
        return max(0, min(raw, 1_000))
    }

    private func dragDurationMs(params: JSON?) -> Double {
        let raw: Double
        if let value = params?["durationMs"]?.numericDouble {
            raw = value
        } else if let value = params?["duration-ms"]?.numericDouble {
            raw = value
        } else if let value = params?["dragDurationMs"]?.numericDouble {
            raw = value
        } else if let value = params?["drag-duration-ms"]?.numericDouble {
            raw = value
        } else {
            raw = 360
        }
        return max(40, min(raw, 3_000))
    }

    private func dragSteps(params: JSON?) -> Int {
        let raw = params?["steps"]?.intValue
            ?? params?["stepCount"]?.intValue
            ?? params?["step-count"]?.intValue
            ?? 18
        return max(2, min(raw, 120))
    }

    private func scrollDelta(params: JSON?) -> CGPoint {
        if params?["deltaX"]?.numericDouble != nil
            || params?["delta-x"]?.numericDouble != nil
            || params?["dx"]?.numericDouble != nil
            || params?["deltaY"]?.numericDouble != nil
            || params?["delta-y"]?.numericDouble != nil
            || params?["dy"]?.numericDouble != nil {
            return CGPoint(
                x: boundedScrollDelta(
                    params?["deltaX"]?.numericDouble
                        ?? params?["delta-x"]?.numericDouble
                        ?? params?["dx"]?.numericDouble
                        ?? 0
                ),
                y: boundedScrollDelta(
                    params?["deltaY"]?.numericDouble
                        ?? params?["delta-y"]?.numericDouble
                        ?? params?["dy"]?.numericDouble
                        ?? 0
                )
            )
        }

        let amount = boundedScrollDelta(
            params?["amount"]?.numericDouble
                ?? params?["distance"]?.numericDouble
                ?? params?["delta"]?.numericDouble
                ?? 420
        )
        switch params?["direction"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "up", "north":
            return CGPoint(x: 0, y: amount)
        case "left", "west":
            return CGPoint(x: -amount, y: 0)
        case "right", "east":
            return CGPoint(x: amount, y: 0)
        default:
            return CGPoint(x: 0, y: -amount)
        }
    }

    private func boundedScrollDelta(_ value: Double) -> Double {
        max(-8_000, min(8_000, value))
    }

    private func clickTransport(_ params: JSON?) -> String {
        let raw = params?["transport"]?.stringValue
            ?? params?["method"]?.stringValue
            ?? params?["inputMode"]?.stringValue
            ?? params?["input-mode"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ax", "accessibility", "no-focus", "nofocus":
            return "ax"
        case "pointer", "mouse", "hardware":
            return "pointer"
        default:
            return "auto"
        }
    }

    private func axPressLabel(_ params: JSON?) -> String? {
        let explicit = params?["axLabel"]?.stringValue
            ?? params?["ax-label"]?.stringValue
            ?? params?["targetText"]?.stringValue
            ?? params?["target-text"]?.stringValue
            ?? params?["label"]?.stringValue
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        if params?["send"]?.boolValue == true || params?["enter"]?.boolValue == true {
            return "send"
        }
        return nil
    }

    private func clickJSON(_ point: CGPoint, button: String?) -> [String: JSON] {
        clickJSON(point, button: button, count: 1)
    }

    private func clickJSON(_ point: CGPoint, button: String?, count: Int) -> [String: JSON] {
        [
            "x": .double(point.x),
            "y": .double(point.y),
            "button": .string(normalizedMouseButton(button)),
            "count": .int(count),
        ]
    }

    private func scrollJSON(_ delta: CGPoint) -> JSON {
        .object([
            "x": .double(delta.x),
            "y": .double(delta.y),
        ])
    }

    private func pressViaAX(
        window: WindowEntry,
        targetPoint: CGPoint?,
        label: String?
    ) throws -> AXPressResult {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for AXPress")
        }
        guard let axWindow = axWindow(pid: window.pid, wid: window.wid) else {
            throw RouterError.custom("Unable to resolve AX window \(window.wid)")
        }

        let windowFrame = CGRect(
            x: window.frame.x,
            y: window.frame.y,
            width: window.frame.w,
            height: window.frame.h
        )
        var candidates: [AXPressCandidate] = []
        let deadline = Date().addingTimeInterval(0.75)
        collectPressCandidates(
            element: axWindow,
            depth: 0,
            deadline: deadline,
            targetPoint: targetPoint,
            targetLabel: label,
            windowFrame: windowFrame,
            candidates: &candidates
        )

        guard let candidate = candidates.sorted(by: { $0.score > $1.score }).first else {
            throw RouterError.custom("No AXPress target found in window \(window.wid)")
        }

        let action = kAXPressAction as String
        let err = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
        guard err == .success else {
            throw RouterError.custom("AXPress failed with \(err.rawValue)")
        }

        return AXPressResult(
            role: candidate.role,
            roleDescription: candidate.roleDescription,
            title: candidate.title,
            value: candidate.value,
            description: candidate.description,
            frame: candidate.frame,
            action: action,
            performed: true
        )
    }

    private func setTextViaAX(
        _ text: String,
        window: WindowEntry,
        targetPoint: CGPoint?,
        append: Bool,
        typeIntervalMs: Double?
    ) throws -> AXTextInsertionResult {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for AX text insertion")
        }
        guard let axWindow = axWindow(pid: window.pid, wid: window.wid) else {
            throw RouterError.custom("Unable to resolve AX window \(window.wid)")
        }

        let windowFrame = CGRect(
            x: window.frame.x,
            y: window.frame.y,
            width: window.frame.w,
            height: window.frame.h
        )
        var candidates: [AXEditableCandidate] = []
        let deadline = Date().addingTimeInterval(0.75)
        collectEditableCandidates(
            element: axWindow,
            depth: 0,
            deadline: deadline,
            targetPoint: targetPoint,
            windowFrame: windowFrame,
            candidates: &candidates
        )

        guard let candidate = candidates.sorted(by: { $0.score > $1.score }).first else {
            throw RouterError.custom("No editable AX text target found in window \(window.wid)")
        }

        func setAXValue(_ value: String) throws {
            let err = AXUIElementSetAttributeValue(
                candidate.element,
                kAXValueAttribute as CFString,
                value as CFString
            )
            guard err == .success else {
                throw RouterError.custom("AX text insertion failed with \(err.rawValue)")
            }
        }

        let previousValue = candidate.value
        let baseValue = append ? (previousValue ?? "") : ""
        let insertedValue = append ? (baseValue + text) : text
        let interval = typeIntervalMs.map { max(4, min($0, 160)) }
        if let interval {
            if !append, previousValue?.isEmpty == false {
                try setAXValue("")
                usleep(80_000)
            }
            var staged = baseValue
            for character in text {
                staged.append(character)
                try setAXValue(staged)
                usleep(UInt32(interval * 1_000))
            }
        } else {
            try setAXValue(insertedValue)
        }

        let verified = axString(candidate.element, attribute: kAXValueAttribute)
        return AXTextInsertionResult(
            role: candidate.role,
            roleDescription: candidate.roleDescription,
            frame: candidate.frame,
            previousValue: previousValue,
            insertedValue: insertedValue,
            verifiedValue: verified,
            typedCharacters: interval == nil ? nil : text.count,
            typeIntervalMs: interval
        )
    }

    private func axTypeIntervalMs(params: JSON?) -> Double? {
        let rawInterval = params?["typeIntervalMs"]?.numericDouble
            ?? params?["type-interval-ms"]?.numericDouble
            ?? params?["typingIntervalMs"]?.numericDouble
            ?? params?["typing-interval-ms"]?.numericDouble
        if let rawInterval, rawInterval > 0 {
            return max(4, min(rawInterval, 160))
        }
        if params?["typewriter"]?.boolValue == true || params?["typing"]?.boolValue == true {
            return 18
        }
        return nil
    }

    private func windowStateMode(_ params: JSON?) throws -> String {
        let raw = params?["mode"]?.stringValue
            ?? params?["stateMode"]?.stringValue
            ?? params?["state-mode"]?.stringValue
            ?? "ax"
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ax", "accessibility":
            return "ax"
        case "both", "all", "ax+screenshot", "screenshot+ax":
            return "both"
        case "screenshot", "capture", "image":
            return "screenshot"
        default:
            throw RouterError.custom("Unsupported computer.windowState mode '\(raw)'; use ax, both, or screenshot")
        }
    }

    private func requiredString(_ params: JSON?, keys: [String]) throws -> String {
        for key in keys {
            if let value = params?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        throw RouterError.missingParam(keys.first ?? "value")
    }

    private func requiredValueString(_ params: JSON?, keys: [String]) throws -> String {
        for key in keys {
            if let value = params?[key]?.stringValue {
                return value
            }
        }
        throw RouterError.missingParam(keys.first ?? "value")
    }

    private func hasKeyboardTarget(_ params: JSON?) -> Bool {
        if params?["wid"]?.uint32Value != nil { return true }
        if params?["session"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if params?["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        return false
    }

    private func keyboardRequest(params: JSON?, requiresModifier: Bool) throws -> (key: String, modifiers: [String]) {
        var key = params?["key"]?.stringValue
            ?? params?["code"]?.stringValue
            ?? params?["shortcut"]?.stringValue
        var modifiers = keyboardModifiers(params)

        if let shortcut = params?["shortcut"]?.stringValue, !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parseKeyboardShortcut(shortcut)
            if params?["key"]?.stringValue == nil && params?["code"]?.stringValue == nil {
                key = parsed.key
            }
            modifiers.append(contentsOf: parsed.modifiers)
        } else if let rawKey = key,
                  rawKey.contains("+")
                    || rawKey.contains("\u{2318}")
                    || rawKey.contains("\u{2325}")
                    || rawKey.contains("\u{2303}")
                    || rawKey.contains("\u{21E7}") {
            let parsed = parseKeyboardShortcut(rawKey)
            key = parsed.key
            modifiers.append(contentsOf: parsed.modifiers)
        }

        guard let rawKey = key?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty else {
            throw RouterError.missingParam("key")
        }

        let normalizedModifiers = uniqueKeyboardModifiers(modifiers)
        if requiresModifier, normalizedModifiers.isEmpty {
            throw RouterError.custom("computer.hotkey requires at least one modifier or shortcut")
        }

        return (rawKey, normalizedModifiers)
    }

    private func keyboardModifiers(_ params: JSON?) -> [String] {
        var modifiers: [String] = []
        if let values = params?["modifiers"]?.arrayValue {
            modifiers.append(contentsOf: values.compactMap(\.stringValue))
        } else if let raw = params?["modifiers"]?.stringValue {
            modifiers.append(contentsOf: raw.split { character in
                character == "," || character == "+" || character == " "
            }.map(String.init))
        }

        let boolAliases: [(String, String)] = [
            ("cmd", "command"),
            ("command", "command"),
            ("meta", "command"),
            ("opt", "option"),
            ("option", "option"),
            ("alt", "option"),
            ("ctrl", "control"),
            ("control", "control"),
            ("shift", "shift"),
        ]
        for (key, modifier) in boolAliases where params?[key]?.boolValue == true {
            modifiers.append(modifier)
        }
        return modifiers
    }

    private func parseKeyboardShortcut(_ value: String) -> (key: String, modifiers: [String]) {
        let expanded = value
            .replacingOccurrences(of: "\u{2318}", with: "command+")
            .replacingOccurrences(of: "\u{2325}", with: "option+")
            .replacingOccurrences(of: "\u{2303}", with: "control+")
            .replacingOccurrences(of: "\u{21E7}", with: "shift+")
        let parts = expanded
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count > 1 else {
            return (value.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        return (
            parts.last ?? value.trimmingCharacters(in: .whitespacesAndNewlines),
            Array(parts.dropLast())
        )
    }

    private func uniqueKeyboardModifiers(_ rawModifiers: [String]) -> [String] {
        let normalized = Set(rawModifiers.compactMap(normalizeKeyboardModifier))
        return ["control", "option", "shift", "command"].filter { normalized.contains($0) }
    }

    private func normalizeKeyboardModifier(_ modifier: String) -> String? {
        switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cmd", "command", "meta", "\u{2318}":
            return "command"
        case "opt", "option", "alt", "\u{2325}":
            return "option"
        case "ctrl", "control", "\u{2303}":
            return "control"
        case "shift", "\u{21E7}":
            return "shift"
        default:
            return nil
        }
    }

    private func elementActionName(_ params: JSON?) throws -> String {
        let raw = params?["action"]?.stringValue
            ?? params?["elementAction"]?.stringValue
            ?? params?["element-action"]?.stringValue
            ?? params?["axAction"]?.stringValue
            ?? params?["ax-action"]?.stringValue
            ?? "press"
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "press", "click", "tap", "open", "confirm", "cancel", "default", "axpress":
            return "press"
        case "showmenu", "show-menu", "menu", "context", "contextmenu", "context-menu", "axshowmenu":
            return "showMenu"
        case "focus", "focused":
            return "focus"
        default:
            throw RouterError.custom("Unsupported computer.elementAction action '\(raw)'; use press, showMenu, or focus")
        }
    }

    private func storeAXSnapshot(
        id: String,
        window: WindowEntry,
        elements: [AXSnapshotElement],
        elementRefsById: [String: AXUIElement]
    ) {
        guard !elements.isEmpty, !elementRefsById.isEmpty else { return }
        axSnapshotLock.lock()
        defer { axSnapshotLock.unlock() }
        pruneAXSnapshotsLocked()
        axSnapshotsById[id] = AXWindowSnapshot(
            id: id,
            window: window,
            createdAt: Date(),
            elementsById: Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) }),
            elementRefsById: elementRefsById
        )
        if axSnapshotsById.count > maxAXSnapshotCacheCount {
            let overflow = axSnapshotsById
                .sorted { $0.value.createdAt < $1.value.createdAt }
                .prefix(axSnapshotsById.count - maxAXSnapshotCacheCount)
                .map(\.key)
            for key in overflow {
                axSnapshotsById.removeValue(forKey: key)
            }
        }
    }

    private func axSnapshot(id: String) throws -> AXWindowSnapshot {
        axSnapshotLock.lock()
        defer { axSnapshotLock.unlock() }
        pruneAXSnapshotsLocked()
        guard let snapshot = axSnapshotsById[id] else {
            throw RouterError.notFound("AX snapshot \(id)")
        }
        return snapshot
    }

    private func pruneAXSnapshotsLocked() {
        let cutoff = Date().addingTimeInterval(-axSnapshotTTL)
        axSnapshotsById = axSnapshotsById.filter { $0.value.createdAt >= cutoff }
    }

    private func axActionName(for requestedAction: String, elementInfo: AXSnapshotElement) throws -> String {
        let action: String
        switch requestedAction {
        case "showMenu":
            action = kAXShowMenuAction as String
        default:
            action = kAXPressAction as String
        }
        guard elementInfo.actions.contains(action) else {
            throw RouterError.custom("Element \(elementInfo.id) does not support \(action)")
        }
        return action
    }

    private func performAXAction(_ element: AXUIElement, action: String) throws {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for AX element actions")
        }
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else {
            throw RouterError.custom("\(action) failed with \(err.rawValue)")
        }
    }

    private func focusAXElement(_ element: AXUIElement) throws {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for AX element focus")
        }
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard err == .success else {
            throw RouterError.custom("AX focus failed with \(err.rawValue)")
        }
    }

    private func setElementValueViaAX(
        _ text: String,
        element: AXUIElement,
        elementInfo: AXSnapshotElement,
        append: Bool,
        typeIntervalMs: Double?
    ) throws -> AXTextInsertionResult {
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for AX text insertion")
        }
        var settable = DarwinBoolean(false)
        let settableErr = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settableErr == .success, settable.boolValue else {
            throw RouterError.custom("Element \(elementInfo.id) does not support setting AXValue")
        }

        func setAXValue(_ value: String) throws {
            let err = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFString
            )
            guard err == .success else {
                throw RouterError.custom("AX value insertion failed with \(err.rawValue)")
            }
        }

        // Mutation inputs and verification must preserve the complete value.
        // axAttributeString trims and truncates text for display in snapshots.
        let previousValue = axString(element, attribute: kAXValueAttribute)
        let baseValue = append ? (previousValue ?? "") : ""
        let insertedValue = append ? (baseValue + text) : text
        let interval = typeIntervalMs.map { max(4, min($0, 160)) }
        if let interval {
            if !append, previousValue?.isEmpty == false {
                try setAXValue("")
                usleep(80_000)
            }
            var staged = baseValue
            for character in text {
                staged.append(character)
                try setAXValue(staged)
                usleep(UInt32(interval * 1_000))
            }
        } else {
            try setAXValue(insertedValue)
        }

        let verified = axString(element, attribute: kAXValueAttribute)
        return AXTextInsertionResult(
            role: elementInfo.role,
            roleDescription: elementInfo.roleDescription,
            frame: elementInfo.frame,
            previousValue: previousValue,
            insertedValue: insertedValue,
            verifiedValue: verified,
            typedCharacters: interval == nil ? nil : text.count,
            typeIntervalMs: interval
        )
    }

    private func axSnapshot(
        window: WindowEntry,
        maxDepth: Int,
        maxElements: Int,
        timeoutMs: Int
    ) throws -> AXSnapshotContext {
        // AX calls targeting this process invoke our AppKit/SwiftUI accessibility
        // implementation directly. Traversing it on the daemon queue can enter
        // view layout off the main thread and crash the Swift exclusivity runtime.
        // Keep only the self-inspection on main; remote AX and capture stay off it.
        if window.pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return try DispatchQueue.main.sync {
                try self.axSnapshot(
                    window: window,
                    maxDepth: maxDepth,
                    maxElements: maxElements,
                    timeoutMs: timeoutMs
                )
            }
        }
        guard AXIsProcessTrusted() else {
            throw RouterError.custom("Accessibility permission is required for computer.windowState")
        }
        guard let axWindow = axWindow(pid: window.pid, wid: window.wid) else {
            throw RouterError.custom("Unable to resolve AX window \(window.wid)")
        }

        var context = AXSnapshotContext(
            maxDepth: maxDepth,
            maxElements: maxElements,
            maxChildrenPerElement: 160,
            deadline: Date().addingTimeInterval(Double(timeoutMs) / 1_000.0),
            messagingTimeout: 0.25
        )
        collectAXSnapshotElements(
            element: axWindow,
            depth: 0,
            path: "0",
            context: &context
        )
        return context
    }

    private func collectAXSnapshotElements(
        element: AXUIElement,
        depth: Int,
        path: String,
        context: inout AXSnapshotContext
    ) {
        guard Date() < context.deadline else {
            context.hitTimeout = true
            return
        }
        guard context.elements.count < context.maxElements else {
            context.hitElementLimit = true
            return
        }
        guard depth <= context.maxDepth else {
            context.hitDepthLimit = true
            return
        }

        let children = axSnapshotChildren(element, context: &context)
        guard !context.hitTimeout else { return }

        let id = "e\(context.nextElementIndex)"
        context.nextElementIndex += 1
        let role = axSnapshotString(element, attribute: kAXRoleAttribute, context: &context) ?? "unknown"
        guard !context.hitTimeout else { return }
        let roleDescription = axSnapshotString(element, attribute: kAXRoleDescriptionAttribute, context: &context)
        let title = axSnapshotAttributeString(element, attribute: kAXTitleAttribute, context: &context)
        let label = axSnapshotAttributeString(element, attribute: "AXLabel", context: &context)
        let value = axSnapshotAttributeString(element, attribute: kAXValueAttribute, context: &context)
        let description = axSnapshotAttributeString(element, attribute: kAXDescriptionAttribute, context: &context)
        let help = axSnapshotAttributeString(element, attribute: kAXHelpAttribute, context: &context)
        let identifier = axSnapshotAttributeString(element, attribute: kAXIdentifierAttribute, context: &context)
        let frame = axSnapshotFrame(element, context: &context)
        let enabled = axSnapshotBool(element, attribute: "AXEnabled", context: &context)
        let selected = axSnapshotBool(element, attribute: "AXSelected", context: &context)
        let focused = axSnapshotBool(element, attribute: "AXFocused", context: &context)
        let actions = axSnapshotActions(element, context: &context)
        context.elements.append(AXSnapshotElement(
            id: id,
            role: role,
            roleDescription: roleDescription,
            title: title,
            label: label,
            value: value,
            description: description,
            help: help,
            identifier: identifier,
            frame: frame,
            enabled: enabled,
            selected: selected,
            focused: focused,
            actions: actions,
            path: path,
            depth: depth,
            childCount: children.count
        ))
        context.elementRefsById[id] = element
        guard !context.hitTimeout else { return }

        guard depth < context.maxDepth else {
            if !children.isEmpty {
                context.hitDepthLimit = true
            }
            return
        }

        let visibleChildren = children.prefix(context.maxChildrenPerElement)
        if children.count > context.maxChildrenPerElement {
            context.warnings.append("Element \(id) had \(children.count) children; visited first \(context.maxChildrenPerElement)")
        }
        for (index, child) in visibleChildren.enumerated() {
            collectAXSnapshotElements(
                element: child,
                depth: depth + 1,
                path: "\(path).\(index)",
                context: &context
            )
            if context.hitTimeout || context.hitElementLimit {
                return
            }
        }
    }

    private func prepareAXSnapshotCall(
        _ element: AXUIElement,
        context: inout AXSnapshotContext
    ) -> Bool {
        let remaining = context.deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            context.hitTimeout = true
            return false
        }
        AXUIElementSetMessagingTimeout(element, Float(min(Double(context.messagingTimeout), remaining)))
        return true
    }

    private func axSnapshotChildren(
        _ element: AXUIElement,
        context: inout AXSnapshotContext
    ) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        if prepareAXSnapshotCall(element, context: &context),
           AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &childrenRef) == .success,
           let visible = childrenRef as? [AXUIElement],
           !visible.isEmpty {
            return visible
        }

        childrenRef = nil
        if prepareAXSnapshotCall(element, context: &context),
           AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            return children
        }
        return []
    }

    private func axSnapshotBool(
        _ element: AXUIElement,
        attribute: String,
        context: inout AXSnapshotContext
    ) -> Bool? {
        var ref: CFTypeRef?
        guard prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean))
        }
        return (ref as? NSNumber)?.boolValue ?? (ref as? Bool)
    }

    private func axSnapshotString(
        _ element: AXUIElement,
        attribute: String,
        context: inout AXSnapshotContext
    ) -> String? {
        var ref: CFTypeRef?
        guard prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func axSnapshotAttributeString(
        _ element: AXUIElement,
        attribute: String,
        context: inout AXSnapshotContext
    ) -> String? {
        var ref: CFTypeRef?
        guard prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        let value: String?
        if let string = ref as? String {
            value = string
        } else if let number = ref as? NSNumber {
            value = number.stringValue
        } else if let url = ref as? URL {
            value = url.absoluteString
        } else {
            value = nil
        }
        return value.flatMap(Self.truncatedAXString)
    }

    private func axSnapshotActions(
        _ element: AXUIElement,
        context: inout AXSnapshotContext
    ) -> [String] {
        var ref: CFArray?
        guard prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyActionNames(element, &ref) == .success,
              let actions = ref as? [String] else {
            return []
        }
        return actions
    }

    private func axSnapshotFrame(
        _ element: AXUIElement,
        context: inout AXSnapshotContext
    ) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              prepareAXSnapshotCall(element, context: &context),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef,
              let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &childrenRef) == .success,
           let visible = childrenRef as? [AXUIElement],
           !visible.isEmpty {
            return visible
        }

        childrenRef = nil
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            return children
        }
        return []
    }

    private func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean))
        }
        return (ref as? NSNumber)?.boolValue ?? (ref as? Bool)
    }

    private func axAttributeString(_ element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        let value: String?
        if let string = ref as? String {
            value = string
        } else if let number = ref as? NSNumber {
            value = number.stringValue
        } else if let url = ref as? URL {
            value = url.absoluteString
        } else {
            value = nil
        }
        return value.flatMap(Self.truncatedAXString)
    }

    private func treeMarkdown(for elements: [AXSnapshotElement]) -> String {
        guard !elements.isEmpty else { return "" }
        return elements.map { element in
            let indent = String(repeating: "  ", count: element.depth)
            let label = [
                element.title,
                element.label,
                element.value,
                element.description,
                element.identifier,
            ]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var line = "\(indent)- \(element.id) \(element.role)"
            if let label {
                line += " \"\(Self.singleLine(label))\""
            }
            if !element.actions.isEmpty {
                line += " actions=\(element.actions.joined(separator: ","))"
            }
            if let frame = element.frame {
                line += " frame=\(Self.compactFrame(frame))"
            }
            return line
        }.joined(separator: "\n")
    }

    private func axWindow(pid: Int32, wid: UInt32) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.5)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var windowId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowId) == .success, windowId == CGWindowID(wid) {
                return window
            }
        }
        return nil
    }

    private func collectEditableCandidates(
        element: AXUIElement,
        depth: Int,
        deadline: Date,
        targetPoint: CGPoint?,
        windowFrame: CGRect,
        candidates: inout [AXEditableCandidate]
    ) {
        guard depth <= 10, Date() < deadline, candidates.count < 80 else { return }

        if let candidate = editableCandidate(
            element: element,
            depth: depth,
            targetPoint: targetPoint,
            windowFrame: windowFrame
        ) {
            candidates.append(candidate)
        }

        var childrenRef: CFTypeRef?
        var children: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &childrenRef) == .success,
           let visible = childrenRef as? [AXUIElement],
           !visible.isEmpty {
            children = visible
        } else {
            childrenRef = nil
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let all = childrenRef as? [AXUIElement] {
                children = all
            }
        }

        for child in children.prefix(80) {
            collectEditableCandidates(
                element: child,
                depth: depth + 1,
                deadline: deadline,
                targetPoint: targetPoint,
                windowFrame: windowFrame,
                candidates: &candidates
            )
        }
    }

    private func collectPressCandidates(
        element: AXUIElement,
        depth: Int,
        deadline: Date,
        targetPoint: CGPoint?,
        targetLabel: String?,
        windowFrame: CGRect,
        candidates: inout [AXPressCandidate]
    ) {
        guard depth <= 12, Date() < deadline, candidates.count < 120 else { return }

        if let candidate = pressCandidate(
            element: element,
            depth: depth,
            targetPoint: targetPoint,
            targetLabel: targetLabel,
            windowFrame: windowFrame
        ) {
            candidates.append(candidate)
        }

        var childrenRef: CFTypeRef?
        var children: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &childrenRef) == .success,
           let visible = childrenRef as? [AXUIElement],
           !visible.isEmpty {
            children = visible
        } else {
            childrenRef = nil
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let all = childrenRef as? [AXUIElement] {
                children = all
            }
        }

        for child in children.prefix(120) {
            collectPressCandidates(
                element: child,
                depth: depth + 1,
                deadline: deadline,
                targetPoint: targetPoint,
                targetLabel: targetLabel,
                windowFrame: windowFrame,
                candidates: &candidates
            )
        }
    }

    private func editableCandidate(
        element: AXUIElement,
        depth: Int,
        targetPoint: CGPoint?,
        windowFrame: CGRect
    ) -> AXEditableCandidate? {
        let role = axString(element, attribute: kAXRoleAttribute) ?? "unknown"
        let roleDescription = axString(element, attribute: kAXRoleDescriptionAttribute)
        let value = axString(element, attribute: kAXValueAttribute)
        var settable = DarwinBoolean(false)
        let settableErr = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settableErr == .success, settable.boolValue else { return nil }

        let roleText = "\(role) \(roleDescription ?? "")".lowercased()
        let roleLooksEditable = roleText.contains("text")
            || role == "AXTextArea"
            || role == "AXTextField"
            || role == "AXComboBox"
        guard roleLooksEditable else { return nil }

        let frame = axFrame(element)
        var score = 100.0 - Double(depth) * 8.0
        if role == "AXTextArea" {
            score += 130
        } else if role == "AXTextField" {
            score += 100
        } else if role == "AXComboBox" {
            score += 40
        }

        if let frame {
            let lowerHalf = frame.midY >= windowFrame.midY
            if lowerHalf {
                score += 90
            }
            let area = max(1, frame.width * frame.height)
            score -= min(80, Double(area / max(1, windowFrame.width * windowFrame.height)) * 120)

            if let targetPoint {
                let hitFrame = frame.insetBy(dx: -8, dy: -8)
                if hitFrame.contains(targetPoint) {
                    score += 1_000
                    score += Double(depth) * 12
                } else {
                    let dx = frame.midX - targetPoint.x
                    let dy = frame.midY - targetPoint.y
                    score -= min(350, Double(hypot(dx, dy) / 4))
                }
            }
        } else if targetPoint != nil {
            score -= 120
        }

        return AXEditableCandidate(
            element: element,
            role: role,
            roleDescription: roleDescription,
            frame: frame,
            value: value,
            score: score
        )
    }

    private func pressCandidate(
        element: AXUIElement,
        depth: Int,
        targetPoint: CGPoint?,
        targetLabel: String?,
        windowFrame: CGRect
    ) -> AXPressCandidate? {
        let actions = axActions(element)
        guard actions.contains(kAXPressAction as String) else { return nil }

        let role = axString(element, attribute: kAXRoleAttribute) ?? "unknown"
        let roleDescription = axString(element, attribute: kAXRoleDescriptionAttribute)
        let title = axString(element, attribute: kAXTitleAttribute)
        let value = axString(element, attribute: kAXValueAttribute)
        let description = axString(element, attribute: kAXDescriptionAttribute)
        let help = axString(element, attribute: kAXHelpAttribute)
        let identifier = axString(element, attribute: kAXIdentifierAttribute)
        let frame = axFrame(element)

        var score = 80.0 - Double(depth) * 5.0
        let roleText = "\(role) \(roleDescription ?? "")".lowercased()
        if role == "AXButton" || roleText.contains("button") {
            score += 140
        } else if role == "AXMenuItem" || roleText.contains("menu item") {
            score += 60
        } else {
            score += 20
        }

        if let frame {
            let lowerRight = frame.midX >= windowFrame.midX && frame.midY >= windowFrame.midY
            let area = max(1, frame.width * frame.height)
            score -= min(70, Double(area / max(1, windowFrame.width * windowFrame.height)) * 130)
            if lowerRight {
                score += 35
            }

            if let targetPoint {
                let hitFrame = frame.insetBy(dx: -10, dy: -10)
                if hitFrame.contains(targetPoint) {
                    score += 1_000
                    score += Double(depth) * 8
                } else {
                    let dx = frame.midX - targetPoint.x
                    let dy = frame.midY - targetPoint.y
                    score -= min(420, Double(hypot(dx, dy) / 3.5))
                }
            }
        } else if targetPoint != nil {
            score -= 120
        }

        if let targetLabel = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !targetLabel.isEmpty {
            let searchable = [
                title,
                value,
                description,
                help,
                identifier,
                roleDescription,
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            if searchable.contains(targetLabel) {
                score += 650
            } else if targetLabel == "send" && frame?.midY ?? 0 >= windowFrame.midY && frame?.midX ?? 0 >= windowFrame.midX {
                score += 170
            } else {
                score -= 70
            }
        }

        return AXPressCandidate(
            element: element,
            role: role,
            roleDescription: roleDescription,
            title: title,
            value: value,
            description: description,
            frame: frame,
            score: score
        )
    }

    private func axActions(_ element: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(element, &ref) == .success,
              let actions = ref as? [String] else {
            return []
        }
        return actions
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef,
              let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func attachBackgroundSafety(
        _ receipt: ComputerBackgroundSafetyReceipt,
        to object: inout [String: JSON]
    ) {
        object["backgroundSafety"] = receipt.json
        object["background_safe"] = .bool(receipt.backgroundSafe)
        object["backgroundSafe"] = .bool(receipt.backgroundSafe)
        object["route"] = .string(receipt.route)
        object["lane"] = .string(receipt.lane)
        object["session"] = .string(receipt.session)
        object["cursor_moved"] = .bool(receipt.cursorMoved)
        object["cursorMoved"] = .bool(receipt.cursorMoved)
        object["foreground_changed"] = .bool(receipt.foregroundChanged)
        object["foregroundChanged"] = .bool(receipt.foregroundChanged)
    }

    private func backgroundSafetyReceipt(
        route: String,
        cursorMoved: Bool = false,
        foregroundChanged: Bool = false,
        backgroundEligible: Bool
    ) -> ComputerBackgroundSafetyReceipt {
        ComputerBackgroundSafetyReceipt(
            route: route,
            lane: "same_session",
            session: "parent",
            backgroundSafe: backgroundEligible && !cursorMoved && !foregroundChanged,
            cursorMoved: cursorMoved,
            foregroundChanged: foregroundChanged
        )
    }

    private func stagedRoute(for treatment: ComputerTreatment) -> String {
        treatment == .observe ? "observe" : "stage"
    }

    private func backgroundSafeRequested(_ params: JSON?) -> Bool {
        params?["backgroundSafe"]?.boolValue == true
            || params?["background-safe"]?.boolValue == true
            || params?["background"]?.boolValue == true
            || params?["noFocus"]?.boolValue == true
            || params?["no-focus"]?.boolValue == true
    }

    private func appResponse(
        action: String,
        run: RunSession,
        appName: String,
        target: WindowEntry?,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        launched: Bool,
        focused: Bool,
        typedText: String?,
        clicked: Bool?
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(action),
            "treatment": .string(treatment.rawValue),
            "app": .string(appName),
            "launched": .bool(launched),
            "focused": .bool(focused),
            "run": run.json,
        ]
        if let target { object["target"] = Encoders.window(target) }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        if let typedText { object["typedText"] = .string(typedText) }
        if let clicked { object["clicked"] = .bool(clicked) }
        let route: String
        let cursorMoved = clicked == true && treatment.performsPointerAction
        let foregroundChanged = launched || focused
        let backgroundEligible: Bool
        if treatment == .observe || treatment == .stage {
            route = stagedRoute(for: treatment)
            backgroundEligible = true
        } else if launched {
            route = "app.launch"
            backgroundEligible = false
        } else if cursorMoved {
            route = "pointer.click"
            backgroundEligible = false
        } else if typedText != nil && treatment.insertsText {
            route = "keyboard.typeText"
            backgroundEligible = false
        } else if focused {
            route = "window.focus"
            backgroundEligible = false
        } else {
            route = "app.\(action)"
            backgroundEligible = false
        }
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: route,
                cursorMoved: cursorMoved,
                foregroundChanged: foregroundChanged,
                backgroundEligible: backgroundEligible
            ),
            to: &object
        )
        return .object(object)
    }

    private func clickResponse(
        action: String,
        run: RunSession,
        target: WindowEntry?,
        point: CGPoint,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        clicked: Bool,
        button: String?,
        count: Int,
        transport: String,
        focused: Bool,
        axResult: AXPressResult?
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(action),
            "treatment": .string(treatment.rawValue),
            "clicked": .bool(clicked),
            "focused": .bool(focused),
            "transport": .string(transport),
            "run": run.json,
            "cursor": cursorJSON(point),
            "button": .string(normalizedMouseButton(button)),
            "count": .int(count),
        ]
        if let target { object["target"] = Encoders.window(target) }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        if let axResult { object["ax"] = axResult.json }
        let isStaged = !clicked || treatment == .observe || treatment == .stage
        let route = isStaged
            ? stagedRoute(for: treatment)
            : (transport == "ax" ? "ax.press" : "pointer.click")
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: route,
                cursorMoved: clicked && transport == "pointer",
                foregroundChanged: focused,
                backgroundEligible: isStaged || transport == "ax"
            ),
            to: &object
        )
        return .object(object)
    }

    private func pointerActionResponse(
        action: String,
        run: RunSession,
        target: WindowEntry?,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        focused: Bool,
        performedKey: String,
        performed: Bool,
        point: CGPoint?,
        from: CGPoint?,
        to: CGPoint?,
        delta: CGPoint?,
        button: String?,
        count: Int?,
        transport: String
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(action),
            "treatment": .string(treatment.rawValue),
            performedKey: .bool(performed),
            "focused": .bool(focused),
            "transport": .string(transport),
            "run": run.json,
        ]
        if let target { object["target"] = Encoders.window(target) }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        if let point { object["cursor"] = cursorJSON(point) }
        if let from { object["from"] = cursorJSON(from) }
        if let to { object["to"] = cursorJSON(to) }
        if let delta { object["delta"] = scrollJSON(delta) }
        if let button { object["button"] = .string(normalizedMouseButton(button)) }
        if let count { object["count"] = .int(count) }
        let isStaged = !performed || treatment == .observe || treatment == .stage
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: isStaged ? stagedRoute(for: treatment) : "pointer.\(action)",
                cursorMoved: performed && transport == "pointer",
                foregroundChanged: focused,
                backgroundEligible: isStaged
            ),
            to: &object
        )
        return .object(object)
    }

    private func keyboardActionResponse(
        action: String,
        run: RunSession,
        target: WindowEntry?,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        key: String,
        modifiers: [String],
        displayName: String,
        count: Int,
        delayMs: Double,
        sent: Bool,
        focused: Bool,
        global: Bool
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(action),
            "treatment": .string(treatment.rawValue),
            "key": .string(key),
            "modifiers": .array(modifiers.map { .string($0) }),
            "display": .string(displayName),
            "count": .int(count),
            "delayMs": .double(delayMs),
            "sent": .bool(sent),
            "focused": .bool(focused),
            "global": .bool(global),
            "run": run.json,
        ]
        if let target { object["target"] = Encoders.window(target) }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        let isStaged = !sent || treatment == .observe || treatment == .stage
        let route = isStaged
            ? stagedRoute(for: treatment)
            : (global ? "keyboard.global" : "keyboard.target")
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: route,
                foregroundChanged: focused,
                backgroundEligible: isStaged
            ),
            to: &object
        )
        return .object(object)
    }

    private func elementActionResponse(
        run: RunSession,
        snapshot: AXWindowSnapshot,
        element: AXSnapshotElement,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        requestedAction: String,
        axAction: String?,
        performed: Bool,
        focused: Bool
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string("elementAction"),
            "treatment": .string(treatment.rawValue),
            "snapshotId": .string(snapshot.id),
            "elementId": .string(element.id),
            "requestedAction": .string(requestedAction),
            "performed": .bool(performed),
            "focused": .bool(focused),
            "target": Encoders.window(snapshot.window),
            "element": element.json,
            "run": run.json,
        ]
        if let axAction { object["axAction"] = .string(axAction) }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        let isStaged = !performed || treatment == .observe || treatment == .stage
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: isStaged ? stagedRoute(for: treatment) : "ax.\(axAction ?? requestedAction)",
                foregroundChanged: focused,
                backgroundEligible: true
            ),
            to: &object
        )
        return .object(object)
    }

    private func elementTextResponse(
        actionName: String,
        run: RunSession,
        snapshot: AXWindowSnapshot,
        element: AXSnapshotElement,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        text: String,
        append: Bool,
        result: AXTextInsertionResult?,
        focused: Bool
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(actionName),
            "treatment": .string(treatment.rawValue),
            "snapshotId": .string(snapshot.id),
            "elementId": .string(element.id),
            "typed": .bool(result != nil),
            "focused": .bool(focused),
            "append": .bool(append),
            "text": .string(text),
            "target": Encoders.window(snapshot.window),
            "element": element.json,
            "run": run.json,
        ]
        if let result {
            object["result"] = result.json
            object["verified"] = result.json["verified"] ?? .bool(false)
        }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        let typed = result != nil
        let isStaged = !typed || treatment == .observe || treatment == .stage
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: isStaged ? stagedRoute(for: treatment) : "ax.setValue",
                foregroundChanged: focused,
                backgroundEligible: true
            ),
            to: &object
        )
        return .object(object)
    }

    private func onMain<T>(_ work: () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try work()
        }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = Result { try work() }
        }
        return try result.get()
    }

    private func canUseTmuxTransport(selected: TerminalCandidate, preference: String) -> Bool {
        guard preference == "auto" || preference == "tmux" else { return false }
        guard TmuxQuery.resolvedPath != nil else { return false }
        return selected.instance.tmuxPaneId?.isEmpty == false
    }

    private func canUseITermSessionTransport(selected: TerminalCandidate, preference: String) -> Bool {
        guard preference == "auto" || preference == "iterm" || preference == "iterm2" else { return false }
        guard selected.instance.app == .iterm2 else { return false }
        return selected.instance.terminalSessionId?.isEmpty == false
    }

    private func canUseFocusedKeyboardTransport(selected: TerminalCandidate) -> Bool {
        // Pasteboard/key-event insertion is window-scoped. It is only safe when
        // the selected terminal tab is already the active receiver. iTerm2 tab
        // queries currently do not expose active-tab state, so iTerm2 must use
        // tmux or direct session transport instead of app-level pasteboard.
        if selected.instance.app == .iterm2 {
            return false
        }
        if selected.instance.tabIndex != nil {
            return selected.instance.isActiveTab
        }
        return selected.instance.terminalSessionId == nil
    }

    private func insertText(
        _ text: String,
        selected: TerminalCandidate,
        window: WindowEntry,
        pressEnter: Bool,
        transportPreference: String
    ) throws -> (characters: Int, transport: String) {
        if canUseTmuxTransport(selected: selected, preference: transportPreference) {
            try insertTextViaTmux(text, selected: selected, pressEnter: pressEnter)
            return (text.count, "tmux")
        }
        if canUseITermSessionTransport(selected: selected, preference: transportPreference) {
            try insertTextViaITermSession(text, selected: selected, pressEnter: pressEnter)
            return (text.count, "iterm-session")
        }
        if transportPreference == "tmux" {
            throw RouterError.custom("tmux transport requested but target has no tmux pane")
        }
        if transportPreference == "iterm" || transportPreference == "iterm2" {
            throw RouterError.custom("iTerm session transport requested but target has no iTerm session id")
        }
        guard canUseFocusedKeyboardTransport(selected: selected) else {
            throw RouterError.custom("pasteboard/key-event transport requires the selected terminal tab to be active")
        }

        let typedCharacters = try CompanionKeyboardController.shared.typeText(
            text,
            targetPid: window.pid
        )
        if pressEnter {
            _ = try CompanionKeyboardController.shared.send(
                key: "enter",
                modifiers: [],
                targetPid: window.pid
            )
        }
        return (typedCharacters, text.count > 1 ? "pasteboard" : "key-events")
    }

    private func insertTextViaTmux(
        _ text: String,
        selected: TerminalCandidate,
        pressEnter: Bool
    ) throws {
        guard let tmux = TmuxQuery.resolvedPath else {
            throw RouterError.custom("tmux is not available")
        }
        guard let paneId = selected.instance.tmuxPaneId, !paneId.isEmpty else {
            throw RouterError.custom("target has no tmux pane")
        }
        if !text.isEmpty {
            guard ProcessQuery.run([tmux, "send-keys", "-t", paneId, "-l", text]) else {
                throw RouterError.custom("tmux failed to insert text into \(paneId)")
            }
        }
        if pressEnter {
            guard ProcessQuery.run([tmux, "send-keys", "-t", paneId, "Enter"]) else {
                throw RouterError.custom("tmux failed to press Enter in \(paneId)")
            }
        }
    }

    private func insertTextViaITermSession(
        _ text: String,
        selected: TerminalCandidate,
        pressEnter: Bool
    ) throws {
        guard let sessionId = selected.instance.terminalSessionId, !sessionId.isEmpty else {
            throw RouterError.custom("target has no iTerm session id")
        }

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique ID of s) is \(appleScriptString(sessionId)) then
                            select w
                            select t
                            select s
                            tell s to write text \(appleScriptString(text)) newline \(pressEnter ? "yes" : "no")
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            error "iTerm session not found"
        end tell
        """

        guard ProcessQuery.run(["/usr/bin/osascript", "-e", script]) else {
            throw RouterError.custom("iTerm failed to insert text into session \(sessionId)")
        }
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            + "\""
    }

    private func focusResponse(
        run: RunSession,
        target: WindowEntry,
        before: JSON?,
        after: JSON?,
        treatment: ComputerTreatment,
        focused: Bool
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string("focusWindow"),
            "treatment": .string(treatment.rawValue),
            "focused": .bool(focused),
            "run": run.json,
            "target": Encoders.window(target),
        ]
        if let before { object["beforeArtifact"] = before["artifact"] ?? before }
        if let after { object["afterArtifact"] = after["artifact"] ?? after }
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: focused ? "window.focus" : stagedRoute(for: treatment),
                foregroundChanged: focused,
                backgroundEligible: !focused
            ),
            to: &object
        )
        return .object(object)
    }

    private func response(
        action: String,
        run: RunSession,
        selected: TerminalCandidate,
        candidates: [TerminalCandidate],
        before: JSON?,
        after: JSON?,
        typedText: String,
        treatment: ComputerTreatment,
        pressedEnter: Bool,
        transport: String?
    ) -> JSON {
        var object: [String: JSON] = [
            "ok": .bool(true),
            "action": .string(action),
            "treatment": .string(treatment.rawValue),
            "run": run.json,
            "selected": selected.json,
            "candidates": .array(candidates.prefix(12).map(\.json)),
            "typedText": .string(typedText),
            "dryRun": .bool(!treatment.insertsText),
            "pressedEnter": .bool(pressedEnter),
        ]
        if let transport {
            object["transport"] = .string(transport)
        }
        if let before { object["beforeArtifact"] = before }
        if let after { object["afterArtifact"] = after }
        let route: String
        let backgroundEligible: Bool
        if !treatment.insertsText {
            route = stagedRoute(for: treatment)
            backgroundEligible = true
        } else if let transport {
            route = "terminal.\(transport)"
            backgroundEligible = transport == "tmux" || transport == "iterm-session"
        } else {
            route = "terminal.focused"
            backgroundEligible = false
        }
        attachBackgroundSafety(
            backgroundSafetyReceipt(
                route: route,
                foregroundChanged: treatment.focusesWindow && !backgroundEligible,
                backgroundEligible: backgroundEligible
            ),
            to: &object
        )
        return .object(object)
    }

    private static func defaultTypedText() -> String {
        "# lattices computer-use demo: observed, focused, typed; Enter intentionally not pressed"
    }

    private static func snapshotId() -> String {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return "axs_\(fileTimestamp())_\(suffix)"
    }

    private static func truncatedAXString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 240 {
            return trimmed
        }
        return String(trimmed.prefix(237)) + "..."
    }

    private static func singleLine(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return truncatedAXString(collapsed) ?? ""
    }

    private static func compactFrame(_ frame: CGRect) -> String {
        let x = Int(frame.origin.x.rounded())
        let y = Int(frame.origin.y.rounded())
        let w = Int(frame.width.rounded())
        let h = Int(frame.height.rounded())
        return "\(x),\(y),\(w),\(h)"
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct TerminalCandidate {
    let instance: TerminalInstance
    let score: Int
    let reason: String
    let activeCommand: String?

    var isSafeForTextInsertion: Bool {
        if let activeCommand,
           ["zsh", "bash", "fish", "sh", "dash"].contains(activeCommand),
           !instance.hasClaude {
            return true
        }
        guard instance.processes.isEmpty, !instance.hasClaude else { return false }
        guard let title = instance.windowTitle else { return false }
        let lowered = title.lowercased()
        if lowered.contains("claude") || lowered.contains("codex") || lowered.contains("vim") || lowered.contains("nvim") {
            return false
        }
        return title.contains("@") && title.contains(":") &&
            (title.contains("~/") || title.contains(":/") || title.hasSuffix(":~"))
    }

    var isSafeForEnter: Bool {
        guard let activeCommand else { return false }
        return ["zsh", "bash", "fish", "sh", "dash"].contains(activeCommand)
            && !instance.hasClaude
    }

    var json: JSON {
        var object: [String: JSON] = [
            "score": .int(score),
            "reason": .string(reason),
            "safeForTextInsertion": .bool(isSafeForTextInsertion),
            "terminal": Encoders.terminalInstance(instance),
        ]
        if let activeCommand {
            object["activeCommand"] = .string(activeCommand)
        }
        return .object(object)
    }
}
