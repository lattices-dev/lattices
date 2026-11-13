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

    private struct ResolvedSnapZone {
        let id: String
        let label: String
        let placement: PlacementSpec
        let screen: NSScreen
        let screenID: String
        let triggerRect: CGRect
        let visibleRect: CGRect
        let previewRect: CGRect
        let priority: Int
    }

    private struct DragSession {
        let pid: pid_t
        let wid: UInt32?
        let zones: [ResolvedSnapZone]
    }

    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var flagsChangedMonitor: Any?

    private var dragCandidate: DragWindowCandidate?
    private var activeSession: DragSession?
    private var modifierModeEnabled = false
    private var windowHasMoved = false

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
        guard modifierModeEnabled, let activeSession else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let zone = bestZone(at: mouseLocation, in: activeSession.zones) else { return }

        DiagnosticLog.shared.info("WindowDragSnap: drop → \(zone.label) (\(zone.id)) on \(zone.screen.localizedName)")
        if let wid = activeSession.wid {
            WindowTiler.tileWindowById(wid: wid, pid: activeSession.pid, to: zone.placement, on: zone.screen)
            WindowTiler.highlightWindowById(wid: wid)
        } else {
            WindowTiler.tileFrontmostViaAX(to: zone.placement)
        }
    }

    private func beginDragSession(with candidate: DragWindowCandidate, mouseLocation: NSPoint) {
        WorkspaceManager.shared.loadGridConfig()
        let config = WorkspaceManager.shared.snapZonesConfig
        guard config.enabled ?? false else { return }

        let zones = resolveZones(using: config)
        guard !zones.isEmpty else { return }

        activeSession = DragSession(
            pid: candidate.pid,
            wid: candidate.wid,
            zones: zones
        )

        DiagnosticLog.shared.info("WindowDragSnap: tracking drag for pid=\(candidate.pid) wid=\(candidate.wid ?? 0)")
        updateActiveSession(at: mouseLocation)
    }

    private func updateActiveSession(at mouseLocation: NSPoint) {
        guard let activeSession else { return }
        let hoveredZone = bestZone(at: mouseLocation, in: activeSession.zones)
        render(zones: activeSession.zones, hoveredZone: hoveredZone)
    }

    private func clearTracking() {
        dragCandidate = nil
        activeSession = nil
        modifierModeEnabled = false
        windowHasMoved = false
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

    private func resolveZones(using config: SnapZonesConfig) -> [ResolvedSnapZone] {
        let wm = WorkspaceManager.shared
        let baseZones = (config.rules ?? []).compactMap { zone -> (SnapZoneDefinition, PlacementSpec, (CGFloat, CGFloat, CGFloat, CGFloat), Int)? in
            let placement: PlacementSpec
            switch zone.placement {
            case .named(let name):
                guard let resolved = wm.resolvePlacement(name) else {
                    DiagnosticLog.shared.warn("WindowDragSnap: ignoring snap zone \(zone.id) — unknown placement \(name)")
                    return nil
                }
                placement = resolved
            case .fractions(let fractionalPlacement):
                placement = .fractions(fractionalPlacement)
            }

            let triggerFractions: (CGFloat, CGFloat, CGFloat, CGFloat)
            switch zone.trigger {
            case .named(let name):
                guard let triggerPlacement = wm.resolvePlacement(name) else {
                    DiagnosticLog.shared.warn("WindowDragSnap: ignoring snap zone \(zone.id) — unknown trigger \(name)")
                    return nil
                }
                triggerFractions = triggerPlacement.fractions
            case .fractions(let placement):
                triggerFractions = placement.fractions
            }

            return (zone, placement, triggerFractions, zone.priority ?? 0)
        }

        var resolved: [ResolvedSnapZone] = []
        for screen in NSScreen.screens {
            let screenID = ScreenOverlayCanvasController.screenID(for: screen)
            for (zone, placement, triggerFractions, priority) in baseZones {
                let triggerRect = Self.screenRect(for: triggerFractions, on: screen)
                let previewRect = Self.screenRect(fromAX: WindowTiler.tileFrame(for: placement, on: screen))
                let visibleRect = Self.visibleRect(forTriggerRect: triggerRect, previewRect: previewRect, on: screen)
                resolved.append(
                    ResolvedSnapZone(
                        id: zone.id,
                        label: zone.label ?? zone.id,
                        placement: placement,
                        screen: screen,
                        screenID: screenID,
                        triggerRect: triggerRect,
                        visibleRect: visibleRect,
                        previewRect: previewRect,
                        priority: priority
                    )
                )
            }
        }

        return resolved.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            let leftArea = $0.triggerRect.width * $0.triggerRect.height
            let rightArea = $1.triggerRect.width * $1.triggerRect.height
            if leftArea != rightArea {
                return leftArea < rightArea
            }
            return $0.id < $1.id
        }
    }

    private func bestZone(at mouseLocation: NSPoint, in zones: [ResolvedSnapZone]) -> ResolvedSnapZone? {
        zones.first(where: { $0.triggerRect.contains(mouseLocation) })
    }

    private func render(zones: [ResolvedSnapZone], hoveredZone: ResolvedSnapZone?) {
        let config = WorkspaceManager.shared.snapZonesConfig
        let grouped = Dictionary(grouping: zones, by: \.screenID)
        var layers: [ScreenOverlayLayerSnapshot] = []

        for screen in NSScreen.screens {
            let screenID = ScreenOverlayCanvasController.screenID(for: screen)
            guard let screenZones = grouped[screenID], !screenZones.isEmpty else { continue }

            let localZones = screenZones.map {
                ScreenOverlaySnapZone(
                    id: $0.id,
                    label: $0.label,
                    rect: $0.visibleRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                    isHovered: hoveredZone?.id == $0.id && hoveredZone?.screenID == screenID
                )
            }

            let previewRect = hoveredZone?.screenID == screenID
                ? hoveredZone?.previewRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                : nil

            let payload = ScreenOverlaySnapZonesPayload(
                zones: localZones,
                previewRect: previewRect,
                previewLabel: nil,
                palette: .mint,
                zoneOpacity: CGFloat(config.zoneOpacity ?? SnapZonesConfig.defaults.zoneOpacity ?? 0.10),
                highlightOpacity: CGFloat(config.highlightOpacity ?? SnapZonesConfig.defaults.highlightOpacity ?? 0.22),
                previewOpacity: CGFloat(config.previewOpacity ?? SnapZonesConfig.defaults.previewOpacity ?? 0.18),
                cornerRadius: config.cornerRadius ?? SnapZonesConfig.defaults.cornerRadius ?? 18
            )

            layers.append(
                ScreenOverlayLayerSnapshot(
                    id: ScreenOverlayLayerID("dragSnap.\(screenID)"),
                    owner: .dragSnap,
                    screen: .screen(id: screenID),
                    zIndex: 100,
                    opacity: 1,
                    payload: .snapZones(payload),
                    expiresAt: nil
                )
            )
        }

        ScreenOverlayCanvasController.shared.replaceLayers(owner: .dragSnap, with: layers)
        if let hoveredZone {
            WindowHoverPreview.shared.show(frame: hoveredZone.previewRect)
        } else {
            WindowHoverPreview.shared.hide()
        }
    }

    private static func screenRect(for fractions: (CGFloat, CGFloat, CGFloat, CGFloat), on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let (fx, fy, fw, fh) = fractions
        return CGRect(
            x: visible.minX + visible.width * fx,
            y: visible.maxY - visible.height * (fy + fh),
            width: visible.width * fw,
            height: visible.height * fh
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

    private static func visibleRect(forTriggerRect triggerRect: CGRect, previewRect: CGRect, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let inset: CGFloat = 18
        let nearLeft = abs(triggerRect.minX - visible.minX) < 8
        let nearRight = abs(triggerRect.maxX - visible.maxX) < 8
        let nearTop = abs(triggerRect.maxY - visible.maxY) < 8
        let nearBottom = abs(triggerRect.minY - visible.minY) < 8

        if (nearLeft || nearRight) && (nearTop || nearBottom) {
            let width: CGFloat = 94
            let height: CGFloat = 56
            let x = nearLeft ? visible.minX + inset : visible.maxX - inset - width
            let y = nearBottom ? visible.minY + inset : visible.maxY - inset - height
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if nearLeft || nearRight {
            let width: CGFloat = 110
            let height: CGFloat = 38
            let x = nearLeft ? visible.minX + inset : visible.maxX - inset - width
            let y = clamp(previewRect.midY - height / 2, min: visible.minY + 54, max: visible.maxY - 54 - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if nearTop || nearBottom {
            let width = min(max(triggerRect.width * 0.34, 132), 240)
            let height: CGFloat = 38
            let x = clamp(previewRect.midX - width / 2, min: visible.minX + 54, max: visible.maxX - 54 - width)
            let y = nearBottom ? visible.minY + inset : visible.maxY - inset - height
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let width = min(max(previewRect.width * 0.28, 132), 220)
        let height: CGFloat = 38
        let x = clamp(previewRect.midX - width / 2, min: visible.minX + 54, max: visible.maxX - 54 - width)
        let y = clamp(previewRect.maxY - height - 16, min: visible.minY + 40, max: visible.maxY - 40 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }
}
