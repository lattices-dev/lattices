import AppKit

enum SpaceSwitchTransit {
    /// Coalesced taps can span many desktops even without OS key repeat.
    /// Only adjacent moves should walk through Dock swipes.
    static func usesDirectJump(distance: Int, hasDisplayPoint: Bool) -> Bool {
        abs(distance) > 1 && hasDisplayPoint
    }
}

/// Destination selection is independent of Dock's asynchronous transit.
/// Clamp every input, so reversing after holding at an edge responds at once.
struct SpaceSwitchSelection {
    let ordered: [Int]
    private(set) var index: Int
    private(set) var scrubbing = false
    var target: Int { ordered[index] }

    init?(ordered: [Int], current: Int) {
        guard let index = ordered.firstIndex(of: current) else { return nil }
        self.ordered = ordered
        self.index = index
    }

    mutating func press(_ offset: Int, repeated: Bool) {
        scrubbing = scrubbing || repeated
        index = min(max(index + offset, 0), ordered.count - 1)
    }

    /// Hold the destination without moving: transit waits for release.
    mutating func hold() { scrubbing = true }

    mutating func choose(_ target: Int) {
        guard let next = ordered.firstIndex(of: target) else { return }
        index = next
    }

    @discardableResult
    mutating func release(choosing: Bool = false) -> Bool {
        guard !choosing else { return false }
        scrubbing = false
        return true
    }
}

/// The next gesture is anchored to the committed destination, even while Dock
/// still reports the departing desktop. Coalesce it without changing the
/// selection that owns the landing cover.
struct SpaceSwitchLandingInput {
    private(set) var selection: SpaceSwitchSelection
    private(set) var wantsCanvas = false
    private(set) var direction = 1
    let point: CGPoint?

    init(selection: SpaceSwitchSelection, point: CGPoint?) {
        self.selection = selection
        self.selection.release()
        self.point = point
    }

    mutating func press(_ offset: Int, repeated: Bool) {
        direction = offset
        selection.press(offset, repeated: repeated)
    }

    mutating func openCanvas() {
        wantsCanvas = true
        selection.hold()
    }

    mutating func release() { selection.release(choosing: wantsCanvas) }
}

