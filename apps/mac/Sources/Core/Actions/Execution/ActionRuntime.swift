import AppKit
import ApplicationServices
import Foundation

final class ActionRuntime {
    static let shared = ActionRuntime()

    private let history = ActionHistoryStore(limit: 50)

    func execute(params: JSON?) throws -> JSON {
        guard case .object(let root) = params else {
            throw RouterError.missingParam("type")
        }

        if let actions = root["actions"]?.arrayValue {
            return try executeBatch(root: root, actions: actions)
        }

        let action = root["action"] ?? params
        return try executeOne(action: action, root: params)
    }

    func history(params: JSON?) -> JSON {
        history.list(params: params)
    }

    func undo(params: JSON?) throws -> JSON {
        let receipts = try selectUndoReceipts(params: params)
        let receipt = try executeUndo(receipts: receipts, params: params)
        let status = receipt["status"]?.stringValue
        let dryRun = receipt["dryRun"]?.boolValue == true
        let undoOf = receipt["undoOf"]?.arrayValue?.compactMap(\.stringValue) ?? []

        if status == "ok", !dryRun {
            history.recordUndo(receipt, undoOf: undoOf)
        } else {
            history.record(receipt)
        }

        return receipt
    }

    func resolveWindowPlace(params: JSON?) throws -> JSON {
        let normalizedParams = try Self.windowPlaceParams(action: params, root: params)
        let placement = PlacementSpec(json: normalizedParams["placement"] ?? normalizedParams["position"])
        let displayIndex = normalizedParams["display"]?.intValue
        var trace: [String] = []
        var events: [JSON] = []

        let resolved = try resolveWindowTarget(params: normalizedParams, trace: &trace, events: &events)
        let screen: NSScreen
        if let displayIndex {
            guard let requestedScreen = onMain({ DisplayGeometryMapper.screen(forDisplayIndex: displayIndex) }) else {
                throw RouterError.notFound("display \(displayIndex)")
            }
            screen = requestedScreen
        } else {
            screen = onMain {
                Self.resolveTargetScreen(for: resolved.entry, displayIndex: nil)
            }
        }

        var result: [String: JSON] = [
            "ok": .bool(true),
            "target": resolved.json,
            "targetKind": .string(resolved.kind),
            "targetResolution": .string(resolved.resolution),
            "display": screenJSON(screen, requestedIndex: displayIndex),
            "trace": .array(trace.map { .string($0) }),
            "events": .array(events),
        ]

        if let wid = resolved.wid { result["wid"] = .int(Int(wid)) }
        if let pid = resolved.pid { result["pid"] = .int(Int(pid)) }
        if let app = resolved.app { result["app"] = .string(app) }
        if let title = resolved.title { result["title"] = .string(title) }
        if let session = resolved.session { result["session"] = .string(session) }

        if let placement {
            let targetFrame = onMain {
                WindowTiler.tileFrame(for: placement, on: screen)
            }
            let beforeFrame = resolved.wid.flatMap { Self.cgWindowFrameTopLeft(wid: $0) }
            result["placement"] = placement.jsonValue
            result["plan"] = planJSON(
                target: resolved,
                placement: placement,
                targetFrame: targetFrame,
                beforeFrame: beforeFrame
            )
            result["verificationTolerance"] = .double(Double(Self.verificationTolerance(forApp: resolved.app)))
        }

        return .object(result)
    }

    func executeWindowPlace(
        params: JSON?,
        source: String = "daemon",
        requestId: String? = nil,
        compatibilityMethod: String? = nil
    ) throws -> JSON {
        let context = ActionInvocationContext(
            requestId: requestId ?? Self.makeId(prefix: "req"),
            actionId: Self.makeId(prefix: "act"),
            source: source,
            compatibilityMethod: compatibilityMethod
        )
        let receipt = try executeWindowPlace(params: params, context: context)
        history.record(receipt)
        return receipt
    }

    /// The UI, API, and placement actions share one serialized relocation.
    /// Display and absolute Space ID identify a single destination together.
    func executeWindowMove(params: JSON?, source: String = "daemon", target: WindowEntry? = nil, followWindow: Bool = false) throws -> JSON {
        let captured = target.map { ResolvedWindowTarget(kind: "wid", resolution: "gesture-start", confidence: 1.0, entry: $0) }
        let receipt = try executeWindowRelocation(params: params, source: source, resolvedTarget: captured, followWindow: followWindow)
        history.record(receipt)
        return receipt
    }

    // Mission Control owns one global drag session, so concurrent requests must
    // not interleave staging, transfer, and rollback operations.
    private static let relocationLock = NSRecursiveLock()

