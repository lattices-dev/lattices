import AppKit
import CryptoKit

struct ScreenOverlayLayerID: Hashable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

enum ScreenOverlayOwner: String {
    case dragSnap
    case spatialLens
    case mouseGesture
    case hotkeyHints
    case focusHighlight
    case agentApi
    case tilePointer
    case quickMenu
}

enum ScreenOverlayScreenTarget: Equatable {
    case screen(id: String)
    case all
}

struct ScreenOverlayLayerSnapshot {
    let id: ScreenOverlayLayerID
    let owner: ScreenOverlayOwner
    let screen: ScreenOverlayScreenTarget
    let zIndex: Int
    let opacity: CGFloat
    let payload: ScreenOverlayPayload
    let expiresAt: Date?
}

struct ScreenOverlayActorVisibilitySnapshot {
    let hidden: Bool
    let actorCount: Int

    var visible: Bool { !hidden }
}

struct ScreenOverlayActorHUD {
    let url: String?
    let html: String?
    let title: String?
    let width: CGFloat
    let height: CGFloat
    let readAccessPath: String?

    var hasContent: Bool {
        (url?.isEmpty == false) || (html?.isEmpty == false)
    }

    var contentKey: String {
        [
            url ?? "",
            html ?? "",
            title ?? "",
            "\(Int(width))x\(Int(height))",
            readAccessPath ?? "",
        ].joined(separator: "|")
    }
}

enum ScreenOverlayPayload {
    case snapZones(ScreenOverlaySnapZonesPayload)
    case toast(ScreenOverlayTextPayload)
    case label(ScreenOverlayTextPayload)
    case highlight(ScreenOverlayHighlightPayload)
    case pet(ScreenOverlayPetPayload)
}

struct ScreenOverlaySnapZone {
    let id: String
    let label: String
    let rect: CGRect
    let isHovered: Bool
}

struct ScreenOverlaySnapZonesPayload {
    let zones: [ScreenOverlaySnapZone]
    let previewRect: CGRect?
    let previewLabel: String?
    let palette: ScreenOverlaySnapPalette
    let zoneOpacity: CGFloat
    let highlightOpacity: CGFloat
    let previewOpacity: CGFloat
    let cornerRadius: CGFloat
}

enum ScreenOverlaySnapPalette: Equatable {
    case mint
    case spatialLens
}

struct ScreenOverlayTextPayload {
    let text: String
    let detail: String?
    let point: CGPoint?
    let placement: ScreenOverlayPlacement
    let style: ScreenOverlayStyle
}

struct ScreenOverlayHighlightPayload {
    let rect: CGRect
    let label: String?
    let style: ScreenOverlayStyle
    let cornerRadius: CGFloat
}

struct ScreenOverlayPetPayload {
    let glyph: String
    let petID: String?
    let state: String?
    let name: String?
    let message: String?
    let targetApp: String?
    let targetBundleIdentifier: String?
    let targetAppPath: String?
    let scale: CGFloat
    let labelHidden: Bool
    let closeOnActivate: Bool
    let hud: ScreenOverlayActorHUD?
    let point: CGPoint?
    let placement: ScreenOverlayPlacement
    let style: ScreenOverlayStyle
    let isDragging: Bool
    let dismissible: Bool

    func moved(to point: CGPoint, state nextState: String?, isDragging nextIsDragging: Bool? = nil) -> ScreenOverlayPetPayload {
        ScreenOverlayPetPayload(
            glyph: glyph,
            petID: petID,
            state: nextState ?? state,
            name: name,
            message: message,
            targetApp: targetApp,
            targetBundleIdentifier: targetBundleIdentifier,
            targetAppPath: targetAppPath,
            scale: scale,
            labelHidden: labelHidden,
            closeOnActivate: closeOnActivate,
            hud: hud,
            point: point,
            placement: .point,
            style: style,
            isDragging: nextIsDragging ?? isDragging,
            dismissible: dismissible
        )
    }

    func withLabelHidden(_ hidden: Bool) -> ScreenOverlayPetPayload {
        ScreenOverlayPetPayload(
            glyph: glyph,
            petID: petID,
            state: state,
            name: name,
            message: message,
            targetApp: targetApp,
            targetBundleIdentifier: targetBundleIdentifier,
            targetAppPath: targetAppPath,
            scale: scale,
            labelHidden: hidden,
            closeOnActivate: closeOnActivate,
            hud: hud,
            point: point,
            placement: placement,
            style: style,
            isDragging: isDragging,
            dismissible: dismissible
        )
    }

    func withScale(_ nextScale: CGFloat) -> ScreenOverlayPetPayload {
        ScreenOverlayPetPayload(
            glyph: glyph,
            petID: petID,
            state: state,
            name: name,
            message: message,
            targetApp: targetApp,
            targetBundleIdentifier: targetBundleIdentifier,
            targetAppPath: targetAppPath,
            scale: max(0.55, min(nextScale, 1.35)),
            labelHidden: labelHidden,
            closeOnActivate: closeOnActivate,
            hud: hud,
            point: point,
            placement: placement,
            style: style,
            isDragging: isDragging,
            dismissible: dismissible
        )
    }

    func withHUD(_ nextHUD: ScreenOverlayActorHUD?) -> ScreenOverlayPetPayload {
        ScreenOverlayPetPayload(
            glyph: glyph,
            petID: petID,
            state: state,
            name: name,
            message: message,
            targetApp: targetApp,
            targetBundleIdentifier: targetBundleIdentifier,
            targetAppPath: targetAppPath,
            scale: scale,
            labelHidden: labelHidden,
            closeOnActivate: closeOnActivate,
            hud: nextHUD,
            point: point,
            placement: placement,
            style: style,
            isDragging: isDragging,
            dismissible: dismissible
        )
    }
}

enum ScreenOverlayPlacement: String {
    case top
    case bottom
    case center
    case cursor
    case point
}

enum ScreenOverlayStyle: String {
    case info
    case success
    case warning
    case danger
    case playful
}

final class ScreenOverlayCanvasController {
    static let shared = ScreenOverlayCanvasController()

    private var windowsByScreenID: [String: ScreenOverlayWindow] = [:]
    private var layersByID: [ScreenOverlayLayerID: ScreenOverlayLayerSnapshot] = [:]
    private var motionsByLayerID: [ScreenOverlayLayerID: OverlayLayerMotion] = [:]
    private var animationTimer: Timer?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var dragState: OverlayActorDragState?
    private var actorDragTimeoutTimer: Timer?
    private var hoveredActorID: ScreenOverlayLayerID?
    private var menuActionTargets: [ActorMenuActionTarget] = []
    private var agentActorsHidden = false
    private let maxActorDragDuration: TimeInterval = 8.0

    private init() {}

    func warmUp() {
        reconcileScreens()
        // Order in once so the first real show is warm, then take it back
        // out: an idle full-screen window at the maximum level, joined to
        // every Space, makes Mission Control render its Space thumbnails as
        // bare wallpaper.
        for window in windowsByScreenID.values {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.orderOut(nil)
        }
    }

