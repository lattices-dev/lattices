import AppKit
import CoreGraphics

/// Immutable plan rendered by Spatial Lens. Building and comparing proposals
/// has no side effects; only `commit` crosses into ActionRuntime.
struct SpatialLensProposal: Equatable {
    let wid: UInt32
    let pid: Int32
    let sourceFrame: CGRect
    let sourceDisplayID: String
    let targetDisplay: DisplayTopology.Display
    let target: SpatialLensTarget
    let selectionSource: SpatialLensSelectionSource
    let placement: PlacementSpec
    let cycleIndex: Int
    let targetFrame: CGRect
    let label: String
}

/// Hold physical Control+Option to reveal contextual placement options around
/// the window under the pointer. Pointer movement previews a proposal; release
/// of either modifier commits exactly one verified ActionRuntime placement.
final class SpatialLensController {
    static let shared = SpatialLensController()

    private struct Session {
        let generation: UInt64
        let anchor: CGPoint              // AppKit global coordinates
        let target: WindowEntry
        let sourceFrame: CGRect          // CG/AX top-left coordinates
        let sourceDisplay: DisplayTopology.Display
        let lensDisplay: DisplayTopology.Display
        let topology: DisplayTopology
        let targetRegions: [SpatialLensTargetRegion]
        var pushed = false
        var proposal: SpatialLensProposal?
    }