    private func executeWindowRelocation(
        params: JSON?,
        source: String,
        context: ActionInvocationContext? = nil,
        resolvedTarget: ResolvedWindowTarget? = nil,
        followWindow: Bool = false
    ) throws -> JSON {
        let dryRun = params?["dryRun"]?.boolValue == true
        if !dryRun && Thread.isMainThread {
            throw RouterError.custom("Window relocation must run off the main thread")
        }
        if !dryRun { Self.relocationLock.lock() }
        defer { if !dryRun { Self.relocationLock.unlock() } }
        let displayIndex = params?["display"]?.intValue
        let requestedSpaceId = params?["spaceId"]?.intValue
        let placementJSON = params?["placement"] ?? params?["position"]
        let placement = PlacementSpec(json: placementJSON)
        if placementJSON != nil && placement == nil {
            throw RouterError.custom("Unknown placement: \(placementJSON?.stringValue ?? "<object>")")
        }
        guard displayIndex != nil || requestedSpaceId != nil || placement != nil else {
            throw RouterError.missingParam("display, placement, or spaceId")
        }
        var trace: [String] = []
        var events: [JSON] = []
        let resolved = try resolvedTarget ?? resolveMoveTarget(params: params, trace: &trace, events: &events)
        guard let wid = resolved.wid, let pid = resolved.pid else {
            throw RouterError.custom("window.move requires a resolvable window")
        }
        let environment = relocationEnvironment(wid: wid, pid: pid, followWindow: followWindow)
        let before = environment.snapshot()
        guard let beforeFrame = before.frame, before.spaceIds.count == 1,
              let sourceSpaceId = before.spaceIds.first else {
            throw RouterError.custom("Window \(wid) must belong to one ordinary desktop and have observable geometry")
        }
        let displays = WindowTiler.getDisplaySpaces()
        guard let sourceDisplay = displays.first(where: { $0.spaces.contains(where: { $0.id == sourceSpaceId }) }),
              sourceDisplay.displayId == before.displayId else {
            throw RouterError.custom("Window \(wid) has inconsistent display and desktop membership")
        }
        let targetDisplay: DisplaySpaces
        if let displayIndex {
            guard let display = displays.first(where: { $0.displayIndex == displayIndex }) else {
                throw RouterError.notFound("display \(displayIndex)")
            }
            targetDisplay = display
        } else if let requestedSpaceId {
            guard let display = displays.first(where: { $0.spaces.contains(where: { $0.id == requestedSpaceId }) }) else {
                throw RouterError.notFound("desktop \(requestedSpaceId)")
            }
            targetDisplay = display
        } else {
            targetDisplay = sourceDisplay
        }
        // macOS holds an app assigned to a desktop (Dock › Options › Assign
        // To) on that desktop. Sent to its display, it goes there; sent to
        // another desktop on that display, macOS would pull it straight back.
        let binding = SpaceAssignments.binding(forPid: pid)
        let assignedHere: Int? = {
            guard case .desktop(let assigned)? = binding,
                  targetDisplay.spaces.contains(where: { $0.id == assigned }) else { return nil }
            return assigned
        }()
        // A placement without a display keeps the window on its own desktop.
        let spaceId = requestedSpaceId ?? (displayIndex == nil ? sourceSpaceId : assignedHere ?? targetDisplay.currentSpaceId)
        guard targetDisplay.spaces.contains(where: { $0.id == spaceId }) else {
            throw RouterError.custom("Desktop \(spaceId) does not belong to display \(targetDisplay.displayIndex), or is a full-screen Space")
        }
        let assignedConflict = SpaceAssignments.conflict(binding, destinationSpaceId: spaceId, displays: displays)
        guard let sourceScreen = onMain({ DisplayGeometryMapper.screen(for: sourceDisplay, in: NSScreen.screens) }),
              let targetScreen = onMain({ DisplayGeometryMapper.screen(for: targetDisplay, in: NSScreen.screens) }) else {
            throw RouterError.custom("Could not resolve source and destination displays")
        }
        let geometry = onMain { () -> ((x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)?, CGRect?) in
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let sourceVisible = DisplayGeometryMapper.topLeftFrame(sourceScreen.visibleFrame, primaryHeight: primaryHeight)
            let fractions = DisplayGeometryMapper.normalizedFractions(of: beforeFrame, in: sourceVisible)
            if let placement { return (fractions, WindowTiler.tileFrame(for: placement, on: targetScreen)) }
            // A desktop-only move preserves exact geometry on the same display.
            if sourceDisplay.displayId == targetDisplay.displayId { return (fractions, beforeFrame) }
            return (fractions, fractions.map { WindowTiler.tileFrame(fractions: $0, on: targetScreen) })
        }
        guard let targetFrame = geometry.1 else {
            throw RouterError.custom("Could not derive destination geometry for window \(wid)")
        }
        let destination = WindowRelocation.Destination(displayId: targetDisplay.displayId, spaceId: spaceId, frame: targetFrame)
        let tolerance = Self.verificationTolerance(forApp: resolved.app)
        var outcome: WindowRelocation.Result?
        var blockedReason: String?
        var assignmentMessage: String?
        if dryRun {
            trace.append("dry run; skipped relocation")
        } else if !AXIsProcessTrusted() {
            blockedReason = "accessibility-not-trusted"
            trace.append("blocked: Accessibility permission required")
        } else if let assigned = assignedConflict {
            blockedReason = "app-assigned-desktop"
            let name = resolved.app ?? "This app"
            assignmentMessage = "\(name) is assigned to \(SpaceAssignments.describe(spaceId: assigned, displays: displays)) in macOS (Dock › Options › Assign To), which pulls its windows back there"
            trace.append("blocked: \(name) is assigned to desktop \(assigned)")
        } else {
            DiagnosticLog.shared.info("WindowRelocation: wid=\(wid) display=\(sourceDisplay.displayIndex) spaces=\(before.spaceIds) → display=\(targetDisplay.displayIndex) space=\(spaceId)")
            outcome = WindowRelocation.execute(from: before, to: destination, tolerance: tolerance, environment: environment)
            trace.append(contentsOf: outcome!.trace)
            for step in outcome!.trace { DiagnosticLog.shared.info("WindowRelocation: wid=\(wid) \(step)") }
            DesktopModel.shared.markInteraction(wid: wid)
        }
        let after = outcome?.after ?? (dryRun ? nil : environment.snapshot())
        let verifiedFrame = after?.frame.map { Self.framesClose($0, targetFrame, tolerance: tolerance) } ?? false
        let verifiedDisplay = after?.displayId == targetDisplay.displayId
        let verifiedSpace = after?.spaceIds == [spaceId]
        let verified = outcome?.verified == true && verifiedFrame && verifiedDisplay && verifiedSpace
        let status = dryRun ? "planned" : blockedReason != nil ? "blocked" : verified ? "ok" : "failed"
        let actionType = placement == nil ? "window.move" : "window.place"
        events.append(event("relocation.verify", verified ? "verified display, desktop, and frame" : "\(status): \(outcome?.failure ?? trace.last ?? "not executed")"))
        var mutation: [String: JSON] = [
            "kind": .string(placement == nil ? "moveWindowToDisplay" : "placeWindow"),
            "wid": .int(Int(wid)), "pid": .int(Int(pid)),
            "from": Self.frameJSON(beforeFrame), "to": Self.frameJSON(targetFrame),
            "fromSpaceIds": .array(before.spaceIds.map { .int($0) }),
            "toSpaceId": .int(spaceId),
        ]
        if let afterFrame = after?.frame { mutation["after"] = Self.frameJSON(afterFrame) }
        if let after { mutation["afterSpaceIds"] = .array(after.spaceIds.map { .int($0) }) }
        var receipt: [String: JSON] = [
            "ok": .bool(status == "ok" || status == "planned"), "status": .string(status),
            "receiptId": .string(Self.makeId(prefix: "exec")),
            "requestId": .string(context?.requestId ?? Self.makeId(prefix: "req")), "source": .string(source),
            "action": .object(["id": .string(context?.actionId ?? Self.makeId(prefix: "act")), "type": .string(actionType)]),
            "target": resolved.json, "targetKind": .string(resolved.kind), "targetResolution": .string(resolved.resolution),
            "wid": .int(Int(wid)), "pid": .int(Int(pid)), "spaceId": .int(spaceId),
            "fromSpaceIds": .array(before.spaceIds.map { .int($0) }),
            "afterSpaceIds": .array((after?.spaceIds ?? []).map { .int($0) }),
            "dryRun": .bool(dryRun),
            "sourceDisplay": onMain { displayJSON(sourceScreen, requestedIndex: sourceDisplay.displayIndex) },
            "display": onMain { displayJSON(targetScreen, requestedIndex: targetDisplay.displayIndex) },
            "verificationTolerance": .double(Double(tolerance)),
            "plan": .object([
                "actionType": .string(actionType), "target": resolved.json,
                "steps": .array(["resolve display and desktop", "stage inactive source if needed", "transfer geometry", "move to destination desktop", "verify display, desktop, and frame"].map { .string($0) }),
                "mutations": .array([.object(mutation)]),
            ]),
            "mutations": .array([.object(mutation)]),
            "verified": .bool(verified), "verifiedFrame": .bool(verifiedFrame),
            "verifiedDisplay": .bool(verifiedDisplay), "verifiedSpace": .bool(verifiedSpace),
            "moved": .bool(verified && before != after), "method": .string("relocation"),
            "trace": .array(trace.map { .string($0) }), "events": .array(events),
            "timestamp": .double(Date().timeIntervalSince1970),
            "rollback": .object(["attempted": .bool(outcome?.rollbackAttempted == true), "verified": .bool(outcome?.rollbackVerified == true)]),
            "undoable": .bool(verified),
        ]
        if let fractions = geometry.0 {
            receipt["fractions"] = .object(["x": .double(Double(fractions.x)), "y": .double(Double(fractions.y)), "w": .double(Double(fractions.w)), "h": .double(Double(fractions.h))])
        }
        if let placement {
            receipt["placement"] = placement.jsonValue
            if context == nil { receipt["compatibilityMethod"] = .string("window.move") }
        }
        if let method = context?.compatibilityMethod { receipt["compatibilityMethod"] = .string(method) }
        if let app = resolved.app { receipt["app"] = .string(app) }
        if let title = resolved.title { receipt["title"] = .string(title) }
        if let session = resolved.session { receipt["session"] = .string(session) }
        if let failure = outcome?.failure { receipt["failureReason"] = .string(failure) }
        if let assigned = assignedConflict {
            receipt["assignedSpaceId"] = .int(assigned)
        }
        if let assignmentMessage {
            receipt["blockedReason"] = .string("app-assigned-desktop")
            receipt["message"] = .string(assignmentMessage)
        } else if let blockedReason {
            receipt["blockedReason"] = .string(blockedReason)
            receipt["requiredPermissions"] = .array([.string("accessibility")])
        }
        if verified && followWindow {
            // Verify the viewed desktop too, including when CGS moved the window
            // without needing the Mission Control carry fallback.
            let followed = WindowSpaceCarry.selectDesktop(spaceId, on: targetDisplay.displayId,
                                                          at: CGPoint(x: targetFrame.midX, y: targetFrame.midY))
            receipt["followed"] = .bool(followed)
            if followed {
                onMain {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    if let axWindow = WindowTiler.findAXWindowByFrame(wid: wid, pid: pid) {
                        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    }
                }
            }
        }
        if verified {
            receipt["undo"] = .object(["strategy": .string("restore-frame-and-space"), "requiresCurrentFrameMatch": .bool(true), "requiresCurrentSpaceMatch": .bool(true), "frameSource": .string("mutations.from")])
        }
        return .object(receipt)
    }