    func reconcileScreens() {
        let currentScreenIDs = Set(NSScreen.screens.map(Self.screenID(for:)))
        for staleID in windowsByScreenID.keys where !currentScreenIDs.contains(staleID) {
            windowsByScreenID[staleID]?.orderOut(nil)
            windowsByScreenID.removeValue(forKey: staleID)
        }

        for screen in NSScreen.screens {
            let screenID = Self.screenID(for: screen)
            let window = windowsByScreenID[screenID] ?? makeWindow(for: screen)
            window.setFrame(screen.frame, display: false)
            window.overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
            windowsByScreenID[screenID] = window
        }
    }

    func publishLayer(_ layer: ScreenOverlayLayerSnapshot) {
        layersByID[layer.id] = layer
        scheduleExpiration(for: layer)
        render()
        updateLifecycleMonitors()
    }

    func replaceLayers(owner: ScreenOverlayOwner, with layers: [ScreenOverlayLayerSnapshot]) {
        layersByID = layersByID.filter { _, layer in layer.owner != owner }
        for layer in layers {
            layersByID[layer.id] = layer
            scheduleExpiration(for: layer)
        }
        render()
        updateLifecycleMonitors()
    }

    func removeLayer(id: ScreenOverlayLayerID) {
        layersByID.removeValue(forKey: id)
        motionsByLayerID.removeValue(forKey: id)
        if hoveredActorID == id {
            hoveredActorID = nil
            ScreenOverlayActorHUDController.shared.hide()
        }
        if dragState?.id == id {
            dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
        }
        render()
        updateLifecycleMonitors()
    }

    func removeLayers(owner: ScreenOverlayOwner) {
        let removedIDs = Set(layersByID.values.filter { $0.owner == owner }.map(\.id))
        layersByID = layersByID.filter { _, layer in layer.owner != owner }
        motionsByLayerID = motionsByLayerID.filter { id, _ in layersByID[id] != nil }
        if let hoveredActorID, removedIDs.contains(hoveredActorID) {
            self.hoveredActorID = nil
            ScreenOverlayActorHUDController.shared.hide()
        }
        if let dragState, removedIDs.contains(dragState.id) {
            self.dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
        }
        render()
        updateLifecycleMonitors()
    }

    func toggleAgentActorsVisibility() {
        _ = setAgentActorsHidden(!agentActorsHidden, showFeedback: true)
    }

    @discardableResult
    func setAgentActorsHidden(_ hidden: Bool, showFeedback: Bool = false) -> ScreenOverlayActorVisibilitySnapshot {
        agentActorsHidden = hidden
        if agentActorsHidden {
            hoveredActorID = nil
            dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
            ScreenOverlayActorHUDController.shared.hide()
        }
        render()
        updateLifecycleMonitors()
        let snapshot = agentActorsVisibility()
        if showFeedback {
            showActorVisibilityFeedback(snapshot)
        }
        return snapshot
    }

    func agentActorsVisibility() -> ScreenOverlayActorVisibilitySnapshot {
        let count = layersByID.values.filter(\.isParkableActor).count
        return ScreenOverlayActorVisibilitySnapshot(hidden: agentActorsHidden, actorCount: count)
    }

    func resetInputCapture(reason: String) {
        dragState = nil
        cancelActorDragTimeout()
        resetPointerCapture()
        ScreenOverlayActorHUDController.shared.hide()
        DiagnosticLog.shared.warn("ScreenOverlay: input capture reset for \(reason)")
    }

    @discardableResult
    func moveLayer(id: ScreenOverlayLayerID, to target: CGPoint, durationMs: Int, easing: String?) -> Bool {
        guard let layer = layersByID[id],
              case .pet(let payload) = layer.payload else { return false }
        let now = Date()
        let currentPoint = motionsByLayerID[id]?.point(at: now) ?? payload.point ?? target
        let duration = max(0.08, min(Double(durationMs) / 1000.0, 8.0))
        let restingState = payload.state == "run_left" || payload.state == "run_right" ? "idle" : payload.state
        let movingState = target.x < currentPoint.x - 2 ? "run_left" : "run_right"

        motionsByLayerID[id] = OverlayLayerMotion(
            from: currentPoint,
            to: target,
            startedAt: now,
            duration: duration,
            easing: OverlayLayerMotion.Easing.parse(easing),
            restingState: restingState
        )
        layersByID[id] = layer.replacingPayload(.pet(payload.moved(to: currentPoint, state: movingState)))
        render()
        updateLifecycleMonitors()
        return true
    }

    @discardableResult
    func setActorHUD(id: ScreenOverlayLayerID, hud: ScreenOverlayActorHUD?) -> Bool {
        guard let layer = layersByID[id],
              case .pet(let payload) = layer.payload else { return false }
        layersByID[id] = layer.replacingPayload(.pet(payload.withHUD(hud)))
        if hoveredActorID == id, hud?.hasContent != true {
            ScreenOverlayActorHUDController.shared.hide()
        }
        render()
        updateLifecycleMonitors()
        return true
    }

    static func screenID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    private func makeWindow(for screen: NSScreen) -> ScreenOverlayWindow {
        let window = ScreenOverlayWindow(frame: screen.frame, controller: self)
        windowsByScreenID[Self.screenID(for: screen)] = window
        return window
    }

    private func render() {
        reconcileScreens()
        dropExpiredLayers()

        for screen in NSScreen.screens {
            let screenID = Self.screenID(for: screen)
            guard let window = windowsByScreenID[screenID] else { continue }
            let visibleLayers = layersByID.values
                .filter { layer in
                    if agentActorsHidden && layer.isParkableActor {
                        return false
                    }
                    switch layer.screen {
                    case .all:
                        return true
                    case .screen(let targetID):
                        return targetID == screenID
                    }
                }
                .sorted { left, right in
                    if left.zIndex != right.zIndex {
                        return left.zIndex < right.zIndex
                    }
                    return left.id.rawValue < right.id.rawValue
                }

            window.overlayView.layers = visibleLayers
            window.overlayView.hoveredLayerID = agentActorsHidden ? nil : hoveredActorID
            if visibleLayers.isEmpty {
                window.alphaValue = 0
                window.orderOut(nil)
            } else {
                window.alphaValue = 1
                window.orderFrontRegardless()
            }
        }
    }

    private func dropExpiredLayers() {
        let now = Date()
        layersByID = layersByID.filter { _, layer in
            guard let expiresAt = layer.expiresAt else { return true }
            return expiresAt > now
        }
        motionsByLayerID = motionsByLayerID.filter { id, _ in layersByID[id] != nil }
    }