    private var timer: Timer?
    private var session: Session?
    private var running = false

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        running = true
        SpatialLensModifierMonitor.shared.start { [weak self] event in
            self?.handle(event)
        }
        DiagnosticLog.shared.info("SpatialLens: ready")
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        running = false
        SpatialLensModifierMonitor.shared.stop()
        cancelSession(reason: "stop")
    }

    func resetForSystemInputBoundary(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        SpatialLensModifierMonitor.shared.reset()
        cancelSession(reason: reason)
    }

    private func handle(_ event: SpatialLensModifierMonitor.Event) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard running else { return }

        switch event {
        case .pressed(let generation):
            begin(generation: generation)
        case .chorded(let generation):
            guard session?.generation == generation else { return }
            cancelSession(reason: "Control+Option chord")
        case .released(let generation):
            guard session?.generation == generation else { return }
            finish()
        case .cancelled(let generation):
            guard session?.generation == generation else { return }
            cancelSession(reason: "modifier cancelled")
        }
    }

    private func begin(generation: UInt64) {
        cancelSession(reason: "new hold")
        guard !SpaceZoomInput.engaged, Preferences.shared.spatialLensEnabled,
              PermissionChecker.shared.accessibility,
              !WindowQuickMenu.shared.isActive else {
            return
        }

        let anchor = NSEvent.mouseLocation
        let cgPoint = Self.cgPoint(fromAppKit: anchor)
        let target = DesktopModel.shared.liveFrontWindow(
            at: cgPoint,
            excludingPid: ProcessInfo.processInfo.processIdentifier
        )
        guard let target else {
            DiagnosticLog.shared.warn("SpatialLens: target-selection | result=none")
            return
        }
        DiagnosticLog.shared.info(
            "SpatialLens: target-selection | pointer=\(Self.pointDescription(cgPoint)) result=\(Self.targetDescription(target)) source=live-pointer"
        )

        let sourceFrame = Self.rect(for: target.frame)
        let topology = DisplayTopology.live()
        let center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        guard let sourceDisplay = topology.display(containing: center),
              let lensDisplay = topology.display(containing: cgPoint),
              let lensScreen = screen(for: lensDisplay) else { return }
        let targetRegions = SpatialLensTargetLayout.regions(
            center: anchor,
            within: lensScreen.visibleFrame
        )

        session = Session(
            generation: generation,
            anchor: anchor,
            target: target,
            sourceFrame: sourceFrame,
            sourceDisplay: sourceDisplay,
            lensDisplay: lensDisplay,
            topology: topology,
            targetRegions: targetRegions
        )
        if let session { render(session) }
        DiagnosticLog.shared.info("SpatialLens: activated wid=\(target.wid)")
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard let current = session else { return }
        guard !SpaceZoomInput.engaged, Preferences.shared.spatialLensEnabled,
              PermissionChecker.shared.accessibility else {
            cancelSession(reason: "unavailable")
            return
        }

        let pointer = NSEvent.mouseLocation
        let delta = CGVector(dx: pointer.x - current.anchor.x, dy: pointer.y - current.anchor.y)
        let distance = hypot(delta.dx, delta.dy)

        let next = proposal(for: current, pointer: pointer, distance: distance)
        if next.session.proposal != current.proposal || next.session.pushed != current.pushed {
            let selection = next.proposal.map {
                "target=\($0.target.rawValue) source=\($0.selectionSource.rawValue) display=\($0.targetDisplay.apiIndex) pushed=\(next.session.pushed)"
            } ?? "target=none pushed=false"
            DiagnosticLog.shared.info(
                "SpatialLens: decision | delta=(\(Int(delta.dx)),\(Int(delta.dy))) distance=\(Int(distance)) \(selection)"
            )
            session = next.session
            render(next.session)
        } else {
            session = next.session
        }
    }

    private func proposal(
        for current: Session,
        pointer: CGPoint,
        distance: CGFloat
    ) -> (session: Session, proposal: SpatialLensProposal?) {
        var next = current
        guard let selection = SpatialLensTargetLayout.selection(
            at: pointer,
            anchor: current.anchor,
            regions: current.targetRegions
        ) else {
            next.proposal = nil
            next.pushed = false
            return (next, nil)
        }
        let target = selection.target

        let placement: PlacementSpec
        let cycleIndex: Int
        let baseLabel: String
        var pushed = false
        var targetDisplay = current.sourceDisplay

        if let direction = target.cardinalDirection {
            let minDimension = min(current.sourceDisplay.visibleFrame.width, current.sourceDisplay.visibleFrame.height)
            let wantsPush = SpatialLensGesture.displayPushRequested(
                selectionSource: selection.source,
                wasPushed: current.pushed,
                distance: distance,
                minDimension: minDimension
            )
            let neighbor = current.topology.adjacent(to: current.sourceDisplay.id, direction: direction)
            pushed = wantsPush && neighbor != nil
            if pushed, let neighbor { targetDisplay = neighbor }
            let cycle = SpatialPlacementCycle.resolve(
                direction: direction,
                currentFrame: current.sourceFrame,
                sourceVisibleFrame: current.sourceDisplay.visibleFrame
            )
            placement = cycle.placement
            cycleIndex = cycle.cycleIndex
            baseLabel = cycle.label
        } else if let cornerPlacement = target.cornerPlacement {
            placement = cornerPlacement
            cycleIndex = 0
            baseLabel = target.label
        } else {
            next.proposal = nil
            next.pushed = false
            return (next, nil)
        }

        let targetFrame = WindowTiler.tileFrame(
            fractions: placement.fractions,
            inDisplay: targetDisplay.visibleFrame
        )
        let destinationSuffix = pushed ? " → \(targetDisplay.name)" : ""
        let proposal = SpatialLensProposal(
            wid: current.target.wid,
            pid: current.target.pid,
            sourceFrame: current.sourceFrame,
            sourceDisplayID: current.sourceDisplay.id,
            targetDisplay: targetDisplay,
            target: target,
            selectionSource: selection.source,
            placement: placement,
            cycleIndex: cycleIndex,
            targetFrame: targetFrame,
            label: baseLabel + destinationSuffix
        )
        next.pushed = pushed
        next.proposal = proposal
        return (next, proposal)
    }

    private func finish() {
        guard var current = session else { return }
        timer?.invalidate()
        timer = nil

        // Sample once at physical release so the committed proposal matches
        // the last visible pointer position even between timer ticks.
        let pointer = NSEvent.mouseLocation
        let delta = CGVector(dx: pointer.x - current.anchor.x, dy: pointer.y - current.anchor.y)
        current = proposal(for: current, pointer: pointer, distance: hypot(delta.dx, delta.dy)).session

        session = nil
        hideOverlay()
        guard let proposal = current.proposal else {
            DiagnosticLog.shared.info("SpatialLens: cancelled")
            return
        }
        commit(proposal)
    }

    private func commit(_ proposal: SpatialLensProposal) {
        let target = WindowMoveMenuModel.Target(wid: proposal.wid, pid: proposal.pid)
        let display = WindowMoveMenuModel.Display(
            index: proposal.targetDisplay.apiIndex,
            name: proposal.targetDisplay.name,
            isCurrent: proposal.targetDisplay.id == proposal.sourceDisplayID
        )
        DiagnosticLog.shared.info(
            "SpatialLens: commit wid=\(proposal.wid) placement=\(proposal.placement.wireValue) display=\(display.index)"
        )
        WindowMovementService.placeTarget(
            target,
            on: display,
            placement: proposal.placement,
            placementLabel: proposal.label,
            source: "app.spatial-lens"
        ) { outcome in
            if outcome.ok {
                AppFeedback.shared.commitHaptic()
            } else {
                self.showFailure(outcome.message)
            }
        }
    }

    private func cancelSession(reason: String) {
        let wasVisible = session != nil
        timer?.invalidate()
        timer = nil
        session = nil
        hideOverlay()
        if wasVisible {
            DiagnosticLog.shared.info("SpatialLens: dismissed (\(reason))")
        }
    }

    private func hideOverlay() {
        ScreenOverlayCanvasController.shared.removeLayers(owner: .spatialLens)
    }

    private func render(_ session: Session) {
        guard let sourceScreen = screen(for: session.sourceDisplay),
              let lensScreen = screen(for: session.lensDisplay) else {
            hideOverlay()
            return
        }
        let sourceScreenID = ScreenOverlayCanvasController.screenID(for: sourceScreen)
        let lensScreenID = ScreenOverlayCanvasController.screenID(for: lensScreen)
        let targetRect = Self.localAppKitRect(session.sourceFrame, on: sourceScreen)
        let hovered = session.proposal?.target
        var cueZones = session.targetRegions.map { region in
            let label: String
            if let direction = region.target.cardinalDirection {
                label = SpatialPlacementCycle.resolve(
                    direction: direction,
                    currentFrame: session.sourceFrame,
                    sourceVisibleFrame: session.sourceDisplay.visibleFrame
                ).label
            } else {
                label = region.target.label
            }
            return ScreenOverlaySnapZone(
                id: "spatialLens.cue.\(region.target.rawValue)",
                label: label,
                rect: Self.localScreenRect(region.rect, on: lensScreen),
                isHovered: hovered == region.target
            )
        }
        if let center = SpatialLensTargetLayout.center(of: session.targetRegions) {
            cueZones.append(ScreenOverlaySnapZone(
                id: "spatialLens.cue.cancel",
                label: "Release cancels",
                rect: Self.localScreenRect(
                    CGRect(
                        x: center.x - SpatialLensTargetLayout.targetSize.width / 2,
                        y: center.y - SpatialLensTargetLayout.targetSize.height / 2,
                        width: SpatialLensTargetLayout.targetSize.width,
                        height: SpatialLensTargetLayout.targetSize.height
                    ),
                    on: lensScreen
                ),
                isHovered: session.proposal == nil
            ))
        }

        var layers: [ScreenOverlayLayerSnapshot] = [
            ScreenOverlayLayerSnapshot(
                id: ScreenOverlayLayerID("spatialLens.target"),
                owner: .spatialLens,
                screen: .screen(id: sourceScreenID),
                zIndex: 210,
                opacity: 1,
                payload: .highlight(ScreenOverlayHighlightPayload(
                    rect: targetRect,
                    label: session.target.app,
                    style: .info,
                    cornerRadius: 14
                )),
                expiresAt: nil
            ),
        ]

        layers.append(
            ScreenOverlayLayerSnapshot(
                id: ScreenOverlayLayerID("spatialLens.cues.\(lensScreenID)"),
                owner: .spatialLens,
                screen: .screen(id: lensScreenID),
                zIndex: 215,
                opacity: 1,
                payload: .snapZones(ScreenOverlaySnapZonesPayload(
                    zones: cueZones,
                    previewRect: nil,
                    previewLabel: nil,
                    palette: .spatialLens,
                    zoneOpacity: 0.12,
                    highlightOpacity: 0.34,
                    previewOpacity: 0,
                    cornerRadius: 12
                )),
                expiresAt: nil
            )
        )

        if let proposal = session.proposal,
           proposal.targetDisplay.id == session.sourceDisplay.id {
            layers.append(
                ScreenOverlayLayerSnapshot(
                    id: ScreenOverlayLayerID("spatialLens.preview.\(sourceScreenID)"),
                    owner: .spatialLens,
                    screen: .screen(id: sourceScreenID),
                    zIndex: 205,
                    opacity: 1,
                    payload: .snapZones(ScreenOverlaySnapZonesPayload(
                        zones: [],
                        previewRect: Self.localAppKitRect(proposal.targetFrame, on: sourceScreen),
                        previewLabel: proposal.label,
                        palette: .spatialLens,
                        zoneOpacity: 0,
                        highlightOpacity: 0,
                        previewOpacity: 0.22,
                        cornerRadius: 14
                    )),
                    expiresAt: nil
                )
            )
        }

        if let proposal = session.proposal,
           proposal.targetDisplay.id != session.sourceDisplay.id,
           let targetScreen = screen(for: proposal.targetDisplay) {
            let targetScreenID = ScreenOverlayCanvasController.screenID(for: targetScreen)
            layers.append(
                ScreenOverlayLayerSnapshot(
                    id: ScreenOverlayLayerID("spatialLens.destination.\(targetScreenID)"),
                    owner: .spatialLens,
                    screen: .screen(id: targetScreenID),
                    zIndex: 205,
                    opacity: 1,
                    payload: .snapZones(ScreenOverlaySnapZonesPayload(
                        zones: [],
                        previewRect: Self.localAppKitRect(proposal.targetFrame, on: targetScreen),
                        previewLabel: proposal.label,
                        palette: .spatialLens,
                        zoneOpacity: 0,
                        highlightOpacity: 0,
                        previewOpacity: 0.24,
                        cornerRadius: 14
                    )),
                    expiresAt: nil
                )
            )
        }

        ScreenOverlayCanvasController.shared.replaceLayers(owner: .spatialLens, with: layers)
    }

    private func screen(for display: DisplayTopology.Display) -> NSScreen? {
        DisplayGeometryMapper.screen(forDisplayIndex: display.apiIndex)
            ?? NSScreen.screens.first(where: {
                ScreenOverlayCanvasController.screenID(for: $0) == display.id
            })
    }

    private func showFailure(_ message: String) {
        let layer = ScreenOverlayLayerSnapshot(
            id: ScreenOverlayLayerID("spatialLens.failure"),
            owner: .spatialLens,
            screen: .all,
            zIndex: 700,
            opacity: 1,
            payload: .toast(ScreenOverlayTextPayload(
                text: "Spatial Lens couldn't place the window",
                detail: message,
                point: nil,
                placement: .bottom,
                style: .warning
            )),
            expiresAt: Date().addingTimeInterval(2.2)
        )
        ScreenOverlayCanvasController.shared.publishLayer(layer)
    }

    private static func rect(for frame: WindowFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
    }

    private static func pointDescription(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    private static func targetDescription(_ entry: WindowEntry?) -> String {
        guard let entry else { return "none" }
        return "wid=\(entry.wid),pid=\(entry.pid),z=\(entry.zIndex),app=\(entry.app)"
    }

    private static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func localAppKitRect(_ cgRect: CGRect, on screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGRect(
            x: cgRect.minX,
            y: primaryHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
        return global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private static func localScreenRect(_ appKitRect: CGRect, on screen: NSScreen) -> CGRect {
        appKitRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }
}