    private func relocationEnvironment(wid: UInt32, pid: Int32, followWindow: Bool = false) -> WindowRelocation.Environment {
        let snapshot = { [self] () -> WindowRelocation.Snapshot in
            let frame = Self.cgWindowFrameTopLeft(wid: wid)
            let spaces = WindowTiler.getSpacesForWindow(wid).sorted()
            let displays = WindowTiler.getDisplaySpaces()
            let displayId: String? = onMain {
                guard let frame else { return nil }
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let candidates = displays.compactMap { display -> (String, CGFloat)? in
                    guard let screen = DisplayGeometryMapper.screen(for: display, in: NSScreen.screens) else { return nil }
                    let bounds = DisplayGeometryMapper.topLeftFrame(screen.frame, primaryHeight: primaryHeight)
                    let intersection = bounds.intersection(frame)
                    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
                    return (display.displayId, intersection.width * intersection.height)
                }
                return candidates.max(by: { $0.1 < $1.1 })?.0
            }
            return WindowRelocation.Snapshot(frame: frame, displayId: displayId, spaceIds: spaces)
        }
        return WindowRelocation.Environment(
            displays: {
                WindowTiler.getDisplaySpaces().map { .init(id: $0.displayId, index: $0.displayIndex, currentSpaceId: $0.currentSpaceId, spaceIds: $0.spaces.map(\.id)) }
            },
            snapshot: snapshot,
            moveSpace: { [self] space in
                let from = WindowTiler.getSpacesForWindow(wid)
                if from == [space] { return nil }
                let result = onMain { WindowTiler.moveViaCGS(wid: wid, fromSpaces: from, toSpace: space, switchOnDenial: false) }
                if case .success = result, WindowTiler.getSpacesForWindow(wid) == [space] { return nil }
                if case .failed(let reason) = WindowSpaceCarry.carry(wid: wid, pid: pid, to: space, followWindow: followWindow) { return reason }
                return nil
            },
            moveFrame: { [self] frame in
                onMain { WindowTiler.batchMoveAndRaiseWindows([(wid: wid, pid: pid, frame: frame)], activation: .none) }
            },
            wait: { predicate in
                let deadline = Date().addingTimeInterval(1.2)
                var observed = snapshot()
                while !predicate(observed), Date() < deadline {
                    usleep(50_000)
                    observed = snapshot()
                }
                return observed
            }
        )
    }

    private func executeBatch(root: [String: JSON], actions: [JSON]) throws -> JSON {
        let requestId = root["requestId"]?.stringValue ?? Self.makeId(prefix: "req")
        let source = root["source"]?.stringValue ?? "daemon"
        var receipts: [JSON] = []
        var okCount = 0

        for action in actions {
            let context = ActionInvocationContext(
                requestId: requestId,
                actionId: action["id"]?.stringValue ?? Self.makeId(prefix: "act"),
                source: action["source"]?.stringValue ?? source,
                compatibilityMethod: nil
            )
            let receipt = try executeOne(action: action, root: .object(root), context: context)
            receipts.append(receipt)
            if receipt["ok"]?.boolValue == true { okCount += 1 }
        }

        let status: String
        if okCount == actions.count {
            status = "ok"
        } else if okCount > 0 {
            status = "partial"
        } else {
            status = "failed"
        }

        return .object([
            "ok": .bool(status == "ok"),
            "status": .string(status),
            "requestId": .string(requestId),
            "receipts": .array(receipts),
        ])
    }

    private func executeOne(action: JSON?, root: JSON?) throws -> JSON {
        let context = ActionInvocationContext(
            requestId: root?["requestId"]?.stringValue ?? action?["requestId"]?.stringValue ?? Self.makeId(prefix: "req"),
            actionId: action?["id"]?.stringValue ?? Self.makeId(prefix: "act"),
            source: root?["source"]?.stringValue ?? action?["source"]?.stringValue ?? "daemon",
            compatibilityMethod: nil
        )
        return try executeOne(action: action, root: root, context: context)
    }

    private func executeOne(action: JSON?, root: JSON?, context: ActionInvocationContext) throws -> JSON {
        let type = action?["type"]?.stringValue ?? root?["type"]?.stringValue
        guard type == "window.place" else {
            throw RouterError.custom("Unsupported action type: \(type ?? "<missing>")")
        }

        let placeParams = try Self.windowPlaceParams(action: action, root: root)
        let receipt = try executeWindowPlace(params: placeParams, context: context)
        history.record(receipt)
        return receipt
    }