    private func scheduleExpiration(for layer: ScreenOverlayLayerSnapshot) {
        guard let expiresAt = layer.expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let current = self.layersByID[layer.id],
                  current.expiresAt == expiresAt else { return }
            self.layersByID.removeValue(forKey: layer.id)
            self.motionsByLayerID.removeValue(forKey: layer.id)
            self.render()
            self.updateLifecycleMonitors()
        }
    }

    private func updateLifecycleMonitors() {
        updateAnimationTimer()
        updateDismissMonitors()
    }

    private func updateAnimationTimer() {
        let needsAnimation = !motionsByLayerID.isEmpty || layersByID.values.contains { layer in
            if case .pet = layer.payload { return true }
            return false
        }

        if needsAnimation, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tickAnimation()
            }
        } else if !needsAnimation {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func tickAnimation() {
        let now = Date()
        var completedIDs: [ScreenOverlayLayerID] = []
        for (id, motion) in motionsByLayerID {
            guard let layer = layersByID[id],
                  case .pet(let payload) = layer.payload else {
                completedIDs.append(id)
                continue
            }

            let point = motion.point(at: now)
            let isComplete = motion.isComplete(at: now)
            let state: String?
            if isComplete {
                state = motion.restingState
                completedIDs.append(id)
            } else {
                state = motion.to.x < motion.from.x ? "run_left" : "run_right"
            }
            layersByID[id] = layer.replacingPayload(.pet(payload.moved(to: point, state: state)))
        }
        for id in completedIDs {
            motionsByLayerID.removeValue(forKey: id)
        }

        if !completedIDs.isEmpty {
            updateLifecycleMonitors()
        }
        render()
        for window in windowsByScreenID.values {
            window.overlayView.needsDisplay = true
        }
    }

    private func updateDismissMonitors() {
        let hasAgentLayer = layersByID.values.contains { $0.owner == .agentApi }
        if hasAgentLayer, globalDismissMonitor == nil {
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved,
                .leftMouseDown,
                .leftMouseDragged,
                .leftMouseUp,
                .rightMouseDown,
                .otherMouseDown,
            ]
            globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                DispatchQueue.main.async {
                    _ = self?.handlePointerEvent(event)
                }
            }
            localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    self?.dismissAgentOverlays()
                    return nil
                }
                return event
            }
        } else if !hasAgentLayer {
            if let globalDismissMonitor {
                NSEvent.removeMonitor(globalDismissMonitor)
                self.globalDismissMonitor = nil
            }
            if let localDismissMonitor {
                NSEvent.removeMonitor(localDismissMonitor)
                self.localDismissMonitor = nil
            }
            dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
        }
    }

    @discardableResult
    private func handlePointerEvent(_ event: NSEvent, at globalPoint: CGPoint? = nil) -> Bool {
        let point = globalPoint ?? NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            clearStaleActorDragIfNeeded()
            updatePointerCapture(at: point)
            return false
        case .leftMouseDown:
            if beginActorDrag(at: point) {
                return true
            }
            dismissAgentOverlays()
            return false
        case .leftMouseDragged:
            if dragState != nil {
                return dragActor(to: point)
            }
            updatePointerCapture(at: point)
            return false
        case .leftMouseUp:
            if dragState != nil {
                endActorDrag()
                updatePointerCapture(at: point)
                return true
            }
            updatePointerCapture(at: point)
            return false
        case .rightMouseDown:
            if showActorContextMenu(at: point) {
                return true
            }
            dismissAgentOverlays()
            return false
        case .otherMouseDown:
            dismissAgentOverlays()
            return false
        default:
            return false
        }
    }

    private func updatePointerCapture(at globalPoint: CGPoint) {
        if let dragState {
            setHoveredActor(nil)
            ScreenOverlayActorHUDController.shared.hide()
            for (screenID, window) in windowsByScreenID {
                window.ignoresMouseEvents = screenID != dragState.screenID
            }
            return
        }

        guard let hit = hitActor(at: globalPoint) else {
            setHoveredActor(nil)
            ScreenOverlayActorHUDController.shared.hide()
            resetPointerCapture()
            return
        }

        setHoveredActor(hit.id)
        if let layer = layersByID[hit.id],
           case .pet(let payload) = layer.payload,
           let hud = payload.hud,
           hud.hasContent {
            let globalRect = hit.rect.offsetBy(dx: hit.window.frame.minX, dy: hit.window.frame.minY)
            ScreenOverlayActorHUDController.shared.show(actorID: hit.id, hud: hud, near: globalRect)
        } else {
            ScreenOverlayActorHUDController.shared.hide()
        }
        for (screenID, window) in windowsByScreenID {
            window.ignoresMouseEvents = screenID != hit.screenID
        }
    }

    private func setHoveredActor(_ id: ScreenOverlayLayerID?) {
        guard hoveredActorID != id else { return }
        hoveredActorID = id
        for window in windowsByScreenID.values {
            window.overlayView.hoveredLayerID = id
        }
    }

    private func beginActorDrag(at globalPoint: CGPoint) -> Bool {
        guard let hit = hitActor(at: globalPoint),
              let layer = layersByID[hit.id],
              case .pet(let payload) = layer.payload else { return false }
        let currentPoint = motionsByLayerID[hit.id]?.point(at: Date())
            ?? CGPoint(x: hit.rect.midX, y: hit.rect.midY)
        motionsByLayerID.removeValue(forKey: hit.id)
        dragState = OverlayActorDragState(
            id: hit.id,
            screenID: hit.screenID,
            offset: CGPoint(x: hit.localPoint.x - currentPoint.x, y: hit.localPoint.y - currentPoint.y),
            startPoint: currentPoint,
            lastPoint: currentPoint,
            startedAt: Date()
        )
        scheduleActorDragTimeout()
        layersByID[hit.id] = layer.replacingPayload(.pet(payload.moved(to: currentPoint, state: "idle", isDragging: true)))
        render()
        updateLifecycleMonitors()
        updatePointerCapture(at: globalPoint)
        return true
    }

    private func dragActor(to globalPoint: CGPoint) -> Bool {
        guard var dragState,
              let hit = screenLocalPoint(for: globalPoint),
              let layer = layersByID[dragState.id],
              case .pet(let payload) = layer.payload else { return false }
        clearStaleActorDragIfNeeded()
        guard self.dragState != nil else { return false }
        let nextPoint = CGPoint(
            x: hit.localPoint.x - dragState.offset.x,
            y: hit.localPoint.y - dragState.offset.y
        )
        let state = nextPoint.x < dragState.lastPoint.x - 1 ? "run_left" : "run_right"
        layersByID[dragState.id] = layer.replacingPayload(.pet(payload.moved(to: nextPoint, state: state, isDragging: true)))
        dragState.screenID = hit.screenID
        dragState.lastPoint = nextPoint
        self.dragState = dragState
        render()
        updatePointerCapture(at: globalPoint)
        return true
    }

    private func endActorDrag() {
        guard let dragState,
              let layer = layersByID[dragState.id],
              case .pet(let payload) = layer.payload else {
            self.dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
            return
        }
        let settledPayload = payload.moved(to: dragState.lastPoint, state: "idle", isDragging: false)
        let clickDistance = hypot(dragState.lastPoint.x - dragState.startPoint.x, dragState.lastPoint.y - dragState.startPoint.y)
        if clickDistance < 6, activateActorTarget(settledPayload) {
            if settledPayload.closeOnActivate {
                layersByID.removeValue(forKey: dragState.id)
                motionsByLayerID.removeValue(forKey: dragState.id)
            } else {
                layersByID[dragState.id] = layer.replacingPayload(.pet(settledPayload))
            }
            self.dragState = nil
            cancelActorDragTimeout()
            render()
            updateLifecycleMonitors()
            resetPointerCapture()
            return
        }

        layersByID[dragState.id] = layer.replacingPayload(.pet(settledPayload))
        self.dragState = nil
        cancelActorDragTimeout()
        render()
        updateLifecycleMonitors()
        resetPointerCapture()
    }

    private func activateActorTarget(_ payload: ScreenOverlayPetPayload) -> Bool {
        if let bundleID = payload.targetBundleIdentifier,
           activateRunningApplication(bundleIdentifier: bundleID) {
            return true
        }
        if let appName = payload.targetApp,
           activateRunningApplication(named: appName) {
            return true
        }
        if let appPath = payload.targetAppPath {
            let url = URL(fileURLWithPath: appPath)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            DiagnosticLog.shared.info("ScreenOverlay: opened actor target app at \(appPath)")
            return true
        }
        if let bundleID = payload.targetBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            DiagnosticLog.shared.info("ScreenOverlay: opened actor target bundle \(bundleID)")
            return true
        }
        if let appName = payload.targetApp {
            NSWorkspace.shared.launchApplication(appName)
            DiagnosticLog.shared.info("ScreenOverlay: launched actor target app \(appName)")
            return true
        }
        return false
    }

    private func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        DiagnosticLog.shared.info("ScreenOverlay: activated actor target bundle \(bundleIdentifier)")
        return true
    }

    private func activateRunningApplication(named appName: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { runningApp in
            runningApp.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame
        }) else {
            return false
        }
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        DiagnosticLog.shared.info("ScreenOverlay: activated actor target app \(appName)")
        return true
    }

    private func clearStaleActorDragIfNeeded() {
        guard let dragState,
              Date().timeIntervalSince(dragState.startedAt) > maxActorDragDuration else { return }
        DiagnosticLog.shared.warn("ScreenOverlay: stale actor drag cleared for \(dragState.id.rawValue)")
        endActorDrag()
    }

    private func scheduleActorDragTimeout() {
        cancelActorDragTimeout()
        actorDragTimeoutTimer = Timer.scheduledTimer(withTimeInterval: maxActorDragDuration, repeats: false) { [weak self] _ in
            guard let self, self.dragState != nil else { return }
            DiagnosticLog.shared.warn("ScreenOverlay: actor drag timed out; releasing pointer capture")
            self.endActorDrag()
        }
    }

    private func cancelActorDragTimeout() {
        actorDragTimeoutTimer?.invalidate()
        actorDragTimeoutTimer = nil
    }

    private func resetPointerCapture() {
        for window in windowsByScreenID.values {
            window.ignoresMouseEvents = true
        }
    }

    private func closeActor(at globalPoint: CGPoint) -> Bool {
        guard let hit = hitActor(at: globalPoint),
              let layer = layersByID[hit.id],
              layer.owner == .agentApi,
              case .pet = layer.payload else { return false }
        layersByID.removeValue(forKey: hit.id)
        motionsByLayerID.removeValue(forKey: hit.id)
        if dragState?.id == hit.id {
            dragState = nil
            cancelActorDragTimeout()
        }
        render()
        updateLifecycleMonitors()
        resetPointerCapture()
        return true
    }

    private func showActorContextMenu(at globalPoint: CGPoint) -> Bool {
        guard let hit = hitActor(at: globalPoint),
              let layer = layersByID[hit.id],
              layer.owner == .agentApi,
              case .pet(let payload) = layer.payload else { return false }

        menuActionTargets.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false

        if payload.hasActivationTarget {
            menu.addItem(menuItem(title: "Switch to \(payload.targetDisplayName)", action: { [weak self] in
                _ = self?.activateActorTarget(payload)
            }))
            menu.addItem(.separator())
        }

        menu.addItem(menuItem(title: payload.labelHidden ? "Show Label" : "Hide Label", action: { [weak self] in
            self?.setActorLabelHidden(id: hit.id, hidden: !payload.labelHidden)
        }))

        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        sizeMenu.addItem(menuItem(title: "Small", action: { [weak self] in
            self?.setActorScale(id: hit.id, scale: 0.72)
        }))
        sizeMenu.addItem(menuItem(title: "Normal", action: { [weak self] in
            self?.setActorScale(id: hit.id, scale: 1.0)
        }))
        sizeMenu.addItem(menuItem(title: "Large", action: { [weak self] in
            self?.setActorScale(id: hit.id, scale: 1.18)
        }))
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        menu.addItem(sizeItem)
        menu.setSubmenu(sizeMenu, for: sizeItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Hide Actor Layer", action: { [weak self] in
            _ = self?.setAgentActorsHidden(true, showFeedback: true)
        }))
        menu.addItem(menuItem(title: "Remove Actor", action: { [weak self] in
            self?.removeActor(id: hit.id)
        }))

        menu.popUp(positioning: nil, at: hit.localPoint, in: hit.window.overlayView)
        return true
    }

    private func menuItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = ActorMenuActionTarget(action)
        menuActionTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(ActorMenuActionTarget.invokeMenuAction), keyEquivalent: "")
        item.target = target
        return item
    }

    private func setActorLabelHidden(id: ScreenOverlayLayerID, hidden: Bool) {
        guard let layer = layersByID[id],
              case .pet(let payload) = layer.payload else { return }
        layersByID[id] = layer.replacingPayload(.pet(payload.withLabelHidden(hidden)))
        render()
        updateLifecycleMonitors()
    }

    private func setActorScale(id: ScreenOverlayLayerID, scale: CGFloat) {
        guard let layer = layersByID[id],
              case .pet(let payload) = layer.payload else { return }
        layersByID[id] = layer.replacingPayload(.pet(payload.withScale(scale)))
        render()
        updateLifecycleMonitors()
    }

    private func removeActor(id: ScreenOverlayLayerID) {
        layersByID.removeValue(forKey: id)
        motionsByLayerID.removeValue(forKey: id)
        if hoveredActorID == id {
            hoveredActorID = nil
        }
        if dragState?.id == id {
            dragState = nil
            cancelActorDragTimeout()
        }
        render()
        updateLifecycleMonitors()
        resetPointerCapture()
    }

    private func showActorVisibilityFeedback(_ snapshot: ScreenOverlayActorVisibilitySnapshot) {
        let text = snapshot.hidden ? "Actor notes hidden" : "Actor notes shown"
        let detail = snapshot.hidden ? "Press Hyper+B to bring them back." : "\(snapshot.actorCount) actor\(snapshot.actorCount == 1 ? "" : "s") available."
        let layer = ScreenOverlayLayerSnapshot(
            id: ScreenOverlayLayerID("actor-layer-visibility-feedback"),
            owner: .agentApi,
            screen: .all,
            zIndex: 700,
            opacity: 1,
            payload: .toast(ScreenOverlayTextPayload(
                text: text,
                detail: detail,
                point: nil,
                placement: .bottom,
                style: .info
            )),
            expiresAt: Date().addingTimeInterval(1.6)
        )
        publishLayer(layer)
    }

    private func hitActor(at globalPoint: CGPoint) -> (id: ScreenOverlayLayerID, window: ScreenOverlayWindow, screenID: String, localPoint: CGPoint, rect: CGRect)? {
        guard let hit = screenLocalPoint(for: globalPoint) else { return nil }
        guard let layerHit = hit.window.overlayView.layerHit(at: hit.localPoint) else { return nil }
        return (layerHit.id, hit.window, hit.screenID, hit.localPoint, layerHit.rect)
    }

    fileprivate func handleWindowEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        let location = event.locationInWindow
        let globalPoint = CGPoint(
            x: window.frame.minX + location.x,
            y: window.frame.minY + location.y
        )
        return handlePointerEvent(event, at: globalPoint)
    }

    private func screenLocalPoint(for globalPoint: CGPoint) -> (window: ScreenOverlayWindow, screenID: String, localPoint: CGPoint)? {
        for (screenID, window) in windowsByScreenID where window.frame.contains(globalPoint) {
            let localPoint = CGPoint(
                x: globalPoint.x - window.frame.minX,
                y: globalPoint.y - window.frame.minY
            )
            return (window, screenID, localPoint)
        }
        return nil
    }

    private func dismissAgentOverlays() {
        let before = layersByID.count
        layersByID = layersByID.filter { _, layer in
            guard layer.owner == .agentApi else { return true }
            return !layer.isDismissible
        }
        motionsByLayerID = motionsByLayerID.filter { id, _ in layersByID[id] != nil }
        if let dragState, layersByID[dragState.id] == nil {
            self.dragState = nil
            cancelActorDragTimeout()
            resetPointerCapture()
        }
        if let hoveredActorID, layersByID[hoveredActorID] == nil {
            self.hoveredActorID = nil
            ScreenOverlayActorHUDController.shared.hide()
        }
        guard layersByID.count != before else { return }
        render()
        updateLifecycleMonitors()
    }
}