/// Main owns selection/presentation; the existing serial worker owns Dock.
/// A held key never queues a switch for each repeated key-down.
final class SpaceSwitchNavigator {
    private var selection: SpaceSwitchSelection?
    private var basis: WindowTiler.SpaceSwitchPlan?
    private var running = false
    private var pending = false
    private var lastDirection = 1
    private var scrubSession = false
    private var canvas = false
    /// A canvas landing is waiting for its cover to turn opaque.
    private var awaitingCover = false
    /// The canvas covers the display, so the switch needs no screen freeze.
    private var covered = false
    private var landingInput: SpaceSwitchLandingInput?
    private var epoch = 0
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func press(offset: Int, repeated: Bool, point: CGPoint?) {
        dispatchPrecondition(condition: .onQueue(.main))
        if DesktopCanvasController.shared.active {
            DesktopCanvasController.shared.returnToNormal { [weak self] in self?.press(offset: offset, repeated: repeated, point: point) }
            return
        }
        if landing || waitingForCanvas {
            prepareLandingInput()
            landingInput?.press(offset, repeated: repeated)
            DiagnosticLog.shared.info("SpaceScrub: queued landing navigation target=\(landingInput?.selection.target ?? 0)")
            return
        }
        if canvas {
            SpaceSwitchBezel.shared.moveCanvas(offset: offset)
            return
        }
        if selection == nil {
            guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: 0, from: point),
                  let state = SpaceSwitchSelection(ordered: plan.display.orderedSpaceIds, current: plan.currentSpaceId) else { return }
            basis = plan
            selection = state
        }
        let previous = selection?.target
        selection?.press(offset, repeated: repeated)
        if previous == selection?.target, selection?.scrubbing != true {
            if !running { selection = nil; basis = nil }
            return
        }
        lastDirection = offset
        pending = true
        guard let selection, let basis else { return }
        if selection.scrubbing {
            if !scrubSession {
                scrubSession = true
                DiagnosticLog.shared.info("SpaceScrub: begin target=\(selection.target)")
                SpaceSwitchBezel.shared.prepareTransitCover(on: WindowTiler.screen(for: basis))
            }
            present(scrubbing: true)
        } else {
            present(scrubbing: false)
            drain()
        }
    }

    /// First zoom-out opens Here. Once browsing, zoom only
    /// changes the camera; it never hands focus back or commits a destination.
    func zoom(out: Bool, point: CGPoint?, exitsAtMinimum: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        if DesktopCanvasController.shared.active {
            DesktopCanvasController.shared.returnToNormal { [weak self] in self?.zoom(out: out, point: point, exitsAtMinimum: exitsAtMinimum) }
            return
        }
        if canvas {
            // A fresh Ctrl+↓ with the whole map already in view leaves, as
            // Escape does. Nothing is chosen.
            if out, exitsAtMinimum, SpaceSwitchBezel.shared.canvasAtMinimum {
                DiagnosticLog.shared.info("SpaceScrub: canvas exit at minimum")
                cancel()
                return
            }
            _ = SpaceSwitchBezel.shared.zoomCanvas(out: out)
            return
        }
        if landing {
            if out {
                prepareLandingInput(point: point)
                landingInput?.openCanvas()
                DiagnosticLog.shared.info("SpaceScrub: queued landing canvas target=\(landingInput?.selection.target ?? 0)")
            }
            return
        }
        guard out else { return }
        // A posted Dock gesture cannot be withdrawn. Wait for its completion
        // before capturing Here, so it cannot change the real desktop behind
        // an anchor that has already opened.
        if running {
            if selection == nil {
                guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: 0, from: point),
                      let state = SpaceSwitchSelection(ordered: plan.display.orderedSpaceIds,
                                                       current: plan.display.currentSpaceId) else { return }
                basis = plan
                selection = state
            }
            prepareLandingInput(point: point)
            landingInput?.openCanvas()
            DiagnosticLog.shared.info("SpaceScrub: queued canvas until transit completes")
            return
        }
        let previous = selection?.target
        let previousDisplay = basis?.screenDisplayID
        let openingPoint = point ?? displayPoint
        guard let fresh = WindowTiler.planAdjacentSpaceSwitch(offset: 0, from: openingPoint),
              var state = SpaceSwitchSelection(ordered: fresh.display.orderedSpaceIds,
                                               current: fresh.display.currentSpaceId) else {
            cancel()
            return
        }
        guard SpaceSwitchCanvasEntry(spaceIDs: fresh.display.spaces.map(\.id),
                                     currentSpaceID: fresh.display.currentSpaceId) != nil else {
            // Leave the existing strip and its pending destination intact.
            // A full-screen Space has no honest Here representation yet.
            SpaceSwitchBezel.shared.showCanvasUnavailable(on: WindowTiler.screen(for: fresh))
            return
        }
        // Use this display's current Space, not the active Space from a
        // different display or the gesture's original plan. Preserve only the
        // visible thumbnail for the entry animation; openCanvas's choose
        // callback resets the held destination to Here before accepting input.
        let basis = WindowTiler.SpaceSwitchPlan(offset: 0, display: fresh.display,
            screenDisplayID: fresh.screenDisplayID, activeSpaceId: fresh.activeSpaceId,
            currentSpaceId: fresh.display.currentSpaceId, targetSpaceId: nil)
        if previousDisplay == basis.screenDisplayID, let previous { state.choose(previous) }
        state.hold()
        self.basis = basis
        selection = state
        pending = false
        scrubSession = true
        // Populate from the retained inventory without an intermediate zoom
        // stop. A strip that isn't up is prepared, never flashed on screen.
        present(scrubbing: false, reveal: SpaceSwitchBezel.shared.stripVisible)
        canvas = SpaceSwitchBezel.shared.openCanvas(currentSpaceID: basis.currentSpaceId,
            on: WindowTiler.screen(for: basis), choose: { [weak self] id in
                guard let self, !self.landing else { return }
                self.selection?.choose(id)
                self.pending = true
            }, land: { [weak self] in self?.landCanvas() },
            cancel: { [weak self] in self?.cancel() },
            zoom: { [weak self] out, exits in self?.zoom(out: out, point: nil, exitsAtMinimum: exits) })
        DiagnosticLog.shared.info("SpaceScrub: canvas opened=\(canvas) entry=here current=\(basis.currentSpaceId) target=\(selection?.target ?? 0)")
        if canvas {
            SpaceSwitchBezel.shared.prepareTransitCover(on: WindowTiler.screen(for: basis))
        } else {
            cancel()
        }
    }

    /// Releasing a key ends ordinary scrubbing, but never commits a chooser.
    func release(control: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        if waitingForCanvas {
            landingInput?.release()
            // If Here cannot open after transit (for example, a full-screen
            // destination), the original strip must still receive this release.
            selection?.release()
            return
        }
        if landing {
            landingInput?.release()
            return
        }
        guard selection?.scrubbing == true else { return }
        guard selection?.release(choosing: canvas) == true else {
            if control { DiagnosticLog.shared.info("SpaceScrub: release held canvas target=\(selection?.target ?? 0)") }
            return
        }
        DiagnosticLog.shared.info("SpaceScrub: release target=\(selection?.target ?? 0)")
        present(scrubbing: false)
        if pending { drain() } else if !running { settle() }
    }

    /// Navigation cannot withdraw a committed switch. Teardown may force
    /// cleanup, but ordinary cancellation must retain its landing cover.
    @discardableResult
    func cancel(force: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard force || !SpaceSwitchBezel.shared.canvasHasWindowInteraction else { return false }
        landingInput = nil
        guard force || !landing else { return false }
        canvas = false
        awaitingCover = false
        covered = false
        SpaceSwitchBezel.shared.closeCanvas(landing: false)
        SpaceSwitchBezel.shared.abortLanding()
        epoch &+= 1
        selection = nil
        basis = nil
        pending = false
        scrubSession = false
        SpaceSwitchBezel.shared.endTransitCover()
        SpaceSwitchBezel.shared.dismiss()
        // An already-posted Dock gesture cannot be withdrawn. Its completion
        // still releases `running`; epoch prevents it owning the new HUD.
        return true
    }

    func yieldForDesktopCanvas() -> Bool {
        // A Dock transit already posted cannot be cancelled. Leave its cover
        // intact and allow entry again when the desktop has actually landed.
        guard !running, !landing, !waitingForCanvas else { return false }
        return cancel()
    }

    /// From Enter until the switch reports, the canvas owns the screen. The
    /// commit was explicit and a posted Dock gesture cannot be withdrawn, so
    /// new navigation waits rather than tearing the cover off a live slide.
    private var landing: Bool {
        awaitingCover || covered
    }

    private var waitingForCanvas: Bool {
        running && landingInput?.wantsCanvas == true
    }

    private var displayPoint: CGPoint? {
        basis?.screenDisplayID.map(CGDisplayBounds).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func prepareLandingInput(point: CGPoint? = nil) {
        guard landingInput == nil, let selection else { return }
        landingInput = SpaceSwitchLandingInput(selection: selection,
            point: point ?? displayPoint)
    }

    /// Called only after the committed switch reports. Re-read the display so
    /// a failed switch or a desktop removed mid-flight cannot leave stale state.
    private func resumeLandingInput() {
        guard let input = landingInput else { return }
        landingInput = nil
        if input.wantsCanvas {
            // Here always refreshes the actual current Space after transit;
            // queued arrow destinations must not become the entry anchor.
            zoom(out: true, point: input.point)
            return
        }
        guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: 0, from: input.point),
              var next = SpaceSwitchSelection(ordered: plan.display.orderedSpaceIds, current: plan.currentSpaceId) else { return }
        next.choose(input.selection.target)
        if input.selection.scrubbing { next.hold() }
        selection = next
        basis = plan
        lastDirection = input.direction
        pending = next.target != plan.currentSpaceId
        DiagnosticLog.shared.info("SpaceScrub: resumed landing input target=\(next.target) canvas=\(input.wantsCanvas)")
        if pending || next.scrubbing {
            SpaceSwitchBezel.shared.abortLanding()
            if next.scrubbing {
                scrubSession = true
                SpaceSwitchBezel.shared.prepareTransitCover(on: WindowTiler.screen(for: plan))
            }
            present(scrubbing: next.scrubbing)
            drain()
        } else {
            selection = nil
            basis = nil
        }
    }

    private func finishLanding() {
        // Construct/order a queued replacement while the old opaque cover is
        // still retained. AppKit can stall during panel creation; revealing
        // first would expose a desktop flash before the replacement is ready.
        if landingInput?.wantsCanvas == true { resumeLandingInput() }
        SpaceSwitchBezel.shared.landingSwitchFinished()
        resumeLandingInput()
    }

    private func present(scrubbing: Bool, reveal: Bool = true) {
        guard let basis, let selection else { return }
        let target = basis.display.spaces.first(where: { $0.id == selection.target })
        SpaceLandscape.shared.dismiss()
        SpaceSwitchBezel.shared.show(direction: lastDirection,
            targetIndex: target?.index, currentIndex: basis.currentIndex,
            display: basis.display, holding: true, scrubbing: scrubbing || target == nil,
            fullscreenOrdinal: target == nil ? selection.index + 1 : nil,
            on: WindowTiler.screen(for: basis), reveal: reveal)
    }

    private func landCanvas() {
        guard canvas else { return }
        DiagnosticLog.shared.info("SpaceScrub: canvas explicit land target=\(selection?.target ?? 0)")
        canvas = false
        // The canvas carries the chosen desktop to the full display. Its
        // shade turns opaque first; only then is the switch posted, unfrozen,
        // so the canvas keeps animating while the Dock slides behind it. The
        // strip is never presented again on this path.
        awaitingCover = true
        let mine = epoch
        SpaceSwitchBezel.shared.closeCanvas(landing: true) { [weak self] in
            guard let self, mine == self.epoch, self.awaitingCover else { return }
            self.awaitingCover = false
            self.covered = true
            if self.pending { self.drain() } else if !self.running { self.settle() }
        }
        selection?.release()
    }

    /// The user confirmed the current desktop: nothing needs to move.
    private func settle() {
        covered = false
        selection = nil
        basis = nil
        scrubSession = false
        SpaceSwitchBezel.shared.endTransitCover()
        SpaceSwitchBezel.shared.finishSwitch()
        finishLanding()
    }

    private func drain() {
        guard !running, !awaitingCover, selection?.scrubbing != true, pending,
              let selection, let basis else { return }
        pending = false
        running = true
        let freeze = !covered
        let target = selection.target
        let mine = epoch
        // Mission Control selects by display geometry, independently of where
        // the pointer moves while the key is held.
        let bounds = basis.screenDisplayID.map(CGDisplayBounds)
        let point = bounds.map { CGPoint(x: $0.midX, y: $0.midY) }
        let complete: (Bool) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if !self.landing, self.landingInput?.wantsCanvas == true {
                    self.resumeLandingInput()
                    if self.canvas { return }
                }
                guard mine == self.epoch else { self.drain(); return }
                if self.selection?.scrubbing == true { return }
                // A preceding switch may finish while a newly covered landing
                // waits for this worker. Preserve its cover through the drain;
                // only the final completion for this epoch may release it.
                if self.pending { self.drain(); return }
                // A landing still turning opaque settles from its own cover
                // callback; don't finish the switch underneath it.
                if self.awaitingCover { return }
                self.covered = false
                DiagnosticLog.shared.info("SpaceScrub: settled target=\(target) landed=\(result)")
                self.selection = nil
                self.basis = nil
                self.scrubSession = false
                SpaceSwitchBezel.shared.endTransitCover()
                if result && !basis.display.spaces.contains(where: { $0.id == target }) {
                    SpaceSwitchBezel.shared.dismiss()
                } else {
                    SpaceSwitchBezel.shared.finishSwitch()
                }
                if !result { SpaceSwitchBezel.shared.settleOnCurrentSpace() }
                self.finishLanding()
            }
        }
        queue.async { [weak self] in
            guard let display = WindowTiler.getDisplaySpaces().first(where: { $0.displayId == basis.display.displayId }),
                  let from = display.orderedSpaceIds.firstIndex(of: display.currentSpaceId),
                  let to = display.orderedSpaceIds.firstIndex(of: target) else { complete(false); return }
            if from == to { complete(true); return }
            let plan = WindowTiler.SpaceSwitchPlan(offset: to - from, display: display,
                screenDisplayID: basis.screenDisplayID, activeSpaceId: display.currentSpaceId,
                currentSpaceId: display.currentSpaceId, targetSpaceId: target)
            let useMissionControl = SpaceSwitchTransit.usesDirectJump(distance: to - from, hasDisplayPoint: point != nil)
            let perform = {
                let switched = autoreleasepool {
                    WindowTiler.noteProgrammaticSwitch()
                    let started = ProcessInfo.processInfo.systemUptime
                    let result: Bool
                    if useMissionControl, let point {
                        result = WindowSpaceCarry.selectDesktop(target, on: display.displayId, at: point)
                    } else {
                        result = WindowTiler.performSpaceSwitch(plan, freeze: freeze, screenUpdatesChanged: { enabled in
                            // This is the serial switch worker. Pair the layer
                            // clocks with each actual WindowServer freeze, not
                            // the much later desktop-confirmation callback.
                            DispatchQueue.main.sync {
                                SpaceSwitchBezel.shared.setScreenUpdatesEnabled(enabled)
                            }
                        })
                    }
                    DiagnosticLog.shared.info("SpaceScrub: transit direct=\(useMissionControl) freeze=\(freeze && !useMissionControl) ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) landed=\(result)")
                    WindowTiler.noteProgrammaticSwitch()
                    return result
                }
                complete(switched)
            }
            if useMissionControl {
                // Only the direct jump opens Mission Control. Adjacent cuts
                // must never flash covers on the non-participating displays.
                DispatchQueue.main.async {
                    guard let self, mine == self.epoch, self.selection?.target == target,
                          self.selection?.scrubbing != true else { complete(false); return }
                    if !self.scrubSession {
                        self.scrubSession = true
                        SpaceSwitchBezel.shared.prepareTransitCover(on: WindowTiler.screen(for: basis))
                    }
                    SpaceSwitchBezel.shared.withTransitCover {
                        // Cover preparation is asynchronous. Do not land an old
                        // destination if the user moved on or opened the chooser.
                        guard mine == self.epoch, self.selection?.target == target,
                              self.selection?.scrubbing != true else { complete(false); return }
                        self.queue.async(execute: perform)
                    }
                }
            } else if !freeze {
                // Unfrozen is only safe while this landing still owns its
                // opaque cover. Re-check on main just before posting.
                let owned = DispatchQueue.main.sync { [weak self] () -> Bool in
                    guard let self else { return false }
                    return mine == self.epoch && self.covered && self.selection?.target == target
                }
                if owned { perform() } else { complete(false) }
            } else {
                perform()
            }
        }
    }
}