    private func executeWindowPlace(params: JSON?, context: ActionInvocationContext) throws -> JSON {
        guard let placement = PlacementSpec(json: params?["placement"] ?? params?["position"]) else {
            throw RouterError.missingParam("placement")
        }

        let displayIndex = params?["display"]?.intValue
        let dryRun = params?["dryRun"]?.boolValue == true
        var trace: [String] = []
        var events: [JSON] = []

        let resolved = try resolveWindowTarget(params: params, trace: &trace, events: &events)
        if resolved.wid != nil, resolved.pid != nil,
           displayIndex != nil || params?["spaceId"]?.intValue != nil {
            return try executeWindowRelocation(params: params, source: context.source, context: context, resolvedTarget: resolved)
        }
        let screen: NSScreen
        if let displayIndex {
            guard let requestedScreen = onMain({ DisplayGeometryMapper.screen(forDisplayIndex: displayIndex) }) else {
                throw RouterError.notFound("display \(displayIndex)")
            }
            screen = requestedScreen
        } else {
            screen = onMain {
                Self.resolveTargetScreen(for: resolved.entry, displayIndex: nil)
            }
        }
        let targetFrame = onMain {
            WindowTiler.tileFrame(for: placement, on: screen)
        }
        let verificationTolerance = Self.verificationTolerance(forApp: resolved.app)

        trace.append("placement \(placement.wireValue)")
        events.append(event("plan.computeFrame", "computed \(placement.wireValue) on \(screen.localizedName)"))

        var beforeFrame: CGRect?
        if let wid = resolved.wid {
            beforeFrame = Self.cgWindowFrameTopLeft(wid: wid)
        }

        var blockedReason: String?
        var requiredPermissions: [String] = []

        if dryRun {
            trace.append("dry run; skipped execution")
            events.append(event("execute.skipped", "dry run requested; no window mutation performed"))
        } else if let wid = resolved.wid, let pid = resolved.pid {
            if !AXIsProcessTrusted() {
                blockedReason = "accessibility-not-trusted"
                requiredPermissions.append("accessibility")
                trace.append("blocked: Accessibility permission required for deterministic window placement")
                events.append(event("execute.blocked", "Accessibility permission required to move wid \(wid)"))
            } else {
                onMain {
                    WindowTiler.tileWindowById(wid: wid, pid: pid, to: placement, on: screen)
                }
                DesktopModel.shared.markInteraction(wid: wid)
                trace.append("executed window move")
                events.append(event("execute.placeWindow", "moved wid \(wid)"))
            }
        } else if let session = resolved.session {
            let terminal = Preferences.shared.terminal
            onMain {
                WindowTiler.tile(session: session, terminal: terminal, to: placement, on: screen)
            }
            trace.append("executed terminal session fallback")
            events.append(event("execute.placeSessionWindow", "placed session \(session) through terminal fallback"))
        }

        let afterFrame = dryRun ? nil : resolved.wid.flatMap { wid in
            Self.waitForWindowFrame(
                wid: wid,
                targetFrame: targetFrame,
                tolerance: verificationTolerance
            )
        }
        let verified = dryRun ? false : (afterFrame.map { Self.framesClose($0, targetFrame, tolerance: verificationTolerance) } ?? false)
        if dryRun {
            trace.append("verification skipped for dry run")
            events.append(event("verify.skipped", "dry run requested; no final frame verification performed"))
        } else if verified {
            trace.append("verified target frame")
            events.append(event("verify.frame", "verified final frame"))
        } else if afterFrame != nil {
            trace.append("verification could not confirm exact target frame")
            events.append(event("verify.frame", "final frame did not match target within tolerance"))
        } else {
            trace.append("verification unavailable")
            events.append(event("verify.frame", "no window id available for verification"))
        }

        let status: String
        if dryRun {
            status = "planned"
        } else if blockedReason != nil {
            status = "blocked"
        } else if resolved.wid == nil || verified {
            status = "ok"
        } else {
            status = "failed"
        }
        let ok = status == "ok" || status == "planned"

        let receiptId = Self.makeId(prefix: "exec")
        var receipt: [String: JSON] = [
            "ok": .bool(ok),
            "status": .string(status),
            "receiptId": .string(receiptId),
            "requestId": .string(context.requestId),
            "source": .string(context.source),
            "action": .object([
                "id": .string(context.actionId),
                "type": .string("window.place"),
            ]),
            "target": resolved.json,
            "targetKind": .string(resolved.kind),
            "targetResolution": .string(resolved.resolution),
            "placement": placement.jsonValue,
            "dryRun": .bool(dryRun),
            "display": screenJSON(screen, requestedIndex: displayIndex),
            "verificationTolerance": .double(Double(verificationTolerance)),
            "plan": planJSON(
                target: resolved,
                placement: placement,
                targetFrame: targetFrame,
                beforeFrame: beforeFrame
            ),
            "mutations": .array([
                mutationJSON(
                    target: resolved,
                    beforeFrame: beforeFrame,
                    targetFrame: targetFrame,
                    afterFrame: afterFrame
                )
            ]),
            "verified": .bool(verified),
            "trace": .array(trace.map { .string($0) }),
            "events": .array(events),
            "timestamp": .double(Date().timeIntervalSince1970),
        ]

        if let wid = resolved.wid { receipt["wid"] = .int(Int(wid)) }
        if let pid = resolved.pid { receipt["pid"] = .int(Int(pid)) }
        if let app = resolved.app { receipt["app"] = .string(app) }
        if let title = resolved.title { receipt["title"] = .string(title) }
        if let session = resolved.session { receipt["session"] = .string(session) }
        if let blockedReason {
            receipt["blockedReason"] = .string(blockedReason)
        }
        if !requiredPermissions.isEmpty {
            receipt["requiredPermissions"] = .array(requiredPermissions.map { .string($0) })
        }
        if let compatibilityMethod = context.compatibilityMethod {
            receipt["compatibilityMethod"] = .string(compatibilityMethod)
        }
        let undoable = status == "ok" &&
            !dryRun &&
            resolved.wid != nil &&
            resolved.pid != nil &&
            beforeFrame != nil &&
            afterFrame != nil
        receipt["undoable"] = .bool(undoable)
        if undoable {
            receipt["undo"] = .object([
                "strategy": .string("restore-frame"),
                "requiresCurrentFrameMatch": .bool(true),
                "frameSource": .string("mutations.from"),
            ])
        }

        return .object(receipt)
    }

    private func selectUndoReceipts(params: JSON?) throws -> [JSON] {
        let receiptId = params?["receiptId"]?.stringValue
        let requestId = params?["requestId"]?.stringValue
        let wid = params?["wid"]?.uint32Value
        let steps = max(1, params?["steps"]?.intValue ?? 1)

        let snapshot = history.snapshot()
        let receipts = snapshot.receipts
        let undone = snapshot.undoneReceiptIds

        func matchesFilters(_ receipt: JSON) -> Bool {
            if let wid, receipt["wid"]?.uint32Value != wid {
                return false
            }
            return true
        }

        if let receiptId {
            guard let receipt = receipts.first(where: { $0["receiptId"]?.stringValue == receiptId }) else {
                throw RouterError.notFound("action receipt \(receiptId)")
            }
            guard matchesFilters(receipt), isUndoableReceipt(receipt, undoneReceiptIds: undone) else {
                throw RouterError.custom("Receipt \(receiptId) is not undoable")
            }
            return [receipt]
        }

        if let requestId {
            let selected = receipts.filter { receipt in
                receipt["requestId"]?.stringValue == requestId &&
                    matchesFilters(receipt) &&
                    isUndoableReceipt(receipt, undoneReceiptIds: undone)
            }
            guard !selected.isEmpty else {
                throw RouterError.notFound("undoable receipts for request \(requestId)")
            }
            return selected
        }

        let candidates = receipts.filter { receipt in
            matchesFilters(receipt) && isUndoableReceipt(receipt, undoneReceiptIds: undone)
        }

        guard !candidates.isEmpty else {
            throw RouterError.notFound("undoable action")
        }

        if wid != nil {
            return Array(candidates.prefix(steps))
        }

        var selected: [JSON] = []
        var seenRequestIds: Set<String> = []
        for receipt in candidates {
            let groupId = receipt["requestId"]?.stringValue ?? receipt["receiptId"]?.stringValue ?? UUID().uuidString
            guard !seenRequestIds.contains(groupId) else { continue }
            seenRequestIds.insert(groupId)
            selected.append(contentsOf: candidates.filter { ($0["requestId"]?.stringValue ?? $0["receiptId"]?.stringValue) == groupId })
            if seenRequestIds.count >= steps {
                break
            }
        }

        return selected
    }

