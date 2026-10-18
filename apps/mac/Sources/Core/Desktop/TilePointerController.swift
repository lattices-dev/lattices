import AppKit
import Combine
import CoreGraphics

/// Hold Ctrl+Option and move the mouse to aim. Dead-center is cancel;
/// the rest of the center cell is maximize; outer cells are sectors.
/// Release Ctrl+Option to apply the current aim, or stay in the dead
/// zone to do nothing.
///
/// Keyboard aim (while Ctrl+Option is held):
/// - Numpad 1–9 map to the 3×3 matrix (5 = maximize)
/// - Number row 1–9 use the same matrix layout
/// - Arrow keys tile to an edge; hold two arrows for a corner (e.g. ← + ↓ = bottom-left)
/// Other keys during the hold still cancel the picker.
final class TilePointerController {
    static let shared = TilePointerController()

    private var flagsMonitor: Any?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var keyUpMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var heldArrows = Set<TilePointerKeyboard.Arrow>()
    /// True after an arrow chord set the aim; keeps that cell until modifiers release
    /// even if the arrow keys come up before Ctrl+Option.
    private var arrowAimLocked = false

    private var armed = false
    private var origin: NSPoint?
    private var aimPoint: NSPoint?
    private var currentPosition: TilePosition?
    private var currentScreen: NSScreen?
    private var pollTimer: Timer?
    private var pendingArm: DispatchWorkItem?
    private var pendingDisarm: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Loop `MouseInteractionObserver`: inner dead zone, then maximize
    /// until the ring, then 8 wedges.
    static let noActionDistance: CGFloat = 10
    static let directionalDistance: CGFloat = 50
    private static let edgePin: CGFloat = 1
    static let wedges: [TilePosition] = [
        .top, .topRight, .right, .bottomRight,
        .bottom, .bottomLeft, .left, .topLeft,
    ]

    private init() {}