private struct OverlayActorDragState {
    let id: ScreenOverlayLayerID
    var screenID: String
    let offset: CGPoint
    let startPoint: CGPoint
    var lastPoint: CGPoint
    let startedAt: Date
}

private final class ActorMenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invokeMenuAction() {
        action()
    }
}

private extension ScreenOverlayLayerSnapshot {
    var isDismissible: Bool {
        switch payload {
        case .pet(let payload):
            return payload.dismissible
        default:
            return true
        }
    }

    var isParkableActor: Bool {
        owner == .agentApi && !isDismissible
    }

    func replacingPayload(_ payload: ScreenOverlayPayload) -> ScreenOverlayLayerSnapshot {
        ScreenOverlayLayerSnapshot(
            id: id,
            owner: owner,
            screen: screen,
            zIndex: zIndex,
            opacity: opacity,
            payload: payload,
            expiresAt: expiresAt
        )
    }
}

private extension ScreenOverlayPetPayload {
    var hasActivationTarget: Bool {
        targetBundleIdentifier != nil || targetApp != nil || targetAppPath != nil
    }

    var targetDisplayName: String {
        targetApp ?? targetBundleIdentifier ?? targetAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "App"
    }
}

private struct OverlayLayerMotion {
    enum Easing: String {
        case linear
        case easeInOut
        case spring