    private func executeUndo(receipts: [JSON], params: JSON?) throws -> JSON {
        let dryRun = params?["dryRun"]?.boolValue == true
        if !dryRun && Thread.isMainThread { throw RouterError.custom("Window undo must run off the main thread") }
        if !dryRun { Self.relocationLock.lock() }
        defer { if !dryRun { Self.relocationLock.unlock() } }
        let force = params?["force"]?.boolValue == true
        let source = params?["source"]?.stringValue ?? "daemon"
        let requestId = params?["requestId"]?.stringValue ?? Self.makeId(prefix: "req")
        let actionId = params?["id"]?.stringValue ?? Self.makeId(prefix: "act")
        let receiptId = Self.makeId(prefix: "exec")
        let undoOf = receipts.compactMap { $0["receiptId"]?.stringValue }
        let requestIds = Array(Set(receipts.compactMap { $0["requestId"]?.stringValue })).sorted()
        let moves = receipts.flatMap { undoMoves(from: $0) }

        guard !moves.isEmpty else {
            throw RouterError.custom("Selected receipts do not contain restorable window frames")
        }

        if Set(moves.map(\.wid)).count != moves.count {
            throw RouterError.custom("Multi-step undo for repeated windows is not supported yet; undo one step at a time")
        }

        var trace: [String] = [
            "selected \(receipts.count) receipt\(receipts.count == 1 ? "" : "s")",
            "prepared \(moves.count) restore mutation\(moves.count == 1 ? "" : "s")",
        ]
        var events: [JSON] = [
            event("undo.select", "selected \(receipts.count) receipt\(receipts.count == 1 ? "" : "s")"),
            event("undo.plan", "prepared \(moves.count) restore mutation\(moves.count == 1 ? "" : "s")"),
        ]

        var plannedMoves: [PlannedUndoMove] = []
        var conflicts: [JSON] = []
        var blockedReason: String?
        var requiredPermissions: [String] = []

        for move in moves {
            let currentFrame = Self.cgWindowFrameTopLeft(wid: move.wid)
            if !force {
                if let expectedSpaces = move.expectedCurrentSpaceIds,
                   WindowTiler.getSpacesForWindow(move.wid).sorted() != expectedSpaces.sorted() {
                    conflicts.append(undoConflictJSON(move: move, currentFrame: currentFrame, reason: "current-space-mismatch"))
                }
                if let currentFrame, let expected = move.expectedCurrentFrame {
                    if !Self.framesClose(currentFrame, expected, tolerance: move.tolerance) {
                        conflicts.append(undoConflictJSON(move: move, currentFrame: currentFrame))
                    }
                } else if currentFrame == nil {
                    conflicts.append(undoConflictJSON(move: move, currentFrame: nil))
                }
            }
            plannedMoves.append(PlannedUndoMove(move: move, currentFrame: currentFrame, afterFrame: nil))
        }

        if !conflicts.isEmpty {
            blockedReason = "current-frame-mismatch"
            trace.append("blocked: current frame did not match receipt state")
            events.append(event("undo.blocked", "current frame did not match receipt state"))
        } else if !dryRun && !AXIsProcessTrusted() {
            blockedReason = "accessibility-not-trusted"
            requiredPermissions.append("accessibility")
            trace.append("blocked: Accessibility permission required for deterministic window restore")
            events.append(event("undo.blocked", "Accessibility permission required to restore windows"))
        } else if dryRun {
            trace.append("dry run; skipped restore")
            events.append(event("undo.skipped", "dry run requested; no window mutation performed"))
        } else {
            plannedMoves = plannedMoves.map { planned in
                var updated = planned
                let move = planned.move
                if let restoreSpace = move.restoreSpaceId {
                    let environment = relocationEnvironment(wid: move.wid, pid: move.pid)
                    guard let display = environment.displays().first(where: { $0.spaceIds.contains(restoreSpace) }) else {
                        trace.append("undo failed: original desktop \(restoreSpace) is unavailable")
                        updated.relocationVerified = false
                        return updated
                    }
                    let destination = WindowRelocation.Destination(displayId: display.id, spaceId: restoreSpace, frame: move.restoreFrame)
                    let outcome = WindowRelocation.execute(from: environment.snapshot(), to: destination, tolerance: move.tolerance, environment: environment)
                    updated.afterFrame = outcome.after.frame
                    updated.afterSpaceIds = outcome.after.spaceIds
                    updated.relocationVerified = outcome.verified
                    trace.append(contentsOf: outcome.trace.map { "undo wid=\(move.wid): \($0)" })
                } else {
                    // Receipts created before desktop-aware relocation only
                    // contain a frame, so retain their original undo contract.
                    onMain { WindowTiler.batchMoveAndRaiseWindows([(wid: move.wid, pid: move.pid, frame: move.restoreFrame)]) }
                    updated.afterFrame = Self.waitForWindowFrame(wid: move.wid, targetFrame: move.restoreFrame, tolerance: move.tolerance)
                }
                return updated
            }
            events.append(event("undo.restore", "attempted \(moves.count) window restore mutations"))
            DesktopModel.shared.markInteraction(wids: moves.map(\.wid))
        }

        let verified = !dryRun && blockedReason == nil && plannedMoves.allSatisfy { planned in
            guard let after = planned.afterFrame, planned.relocationVerified != false else { return false }
            return Self.framesClose(after, planned.move.restoreFrame, tolerance: planned.move.tolerance)
        }

        if verified {
            trace.append("verified restored frame\(plannedMoves.count == 1 ? "" : "s")")
            events.append(event("undo.verify", "verified restored frame\(plannedMoves.count == 1 ? "" : "s")"))
        } else if dryRun {
            trace.append("verification skipped for dry run")
            events.append(event("undo.verify.skipped", "dry run requested; no final frame verification performed"))
        } else if blockedReason == nil {
            trace.append("verification could not confirm restored frame\(plannedMoves.count == 1 ? "" : "s")")
            events.append(event("undo.verify", "restored frame verification failed"))
        }

        let status: String
        if blockedReason != nil {
            status = "blocked"
        } else if dryRun {
            status = "planned"
        } else if verified {
            status = "ok"
        } else {
            status = "failed"
        }
        let ok = status == "ok" || status == "planned"

        var receipt: [String: JSON] = [
            "ok": .bool(ok),
            "status": .string(status),
            "receiptId": .string(receiptId),
            "requestId": .string(requestId),
            "source": .string(source),
            "action": .object([
                "id": .string(actionId),
                "type": .string("actions.undo"),
            ]),
            "target": .object([
                "kind": .string("undo"),
                "receiptCount": .int(receipts.count),
                "mutationCount": .int(moves.count),
            ]),
            "targetKind": .string("undo"),
            "targetResolution": .string("history"),
            "undoOf": .array(undoOf.map { .string($0) }),
            "undoRequestIds": .array(requestIds.map { .string($0) }),
            "dryRun": .bool(dryRun),
            "force": .bool(force),
            "mutations": .array(plannedMoves.map { undoMutationJSON($0) }),
            "verified": .bool(verified),
            "undoable": .bool(false),
            "trace": .array(trace.map { .string($0) }),
            "events": .array(events),
            "timestamp": .double(Date().timeIntervalSince1970),
        ]

        if let blockedReason {
            receipt["blockedReason"] = .string(blockedReason)
        }
        if !requiredPermissions.isEmpty {
            receipt["requiredPermissions"] = .array(requiredPermissions.map { .string($0) })
        }
        if !conflicts.isEmpty {
            receipt["conflicts"] = .array(conflicts)
        }

        return .object(receipt)
    }

