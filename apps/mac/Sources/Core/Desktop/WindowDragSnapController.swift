import AppKit
import CoreGraphics

final class WindowDragSnapController {
    static let shared = WindowDragSnapController()

    private struct DragWindowCandidate {
        let pid: pid_t
        let wid: UInt32?
        let axWindow: AXUIElement
        let initialAXFrame: CGRect
    }

    private struct DragSession {
        let pid: pid_t
        let wid: UInt32?
        let initialAXFrame: CGRect
    }

    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var flagsChangedMonitor: Any?

    private var dragCandidate: DragWindowCandidate?
    private var activeSession: DragSession?
    private var modifierModeEnabled = false
    private var windowHasMoved = false
    private var landingTitle: String?

    var isSnapping: Bool { activeSession != nil }

    private init() {}

    func start() {
        guard mouseDownMonitor == nil,
              mouseDragMonitor == nil,
              mouseUpMonitor == nil,
              flagsChangedMonitor == nil else { return }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleMouseDragged(event)
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
        }
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        DiagnosticLog.shared.info("WindowDragSnap: global drag monitors started")
    }

    func stop() {
        if let monitor = mouseDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseDragMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseUpMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = flagsChangedMonitor { NSEvent.removeMonitor(monitor) }
        mouseDownMonitor = nil
        mouseDragMonitor = nil
        mouseUpMonitor = nil
        flagsChangedMonitor = nil
        clearTracking()
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard Preferences.shared.dragSnapEnabled else {
            clearTracking()
            return
        }
        guard PermissionChecker.shared.accessibility else {
            clearTracking()
            return
        }

        WorkspaceManager.shared.loadGridConfig()
        modifierModeEnabled = Self.snapModifierPressed()
        windowHasMoved = false
        activeSession = nil
        hideOverlays()
        dragCandidate = captureFocusedWindow(at: NSEvent.mouseLocation)
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard Preferences.shared.dragSnapEnabled else {
            clearTracking()
            return
        }
        guard PermissionChecker.shared.accessibility else {
            clearTracking()
            return
        }

        guard let candidate = dragCandidate else { return }
        modifierModeEnabled = Self.snapModifierPressed()
        updateDragProgress(for: candidate)
        updateSnapInteraction(at: NSEvent.mouseLocation)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard dragCandidate != nil else { return }
        modifierModeEnabled = Self.snapModifierPressed()
        updateSnapInteraction(at: NSEvent.mouseLocation)
    }

    private func updateDragProgress(for candidate: DragWindowCandidate) {
        guard let currentFrame = WindowTiler.readAXFrame(candidate.axWindow) else { return }

        let moved = hypot(
            currentFrame.origin.x - candidate.initialAXFrame.origin.x,
            currentFrame.origin.y - candidate.initialAXFrame.origin.y
        )
        if moved >= 12 {
            windowHasMoved = true
        }
    }

    private func updateSnapInteraction(at mouseLocation: NSPoint) {
        guard windowHasMoved else {
            if activeSession != nil {
                activeSession = nil
                hideOverlays()
            }
            return
        }

        guard modifierModeEnabled else {
            if activeSession != nil {
                activeSession = nil
                hideOverlays()
            }
            return
        }

        guard let candidate = dragCandidate else { return }
        if activeSession == nil {
            beginDragSession(with: candidate, mouseLocation: mouseLocation)
        } else {
            updateActiveSession(at: mouseLocation)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        defer { clearTracking() }
        modifierModeEnabled = Self.snapModifierPressed()
        guard modifierModeEnabled, let activeSession, let wid = activeSession.wid else { return }
        guard let landing = landing(at: NSEvent.mouseLocation, commit: true) else { return }

        DiagnosticLog.shared.info("WindowDragSnap: drop → \(landing.title)")
        WindowTiler.batchMoveAndRaiseWindows([(wid: wid, pid: activeSession.pid, frame: landing.frame)])
        WindowTiler.highlightWindowById(wid: wid)
    }

    private func beginDragSession(with candidate: DragWindowCandidate, mouseLocation: NSPoint) {
        WorkspaceManager.shared.loadGridConfig()
        guard WorkspaceManager.shared.snapZonesConfig.enabled ?? false else { return }
        guard candidate.wid != nil else { return }

        activeSession = DragSession(
            pid: candidate.pid,
            wid: candidate.wid,
            initialAXFrame: candidate.initialAXFrame
        )

        DiagnosticLog.shared.info("WindowDragSnap: tracking drag for pid=\(candidate.pid) wid=\(candidate.wid ?? 0)")
        updateActiveSession(at: mouseLocation)
    }

    private func updateActiveSession(at mouseLocation: NSPoint) {
        guard activeSession != nil else { return }
        guard let landing = landing(at: mouseLocation, commit: false) else {
            if landingTitle != nil {
                landingTitle = nil
                WindowHoverPreview.shared.hide()
            }
            return
        }
        if landing.title != landingTitle {
            landingTitle = landing.title
            DiagnosticLog.shared.info("WindowDragSnap: \(landing.title)")
        }
        WindowHoverPreview.shared.show([(Self.screenRect(fromAX: landing.frame), landing.title)], held: false)
    }

    /// The Hyperspace landing under the pointer: an open half of a split quarter,
    /// then a quarter, half, or third. A free drag previews the spot it is
    /// approaching and commits nothing. Other windows stay put and only mark
    /// space as taken.
    private func landing(at mouse: NSPoint, commit: Bool) -> (title: String, frame: CGRect)? {
        guard let session = activeSession, let wid = session.wid else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let visible = screen.visibleFrame.insetBy(dx: 2, dy: 2)
        let area = CGRect(x: visible.minX, y: primary - visible.maxY, width: visible.width, height: visible.height)
        let point = CGPoint(x: mouse.x, y: primary - mouse.y)
        let occupied = occupiedFrames(except: wid, in: area)
        let plan = HyperspaceLayoutPlanner.drop(
            wid, original: session.initialAXFrame, start: session.initialAXFrame.origin,
            at: point, in: area, neighbors: [], occupied: occupied)
        if plan.title != "Move window", let frame = plan.frames[wid] {
            return (plan.title, frame)
        }
        guard !commit,
              let approach = HyperspaceLayoutPlanner.approach(wid, at: point, in: area, occupied: occupied),
              let frame = approach.frames[wid] else { return nil }
        return (approach.title, frame)
    }

    private func occupiedFrames(except wid: UInt32, in area: CGRect) -> [CGRect] {
        DesktopModel.shared.snapshot.windows.values.compactMap { entry in
            guard entry.wid != wid, entry.isOnScreen, !entry.collapsed, !entry.appHidden else { return nil }
            let rect = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
            guard rect.width >= 50, rect.height >= 50, area.intersects(rect) else { return nil }
            return rect
        }
    }

    private func clearTracking() {
        dragCandidate = nil
        activeSession = nil
        modifierModeEnabled = false
        windowHasMoved = false
        landingTitle = nil
        hideOverlays()
    }

    private func hideOverlays() {
        ScreenOverlayCanvasController.shared.removeLayers(owner: .dragSnap)
        WindowHoverPreview.shared.hide()
    }

    private func captureFocusedWindow(at mouseLocation: NSPoint) -> DragWindowCandidate? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else {
            return nil
        }
        let axWindow = focusedRef as! AXUIElement
        guard let axFrame = WindowTiler.readAXFrame(axWindow) else { return nil }

        let windowRect = Self.screenRect(fromAX: axFrame)
        guard windowRect.insetBy(dx: -8, dy: -8).contains(mouseLocation) else {
            return nil
        }

        var widValue: CGWindowID = 0
        let wid = _AXUIElementGetWindow(axWindow, &widValue) == .success ? widValue : nil

        return DragWindowCandidate(
            pid: frontApp.processIdentifier,
            wid: wid,
            axWindow: axWindow,
            initialAXFrame: axFrame
        )
    }

    private static func screenRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func snapModifierPressed() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(Self.snapModifier().cgEventFlags)
    }

    private static func snapModifier() -> SnapModifierKey {
        WorkspaceManager.shared.snapZonesConfig.modifier ?? .command
    }
}