        static func parse(_ value: String?) -> Easing {
            switch value?.lowercased() {
            case "linear":
                return .linear
            case "easeinout", "ease-in-out", "ease_in_out":
                return .easeInOut
            case "spring", nil:
                return .spring
            default:
                return .spring
            }
        }
    }

    let from: CGPoint
    let to: CGPoint
    let startedAt: Date
    let duration: TimeInterval
    let easing: Easing
    let restingState: String?

    func isComplete(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= duration
    }

    func point(at date: Date) -> CGPoint {
        let rawProgress = duration <= 0 ? 1 : min(max(date.timeIntervalSince(startedAt) / duration, 0), 1)
        let progress = eased(rawProgress)
        return CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
    }

    private func eased(_ progress: Double) -> Double {
        switch easing {
        case .linear:
            return progress
        case .easeInOut:
            return progress * progress * (3 - 2 * progress)
        case .spring:
            let damping = exp(-6.8 * progress)
            let oscillation = cos(10.5 * progress)
            return min(max(1 - damping * oscillation, 0), 1)
        }
    }
}

private final class ScreenOverlayWindow: NSPanel {
    let overlayView = ScreenOverlayCanvasView(frame: .zero)
    weak var controller: ScreenOverlayCanvasController?

    init(frame: CGRect, controller: ScreenOverlayCanvasController) {
        self.controller = controller
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        alphaValue = 0
        overlayView.frame = NSRect(origin: .zero, size: frame.size)
        overlayView.autoresizingMask = [.width, .height]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if controller?.handleWindowEvent(event, in: self) == true {
            return
        }
        super.sendEvent(event)
    }
}

private final class ScreenOverlayCanvasView: NSView {
    var layers: [ScreenOverlayLayerSnapshot] = [] {
        didSet { needsDisplay = true }
    }
    var hoveredLayerID: ScreenOverlayLayerID? {
        didSet { needsDisplay = true }
    }
    private var interactiveRectsByLayerID: [ScreenOverlayLayerID: CGRect] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        interactiveRectsByLayerID.removeAll()