    private func resolveWindowTarget(params: JSON?, trace: inout [String], events: inout [JSON]) throws -> ResolvedWindowTarget {
        if let wid = params?["wid"]?.uint32Value {
            guard let entry = DesktopModel.shared.windows[wid] else {
                throw RouterError.notFound("window \(wid)")
            }
            trace.append("resolved target by wid")
            events.append(event("plan.resolveTarget", "resolved wid \(wid)"))
            return ResolvedWindowTarget(kind: "wid", resolution: "wid", confidence: 1.0, entry: entry)
        }

        if let session = params?["session"]?.stringValue {
            if let entry = DesktopModel.shared.windowForSession(session) {
                trace.append("resolved target by session")
                events.append(event("plan.resolveTarget", "resolved session \(session) to wid \(entry.wid)"))
                return ResolvedWindowTarget(kind: "session", resolution: "session", confidence: 1.0, entry: entry, session: session)
            }

            if let entry = Self.windowForSessionViaTerminalSynthesis(session) {
                trace.append("resolved target by terminal synthesis")
                events.append(event("plan.resolveTarget", "resolved session \(session) through terminal synthesis to wid \(entry.wid)"))
                return ResolvedWindowTarget(
                    kind: "session",
                    resolution: "terminal-synthesis",
                    confidence: 0.9,
                    entry: entry,
                    session: session
                )
            }

            trace.append("session window not in DesktopModel; using terminal fallback")
            events.append(event("plan.resolveTarget", "session \(session) will use terminal fallback"))
            return ResolvedWindowTarget(kind: "session", resolution: "terminal-fallback", confidence: 0.4, session: session)
        }

        if let app = params?["app"]?.stringValue {
            let title = params?["title"]?.stringValue
            guard let entry = DesktopModel.shared.windowForApp(app: app, title: title) else {
                throw RouterError.notFound("window for app \(app)")
            }
            trace.append("resolved target by app/title match")
            events.append(event("plan.resolveTarget", "resolved app \(app) to wid \(entry.wid)"))
            return ResolvedWindowTarget(kind: "app", resolution: "app-title", confidence: title == nil ? 0.75 : 0.9, entry: entry)
        }

        if let target = Self.frontmostWindowTarget() {
            let entry = DesktopModel.shared.windows[target.wid]
            trace.append("resolved target by frontmost window")
            events.append(event("plan.resolveTarget", "resolved frontmost window \(target.wid)"))
            return ResolvedWindowTarget(
                kind: "frontmost",
                resolution: "frontmost",
                confidence: 0.85,
                entry: entry,
                wid: target.wid,
                pid: target.pid
            )
        }

        throw RouterError.custom("Could not resolve a window target for placement")
    }

    /// Strict target resolution for `window.move`: an explicit wid or session
    /// only. Never falls back to the frontmost window — a malformed or missing
    /// target must fail loudly rather than move whatever happens to be focused.
    private func resolveMoveTarget(params: JSON?, trace: inout [String], events: inout [JSON]) throws -> ResolvedWindowTarget {
        if let wid = params?["wid"]?.uint32Value {
            guard let entry = DesktopModel.shared.windows[wid] else {
                throw RouterError.notFound("window \(wid)")
            }
            trace.append("resolved target by wid")
            events.append(event("plan.resolveTarget", "resolved wid \(wid)"))
            return ResolvedWindowTarget(kind: "wid", resolution: "wid", confidence: 1.0, entry: entry)
        }

        if let session = params?["session"]?.stringValue {
            if let entry = DesktopModel.shared.windowForSession(session) {
                trace.append("resolved target by session")
                events.append(event("plan.resolveTarget", "resolved session \(session) to wid \(entry.wid)"))
                return ResolvedWindowTarget(kind: "session", resolution: "session", confidence: 1.0, entry: entry, session: session)
            }
            if let entry = Self.windowForSessionViaTerminalSynthesis(session) {
                trace.append("resolved target by terminal synthesis")
                events.append(event("plan.resolveTarget", "resolved session \(session) through terminal synthesis to wid \(entry.wid)"))
                return ResolvedWindowTarget(kind: "session", resolution: "terminal-synthesis", confidence: 0.9, entry: entry, session: session)
            }
            throw RouterError.notFound("window for session \(session)")
        }

        throw RouterError.missingParam("wid or session")
    }

    private static func windowPlaceParams(action: JSON?, root: JSON?) throws -> JSON {
        var dict: [String: JSON] = [:]

        func copy(_ key: String, from json: JSON?) {
            if let value = json?[key] {
                dict[key] = value
            }
        }

        if case .object(let args) = action?["args"] {
            for (key, value) in args {
                dict[key] = value
            }
        }

        for key in ["placement", "position", "display", "spaceId", "dryRun", "wid", "session", "app", "title"] {
            copy(key, from: root)
            copy(key, from: action)
        }

        if let target = action?["target"] ?? root?["target"] {
            try mergeTarget(target, into: &dict)
        }

        return .object(dict)
    }

    private static func mergeTarget(_ target: JSON, into dict: inout [String: JSON]) throws {
        guard case .object(let obj) = target else {
            throw RouterError.custom("target must be an object")
        }
        let kind = obj["kind"]?.stringValue?.lowercased() ?? "frontmost"

        switch kind {
        case "frontmost", "current":
            return
        case "wid", "window":
            guard let wid = obj["wid"] ?? obj["id"] else {
                throw RouterError.missingParam("target.wid")
            }
            dict["wid"] = wid
        case "session":
            guard let session = obj["session"] ?? obj["name"] else {
                throw RouterError.missingParam("target.session")
            }
            dict["session"] = session
        case "app":
            guard let app = obj["app"] ?? obj["name"] else {
                throw RouterError.missingParam("target.app")
            }
            dict["app"] = app
            if let title = obj["title"] {
                dict["title"] = title
            }
        default:
            throw RouterError.custom("Unsupported window.place target kind: \(kind)")
        }
    }

    private func event(_ phase: String, _ message: String) -> JSON {
        .object([
            "phase": .string(phase),
            "message": .string(message),
            "time": .double(Date().timeIntervalSince1970),
        ])
    }

