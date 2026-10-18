import AppKit
import ApplicationServices

/// Moves a window to another Space the one way macOS still allows since
/// 14.5: open Mission Control and drag the window's thumbnail onto the
/// target desktop in the Spaces bar, as a person would. The CGS move calls
/// are silently refused for other apps' windows, so this is the fallback
/// `window.move` and `window.present` use.
///
/// Holding a window by its title bar and switching Spaces doesn't work where
/// Lattices owns ⌃-arrow: the Dock ignores its own shortcut once Lattices
/// has turned it off, and the Dock-swipe switch doesn't fire while a mouse
/// button is down. Mission Control exposes the Spaces bar through Dock or
/// WindowManager accessibility, so the drop target can be read.
///
/// Blocks for one to three seconds; never call it on the main thread.
/// Mission Control shows while it runs, and the view returns to the Space
/// the display was on unless the caller requests following the window.
enum WindowSpaceCarry {
    enum Outcome {
        case moved
        case failed(String)
    }

    static func carry(wid: UInt32, pid: pid_t, to target: Int, followWindow: Bool = false) -> Outcome {
        precondition(!Thread.isMainThread, "WindowSpaceCarry blocks; run it off the main thread")
        let diag = DiagnosticLog.shared

        let from = WindowTiler.getSpacesForWindow(wid)
        diag.info("WindowSpaceCarry: begin wid=\(wid) pid=\(pid) source=\(from) target=\(target)")
        if from.contains(target) { return .moved }
        guard from.count == 1, let source = from.first else {
            return .failed("window \(wid) is on \(from.count) Spaces; only a window on one Space can be carried")
        }
        guard let display = WindowTiler.getDisplaySpaces().first(where: {
            $0.orderedSpaceIds.contains(source) && $0.orderedSpaceIds.contains(target)
        }), let targetIndex = display.orderedSpaceIds.firstIndex(of: target) else {
            return .failed("Spaces \(source) and \(target) are on different displays; move the window to the display first")
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            return .failed("\(app.localizedName ?? "the app") is hidden; show it before moving its window")
        }
        let missionControlApps = missionControlApplications()
        guard !missionControlApps.isEmpty else {
            return .failed("Mission Control's accessibility hosts aren't running")
        }
        guard let initialFrame = bounds(wid) else {
            return .failed("window \(wid) has no readable frame")
        }
        let sourcePoint = CGPoint(x: initialFrame.midX, y: initialFrame.midY)
        let startSpace = display.currentSpaceId
        var moved = false
        let restoreCursor = CGEvent(source: nil)?.location
        defer {
            if let restoreCursor { CGWarpMouseCursorPosition(restoreCursor) }
        }

        // 1. Mission Control shows the current Space's windows, so stand on
        //    the window's Space first.
        defer {
            if !followWindow || !moved,
               !selectDesktop(startSpace, on: display.displayId, at: sourcePoint, applications: missionControlApps) {
                diag.warn("WindowSpaceCarry: could not restore display \(display.displayIndex) view to Space \(startSpace)")
            }
        }
        guard selectDesktop(source, on: display.displayId, at: sourcePoint, applications: missionControlApps) else {
            return .failed("Mission Control couldn't select the window's Desktop")
        }
        guard waitUntil(timeout: 1.0, { isOnScreen(wid) }), let home = bounds(wid) else {
            return .failed("window \(wid) didn't come on screen on Space \(source)")
        }

        // 2. Open Mission Control and wait for the thumbnail to settle.
        defer { closeMissionControl(missionControlApps) }
        guard openMissionControl(missionControlApps) else {
            return .failed("Mission Control's Desktop controls weren't available")
        }
        var thumb = home
        let openedAt = Date()
        var stableSince = Date()
        let settled = waitUntil(timeout: 1.5) {
            guard let now = bounds(wid) else { return false }
            if now != thumb {
                thumb = now
                stableSince = Date()
            }
            // A small lone window can keep its original bounds in Mission
            // Control. Stable geometry, not a mandatory size change, is the
            // condition for a settled thumbnail.
            return Date().timeIntervalSince(openedAt) >= 0.35 && Date().timeIntervalSince(stableSince) >= 0.15
        }
        guard settled else { return .failed("no Mission Control thumbnail for window \(wid)") }
        guard let bar = spacesBar(missionControlApps, containing: CGPoint(x: home.midX, y: home.midY)) else {
            return .failed("no Spaces bar on the window's display")
        }
        guard bar.buttons.count == display.orderedSpaceIds.count else {
            return .failed("the Spaces bar shows \(bar.buttons.count) Spaces, expected \(display.orderedSpaceIds.count)")
        }
        let button = bar.buttons[targetIndex]

        // 3. Pick the thumbnail up and bring it to the bar, which expands
        //    under the cursor.
        let events = CGEventSource(stateID: .combinedSessionState)
        var cursor = CGPoint(x: thumb.midX, y: thumb.midY)
        func mouse(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: events, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            // A gesture's held Shift belongs to Lattices, not the thumbnail
            // drag. Do not let hardware modifiers alter Mission Control input.
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        func drag(to point: CGPoint, steps: Int) {
            let origin = cursor
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                mouse(.leftMouseDragged, CGPoint(x: origin.x + (point.x - origin.x) * t,
                                                 y: origin.y + (point.y - origin.y) * t))
                usleep(20_000)
            }
            cursor = point
        }
        let pickup = cursor
        diag.info("WindowSpaceCarry: wid=\(wid) \(source) → \(target) (Space \(targetIndex + 1) of \(display.orderedSpaceIds.count))")
        mouse(.mouseMoved, pickup)
        usleep(80_000)
        mouse(.leftMouseDown, pickup)
        usleep(120_000)
        drag(to: CGPoint(x: bar.frame.midX, y: bar.frame.minY + 30), steps: 20)

        // Collapsed, the buttons sit above the display's top edge.
        var drop = CGPoint.zero
        let expanded = waitUntil(timeout: 1.5) {
            guard let frame = frame(button), frame.minY >= bar.frame.minY else { return false }
            // WindowManager reports an expanded thumbnail's centre as its
            // position (the size is the collapsed label's). Drop there: a
            // drop in the gap between thumbnails makes a full-screen Space.
            drop = frame.origin
            return true
        }
        guard expanded else {
            drag(to: pickup, steps: 10)
            mouse(.leftMouseUp, pickup)
            return .failed("the Spaces bar didn't expand")
        }
        drag(to: drop, steps: 12)
        usleep(400_000)
        mouse(.leftMouseUp, drop)

        // 4. Check where it landed.
        _ = waitUntil(timeout: 1.0) { WindowTiler.getSpacesForWindow(wid) != [source] }
        let after = WindowTiler.getSpacesForWindow(wid)
        if after.contains(target) {
            moved = true
            // Select the destination while Mission Control is already open.
            // Gesture moves carry the user with the window; other moves return.
            if followWindow {
                _ = selectDesktop(target, on: display.displayId, at: sourcePoint, applications: missionControlApps)
            }
            diag.success("WindowSpaceCarry: wid=\(wid) now on \(after)")
            return .moved
        }
        let desktops = Set(WindowTiler.getDisplaySpaces().flatMap { $0.spaces.map(\.id) })
        if let fullScreen = after.first(where: { !desktops.contains($0) }) {
            closeMissionControl(missionControlApps)
            let recovered = leaveFullScreen(wid: wid, pid: pid, space: fullScreen)
            let recovery = recovered ? "left full screen" : "could not leave full screen"
            diag.warn("WindowSpaceCarry: wid=\(wid) dropped between desktops; \(recovery)")
            return .failed("the drop missed Space \(target) and made a full-screen Space; \(recovery)")
        }
        diag.warn("WindowSpaceCarry: wid=\(wid) stayed on \(after)")
        return .failed("the drop didn't take (window still on \(after))")
    }