        for layer in layers {
            NSGraphicsContext.saveGraphicsState()
            NSColor.black.withAlphaComponent(0).set()
            switch layer.payload {
            case .snapZones(let payload):
                drawSnapZones(payload, opacity: layer.opacity)
            case .toast(let payload):
                drawTextPill(payload, opacity: layer.opacity, isToast: true)
            case .label(let payload):
                drawTextPill(payload, opacity: layer.opacity, isToast: false)
            case .highlight(let payload):
                drawHighlight(payload, opacity: layer.opacity)
            case .pet(let payload):
                drawPet(payload, id: layer.id, opacity: layer.opacity, isHovered: hoveredLayerID == layer.id)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func layerHit(at point: CGPoint) -> (id: ScreenOverlayLayerID, rect: CGRect)? {
        for layer in layers.reversed() {
            guard let rect = interactiveRectsByLayerID[layer.id], rect.contains(point) else {
                continue
            }
            return (layer.id, rect)
        }
        return nil
    }

    private func drawTextPill(_ payload: ScreenOverlayTextPayload, opacity: CGFloat, isToast: Bool) {
        let titleFont = NSFont.monospacedSystemFont(ofSize: isToast ? 13 : 11, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let maxWidth = min(bounds.width - 64, isToast ? 460 : 320)
        let title = attributed(payload.text, font: titleFont, color: NSColor.white.withAlphaComponent(0.94 * opacity))
        let detail = payload.detail.map {
            attributed($0, font: detailFont, color: NSColor.white.withAlphaComponent(0.66 * opacity))
        }
        let detailSize = detail?.boundingRect(
            with: CGSize(width: maxWidth - 28, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size ?? .zero
        let titleSize = title.boundingRect(
            with: CGSize(width: maxWidth - 28, height: 80),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let width = min(maxWidth, max(110, max(titleSize.width, detailSize.width) + 28))
        let height = max(30, titleSize.height + (detail == nil ? 12 : detailSize.height + 18))
        let origin = overlayOrigin(
            placement: payload.placement,
            point: payload.point,
            size: CGSize(width: width, height: height),
            margin: isToast ? 42 : 18
        )
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))

        drawPanel(rect, style: payload.style, opacity: opacity, radius: min(16, height / 2))
        title.draw(with: CGRect(x: rect.minX + 14, y: rect.maxY - titleSize.height - (detail == nil ? 8 : 10), width: width - 28, height: titleSize.height), options: [.usesLineFragmentOrigin])
        if let detail {
            detail.draw(with: CGRect(x: rect.minX + 14, y: rect.minY + 8, width: width - 28, height: detailSize.height + 2), options: [.usesLineFragmentOrigin])
        }
    }

    private func drawHighlight(_ payload: ScreenOverlayHighlightPayload, opacity: CGFloat) {
        let rect = payload.rect.insetBy(dx: -3, dy: -3)
        let radius = min(payload.cornerRadius, min(rect.width, rect.height) * 0.2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let tint = color(for: payload.style)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = .zero
        shadow.shadowColor = tint.withAlphaComponent(0.25 * opacity)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        tint.withAlphaComponent(0.08 * opacity).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        path.lineWidth = 2
        tint.withAlphaComponent(0.82 * opacity).setStroke()
        path.stroke()

        if let label = payload.label, !label.isEmpty {
            let textPayload = ScreenOverlayTextPayload(
                text: label,
                detail: nil,
                point: CGPoint(x: rect.minX + 14, y: rect.maxY + 18),
                placement: .point,
                style: payload.style
            )
            drawTextPill(textPayload, opacity: opacity, isToast: false)
        }
    }

    private func drawPet(_ payload: ScreenOverlayPetPayload, id: ScreenOverlayLayerID, opacity: CGFloat, isHovered: Bool) {
        let glyphFont = NSFont.systemFont(ofSize: 44, weight: .regular)
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let glyph = attributed(payload.glyph, font: glyphFont, color: NSColor.white.withAlphaComponent(0.96 * opacity))
        let name = payload.labelHidden ? nil : payload.name.map { attributed($0, font: nameFont, color: NSColor.white.withAlphaComponent(0.96 * opacity)) }
        let message = payload.labelHidden ? nil : payload.message.map {
            attributed($0, font: messageFont, color: NSColor.white.withAlphaComponent(0.86 * opacity))
        }
        let actorScale = max(0.55, min(payload.scale, 1.35))
        let artSize = CGSize(width: 96 * actorScale, height: 104 * actorScale)
        let textWidth: CGFloat = (name == nil && message == nil) ? 0 : 228
        let textHeight = textPlateHeight(name: name, message: message, width: textWidth)
        let bubbleWidth = artSize.width + (textWidth > 0 ? textWidth + 10 : 0)
        let bubbleHeight = max(artSize.height, textHeight)
        let origin = overlayOrigin(
            placement: payload.placement,
            point: payload.point,
            size: CGSize(width: bubbleWidth, height: bubbleHeight),
            margin: 30
        )
        let rect = CGRect(origin: origin, size: CGSize(width: bubbleWidth, height: bubbleHeight))
        let artRect = CGRect(
            x: rect.minX,
            y: rect.midY - artSize.height / 2,
            width: artSize.width,
            height: artSize.height
        )
        let dragPhase = Date().timeIntervalSinceReferenceDate * 11
        let dragLift: CGFloat = payload.isDragging ? 8 + CGFloat(sin(dragPhase)) * 2.5 : 0
        let dragTilt: CGFloat = payload.isDragging
            ? (payload.state == "run_left" ? 7 : -7) + CGFloat(sin(dragPhase * 0.72)) * 2.5
            : 0
        let dragScaleX: CGFloat = payload.isDragging ? 1.05 + CGFloat(sin(dragPhase * 0.9)) * 0.018 : 1
        let dragScaleY: CGFloat = payload.isDragging ? 0.98 + CGFloat(cos(dragPhase * 0.9)) * 0.018 : 1
        let hoverLift: CGFloat = isHovered && !payload.isDragging ? 4 : 0
        let hoverInset: CGFloat = isHovered && !payload.isDragging ? -3 : 0
        let bodyRect = artRect.insetBy(dx: hoverInset, dy: hoverInset).offsetBy(dx: 0, dy: dragLift + hoverLift)

        if isHovered {
            drawActorHoverHalo(around: artRect.offsetBy(dx: 0, dy: hoverLift), style: payload.style, opacity: opacity)
        }

        NSGraphicsContext.saveGraphicsState()
        if payload.isDragging {
            let transform = NSAffineTransform()
            transform.translateX(by: bodyRect.midX, yBy: bodyRect.midY)
            transform.rotate(byDegrees: dragTilt)
            transform.scaleX(by: dragScaleX, yBy: dragScaleY)
            transform.translateX(by: -bodyRect.midX, yBy: -bodyRect.midY)
            transform.concat()
        }
        if let petID = payload.petID,
           let frame = CodexPetAssetCache.shared.frame(for: petID, state: payload.state) {
            frame.image.draw(
                in: bodyRect,
                from: frame.sourceRect,
                operation: .sourceOver,
                fraction: opacity,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            glyph.draw(
                with: CGRect(x: bodyRect.midX - 26, y: bodyRect.midY - 26, width: 52, height: 52),
                options: [.usesLineFragmentOrigin]
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        interactiveRectsByLayerID[id] = artRect.insetBy(dx: -8, dy: -8)
        guard textWidth > 0 else {
            return
        }
        let textRect = CGRect(
            x: artRect.maxX + 10,
            y: rect.midY - textHeight / 2,
            width: textWidth,
            height: textHeight
        )
        drawTranslucentTextWash(textRect, style: payload.style, opacity: opacity, isHovered: isHovered)

        var cursorY = textRect.maxY - 10
        if let name {
            let nameRect = CGRect(x: textRect.minX + 12, y: cursorY - 16, width: textRect.width - 24, height: 16)
            drawCrispOverlayText(name, in: nameRect, opacity: opacity)
            cursorY = nameRect.minY - 4
        }
        if let message {
            let messageRect = CGRect(x: textRect.minX + 12, y: textRect.minY + 10, width: textRect.width - 24, height: max(18, cursorY - textRect.minY - 10))
            drawCrispOverlayText(message, in: messageRect, opacity: opacity)
        }
    }

    private func textPlateHeight(name: NSAttributedString?, message: NSAttributedString?, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let messageSize = message?.boundingRect(
            with: CGSize(width: width - 24, height: 72),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size ?? .zero
        return max(38, (name == nil ? 0 : 20) + (message == nil ? 0 : ceil(messageSize.height) + 10) + 18)
    }

    private func drawActorHoverHalo(around rect: CGRect, style: ScreenOverlayStyle, opacity: CGFloat) {
        let tint = color(for: style)
        let haloRect = rect.insetBy(dx: -8, dy: -8)
        let path = NSBezierPath(ovalIn: haloRect)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = .zero
        shadow.shadowColor = tint.withAlphaComponent(0.30 * opacity)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        tint.withAlphaComponent(0.12 * opacity).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTranslucentTextWash(_ rect: CGRect, style: ScreenOverlayStyle, opacity: CGFloat, isHovered: Bool) {
        let radius: CGFloat = 12
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let tint = color(for: style)
        let hoverBoost: CGFloat = isHovered ? 1.16 : 1.0

        let shadow = NSShadow()
        shadow.shadowBlurRadius = isHovered ? 26 : 22
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * hoverBoost * opacity)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.060, alpha: 0.28 * hoverBoost * opacity).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(
            starting: NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.28, alpha: 0.32 * hoverBoost * opacity),
            ending: NSColor(calibratedRed: 0.055, green: 0.070, blue: 0.092, alpha: 0.34 * hoverBoost * opacity)
        )?.draw(in: rect, angle: -90)

        tint.withAlphaComponent((isHovered ? 0.12 : 0.08) * opacity).setFill()
        path.fill()

        let lowerWash = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.52)
        NSGradient(
            starting: NSColor.black.withAlphaComponent(0.04 * opacity),
            ending: NSColor.black.withAlphaComponent(0.16 * opacity)
        )?.draw(in: lowerWash, angle: -90)

        let glossRect = CGRect(x: rect.minX + 1, y: rect.midY, width: rect.width - 2, height: rect.height * 0.45)
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.18 * opacity),
            ending: NSColor.white.withAlphaComponent(0.02 * opacity)
        )?.draw(in: glossRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let innerPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        innerPath.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.26 * opacity).setStroke()
        innerPath.stroke()

        path.lineWidth = 1
        tint.withAlphaComponent((isHovered ? 0.38 : 0.24) * opacity).setStroke()
        path.stroke()
    }

    private func drawCrispOverlayText(_ text: NSAttributedString, in rect: CGRect, opacity: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.68 * opacity)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        text.draw(with: rect.offsetBy(dx: 0, dy: -0.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()

        let halo = NSMutableAttributedString(attributedString: text)
        halo.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.32 * opacity), range: NSRange(location: 0, length: halo.length))
        halo.draw(with: rect.offsetBy(dx: 0.5, dy: -0.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        halo.draw(with: rect.offsetBy(dx: -0.5, dy: -0.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawSnapZones(_ payload: ScreenOverlaySnapZonesPayload, opacity: CGFloat) {
        for zone in payload.zones {
            drawSnapZone(zone, payload: payload, opacity: opacity)
        }

        if let previewRect = payload.previewRect {
            drawSnapPreview(previewRect, label: payload.previewLabel, payload: payload, opacity: opacity)
        }
    }

    private func drawSnapZone(
        _ zone: ScreenOverlaySnapZone,
        payload: ScreenOverlaySnapZonesPayload,
        opacity: CGFloat
    ) {
        let rect = zone.rect.insetBy(dx: 1.5, dy: 1.5)
        let radius = min(payload.cornerRadius, min(rect.width, rect.height) * 0.34)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let idleStrength = max(0.35, min(payload.zoneOpacity / 0.10, 1.4))
        let hoverStrength = max(0.35, min(payload.highlightOpacity / 0.22, 1.4))
        let colors = snapPaletteColors(for: payload.palette)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = zone.isHovered ? 18 : 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent((zone.isHovered ? 0.20 : 0.10) * opacity)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let baseTop = colors.zoneTop.withAlphaComponent(
            (zone.isHovered ? 0.42 * hoverStrength : 0.22 * idleStrength) * opacity
        )
        let baseBottom = colors.zoneBottom.withAlphaComponent(
            (zone.isHovered ? 0.34 * hoverStrength : 0.15 * idleStrength) * opacity
        )
        NSGradient(starting: baseTop, ending: baseBottom)?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        if zone.isHovered {
            let glowPath = path.copy() as! NSBezierPath
            glowPath.lineWidth = 6
            colors.glow.withAlphaComponent(payload.highlightOpacity * 0.28 * opacity).setStroke()
            glowPath.stroke()
        }

        path.lineWidth = zone.isHovered ? 1.6 : 1.0
        colors.border.withAlphaComponent(
            (zone.isHovered ? 0.54 * hoverStrength : 0.10 * idleStrength) * opacity
        ).setStroke()
        path.stroke()

        let lipRect = CGRect(x: rect.minX + 1.5, y: rect.maxY - 2.5, width: rect.width - 3, height: 2)
        if lipRect.width > 0 {
            let lipPath = NSBezierPath(roundedRect: lipRect, xRadius: 1, yRadius: 1)
            NSColor.white.withAlphaComponent((zone.isHovered ? 0.18 : 0.08) * opacity).setFill()
            lipPath.fill()
        }

        drawLabel(zone.label, in: rect, emphasized: zone.isHovered, opacity: opacity)
    }

    private func drawSnapPreview(
        _ rect: CGRect,
        label: String?,
        payload: ScreenOverlaySnapZonesPayload,
        opacity: CGFloat
    ) {
        let previewRect = rect.insetBy(dx: 10, dy: 10)
        let radius = min(payload.cornerRadius, min(previewRect.width, previewRect.height) * 0.14)
        let path = NSBezierPath(roundedRect: previewRect, xRadius: radius, yRadius: radius)
        let colors = snapPaletteColors(for: payload.palette)

        let fillAlpha: CGFloat = payload.palette == .spatialLens
            ? max(0.10, payload.previewOpacity * 0.72) * opacity
            : payload.previewOpacity * 0.22 * opacity
        NSGradient(
            starting: colors.previewTop.withAlphaComponent(fillAlpha),
            ending: colors.previewBottom.withAlphaComponent(fillAlpha)
        )?.draw(in: path, angle: -45)

        path.lineWidth = 1.6
        if payload.palette == .mint {
            path.setLineDash([10, 8], count: 2, phase: 0)
        }
        colors.previewBorder.withAlphaComponent(
            max(payload.palette == .spatialLens ? 0.48 : 0.34, payload.previewOpacity * 3.2) * opacity
        ).setStroke()
        path.stroke()
        path.setLineDash([], count: 0, phase: 0)

        let innerPath = NSBezierPath(
            roundedRect: previewRect.insetBy(dx: 7, dy: 7),
            xRadius: max(radius - 4, 8),
            yRadius: max(radius - 4, 8)
        )
        innerPath.lineWidth = 1
        NSColor.white.withAlphaComponent(max(0.08, payload.previewOpacity * 1.2) * opacity).setStroke()
        innerPath.stroke()

        if let label {
            let tagRect = CGRect(x: previewRect.minX + 14, y: previewRect.maxY - 34, width: 110, height: 24)
            let tagPath = NSBezierPath(roundedRect: tagRect, xRadius: 12, yRadius: 12)
            NSColor(calibratedWhite: 0.08, alpha: 0.62 * opacity).setFill()
            tagPath.fill()
            NSColor.white.withAlphaComponent(0.10 * opacity).setStroke()
            tagPath.lineWidth = 1
            tagPath.stroke()
            drawLabel(label, in: tagRect, emphasized: true, opacity: opacity)
        }
    }

    private struct SnapPaletteColors {
        let zoneTop: NSColor
        let zoneBottom: NSColor
        let glow: NSColor
        let border: NSColor
        let previewTop: NSColor
        let previewBottom: NSColor
        let previewBorder: NSColor
    }

    private func snapPaletteColors(for palette: ScreenOverlaySnapPalette) -> SnapPaletteColors {
        switch palette {
        case .mint:
            return SnapPaletteColors(
                zoneTop: NSColor(calibratedWhite: 0.13, alpha: 1),
                zoneBottom: NSColor(calibratedWhite: 0.07, alpha: 1),
                glow: NSColor(calibratedRed: 0.25, green: 0.84, blue: 0.58, alpha: 1),
                border: NSColor(calibratedRed: 0.52, green: 0.94, blue: 0.72, alpha: 1),
                previewTop: .white,
                previewBottom: .white,
                previewBorder: NSColor(calibratedRed: 0.44, green: 0.90, blue: 0.68, alpha: 1)
            )
        case .spatialLens:
            return SnapPaletteColors(
                zoneTop: NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.56, alpha: 1),
                zoneBottom: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.42, alpha: 1),
                glow: NSColor(calibratedRed: 0.42, green: 0.58, blue: 1.00, alpha: 1),
                border: NSColor(calibratedRed: 0.58, green: 0.66, blue: 1.00, alpha: 1),
                previewTop: NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.00, alpha: 1),
                previewBottom: NSColor(calibratedRed: 0.56, green: 0.30, blue: 1.00, alpha: 1),
                previewBorder: NSColor(calibratedRed: 0.60, green: 0.68, blue: 1.00, alpha: 1)
            )
        }
    }

    private func drawLabel(_ label: String, in rect: CGRect, emphasized: Bool, opacity: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: emphasized ? 11 : 10, weight: emphasized ? .semibold : .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent((emphasized ? 0.92 : 0.72) * opacity),
        ]
        let attributed = NSAttributedString(string: label.uppercased(), attributes: attributes)
        let size = attributed.size()
        let drawPoint = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        attributed.draw(at: drawPoint)
    }

    private func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private func overlayOrigin(
        placement: ScreenOverlayPlacement,
        point: CGPoint?,
        size: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let cursor = convertGlobalPointToLocal(NSEvent.mouseLocation)
        let anchor: CGPoint
        switch placement {
        case .top:
            anchor = CGPoint(x: bounds.midX, y: bounds.maxY - margin - size.height / 2)
        case .bottom:
            anchor = CGPoint(x: bounds.midX, y: bounds.minY + margin + size.height / 2)
        case .center:
            anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        case .cursor:
            anchor = cursor
        case .point:
            anchor = point ?? cursor
        }

        return CGPoint(
            x: min(max(anchor.x - size.width / 2, 16), bounds.maxX - size.width - 16),
            y: min(max(anchor.y - size.height / 2, 16), bounds.maxY - size.height - 16)
        )
    }

    private func convertGlobalPointToLocal(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
    }

    private func drawPanel(_ rect: CGRect, style: ScreenOverlayStyle, opacity: CGFloat, radius: CGFloat) {
        let tint = color(for: style)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.26 * opacity)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSGradient(
            starting: NSColor(calibratedWhite: 0.12, alpha: 0.90 * opacity),
            ending: NSColor(calibratedWhite: 0.06, alpha: 0.90 * opacity)
        )?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        path.lineWidth = 1
        tint.withAlphaComponent(0.34 * opacity).setStroke()
        path.stroke()

        let lipRect = CGRect(x: rect.minX + 10, y: rect.maxY - 2, width: rect.width - 20, height: 1)
        NSColor.white.withAlphaComponent(0.10 * opacity).setFill()
        NSBezierPath(roundedRect: lipRect, xRadius: 0.5, yRadius: 0.5).fill()
    }

    private func color(for style: ScreenOverlayStyle) -> NSColor {
        switch style {
        case .info:
            return NSColor(calibratedRed: 0.36, green: 0.72, blue: 1.0, alpha: 1)
        case .success:
            return NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.62, alpha: 1)
        case .warning:
            return NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.24, alpha: 1)
        case .danger:
            return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.38, alpha: 1)
        case .playful:
            return NSColor(calibratedRed: 0.95, green: 0.66, blue: 1.0, alpha: 1)
        }
    }
}

