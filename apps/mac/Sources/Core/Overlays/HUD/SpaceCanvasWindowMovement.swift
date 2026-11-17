import AppKit

/// Applies a drop to the window captured by the canvas, through the same
/// serialized, verified relocation used by the CLI and Overview. A drop does
/// not focus a different window or follow it onto its destination desktop.
enum SpaceCanvasWindowMovement {
    struct Request {
        let windowID: UInt32
        let pid: Int32
        let sourceSpaceID: Int
        let destinationSpaceID: Int
        /// Full-window top-left, normalized against the full monitor, not its
        /// menu/Dock-inset usable frame and not the clipped thumbnail bounds.
        let normalizedOrigin: CGPoint
    }

    struct Outcome {
        let windowID: UInt32
        let spaceID: Int
        let actualFrame: CGRect
        let normalizedFrame: CGRect
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    struct DisplayState {
        let id: String
        let index: Int
        let spaceIDs: [Int]
        let currentSpaceID: Int
        let bounds: CGRect
        let usableBounds: CGRect
    }

    struct Environment {
        var display: () -> DisplayState?
        var window: (UInt32) -> WindowEntry?
        var relocate: (JSON, WindowEntry) throws -> JSON
        var restoreSpace: (Int) -> Bool
    }

    struct Plan {
        let frame: CGRect
        let placement: PlacementSpec
    }

    private static let queue = DispatchQueue(label: "dev.lattices.space-canvas.window-movement", qos: .userInitiated)