    private func planJSON(
        target: ResolvedWindowTarget,
        placement: PlacementSpec,
        targetFrame: CGRect,
        beforeFrame: CGRect?
    ) -> JSON {
        var mutation: [String: JSON] = [
            "kind": .string(target.wid == nil ? "placeSessionWindow" : "placeWindow"),
            "to": Self.frameJSON(targetFrame),
        ]
        if let wid = target.wid { mutation["wid"] = .int(Int(wid)) }
        if let session = target.session { mutation["session"] = .string(session) }
        if let beforeFrame { mutation["from"] = Self.frameJSON(beforeFrame) }

        return .object([
            "actionType": .string("window.place"),
            "target": target.json,
            "placement": placement.jsonValue,
            "steps": .array([
                .string("resolve target"),
                .string("compute frame"),
                .string(target.wid == nil ? "place session window" : "place window"),
                .string("verify frame"),
            ]),
            "mutations": .array([.object(mutation)]),
        ])
    }

    private func mutationJSON(
        target: ResolvedWindowTarget,
        beforeFrame: CGRect?,
        targetFrame: CGRect,
        afterFrame: CGRect?
    ) -> JSON {
        var obj: [String: JSON] = [
            "kind": .string(target.wid == nil ? "placeSessionWindow" : "placeWindow"),
            "to": Self.frameJSON(targetFrame),
        ]
        if let wid = target.wid { obj["wid"] = .int(Int(wid)) }
        if let pid = target.pid { obj["pid"] = .int(Int(pid)) }
        if let session = target.session { obj["session"] = .string(session) }
        if let beforeFrame { obj["from"] = Self.frameJSON(beforeFrame) }
        if let afterFrame { obj["after"] = Self.frameJSON(afterFrame) }
        return .object(obj)
    }

    private func undoMoves(from receipt: JSON) -> [UndoMove] {
        guard let mutations = receipt["mutations"]?.arrayValue else { return [] }
        let receiptId = receipt["receiptId"]?.stringValue ?? "<unknown>"
        let requestId = receipt["requestId"]?.stringValue
        let app = receipt["app"]?.stringValue
        let session = receipt["session"]?.stringValue
        let tolerance = CGFloat(receipt["verificationTolerance"]?.numericDouble ?? Double(Self.verificationTolerance(forApp: app)))

        return mutations.compactMap { mutation in
            guard let wid = mutation["wid"]?.uint32Value,
                  let pidInt = mutation["pid"]?.intValue ?? receipt["pid"]?.intValue,
                  let restoreFrame = Self.frame(from: mutation["from"]) else {
                return nil
            }
            let expectedCurrent = Self.frame(from: mutation["after"]) ?? Self.frame(from: mutation["to"])
            return UndoMove(
                receiptId: receiptId,
                requestId: requestId,
                wid: wid,
                pid: Int32(pidInt),
                app: app,
                session: session,
                restoreFrame: restoreFrame,
                expectedCurrentFrame: expectedCurrent,
                restoreSpaceId: mutation["fromSpaceIds"]?.arrayValue.flatMap { $0.count == 1 ? $0.first?.intValue : nil },
                expectedCurrentSpaceIds: mutation["afterSpaceIds"]?.arrayValue.map { $0.compactMap(\.intValue) },
                tolerance: tolerance
            )
        }
    }

    private func isUndoableReceipt(_ receipt: JSON, undoneReceiptIds: Set<String>) -> Bool {
        let actionType = receipt["action"]?["type"]?.stringValue
        guard let receiptId = receipt["receiptId"]?.stringValue,
              !undoneReceiptIds.contains(receiptId),
              receipt["status"]?.stringValue == "ok",
              actionType == "window.place" || actionType == "window.move" else {
            return false
        }
        if receipt["undoable"]?.boolValue == false {
            return false
        }
        return !undoMoves(from: receipt).isEmpty
    }

    private func undoMutationJSON(_ planned: PlannedUndoMove) -> JSON {
        let move = planned.move
        var obj: [String: JSON] = [
            "kind": .string("restoreFrame"),
            "receiptId": .string(move.receiptId),
            "wid": .int(Int(move.wid)),
            "pid": .int(Int(move.pid)),
            "from": planned.currentFrame.map(Self.frameJSON) ?? .null,
            "to": Self.frameJSON(move.restoreFrame),
            "tolerance": .double(Double(move.tolerance)),
        ]
        if let requestId = move.requestId { obj["requestId"] = .string(requestId) }
        if let app = move.app { obj["app"] = .string(app) }
        if let session = move.session { obj["session"] = .string(session) }
        if let expected = move.expectedCurrentFrame { obj["expectedCurrent"] = Self.frameJSON(expected) }
        if let after = planned.afterFrame { obj["after"] = Self.frameJSON(after) }
        if let space = move.restoreSpaceId { obj["toSpaceId"] = .int(space) }
        if let spaces = planned.afterSpaceIds { obj["afterSpaceIds"] = .array(spaces.map { .int($0) }) }
        if let verified = planned.relocationVerified { obj["verified"] = .bool(verified) }
        return .object(obj)
    }

    private func undoConflictJSON(move: UndoMove, currentFrame: CGRect?, reason: String? = nil) -> JSON {
        var obj: [String: JSON] = [
            "receiptId": .string(move.receiptId),
            "wid": .int(Int(move.wid)),
            "reason": .string(reason ?? (currentFrame == nil ? "window-frame-unavailable" : "current-frame-mismatch")),
            "target": Self.frameJSON(move.restoreFrame),
            "tolerance": .double(Double(move.tolerance)),
        ]
        if let currentFrame { obj["current"] = Self.frameJSON(currentFrame) }
        if let expected = move.expectedCurrentFrame { obj["expectedCurrent"] = Self.frameJSON(expected) }
        if let spaces = move.expectedCurrentSpaceIds {
            obj["expectedSpaceIds"] = .array(spaces.map { .int($0) })
            obj["currentSpaceIds"] = .array(WindowTiler.getSpacesForWindow(move.wid).map { .int($0) })
        }
        return .object(obj)
    }

    private func screenJSON(_ screen: NSScreen, requestedIndex: Int?) -> JSON {
        let resolvedIndex = NSScreen.screens.firstIndex(where: { $0 === screen })
        var obj: [String: JSON] = [
            "name": .string(screen.localizedName),
            "resolvedIndex": .int(resolvedIndex ?? -1),
        ]
        if let requestedIndex {
            obj["requestedIndex"] = .int(requestedIndex)
        }
        return .object(obj)
    }