private final class CodexPetAssetCache {
    static let shared = CodexPetAssetCache()

    struct Frame {
        let image: NSImage
        let sourceRect: CGRect
    }

    private struct Metadata: Decodable {
        struct State: Decodable {
            let row: Int
            let frames: Int
            let frameWidth: CGFloat
            let frameHeight: CGFloat
        }

        let spritesheetPath: String?
        /// Bundled pets carry identity here and fetch their art once from a
        /// versioned URL; the hash keys a cache that never needs to expire.
        let spritesheetURL: String?
        let spritesheetSHA256: String?
        let states: [String: State]?
    }

    private var cache: [String: (image: NSImage, metadata: Metadata?)] = [:]
    private var fetching: Set<String> = []
    private static let downloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    private init() {}

    func frame(for petID: String, state requestedState: String?) -> Frame? {
        guard let asset = load(petID: petID),
              let size = asset.image.representations.first.map({ CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }) else {
            return nil
        }

        let state = requestedState.flatMap { asset.metadata?.states?[$0] }
            ?? asset.metadata?.states?["idle"]
            ?? Metadata.State(row: 0, frames: 1, frameWidth: 192, frameHeight: 208)
        let frameWidth = max(1, state.frameWidth)
        let frameHeight = max(1, state.frameHeight)
        let frameCount = max(1, state.frames)
        let frameIndex = Int(Date().timeIntervalSinceReferenceDate * 8) % frameCount
        let row = max(0, state.row)
        let maxX = max(0, size.width - frameWidth)
        let y = max(0, size.height - CGFloat(row + 1) * frameHeight)
        return Frame(
            image: asset.image,
            sourceRect: CGRect(x: min(CGFloat(frameIndex) * frameWidth, maxX), y: y, width: frameWidth, height: frameHeight)
        )
    }