    /// Constant-distance navigation for the held-key selector. Uses the same
    /// native AX press as window carry; never changes SkyLight bookkeeping.
    static func selectDesktop(_ spaceId: Int, on displayId: String, at point: CGPoint) -> Bool {
        precondition(!Thread.isMainThread)
        return selectDesktop(spaceId, on: displayId, at: point, applications: missionControlApplications())
    }

    // MARK: - Mission Control

    private struct SpacesBar {
        let frame: CGRect
        let buttons: [AXUIElement]
    }

    private static func missionControlApplications() -> [AXUIElement] {
        ["com.apple.WindowManager", "com.apple.dock"].compactMap { bundleId in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1.0)
            return element
        }
    }

    static func displayNodes<Node>(in roots: [Node], identifier: (Node) -> String?, children: (Node) -> [Node]) -> [Node] {
        for root in roots {
            let direct = children(root)
            let displays = direct.flatMap { node -> [Node] in
                switch identifier(node) {
                case "mc.display": return [node]
                case "mc": return children(node).filter { identifier($0) == "mc.display" }
                default: return []
                }
            }
            if !displays.isEmpty { return displays }
        }
        return []
    }

    private static func missionControlDisplays(_ applications: [AXUIElement]) -> [AXUIElement] {
        displayNodes(in: applications, identifier: identifier, children: children)
    }

    private static func openMissionControl(_ applications: [AXUIElement]) -> Bool {
        if !missionControlDisplays(applications).isEmpty { return true }
        toggleMissionControl()
        let opened = waitUntil(timeout: 1.5) { !missionControlDisplays(applications).isEmpty }
        DiagnosticLog.shared.info("WindowSpaceCarry: Mission Control ready=\(opened) displays=\(missionControlDisplays(applications).count)")
        return opened
    }

    private static func closeMissionControl(_ applications: [AXUIElement]) {
        // Checked first: the toggle would open it again.
        guard !missionControlDisplays(applications).isEmpty else { return }
        toggleMissionControl()
        _ = waitUntil(timeout: 1.5) { missionControlDisplays(applications).isEmpty }
        usleep(400_000)
    }

    private static func selectDesktop(_ spaceId: Int, on displayId: String, at point: CGPoint, applications: [AXUIElement]) -> Bool {
        guard let display = WindowTiler.getDisplaySpaces().first(where: { $0.displayId == displayId }),
              let index = display.orderedSpaceIds.firstIndex(of: spaceId) else { return false }
        if display.currentSpaceId == spaceId { return true }
        defer { closeMissionControl(applications) }
        guard openMissionControl(applications),
              let bar = spacesBar(applications, containing: point),
              bar.buttons.count == display.orderedSpaceIds.count else { return false }
        let result = AXUIElementPerformAction(bar.buttons[index], kAXPressAction as CFString)
        DiagnosticLog.shared.info("WindowSpaceCarry: select Desktop \(spaceId) AXPress=\(result.rawValue)")
        guard result == .success else { return false }
        _ = waitUntil(timeout: 1.5) {
            WindowTiler.getDisplaySpaces().first(where: { $0.displayId == displayId })?.currentSpaceId == spaceId
        }
        closeMissionControl(applications)
        var stableSince: Date?
        let selected = waitUntil(timeout: 2.0) {
            guard WindowTiler.getDisplaySpaces().first(where: { $0.displayId == displayId })?.currentSpaceId == spaceId else {
                stableSince = nil
                return false
            }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) >= 0.4
        }
        DiagnosticLog.shared.info("WindowSpaceCarry: selected Desktop \(spaceId) verified=\(selected)")
        return selected
    }

    /// The app rather than ⌃↑ or Escape: it works whatever the shortcut is
    /// set to, and Escape from Lattices doesn't reach Mission Control.
    private static func toggleMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DiagnosticLog.shared.info("WindowSpaceCarry: Mission Control launch pid=\(app?.processIdentifier ?? 0) error=\(error?.localizedDescription ?? "none")")
        }
    }

    private static func spacesBar(_ applications: [AXUIElement], containing point: CGPoint) -> SpacesBar? {
        guard let display = missionControlDisplays(applications).first(where: {
            frame($0)?.contains(point) ?? false
        }), let group = children(display).first(where: { string($0, kAXDescriptionAttribute) == "Spaces Bar"
            || string($0, kAXTitleAttribute) == "Spaces Bar"
            || children($0).contains { identifier($0) == "mc.spaces.list" } }),
            let list = children(group).first(where: { identifier($0) == "mc.spaces.list" }),
            let displayFrame = frame(display)
        else { return nil }
        return SpacesBar(frame: displayFrame, buttons: children(list))
    }

    // MARK: - Pieces

    private static func leaveFullScreen(wid: UInt32, pid: pid_t, space: Int) -> Bool {
        guard WindowTiler.switchToSpace(spaceId: space) else { return false }
        usleep(300_000)
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.first(where: { window in
                  var id: CGWindowID = 0
                  return _AXUIElementGetWindow(window, &id) == .success && id == wid
              }) else { return false }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        return waitUntil(timeout: 2.0) { !WindowTiler.getSpacesForWindow(wid).contains(space) }
    }

    private static func bounds(_ wid: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first,
              let dict = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    private static func isOnScreen(_ wid: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first else { return false }
        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        string(element, kAXIdentifierAttribute)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(30_000)
        } while Date() < deadline
        return condition()
    }
}