    /// screenJSON plus the SkyLight display index and visible frame in API
    /// (top-left) coordinates. Call on the main thread.
    private func displayJSON(_ screen: NSScreen, requestedIndex: Int?) -> JSON {
        guard case .object(var obj) = screenJSON(screen, requestedIndex: requestedIndex) else {
            return screenJSON(screen, requestedIndex: requestedIndex)
        }
        let screens = NSScreen.screens
        if let display = WindowTiler.getDisplaySpaces().first(where: {
            DisplayGeometryMapper.screen(for: $0, in: screens) === screen
        }) {
            obj["displayIndex"] = .int(display.displayIndex)
        }
        let primaryHeight = screens.first?.frame.height ?? 0
        obj["visibleFrame"] = Self.frameJSON(
            DisplayGeometryMapper.topLeftFrame(screen.visibleFrame, primaryHeight: primaryHeight)
        )
        return .object(obj)
    }

    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
            abs(a.origin.y - b.origin.y) <= tolerance &&
            abs(a.width - b.width) <= tolerance &&
            abs(a.height - b.height) <= tolerance
    }

    private static func verificationTolerance(forApp app: String?) -> CGFloat {
        guard let app else { return 6 }
        if app == "Terminal" || app == "iTerm2" {
            return 14
        }
        return 6
    }

    private static func windowForSessionViaTerminalSynthesis(_ session: String) -> WindowEntry? {
        ProcessModel.shared.synthesizeTerminals()
            .first { $0.tmuxSession == session }
            .flatMap { instance in
                instance.windowId.flatMap { DesktopModel.shared.windows[$0] }
            }
    }

    private static func waitForWindowFrame(
        wid: UInt32,
        targetFrame: CGRect,
        tolerance: CGFloat,
        timeout: TimeInterval = 0.8,
        interval: useconds_t = 50_000
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame: CGRect?

        repeat {
            if let frame = Self.cgWindowFrameTopLeft(wid: wid) {
                lastFrame = frame
                if framesClose(frame, targetFrame, tolerance: tolerance) {
                    return frame
                }
            }
            usleep(interval)
        } while Date() < deadline

        return lastFrame
    }

    private static func cgWindowFrameTopLeft(wid: UInt32) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  windowNumber == wid,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(bounds, &rect) {
                return rect
            }
        }

        return nil
    }

    private static func frame(from json: JSON?) -> CGRect? {
        guard case .object(let obj) = json,
              let x = obj["x"]?.numericDouble,
              let y = obj["y"]?.numericDouble,
              let w = obj["w"]?.numericDouble,
              let h = obj["h"]?.numericDouble else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func resolveTargetScreen(for entry: WindowEntry?, displayIndex: Int?) -> NSScreen {
        if let displayIndex, let screen = DisplayGeometryMapper.screen(forDisplayIndex: displayIndex) {
            return screen
        }
        if let entry {
            return WindowTiler.screenForWindowFrame(entry.frame)
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private static func frontmostWindowTarget() -> (wid: UInt32, pid: Int32)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !LatticesRuntime.isLatticesBundleIdentifier(app.bundleIdentifier) else {
            return nil
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedWindow = focusedRef else {
            return nil
        }

        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focusedWindow as! AXUIElement, &wid) == .success else {
            return nil
        }
        return (UInt32(wid), app.processIdentifier)
    }

    private static func frameJSON(_ frame: CGRect) -> JSON {
        .object([
            "x": .double(Double(frame.origin.x)),
            "y": .double(Double(frame.origin.y)),
            "w": .double(Double(frame.width)),
            "h": .double(Double(frame.height)),
        ])
    }

    private static func makeId(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.lowercased())"
    }
}

private struct ActionInvocationContext {
    let requestId: String
    let actionId: String
    let source: String
    let compatibilityMethod: String?
}

private struct UndoMove {
    let receiptId: String
    let requestId: String?
    let wid: UInt32
    let pid: Int32
    let app: String?
    let session: String?
    let restoreFrame: CGRect
    let expectedCurrentFrame: CGRect?
    let restoreSpaceId: Int?
    let expectedCurrentSpaceIds: [Int]?
    let tolerance: CGFloat
}

private struct PlannedUndoMove {
    let move: UndoMove
    let currentFrame: CGRect?
    var afterFrame: CGRect?
    var afterSpaceIds: [Int]? = nil
    var relocationVerified: Bool? = nil
}

private struct ResolvedWindowTarget {
    let kind: String
    let resolution: String
    let confidence: Double
    let entry: WindowEntry?
    let session: String?
    let explicitWid: UInt32?
    let explicitPid: Int32?

    init(
        kind: String,
        resolution: String,
        confidence: Double,
        entry: WindowEntry? = nil,
        session: String? = nil,
        wid: UInt32? = nil,
        pid: Int32? = nil
    ) {
        self.kind = kind
        self.resolution = resolution
        self.confidence = confidence
        self.entry = entry
        self.session = session ?? entry?.latticesSession
        self.explicitWid = wid
        self.explicitPid = pid
    }

    var wid: UInt32? { entry?.wid ?? explicitWid }
    var pid: Int32? { entry?.pid ?? explicitPid }
    var app: String? { entry?.app }
    var title: String? { entry?.title }

    var json: JSON {
        var obj: [String: JSON] = [
            "kind": .string(kind),
            "resolution": .string(resolution),
            "confidence": .double(confidence),
        ]
        if let wid { obj["wid"] = .int(Int(wid)) }
        if let pid { obj["pid"] = .int(Int(pid)) }
        if let app { obj["app"] = .string(app) }
        if let title { obj["title"] = .string(title) }
        if let session { obj["session"] = .string(session) }
        return .object(obj)
    }
}

private final class ActionHistoryStore {
    private let limit: Int
    private let lock = NSLock()
    private var receipts: [JSON] = []
    private var undoneReceiptIds: Set<String> = []

    init(limit: Int) {
        self.limit = limit
    }

    func record(_ receipt: JSON) {
        lock.lock()
        receipts.insert(receipt, at: 0)
        if receipts.count > limit {
            receipts.removeLast(receipts.count - limit)
        }
        lock.unlock()
    }

    func recordUndo(_ receipt: JSON, undoOf receiptIds: [String]) {
        lock.lock()
        undoneReceiptIds.formUnion(receiptIds)
        receipts.insert(receipt, at: 0)
        if receipts.count > limit {
            receipts.removeLast(receipts.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> (receipts: [JSON], undoneReceiptIds: Set<String>) {
        lock.lock()
        let result = (receipts, undoneReceiptIds)
        lock.unlock()
        return result
    }

    func list(params: JSON?) -> JSON {
        let limit = params?["limit"]?.intValue ?? 20
        let type = params?["type"]?.stringValue
        let source = params?["source"]?.stringValue
        let wid = params?["wid"]?.uint32Value
        let requestId = params?["requestId"]?.stringValue
        let status = params?["status"]?.stringValue
        let session = params?["session"]?.stringValue
        let undoable = params?["undoable"]?.boolValue

        lock.lock()
        let snapshot = receipts
        let undone = undoneReceiptIds
        lock.unlock()

        let filtered = snapshot.map { decorate($0, undoneReceiptIds: undone) }.filter { receipt in
            if let type, receipt["action"]?["type"]?.stringValue != type {
                return false
            }
            if let source, receipt["source"]?.stringValue != source {
                return false
            }
            if let wid, receipt["wid"]?.uint32Value != wid {
                return false
            }
            if let requestId, receipt["requestId"]?.stringValue != requestId {
                return false
            }
            if let status, receipt["status"]?.stringValue != status {
                return false
            }
            if let session, receipt["session"]?.stringValue != session {
                return false
            }
            if let undoable, receipt["undoable"]?.boolValue != undoable {
                return false
            }
            return true
        }

        return .array(Array(filtered.prefix(max(0, limit))))
    }

    private func decorate(_ receipt: JSON, undoneReceiptIds: Set<String>) -> JSON {
        guard case .object(var obj) = receipt else { return receipt }
        let isUndone = obj["receiptId"]?.stringValue.map { undoneReceiptIds.contains($0) } ?? false
        obj["undone"] = .bool(isUndone)
        if isUndone {
            obj["undoable"] = .bool(false)
        }
        return .object(obj)
    }
}