    private func load(petID: String) -> (image: NSImage, metadata: Metadata?)? {
        if let cached = cache[petID] {
            return cached
        }

        guard petID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        let root = bundledPetRoot(petID: petID) ?? codexPetRoot(petID: petID)
        let metadataURL = root.appendingPathComponent("pet.json")
        let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        let localSheet = root.appendingPathComponent(metadata?.spritesheetPath ?? "spritesheet.webp")
        let sheet: URL
        if FileManager.default.fileExists(atPath: localSheet.path) {
            sheet = localSheet
        } else if let hash = metadata?.spritesheetSHA256, let remote = metadata?.spritesheetURL {
            let cached = Self.cacheDirectory.appendingPathComponent(hash + ".webp")
            guard FileManager.default.fileExists(atPath: cached.path) else {
                fetch(remote, hash: hash, to: cached)
                return nil
            }
            sheet = cached
        } else {
            return nil
        }
        guard let image = NSImage(contentsOf: sheet) else {
            return nil
        }

        let asset = (image, metadata)
        cache[petID] = asset
        return asset
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.lattices.app")
            .appendingPathComponent("Pets")
    }

    /// Fetches a spritesheet once; the pet appears on the next frame after it lands.
    private func fetch(_ remote: String, hash: String, to destination: URL) {
        guard !fetching.contains(hash), let url = URL(string: remote),
              url.scheme == "https", let host = url.host, Self.downloadHosts.contains(host) else { return }
        fetching.insert(hash)
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, let data, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash {
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: destination, options: .atomic)
            }
            DispatchQueue.main.async { self?.fetching.remove(hash) }
        }.resume()
    }

    private func bundledPetRoot(petID: String) -> URL? {
        let candidateRoots = [
            Bundle.main.resourceURL?.appendingPathComponent("Pets"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Pets"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("apps/mac/Resources/Pets"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Pets"),
        ].compactMap { $0 }

        for petsRoot in candidateRoots {
            let root = petsRoot.appendingPathComponent(petID)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("pet.json").path) {
                return root
            }
        }

        return nil
    }

    private func codexPetRoot(petID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("pets")
            .appendingPathComponent(petID)
    }
}