    func start() {
        guard flagsMonitor == nil else { return }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event.modifierFlags)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event.modifierFlags)
            return event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }

        Preferences.shared.$ctrlOptionHoldMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard mode != .tileHUD else { return }
                self?.dismiss(apply: false)
            }
            .store(in: &subscriptions)

        DiagnosticLog.shared.info("TilePointer: Ctrl+Option mouse aiming started")
    }

    func stop() {
        for monitor in [
            flagsMonitor, mouseMonitor, keyMonitor, keyUpMonitor,
            localFlagsMonitor, localMouseMonitor, localKeyMonitor, localKeyUpMonitor,
        ] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        flagsMonitor = nil
        mouseMonitor = nil
        keyMonitor = nil
        keyUpMonitor = nil
        localFlagsMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
        localKeyUpMonitor = nil
        pendingArm?.cancel()
        pendingArm = nil
        pendingDisarm?.cancel()
        pendingDisarm = nil
        subscriptions.removeAll()
        dismiss(apply: false)
    }

    /// Keyboard chords and other Ctrl+Option hotkeys own the hold.
    var isAiming: Bool { armed }

    /// While the Ctrl+Option HUD is actively using arrow aim, defer global tiling
    /// hotkeys that share the same chord. Quick Ctrl+Option+arrow chords must still
    /// tile immediately via the registered hotkey path.
    func shouldSuppressTilingHotkey(_ action: HotkeyAction) -> Bool {
        guard armed, arrowAimLocked || !heldArrows.isEmpty else { return false }
        switch action {
        case .tileLeft, .tileRight, .tileTop, .tileBottom,
             .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
             .tileMaximize, .tileLeftThird, .tileCenterThird, .tileRightThird:
            return true
        default:
            return false
        }
    }

    func cancelApply() {
        dismiss(apply: false)
    }

    /// Returns true when the key was consumed for a keyboard tile.
    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // When another feature owns the Ctrl+Option hold, chords fall through
        // to the registered tiling hotkeys instead of committing here.
        guard Preferences.shared.ctrlOptionHoldMode == .tileHUD, !SpaceZoomInput.engaged, !WindowQuickMenu.shared.isActive else { return false }
        guard !Self.modifierKeyCodes.contains(event.keyCode) else { return false }
        guard Self.ctrlOptionHeld(event.modifierFlags) else {
            cancelApply()
            return false
        }

        if let position = TilePointerKeyboard.tilePosition(forMatrixKeyCode: event.keyCode) {
            applyKeyboardTile(to: position)
            return true
        }
        if let arrow = TilePointerKeyboard.Arrow.from(keyCode: event.keyCode) {
            // Before the HUD arms, leave Ctrl+Option+arrow to the global tiling hotkeys.
            guard armed else { return false }
            heldArrows.insert(arrow)
            updateArrowAim()
            return true
        }

        cancelApply()
        return false
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard let arrow = TilePointerKeyboard.Arrow.from(keyCode: event.keyCode) else { return }
        heldArrows.remove(arrow)
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        // A ⌃⌥ right-click's menu owns the hold until it closes.
        guard Preferences.shared.ctrlOptionHoldMode == .tileHUD, !SpaceZoomInput.engaged, !WindowQuickMenu.shared.isActive else {
            pendingArm?.cancel()
            pendingArm = nil
            if armed {
                dismiss(apply: false)
            }
            return
        }
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        // If Command or Shift is held (e.g. Hyper key chord or transition),
        // immediately abort aiming so the Hyper key is never intercepted.
        if !mods.intersection([.command, .shift]).isEmpty {
            pendingArm?.cancel()
            pendingArm = nil
            pendingDisarm?.cancel()
            pendingDisarm = nil
            if armed {
                dismiss(apply: false)
            }
            return
        }

        if !Self.ctrlOptionHeld(flags) {
            heldArrows.removeAll()
        }

        if Self.ctrlOptionHeld(flags) {
            pendingDisarm?.cancel()
            pendingDisarm = nil
            guard !armed, pendingArm == nil else { return }
            // Debounce arming briefly (30ms) so rapid modifier transitions (e.g. Hyper press)
            // do not transiently arm before Command and Shift register.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingArm = nil
                guard !SpaceZoomInput.engaged, Self.ctrlOptionHeld(NSEvent.modifierFlags), !self.armed else { return }
                DiagnosticLog.shared.info("TilePointer: arm flags=\(NSEvent.modifierFlags.rawValue)")
                self.arm()
            }
            pendingArm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
            return
        }

        pendingArm?.cancel()
        pendingArm = nil
        guard armed else { return }
        scheduleDisarm()
    }

    private func scheduleDisarm() {
        guard pendingDisarm == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDisarm = nil
            guard self.armed, !Self.ctrlOptionHeld(NSEvent.modifierFlags) else { return }
            let currentMods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasDisallowedModifiers = !currentMods.intersection([.command, .shift]).isEmpty
            let shouldApply = !hasDisallowedModifiers && self.currentPosition != nil && !WindowDragSnapController.shared.isSnapping
            DiagnosticLog.shared.info("TilePointer: disarm apply=\(shouldApply) pos=\(self.currentPosition?.rawValue ?? "nil")")
            self.dismiss(apply: shouldApply)
        }
        pendingDisarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func handleMouseMoved(_ event: NSEvent? = nil) {
        guard armed, heldArrows.isEmpty, !arrowAimLocked, !WindowDragSnapController.shared.isSnapping else { return }
        if origin == nil {
            origin = NSEvent.mouseLocation
        }
        guard let origin else { return }
        let location = resolveAimPoint(event, origin: origin)

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        currentScreen = screen
        let position = Self.position(at: location, origin: origin)
        showHUD(at: origin, position: position)
        guard position != currentPosition else { return }
        currentPosition = position
        DiagnosticLog.shared.info("TilePointer: aim \(position?.rawValue ?? "idle") on \(screen.localizedName)")
        // Move detent: tick when the aim enters a new cell. Returning to
        // dead-center stays silent so cancel reads as "null".
        if position != nil, Preferences.shared.tilePointerSoundEffectsEnabled {
            AppFeedback.shared.aimTick()
        }
        if let position {
            TileZoneOverlay.shared.show(position: position, on: screen)
        } else {
            TileZoneOverlay.shared.dismiss()
        }
    }

    private func updateArrowAim() {
        guard armed, let origin else { return }
        guard let position = TilePointerKeyboard.tilePosition(forArrows: heldArrows) else {
            return
        }
        arrowAimLocked = true

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        currentScreen = screen
        showHUD(at: origin, position: position)
        guard position != currentPosition else { return }
        currentPosition = position
        if Preferences.shared.tilePointerSoundEffectsEnabled {
            AppFeedback.shared.aimTick()
        }
        TileZoneOverlay.shared.show(position: position, on: screen)
    }

    /// When the origin sits against a display edge, macOS pins the cursor.
    /// Keep integrating event deltas past that pin so outward cells stay reachable
    /// — the same absolute-mouse compensation Loop uses on its radial menu.
    private func resolveAimPoint(_ event: NSEvent?, origin: NSPoint) -> NSPoint {
        let current = NSEvent.mouseLocation
        guard let bounds = NSScreen.screens.first(where: { $0.frame.contains(origin) })?.frame else {
            aimPoint = current
            return current
        }

        let nearEdge = abs(origin.x - bounds.minX) < Self.directionalDistance
            || abs(origin.x - bounds.maxX) < Self.directionalDistance
            || abs(origin.y - bounds.minY) < Self.directionalDistance
            || abs(origin.y - bounds.maxY) < Self.directionalDistance
        guard nearEdge else {
            aimPoint = current
            return current
        }

        guard let event else {
            return aimPoint ?? current
        }

        let atMinX = abs(current.x - bounds.minX) < Self.edgePin
        let atMaxX = abs(current.x - bounds.maxX) < Self.edgePin
        let atMinY = abs(current.y - bounds.minY) < Self.edgePin
        let atMaxY = abs(current.y - bounds.maxY) < Self.edgePin
        var resolved = current
        let last = aimPoint ?? current
        let maxOffset = Self.directionalDistance
        if atMinX || atMaxX {
            resolved.x = min(max(last.x + event.deltaX, bounds.minX - maxOffset), bounds.maxX + maxOffset)
        }
        if atMinY || atMaxY {
            resolved.y = min(max(last.y + event.deltaY, bounds.minY - maxOffset), bounds.maxY + maxOffset)
        }
        aimPoint = resolved
        return resolved
    }

    private func arm() {
        armed = true
        arrowAimLocked = false
        origin = NSEvent.mouseLocation
        aimPoint = origin
        currentPosition = nil
        currentScreen = NSScreen.screens.first(where: { $0.frame.contains(origin ?? .zero) }) ?? NSScreen.main
        startPolling()
        if let origin {
            showHUD(at: origin, position: nil)
        }
        handleMouseMoved(nil)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard self?.armed == true else { return }
            self?.handleMouseMoved(nil)
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func dismiss(apply: Bool) {
        pendingArm?.cancel()
        pendingArm = nil
        pendingDisarm?.cancel()
        pendingDisarm = nil
        pollTimer?.invalidate()
        pollTimer = nil
        let position = currentPosition
        let screen = currentScreen
        heldArrows.removeAll()
        arrowAimLocked = false
        armed = false
        origin = nil
        aimPoint = nil
        currentPosition = nil
        currentScreen = nil

        hideHUD()
        if apply, let position {
            commitTile(to: position, on: screen)
            return
        }
        TileZoneOverlay.shared.dismiss()
    }

    private func applyKeyboardTile(to position: TilePosition) {
        pendingArm?.cancel()
        pendingArm = nil
        pendingDisarm?.cancel()
        pendingDisarm = nil
        pollTimer?.invalidate()
        pollTimer = nil
        heldArrows.removeAll()
        arrowAimLocked = false
        armed = false
        origin = nil
        aimPoint = nil
        currentPosition = nil
        let screen = currentScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        currentScreen = nil
        hideHUD()
        commitTile(to: position, on: screen)
    }

    private func commitTile(to position: TilePosition, on screen: NSScreen?) {
        if Preferences.shared.tilePointerSoundEffectsEnabled {
            AppFeedback.shared.commitTactile()
        }
        if WindowMotionMode.shared.tileCurrentTarget(to: position) {
            return
        }
        TileZoneOverlay.shared.show(position: position, on: screen, autoHideAfter: 0.28)
        WindowTiler.tileFrontmostViaAX(to: position)
    }

    private var hudStyle: TilePointerHUDStyle {
        Preferences.shared.tilePointerHUDStyle
    }

    private func showHUD(at origin: NSPoint, position: TilePosition?) {
        switch hudStyle {
        case .loop:
            TilePointerMatrixHUD.shared.hide()
            TilePointerRadialHUD.shared.show(at: origin, position: position)
        case .matrix:
            TilePointerRadialHUD.shared.hide()
            TilePointerMatrixHUD.shared.show(at: origin, position: position)
        }
    }

    private func hideHUD() {
        TilePointerRadialHUD.shared.hide()
        TilePointerMatrixHUD.shared.hide()
    }

    private static func ctrlOptionHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        return mods.contains(.control)
            && mods.contains(.option)
            && mods.intersection([.command, .shift]).isEmpty
    }

    static func wedgeIndex(for position: TilePosition) -> Int? {
        wedges.firstIndex(of: position)
    }

    static func position(at point: NSPoint, origin: NSPoint) -> TilePosition? {
        switch Preferences.shared.tilePointerHUDStyle {
        case .loop:
            return loopPosition(at: point, origin: origin)
        case .matrix:
            return matrixPosition(at: point, origin: origin)
        }
    }

    /// Loop `MouseInteractionObserver.processNewMouseLocation`:
    /// `-atan2(dy, dx) + π/2` so 0° is up, then 8 wedges clockwise.
    static func loopPosition(at point: NSPoint, origin: NSPoint) -> TilePosition? {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let distance = hypot(dx, dy)
        if distance < noActionDistance { return nil }
        let ringThreshold = directionalDistance - TilePointerRadialHUD.thickness
        if distance <= ringThreshold {
            return .maximize
        }

        var degrees = (-atan2(dy, dx) + .pi / 2) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let span = 360.0 / CGFloat(wedges.count)
        let index = Int((degrees + span / 2) / span) % wedges.count
        return wedges[index]
    }

    /// Same three bands as Loop, mapped onto the matrix: inner dead zone,
    /// rest of the center cell = maximize, then unbounded 3×3 sectors.
    static func matrixPosition(at point: NSPoint, origin: NSPoint) -> TilePosition? {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let cell = TilePointerMatrixHUD.cellSize
        let half = cell / 2
        let inCenter = abs(dx) <= half && abs(dy) <= half
        if inCenter {
            if hypot(dx, dy) < cell * 0.34 { return nil }
            return .maximize
        }
        let col = dx < 0 ? 0 : 2
        let row = dy > 0 ? 0 : 2
        let onVertical = abs(dx) <= half
        let onHorizontal = abs(dy) <= half
        if onVertical { return dy > 0 ? .top : .bottom }
        if onHorizontal { return dx < 0 ? .left : .right }
        return TilePointerMatrixHUD.cells.first { $0.col == col && $0.row == row }?.position
    }
}