    /// Call on main. Work runs off main; the completion always returns on main.
    static func move(windowID: UInt32, pid: Int32, sourceSpaceID: Int, destinationSpaceID: Int,
                     normalizedOrigin: CGPoint, on screen: NSScreen,
                     completion: @escaping (Result<Outcome, Failure>) -> Void) {
        precondition(Thread.isMainThread)
        let request = Request(windowID: windowID, pid: pid, sourceSpaceID: sourceSpaceID,
            destinationSpaceID: destinationSpaceID, normalizedOrigin: normalizedOrigin)
        let screenID = ScreenOverlayCanvasController.screenID(for: screen)
        let display = { () -> DisplayState? in
            onMain {
                guard let liveScreen = NSScreen.screens.first(where: {
                    ScreenOverlayCanvasController.screenID(for: $0) == screenID
                }), let topology = WindowTiler.getDisplaySpaces().first(where: {
                    DisplayGeometryMapper.screen(for: $0, in: NSScreen.screens) === liveScreen
                }) else { return nil }
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                return DisplayState(id: topology.displayId, index: topology.displayIndex,
                    spaceIDs: topology.spaces.map(\.id), currentSpaceID: topology.currentSpaceId,
                    bounds: DisplayGeometryMapper.topLeftFrame(liveScreen.frame, primaryHeight: primaryHeight),
                    usableBounds: DisplayGeometryMapper.topLeftFrame(liveScreen.visibleFrame, primaryHeight: primaryHeight))
            }
        }
        let environment = Environment(display: display, window: liveWindow, relocate: { params, target in
            try ActionRuntime.shared.executeWindowMove(params: params, source: "app.space-canvas",
                target: target, followWindow: false)
        }, restoreSpace: { spaceID in
            guard let current = display() else { return false }
            return WindowSpaceCarry.selectDesktop(spaceID, on: current.id,
                at: CGPoint(x: current.bounds.midX, y: current.bounds.midY))
        })
        queue.async {
            let result = execute(request, environment: environment)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Isolated orchestration for deterministic tests. The canonical runtime
    /// owns mutation, staging, rollback, and its global Mission Control lock.
    static func execute(_ request: Request, environment: Environment) -> Result<Outcome, Failure> {
        func fail(_ message: String) -> Result<Outcome, Failure> { .failure(Failure(message: message)) }
        guard request.windowID != 0, request.pid > 0,
              let display = environment.display(),
              display.spaceIDs.contains(request.sourceSpaceID),
              display.spaceIDs.contains(request.destinationSpaceID),
              display.spaceIDs.contains(display.currentSpaceID) else {
            return fail("The window and destination must be ordinary desktops on this monitor")
        }
        guard let target = environment.window(request.windowID), target.pid == request.pid,
              target.spaceIds == [request.sourceSpaceID], !target.appHidden, !target.collapsed else {
            return fail("The window changed or is no longer available on its original desktop")
        }
        let plan: Plan
        do {
            plan = try destination(normalizedOrigin: request.normalizedOrigin,
                windowSize: CGSize(width: target.frame.w, height: target.frame.h),
                displayBounds: display.bounds, usableBounds: display.usableBounds)
        } catch { return fail(error.localizedDescription) }
        let params = JSON.object([
            "wid": .int(Int(request.windowID)), "display": .int(display.index),
            "spaceId": .int(request.destinationSpaceID), "placement": plan.placement.jsonValue,
        ])
        var receipt: JSON?
        var mutationFailure: String?
        do {
            let result = try environment.relocate(params, target)
            receipt = result
            mutationFailure = WindowMovementService.failureMessage(for: result)
        } catch { mutationFailure = error.localizedDescription }

        // Carry already requests restoration; independently verify it even if
        // the runtime throws or reports failure after a partially applied move.
        if environment.display()?.currentSpaceID != display.currentSpaceID {
            _ = environment.restoreSpace(display.currentSpaceID)
        }
        guard let restored = environment.display(), restored.id == display.id,
              restored.currentSpaceID == display.currentSpaceID else {
            return fail("The move could not restore your original desktop. \(mutationFailure ?? "Check the window's final position.")")
        }
        if let mutationFailure { return fail(mutationFailure) }
        guard let receipt,
              receipt["wid"]?.uint32Value == request.windowID,
              receipt["pid"]?.intValue == Int(request.pid),
              receipt["verifiedFrame"]?.boolValue == true,
              receipt["verifiedDisplay"]?.boolValue == true,
              receipt["verifiedSpace"]?.boolValue == true,
              let after = environment.window(request.windowID), after.pid == request.pid,
              after.spaceIds == [request.destinationSpaceID] else {
            return fail("The window's final desktop and position could not be verified")
        }
        let actual = CGRect(x: after.frame.x, y: after.frame.y, width: after.frame.w, height: after.frame.h)
        let rawTolerance = receipt["verificationTolerance"]?.numericDouble ?? 6
        let tolerance = CGFloat(rawTolerance.isFinite ? min(14, max(0, rawTolerance)) : 6)
        guard WindowRelocation.framesClose(actual, plan.frame, tolerance: tolerance) else {
            return fail("The window did not reach the dropped position")
        }
        return .success(Outcome(windowID: request.windowID, spaceID: request.destinationSpaceID,
            actualFrame: actual, normalizedFrame: CGRect(
                x: (actual.minX - restored.bounds.minX) / restored.bounds.width,
                y: (actual.minY - restored.bounds.minY) / restored.bounds.height,
                width: actual.width / restored.bounds.width, height: actual.height / restored.bounds.height)))
    }

    static func destination(normalizedOrigin: CGPoint, windowSize: CGSize,
                            displayBounds: CGRect, usableBounds: CGRect) throws -> Plan {
        let values = [normalizedOrigin.x, normalizedOrigin.y, windowSize.width, windowSize.height,
                      displayBounds.minX, displayBounds.minY, displayBounds.width, displayBounds.height,
                      usableBounds.minX, usableBounds.minY, usableBounds.width, usableBounds.height]
        guard values.allSatisfy(\.isFinite), windowSize.width > 1, windowSize.height > 1,
              displayBounds.width > 0, displayBounds.height > 0,
              usableBounds.width > 0, usableBounds.height > 0 else {
            throw Failure(message: "The window or monitor no longer has readable geometry")
        }
        guard windowSize.width <= usableBounds.width, windowSize.height <= usableBounds.height else {
            throw Failure(message: "This window is larger than the monitor's usable area; resize it before dragging")
        }
        let origin = CGPoint(
            x: min(usableBounds.maxX - windowSize.width, max(usableBounds.minX,
                displayBounds.minX + normalizedOrigin.x * displayBounds.width)),
            y: min(usableBounds.maxY - windowSize.height, max(usableBounds.minY,
                displayBounds.minY + normalizedOrigin.y * displayBounds.height)))
        guard let fractions = FractionalPlacement(
            x: (origin.x - usableBounds.minX) / usableBounds.width,
            y: (origin.y - usableBounds.minY) / usableBounds.height,
            w: windowSize.width / usableBounds.width, h: windowSize.height / usableBounds.height) else {
            throw Failure(message: "The dropped position could not be represented on this monitor")
        }
        return Plan(frame: CGRect(origin: origin, size: windowSize), placement: .fractions(fractions))
    }

    private static func liveWindow(_ wid: UInt32) -> WindowEntry? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wid }),
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &frame) else { return nil }
        return WindowEntry(wid: wid, app: info[kCGWindowOwnerName as String] as? String ?? "Window", pid: pid,
            title: info[kCGWindowName as String] as? String ?? "",
            frame: WindowFrame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
            spaceIds: WindowTiler.getSpacesForWindow(wid).sorted(),
            isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false, latticesSession: nil,
            appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden ?? false,
            collapsed: frame.width <= 1 || frame.height <= 1)
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
