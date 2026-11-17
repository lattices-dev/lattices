import AppKit
import SwiftUI
import LatticesWorkspaceCore

/// An exact launcher handoff. Resolve the entire ordered set before opening or
/// changing an arrangement; a stale target must never become a different window.
struct MotionArrangementRequest {
    let windowIDs: [UInt32]
    let displayID: CGDirectDisplayID

    func resolve(in eligible: [WindowEntry],
                 displayForWindow: (WindowEntry) -> CGDirectDisplayID?) -> [WindowEntry]? {
        guard !windowIDs.isEmpty, Set(windowIDs).count == windowIDs.count else { return nil }
        var windows: [WindowEntry] = []
        for wid in windowIDs {
            guard let window = eligible.first(where: { $0.wid == wid }),
                  DesktopModel.isPlaceableTarget(window),
                  displayForWindow(window) == displayID else { return nil }
            windows.append(window)
        }
        return windows
    }

    /// A launcher request may reuse a transaction only when every pending or
    /// already-previewed change belongs to its exact target set.
    static func canRetainChanges(for windowIDs: [UInt32],
                                 movedWindowIDs: Set<UInt32>,
                                 stagedWindowIDs: Set<UInt32>) -> Bool {
        let requested = Set(windowIDs)
        return movedWindowIDs.isSubset(of: requested) && stagedWindowIDs.isSubset(of: requested)
    }
}

// MARK: - WindowMotionMode
//
// A keyboard-driven "quick motion" mode for moving/tiling real desktop windows.
// Trigger (Hyper+Space) arms a transparent key-capturing overlay. Plain vim/
// arrow keys fling the active window into a tile; Tab points at other windows
// and Space "plucks" them into a group you can grid with G. Moves animate the
// real window with a little drift/wind-up (see RealWindowAnimator).

final class WindowMotionMode {
    static let shared = WindowMotionMode()

    enum Entry { case hyperspace, inPlace }

    struct PickOutcome {
        let status: String
        let window: WindowEntry?
        let error: String?

        static func selected(_ window: WindowEntry) -> PickOutcome {
            PickOutcome(status: "selected", window: window, error: nil)
        }

        static func cancelled() -> PickOutcome {
            PickOutcome(status: "cancelled", window: nil, error: nil)
        }

        static func unavailable(_ error: String) -> PickOutcome {
            PickOutcome(status: "unavailable", window: nil, error: error)
        }
    }

    private var panel: MotionPanel?
    private var activeEntry: Entry?
    private var lastToggle: CFTimeInterval = 0
    private var pickCompletion: ((PickOutcome) -> Void)?
    private var pickCompleted = false

    var isActive: Bool { panel != nil }

    func toggleHyperspace() {
        if panel != nil { deactivate() }
        else { toggle(entry: .inPlace) }
    }

    /// Open an arrangement with exactly these windows selected, without moving
    /// them. The launcher calls this on main after dismissing its own panel.
    /// Failure leaves an existing arrangement and its selection untouched.
    @discardableResult
    func arrangeWindows(windowIDs: [UInt32], on displayID: CGDirectDisplayID) -> Bool {
        guard Thread.isMainThread, !isPickingWindow else { return false }
        let request = MotionArrangementRequest(windowIDs: windowIDs, displayID: displayID)
        if let panel {
            DesktopModel.shared.forcePoll()
            guard let screen = Self.screen(withID: displayID),
                  let windows = request.resolve(in: eligibleWindows(), displayForWindow: Self.displayID),
                  panel.arrangeWindows(windows, on: screen) else { return false }
            activeEntry = .inPlace
            return true
        }
        return activate(entry: .inPlace, arrangement: request)
    }

    func startWindowPick(prompt: String? = nil,
                         currentWid: UInt32? = nil,
                         completion: @escaping (PickOutcome) -> Void) {
        DispatchQueue.main.async {
            guard self.pickCompletion == nil else {
                completion(.unavailable("window pick already active"))
                return
            }
            if self.isActive { self.deactivate() }
            self.pickCompletion = completion
            self.pickCompleted = false
            self.activate(entry: .hyperspace,
                          selectionPrompt: prompt,
                          selectionCurrentWid: currentWid)
        }
    }

    private var isPickingWindow: Bool { pickCompletion != nil }

    private func finishWindowPick(_ outcome: PickOutcome) {
        guard let completion = pickCompletion, !pickCompleted else { return }
        pickCompleted = true
        pickCompletion = nil
        completion(outcome)
    }

    private func toggle(entry: Entry) {
        // Debounce machine-gun re-fire. The Hyper trigger rides the Caps Lock
        // transport remap, which can flicker active/inactive and fire the hotkey
        // several times in a few ms — racing activate against deactivate. A human
        // toggle is never this fast, so swallow anything inside the window.
        let now = CACurrentMediaTime()
        if now - lastToggle < 0.18 { return }
        lastToggle = now
        if isActive {
            if activeEntry == entry { deactivate() }
            else { show(entry: entry) }
        } else {
            activate(entry: entry)
        }
    }

    /// A different entrance changes the presentation of the current transaction.
    /// Keep its ordered picks, staged intents, original frames and z-order alive.
    private func show(entry: Entry) {
        guard !isPickingWindow, let panel,
              panel.showPresentation(inPlace: entry == .inPlace) else {
            NSSound.beep()
            return
        }
        activeEntry = entry
    }

    fileprivate func showHyperspace() { show(entry: .hyperspace) }
    fileprivate func showDesktop() { show(entry: .inPlace) }

    private func eligibleWindows() -> [WindowEntry] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        return DesktopModel.shared.allWindows()
            .filter { $0.pid != myPid && $0.isOnScreen && (isPickingWindow || !$0.title.isEmpty) }
            .filter { !($0.app == "ChatGPT Computer Use" && $0.title == "Software Cursor") }
            .sorted { $0.zIndex < $1.zIndex }
    }

    private static func screen(withID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func displayID(for window: WindowEntry) -> CGDirectDisplayID? {
        let screen = WindowTiler.screenForWindowFrame(window.frame)
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @discardableResult
    private func activate(entry: Entry = .hyperspace,
                          selectionPrompt: String? = nil,
                          selectionCurrentWid: UInt32? = nil,
                          arrangement: MotionArrangementRequest? = nil) -> Bool {
        guard panel == nil else { return false }
        let t0 = CACurrentMediaTime()
        DesktopModel.shared.forcePoll()
        let tPoll = CACurrentMediaTime()
        // Eligible = real app windows (never our own), frontmost first.
        let eligible = eligibleWindows()
        guard !eligible.isEmpty else {
            DiagnosticLog.shared.warn("MotionMode: no eligible app window to act on")
            NSSound.beep()
            if isPickingWindow { finishWindowPick(.unavailable("no eligible app window to pick")) }
            return false
        }
        var initialSelection: [UInt32] = []
        var initialScreen: NSScreen?
        if let arrangement {
            guard let screen = Self.screen(withID: arrangement.displayID),
                  let windows = arrangement.resolve(in: eligible, displayForWindow: Self.displayID) else { return false }
            initialSelection = windows.map(\.wid)
            initialScreen = screen
        }
        // Clear orphaned overlays only after validating the complete handoff.
        CommandModeWindow.shared.dismiss()
        UnifiedCommandBarWindow.shared.dismiss()
        MotionPanel.teardownStrayPanels()
        let tEligible = CACurrentMediaTime()
        let inPlace = entry == .inPlace
        let selectingWindow = isPickingWindow
        AppFeedback.shared.warmUp()
        let p = MotionPanel(eligible: eligible,
                            inPlace: inPlace,
                            selectionPrompt: selectionPrompt,
                            selectionCurrentWid: selectionCurrentWid,
                            initialSelection: initialSelection,
                            initialScreen: initialScreen)
        p.loadStart = t0
        p.beginLoadTrace()
        let tInit = CACurrentMediaTime()
        if selectingWindow {
            p.onSelection = { [weak self] entry in
                self?.finishWindowPick(.selected(entry))
                self?.deactivate()
            }
        }
        p.onExit = { [weak self] in
            guard let self else { return }
            if selectingWindow { self.finishWindowPick(.cancelled()) }
            self.deactivate()
        }
        panel = p
        activeEntry = entry
        p.present()
        let tUp = CACurrentMediaTime()
        let tag = inPlace ? "In-place" : "Hyperspace"
        // Time-to-load profile (the async capture + first-paint marks land later,
        // logged from the panel). Read it back from ~/.lattices/lattices.log.
        DiagnosticLog.shared.info(String(
            format: "%@ load — poll %.1f · build %.1f · init %.1f · present+expose %.1f · on-screen %.1fms (from trigger)",
            tag,
            (tPoll - t0) * 1000, (tEligible - tPoll) * 1000, (tInit - tEligible) * 1000,
            (tUp - tInit) * 1000, (tUp - t0) * 1000))
        return true
    }

    func deactivate() {
        panel?.dismiss()
        panel = nil
        activeEntry = nil
        if pickCompletion != nil { finishWindowPick(.cancelled()) }
        // Belt-and-suspenders: sweep up any Hyperspace overlay panel still on screen
        // even if we lost the reference to it. Guarantees the toggle hotkey always
        // clears the spread — the recovery path for the "stuck on top" trap.
        MotionPanel.teardownStrayPanels()
    }

    /// Ctrl+Option tiling while Hyperspace is open. Lattices is
    /// frontmost in that mode, so the global tile hotkeys would otherwise no-op.
    /// Returns true when the overlay consumed the chord.
    @discardableResult
    func tileCurrentTarget(to position: TilePosition) -> Bool {
        panel?.tileCurrentTarget(to: position) ?? false
    }
}

// MARK: - Motion key mapping

private enum MotionSide { case left, right, top, bottom }

private enum MotionKeys {
    static func side(_ code: UInt16) -> MotionSide? {
        switch code {
        case 4, 123:  return .left
        case 37, 124: return .right
        case 40, 126: return .top
        case 38, 125: return .bottom
        default:      return nil
        }
    }

    static func special(_ code: UInt16) -> TilePosition? {
        switch code {
        case 16:    return .topLeft     // y
        case 32:    return .topRight    // u
        case 11:    return .bottomLeft  // b
        case 45:    return .bottomRight // n
        case 8:     return .center      // c
        default:    return nil
        }
    }

    static func arrow(_ code: UInt16) -> CGVector? {
        switch code {
        case 123: return CGVector(dx: -1, dy: 0)
        case 124: return CGVector(dx: 1, dy: 0)
        case 126: return CGVector(dx: 0, dy: -1)
        case 125: return CGVector(dx: 0, dy: 1)
        default:  return nil
        }
    }
}

private final class HyperspaceScreenPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .readOnly
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Full-screen overlay host. SwiftUI marks empty regions with allowsHitTesting(false)
/// so super.hitTest returns nil and clicks reach the desktop; gesture-backed HUD
/// targets resolve to self and must be kept (the old `self → nil` pass-through broke taps).
/// In-place mode also captures clicks over live window frames (see InPlaceHostingView).
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }
}

/// Hyper+G overlay: HUD regions stay SwiftUI-tappable; clicks on real desktop windows
/// are captured here (local monitors never see them — they go to the app underneath).
private final class InPlaceHostingView<Content: View>: NSHostingView<Content> {
    weak var panel: MotionPanel?
    var screen: NSScreen?
    private var pointerTrackingArea: NSTrackingArea?
    private var lastHoverSample: TimeInterval = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The open Grid, Layers, or Map card sits in front of the windows
        // underneath it. A click there must not start a desktop drag.
        if let panel, let screen, panel.toolChromeContains(point, in: self, on: screen) {
            return super.hitTest(point) ?? self
        }
        // The unified desktop is an AppKit gesture surface. A transparent
        // SwiftUI descendant can still win hit-testing and swallow the drag.
        if let panel, let screen, panel.ownsDesktopPointer,
           panel.inPlaceCapturesDesktopClick(at: point, in: self, on: screen) { return self }
        if let hit = super.hitTest(point) { return hit }
        guard let panel, let screen else { return nil }
        // Swallow clicks on chrome padding that SwiftUI doesn't paint — never fall through
        // to live-window selection when the user meant to hit the HUD.
        if panel.inPlaceChromeBlocksClick(at: point, in: self, on: screen) { return self }
        guard panel.inPlaceCapturesDesktopClick(at: point, in: self, on: screen) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let panel, let screen else {
            super.mouseDown(with: event)
            return
        }
        if panel.inPlaceChromeBlocksClick(at: local, in: self, on: screen) { return }
        if panel.toolChromeContains(local, in: self, on: screen) {
            super.mouseDown(with: event)
            return
        }
        if panel.inPlaceCapturesDesktopClick(at: local, in: self, on: screen) {
            panel.beginDesktopGesture(at: local, in: self, on: screen)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.moveDesktopGesture(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.endDesktopGesture()
    }

    override func mouseMoved(with event: NSEvent) {
        // CG window hit-testing is deliberately sampled rather than run at the
        // display refresh rate. The affordance only needs to follow window changes.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHoverSample >= 0.08 else { return }
        lastHoverSample = now

        let local = convert(event.locationInWindow, from: nil)
        guard panel?.ownsDesktopPointer == true || super.hitTest(local) == nil else {
            panel?.clearInPlaceDesktopHover()
            return
        }
        guard let panel, let screen else { return }
        panel.performInPlaceDesktopHover(at: local, in: self, on: screen)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        panel?.clearInPlaceDesktopHover()
        super.mouseExited(with: event)
    }
}

// MARK: - Expose canvas (zoom/pan)
//
// Ephemeral navigation state for the screenshot survey: a pure view transform over
// the already-laid-out lattice — no reflow, no real windows move. Owned by the panel
// (so it survives the frequent ExposeView rebuilds) and observed by ExposeView, which
// applies it as a scaleEffect + offset. Separate axis from the persisted "size" dial:
// size changes how big tiles are laid out; this magnifies whatever is laid out.
final class ExposeCanvas: ObservableObject {
    @Published var zoom: CGFloat = 1     // 1 = fit (floor). Pan only matters when > 1.
    @Published var pan: CGSize = .zero   // points, in SwiftUI offset space (+x right, +y down)
    @Published var tool: HyperspaceTool?
    let minZoom: CGFloat = 1.0
    let maxZoom: CGFloat = 4.0

    func reset() { zoom = 1; pan = .zero }
}

// MARK: - Drag & drop "intent layer" (design/hyperspace-drag-drop.md)

/// Resolution of the Lattice drop grid. Each step is a plain CxR grid you drop a
/// window onto; the cell maps straight to `PlacementSpec.grid`. Default is quarters;
/// modifiers (⇧ halves · ⌥ thirds · ⌘ fine · ⌃ dense) override the selector while held.
enum LatticeRes: Int, CaseIterable {
    case halves, thirds, quarters, fine, dense

    var dims: (cols: Int, rows: Int) {
        switch self {
        case .halves:   return (2, 1)
        case .thirds:   return (3, 1)
        case .quarters: return (2, 2)
        case .fine:     return (4, 4)
        case .dense:    return (8, 8)
        }
    }
    var glyph: String {
        switch self {
        case .halves:   return "½"
        case .thirds:   return "⅓"
        case .quarters: return "¼"
        case .fine:     return "▦"
        case .dense:    return "⊞"
        }
    }
    var name: String {
        switch self {
        case .halves:   return "halves"
        case .thirds:   return "thirds"
        case .quarters: return "quarters"
        case .fine:     return "fine"
        case .dense:    return "dense"
        }
    }
    /// Map a grid's dims back to its selector glyph (for staged badges).
    static func glyph(cols: Int, rows: Int) -> String {
        LatticeRes.allCases.first { $0.dims == (cols, rows) }?.glyph ?? "▦"
    }
}

/// A cell coordinate in the lattice grid (0-indexed, top-left origin) — matches
/// `GridPlacement(column:row:)`.
struct HoverCell: Equatable { let col: Int; let row: Int }

/// The screen region a grid click stands for. One window keeps the cell.
/// Several windows take the side the click is on, so the right column is the
/// right half and the windows share it.
struct GridSpan: Equatable {
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
    func contains(col: Int, row: Int) -> Bool {
        col >= self.col && col < self.col + cols && row >= self.row && row < self.row + rows
    }
}

func gridClickSpan(col: Int, row: Int, cols: Int, rows: Int, count: Int) -> GridSpan {
    guard cols > 0, rows > 0 else { return GridSpan(col: 0, row: 0, cols: 1, rows: 1) }
    let col = min(max(0, col), cols - 1)
    let row = min(max(0, row), rows - 1)
    if count <= 1 { return GridSpan(col: col, row: row, cols: 1, rows: 1) }
    let fx = (CGFloat(col) + 0.5) / CGFloat(cols)
    let fy = (CGFloat(row) + 0.5) / CGFloat(rows)
    if fx <= 0.34 {
        let width = max(1, Int((CGFloat(cols) * 0.5).rounded()))
        return GridSpan(col: 0, row: 0, cols: width, rows: rows)
    }
    if fx >= 0.66 {
        let width = max(1, Int((CGFloat(cols) * 0.5).rounded()))
        return GridSpan(col: cols - width, row: 0, cols: width, rows: rows)
    }
    if fy <= 0.34 {
        let height = max(1, Int((CGFloat(rows) * 0.5).rounded()))
        return GridSpan(col: 0, row: 0, cols: cols, rows: height)
    }
    if fy >= 0.66 {
        let height = max(1, Int((CGFloat(rows) * 0.5).rounded()))
        return GridSpan(col: 0, row: rows - height, cols: cols, rows: height)
    }
    return GridSpan(col: col, row: row, cols: 1, rows: 1)
}

func gridSpanTitle(_ span: GridSpan, cols: Int, rows: Int) -> String {
    if span.cols == cols, span.rows == rows { return "Fill display" }
    if span.rows == rows, span.col == 0, span.cols * 2 == cols { return "Left half" }
    if span.rows == rows, span.col + span.cols == cols, span.cols * 2 == cols { return "Right half" }
    if span.cols == cols, span.row == 0, span.rows * 2 == rows { return "Top half" }
    if span.cols == cols, span.row + span.rows == rows, span.rows * 2 == rows { return "Bottom half" }
    if span.rows == rows, span.col + span.cols == cols { return "Right side" }
    if span.rows == rows, span.col == 0 { return "Left side" }
    if span.cols == cols, span.row == 0 { return "Top side" }
    if span.cols == cols, span.row + span.rows == rows { return "Bottom side" }
    return "Grid"
}

/// Balanced cell assignments within a lattice grid, anchored at the drop cell.
/// Short final rows are centered within the explicitly chosen drop lattice.
private func balancedGridCells(count: Int, latticeCols: Int, latticeRows: Int,
                               anchorCol: Int, anchorRow: Int) -> [(col: Int, row: Int)]? {
    guard count > 0 else { return [] }
    let subCols = max(1, Int(ceil(Double(count).squareRoot())))
    let subRows = max(1, Int(ceil(Double(count) / Double(subCols))))
    guard anchorCol + subCols <= latticeCols, anchorRow + subRows <= latticeRows else { return nil }
    return (0..<count).map { i in
        let r = i / subCols, c = i % subCols
        let itemsInRow = min(subCols, count - r * subCols)
        let xOffset = (subCols - itemsInRow) / 2
        return (col: anchorCol + xOffset + c, row: anchorRow + r)
    }
}

/// Ephemeral drag state for the intent layer. Owned by `MotionPanel` (so it
/// survives the frequent ExposeView rebuilds) and observed by every screen's
/// ExposeView. The drag is scoped to one screen via `screenID`; only that screen
/// renders the ghost and accepts a drop. Nothing real moves here — a drop only
/// stages a destination (committed later on gather).
final class HyperspaceDrag: ObservableObject {
    @Published var wid: UInt32?              // window being dragged (nil = idle/tap-only)
    @Published var image: NSImage?           // ghost thumbnail following the cursor
    @Published var tileSize: CGSize = .zero
    @Published var location: CGPoint = .zero // cursor, in ExposeView's root space
    @Published var res: LatticeRes = .quarters   // effective resolution (modifier ?? base)
    @Published var baseRes: LatticeRes = .quarters // selector choice; modifiers override live
    @Published var hoverCell: HoverCell?     // cell under the cursor in the lattice grid
    @Published var hoverCurrentView = false  // cursor over the Current View screen-map
    @Published var hoverLayoutWid: UInt32?   // outline under the cursor in Current View
    @Published var hoverSurveyWid: UInt32?   // survey tile under the cursor — links to Current View
    @Published var hoverGrid = false         // cursor over the Grid drop zone mid-drag
    @Published var inspectCurrentView = false // plain hover on Current View (no drag)
    var ghostTint: Color?                    // tinted ghost when dragging an outline without a thumb
    @Published var hoverLayer: String?       // layer pile under the cursor (layer id, or newLayerKey)
    @Published var hoverLayoutTitle: String? // layout card under the cursor (plan title)
    @Published var landingTarget: UInt32?    // proposal slot the dragged window would swap into
    @Published var placementPreview: HyperspaceLayoutPlan?
    var placementAnchor: CGPoint?
    @Published var inspectLayer: String?     // pile under a plain mouse hover (no drag) — reveals its roster
    @Published var inspectScreen: String?    // which screen that hovered pile is on
    @Published var selectedLayer: String?    // layer pile clicked open → the inspector modal (layer id)
    @Published var screenID: String = ""     // which screen owns the in-flight drag
    /// Where the in-flight drag started — survey tile vs Current View outline.
    var dragSource: DragSource?
    /// Full selection when dragging a picked window (2+); otherwise just the one window.
    var dragWids: [UInt32] = []

    enum DragSource { case survey, currentView }

    // Right-click "place me" mode: a tile was secondary-clicked, opening a life-size
    // interactive stage to pick its grid spot (mouse-only alternative to drag → Grid).
    @Published var placeWid: UInt32?         // window in placement mode (nil = off)
    @Published var placeScreen: String?      // which screen its stage shows on
    @Published var placeCell: HoverCell?     // cell under the cursor on the stage
    var isPlacing: Bool { placeWid != nil }
    func beginPlacing(_ wid: UInt32, on screen: String) { placeWid = wid; placeScreen = screen; placeCell = nil }
    func endPlacing() { placeWid = nil; placeScreen = nil; placeCell = nil }

    var latticeFrames: [String: CGRect] = [:]              // per-screen lattice grid frame (root space)
    var toolFrames: [String: CGRect] = [:]                // the open Layers / Grid / Map card
    var currentViewFrames: [String: CGRect] = [:]          // per-screen Current View canvas frame (root space)
    var layerFrames: [String: [String: CGRect]] = [:]      // [screenID: [layerKey: frame]] (root space)
    var layoutCardFrames: [String: [String: CGRect]] = [:] // [screenID: [plan title: frame]] (root space)
    var proposalCanvas: [String: CGRect] = [:]             // per-screen proposal stage (root space)

    static let newLayerKey = "+new"          // sentinel for the ＋ "new layer" pile

    // A one-shot "landing" beat fired at the drop target the instant you release, so a
    // drop reads as confirmed even though the target's hover highlight has cleared.
    struct DropPulse: Equatable { let id: Int; let frame: CGRect }
    @Published var dropPulse: DropPulse?
    private var pulseCounter = 0

    var isActive: Bool { wid != nil }

    func reset() {
        wid = nil
        dragWids = []
        image = nil
        dragSource = nil
        hoverCell = nil
        hoverCurrentView = false
        hoverLayoutWid = nil
        hoverSurveyWid = nil
        hoverGrid = false
        ghostTint = nil
        inspectCurrentView = false
        hoverLayer = nil
        hoverLayoutTitle = nil
        landingTarget = nil
        placementPreview = nil
        placementAnchor = nil
    }

    /// Flash a ring at `frame` (root space) and auto-clear it after the beat. Tokened
    /// so each drop restarts the animation even on the same target.
    func firePulse(at frame: CGRect) {
        guard frame.width > 1 else { return }
        pulseCounter += 1
        let id = pulseCounter
        dropPulse = DropPulse(id: id, frame: frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            if self?.dropPulse?.id == id { self?.dropPulse = nil }
        }
    }
}

// MARK: - MotionPanel

private final class MotionPanel: NSPanel {
    var onExit: (() -> Void)?
    var onSelection: ((WindowEntry) -> Void)?
    var loadStart: CFTimeInterval = 0          // set by activate(); base for load-profile marks
    private var loadTrace: HyperspaceLoadTrace?

    private var firstPaintAt: CFTimeInterval = 0
    private var capturesAt: CFTimeInterval = 0
    private var captureCount = 0

    func beginLoadTrace() {
        guard loadStart > 0 else { return }
        loadTrace = HyperspaceLoadTrace(origin: loadStart)
        loadTrace?.mark("trace.start")
    }

    private let eligible: [WindowEntry]
    private var reticle = 0                          // index of the active window
    private var fillAimWid: UInt32?                  // last click/Tab aim — F fills this window
    private var group: Set<UInt32> { selection.members(on: activeSelectionScreenID) }
    private var resolved: [UInt32: AXUIElement] = [:]
    private var animators: [UInt32: RealWindowAnimator] = [:]
    private var borderLayers: [CALayer] = []
    private var originalFrames: [UInt32: CGRect] = [:]   // for Esc-undo
    private var exposed = false                          // Exposé spread is laid out
    private var dismissed = false                        // torn down — any late async work must no-op
    private var presentationGeneration: UInt = 0         // invalidate callbacks from replaced hosts

    private var lastSide: MotionSide?
    private var cycleStep = 0
    private var ignoreResign = false        // swallow the transient key-resign while raising windows
    private var didMoveWindows = false       // did we move/raise any real window? (gates the Esc restore)
    /// A change the user meant and saw land (an applied layout, fill, swap or
    /// tabs). Once there is one, Esc keeps it and leaves; ⌘Z, `:q` and the
    /// ⋯ menu's Restore still go back.
    private var keptChange = false
    private let exposeGap: CGFloat = 0.012  // gutter between cells in the Exposé spread
    private let nudgeStep: CGFloat = 60
    private let resizeStep: CGFloat = 60

    private var legendHost: NSHostingView<MotionLegend>?
    private var stackHost: NSHostingView<MotionStack>?
    private var chromeHost: NSView?                       // bottom layer-host for window borders/previews
    private var thumbs: [UInt32: NSImage] = [:]          // cached window snapshots
    private var captureFrame: [UInt32: CGRect] = [:]     // the frame each capture was taken at
    private var thumbInFlight: Set<UInt32> = []          // de-dupe in-flight captures
    private let stackMargin: CGFloat = 24
    private var keyObserver: Any?
    private var layoutRefreshTimer: Timer?   // keep Current View frames live while surveying
    private var layoutFingerprintByScreen: [String: Int] = [:]
    private var captureRebuildWorkItemsByScreenID: [String: DispatchWorkItem] = [:]
    /// In-place tools (Hyper+G): float Current View + inventory over the live desktop.
    /// Hyperspace (Hyper+Space) keeps the full scrim + screenshot survey.
    private var inPlaceMode: Bool
    private let selectionPrompt: String?
    private let selectionCurrentWid: UInt32?
    private var scrollMonitor: Any?
    private var mouseUpMonitor: Any?    // re-claims key focus after a survey click/drag
    private var keyMonitor: Any?        // catches Enter/Esc even when a survey panel holds key
    private var newLayerPanel: NewLayerPanel?   // the "create a new layer" authoring flow, when open
    private var rulePanel: LayerRulePanel?       // the "add/edit layer rule" flow, when open
    private var commandPanel: HyperspaceCommandPanel?   // the `/` command bar, when open

    // One authority for every display's picks. Active membership and slot order
    // are read-only views, so switching or clearing another display cannot drift.
    private var selection = MotionSelectionState()
    private var pickOrder: [UInt32] { selection.order(on: activeSelectionScreenID) }
    private var pickOrderByScreen: [String: [UInt32]] { selection.ordersByDisplay }

    // Drag & drop "intent layer" (design/hyperspace-drag-drop.md). Each window can
    // be staged across three orthogonal axes; nothing real moves until the gather
    // commit. Populated by the drag UI (Phase 1+); committed only on confirmation.
    struct StagedIntent {
        var layers: Set<String> = []        // ⌘⌥ layer ids — multi-membership (Phase 2)
        var newLayer: Bool = false          // stage a fresh layer seeded from this window (＋ pile)
        var location: PlacementSpec?         // where on the active screen (Phase 1)
        var space: Int?                      // target macOS Space (Phase 3)
        var isEmpty: Bool { layers.isEmpty && !newLayer && location == nil && space == nil }
    }
    private var stagedIntents: [UInt32: StagedIntent] = [:]

    // Live drag state for the intent layer — owned here so it outlives the frequent
    // ExposeView rebuilds, observed by every screen's spread.
    private let dragModel = HyperspaceDrag()

    // Screenshot Exposé: real windows never move during the survey. We render a
    // clustered lattice of live captures and pluck by home-row hint key; only the
    // gather (⏎ / G) moves real windows.
    private var exposeHost: NSHostingView<ExposeView>?
    private var exposeHostsByScreenID: [String: NSHostingView<ExposeView>] = [:]
    private var exposePanelsByScreenID: [String: HyperspaceScreenPanel] = [:]
    private var desktopDimByScreenID: [String: HyperspaceDimView] = [:]
    private var canvasByScreenID: [String: ExposeCanvas] = [:]
    private var activeScreenID: String?
    private var exposeClustersByScreen: [String: [ExposeCluster]] = [:]
    private var exposeOrderByScreen: [String: [UInt32]] = [:]
    private var exposeAimByScreen: [String: Int] = [:]
    private var hintForByScreen: [String: [UInt32: String]] = [:]
    private var hintMapByScreen: [String: [String: UInt32]] = [:]
    private var clusterHintForByScreen: [String: [Int: String]] = [:]
    private var clusterHintMapByScreen: [String: [String: Int]] = [:]
    private var exposeTileWByScreen: [String: CGFloat] = [:]
    private var exposeFramesByScreen: [String: [UInt32: CGRect]] = [:]
    private var desktopHUD: HyperspaceDesktopHUD?
    private let layoutPreview = WindowHoverPreview(level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 6))
    private let dividerHandles = HyperspaceDividerHandles()
    private var pendingLayout: HyperspaceLayoutPlan?
    /// The landing drawn ahead of the pointer while a free drag is still short of it.
    private var landingCue: String?
    /// True once a drag has been released. The overlay fills in and waits for Apply.
    private var layoutLocked = false
    /// Styles for the bunch on the overview screen. A tap advances the index.
    private var layoutCycle: [HyperspaceLayoutPlan] = []
    private var layoutCycleIndex = 0
    private var layoutHistory: [[UInt32: CGRect]] = []
    private var layoutNotice: String?
    private var layoutApplying = false
    private var keyboardBrowsing = false
    fileprivate var ownsDesktopPointer: Bool { !selectionOnly && inPlaceMode && !dragModel.isPlacing }
    private struct DesktopGesture {
        let wid: UInt32?
        /// The dragged window alone, or the whole selection when that window is part of it.
        let ids: [UInt32]
        let original: CGRect
        let originals: [UInt32: CGRect]
        let start: CGPoint
        let screen: NSScreen
        let divider: HyperspaceLayoutPlanner.Divider?
        let neighbors: [(UInt32, CGRect)]
        var at: CGPoint
        var moved = false
    }
    private var desktopGesture: DesktopGesture?
    private var inPlaceHoverWid: UInt32?
    /// The top island per display; it also carries the `:` command line.
    private var selectionFrameByScreenID: [String: HyperspaceSelectionFrame] = [:]
    private var commandLineState: CommandLineState?
    /// Overview in place: every real window carries an outline and its pick key.
    private var overviewMarks = false
    private var clusterSearchQueryByScreen: [String: [Int: String]] = [:]
    private var activeClusterSearchByScreen: [String: Int] = [:]
    private var exposeClusters: [ExposeCluster] = []      // structural clusters for the spread
    private var exposeOrder: [UInt32] = []                // wids in spread layout order
    private var exposeAim = 0                             // highlighted tile (Tab/Space fallback)
    private var hintFor: [UInt32: String] = [:]          // wid → home-row hint letter
    private var hintMap: [String: UInt32] = [:]          // hint letter → wid
    private var clusterHintFor: [Int: String] = [:]      // cluster id → ⇧-letter (display, uppercase)
    private var clusterHintMap: [String: Int] = [:]      // letter → cluster id (⇧+letter plucks the group)
    private var exposeTileW: CGFloat = 240
    private var clusterRules: [ClusterRule] = []
    private var exposeFrames: [UInt32: CGRect] = [:]   // tile wid → laid-out frame (survey space)
    private lazy var handKeysMode = UserDefaults.standard.bool(forKey: "hyperspace.handKeys")

    private var selectionOnly: Bool { onSelection != nil }
    private var activeEntry: WindowEntry { eligible[reticle] }
    private var activeSurveyScreen: NSScreen? {
        if let activeScreenID,
           let screen = NSScreen.screens.first(where: { MotionPanel.screenID($0) == activeScreenID }) {
            return screen
        }
        return screen(for: activeEntry)
    }

    /// Follow the effective survey display if the remembered display disconnects.
    /// Preserve the remembered/empty scope when no screen can be resolved.
    private var activeSelectionScreenID: String {
        activeSurveyScreen.map(MotionPanel.screenID) ?? activeScreenID ?? ""
    }

    private var activeSurveyMembers: [WindowEntry] {
        guard let screen = activeSurveyScreen else { return [] }
        return eligible.filter { entry($0, isOn: screen) }
    }

    init(eligible: [WindowEntry],
         inPlace: Bool = false,
         selectionPrompt: String? = nil,
         selectionCurrentWid: UInt32? = nil,
         initialSelection: [UInt32] = [],
         initialScreen: NSScreen? = nil) {
        self.eligible = eligible
        self.inPlaceMode = inPlace
        self.selectionPrompt = selectionPrompt
        self.selectionCurrentWid = selectionCurrentWid

        let union = MotionPanel.screensUnion()
        super.init(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .readOnly
        ignoresMouseEvents = false   // capture clicks so you can pluck windows by clicking
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: union.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        contentView = host

        // Window borders/previews draw into this dedicated bottom container so they
        // can never stack above the chrome (instruction strip + minimap), which are
        // added as subviews on top of it.
        let chrome = NSView(frame: NSRect(origin: .zero, size: union.size))
        chrome.wantsLayer = true
        chrome.layer?.masksToBounds = false
        chrome.autoresizingMask = [.width, .height]
        host.addSubview(chrome)
        chromeHost = chrome

        clusterRules = MotionPanel.loadClusterRules()
        seedActiveFromFocus()
        activeScreenID = activeSurveyScreen.map(MotionPanel.screenID)
        if let initialScreen, !initialSelection.isEmpty {
            seedArrangementSelection(initialSelection, on: initialScreen)
        }
        installLegend(on: host)
        installStack(on: host)
        refreshBorders()
        updateStack()
    }

    /// Align the initial active window to the frontmost app's *focused* AX
    /// window — the one the user is actually in — and cache that exact element.
    /// This avoids relying on CGWindowID→AX mapping (unreliable for Chrome etc.).
    private func seedActiveFromFocus() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var wref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &wref) == .success,
              let value = wref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let focused = value as! AXUIElement
        guard let ff = RealWindowAnimator.axFrame(focused) else { return }

        // Point the reticle at the eligible entry whose frame matches the
        // focused window, and pin the resolved element so we act on exactly it.
        var bestIdx: Int?
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for (i, e) in eligible.enumerated() where e.pid == pid {
            let ef = CGRect(x: e.frame.x, y: e.frame.y, width: e.frame.w, height: e.frame.h)
            let d = abs(ef.minX - ff.minX) + abs(ef.minY - ff.minY)
                + abs(ef.width - ff.width) + abs(ef.height - ff.height)
            if d < bestDelta { bestDelta = d; bestIdx = i }
        }
        if let bestIdx, bestDelta < 80 {
            reticle = bestIdx
            fillAimWid = eligible[bestIdx].wid
            resolved[eligible[bestIdx].wid] = focused
        }
        if let selectionCurrentWid,
           let idx = eligible.firstIndex(where: { $0.wid == selectionCurrentWid }) {
            reticle = idx
            fillAimWid = selectionCurrentWid
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A modal editor or active drag owns its input until it finishes. Changing
    /// presentation must not discard its draft or interrupt a drop callback.
    private var canChangePresentation: Bool {
        !dismissed && !selectionOnly && !dragModel.isActive && desktopGesture == nil && !layoutApplying &&
            newLayerPanel == nil && rulePanel == nil && commandPanel == nil
    }

    /// Reuse this session for an exact launcher selection. The caller has already
    /// validated a fresh desktop snapshot; also require the same captured process
    /// identities and display membership before mutating any session state.
    func arrangeWindows(_ windows: [WindowEntry], on screen: NSScreen) -> Bool {
        guard canChangePresentation, !windows.isEmpty,
              MotionArrangementRequest.canRetainChanges(
                  for: windows.map(\.wid),
                  movedWindowIDs: Set(originalFrames.keys),
                  stagedWindowIDs: Set(stagedIntents.compactMap { $0.value.isEmpty ? nil : $0.key })),
              windows.allSatisfy({ requested in
                  eligible.contains { original in
                      original.wid == requested.wid && original.pid == requested.pid && self.entry(original, isOn: screen)
                  }
              }) else { return false }
        seedArrangementSelection(windows.map(\.wid), on: screen)
        return showPresentation(inPlace: true)
    }

    private func seedArrangementSelection(_ windowIDs: [UInt32], on screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        selection.clear(on: id)
        selection.append(windowIDs, on: id)
        activeScreenID = id
        if let first = windowIDs.first, let index = eligible.firstIndex(where: { $0.wid == first }) {
            reticle = index
            fillAimWid = first
        }
    }

    /// Replace only the presentation hosts. The panel remains the transaction
    /// owner, including restoration frames, pick order, and pending placements.
    @discardableResult
    func showPresentation(inPlace: Bool) -> Bool {
        guard canChangePresentation else { return false }
        ignoreResign = true
        stopLayoutRefresh()
        cancelCaptureRebuilds()
        presentationGeneration &+= 1
        thumbInFlight.removeAll()
        inPlaceMode = inPlace
        inPlaceHoverWid = nil
        overviewMarks = false
        WindowSelectionOverlay.shared.clear()
        dragModel.reset()
        dragModel.endPlacing()
        dragModel.selectedLayer = nil
        dragModel.inspectLayer = nil
        dragModel.inspectScreen = nil

        if exposed {
            ignoresMouseEvents = !inPlaceMode
            for screen in surveyScreens() {
                // The mode changes the available survey area. Keep aim/picks,
                // but recompute tile sizes before creating the right host class.
                rebuildSurveyState(for: screen)
            }
            if let screen = activeSurveyScreen { syncActiveSurveyState(from: screen) }
            installExposeHosts()
            if !inPlaceMode { surveyScreens().flatMap { surveyMembers(on: $0) }.forEach { captureThumb(for: $0) } }
            rebuildExposeView()
            startLayoutRefresh()
        } else {
            expose()
        }
        updateLegend()
        refreshBorders()
        updateStack()
        makeKeyAndOrderFront(nil)
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.dismissed, self.presentationGeneration == generation,
                  self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil else { return }
            self.makeKey()
            self.ignoreResign = false
        }
        DiagnosticLog.shared.info("Motion presentation — \(inPlace ? "in-place" : "hyperspace"); retained selection and transaction")
        return true
    }

    func present() {
        loadTrace?.mark("present")
        // Opening from the global Hyper+Space path churns focus: the keyboard
        // transport layer goes up/down around the same time this LSUIElement app
        // presents a key panel. A short startup resign can otherwise tear the
        // survey down right after first paint, which reads as "didn't load."
        ignoreResign = true
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.ignoreResign {
                DiagnosticLog.shared.info("MotionPanel: ignored transient key resign")
                return
            }
            // Hyper+G is a staging session — clicks and window raises must not dismiss it.
            // Leave only via Enter (commit) or Esc (cancel).
            if self.inPlaceMode {
                DiagnosticLog.shared.info("MotionPanel: in-place key resign — reclaiming key")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.exposed, !self.dismissed else { return }
                    self.makeKey()
                }
                return
            }
            DiagnosticLog.shared.info("MotionPanel: key resigned, exiting")
            self.onExit?()
        }
        // Survey zoom/pan: a local scroll monitor (gated to this panel) so ⌘-scroll /
        // scroll reach us even though the SwiftUI host would otherwise swallow them.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self || self.exposePanelsByScreenID.values.contains(where: { event.window === $0 }) else {
                return event
            }
            return self.handleScroll(event) ? nil : event
        }
        // A click or drag on a survey screen-panel (canBecomeKey == false) can leave the
        // app with *no* key window, so Enter/Esc fall on the floor. After any mouse-up on
        // one of our panels, re-claim key on the next runloop turn (after the gesture's
        // onEnded settles) so the keyboard keeps working — the reported "couldn't hit
        // enter to confirm" bug.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self,
                  event.window === self || self.exposePanelsByScreenID.values.contains(where: { event.window === $0 }) else {
                return event
            }
            let generation = self.presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.exposed, !self.dismissed, !self.isKeyWindow,
                      self.presentationGeneration == generation,
                      self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil else { return }
                self.makeKey()
            }
            return event   // don't swallow — the click/drag still needs to process
        }
        // Belt-and-suspenders for the "couldn't hit Enter to confirm" bug: if a survey
        // screen-panel (canBecomeKey == false) or nothing holds key, the MotionPanel's own
        // keyDown never fires. Catch Enter/Esc here and route them so they never fall on the
        // floor. When the MotionPanel *is* key, defer to its keyDown (don't double-handle).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Stand down while the New Layer panel, rule panel, or command bar is up — they own
            // the keyboard (text field).
            guard let self, self.exposed, !self.isKeyWindow,
                  self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil else { return event }
            switch event.keyCode {
            case 53, 36, 76:      self.keyDown(with: event); return nil   // Return / keypad Enter — confirm
            default:          return event
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.dismissed,
                  self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil else { return }
            self.ignoreResign = false
        }
        // Hyperspace lands you straight in the survey. E collapses back to plain
        // motion; expose() no-ops to plain mode if there's <2 windows to lay out.
        expose()
    }

    func dismiss() {
        // Mark dead FIRST. A rapid hotkey re-fire can land a deactivate while the
        // async survey capture / first-paint from the *previous* activate is still
        // in flight. Those callbacks check `exposed` and self-heal via
        // rebuildExposeView() → installExposeHosts() — which, after teardown, would
        // resurrect the survey panels on a controller we no longer track (no key
        // monitor, no resign observer). That's the "Hyperspace stuck on top, esc /
        // quit / hotkey do nothing" trap. Clearing `exposed` + `dismissed` makes
        // every late callback a no-op so nothing can come back.
        dismissed = true
        stopLayoutRefresh()
        exposed = false
        ignoresMouseEvents = false
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        newLayerPanel?.close()
        newLayerPanel = nil
        rulePanel?.close()
        rulePanel = nil
        commandPanel?.close()
        commandPanel = nil
        animators.values.forEach { $0.cancel() }
        thumbs.removeAll()
        captureFrame.removeAll()
        thumbInFlight.removeAll()
        captureRebuildWorkItemsByScreenID.values.forEach { $0.cancel() }
        captureRebuildWorkItemsByScreenID.removeAll()
        inPlaceHoverWid = nil
        desktopGesture = nil
        layoutPreview.clear()
        dividerHandles.clear()
        NSCursor.arrow.set()
        desktopHUD?.orderOut(nil)
        desktopHUD = nil
        WindowSelectionOverlay.shared.clear()
        removeExposeHost()
        orderOut(nil)
    }

    /// Force every Hyperspace overlay panel off screen — even ones no live
    /// controller still tracks. Used as the recovery sweep so the toggle hotkey
    /// can always clear a survey that a prior race left orphaned (no key monitor,
    /// no resign observer) and stuck on top. Cheap; runs only on activate/deactivate.
    static func teardownStrayPanels() {
        WindowSelectionOverlay.shared.clear()
        for window in NSApp.windows where window is HyperspaceScreenPanel || window is MotionPanel || window is HyperspaceDesktopHUD {
            window.orderOut(nil)
            window.close()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Click = a targeted pluck: toggle the window under the cursor in/out of the
        // picked set. Like Space, it only *marks* — it never grids or moves a window
        // (that happens later on G / ⏎), so clicking stays calm and predictable.
        let p = event.locationInWindow

        // Ignore clicks on our own HUDs so they don't pluck a window behind them.
        // (The minimap handles its own clicks — clicking a cell deselects it.)
        if let s = stackHost, s.frame.contains(p) { return }
        if let l = legendHost, l.frame.contains(p) { return }

        // In the screenshot survey the spread (ExposeView) and minimap own all
        // clicks. Live-frame plucking here would toggle whatever real window sits
        // under the cursor — a *different* window than the tile you see — so skip it.
        if exposed { return }

        let globalAppKit = CGPoint(x: p.x + frame.origin.x, y: p.y + frame.origin.y)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: globalAppKit.x, y: primaryH - globalAppKit.y)   // CG top-left

        // Fresh z-order from CGWindowList — stale eligible zIndex picks the wrong overlap.
        DesktopModel.shared.forcePoll()
        let myPid = ProcessInfo.processInfo.processIdentifier
        let eligibleWids = Set(eligible.map(\.wid))
        guard let fresh = DesktopModel.shared.frontWindow(at: cg, excludingPid: myPid),
              eligibleWids.contains(fresh.wid),
              let hit = eligible.first(where: { $0.wid == fresh.wid }) else { return }

        togglePicked(hit.wid)
        updateLegend()
        refreshBorders()
        updateStack()
    }

    // MARK: - Canvas zoom/pan (survey only)
    //
    // ⌘-scroll zooms toward the pointer; plain scroll pans once zoomed past fit. This
    // is a pure view transform on the screenshot lattice — nothing here moves a real
    // window. State lives per display; ExposeView observes it and applies the
    // scaleEffect + offset. Driven by a local .scrollWheel monitor (installed in
    // present()) rather than a scrollWheel override, since NSHostingView swallows
    // unhandled scroll — matching the ScreenMap/Studio canvas idiom.
    //
    // Returns true when the survey consumed the scroll (the monitor then swallows it).
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard exposed,
              let screen = validSurveyScreen(screenForEvent(event)) ?? activeSurveyScreen,
              let host = exposeHostsByScreenID[MotionPanel.screenID(screen)] else { return false }
        let screenCanvas = canvasForScreen(screen)
        if activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(screen) {
            setActiveSurveyScreen(screen)
        }
        if event.modifierFlags.contains(.command) {
            let step = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
            zoomCanvas(screenCanvas, by: step, towardWindowPoint: event.locationInWindow, host: host)
            return true
        }
        guard screenCanvas.zoom > 1.0001 else { return false }        // nothing to pan at fit
        // Sign matches the ScreenMap canvas (+x right, −y to follow natural scroll).
        screenCanvas.pan = clampPan(CGSize(width:  screenCanvas.pan.width  + event.scrollingDeltaX,
                                           height: screenCanvas.pan.height - event.scrollingDeltaY),
                                    zoom: screenCanvas.zoom, host: host)
        return true
    }

    /// Zoom by `delta`, keeping the survey point under `windowPoint` fixed (cursor anchor).
    /// `windowPoint` is panel/window coords (bottom-left origin); the survey offset is
    /// top-left/+y-down, so the vertical component is flipped into host space first.
    private func zoomCanvas(_ canvas: ExposeCanvas, by delta: CGFloat, towardWindowPoint windowPoint: CGPoint, host: NSView) {
        let z0 = canvas.zoom
        let z1 = min(max(z0 + delta, canvas.minZoom), canvas.maxZoom)
        guard z1 != z0 else { return }
        let ratio = z1 / z0
        // Cursor vector from the container centre, in SwiftUI offset axes (+x right, +y down).
        let cx = windowPoint.x - host.frame.minX
        let cyTop = host.frame.maxY - windowPoint.y
        let d = CGSize(width: cx - host.frame.width / 2, height: cyTop - host.frame.height / 2)
        let pan0 = canvas.pan
        canvas.zoom = z1
        canvas.pan = clampPan(CGSize(width:  d.width  - ratio * (d.width  - pan0.width),
                                     height: d.height - ratio * (d.height - pan0.height)),
                              zoom: z1, host: host)
    }

    /// Keyboard zoom — step toward the survey centre (no pointer), scaling the current
    /// pan proportionally so the framing holds, then re-clamp.
    private func zoomCanvasStep(_ delta: CGFloat) {
        guard let screen = activeSurveyScreen,
              let host = exposeHostsByScreenID[MotionPanel.screenID(screen)] else { return }
        zoomCanvas(canvasForScreen(screen), by: delta, towardWindowPoint: CGPoint(x: host.frame.midX, y: host.frame.midY), host: host)
    }

    /// Keep the centre-scaled lattice from sliding past its own edges (no empty gutters).
    private func clampPan(_ pan: CGSize, zoom: CGFloat, host: NSView) -> CGSize {
        let maxX = max(0, (zoom - 1) * host.frame.width  / 2)
        let maxY = max(0, (zoom - 1) * host.frame.height / 2)
        return CGSize(width:  min(max(pan.width,  -maxX), maxX),
                      height: min(max(pan.height, -maxY), maxY))
    }

    override func keyDown(with event: NSEvent) {
        if layoutApplying { return }
        if commandLineState != nil { handleCommandLineKey(event); return }
        let code = event.keyCode
        if exposed, handleClusterSearchKey(event) { return }
        if code == 53 {                                     // Esc — close inspector / placement stage first, else leave
            if dragModel.selectedLayer != nil { dragModel.selectedLayer = nil; return }
            if dragModel.isPlacing { dragModel.endPlacing(); return }
            if !selectionOnly, let screen = activeSurveyScreen, canvasForScreen(screen).tool != nil {
                canvasForScreen(screen).tool = nil
                updateDesktopHUD()
                return
            }
            if inPlaceMode, overviewMarks { setOverviewMarks(false); return }
            if !selectionOnly, pendingLayout != nil {
                pendingLayout = nil
                layoutLocked = false
                desktopGesture = nil
                layoutPreview.clear()
                rebuildExposeView()
                return
            }
            if inPlaceMode, !selectionOnly, keptChange {
                DiagnosticLog.shared.info("In-place Esc — keep applied changes + exit")
                onExit?()
                return
            }
            undoAndExit(); return
        }
        if code == 36 || code == 76 {                       // Return / keypad Enter — confirm: keep + leave
            if selectionOnly {
                let screen = validSurveyScreen(screenForPointer())
                    ?? validSurveyScreen(screenForEvent(event))
                    ?? activeSurveyScreen
                completeWindowPickFromAim(on: screen)
            } else if exposed && !selectionOnly {
                let screen = validSurveyScreen(screenForPointer())
                    ?? validSurveyScreen(screenForEvent(event))
                    ?? activeSurveyScreen
                finishDesktopSession(on: screen)
            } else if exposed {                             // Hyperspace: gather the plucked, then leave
                let screen = validSurveyScreen(screenForPointer())
                    ?? validSurveyScreen(screenForEvent(event))
                    ?? activeSurveyScreen
                if let screen {
                    let count = pickOrderByScreen[MotionPanel.screenID(screen)]?.count ?? 0
                    if count > 0 { AppFeedback.shared.commitTactile() }
                    DiagnosticLog.shared.info("Motion confirm — gather \(count) from Exposé + exit")
                    gatherAndExit(on: screen)
                }
            } else {
                // A prior G may have collapsed the survey. Pending placements
                // still belong to this transaction and commit only on Return.
                if !group.isEmpty {
                    AppFeedback.shared.commitTactile()
                    DiagnosticLog.shared.info("Motion confirm — grid \(group.count) + exit")
                } else {
                    DiagnosticLog.shared.info("Motion confirm — keep changes + exit")
                }
                gatherAndExit(on: activeSurveyScreen)
            }
            return
        }
        let mods = event.modifierFlags
        if !selectionOnly, exposed {
            if mods.contains(.command), code == 6 { undoDesktopLayout(); return }
            if code == 14, !mods.contains(.shift) {
                if inPlaceMode { setOverviewMarks(!overviewMarks) }
                else { WindowMotionMode.shared.showDesktop() }
                return
            }
            if code == 5, !mods.contains(.shift) { proposeDesktopLayout(); return }
        }

        // A daemon window pick is a read-only selection session. `expose()` can
        // legitimately stay collapsed when only one window is eligible, so gate
        // the plain motion key map as well as the survey actions below.
        if selectionOnly && !exposed {
            switch code {
            case 48:
                moveReticle(mods.contains(.shift) ? -1 : 1)
            case 49:
                completeWindowPick(activeEntry.wid)
            default:
                NSSound.beep()
            }
            return
        }

        // In the screenshot Exposé survey the keyboard drives a clustered lattice:
        // Tab/Space move & pluck the highlighted tile, a–z pluck by hint letter,
        // G gathers in place, E collapses back. Nothing here moves a real window
        // except the gather (G), matching the "survey on screenshots" model.
        if exposed {
            let eventScreen = validSurveyScreen(screenForPointer())
                ?? validSurveyScreen(screenForEvent(event))
                ?? activeSurveyScreen
            if let eventScreen,
               activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(eventScreen) {
                setActiveSurveyScreen(eventScreen)
            }
            let screenID = eventScreen.map(MotionPanel.screenID)
            if inPlaceMode, !selectionOnly, event.characters == ":", let eventScreen {
                openCommandLine(on: eventScreen)                             // : — command line
                return
            }
            switch code {
            case 123, 124, 125, 126 where inPlaceMode && !selectionOnly:     // arrows — aim by position
                if let eventScreen {
                    let direction: HyperspaceSpatialAim.Direction = switch code {
                    case 123: .left
                    case 124: .right
                    case 125: .down
                    default: .up
                    }
                    aimSpatially(direction, from: eventScreen)
                }
                return
            case 49 where inPlaceMode && !selectionOnly && inPlaceHoverWid != nil: // Space — pick the aimed window
                if let wid = inPlaceHoverWid, let entry = eligible.first(where: { $0.wid == wid }),
                   let screen = screen(for: entry) {
                    exposeToggle(wid, on: screen)
                }
                return
            case 48:                                                         // Tab — move highlight
                if let eventScreen { exposeAimStep(mods.contains(.shift) ? -1 : 1, on: eventScreen) }
                return
            case 49:                                                         // Space — pluck highlighted
                if let eventScreen, let id = screenID {
                    let aim = exposeAimByScreen[id] ?? 0
                    if let wid = exposeOrderByScreen[id]?[safe: aim] {
                        if selectionOnly { completeWindowPick(wid) }
                        else { exposeToggle(wid, on: eventScreen) }
                    }
                }
                return
            case 14 where !mods.contains(.shift) && !inPlaceMode:             // E — collapse survey
                if selectionOnly { NSSound.beep() }
                else { collapseExpose() }
                return
            case 5  where !mods.contains(.shift):                            // G — grid selection (stay in mode)
                if selectionOnly { NSSound.beep(); return }
                AppFeedback.shared.commitTactile()
                if let eventScreen { gatherInPlace(on: eventScreen) }
                return
            case 3  where !mods.contains(.shift) && inPlaceMode:             // F — fill available space
                guard let eventScreen else { NSSound.beep(); return }
                fillSelectedInPlace(on: eventScreen)
                return
            case 1  where !mods.contains(.shift) && inPlaceMode:             // S — swap first two picks
                if let eventScreen, let id = screenID,
                   let a = pickOrderByScreen[id]?[safe: 0],
                   let b = pickOrderByScreen[id]?[safe: 1] {
                    swapWindows(widA: a, widB: b, on: eventScreen)
                } else { NSSound.beep() }
                return
            case 24: zoomCanvasStep(0.2); return                            // = / +  — zoom in
            case 27: zoomCanvasStep(-0.2); return                           // −      — zoom out
            case 29:
                if let eventScreen { canvasForScreen(eventScreen).reset() }  // 0      — reset to fit
                return
            case 44:                                                         // / — curated command bar
                if selectionOnly { NSSound.beep() }
                else if let eventScreen { presentCommandBar(on: eventScreen) }
                return
            default:
                let ch = event.charactersIgnoringModifiers?.lowercased()
                if let eventScreen, let id = screenID,
                   mods.contains(.shift), let ch, let cid = clusterHintMapByScreen[id]?[ch] {
                    if selectionOnly { NSSound.beep() }
                    else { exposeToggleCluster(cid, on: eventScreen) }        // ⇧a–z — pluck a whole group
                } else if let eventScreen, let id = screenID,
                          let ch, let wid = hintMapByScreen[id]?[ch] {
                    if selectionOnly { completeWindowPick(wid) }
                    else { exposeToggle(wid, on: eventScreen) }              // a–z — pluck by hint
                } else {
                    NSSound.beep()
                }
                return
            }
        }

        switch code {
        case 48:                                            // Tab — point at next/prev window
            moveReticle(mods.contains(.shift) ? -1 : 1)
            return
        case 49:                                            // Space — pluck into group
            togglePluck()
            return
        case 14:                                            // E — toggle the Exposé spread
            toggleExpose()
            return
        case 5:                                             // G — grid the group (in Exposé: gather but stay)
            AppFeedback.shared.commitTactile()
            if exposed { gatherInPlace() } else { distributeGroup() }
            return
        case 3:                                             // F — grow into open space until a neighbor
            fillAvailableSpace()
            return
        default:
            break
        }

        if mods.contains(.shift), let v = MotionKeys.arrow(code) { nudge(v); return }
        if mods.contains(.option), let v = MotionKeys.arrow(code) { resize(v); return }
        if let s = MotionKeys.side(code) { cycleTile(s); return }
        if let position = MotionKeys.special(code) { tile(position); lastSide = nil; return }
        NSSound.beep()
    }

    /// Command-modified keys arrive here, not in `keyDown`. ⌘L remembers the
    /// current plucked set as a rule-backed Studio layer; ⌘T turns it into a
    /// live cross-app tab stack.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if commandLineState != nil, event.modifierFlags.contains(.command) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 37 {                                // ⌘L — save the pluck as a layer
            guard !selectionOnly else { NSSound.beep(); return true }
            saveGroupAsLayer()
            return true
        }
        if event.keyCode == 17 {                                // ⌘T — stack the pluck as tabs
            guard !selectionOnly else { NSSound.beep(); return true }
            createLiveTabsFromSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Selection

    private func completeWindowPick(_ wid: UInt32) {
        guard let entry = eligible.first(where: { $0.wid == wid }) else {
            NSSound.beep()
            return
        }
        DiagnosticLog.shared.info("Window pick — selected \(entry.app) #\(entry.wid)")
        AppFeedback.shared.commitTactile()
        onSelection?(entry)
    }

    private func completeWindowPickFromAim(on screen: NSScreen?) {
        guard let screen else {
            completeWindowPick(activeEntry.wid)
            return
        }
        let id = MotionPanel.screenID(screen)
        let aim = exposeAimByScreen[id] ?? 0
        if let wid = exposeOrderByScreen[id]?[safe: aim] {
            completeWindowPick(wid)
        } else {
            completeWindowPick(activeEntry.wid)
        }
    }

    private func moveReticle(_ delta: Int) {
        let members = activeSurveyMembers
        guard !members.isEmpty else { NSSound.beep(); return }
        let currentWid = activeEntry.wid
        let current = members.firstIndex { $0.wid == currentWid } ?? 0
        let next = ((current + delta) % members.count + members.count) % members.count
        if let idx = eligible.firstIndex(where: { $0.wid == members[next].wid }) {
            reticle = idx
            fillAimWid = activeEntry.wid
        }
        lastSide = nil
        _ = ax(for: activeEntry)          // resolve + cache
        updateLegend()
        refreshBorders()                  // fake bring-to-front: preview the aimed window in place, don't raise it
        updateStack()
    }

    private func togglePluck() {
        togglePicked(activeEntry.wid)
        // Pluck only *marks* the window — nothing moves. You build the selection
        // calmly, then arrange it when you're ready: G grids in place, ⏎ gathers.
        // (No more re-gridding on every pluck.)
        updateLegend()
        refreshBorders()
        updateStack()
    }

    /// Toggle a window in the active display's ordered selection. Slot numbers
    /// and the gather grid follow that same authoritative order.
    private func togglePicked(_ wid: UInt32) {
        if selection.toggle(wid, on: activeSelectionScreenID),
           let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        pruneActivePicks()
    }

    /// The picked windows in pick order — the order their slot numbers run and the
    /// order they fill the balanced gather grid (so slot N lands in cell N).
    private func orderedGroup() -> [WindowEntry] {
        let activeIDs = Set(activeSurveyMembers.map(\.wid))
        return pickOrder.compactMap { wid in
            guard activeIDs.contains(wid) else { return nil }
            return eligible.first { $0.wid == wid }
        }
    }

    /// The picked windows that should fall into the balanced gather grid — i.e.
    /// the group minus any window that was drag-staged to a specific location
    /// (that one honours its dropped cell instead of the grid). No-op outside the
    /// survey, where nothing is ever staged.
    private func gatherMembers() -> [WindowEntry] {
        orderedGroup().filter { stagedIntents[$0.wid]?.location == nil }
    }

    /// ⌘L — save the plucked windows as a new ⌘⌥ layer. Nothing moves — this
    /// only records the selection — and we stay in the mode so you can keep
    /// arranging.
    private func saveGroupAsLayer() {
        let picked = orderedGroup()
        guard !picked.isEmpty else { NSSound.beep(); return }
        let name = Self.defaultLayerName(forApps: Self.orderedApps(picked))
        guard editLayers("save '\(name)'", { try $0.createLayer(label: name, windows: picked) }) else { return }
        DiagnosticLog.shared.info("Motion — saved \(picked.count) selected windows as layer '\(name)'")
        LayerBezel.shared.acknowledge("Saved · \(name)")
    }

    /// Turn the current per-display pluck into an ephemeral tab stack. The same
    /// selection is published to `LiveTabGroupStore` continuously, so the
    /// assistant and daemon agents can perform this exact action too.
    private func createLiveTabsFromSelection(on targetScreen: NSScreen? = nil) {
        keptChange = true
        let picked: [WindowEntry]
        if let targetScreen {
            let id = MotionPanel.screenID(targetScreen)
            let ids = pickOrderByScreen[id] ?? []
            picked = ids.compactMap { wid in eligible.first(where: { $0.wid == wid }) }
        } else {
            picked = orderedGroup()
        }
        guard picked.count >= 2 else { NSSound.beep(); return }
        LiveTabGroupStore.shared.captureCandidateSelection(picked.map(\.wid))
        guard let tabs = LiveTabGroupStore.shared.create(
            windowIDs: picked.map(\.wid),
            placement: .tile(.topLeft),
            screen: targetScreen ?? activeSurveyScreen ?? screen(for: picked[0])
        ) else { NSSound.beep(); return }
        AppFeedback.shared.commitTactile()
        LayerBezel.shared.acknowledge("Tabs · \(tabs.name)")
        onExit?()
    }

    // MARK: - Single-window operations (on the active window)

    /// Same geometry-derived cycle as Spatial Lens: half → third → two-thirds.
    /// The current AX frame decides the next step, so this remains correct after
    /// external moves and across separate Hyper+G sessions.
    private func cycleTile(_ side: MotionSide) {
        guard let el = ax(for: activeEntry), let cur = RealWindowAnimator.axFrame(el) else { return }

        // Pick the display from the live AX frame, not the stale polled
        // WindowEntry.frame; after a move this keeps repeated taps on the
        // screen where the window actually is.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let currentCenter = CGPoint(x: cur.midX, y: primaryH - cur.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(currentCenter) }) ?? screen(for: activeEntry) else { return }

        let direction: SpatialDirection
        switch side {
        case .left: direction = .left
        case .right: direction = .right
        case .top: direction = .up
        case .bottom: direction = .down
        }
        let visibleFrame = WindowTiler.tileFrame(fractions: (0, 0, 1, 1), on: screen)
        let cycle = SpatialPlacementCycle.resolve(
            direction: direction,
            currentFrame: cur,
            sourceVisibleFrame: visibleFrame
        )
        lastSide = side
        cycleStep = cycle.cycleIndex
        placeActive(to: WindowTiler.tileFrame(for: cycle.placement, on: screen))
    }

    private func tile(_ position: TilePosition) {
        guard let screen = screen(for: activeEntry) else { return }
        placeActive(to: WindowTiler.tileFrame(for: position, on: screen))
    }

    private func nudge(_ v: CGVector) {
        lastSide = nil
        guard let el = ax(for: activeEntry), let cur = RealWindowAnimator.axFrame(el) else { return }
        let target = CGRect(
            x: cur.minX + v.dx * nudgeStep,
            y: cur.minY + v.dy * nudgeStep,
            width: cur.width,
            height: cur.height
        )
        placeActive(to: target)
    }

    private func resize(_ v: CGVector) {
        lastSide = nil
        guard let el = ax(for: activeEntry), let cur = RealWindowAnimator.axFrame(el) else { return }
        let minWidth: CGFloat = 160
        let minHeight: CGFloat = 120
        var target = cur

        if v.dx < 0 {
            target.origin.x -= resizeStep
            target.size.width += resizeStep
        } else if v.dx > 0 {
            target.size.width += resizeStep
        }

        if v.dy < 0 {
            target.origin.y -= resizeStep
            target.size.height += resizeStep
        } else if v.dy > 0 {
            target.size.height += resizeStep
        }

        target.size.width = max(minWidth, target.width)
        target.size.height = max(minHeight, target.height)
        placeActive(to: target)
    }

    fileprivate func tileCurrentTarget(to position: TilePosition) -> Bool {
        let selected = pickOrder
        let targetWid = inPlaceHoverWid
            ?? fillAimWid
            ?? selected.last
            ?? activeEntry.wid
        guard let entry = eligible.first(where: { $0.wid == targetWid }),
              let screen = screen(for: entry) else {
            NSSound.beep()
            return true
        }
        TileZoneOverlay.shared.show(position: position, on: screen, autoHideAfter: 0.28)
        placeEntry(entry, to: WindowTiler.tileFrame(for: position, on: screen), label: position.rawValue)
        return true
    }

    /// Place the active window instantly and exactly — snappy, no jittery tween.
    private func placeActive(to target: CGRect) {
        placeEntry(activeEntry, to: target, label: "place")
    }

    private func placeEntry(_ entry: WindowEntry, to target: CGRect, label: String = "place") {
        if exposed && !selectionOnly {
            pendingLayout = .init(title: label == "fill" ? "Fill available space" : "Window placement", frames: [entry.wid: target])
            applyDesktopLayout()
            return
        }
        guard let el = ax(for: entry) else { NSSound.beep(); return }
        recordOriginal(entry.wid, el)
        let before = RealWindowAnimator.axFrame(el) ?? .zero
        raising { RealWindowAnimator.setFrameRobust(el, target, pid: entry.pid, raise: true) }
        let after = RealWindowAnimator.axFrame(el) ?? .zero
        DiagnosticLog.shared.info("Motion \(label) \(entry.app) wid=\(entry.wid) step=\(cycleStep) before=\(rectStr(before)) target=\(rectStr(target)) after=\(rectStr(after))")
        refreshBorders()
        updateStack()
        if exposed { rebuildExposeView() }
    }

    /// F — expand the aimed window until it hits a same-screen neighbor or the
    /// display edge. Perpendicular overlap counts as a wall (same rule as Screen Map grow).
    private func fillAvailableSpace(for wid: UInt32? = nil) {
        keptChange = true
        guard let target = wid.flatMap({ w in eligible.first(where: { $0.wid == w }) }) ?? fillTargetEntry(),
              let el = ax(for: target),
              let me = RealWindowAnimator.axFrame(el) else { NSSound.beep(); return }

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let currentCenter = CGPoint(x: me.midX, y: primaryH - me.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(currentCenter) }) ?? screen(for: target) else {
            NSSound.beep(); return
        }

        let bounds = WindowTiler.tileFrame(fractions: (0, 0, 1, 1), on: screen)
        var left = bounds.minX, right = bounds.maxX, top = bounds.minY, bottom = bounds.maxY
        let tolerance: CGFloat = 2

        for other in eligible where other.wid != target.wid {
            guard entry(other, isOn: screen),
                  let otherEl = ax(for: other),
                  let of = RealWindowAnimator.axFrame(otherEl) else { continue }
            if of.maxX <= me.minX + tolerance && of.maxY > me.minY + tolerance && of.minY < me.maxY - tolerance {
                left = max(left, of.maxX)
            }
            if of.minX >= me.maxX - tolerance && of.maxY > me.minY + tolerance && of.minY < me.maxY - tolerance {
                right = min(right, of.minX)
            }
            if of.maxY <= me.minY + tolerance && of.maxX > me.minX + tolerance && of.minX < me.maxX - tolerance {
                top = max(top, of.maxY)
            }
            if of.minY >= me.maxY - tolerance && of.maxX > me.minX + tolerance && of.minX < me.maxX - tolerance {
                bottom = min(bottom, of.minY)
            }
        }

        let newFrame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard newFrame.width >= 160, newFrame.height >= 120 else { NSSound.beep(); return }
        if abs(newFrame.minX - me.minX) < tolerance && abs(newFrame.minY - me.minY) < tolerance
            && abs(newFrame.width - me.width) < tolerance && abs(newFrame.height - me.height) < tolerance {
            NSSound.beep(); return
        }

        lastSide = nil
        placeEntry(target, to: newFrame, label: "fill")
    }

    /// Hyper+G exposes only selected windows as action targets. Keep the F shortcut
    /// on the same model as the shelf instead of filling the implicit startup aim.
    private func fillSelectedInPlace(on screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        let selected = pickOrderByScreen[id] ?? []
        let target = fillAimWid.flatMap { selected.contains($0) ? $0 : nil } ?? selected.last
        guard let target else { NSSound.beep(); return }
        fillAvailableSpace(for: target)
    }

    /// Pin keyboard actions (F fill, half-tiles, etc.) to the window the user last
    /// clicked or Tab-aimed — not a stale expose index from mode entry.
    private func aimWindow(_ wid: UInt32, on surveyScreen: NSScreen? = nil) {
        fillAimWid = wid
        if let idx = eligible.firstIndex(where: { $0.wid == wid }) {
            reticle = idx
        }
        let resolvedScreen = surveyScreen
            ?? activeSurveyScreen
            ?? eligible.first(where: { $0.wid == wid }).flatMap { self.screen(for: $0) }
        if let resolvedScreen {
            let id = MotionPanel.screenID(resolvedScreen)
            if let order = exposeOrderByScreen[id], let aimIdx = order.firstIndex(of: wid) {
                exposeAimByScreen[id] = aimIdx
                if activeSurveyScreen.map(MotionPanel.screenID) == id {
                    exposeAim = aimIdx
                }
            }
        }
    }

    private func fillTargetEntry() -> WindowEntry? {
        if let wid = fillAimWid, let entry = eligible.first(where: { $0.wid == wid }) {
            return entry
        }
        return activeEntry
    }

    private func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private func recordOriginal(_ wid: UInt32, _ el: AXUIElement) {
        if originalFrames[wid] == nil, let cur = RealWindowAnimator.axFrame(el) {
            originalFrames[wid] = cur
        }
    }

    /// Esc: leave immediately, then restore anything we actually moved. The overlay tears
    /// down *first* so dismissal feels instant; the (slow) per-window AX restore only runs
    /// if we touched real windows this session — a pure survey/preview Esc skips it entirely
    /// instead of needlessly re-raising every window (the "Esc takes forever" bug).
    private func undoAndExit() {
        guard !layoutApplying else { return }
        onExit?()                                   // instant visual dismiss
        guard didMoveWindows else { return }        // nothing real changed → done
        for (wid, frame) in originalFrames {
            guard let entry = eligible.first(where: { $0.wid == wid }), let el = ax(for: entry) else { continue }
            RealWindowAnimator.setFrameRobust(el, frame, pid: entry.pid)
        }
        restoreOriginalOrder()
    }

    /// Mouse and keyboard confirmation share one transaction boundary: staged
    /// placements are applied, live preview changes stay where they are, then the
    /// overlay closes. `undoAndExit()` is the exact inverse used by Esc / Cancel.
    private func keepInPlaceAndExit(on screen: NSScreen?) {
        if let screen {
            if !stagedIntents.isEmpty { AppFeedback.shared.commitTactile() }
            commitStagedIntents(on: screen)
            DiagnosticLog.shared.info("In-place confirm — commit staged + exit")
        }
        onExit?()
    }

    /// Re-stack every window in the front-to-back order it had when the mode
    /// opened (`eligible` is sorted frontmost-first). Tab/preview raises only lift
    /// the aimed window transiently; this is what makes them ephemeral — replaying
    /// the original order back→front leaves the original frontmost window on top.
    private func restoreOriginalOrder() {
        raising {
            for entry in eligible.reversed() {
                guard let el = ax(for: entry) else { continue }
                RealWindowAnimator.raise(el)
            }
        }
    }

    // MARK: - Group grid

    /// The shared grid used by distribution and HUD tiling. The real gather and
    /// its minimap use the same ordered unit rectangles, including three columns.
    private func balancedGrid(_ n: Int) -> [CGRect] {
        WindowTiler.normalizedGridSlots(count: n)
    }

    /// Lay the plucked group out live: 2+ windows tile into a grid (each moved
    /// AND raised so it actually comes to the front); a lone window is just
    /// raised. Called on every pluck/unpluck so a position opens up as soon as
    /// you add a window. Moves are real but revertible (Enter confirms, Esc resets).
    private func relayoutGroup() {
        let members = gatherMembers()
        guard let screen = activeSurveyScreen, !members.isEmpty else { return }
        if members.count == 1 {
            if let el = ax(for: members[0]) { raising { RealWindowAnimator.raise(el) } }
            return
        }
        let rects = balancedGrid(members.count)
        var resolvedMoves: [(wid: UInt32, pid: Int32, frame: CGRect, axWindow: AXUIElement)] = []
        var fallbackMoves: [(wid: UInt32, pid: Int32, frame: CGRect)] = []
        resolvedMoves.reserveCapacity(members.count)
        fallbackMoves.reserveCapacity(members.count)
        for (i, m) in members.enumerated() {
            let r = rects[i]
            let target = WindowTiler.tileFrame(fractions: (r.minX, r.minY, r.width, r.height), on: screen)
            if let el = ax(for: m) {
                recordOriginal(m.wid, el)
                resolvedMoves.append((wid: m.wid, pid: m.pid, frame: target, axWindow: el))
            } else {
                fallbackMoves.append((wid: m.wid, pid: m.pid, frame: target))
            }
        }
        guard !resolvedMoves.isEmpty || !fallbackMoves.isEmpty else { return }
        raising {
            if fallbackMoves.isEmpty {
                WindowTiler.batchMoveAndRaiseWindows(resolvedMoves)
            } else {
                WindowTiler.batchMoveAndRaiseWindows(
                    resolvedMoves.map { (wid: $0.wid, pid: $0.pid, frame: $0.frame) } + fallbackMoves
                )
            }
        }
        DiagnosticLog.shared.info("Motion grid — \(resolvedMoves.count + fallbackMoves.count) windows")
    }

    /// Refresh inventory chrome after a grid snap without blocking the batch move.
    private func refreshAfterGridMove(on screen: NSScreen) {
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.dismissed, self.presentationGeneration == generation else { return }
            DesktopModel.shared.poll()
            self.layoutFingerprintByScreen[MotionPanel.screenID(screen)] = self.layoutFingerprint(for: screen)
            self.rebuildExposeView(screens: [screen])
            self.updateLegend()
            self.refreshBorders()
            self.updateStack()
            self.makeKey()
        }
    }

    /// G — make sure the aimed window is part of the group, then lay out the grid.
    private func distributeGroup() {
        if !group.contains(activeEntry.wid) { togglePicked(activeEntry.wid) }
        let screen = activeSurveyScreen
        relayoutGroup()
        updateLegend()
        if inPlaceMode, let screen {
            refreshAfterGridMove(on: screen)
        } else {
            refreshBorders()
            updateStack()
        }
    }

    // MARK: - Screenshot Exposé (the lattice survey)
    //
    // E lifts every window on the active display into a *clustered lattice of live
    // captures* — the real windows never move. Tiles are grouped into clusters
    // (your own rules first, then smart by-app) and each wears a home-row hint
    // letter; press it (or click) to pluck. Picks get slot numbers in pick order.
    // ⏎/G gather the picked set into a balanced grid (the only real window moves);
    // E collapses the survey; Esc reverts everything. See study 05 in
    // design/hyperspace-lattice-studio.html for the visual language.

    private func toggleExpose() {
        if exposed { collapseExpose() } else { expose() }
    }

    /// Build the survey: cluster the active-display windows, assign hint letters,
    /// size the tiles, show the spread overlay, and kick off live captures. No
    /// real window is touched — this is a screenshot survey.
    private func expose() {
        guard let screen = activeSurveyScreen else { return }
        loadTrace?.mark("expose.begin")
        let screens = surveyScreens()
        let members = eligible.filter { entry($0, isOn: screen) }
        let allMembers = screens.flatMap { surveyMembers(on: $0) }
        guard !members.isEmpty else { NSSound.beep(); return }    // nothing to survey

        exposed = true
        ignoresMouseEvents = !inPlaceMode
        resetSurveyState(for: screens)
        for surveyScreen in screens {
            rebuildSurveyState(for: surveyScreen, resetAim: true)
            canvasForScreen(surveyScreen).reset()
        }
        prunePicks(on: screen)
        syncActiveSurveyState(from: screen)
        loadTrace?.mark("survey.state")
        let hostsT0 = CACurrentMediaTime()
        installExposeHosts()
        loadTrace?.record("installHosts", ms: (CACurrentMediaTime() - hostsT0) * 1000, warnAbove: 48)
        loadTrace?.mark("hosts.ready")
        captureCount = allMembers.count
        if !inPlaceMode { allMembers.forEach { captureThumb(for: $0) } } // Desktop uses real windows, not captures.
        DesktopModel.shared.poll()
        layoutFingerprintByScreen.removeAll()
        for screen in screens { layoutFingerprintByScreen[MotionPanel.screenID(screen)] = layoutFingerprint(for: screen) }
        rebuildExposeView()
        loadTrace?.mark("expose.ready")
        checkCapturesSettled()                                     // every tile a cache hit → already done
        startLayoutRefresh()

        // First-paint mark: the next main-loop turn after we install and lay out
        // the spread is a good proxy for "the survey is on screen."
        if firstPaintAt == 0, loadStart > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.firstPaintAt == 0 else { return }
                self.firstPaintAt = CACurrentMediaTime()
                DiagnosticLog.shared.info(String(format: "Hyperspace load — first paint %.1fms (from trigger)", (self.firstPaintAt - self.loadStart) * 1000))
            }
        }

        DiagnosticLog.shared.info("Motion expose — survey \(allMembers.count) windows across \(screens.count) displays; active \(members.count) windows in \(exposeClusters.count) clusters")
        updateLegend()
        updateStack()
        refreshBorders()                                          // clears real-window chrome while surveying
    }

    /// E (while surveying) — drop the spread, back to normal motion mode. Picks
    /// are kept (nothing moved), so you can still gather or keep arranging.
    private func collapseExpose() {
        stopLayoutRefresh()
        removeExposeHost()
        exposed = false
        ignoresMouseEvents = false
        updateLegend()
        refreshBorders()
        updateStack()
    }

    /// Stage a location without rebuilding — callers batch and rebuild once.
    private func stageDrop(_ wid: UInt32, _ placement: PlacementSpec?) {
        if exposed && !selectionOnly {
            guard let placement, let entry = eligible.first(where: { $0.wid == wid }),
                  let screen = screen(for: entry) else { return }
            var frames = pendingLayout?.frames ?? [:]
            frames[wid] = WindowTiler.tileFrame(fractions: placement.fractions, on: screen)
            pendingLayout = .init(title: "Window placement", frames: frames)
            layoutNotice = nil
            refreshLayoutPreview()
            return
        }
        if let placement {
            stagedIntents[wid, default: StagedIntent()].location = placement
        }
    }

    /// A tile was dropped in the survey. A non-nil placement stages a location for
    /// that window (badge shows; nothing real moves until gather); nil means the
    /// drop missed every target — no change, we just rebuild to clear the drag
    /// placeholder. Either way the rebuild here un-suppresses the spread (rebuilds
    /// are skipped while a drag is in flight so the SwiftUI gesture survives).
    private func handleDrop(_ wid: UInt32, _ placement: PlacementSpec?) {
        stageDrop(wid, placement)
        if let placement {
            DiagnosticLog.shared.info("Hyperspace stage — wid=\(wid) location \(placement.wireValue)")
        }
        rebuildExposeForActiveScreen()
    }

    /// Stage a balanced sub-grid for a multi-window drop onto the lattice, anchored at `anchor`.
    private func handleGridGroupDrop(_ wids: [UInt32], res: LatticeRes, anchor: HoverCell) {
        let (cols, rows) = res.dims
        guard let cells = balancedGridCells(count: wids.count, latticeCols: cols, latticeRows: rows,
                                            anchorCol: anchor.col, anchorRow: anchor.row) else {
            NSSound.beep()
            return
        }
        for (i, wid) in wids.enumerated() {
            let cell = cells[i]
            guard let gp = GridPlacement(columns: cols, rows: rows, column: cell.col, row: cell.row) else { continue }
            stageDrop(wid, PlacementSpec.grid(gp))
        }
        DiagnosticLog.shared.info("Hyperspace stage — \(wids.count) windows grid @ \(anchor.col),\(anchor.row) (\(res.name))")
        rebuildExposeForActiveScreen()
    }

    /// Click a cell on the open grid. The selection lands in that cell, or in
    /// the side the cell belongs to when more than one window is selected.
    private func placeSelectionOnGrid(col: Int, row: Int, res: LatticeRes, on screen: NSScreen) {
        guard !layoutApplying else { return }
        let id = MotionPanel.screenID(screen)
        let picked = pickOrderByScreen[id] ?? []
        guard !picked.isEmpty else { NSSound.beep(); return }
        let (cols, rows) = res.dims
        let area = desktopArea(on: screen)
        let span = gridClickSpan(col: col, row: row, cols: cols, rows: rows, count: picked.count)
        let region = gridSpanFrame(span, latticeCols: cols, latticeRows: rows, in: area)
        let frames = HyperspaceLayoutPlanner.pack(picked, into: region)
            ?? (picked.count > 1 ? HyperspaceLayoutPlanner.pack(picked, into: area) : nil)
        guard let frames else { NSSound.beep(); return }
        layoutNotice = nil
        layoutLocked = true
        pendingLayout = .init(title: gridSpanTitle(span, cols: cols, rows: rows), frames: frames)
        DiagnosticLog.shared.info("Hyperspace grid — \(picked.count) window(s) \(pendingLayout?.title ?? "")")
        refreshLayoutPreview()
        updateDesktopHUD()
        updateLegend()
    }

    private func gridSpanFrame(_ span: GridSpan, latticeCols: Int, latticeRows: Int, in area: CGRect) -> CGRect {
        let fx = CGFloat(span.col) / CGFloat(max(1, latticeCols))
        let fy = CGFloat(span.row) / CGFloat(max(1, latticeRows))
        let fw = CGFloat(span.cols) / CGFloat(max(1, latticeCols))
        let fh = CGFloat(span.rows) / CGFloat(max(1, latticeRows))
        return CGRect(x: area.minX + fx * area.width, y: area.minY + fy * area.height,
                      width: fw * area.width, height: fh * area.height)
    }

    /// Stage a layer join without rebuilding — callers batch and rebuild once.
    private func stageLayerDrop(_ wid: UInt32, _ layerKey: String) {
        if layerKey == HyperspaceDrag.newLayerKey {
            stagedIntents[wid, default: StagedIntent()].newLayer.toggle()
        } else if stagedIntents[wid]?.layers.contains(layerKey) == true {
            stagedIntents[wid]?.layers.remove(layerKey)
        } else {
            stagedIntents[wid, default: StagedIntent()].layers.insert(layerKey)
        }
    }

    /// A tile was dropped on a Layers pile. The ＋ pile stages a brand-new layer; any
    /// other pile toggles a staged join (multi-membership). Only *stages* — nothing is
    /// written to workspace.json until gather, so Esc still discards cleanly.
    private func handleLayerDrop(_ wid: UInt32, _ layerKey: String) {
        stageLayerDrop(wid, layerKey)
        DiagnosticLog.shared.info("Hyperspace stage — wid=\(wid) layer \(layerKey)")
        rebuildExposeForActiveScreen()
    }

    private func handleLayerDrops(_ wids: [UInt32], _ layerKey: String) {
        guard !wids.isEmpty else { return }
        for wid in wids { stageLayerDrop(wid, layerKey) }
        DiagnosticLog.shared.info("Hyperspace stage — \(wids.count) window(s) layer \(layerKey)")
        rebuildExposeForActiveScreen()
    }

    /// In-place: rebuild one screen; hyperspace survey: rebuild all.
    private func rebuildExposeForActiveScreen() {
        if inPlaceMode, let screen = activeSurveyScreen {
            rebuildExposeView(screens: [screen])
        } else {
            rebuildExposeView()
        }
    }

    private func rebuildExposeForScreenInteraction(on screen: NSScreen) {
        if inPlaceMode {
            rebuildExposeView(screens: [screen])
        } else {
            rebuildExposeView()
        }
    }

    /// Edit mode: drop one rule from a layer (the ✕ on a pile's rule chip).
    /// Writes straight through to workspace.json — these are committed rules,
    /// not staged intents. A layer keeps going when its last rule goes. The
    /// band rebuilds so the pile preview re-resolves.
    private func removeLayerClause(_ layerId: String, _ clauseIndex: Int) {
        guard let (index, layer) = workspaceLayer(layerId) else { return }
        let rules = Self.ruleEntries(layer)
        guard rules.indices.contains(clauseIndex) else { return }
        if editLayers("drop a rule", { try $0.removeEntry(at: rules[clauseIndex].index, fromLayer: index) }) {
            DiagnosticLog.shared.info("Hyperspace edit — layer \(layer.label) dropped rule \(clauseIndex)")
        }
        rebuildExposeView()
    }

    /// Edit mode: write a new or edited rule from the Hyperspace inspector.
    private func saveLayerClause(_ layerId: String, _ clauseIndex: Int?, _ clause: StudioLayerClause) {
        guard let (index, layer) = workspaceLayer(layerId) else { return }
        let rules = Self.ruleEntries(layer)
        let entry = clauseIndex.flatMap { rules.indices.contains($0) ? rules[$0].index : nil }
        var project = entry.map { layer.projects[$0] } ?? LayerProject(clause: clause)
        project.setClause(clause)
        if editLayers("save a rule", { try $0.setEntry(project, at: entry, inLayer: index) }) {
            DiagnosticLog.shared.info("Hyperspace edit — layer \(layer.label) \(entry == nil ? "added" : "updated") rule [\(clause.summary)]")
        }
        rebuildExposeView()
    }

    private func presentLayerRuleEditor(_ layerId: String, _ clauseIndex: Int?, _ clause: StudioLayerClause, on screen: NSScreen) {
        guard exposed, rulePanel == nil, let (_, layer) = workspaceLayer(layerId) else { return }
        ignoreResign = true
        let panel = LayerRulePanel(
            layerName: layer.label,
            clauseIndex: clauseIndex,
            clause: clause,
            onSave: { [weak self] saved in
                guard let self else { return }
                self.saveLayerClause(layerId, clauseIndex, saved)
                self.finishLayerRuleEditor()
            },
            onCancel: { [weak self] in self?.finishLayerRuleEditor() }
        )
        rulePanel = panel
        panel.present(on: screen)
    }

    private func finishLayerRuleEditor() {
        rulePanel = nil
        ignoreResign = false
        makeKey()
    }

    /// Edit mode: delete a whole layer (the "Delete layer" item in a pile's right-click menu).
    private func deleteLayer(_ layerId: String) {
        guard let (index, layer) = workspaceLayer(layerId) else { return }
        if editLayers("delete '\(layer.label)'", { try $0.deleteLayer(index) }) {
            DiagnosticLog.shared.info("Hyperspace edit — deleted layer \(layer.label)")
        }
        rebuildExposeView()
    }

    /// The ＋ pile's authoring flow: open the New Layer panel seeded with the apps on the active
    /// display (the plucked apps preselected, if any), let the user name it and pick which apps
    /// define it, then save a ⌘⌥ layer of those app rules. A real flow vs the drag-onto-＋ quick path.
    private func presentNewLayer() {
        guard exposed, newLayerPanel == nil,
              let screen = validSurveyScreen(activeSurveyScreen) ?? surveyScreens().first else { return }
        let id = MotionPanel.screenID(screen)
        let members = surveyMembers(on: screen)
        let plucked = Set(pickOrderByScreen[id] ?? [])

        // Unique apps on this display, each with a sample thumbnail + window count, in survey order.
        var order: [String] = []
        var img: [String: NSImage] = [:]
        var count: [String: Int] = [:]
        for w in members {
            if count[w.app] == nil { order.append(w.app) }
            count[w.app, default: 0] += 1
            if img[w.app] == nil, let t = thumbs[w.wid] { img[w.app] = t }
        }
        let candidates = order.map { NewLayerPanel.Candidate(app: $0, image: img[$0], count: count[$0] ?? 0) }
        let pluckedApps = Set(members.filter { plucked.contains($0.wid) }.map(\.app))
        let defaultName = Self.defaultLayerName(forApps: order.filter { pluckedApps.contains($0) })

        ignoreResign = true                         // making the panel key resigns ours — don't exit
        let panel = NewLayerPanel(
            candidates: candidates, preselected: pluckedApps, defaultName: defaultName,
            onCreate: { [weak self] name, apps in
                guard let self else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = trimmed.isEmpty ? "Layer" : trimmed
                let rules = apps.map { LayerProject(clause: StudioLayerClause(appEquals: $0)) }
                self.editLayers("create '\(label)'") { try $0.createLayer(label: label, windows: [], entries: rules) }
                DiagnosticLog.shared.info("Hyperspace — created layer '\(label)' from \(apps.count) app(s)")
                self.finishNewLayer()
                self.rebuildExposeView()            // the new pile appears in the band
            },
            onCancel: { [weak self] in self?.finishNewLayer() })
        newLayerPanel = panel
        panel.present(on: screen)
    }

    private func finishNewLayer() {
        newLayerPanel = nil
        ignoreResign = false
        makeKey()                                   // reclaim key so the survey keeps responding
    }

    /// A friendly default name from the apps that seed the layer.
    private static func defaultLayerName(forApps apps: [String]) -> String {
        switch apps.count {
        case 0:  return "Layer"
        case 1:  return apps[0]
        case 2:  return "\(apps[0]) + \(apps[1])"
        default: return "\(apps[0]) +\(apps.count - 1)"
        }
    }

    // MARK: ⌘⌥ layers

    /// A ⌘⌥ layer by id, with its index.
    private func workspaceLayer(_ id: String) -> (Int, Layer)? {
        let layers = WorkspaceManager.shared.layers
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, layers[index])
    }

    /// The windows a layer holds, on any display.
    private func layerMembers(_ layer: Layer) -> [WindowEntry] {
        WorkspaceManager.shared.memberWindows(of: layer, in: DesktopModel.shared.allWindows()).map(\.entry)
    }

    /// Every ⌘⌥ layer with the windows it holds, on any display, from one
    /// resolution (`LayerMembership`).
    private func resolvedLayers() -> [(layer: Layer, members: [LayerMembership.Member])] {
        let workspace = WorkspaceManager.shared
        let layers = workspace.layers
        let resolution = workspace.layerMembership(in: DesktopModel.shared.allWindows())
        return layers.enumerated().map { index, layer in
            (layer, resolution.layers.indices.contains(index) ? resolution.layers[index] : [])
        }
    }

    /// The entries a pile shows as rules, with each one's index in the layer.
    /// Tab groups and project folders aren't rules and stay out of it.
    private static func ruleEntries(_ layer: Layer) -> [(index: Int, clause: StudioLayerClause)] {
        layer.projects.enumerated().compactMap { index, project in
            project.clause.map { (index, $0) }
        }
    }

    private static func orderedApps(_ windows: [WindowEntry]) -> [String] {
        var seen = Set<String>()
        return windows.map(\.app).filter { seen.insert($0).inserted }
    }

    /// Runs a layer edit, logging and beeping when it can't save.
    @discardableResult
    private func editLayers(_ what: String, _ edit: (WorkspaceManager) throws -> Void) -> Bool {
        do {
            try edit(WorkspaceManager.shared)
            return true
        } catch {
            DiagnosticLog.shared.error("Hyperspace — couldn't \(what): \(error.localizedDescription)")
            NSSound.beep()
            return false
        }
    }

    /// Build the Layers section view-models for a screen: each ⌘⌥ layer as a
    /// pile whose preview is a *screen-map* of its member windows on this display (cheap
    /// per-monitor scoping — same layer can appear on both displays, each showing its
    /// local slice), plus a trailing ＋ pile. A pile reads as "staged" while any window
    /// holds a pending join to it.
    private func layerPiles(on screen: NSScreen) -> [ExposeView.LayerPile] {
        let screenAX = MotionPanel.axRect(of: screen)
        var piles = resolvedLayers().map { layer, held -> ExposeView.LayerPile in
            let onScreen = held.map(\.entry).filter { entry($0, isOn: screen) }
            let members = onScreen.map { w -> ExposeView.LayerMember in
                ExposeView.LayerMember(
                    id: w.wid,
                    frac: MotionPanel.frac(of: layoutFrame(for: freshEntry(w)), in: screenAX),
                    tint: Color(nsColor: MotionPanel.tint(for: w.app)),
                    image: inPlaceMode ? nil : thumbs[w.wid])
            }
            let stagedCount = stagedIntents.values.filter { $0.layers.contains(layer.id) }.count
            let ruleEntries = Self.ruleEntries(layer)
            let rules = ruleEntries.map(\.clause)
            return ExposeView.LayerPile(id: layer.id, name: layer.label, count: onScreen.count,
                                        members: members, rule: rules.map(\.summary).joined(separator: " + "),
                                        clauses: rules,
                                        held: held.map(\.entry),
                                        ruleWindows: ruleEntries.map { rule in
                                            held.filter { $0.project == rule.index }.map(\.entry)
                                        },
                                        isNew: false, staged: stagedCount > 0, stagedCount: stagedCount)
        }
        let newCount = stagedIntents.values.filter { $0.newLayer }.count
        piles.append(ExposeView.LayerPile(id: HyperspaceDrag.newLayerKey, name: "new", count: 0,
                                          isNew: true, staged: newCount > 0, stagedCount: newCount))
        return piles
    }

    /// Latest polled entry for a survey window (DesktopModel refreshes on its own timer).
    private func freshEntry(_ w: WindowEntry) -> WindowEntry {
        DesktopModel.shared.allWindows().first { $0.wid == w.wid } ?? w
    }

    /// Live AX frame when we can resolve it, else the freshest polled CG frame.
    private func layoutFrame(for entry: WindowEntry) -> CGRect {
        if let el = ax(for: entry), let f = RealWindowAnimator.axFrame(el) { return f }
        return layoutCGFrame(for: entry)
    }

    /// Polled CG frame for display maps — matches DesktopModel / inferTilePlacement coords.
    private func layoutCGFrame(for entry: WindowEntry) -> CGRect {
        let fresh = freshEntry(entry)
        return CGRect(x: fresh.frame.x, y: fresh.frame.y, width: fresh.frame.w, height: fresh.frame.h)
    }

    /// Same eligibility rules as the survey, but polled live so moved / raised windows
    /// still appear in Current View without reopening Hyperspace.
    private func liveMembers(on screen: NSScreen) -> [WindowEntry] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        return DesktopModel.shared.allWindows()
            .filter { $0.pid != myPid && $0.isOnScreen && !$0.title.isEmpty }
            .filter { entry($0, isOn: screen) }
    }

    private func layoutSignificantOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        guard !inter.isNull && inter.width > 0 && inter.height > 0 else { return false }
        let interArea = inter.width * inter.height
        let smallerArea = min(a.width * a.height, b.width * b.height)
        guard smallerArea > 0 else { return false }
        return interArea / smallerArea >= 0.15
    }

    /// Cheap hash of on-screen window frames — skip full ExposeView rebuilds when nothing moved.
    private func layoutFingerprint(for screen: NSScreen) -> Int {
        let windows = liveMembers(on: screen)
        var hasher = Hasher()
        hasher.combine(windows.count)
        for w in windows {
            let f = layoutCGFrame(for: w)
            hasher.combine(w.wid)
            hasher.combine(Int64(f.origin.x.rounded()))
            hasher.combine(Int64(f.origin.y.rounded()))
            hasher.combine(Int64(f.width.rounded()))
            hasher.combine(Int64(f.height.rounded()))
        }
        return hasher.finalize()
    }

    /// Every window currently on a screen, as fractional footprints — the Current View's
    /// always-on baseline ("what this display looks like right now"). Uses live members
    /// + CG frames (not the open-time snapshot) and paints back-to-front so frontmost
    /// reads on top; windows covered by a front neighbor are marked `behind`.
    /// Caller must poll DesktopModel first when frames need to be fresh.
    private func currentLayout(on screen: NSScreen) -> [ExposeView.LayerMember] {
        let screenAX = MotionPanel.axRect(of: screen)
        let windows = liveMembers(on: screen).sorted { $0.zIndex < $1.zIndex }
        let frames = windows.map { layoutCGFrame(for: $0) }
        return windows.enumerated().map { i, w in
            let frame = frames[i]
            let behind = (0..<i).contains { j in
                layoutSignificantOverlap(frames[j], frame)
            }
            return ExposeView.LayerMember(
                id: w.wid,
                frac: MotionPanel.frac(of: frame, in: screenAX),
                tint: Color(nsColor: MotionPanel.tint(for: w.app)),
                image: inPlaceMode ? nil : thumbs[w.wid],
                behind: behind)
        }
    }

    /// Project the session's pending geometry into the existing Grid preview.
    private func stagedPlan(on screen: NSScreen) -> [ExposeView.StagedMarker] {
        let screenAX = MotionPanel.axRect(of: screen)
        return surveyMembers(on: screen).compactMap { w -> ExposeView.StagedMarker? in
            let frac: CGRect
            if let frame = pendingLayout?.frames[w.wid] {
                frac = MotionPanel.frac(of: frame, in: screenAX)
            } else if let loc = stagedIntents[w.wid]?.location {
                let f = loc.fractions
                frac = CGRect(x: f.0, y: f.1, width: f.2, height: f.3)
            } else { return nil }
            return ExposeView.StagedMarker(
                id: w.wid,
                frac: frac,
                tint: Color(nsColor: MotionPanel.tint(for: w.app)),
                image: thumbs[w.wid],
                label: stagedLabel(for: w.wid) ?? "")
        }
    }

    /// Swap two windows' live frames in place — no grid staging, no separate flow.
    private func clearPicks(on screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        selection.clear(on: id)
        prunePicks(on: screen)
        rebuildExposeView(screens: [screen])
        updateLegend()
        refreshBorders()
        updateStack()
    }

    private func focusWindow(_ wid: UInt32, on screen: NSScreen) {
        guard let entry = eligible.first(where: { $0.wid == wid }), let el = ax(for: entry) else {
            NSSound.beep()
            return
        }
        raising { RealWindowAnimator.raise(el) }
        DesktopModel.shared.markInteraction(wid: wid)
        DispatchQueue.main.async { [weak self] in self?.makeKey() }
        DiagnosticLog.shared.info("In-place focus — wid=\(wid) app=\(entry.app)")
    }

    /// Immediate tile (explicit menu action) — distinct from staging for Enter.
    private func applyPlacementNow(_ wid: UInt32, _ placement: PlacementSpec, on screen: NSScreen) {
        if exposed && !selectionOnly {
            pendingLayout = .init(title: "Window placement", frames: [wid: WindowTiler.tileFrame(fractions: placement.fractions, on: screen)])
            applyDesktopLayout()
            return
        }
        guard let entry = eligible.first(where: { $0.wid == wid }) else { NSSound.beep(); return }
        if originalFrames[wid] == nil, let el = ax(for: entry), let cur = RealWindowAnimator.axFrame(el) {
            originalFrames[wid] = cur
        }
        raising {
            WindowTiler.tileWindowById(wid: wid, pid: entry.pid, to: placement, on: screen)
        }
        DesktopModel.shared.poll()
        invalidateLayoutFingerprint(for: screen)
        rebuildExposeView(screens: [screen])
        updateLegend()
        refreshBorders()
        DispatchQueue.main.async { [weak self] in self?.makeKey() }
        DiagnosticLog.shared.info("In-place apply — wid=\(wid) \(placement.wireValue)")
    }

    private func swapWindows(widA: UInt32, widB: UInt32, on screen: NSScreen) {
        keptChange = true
        guard widA != widB,
              let entryA = eligible.first(where: { $0.wid == widA }),
              let entryB = eligible.first(where: { $0.wid == widB }) else {
            NSSound.beep()
            return
        }
        DesktopModel.shared.poll()
        let axA = ax(for: entryA)
        let axB = ax(for: entryB)
        let frameA = axA.flatMap { RealWindowAnimator.axFrame($0) } ?? layoutCGFrame(for: entryA)
        let frameB = axB.flatMap { RealWindowAnimator.axFrame($0) } ?? layoutCGFrame(for: entryB)
        if exposed && !selectionOnly {
            pendingLayout = .init(title: "Swap windows", frames: [widA: frameB, widB: frameA])
            applyDesktopLayout()
            return
        }
        if originalFrames[widA] == nil { originalFrames[widA] = frameA }
        if originalFrames[widB] == nil { originalFrames[widB] = frameB }
        raising {
            if let axA, let axB {
                WindowTiler.batchMoveAndRaiseWindows([
                    (wid: widA, pid: entryA.pid, frame: frameB, axWindow: axA),
                    (wid: widB, pid: entryB.pid, frame: frameA, axWindow: axB),
                ])
            } else {
                WindowTiler.batchMoveAndRaiseWindows([
                    (wid: widA, pid: entryA.pid, frame: frameB),
                    (wid: widB, pid: entryB.pid, frame: frameA),
                ])
            }
        }
        let id = MotionPanel.screenID(screen)
        selection.remove([widA, widB], on: id)
        if activeSurveyScreen.map(MotionPanel.screenID) == id {
            prunePicks(on: screen)
        }
        DiagnosticLog.shared.info("Hyperspace swap — \(entryA.app) ↔ \(entryB.app)")
        invalidateLayoutFingerprint(for: screen)
        rebuildExposeView(screens: [screen])
        updateLegend()
        refreshBorders()
        updateStack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.rebuildExposeView(screens: [screen])
        }
    }

    /// Commit the drag & drop intent plan on explicit confirmation. Location
    /// moves the window; layer joins add the window to the ⌘⌥ layer; ＋ piles seed a
    /// fresh layer. (Space axis is Phase 3.) No-op until `stagedIntents` is populated,
    /// so confirmation without pending work is a no-op.
    private func commitStagedIntents(on screen: NSScreen) {
        var newLayerSeeds: [WindowEntry] = []
        for (wid, intent) in stagedIntents where !intent.isEmpty {
            guard let entry = eligible.first(where: { $0.wid == wid }) else { continue }
            if let placement = intent.location {
                if originalFrames[wid] == nil, let el = ax(for: entry),
                   let cur = RealWindowAnimator.axFrame(el) {
                    originalFrames[wid] = cur
                }
                WindowTiler.tileWindowById(wid: wid, pid: entry.pid, to: placement, on: screen)
                didMoveWindows = true        // a real move → Esc must restore
            }
            for layerID in intent.layers {
                guard let (index, layer) = workspaceLayer(layerID) else { continue }
                editLayers("add to '\(layer.label)'") { try $0.addWindows([entry], toLayer: index) }
            }
            if intent.newLayer { newLayerSeeds.append(entry) }
            // Phase 3: intent.space → WindowTiler.moveViaCGS
        }
        if !newLayerSeeds.isEmpty {
            let name = Self.defaultLayerName(forApps: Self.orderedApps(newLayerSeeds))
            editLayers("create '\(name)'") { try $0.createLayer(label: name, windows: newLayerSeeds) }
            DiagnosticLog.shared.info("Hyperspace commit — new layer '\(name)' from \(newLayerSeeds.count) window(s)")
        }
    }

    /// Grid is a reversible live preview in either presentation. Staged placements
    /// and layer changes stay pending until Return / Keep, including after a view
    /// switch. Windows with explicit staged placements are excluded from the grid.
    private func gatherInPlace() {
        if exposed && !selectionOnly { proposeDesktopLayout(); return }
        let screen = activeSurveyScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let members = gatherMembers()
        if members.count >= 2 {
            relayoutGroup()                                       // picked set snaps into the grid, on top
        } else if let only = members.first, let el = ax(for: only) {
            raising { RealWindowAnimator.raise(el) }              // a single pick just comes forward
        }
        if inPlaceMode {
            refreshAfterGridMove(on: screen)
            return
        }
        removeExposeHost()
        exposed = false
        ignoresMouseEvents = false
        updateLegend()
        refreshBorders()
        updateStack()
    }

    private func gatherInPlace(on screen: NSScreen) {
        setActiveSurveyScreen(screen)
        gatherInPlace()
    }

    private func gatherAndExit(on screen: NSScreen?) {
        if let screen {
            setActiveSurveyScreen(screen)
            commitStagedIntents(on: screen)
            gatherInPlace()
        }
        onExit?()
    }

    // MARK: - Clustering

    /// Group the survey windows into clusters: the user's own rules first (a
    /// cluster is a named rule — see ~/.lattices/clusters.json), then everything
    /// left over smart-clustered by app. Tint stays per-app; the cluster is an
    /// independent grouping axis.
    private func buildClusters(_ members: [WindowEntry]) -> [ExposeCluster] {
        var remaining = members
        var boxes: [ExposeCluster] = []
        var id = 0

        for rule in clusterRules {
            let matched = remaining.filter { rule.matches($0) }
            guard !matched.isEmpty else { continue }
            boxes.append(ExposeCluster(id: id, name: rule.name, rule: rule.summary, userDefined: true, members: matched))
            id += 1
            let matchedIds = Set(matched.map { $0.wid })
            remaining.removeAll { matchedIds.contains($0.wid) }
        }

        let byApp = Dictionary(grouping: remaining) { $0.app }
        let apps = byApp.keys.sorted {
            let a = byApp[$0]?.map(\.zIndex).min() ?? Int.max
            let b = byApp[$1]?.map(\.zIndex).min() ?? Int.max
            return a == b ? $0 < $1 : a < b
        }
        for app in apps {
            let ms = (byApp[app] ?? []).sorted { $0.title < $1.title }
            boxes.append(ExposeCluster(id: id, name: app, rule: "app", userDefined: false, members: ms))
            id += 1
        }
        return boxes
    }

    /// Letters the survey reserves for commands, so no tile or cluster is ever dealt
    /// one (E = overview, G = gather, F = fill, S = swap — see keyDown, where their
    /// keycodes are matched before the hint logic). Kept out of every hint pool below,
    /// so the shifted letters carry no cluster meaning and the bare keys always mean
    /// their command.
    private static let reservedKeys: Set<Character> = ["e", "g", "f", "s"]

    private func resetSurveyState(for screens: [NSScreen]) {
        let validIDs = Set(screens.map(MotionPanel.screenID))
        selection.retainDisplays(validIDs)
        exposeClustersByScreen.removeAll()
        exposeOrderByScreen.removeAll()
        exposeAimByScreen.removeAll()
        hintForByScreen.removeAll()
        hintMapByScreen.removeAll()
        clusterHintForByScreen.removeAll()
        clusterHintMapByScreen.removeAll()
        exposeTileWByScreen.removeAll()
        exposeFramesByScreen.removeAll()
        clusterSearchQueryByScreen = clusterSearchQueryByScreen.filter { validIDs.contains($0.key) }
        activeClusterSearchByScreen = activeClusterSearchByScreen.filter { validIDs.contains($0.key) }
        canvasByScreenID = canvasByScreenID.filter { validIDs.contains($0.key) }
    }

    private func rebuildSurveyState(for screen: NSScreen, resetAim: Bool = false) {
        let id = MotionPanel.screenID(screen)
        let members = surveyMembers(on: screen)
        let clusters = buildClusters(members)
        let order = clusters.flatMap { $0.members.map(\.wid) }
        let oldAim = exposeAimByScreen[id] ?? 0
        let frames = exposeFramesByScreen[id] ?? [:]
        let (hf, hm) = (handKeysMode && frames.count >= order.count)
            ? computeHandHints(order: order, frames: frames)
            : readingHints(for: order)
        let (chf, chm) = clusterHints(for: clusters)

        exposeClustersByScreen[id] = clusters
        exposeOrderByScreen[id] = order
        exposeAimByScreen[id] = resetAim ? 0 : min(oldAim, max(order.count - 1, 0))
        hintForByScreen[id] = hf
        hintMapByScreen[id] = hm
        clusterHintForByScreen[id] = chf
        clusterHintMapByScreen[id] = chm
        exposeTileWByScreen[id] = autoTileWidth(count: members.count, screen: screen)

        let clusterIDs = Set(clusters.map(\.id))
        clusterSearchQueryByScreen[id] = (clusterSearchQueryByScreen[id] ?? [:])
            .filter { clusterIDs.contains($0.key) }
        if let activeID = activeClusterSearchByScreen[id], !clusterIDs.contains(activeID) {
            activeClusterSearchByScreen[id] = nil
        }

        let memberIDs = Set(members.map(\.wid))
        selection.retainWindows(memberIDs, on: id)
    }

    private func syncActiveSurveyState(from screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        exposeClusters = exposeClustersByScreen[id] ?? []
        exposeOrder = exposeOrderByScreen[id] ?? []
        exposeAim = exposeAimByScreen[id] ?? 0
        hintFor = hintForByScreen[id] ?? [:]
        hintMap = hintMapByScreen[id] ?? [:]
        clusterHintFor = clusterHintForByScreen[id] ?? [:]
        clusterHintMap = clusterHintMapByScreen[id] ?? [:]
        exposeTileW = exposeTileWByScreen[id] ?? autoTileWidth(count: surveyMembers(on: screen).count, screen: screen)
        exposeFrames = exposeFramesByScreen[id] ?? [:]
        prunePicks(on: screen)
    }

    private func readingHints(for order: [UInt32]) -> ([UInt32: String], [String: UInt32]) {
        let homerow = Array("asdfghjklqwertyuiopzxcvbnm").filter { !MotionPanel.reservedKeys.contains($0) }
        var hf: [UInt32: String] = [:], hm: [String: UInt32] = [:]
        for (i, wid) in order.enumerated() where i < homerow.count {
            let h = String(homerow[i]); hf[wid] = h; hm[h] = wid
        }
        return (hf, hm)
    }

    private func computeHandHints(order: [UInt32], frames: [UInt32: CGRect]) -> ([UInt32: String], [String: UInt32]) {
        let rightKeys = Array("jkluiophynm;").filter  { !MotionPanel.reservedKeys.contains($0) }
        let leftKeys  = Array("fdsarewqgtvcxzb").filter { !MotionPanel.reservedKeys.contains($0) }
        let placed = order.compactMap { wid in frames[wid].map { (wid: wid, rect: $0) } }
        guard !placed.isEmpty else { return readingHints(for: order) }
        let mids = placed.map { $0.rect.midX }
        let mid = (mids.min()! + mids.max()!) / 2
        func sortKey(_ r: CGRect) -> (CGFloat, CGFloat) { (abs(r.midX - mid), r.minY) }
        let left  = placed.filter { $0.rect.midX <= mid }.sorted { sortKey($0.rect) < sortKey($1.rect) }
        let right = placed.filter { $0.rect.midX >  mid }.sorted { sortKey($0.rect) < sortKey($1.rect) }
        var hf: [UInt32: String] = [:], hm: [String: UInt32] = [:]
        for (i, t) in left.enumerated()  where i < leftKeys.count  { let h = String(leftKeys[i]);  hf[t.wid] = h; hm[h] = t.wid }
        for (i, t) in right.enumerated() where i < rightKeys.count { let h = String(rightKeys[i]); hf[t.wid] = h; hm[h] = t.wid }
        return (hf, hm)
    }

    private func clusterHints(for clusters: [ExposeCluster]) -> ([Int: String], [String: Int]) {
        var hf: [Int: String] = [:], hm: [String: Int] = [:]
        var used = Set<String>()
        let alphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        for box in clusters {
            let fromName = box.name.lowercased().filter { $0.isLetter }.map(String.init)
            guard let letter = (fromName + alphabet).first(where: {
                !used.contains($0) && !MotionPanel.reservedKeys.contains(Character($0))
            }) else { continue }
            used.insert(letter)
            hf[box.id] = letter.uppercased()
            hm[letter] = box.id
        }
        return (hf, hm)
    }

    /// Assign the spread's layout order and per-window hint letters. Two schemes:
    /// reading-order (clusters in display order) or — when hand-keys mode is on and
    /// we know where the tiles landed — a spatial split where left-of-centre tiles
    /// take left-hand keys and right-of-centre tiles take right-hand keys, each
    /// dealt centre→edge so the strongest fingers land the most central windows.
    /// ⇧-letter cluster plucks are assigned separately (own, shifted key space).
    private func assignHints() {
        exposeOrder = exposeClusters.flatMap { $0.members.map(\.wid) }
        exposeAim = 0
        (hintFor, hintMap) = (handKeysMode && exposeFrames.count >= exposeOrder.count)
            ? computeHandHints(exposeFrames) : readingHints()
        assignClusterHints()
    }

    /// Home-row letters dealt in display order — the original scheme.
    private func readingHints() -> ([UInt32: String], [String: UInt32]) {
        let homerow = Array("asdfghjklqwertyuiopzxcvbnm").filter { !MotionPanel.reservedKeys.contains($0) }
        var hf: [UInt32: String] = [:], hm: [String: UInt32] = [:]
        for (i, wid) in exposeOrder.enumerated() where i < homerow.count {
            let h = String(homerow[i]); hf[wid] = h; hm[h] = wid
        }
        return (hf, hm)
    }

    /// Spatial hand-split letters. Tiles left of the spread's mid-line get left-hand
    /// keys, the rest right-hand keys; within a hand they're dealt centre→edge so the
    /// key location predicts the window's location. Needs the laid-out tile frames.
    private func computeHandHints(_ frames: [UInt32: CGRect]) -> ([UInt32: String], [String: UInt32]) {
        let rightKeys = Array("jkluiophynm;").filter  { !MotionPanel.reservedKeys.contains($0) }   // right hand, centre → edge
        let leftKeys  = Array("fdsarewqgtvcxzb").filter { !MotionPanel.reservedKeys.contains($0) }  // left hand,  centre → edge (e/g reserved)
        let placed = exposeOrder.compactMap { wid in frames[wid].map { (wid: wid, rect: $0) } }
        guard !placed.isEmpty else { return readingHints() }
        let mids = placed.map { $0.rect.midX }
        let mid = (mids.min()! + mids.max()!) / 2
        func sortKey(_ r: CGRect) -> (CGFloat, CGFloat) { (abs(r.midX - mid), r.minY) }
        let left  = placed.filter { $0.rect.midX <= mid }.sorted { sortKey($0.rect) < sortKey($1.rect) }
        let right = placed.filter { $0.rect.midX >  mid }.sorted { sortKey($0.rect) < sortKey($1.rect) }
        var hf: [UInt32: String] = [:], hm: [String: UInt32] = [:]
        for (i, t) in left.enumerated()  where i < leftKeys.count  { let h = String(leftKeys[i]);  hf[t.wid] = h; hm[h] = t.wid }
        for (i, t) in right.enumerated() where i < rightKeys.count { let h = String(rightKeys[i]); hf[t.wid] = h; hm[h] = t.wid }
        return (hf, hm)
    }

    /// Recompute per-window hints after the spread lays out, or when the mode flips.
    /// Idempotent — only rebuilds the view if the letters actually changed.
    private func reassignHandHints() {
        guard let screen = activeSurveyScreen else { return }
        reassignHandHints(on: screen)
    }

    @discardableResult
    private func reassignHandHints(on screen: NSScreen, rebuild: Bool = true) -> Bool {
        guard exposed else { return false }
        let id = MotionPanel.screenID(screen)
        let order = exposeOrderByScreen[id] ?? []
        let frames = exposeFramesByScreen[id] ?? [:]
        let (hf, hm) = (handKeysMode && frames.count >= order.count)
            ? computeHandHints(order: order, frames: frames)
            : readingHints(for: order)
        guard hf != hintForByScreen[id] else { return false }
        hintForByScreen[id] = hf
        hintMapByScreen[id] = hm
        if activeSurveyScreen.map(MotionPanel.screenID) == id {
            hintFor = hf
            hintMap = hm
        }
        if rebuild { rebuildExposeView(screens: [screen]) }
        return true
    }

    /// Per-cluster shortcut: ⇧+letter plucks the whole group at once (e.g. ⇧I →
    /// every iTerm). Prefer a letter from the cluster's name so it's guessable,
    /// falling back to the next free letter. Lives in its own (shifted) key space,
    /// so it never collides with the lowercase per-window hints above.
    private func assignClusterHints() {
        clusterHintFor.removeAll(); clusterHintMap.removeAll()
        var used = Set<String>()
        let alphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        for box in exposeClusters {
            let fromName = box.name.lowercased().filter { $0.isLetter }.map(String.init)
            guard let letter = (fromName + alphabet).first(where: {
                !used.contains($0) && !MotionPanel.reservedKeys.contains(Character($0))
            }) else { continue }
            used.insert(letter)
            clusterHintFor[box.id] = letter.uppercased()
            clusterHintMap[letter] = box.id
        }
    }

    /// Pick a tile width that fills the survey: few windows zoom in, many zoom out.
    /// A free-grid fit over the display's working area — try every column count and
    /// keep the width that best uses both axes — then a packing margin and clamps so
    /// the clustered layout (a little less dense than a bare grid) still fits cleanly.
    /// Height of the top intent band on a given display. Shared by the survey
    /// fit (so tiles never run under the band) and ExposeView (which draws it).
    private func bandHeight(for screen: NSScreen) -> CGFloat {
        if inPlaceMode { return 0 }
        if !selectionOnly { return 0 }
        // Reserve a touch under the top third for the intent band so the survey
        // grid gets the bottom ~2/3 (design/hyperspace-drag-drop.md). Floored so the
        // Layers/Lattice/Spaces cards still fit on a short display, capped so it
        // doesn't bloat on a tall external one.
        return max(196, min(screen.frame.height * 0.30, 420))
    }

    private func autoTileWidth(count n: Int, screen: NSScreen) -> CGFloat {
        let area = screen.frame
        let pad: CGFloat = 72            // 36pt survey padding each side
        let availW = max(200, area.width - pad)
        let controlsHeight: CGFloat = selectionOnly ? 44 : 112
        let availH = max(200, area.height - pad - bandHeight(for: screen) - controlsHeight)
        let aspect: CGFloat = 0.62       // tile height / width
        let gap: CGFloat = 26            // tile gaps + cluster chrome, averaged
        let count = max(1, n)
        var best: CGFloat = 0
        let maxCols = max(1, min(count, Int(availW / 150)))
        for cols in 1...maxCols {
            let rows = Int((Double(count) / Double(cols)).rounded(.up))
            let w = (availW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (availH - gap * CGFloat(rows - 1)) / CGFloat(rows)
            best = max(best, min(w, h / aspect))
        }
        // Packing margin: sit the survey a little inside the fill so there's air
        // around the lattice — the extra room reads as perspective, not a wall of tiles.
        return min(max((best * 0.74).rounded(), 150), 520)
    }

    private static func loadClusterRules() -> [ClusterRule] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lattices/clusters.json")
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([ClusterRule].self, from: data) else { return [] }
        return rules
    }

    // MARK: - Survey overlay (SwiftUI spread)

    private func installExposeHosts() {
        guard !dismissed else { return }   // never re-create panels after teardown (orphan guard)
        removeExposeHost()
        for screen in surveyScreens() {
            let id = MotionPanel.screenID(screen)
            let placeholder = ExposeView(
                clusters: [],
                tileWidth: autoTileWidth(count: max(1, surveyMembers(on: screen).count), screen: screen),
                canvas: canvasForScreen(screen),
                drag: dragModel,
                screenID: id,
                bandHeight: bandHeight(for: screen),
                inPlace: inPlaceMode,
                unifiedChrome: !selectionOnly,
                screenAspect: screen.visibleFrame.width / max(1, screen.visibleFrame.height),
                usableInset: MotionPanel.usableInset(of: screen),
                onSnapshot: { [weak self] completion in
                    guard let self else { completion("In-place tools closed"); return }
                    self.captureInPlaceSnapshot(on: screen, completion: completion)
                },
                onCancel: { [weak self] in self?.undoAndExit() },
                onKeep: { [weak self] in self?.finishDesktopSession(on: screen) },
                onNewLayer: { [weak self] in self?.presentNewLayer() })
            let hosting: NSHostingView<ExposeView>
            if inPlaceMode {
                let inPlaceHost = InPlaceHostingView(rootView: placeholder)
                inPlaceHost.panel = self
                inPlaceHost.screen = screen
                hosting = inPlaceHost
            } else {
                hosting = NSHostingView(rootView: placeholder)
            }
            // Screen overlays follow the display, not SwiftUI's intrinsic
            // content size. Match the HUD hosts so a large survey cannot grow
            // the panel past the display and displace its bottom controls.
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            let panel = HyperspaceScreenPanel(screen: screen)
            if inPlaceMode {
                hosting.wantsLayer = true
                hosting.layer?.backgroundColor = NSColor.clear.cgColor
                let container = HyperspacePassThroughView(frame: hosting.frame)
                let dim = HyperspaceDimView(frame: container.bounds)
                dim.autoresizingMask = [.width, .height]
                container.addSubview(dim)
                container.addSubview(hosting)
                if !selectionOnly {
                    let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                    let selectionFrame = HyperspaceSelectionFrame(frame: container.bounds, usableFrame: visible)
                    selectionFrame.autoresizingMask = [.width, .height]
                    container.addSubview(selectionFrame)
                    selectionFrameByScreenID[id] = selectionFrame
                    selectionFrame.onSuggestion = { [weak self] index in self?.commitCommandLine(choosing: index) }
                }
                panel.contentView = container
                desktopDimByScreenID[id] = dim
            } else {
                panel.contentView = hosting
            }
            panel.orderFrontRegardless()
            exposeHostsByScreenID[id] = hosting
            exposePanelsByScreenID[id] = panel
        }
        exposeHost = activeSurveyScreen.flatMap { exposeHostsByScreenID[MotionPanel.screenID($0)] }
    }

    /// Poll DesktopModel and refresh Current View outlines while the survey is open.
    private func startLayoutRefresh() {
        stopLayoutRefresh()
        let interval: TimeInterval = inPlaceMode ? 1.5 : 0.75
        layoutRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshLiveLayoutIfChanged()
        }
    }

    /// Timer tick: poll once, rebuild only when a window actually moved or resized.
    private func refreshLiveLayoutIfChanged() {
        guard exposed, !dismissed, !dragModel.isActive else { return }
        DesktopModel.shared.poll()
        var changedScreens: [NSScreen] = []
        for screen in surveyScreens() {
            let id = MotionPanel.screenID(screen)
            let fp = layoutFingerprint(for: screen)
            if layoutFingerprintByScreen[id] != fp {
                layoutFingerprintByScreen[id] = fp
                changedScreens.append(screen)
            }
        }
        if !changedScreens.isEmpty {
            rebuildExposeView(screens: changedScreens)
            if inPlaceMode { refreshBorders() }
        }
    }

    private func invalidateLayoutFingerprint(for screen: NSScreen) {
        layoutFingerprintByScreen.removeValue(forKey: MotionPanel.screenID(screen))
    }

    private func stopLayoutRefresh() {
        layoutRefreshTimer?.invalidate()
        layoutRefreshTimer = nil
    }

    private func cancelCaptureRebuilds() {
        captureRebuildWorkItemsByScreenID.values.forEach { $0.cancel() }
        captureRebuildWorkItemsByScreenID.removeAll()
    }

    private func removeExposeHost() {
        cancelCaptureRebuilds()
        exposePanelsByScreenID.values.forEach { $0.close() }
        exposePanelsByScreenID.removeAll()
        desktopDimByScreenID.removeAll()
        selectionFrameByScreenID.removeAll()
        commandLineState = nil
        exposeHostsByScreenID.values.forEach { $0.removeFromSuperview() }
        exposeHostsByScreenID.removeAll()
        exposeHost = nil
    }

    /// Rebuild the spread's view-model from current picks/aim/captures. Cheap —
    /// the cluster *structure* is fixed for the life of a survey; only the per-tile
    /// pick slot, highlight, and image change. In-place mode can target one screen
    /// to avoid rebuilding every monitor on each pick.
    private func rebuildExposeView(screens: [NSScreen]? = nil) {
        guard exposed else { return }
        // Replacing host.rootView mid-drag would tear down the in-flight SwiftUI
        // gesture and abort the drag. Skip while a drag is live; handleDrop()
        // rebuilds once it ends.
        guard !dragModel.isActive else { return }
        let rebuildT0 = CACurrentMediaTime()
        defer {
            updateDesktopHUD()
            refreshLayoutPreview()
            let ms = (CACurrentMediaTime() - rebuildT0) * 1000
            loadTrace?.bump("rebuild.count")
            loadTrace?.record("rebuildView", ms: ms, warnAbove: 24)
        }
        if exposeHostsByScreenID.isEmpty { installExposeHosts() }
        exposeHost = activeSurveyScreen.flatMap { exposeHostsByScreenID[MotionPanel.screenID($0)] }

        let targets = screens ?? surveyScreens()
        for screen in targets {
            rebuildExposeScreen(screen)
        }
    }

    private func rebuildExposeScreen(_ screen: NSScreen) {
            let id = MotionPanel.screenID(screen)
            let generation = presentationGeneration
            guard let host = exposeHostsByScreenID[id] else { return }
            let members = surveyMembers(on: screen)
            if exposeClustersByScreen[id] == nil {
                rebuildSurveyState(for: screen, resetAim: true)
            }
            let clusters = exposeClustersByScreen[id] ?? []
            let screenHintFor = hintForByScreen[id] ?? [:]
            let screenClusterHintFor = clusterHintForByScreen[id] ?? [:]
            let searchQueries = clusterSearchQueryByScreen[id] ?? [:]
            let activeSearchID = activeClusterSearchByScreen[id]
            let vm = clusters.map { box in
                ExposeView.Cluster(
                    id: box.id,
                    name: box.name,
                    rule: box.rule,
                    userDefined: box.userDefined,
                    hint: screenClusterHintFor[box.id] ?? "",
                    searchQuery: searchQueries[box.id] ?? "",
                    searchActive: activeSearchID == box.id,
                    tiles: box.members.map { tileVM($0, on: screen, hints: screenHintFor) }
                )
            }
            host.rootView = ExposeView(
                clusters: vm,
                tileWidth: exposeTileWByScreen[id] ?? autoTileWidth(count: members.count, screen: screen),
                canvas: canvasForScreen(screen),
                drag: dragModel,
                screenID: id,
                bandHeight: bandHeight(for: screen),
                inPlace: inPlaceMode,
                unifiedChrome: !selectionOnly,
                screenAspect: screen.visibleFrame.width / max(1, screen.visibleFrame.height),
                usableInset: MotionPanel.usableInset(of: screen),
                onPick: { [weak self] wid in
                    guard let self else { return }
                    self.keyboardBrowsing = false
                    if self.selectionOnly { self.completeWindowPick(wid) }
                    else { self.exposeToggle(wid, on: screen) }
                },
                onDrop: { [weak self] wid, spec in
                    guard let self, !self.selectionOnly else { return }
                    self.handleDrop(wid, spec)
                },
                onDropGridGroup: { [weak self] wids, res, anchor in
                    guard let self, !self.selectionOnly else { return }
                    self.handleGridGroupDrop(wids, res: res, anchor: anchor)
                },
                onPlaceOnGrid: { [weak self] col, row, res in
                    guard let self, !self.selectionOnly else { return }
                    self.placeSelectionOnGrid(col: col, row: row, res: res, on: screen)
                },
                onDropLayer: { [weak self] wid, key in
                    guard let self, !self.selectionOnly else { return }
                    self.handleLayerDrop(wid, key)
                },
                onDropLayers: { [weak self] wids, key in
                    guard let self, !self.selectionOnly else { return }
                    self.handleLayerDrops(wids, key)
                },
                onSwap: { [weak self] a, b in
                    guard let self, !self.selectionOnly else { return }
                    self.swapWindows(widA: a, widB: b, on: screen)
                },
                onGridSelection: { [weak self] in
                    guard let self, !self.selectionOnly else { return }
                    self.gatherInPlace(on: screen)
                },
                onStackSelection: { [weak self] in
                    guard let self, !self.selectionOnly else { return }
                    self.createLiveTabsFromSelection(on: screen)
                },
                onSwapFirstTwo: { [weak self] in
                    guard let self, !self.selectionOnly, let a = self.pickOrderByScreen[id]?[safe: 0],
                          let b = self.pickOrderByScreen[id]?[safe: 1] else { NSSound.beep(); return }
                    self.swapWindows(widA: a, widB: b, on: screen)
                },
                onSwapWith: { [weak self] a, b in
                    guard let self, !self.selectionOnly else { return }
                    self.swapWindows(widA: a, widB: b, on: screen)
                },
                onFocusWindow: { [weak self] wid in
                    guard let self else { return }
                    if self.selectionOnly { self.completeWindowPick(wid) }
                    else { self.focusWindow(wid, on: screen) }
                },
                onClearSelection: { [weak self] in
                    guard let self, !self.selectionOnly else { return }
                    self.clearPicks(on: screen)
                },
                onApplyPlacement: { [weak self] wid, spec in
                    guard let self, !self.selectionOnly else { return }
                    self.applyPlacementNow(wid, spec, on: screen)
                },
                onFillAvailable: { [weak self] wid in
                    guard let self, !self.selectionOnly else { return }
                    self.fillAvailableSpace(for: wid)
                },
                onOpenHyperspace: { [weak self] in
                    guard let self, !self.selectionOnly, !self.dismissed else { NSSound.beep(); return }
                    WindowMotionMode.shared.showHyperspace()
                },
                onSnapshot: { [weak self] completion in
                    guard let self else { completion("In-place tools closed"); return }
                    self.captureInPlaceSnapshot(on: screen, completion: completion)
                },
                onCancel: { [weak self] in self?.undoAndExit() },
                onKeep: { [weak self] in self?.finishDesktopSession(on: screen) },
                layers: layerPiles(on: screen),
                stagedPlan: stagedPlan(on: screen),
                hasLayoutProposal: pendingLayout != nil,
                currentLayout: currentLayout(on: screen),
                pickedWids: Set(pickOrderByScreen[id] ?? []),
                pickedOrder: pickOrderByScreen[id] ?? [],
                layoutArea: desktopArea(on: screen),
                screenAX: MotionPanel.axRect(of: screen),
                layoutPreview: pendingLayout,
                onChooseLayout: { [weak self] ids, plan in
                    guard let self, !self.selectionOnly else { return }
                    self.chooseOverviewLayout(ids, plan: plan, on: screen)
                },
                onPlaceInProposal: { [weak self] ids, update in
                    guard let self, !self.selectionOnly else { return }
                    self.placeInProposal(ids, update, on: screen)
                },
                canCycleLayout: self.canCycleLayout,
                layoutCycleTitle: self.layoutCycleTitle,
                onCycleLayout: { [weak self] in
                    guard let self, !self.selectionOnly else { return }
                    self.cycleOverviewLayout(on: screen)
                },
                hasSessionChanges: didMoveWindows,
                displayScope: exposeDisplayScope(for: screen),
                onLayout: { [weak self] frames in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.exposed, !self.dismissed, self.presentationGeneration == generation,
                              frames != self.exposeFramesByScreen[id] else { return }
                        self.exposeFramesByScreen[id] = frames
                        if self.handKeysMode { self.reassignHandHints(on: screen) }
                    }
                },
                onHandKeys: { [weak self] on in
                    guard let self, !self.selectionOnly else { NSSound.beep(); return }
                    self.handKeysMode = on
                    let changed = self.surveyScreens().filter {
                        self.reassignHandHints(on: $0, rebuild: false)
                    }
                    guard !changed.isEmpty else { return }
                    if self.inPlaceMode {
                        self.rebuildExposeView(screens: changed)
                    } else {
                        self.rebuildExposeView()
                    }
                },
                onExit: { [weak self] in self?.onExit?() },   // ✕ — leave, keep what's on screen
                onNewLayer: { [weak self] in
                    guard let self, !self.selectionOnly else { NSSound.beep(); return }
                    self.presentNewLayer()
                },
                onRecallLayer: { [weak self] id in self?.pluckLayer(id, on: screen) },
                onBeginClusterSearch: { [weak self] cid in self?.activateClusterSearch(cid, on: screen) },
                onClearClusterSearch: { [weak self] cid in self?.clearClusterSearch(cid, on: screen) },
                onPluckGroup: { [weak self] cid in self?.exposeToggleCluster(cid, on: screen) },
                onFocusCluster: { [weak self] cid in self?.focusClusterApp(cid, on: screen) },
                onQuitCluster: { [weak self] cid in self?.quitClusterApp(cid, on: screen) },
                onEditClause: { [weak self] id, idx, clause in
                    guard let self, !self.selectionOnly else { NSSound.beep(); return }
                    self.presentLayerRuleEditor(id, idx, clause, on: screen)
                },
                onRemoveClause: { [weak self] id, idx in
                    guard let self, !self.selectionOnly else { NSSound.beep(); return }
                    self.removeLayerClause(id, idx)
                },
                onDeleteLayer: { [weak self] id in
                    guard let self, !self.selectionOnly else { NSSound.beep(); return }
                    self.deleteLayer(id)
                },
                loadSummary: loadSummaryText())
    }

    /// Compact load readout for the survey: time-to-first-paint and time-to-all-
    /// captures, both measured from the Hyper+Space trigger. "…" until the mark lands.
    private func loadSummaryText() -> String {
        guard loadStart > 0 else { return "" }
        func ms(_ t: CFTimeInterval) -> String { t > 0 ? "\(Int(((t - loadStart) * 1000).rounded()))" : "…" }
        return "up \(ms(firstPaintAt))ms · caps \(ms(capturesAt))ms·\(captureCount)"
    }

    private func tileVM(_ w: WindowEntry) -> ExposeView.Tile {
        ExposeView.Tile(
            id: w.wid, app: w.app, title: w.title,
            tint: Color(nsColor: MotionPanel.tint(for: w.app)),
            image: thumbs[w.wid],
            hint: hintFor[w.wid] ?? "",
            pickSlot: pickOrder.firstIndex(of: w.wid).map { $0 + 1 },
            isAimed: (selectionOnly || keyboardBrowsing) && exposeOrder[safe: exposeAim] == w.wid
        )
    }

    private func tileVM(_ w: WindowEntry, on screen: NSScreen, hints: [UInt32: String]) -> ExposeView.Tile {
        let id = MotionPanel.screenID(screen)
        let savedOrder = pickOrderByScreen[id] ?? []
        let order = exposeOrderByScreen[id] ?? []
        let aim = exposeAimByScreen[id] ?? 0
        return ExposeView.Tile(
            id: w.wid, app: w.app, title: w.title,
            tint: Color(nsColor: MotionPanel.tint(for: w.app)),
            image: thumbs[w.wid],
            hint: hints[w.wid] ?? "",
            pickSlot: savedOrder.firstIndex(of: w.wid).map { $0 + 1 },
            isAimed: (selectionOnly || keyboardBrowsing) && order[safe: aim] == w.wid,
            appIcon: NSRunningApplication(processIdentifier: w.pid)?.icon,
            staged: stagedLabel(for: w.wid),
            layerTags: layerTags(for: w.wid)
        )
    }

    /// Names of the layers a window is staged to join (plus "new" for a staged ＋),
    /// shown as labels along the tile's bottom. Empty when nothing layer-ish is staged.
    private func layerTags(for wid: UInt32) -> [String] {
        guard let intent = stagedIntents[wid] else { return [] }
        let names = WorkspaceManager.shared.layers
            .filter { intent.layers.contains($0.id) }
            .map(\.label)
        return intent.newLayer ? names + ["new"] : names
    }

    /// Compact badge for a window's staged *location*, e.g. "¼ 1,0". Layer membership
    /// is shown separately as bottom labels (see layerTags) — a tag, not a move.
    private func stagedLabel(for wid: UInt32) -> String? {
        if let plan = pendingLayout, plan.frames[wid] != nil { return plan.title }
        guard let loc = stagedIntents[wid]?.location else { return nil }
        if case let .grid(g) = loc {
            return "\(LatticeRes.glyph(cols: g.columns, rows: g.rows)) \(g.column),\(g.row)"
        }
        return loc.wireValue
    }

    /// Pluck a tile by wid (hint key or click) and refresh the survey + minimap.
    private func exposeToggle(_ wid: UInt32) {
        togglePicked(wid)
        aimWindow(wid)
        rebuildExposeView()
        updateLegend()
        updateStack()
    }

    private func exposeToggle(_ wid: UInt32, on screen: NSScreen, keepProposal: Bool = false) {
        if !keepProposal {
            pendingLayout = nil
            layoutLocked = false
            layoutPreview.clear()
        }
        aimWindow(wid, on: screen)
        let id = MotionPanel.screenID(screen)
        if selection.toggle(wid, on: id),
           let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        let memberIDs = Set(surveyMembers(on: screen).map(\.wid))
        selection.retainWindows(memberIDs, on: id)
        if activeSurveyScreen.map(MotionPanel.screenID) != id {
            setActiveSurveyScreen(screen)
        } else {
            prunePicks(on: screen)
        }
        if inPlaceMode {
            rebuildExposeView(screens: [screen])
        } else {
            rebuildExposeView()
        }
        updateLegend()
        refreshBorders()
        updateStack()
    }

    /// ⇧+letter — pluck a whole cluster at once (e.g. all iTerms). If the group is
    /// already fully picked it unplucks the group; otherwise it adds the members
    /// that aren't picked yet. Toggling on the "all-picked" state makes the same key
    /// select then clear the group.
    private func exposeToggleCluster(_ id: Int) {
        guard let box = exposeClusters.first(where: { $0.id == id }) else { NSSound.beep(); return }
        let wids = box.members.map { $0.wid }
        guard !wids.isEmpty else { return }
        let added = selection.toggleGroup(wids, on: activeSelectionScreenID)
        for wid in added {
            if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        }
        pruneActivePicks()
        rebuildExposeView()
        updateLegend()
        updateStack()
    }

    private func exposeToggleCluster(_ clusterID: Int, on screen: NSScreen) {
        keyboardBrowsing = false
        pendingLayout = nil
        layoutPreview.clear()
        let screenID = MotionPanel.screenID(screen)
        guard let box = exposeClustersByScreen[screenID]?.first(where: { $0.id == clusterID }) else {
            NSSound.beep()
            return
        }
        let wids = box.members.map { $0.wid }
        guard !wids.isEmpty else { return }
        let added = selection.toggleGroup(wids, on: screenID)
        for wid in added {
            if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        }
        if activeSurveyScreen.map(MotionPanel.screenID) != screenID {
            setActiveSurveyScreen(screen)
        } else {
            prunePicks(on: screen)
        }
        rebuildExposeForScreenInteraction(on: screen)
        updateLegend()
        refreshBorders()
        updateStack()
    }

    private func focusClusterApp(_ clusterID: Int, on screen: NSScreen) {
        let screenID = MotionPanel.screenID(screen)
        guard let box = exposeClustersByScreen[screenID]?.first(where: { $0.id == clusterID }),
              let entry = box.members.first else {
            NSSound.beep()
            return
        }
        NSRunningApplication(processIdentifier: pid_t(entry.pid))?.activate()
        focusWindow(entry.wid, on: screen)
        DiagnosticLog.shared.info("Hyperspace focus — cluster \(box.name) app=\(entry.app)")
    }

    private func quitClusterApp(_ clusterID: Int, on screen: NSScreen) {
        let screenID = MotionPanel.screenID(screen)
        guard let box = exposeClustersByScreen[screenID]?.first(where: { $0.id == clusterID }),
              let entry = box.members.first,
              let app = NSRunningApplication(processIdentifier: pid_t(entry.pid)) else {
            NSSound.beep()
            return
        }
        DiagnosticLog.shared.info("Hyperspace quit — cluster \(box.name) app=\(entry.app)")
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.exposed, !self.dismissed else { return }
            DesktopModel.shared.poll()
            self.rebuildSurveyState(for: screen, resetAim: false)
            self.rebuildExposeView(screens: [screen])
            self.updateLegend()
            self.refreshBorders()
            self.updateStack()
        }
    }

    // MARK: - Cluster-local search

    private func activateClusterSearch(_ clusterID: Int, on screen: NSScreen) {
        let screenID = MotionPanel.screenID(screen)
        let previouslyActiveScreens = activeClusterSearchByScreen.keys.compactMap { id in
            NSScreen.screens.first(where: { MotionPanel.screenID($0) == id })
        }
        activeClusterSearchByScreen.removeAll()
        activeClusterSearchByScreen[screenID] = clusterID
        var queries = clusterSearchQueryByScreen[screenID] ?? [:]
        queries[clusterID] = queries[clusterID] ?? ""
        clusterSearchQueryByScreen[screenID] = queries
        if activeSurveyScreen.map(MotionPanel.screenID) != screenID {
            setActiveSurveyScreen(screen)
        }
        if inPlaceMode {
            let uniqueTargets = ([screen] + previouslyActiveScreens)
                .reduce(into: [String: NSScreen]()) { $0[MotionPanel.screenID($1)] = $1 }
            let targets = Array(uniqueTargets.values)
            rebuildExposeView(screens: targets)
        } else {
            rebuildExposeView()
        }
    }

    private func clearClusterSearch(_ clusterID: Int, on screen: NSScreen) {
        let screenID = MotionPanel.screenID(screen)
        var queries = clusterSearchQueryByScreen[screenID] ?? [:]
        queries[clusterID] = ""
        clusterSearchQueryByScreen[screenID] = queries
        activeClusterSearchByScreen[screenID] = clusterID
        if activeSurveyScreen.map(MotionPanel.screenID) != screenID {
            setActiveSurveyScreen(screen)
        }
        rebuildExposeForScreenInteraction(on: screen)
    }

    private func activeClusterSearchTarget() -> (screen: NSScreen, screenID: String, clusterID: Int)? {
        for (screenID, clusterID) in activeClusterSearchByScreen {
            if let screen = NSScreen.screens.first(where: { MotionPanel.screenID($0) == screenID }) {
                return (screen, screenID, clusterID)
            }
        }
        return nil
    }

    private func handleClusterSearchKey(_ event: NSEvent) -> Bool {
        guard commandPanel == nil, newLayerPanel == nil, rulePanel == nil,
              let target = activeClusterSearchTarget() else { return false }

        switch event.keyCode {
        case 53:                                                    // Esc — clear, then leave filter mode
            let q = clusterSearchQueryByScreen[target.screenID]?[target.clusterID] ?? ""
            if q.isEmpty {
                activeClusterSearchByScreen[target.screenID] = nil
            } else {
                setClusterSearchQuery("", clusterID: target.clusterID, screenID: target.screenID)
            }
            rebuildExposeForScreenInteraction(on: target.screen)
            return true
        case 51:                                                    // Delete / Backspace
            var q = clusterSearchQueryByScreen[target.screenID]?[target.clusterID] ?? ""
            if !q.isEmpty {
                q.removeLast()
                setClusterSearchQuery(q, clusterID: target.clusterID, screenID: target.screenID)
                rebuildExposeForScreenInteraction(on: target.screen)
            }
            return true
        case 36, 76:                                                // Return — pluck visible matches
            selectClusterSearchMatches(target.clusterID, on: target.screen)
            return true
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let blocked = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
            guard !blocked, let text = clusterSearchText(from: event) else { return false }
            let current = clusterSearchQueryByScreen[target.screenID]?[target.clusterID] ?? ""
            setClusterSearchQuery(current + text, clusterID: target.clusterID, screenID: target.screenID)
            rebuildExposeForScreenInteraction(on: target.screen)
            return true
        }
    }

    private func setClusterSearchQuery(_ query: String, clusterID: Int, screenID: String) {
        var queries = clusterSearchQueryByScreen[screenID] ?? [:]
        queries[clusterID] = String(query.prefix(80))
        clusterSearchQueryByScreen[screenID] = queries
    }

    private func clusterSearchText(from event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_./:@#")
        guard chars.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return chars
    }

    private func selectClusterSearchMatches(_ clusterID: Int, on screen: NSScreen) {
        let screenID = MotionPanel.screenID(screen)
        guard let box = exposeClustersByScreen[screenID]?.first(where: { $0.id == clusterID }) else {
            NSSound.beep()
            return
        }
        let query = clusterSearchQueryByScreen[screenID]?[clusterID] ?? ""
        let hints = hintForByScreen[screenID] ?? [:]
        let matches = box.members
            .filter { Self.clusterSearchMatches($0, query: query, hint: hints[$0.wid] ?? "") }
            .map(\.wid)
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }

        let added = selection.append(matches, on: screenID)
        for wid in added {
            if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        }
        setClusterSearchQuery("", clusterID: clusterID, screenID: screenID)
        activeClusterSearchByScreen[screenID] = nil
        if activeSurveyScreen.map(MotionPanel.screenID) != screenID {
            setActiveSurveyScreen(screen)
        } else {
            prunePicks(on: screen)
        }
        rebuildExposeForScreenInteraction(on: screen)
        updateLegend()
        refreshBorders()
        updateStack()
    }

    private static func clusterSearchMatches(_ entry: WindowEntry, query: String, hint: String) -> Bool {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return true }
        let haystack = "\(entry.title) \(entry.app) \(hint)".lowercased()
        return terms.allSatisfy { haystack.range(of: String($0)) != nil }
    }

    // MARK: - Command bar (/)

    /// Open the curated `/` palette for one monitor: search its windows, target a
    /// group/layer (⏎ plucks), or /tile to stage a placement. Snapshots this screen's
    /// windows/clusters/layers and wires each verb to the survey's own selection path.
    private func presentCommandBar(on screen: NSScreen) {
        guard commandPanel == nil else { return }
        let id = MotionPanel.screenID(screen)
        let windows = surveyMembers(on: screen).map {
            HyperspaceCommandModel.WindowItem(wid: $0.wid, title: $0.title.isEmpty ? $0.app : $0.title, app: $0.app)
        }
        let hintFor = clusterHintForByScreen[id] ?? [:]
        let groups = (exposeClustersByScreen[id] ?? []).map { cluster in
            HyperspaceCommandModel.GroupItem(cid: cluster.id, name: cluster.name,
                                             hint: hintFor[cluster.id] ?? "", members: cluster.members.map(\.wid))
        }
        let layers = resolvedLayers().map { layer, held in
            HyperspaceCommandModel.LayerItem(lid: layer.id, name: layer.label,
                                             members: held.map(\.entry).filter { self.entry($0, isOn: screen) }.map(\.wid))
        }
        let model = HyperspaceCommandModel(windows: windows, groups: groups, layers: layers)
        model.onPluckWindow = { [weak self] wid in self?.exposeToggle(wid, on: screen) }
        model.onPluckGroup  = { [weak self] cid in self?.exposeToggleCluster(cid, on: screen) }
        model.onRecallLayer = { [weak self] lid in self?.pluckLayer(lid, on: screen) }
        model.onTile        = { [weak self] gp  in self?.stageTileForSelection(gp, on: screen) }
        model.onSaveLayer   = { [weak self] in self?.saveGroupAsLayer() }
        model.pluckedProvider = { [weak self] in self?.pickOrderByScreen[id] ?? [] }
        let panel = HyperspaceCommandPanel(model: model, onClose: { [weak self] in self?.dismissCommandBar() })
        commandPanel = panel
        ignoreResign = true                 // the bar takes key → our key-resign must NOT exit the survey
        panel.present(on: screen)
    }

    private func dismissCommandBar() {
        commandPanel?.close()
        commandPanel = nil
        ignoreResign = false
        makeKey()                           // reclaim key so the survey keeps responding
    }

    /// Select every on-screen window a layer's rule resolves to — the survey-native
    /// read of "recall this layer": it builds the selection (nothing raises), and
    /// gather (⏎/G) is still the only real move.
    private func pluckLayer(_ layerID: String, on screen: NSScreen) {
        guard let (_, layer) = workspaceLayer(layerID) else { NSSound.beep(); return }
        let members = layerMembers(layer).filter { entry($0, isOn: screen) }
        guard !members.isEmpty else { NSSound.beep(); return }
        pendingLayout = nil
        layoutPreview.clear()
        layoutNotice = nil
        let id = MotionPanel.screenID(screen)
        let added = selection.append(members.map(\.wid), on: id)
        for wid in added {
            if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
        }
        if activeSurveyScreen.map(MotionPanel.screenID) != id { setActiveSurveyScreen(screen) }
        else { prunePicks(on: screen) }
        rebuildExposeForScreenInteraction(on: screen); updateLegend(); refreshBorders(); updateStack()
    }

    /// Stage a named placement for the plucked set on this screen — the same staging
    /// a drag onto the Grid does. Nothing moves until Return / Keep.
    private func stageTileForSelection(_ gp: GridPlacement, on screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        let picked = pickOrderByScreen[id] ?? []
        guard !picked.isEmpty else { NSSound.beep(); return }
        let spec = PlacementSpec.grid(gp)
        for wid in picked { stageDrop(wid, spec) }
        DiagnosticLog.shared.info("Hyperspace stage — \(picked.count) selected window(s) \(spec.wireValue)")
        rebuildExposeForScreenInteraction(on: screen)
    }

    // MARK: - Keyboard: spatial aim and the `:` command line

    private struct CommandLineState {
        var buffer = ""
        let screenID: String
        var historyIndex: Int?
        var suggestions: [CommandSuggestion] = []
        /// Index into `suggestions`; 0 sits nearest the line.
        var selected: Int?
        /// Terminal tabs, read once per line the first time `go` needs them.
        var terminals: [TerminalInstance]?
    }
    private struct CommandSuggestion {
        let text: String
        let detail: String
        /// The line a verb suggestion completes to.
        let line: String
        /// The window a window suggestion names; Return acts on exactly it.
        let wid: UInt32?
        /// A tool card (Layers, Grid, Map) the suggestion opens.
        var tool: HyperspaceTool? = nil
    }

    private func toggleTool(_ tool: HyperspaceTool, on screen: NSScreen) {
        guard !layoutApplying else { return }
        let canvas = canvasForScreen(screen)
        canvas.tool = canvas.tool == tool ? nil : tool
        if canvas.tool == nil { dragModel.toolFrames[MotionPanel.screenID(screen)] = .zero }
        updateDesktopHUD()
    }
    private static var commandHistory: [String] = []

    /// Arrows move the aim to the nearest window that way, across displays.
    /// The aim shares the hover ring, so Space, the commands and a click all
    /// read the same target.
    private func aimSpatially(_ direction: HyperspaceSpatialAim.Direction, from screen: NSScreen) {
        let members = surveyScreens().flatMap { surveyMembers(on: $0) }
        guard !members.isEmpty else { NSSound.beep(); return }
        let target: WindowEntry
        if let current = inPlaceHoverWid, let index = members.firstIndex(where: { $0.wid == current }) {
            let frames = members.map { liveAppKitFrame(for: $0) }
            guard let next = HyperspaceSpatialAim.next(from: frames[index], direction: direction, among: frames) else {
                NSSound.beep(); return
            }
            target = members[next]
        } else {
            target = surveyMembers(on: screen).min { $0.zIndex < $1.zIndex } ?? members[0]
        }
        aimAtWindow(target)
    }

    private func aimAtWindow(_ entry: WindowEntry) {
        if let screen = screen(for: entry), activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(screen) {
            setActiveSurveyScreen(screen)
        }
        aimWindow(entry.wid, on: screen(for: entry))
        setInPlaceDesktopHover(entry.wid)
    }

    private var commandLineScreen: NSScreen? {
        guard let id = commandLineState?.screenID else { return nil }
        return NSScreen.screens.first { MotionPanel.screenID($0) == id }
    }

    private func openCommandLine(on screen: NSScreen) {
        guard selectionFrameByScreenID[MotionPanel.screenID(screen)] != nil else { NSSound.beep(); return }
        commandLineState = CommandLineState(screenID: MotionPanel.screenID(screen))
        renderCommandLine()
    }

    private func closeCommandLine() {
        if let id = commandLineState?.screenID { selectionFrameByScreenID[id]?.endPrompt() }
        commandLineState = nil
    }

    private func renderCommandLine(refresh: Bool = true) {
        guard var state = commandLineState, let screen = commandLineScreen,
              let frame = selectionFrameByScreenID[state.screenID] else { return }
        if refresh {
            state.suggestions = commandSuggestions(&state, on: screen)
            state.selected = nil
        }
        commandLineState = state
        let pick = state.selected.map { state.suggestions[$0] } ?? state.suggestions.first
        var ghost = ""
        if let pick, pick.wid == nil, !state.buffer.isEmpty || state.selected != nil,
           pick.line.lowercased().hasPrefix(state.buffer.lowercased()) {
            ghost = String(pick.line.dropFirst(state.buffer.count))
        }
        // The highlighted (or best) window wears the aim ring, so the list
        // and the desktop agree on what Return will act on.
        if let wid = pick?.wid, wid != inPlaceHoverWid { setInPlaceDesktopHover(wid) }
        let hint = state.buffer.isEmpty ? "" : HyperspaceCommandLine.verb(for: state.buffer)?.usage ?? ""
        frame.showPrompt(state.buffer, ghost: ghost, hint: hint,
                         suggestions: state.suggestions.map { .init(text: $0.text, detail: $0.detail) },
                         selected: state.selected)
    }

    /// What the line offers as you type: verbs first; after a window verb,
    /// the windows that match by app, title, or terminal tab; after `layer`,
    /// the layers.
    private func commandSuggestions(_ state: inout CommandLineState, on screen: NSScreen) -> [CommandSuggestion] {
        let line = state.buffer.drop { $0 == " " }
        let limit = HyperspaceSelectionFrame.maxSuggestions
        guard let space = line.firstIndex(of: " ") else {
            let head = line.lowercased()
            // The tools lead: the same cards as the bar's buttons.
            let tools: [CommandSuggestion] = HyperspaceTool.allCases
                .filter { head.isEmpty || $0.rawValue.lowercased().hasPrefix(head) }
                .map { tool in
                    let detail = switch tool {
                    case .layers: "saved window groups"
                    case .grid: "place picks on a grid"
                    case .map: "displays and their windows"
                    }
                    return CommandSuggestion(text: tool.rawValue, detail: detail, line: tool.rawValue.lowercased(),
                                             wid: nil, tool: tool)
                }
            let common = ["go", "pick", "only", "grid", "left", "layer", "apply"]
            let verbs = head.isEmpty
                ? common.compactMap { name in HyperspaceCommandLine.verbs.first { $0.names.contains(name) } }
                : HyperspaceCommandLine.verbs.filter { $0.names.contains { $0.hasPrefix(head) } }
            let commands = verbs.map { verb in
                let name = verb.names.first { $0.hasPrefix(head) && $0.count > 1 } ?? verb.name
                let usage = verb.usage.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                let bare = verb.usage.hasPrefix(verb.name + " ") ? String(verb.usage.dropFirst(verb.name.count + 1)) : verb.usage
                return CommandSuggestion(text: name, detail: usage.isEmpty ? bare : usage,
                                         line: name + (verb.argument == .none ? "" : " "), wid: nil)
            }
            // Rows read top-down on screen but index from the line up, so the
            // tools take the top rows by going last.
            let shown = Array((tools + commands).prefix(limit))
            return shown.reversed()
        }
        let head = line[..<space].lowercased()
        let query = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        let id = MotionPanel.screenID(screen)
        let picked = pickOrderByScreen[id] ?? []
        let members: [WindowEntry]
        switch head {
        case "layer", "ly":
            let q = query.lowercased()
            return resolvedLayers()
                .filter { q.isEmpty || $0.layer.label.lowercased().contains(q) }
                .sorted { ($0.layer.label.lowercased().hasPrefix(q) ? 0 : 1) < ($1.layer.label.lowercased().hasPrefix(q) ? 0 : 1) }
                .prefix(limit)
                .map { .init(text: $0.layer.label, detail: "\($0.members.count) windows",
                             line: "layer \($0.layer.label)", wid: nil) }
        case "go", "goto":
            if state.terminals == nil {
                ProcessModel.shared.refreshTerminalTabs()
                state.terminals = ProcessModel.shared.synthesizeTerminals()
            }
            members = surveyScreens().flatMap { surveyMembers(on: $0) }
        case "pick", "p", "only", "o":
            members = surveyMembers(on: screen)
        case "drop", "d":
            members = surveyMembers(on: screen).filter { picked.contains($0.wid) }
        default:
            return []
        }
        let terminals = state.terminals ?? []
        let words = query.lowercased().split(separator: " ").map(String.init)
        let home = NSHomeDirectory()
        return HyperspaceCommandLine.ranked(query, in: commandCandidates(members, terminals: terminals))
            .prefix(limit)
            .compactMap { c in
                guard let entry = members.first(where: { $0.wid == c.wid }) else { return nil }
                // A terminal names the directory (or tab) that matched.
                let tabs = terminals.filter { $0.windowId == c.wid }
                let tabHit = tabs.lazy.compactMap { t -> String? in
                    let fields = [t.cwd, t.tabTitle, t.tmuxSession].compactMap { $0 }
                    return fields.first { f in words.contains { f.lowercased().contains($0) } }
                }.first ?? tabs.first?.cwd
                var detail = entry.app
                if let tabHit { detail += " · " + tabHit.replacingOccurrences(of: home, with: "~") }
                if picked.contains(c.wid) { detail += " · picked" }
                let title = entry.title.isEmpty ? entry.app : entry.title
                return CommandSuggestion(text: title, detail: detail, line: "\(head) \(title)", wid: c.wid)
            }
    }

    /// Return, or a click on a row: run the line, or the chosen suggestion.
    private func commitCommandLine(choosing index: Int?) {
        guard var state = commandLineState, let screen = commandLineScreen else { return }
        var line = state.buffer.trimmingCharacters(in: .whitespaces)
        var pinned: UInt32?
        if let index, state.suggestions.indices.contains(index) {
            let pick = state.suggestions[index]
            if let tool = pick.tool {
                closeCommandLine()
                toggleTool(tool, on: screen)
                return
            }
            if let wid = pick.wid { pinned = wid; line = pick.line }
            else if pick.line.hasSuffix(" ") {                      // a verb that takes a name: keep typing
                state.buffer = pick.line
                state.selected = nil
                commandLineState = state
                renderCommandLine()
                return
            } else { line = pick.line }
        } else if let tool = HyperspaceTool.allCases.first(where: { $0 != .grid && $0.rawValue.lowercased() == line.lowercased() }) {
            // `layers` and `map` open their cards; `grid` stays the layout verb.
            closeCommandLine()
            toggleTool(tool, on: screen)
            return
        }
        commandLineState = nil
        guard !line.isEmpty else { closeCommandLine(); return }
        if Self.commandHistory.last != line { Self.commandHistory.append(line) }
        runCommandLine(line, on: screen, pinned: pinned)
    }

    private func handleCommandLineKey(_ event: NSEvent) {
        guard var state = commandLineState else { return }
        let mods = event.modifierFlags
        let n = state.suggestions.count
        switch event.keyCode {
        case 53:                                                    // Esc — unselect, then close
            if state.selected != nil {
                state.selected = nil
                commandLineState = state
                renderCommandLine(refresh: false)
                return
            }
            closeCommandLine()
            return
        case 36, 76:                                                // Return — run it
            commitCommandLine(choosing: state.selected)
            return
        case 48 where n > 0:                                        // Tab — walk the list (⇧ back)
            let step = mods.contains(.shift) ? -1 : 1
            state.selected = ((state.selected ?? (step > 0 ? -1 : 0)) + step + n) % n
            commandLineState = state
            renderCommandLine(refresh: false)
            return
        case 126 where n > 0 && !(state.buffer.isEmpty && state.selected == nil && !Self.commandHistory.isEmpty):
            state.selected = min(n - 1, (state.selected ?? -1) + 1)   // ↑ — up the list
            commandLineState = state
            renderCommandLine(refresh: false)
            return
        case 125 where state.selected != nil:                       // ↓ — back toward the line
            state.selected = state.selected! == 0 ? nil : state.selected! - 1
            commandLineState = state
            renderCommandLine(refresh: false)
            return
        case 126, 125:                                              // ↑ ↓ — history
            let history = Self.commandHistory
            guard !history.isEmpty else { NSSound.beep(); return }
            let up = event.keyCode == 126
            let current = state.historyIndex ?? history.count
            let next = min(history.count, max(0, current + (up ? -1 : 1)))
            state.historyIndex = next
            state.buffer = next < history.count ? history[next] : ""
        case 51:                                                    // Delete — ⌥ deletes a word
            if state.buffer.isEmpty { closeCommandLine(); return }
            if mods.contains(.option) {
                let trimmed = state.buffer.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if let space = trimmed.lastIndex(of: " ") { state.buffer = String(trimmed[...space]) }
                else { state.buffer = "" }
            } else {
                state.buffer.removeLast()
            }
            state.historyIndex = nil
        case 48:
            NSSound.beep()
            return
        default:
            guard !mods.contains(.command), !mods.contains(.control),
                  let chars = event.characters, !chars.isEmpty,
                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value >= 0xF700 })
            else { NSSound.beep(); return }
            // Typing on from a highlighted verb takes that verb.
            if let index = state.selected, state.suggestions[index].wid == nil, !state.buffer.contains(" ") {
                state.buffer = state.suggestions[index].line.trimmingCharacters(in: .whitespaces)
            }
            state.buffer += chars
            state.historyIndex = nil
        }
        commandLineState = state
        renderCommandLine()
    }

    private func commandCandidates(_ members: [WindowEntry], terminals: [TerminalInstance] = []) -> [HyperspaceCommandLine.Candidate] {
        var extras: [UInt32: [String]] = [:]
        for t in terminals {
            guard let wid = t.windowId else { continue }
            extras[wid, default: []] += [t.cwd, t.tabTitle, t.tmuxSession].compactMap { $0 }
                + t.processes.map(\.comm)
        }
        return members.sorted { $0.zIndex < $1.zIndex }.map {
            .init(wid: $0.wid, app: $0.app, title: $0.fullTitle ?? $0.title, extra: extras[$0.wid] ?? [])
        }
    }

    private func runCommandLine(_ line: String, on screen: NSScreen, pinned: UInt32? = nil) {
        let island = selectionFrameByScreenID[MotionPanel.screenID(screen)]
        switch HyperspaceCommandLine.parse(line) {
        case .failure(let failure):
            NSSound.beep()
            island?.showResult(failure.message, error: true)
        case .success(let command):
            DiagnosticLog.shared.info("Hyperspace command — :\(line)")
            guard let (ok, message) = perform(command, on: screen, pinned: pinned) else { island?.endPrompt(); return }
            if !ok { NSSound.beep() }
            island?.showResult(message, error: !ok)
        }
    }

    /// Picks, or the aimed window when nothing is picked.
    private func commandTargets(on screen: NSScreen) -> [UInt32] {
        let picks = pickOrderByScreen[MotionPanel.screenID(screen)] ?? []
        if !picks.isEmpty { return picks }
        if let aim = inPlaceHoverWid, surveyMembers(on: screen).contains(where: { $0.wid == aim }) { return [aim] }
        return []
    }

    private func afterCommandSelection(on screen: NSScreen) {
        pendingLayout = nil
        layoutLocked = false
        layoutPreview.clear()
        layoutNotice = nil
        if activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(screen) { setActiveSurveyScreen(screen) }
        else { prunePicks(on: screen) }
        rebuildExposeForScreenInteraction(on: screen); updateLegend(); refreshBorders(); updateStack()
    }

    private func proposeCommandLayout(_ plan: HyperspaceLayoutPlan?) -> (Bool, String) {
        guard let plan, !plan.frames.isEmpty else { return (false, "Not enough room for that layout") }
        layoutNotice = nil
        layoutLocked = true
        pendingLayout = plan
        refreshLayoutPreview()
        updateDesktopHUD()
        updateLegend()
        return (true, "\(plan.title) · ⏎ or :w applies, Esc drops it")
    }

    private func perform(_ command: HyperspaceCommandLine.Command, on screen: NSScreen,
                         pinned: UInt32? = nil) -> (Bool, String)? {
        let id = MotionPanel.screenID(screen)
        let picked = { self.pickOrderByScreen[id] ?? [] }
        let area = desktopArea(on: screen)
        switch command {
        case .pick(let query), .only(let query):
            let found = pinned.map { [$0] }
                ?? HyperspaceCommandLine.matches(query, in: commandCandidates(surveyMembers(on: screen))).map(\.wid)
            guard !found.isEmpty else { return (false, "No window here matches \"\(query)\"") }
            if case .only = command { selection.clear(on: id) }
            for wid in selection.append(found, on: id) {
                if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
            }
            afterCommandSelection(on: screen)
            return (true, "Picked \(found.count) · \(picked().count) picked")
        case .drop(let query):
            let pickedEntries = surveyMembers(on: screen).filter { picked().contains($0.wid) }
            let found = pinned.map { [$0] } ?? HyperspaceCommandLine.matches(query, in: commandCandidates(pickedEntries)).map(\.wid)
            guard !found.isEmpty else { return (false, "No pick matches \"\(query)\"") }
            selection.remove(Set(found), on: id)
            afterCommandSelection(on: screen)
            return (true, "Dropped \(found.count) · \(picked().count) picked")
        case .all:
            for wid in selection.append(surveyMembers(on: screen).map(\.wid), on: id) {
                if let e = eligible.first(where: { $0.wid == wid }) { _ = ax(for: e) }
            }
            afterCommandSelection(on: screen)
            return (true, "\(picked().count) picked")
        case .clear:
            clearPicks(on: screen)
            return (true, "No picks")
        case .go(let query):
            return goTo(query, pinned: pinned)
        case .balanced:
            let ids = commandTargets(on: screen)
            guard !ids.isEmpty else { return (false, "Pick windows first") }
            return proposeCommandLayout(ids.count >= 3
                ? HyperspaceLayoutPlanner.grid(ids, in: area)
                : HyperspaceLayoutPlanner.columns(ids, in: area))
        case .grid(let columns, let rows):
            let ids = commandTargets(on: screen)
            guard !ids.isEmpty else { return (false, "Pick windows first") }
            guard ids.count <= columns * rows else { return (false, "\(ids.count) picks don't fit \(columns)×\(rows)") }
            let gap = HyperspaceLayoutPlanner.gap
            let w = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let h = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            var frames: [UInt32: CGRect] = [:]
            for (index, wid) in ids.enumerated() {
                let c = index % columns, r = index / columns
                frames[wid] = CGRect(x: area.minX + CGFloat(c) * (w + gap), y: area.minY + CGFloat(r) * (h + gap),
                                     width: w, height: h).integral
            }
            return proposeCommandLayout(.init(title: "\(columns)×\(rows) grid", frames: frames))
        case .columns:
            let ids = commandTargets(on: screen)
            guard !ids.isEmpty else { return (false, "Pick windows first") }
            return proposeCommandLayout(HyperspaceLayoutPlanner.columns(ids, in: area))
        case .rows:
            let ids = commandTargets(on: screen)
            guard !ids.isEmpty else { return (false, "Pick windows first") }
            return proposeCommandLayout(HyperspaceLayoutPlanner.rows(ids, in: area))
        case .main(let leading):
            let ids = commandTargets(on: screen)
            guard ids.count >= 2 else { return (false, "Main needs two picks") }
            return proposeCommandLayout(HyperspaceLayoutPlanner.mainAndCompanions(ids, in: area, leading: leading))
        case .place(let spec, let name):
            let ids = commandTargets(on: screen)
            guard !ids.isEmpty else { return (false, "Pick or aim at a window first") }
            let region = WindowTiler.tileFrame(fractions: spec.fractions, on: screen)
            guard let frames = HyperspaceLayoutPlanner.pack(ids, into: region) else {
                return (false, "\(ids.count) windows don't fit \(name)")
            }
            return proposeCommandLayout(.init(title: name.capitalized, frames: frames))
        case .fill:
            let ids = commandTargets(on: screen)
            guard let target = ids.last else { return (false, "Pick or aim at a window first") }
            fillAvailableSpace(for: target)
            return (true, "Filled into open space  ·  Esc keeps it  ·  ⌘Z undoes")
        case .swap:
            let ids = picked()
            guard ids.count >= 2 else { return (false, "Swap needs two picks") }
            swapWindows(widA: ids[0], widB: ids[1], on: screen)
            return (true, "Swapped  ·  Esc keeps it")
        case .layer(let query):
            let layers = resolvedLayers()
            let q = query.lowercased()
            guard let match = layers.first(where: { $0.layer.label.lowercased() == q })
                    ?? layers.first(where: { $0.layer.label.lowercased().hasPrefix(q) })
                    ?? layers.first(where: { $0.layer.label.lowercased().contains(q) }) else {
                return (false, "No layer \"\(query)\"")
            }
            pluckLayer(match.layer.id, on: screen)
            return (true, "Layer \(match.layer.label) · \(picked().count) picked")
        case .save:
            guard !picked().isEmpty else { return (false, "Pick windows first") }
            saveGroupAsLayer()
            return nil
        case .tabs:
            guard picked().count >= 2 else { return (false, "Tabs need two picks") }
            createLiveTabsFromSelection(on: screen)
            return (true, "Stacked \(picked().count) as tabs")
        case .undo:
            undoDesktopLayout()
            return (true, "Undone")
        case .apply(let leave):
            if leave { finishDesktopSession(on: screen); return nil }
            guard pendingLayout != nil else { return (false, "Nothing to apply") }
            applyDesktopLayout()
            return nil
        case .quit:
            undoAndExit()
            return nil
        }
    }

    /// `go` finds a window on any display by app, title, or a terminal tab's
    /// directory, title, tmux session or running command. It aims there,
    /// brings the window forward, and switches to the matching tab.
    private func goTo(_ query: String, pinned: UInt32? = nil) -> (Bool, String) {
        let members = surveyScreens().flatMap { surveyMembers(on: $0) }
        ProcessModel.shared.refreshTerminalTabs()
        let terminals = ProcessModel.shared.synthesizeTerminals()
        guard let wid = pinned ?? HyperspaceCommandLine.matches(query, in: commandCandidates(members, terminals: terminals)).first?.wid,
              let entry = eligible.first(where: { $0.wid == wid }) else {
            return (false, "Nothing matches \"\(query)\"")
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let tab = terminals.filter { $0.windowId == entry.wid }.first { t in
            let text = ([t.cwd, t.tabTitle, t.tmuxSession].compactMap { $0 } + t.processes.map(\.comm))
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        if let tab { selectTerminalTab(tab) }
        aimAtWindow(entry)
        if let screen = screen(for: entry) { focusWindow(entry.wid, on: screen) }
        let name = entry.title.isEmpty ? entry.app : entry.title
        let where_ = tab.map { " · tab \(($0.tabIndex ?? 0) + 1)" } ?? ""
        return (true, "\(entry.app) · \(name.prefix(48))\(where_)")
    }

    /// Bring a terminal tab to the front of its window. iTerm2 by session ID,
    /// Terminal.app by TTY; other terminals keep their current tab.
    private func selectTerminalTab(_ tab: TerminalInstance) {
        let script: String
        switch tab.app {
        case .iterm2?:
            guard let sid = tab.terminalSessionId, !sid.contains("\"") else { return }
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique ID of s is "\(sid)" then
                                tell t to select
                                tell s to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case .terminal?:
            guard !tab.isActiveTab, !tab.tty.contains("\"") else { return }
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(tab.tty)" then
                            set selected tab of w to t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Display-scoped survey

    private func surveyScreens() -> [NSScreen] {
        NSScreen.screens.filter { screen in
            !surveyMembers(on: screen).isEmpty
        }
    }

    private func surveyMembers(on screen: NSScreen) -> [WindowEntry] {
        eligible.filter { entry($0, isOn: screen) }
    }

    private func engageSurveyScreen(_ screen: NSScreen, toggling wid: UInt32? = nil) {
        let targetID = MotionPanel.screenID(screen)
        let currentID = activeSurveyScreen.map(MotionPanel.screenID)
        if currentID != targetID {
            pruneActivePicks()
            setActiveSurveyScreen(screen)
        }
        if let wid {
            exposeToggle(wid)
        }
    }

    private func screenForEvent(_ event: NSEvent) -> NSScreen? {
        if let window = event.window,
           let screenID = exposePanelsByScreenID.first(where: { window === $0.value })?.key,
           let screen = NSScreen.screens.first(where: { MotionPanel.screenID($0) == screenID }) {
            return screen
        }
        let point = event.locationInWindow
        let global = CGPoint(x: point.x + frame.origin.x, y: point.y + frame.origin.y)
        return NSScreen.screens.first(where: { $0.frame.contains(global) })
    }

    private func screenForPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    // MARK: - In-place desktop click (Hyper+G)

    /// Frontmost eligible window at a desktop click. Walks CGWindowList fresh so
    /// z-order and bounds match what you see at click time — the open-time
    /// `eligible` snapshot can be stale after raises.
    private func topWindowAtDesktopClick(cg: CGPoint, on screen: NSScreen) -> WindowEntry? {
        let selectable = Dictionary(uniqueKeysWithValues: surveyMembers(on: screen).map { ($0.wid, $0) })
        guard !selectable.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let myPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let wid = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            if pid == myPid { continue }       // skip our transparent overlay panels

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect),
                  rect.width >= 50, rect.height >= 50,
                  rect.contains(cg) else { continue }

            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true
            guard isOnScreen else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else {
                // A transparent overlay that spans the display (a desktop
                // companion, a screen tint) cannot be told apart from a menu by
                // CGWindowList, but it never takes the click itself. Look past it.
                if rect.width >= screen.frame.width, rect.height >= screen.frame.height { continue }
                return nil                      // front menu/panel/etc. blocks windows behind it
            }

            // The first real window containing the click owns the click.  If it
            // is not in this in-place survey roster, do not fall through and pick
            // some eligible window hidden behind it.
            return selectable[wid]
        }
        return nil
    }

    /// AppKit screen point (bottom-left origin) → CG top-left, matching liveFrame / AX.
    fileprivate func cgPoint(fromAppKitScreen point: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryH - point.y)
    }

    fileprivate func appKitScreenPoint(from viewPoint: NSPoint, in view: NSView) -> CGPoint {
        let windowPoint = view.convert(viewPoint, to: nil)
        if let window = view.window {
            return window.convertPoint(toScreen: windowPoint)
        }
        return NSEvent.mouseLocation
    }

    // MARK: - Unified desktop session

    private func desktopArea(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame.insetBy(dx: 2, dy: 2)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                      width: visible.width, height: visible.height)
    }

    private func desktopFrames(on screen: NSScreen, selectedOnly: Bool = false) -> [(UInt32, CGRect)] {
        surveyMembers(on: screen).compactMap { entry in
            if selectedOnly && !(pickOrderByScreen[MotionPanel.screenID(screen)] ?? []).contains(entry.wid) { return nil }
            let rect = liveAppKitFrame(for: entry)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return (entry.wid, CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    private func desktopDivider(at point: CGPoint, on screen: NSScreen) -> HyperspaceLayoutPlanner.Divider? {
        HyperspaceLayoutPlanner.dividers(desktopFrames(on: screen, selectedOnly: true)).first { $0.hitFrame.contains(point) }
    }

    private func updateDesktopHUD() {
        guard exposed, !dismissed, !selectionOnly, let screen = activeSurveyScreen else { return }
        let hud: HyperspaceDesktopHUD
        if let desktopHUD { hud = desktopHUD }
        else {
            hud = HyperspaceDesktopHUD()
            desktopHUD = hud
            hud.onPick = { [weak self] wid in
                guard let self, !self.layoutApplying, let screen = self.activeSurveyScreen else { return }
                self.keyboardBrowsing = false
                self.layoutNotice = nil
                self.exposeToggle(wid, on: screen, keepProposal: true)
            }
            hud.onPickGroup = { [weak self] wids in
                guard let self, !self.layoutApplying, let screen = self.activeSurveyScreen, !wids.isEmpty else { return }
                self.keyboardBrowsing = false
                self.layoutNotice = nil
                let screenID = MotionPanel.screenID(screen)
                let added = self.selection.toggleGroup(wids, on: screenID)
                for wid in added {
                    if let entry = self.eligible.first(where: { $0.wid == wid }) { _ = self.ax(for: entry) }
                }
                self.prunePicks(on: screen)
                self.rebuildExposeForScreenInteraction(on: screen)
                self.updateLegend()
                self.refreshBorders()
            }
            hud.onPresentation = { [weak self] desktop in
                guard let self else { return }
                // Overview stays on the live desktop: it marks the real windows.
                if self.inPlaceMode { self.setOverviewMarks(!desktop) }
                else if desktop { WindowMotionMode.shared.showDesktop() }
            }
            hud.onLayout = { [weak self] in self?.proposeDesktopLayout() }
            hud.onChooseLayout = { [weak self] plan in
                guard let self, !self.layoutApplying, let screen = self.activeSurveyScreen,
                      Set(plan.frames.keys) == Set(self.pickOrderByScreen[MotionPanel.screenID(screen)] ?? []) else { return }
                // Overview arranges through its own path, so the survey and the
                // ghost windows follow the choice.
                if !self.inPlaceMode {
                    self.chooseOverviewLayout(self.pickOrderByScreen[MotionPanel.screenID(screen)] ?? [], plan: plan, on: screen)
                    return
                }
                self.layoutLocked = true
                self.pendingLayout = plan
                let order = self.pickOrderByScreen[MotionPanel.screenID(screen)] ?? []
                if self.layoutCycle.isEmpty || Set(self.layoutCycle[0].frames.keys) != Set(order) {
                    self.layoutCycle = HyperspaceLayoutPlanner.arrangements(order, in: self.desktopArea(on: screen))
                }
                if let index = self.layoutCycle.firstIndex(where: { $0.title == plan.title }) { self.layoutCycleIndex = index }
                self.layoutNotice = nil
                self.rebuildExposeView()
            }
            hud.onTool = { [weak self] tool in
                guard let self, let screen = self.activeSurveyScreen, !self.layoutApplying else { return }
                self.toggleTool(tool, on: screen)
            }
            hud.onUndo = { [weak self] in self?.undoDesktopLayout() }
            hud.onRestore = { [weak self] in self?.undoAndExit() }
            hud.onDone = { [weak self] in self?.finishDesktopSession(on: self?.activeSurveyScreen) }
            hud.onApply = { [weak self] in self?.applyDesktopLayout() }
            hud.onDiscard = { [weak self] in
                self?.layoutLocked = false
                self?.pendingLayout = nil
                self?.landingCue = nil
                self?.layoutPreview.clear()
                self?.rebuildExposeView()
            }
        }
        let order = pickOrderByScreen[MotionPanel.screenID(screen)] ?? []
        let frames = Dictionary(uniqueKeysWithValues: desktopFrames(on: screen))
        let windows = surveyMembers(on: screen).map { entry in
            HyperspaceDesktopHUD.Window(id: entry.wid, app: entry.app, title: entry.title,
                frame: frames[entry.wid] ?? .zero,
                icon: NSRunningApplication(processIdentifier: entry.pid)?.icon,
                slot: order.firstIndex(of: entry.wid).map { $0 + 1 })
        }
        let groups = (exposeClustersByScreen[MotionPanel.screenID(screen)] ?? []).map { box in
            HyperspaceDesktopHUD.Group(
                id: box.id, name: box.name, rule: box.rule, userDefined: box.userDefined,
                wids: box.members.map(\.wid),
                icon: box.userDefined ? nil : box.members.first.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon })
        }
        hud.update(.init(windows: windows, groups: groups, area: desktopArea(on: screen), desktop: inPlaceMode && !overviewMarks,
                         aimedID: keyboardBrowsing ? exposeOrderByScreen[MotionPanel.screenID(screen)]?[safe: exposeAimByScreen[MotionPanel.screenID(screen)] ?? 0] : nil,
                         hasChanges: didMoveWindows || !stagedIntents.isEmpty, canUndo: !layoutHistory.isEmpty,
                         preview: pendingLayout,
                         held: layoutLocked,
                         cue: landingCue,
                         notice: layoutNotice ?? (stagedIntents.isEmpty ? nil : "Placement staged · Done to apply"),
                         busy: layoutApplying, tool: canvasForScreen(screen).tool,
                         layouts: offeredLayouts(order, on: screen)), on: screen)
    }

    /// The arrangements the HUD offers: the live cycle when it belongs to this
    /// selection, otherwise the stock ones for two or more chosen windows.
    private func offeredLayouts(_ order: [UInt32], on screen: NSScreen) -> [HyperspaceLayoutPlan] {
        if !layoutCycle.isEmpty, Set(layoutCycle[0].frames.keys) == Set(order) { return layoutCycle }
        guard order.count >= 2 else { return [] }
        return HyperspaceLayoutPlanner.arrangements(order, in: desktopArea(on: screen))
    }

    private func refreshLayoutPreview() {
        guard inPlaceMode, let plan = pendingLayout, !dismissed else { layoutPreview.clear(); return }
        let frames = plan.frames.sorted { $0.key < $1.key }.map { wid, frame in
            (appKitFrame(fromAX: frame), eligible.first(where: { $0.wid == wid })?.app ?? "Window")
        }
        layoutPreview.show(frames, held: layoutLocked, guides: landingGuideFrames())
    }

    /// Faint plates for the quarter or edge the hand is heading toward.
    /// A committed landing already draws its own plates, so this stays empty then.
    private func landingGuideFrames() -> [(CGRect, String)] {
        guard let gesture = desktopGesture, gesture.moved, let wid = gesture.wid,
              let plan = pendingLayout, plan.title == "Move window" || plan.title == "Move windows" else { return [] }
        let ids = gesture.ids.count >= 2 ? gesture.ids : [wid]
        let occupied = gesture.neighbors.filter { !gesture.ids.contains($0.0) }.map(\.1)
        guard let approach = HyperspaceLayoutPlanner.approachGroup(ids, anchor: wid, at: gesture.at,
            in: desktopArea(on: gesture.screen), occupied: occupied) else { return [] }
        return approach.frames.sorted { $0.key < $1.key }.map { _, frame in
            (appKitFrame(fromAX: frame), approach.title)
        }
    }

    private func proposeDesktopLayout() {
        guard !layoutApplying, let screen = activeSurveyScreen else { return }
        let ids = pickOrderByScreen[MotionPanel.screenID(screen)] ?? []
        guard !ids.isEmpty else { layoutNotice = "Choose windows first."; updateDesktopHUD(); return }
        layoutNotice = nil
        let styles = HyperspaceLayoutPlanner.arrangements(ids, in: desktopArea(on: screen))
        layoutCycle = styles
        layoutCycleIndex = 0
        layoutLocked = true
        pendingLayout = styles.first
        if pendingLayout == nil { layoutNotice = "These windows need more room. Choose fewer windows." }
        rebuildExposeView()
    }

    /// Preview a layout from the overview tray. The plan's windows become the
    /// selection when the drag was holding a different set. Apply still commits.
    private func chooseOverviewLayout(_ ids: [UInt32], plan: HyperspaceLayoutPlan, on screen: NSScreen) {
        guard !layoutApplying, !ids.isEmpty, Set(plan.frames.keys) == Set(ids) else { return }
        let screenID = MotionPanel.screenID(screen)
        if pickOrderByScreen[screenID] != ids {
            selection.clear(on: screenID)
            let added = selection.append(ids, on: screenID)
            for wid in added {
                if let entry = eligible.first(where: { $0.wid == wid }) { _ = ax(for: entry) }
            }
            prunePicks(on: screen)
        }
        guard Set(plan.frames.keys) == Set(pickOrderByScreen[screenID] ?? []) else { return }
        keyboardBrowsing = false
        let styles = HyperspaceLayoutPlanner.arrangements(ids, in: desktopArea(on: screen))
        layoutCycle = styles
        layoutCycleIndex = styles.firstIndex { $0.title == plan.title } ?? 0
        layoutLocked = true
        pendingLayout = plan
        layoutNotice = nil
        rebuildExposeView()
        updateLegend()
    }

    private var canCycleLayout: Bool {
        guard layoutCycle.count > 1, layoutCycle.indices.contains(layoutCycleIndex),
              let pending = pendingLayout else { return false }
        let style = layoutCycle[layoutCycleIndex]
        return style.title == pending.title && Set(style.frames.keys) == Set(pending.frames.keys)
    }

    private var layoutCycleTitle: String {
        guard layoutCycle.indices.contains(layoutCycleIndex) else { return "" }
        return layoutCycle[layoutCycleIndex].title
    }

    /// The next style for the bunch already on the screen. Apply still commits.
    private func cycleOverviewLayout(on screen: NSScreen) {
        guard !layoutApplying, layoutCycle.count > 1 else { return }
        layoutCycleIndex = (layoutCycleIndex + 1) % layoutCycle.count
        layoutLocked = true
        pendingLayout = layoutCycle[layoutCycleIndex]
        layoutNotice = nil
        keyboardBrowsing = false
        rebuildExposeView(screens: [screen])
        updateLegend()
    }

    /// Drop onto the overview screen. One window keeps the spot under the hand.
    /// A bunch replaces the screen with that arrangement.
    private func placeInProposal(_ ids: [UInt32], _ update: HyperspaceLayoutPlan, on screen: NSScreen) {
        guard !layoutApplying, !update.frames.isEmpty else { return }
        if update.frames.count >= 2, HyperspaceLayoutPlanner.isArrangement(update.title) {
            let ordered = ids.filter { update.frames[$0] != nil }
            let planIDs = ordered.count == update.frames.count ? ordered : Array(update.frames.keys)
            guard planIDs.count >= 2 else { return }
            installArrangement(planIDs, preferredTitle: update.title, on: screen)
            return
        }
        layoutCycle = []
        layoutCycleIndex = 0
        layoutLocked = true
        var plan = pendingLayout ?? HyperspaceLayoutPlan(title: update.title, frames: [:])
        for (id, frame) in update.frames {
            plan.frames[id] = frame
        }
        plan.title = update.title
        let screenID = MotionPanel.screenID(screen)
        let missing = update.frames.keys.filter { !(pickOrderByScreen[screenID] ?? []).contains($0) }
        if !missing.isEmpty {
            let added = selection.append(Array(missing), on: screenID)
            for wid in added {
                if let entry = eligible.first(where: { $0.wid == wid }) { _ = ax(for: entry) }
            }
        }
        keyboardBrowsing = false
        pendingLayout = plan
        layoutNotice = nil
        rebuildExposeView(screens: [screen])
        updateLegend()
    }

    /// Put exactly these windows on the screen, in this order, and remember the
    /// other styles so a tap can switch.
    private func installArrangement(_ ids: [UInt32], preferredTitle: String, on screen: NSScreen) {
        let styles = HyperspaceLayoutPlanner.arrangements(ids, in: desktopArea(on: screen))
        guard !styles.isEmpty else { return }
        let screenID = MotionPanel.screenID(screen)
        if pickOrderByScreen[screenID] != ids {
            selection.clear(on: screenID)
            let added = selection.append(ids, on: screenID)
            for wid in added {
                if let entry = eligible.first(where: { $0.wid == wid }) { _ = ax(for: entry) }
            }
            prunePicks(on: screen)
        }
        layoutCycle = styles
        layoutCycleIndex = styles.firstIndex { $0.title == preferredTitle } ?? 0
        keyboardBrowsing = false
        layoutLocked = true
        pendingLayout = styles[layoutCycleIndex]
        layoutNotice = nil
        rebuildExposeView(screens: [screen])
        updateLegend()
    }

    /// A click toggles selection. Dragging one selected window carries the rest
    /// into the landing spot. A shared-edge drag still resizes those two windows.
    fileprivate func beginDesktopGesture(at point: NSPoint, in view: NSView, on screen: NSScreen) {
        guard !layoutApplying else { return }
        keyboardBrowsing = false
        let cg = cgPoint(fromAppKitScreen: appKitScreenPoint(from: point, in: view))
        let divider = desktopDivider(at: cg, on: screen)
        let window = topWindowAtDesktopClick(cg: cg, on: screen)
        guard divider != nil || window != nil else { return }
        if activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(screen) { setActiveSurveyScreen(screen) }
        let frames = desktopFrames(on: screen)
        let originals = Dictionary(frames, uniquingKeysWith: { first, _ in first })
        let original = window.flatMap { originals[$0.wid] } ?? .zero
        let order = pickOrderByScreen[MotionPanel.screenID(screen)] ?? []
        let ids: [UInt32]
        if let wid = window?.wid, order.contains(wid), order.count >= 2 {
            ids = order.filter { originals[$0] != nil }
        } else if let wid = window?.wid {
            ids = [wid]
        } else {
            ids = []
        }
        desktopGesture = .init(wid: window?.wid, ids: ids, original: original, originals: originals,
                               start: cg, screen: screen, divider: divider, neighbors: frames, at: cg)
        layoutNotice = nil
    }

    fileprivate func moveDesktopGesture(at point: NSPoint, in view: NSView) {
        guard var gesture = desktopGesture, !layoutApplying else { return }
        let cg = cgPoint(fromAppKitScreen: appKitScreenPoint(from: point, in: view))
        guard gesture.moved || hypot(cg.x - gesture.start.x, cg.y - gesture.start.y) >= 6 else { return }
        let wasPreviewing = gesture.moved
        let previousCue = landingCue
        gesture.moved = true
        gesture.at = cg
        desktopGesture = gesture
        layoutLocked = false
        if let divider = gesture.divider {
            pendingLayout = divider.plan(at: cg)
            landingCue = nil
        } else if let wid = gesture.wid {
            let area = desktopArea(on: gesture.screen)
            let others = gesture.neighbors.filter { !gesture.ids.contains($0.0) }
            if gesture.ids.count >= 2 {
                pendingLayout = HyperspaceLayoutPlanner.dropGroup(gesture.ids, originals: gesture.originals,
                    anchor: wid, start: gesture.start, at: cg, in: area, neighbors: others)
            } else {
                pendingLayout = HyperspaceLayoutPlanner.drop(wid, original: gesture.original, start: gesture.start,
                    at: cg, in: area, neighbors: others)
            }
            let ids = gesture.ids.count >= 2 ? gesture.ids : [wid]
            let moving = pendingLayout?.title == "Move window" || pendingLayout?.title == "Move windows"
            let occupied = others.map(\.1)
            landingCue = moving ? HyperspaceLayoutPlanner.approachGroup(ids, anchor: wid, at: cg, in: area, occupied: occupied)?.title : nil
        }
        clearInPlaceDesktopHover()
        refreshLayoutPreview()
        if !wasPreviewing || landingCue != previousCue { updateDesktopHUD() }
    }

    fileprivate func endDesktopGesture() {
        guard let gesture = desktopGesture else { return }
        desktopGesture = nil
        landingCue = nil
        if gesture.moved {
            // The spot stays on screen. Apply places it. Cancel clears it.
            layoutLocked = pendingLayout != nil
            refreshLayoutPreview()
            updateDesktopHUD()
            updateLegend()
        }
        else if let wid = gesture.wid, gesture.divider == nil {
            exposeToggle(wid, on: gesture.screen, keepProposal: true)
        }
        makeKey()
    }

    private func finishDesktopSession(on screen: NSScreen?) {
        guard !layoutApplying else { return }
        if pendingLayout != nil {
            applyDesktopLayout { [weak self] in self?.keepInPlaceAndExit(on: screen) }
        } else { keepInPlaceAndExit(on: screen) }
    }

    /// Resolve the entire plan before changing a frame. Verify the actual result:
    /// AX clients can impose a minimum size, so an unachievable layout rolls back.
    private func applyDesktopLayout(after completion: (() -> Void)? = nil) {
        guard !layoutApplying, let plan = pendingLayout, !plan.frames.isEmpty else { return }
        DesktopModel.shared.forcePoll()
        var moves: [(wid: UInt32, pid: Int32, frame: CGRect, axWindow: AXUIElement)] = []
        var previous: [UInt32: CGRect] = [:]
        for (wid, target) in plan.frames {
            guard let entry = eligible.first(where: { $0.wid == wid }),
                  let current = DesktopModel.shared.windows[wid], current.pid == entry.pid,
                  current.isOnScreen, let el = ax(for: entry),
                  let before = RealWindowAnimator.axFrame(el) else {
                layoutNotice = "A window is unavailable. Choose the windows again."
                pendingLayout = nil
                layoutPreview.clear()
                rebuildExposeView()
                return
            }
            previous[wid] = before
            recordOriginal(wid, el)
            moves.append((wid: wid, pid: entry.pid, frame: target, axWindow: el))
        }
        layoutApplying = true
        didMoveWindows = true
        updateDesktopHUD()
        let title = plan.title
        let names = moves.map { move in eligible.first { $0.wid == move.wid }?.app ?? "Window" }
        DiagnosticLog.shared.info("Hyperspace apply: \(title) · \(names.joined(separator: ", "))")
        // Stay key. Activating a placed app resigns this panel and the windows
        // come back before the check can see where they landed.
        raising { WindowTiler.batchMoveAndRaiseWindows(moves, activation: .none) }
        settleApply(moves, previous: previous, title: title, attempt: 0, completion: completion)
    }

    /// The first reading is often still in flight. Place the plan once more,
    /// then roll back only if a window is still more than 5pt off.
    private func settleApply(
        _ moves: [(wid: UInt32, pid: Int32, frame: CGRect, axWindow: AXUIElement)],
        previous: [UInt32: CGRect],
        title: String,
        attempt: Int,
        completion: (() -> Void)?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.18 : 0.28)) { [weak self] in
            guard let self, !self.dismissed else { return }
            let misses = moves.compactMap { move -> String? in
                guard let actual = RealWindowAnimator.axFrame(move.axWindow) else {
                    return "wid=\(move.wid) unread"
                }
                let dx = actual.minX - move.frame.minX
                let dy = actual.minY - move.frame.minY
                let dw = actual.width - move.frame.width
                let dh = actual.height - move.frame.height
                guard abs(dx) > 5 || abs(dy) > 5 || abs(dw) > 5 || abs(dh) > 5 else { return nil }
                return "wid=\(move.wid) dx=\(Int(dx)) dy=\(Int(dy)) dw=\(Int(dw)) dh=\(Int(dh))"
            }
            if misses.isEmpty {
                self.layoutHistory.append(previous)
                if title != "Undo layout" {
                    self.keptChange = true
                    self.announce("\(title) applied  ·  Esc keeps it  ·  ⌘Z undoes")
                }
                self.layoutNotice = nil
                self.pendingLayout = nil
                self.layoutLocked = false
                self.layoutPreview.clear()
                DiagnosticLog.shared.success("Hyperspace apply held: \(title)")
            } else if attempt == 0 {
                DiagnosticLog.shared.warn("Hyperspace apply retry \(title): \(misses.joined(separator: "; "))")
                self.raising { WindowTiler.batchMoveAndRaiseWindows(moves, activation: .none) }
                self.settleApply(moves, previous: previous, title: title, attempt: 1, completion: completion)
                return
            } else {
                DiagnosticLog.shared.warn("Hyperspace apply gave back \(title): \(misses.joined(separator: "; "))")
                self.raising {
                    WindowTiler.batchMoveAndRaiseWindows(moves.compactMap { move in
                        previous[move.wid].map { (wid: move.wid, pid: move.pid, frame: $0, axWindow: move.axWindow) }
                    }, activation: .none)
                }
                self.layoutLocked = true
                self.layoutNotice = "That layout did not fit. The suggestion is still here."
            }
            self.layoutApplying = false
            DesktopModel.shared.forcePoll()
            self.rebuildExposeView()
            self.refreshBorders()
            self.makeKey()
            if misses.isEmpty { completion?() }
        }
    }

    /// A short note on the active display's island.
    private func announce(_ message: String) {
        guard let screen = activeSurveyScreen else { return }
        selectionFrameByScreenID[MotionPanel.screenID(screen)]?.showResult(message)
    }

    private func undoDesktopLayout() {
        guard !layoutApplying else { return }
        if pendingLayout != nil {
            pendingLayout = nil
            layoutLocked = false
            layoutPreview.clear()
            rebuildExposeView()
            return
        }
        guard let previous = layoutHistory.last else { return }
        pendingLayout = .init(title: "Undo layout", frames: previous)
        // The undo itself uses the same verified transaction, without appending
        // another undo entry (which would merely toggle the same two states).
        let remaining = Array(layoutHistory.dropLast())
        applyDesktopLayout { [weak self] in
            self?.layoutHistory = remaining
            self?.announce(remaining.isEmpty ? "Undone  ·  back where you started" : "Undone  ·  Esc keeps this")
            self?.updateDesktopHUD()
        }
    }

    /// Chrome bands where a click must not pluck a live window underneath.
    /// The open tool card, in the same top-left space as the hosting view.
    fileprivate func toolChromeContains(_ point: NSPoint, in view: NSView, on screen: NSScreen) -> Bool {
        guard inPlaceMode, canvasForScreen(screen).tool != nil else { return false }
        let frame = dragModel.toolFrames[MotionPanel.screenID(screen)] ?? .zero
        guard frame.width > 1, frame.height > 1 else { return false }
        return frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    fileprivate func inPlaceChromeBlocksClick(at viewPoint: NSPoint, in view: NSView, on screen: NSScreen) -> Bool {
        guard exposed, inPlaceMode, !dismissed else { return false }
        return desktopHUD?.frame.contains(appKitScreenPoint(from: viewPoint, in: view)) == true
    }

    /// True when this click should be captured by the overlay (over a live window).
    fileprivate func inPlaceCapturesDesktopClick(at viewPoint: NSPoint, in view: NSView, on screen: NSScreen) -> Bool {
        guard exposed, inPlaceMode, !dismissed, !layoutApplying, !dragModel.isActive, !dragModel.isPlacing else { return false }
        guard commandPanel == nil, newLayerPanel == nil, rulePanel == nil else { return false }
        if inPlaceChromeBlocksClick(at: viewPoint, in: view, on: screen) { return false }
        let cg = cgPoint(fromAppKitScreen: appKitScreenPoint(from: viewPoint, in: view))
        return desktopDivider(at: cg, on: screen) != nil || topWindowAtDesktopClick(cg: cg, on: screen) != nil
    }

    fileprivate func performInPlaceDesktopSelect(at viewPoint: NSPoint, in view: NSView, on screen: NSScreen) {
        let cg = cgPoint(fromAppKitScreen: appKitScreenPoint(from: viewPoint, in: view))
        guard let hit = topWindowAtDesktopClick(cg: cg, on: screen) else { return }
        exposeToggle(hit.wid, on: screen)
        DiagnosticLog.shared.info("In-place select — click wid=\(hit.wid) app=\(hit.app) fillAim=\(hit.wid)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.exposed, !self.isKeyWindow, self.commandPanel == nil else { return }
            self.makeKey()
        }
    }

    /// Passive hover is an affordance only: it advertises that the real window is
    /// clickable, but never changes the active action target or selection.
    fileprivate func performInPlaceDesktopHover(at viewPoint: NSPoint, in view: NSView, on screen: NSScreen) {
        guard exposed, inPlaceMode, !dismissed, !dragModel.isActive, !dragModel.isPlacing else {
            clearInPlaceDesktopHover()
            return
        }
        let cg = cgPoint(fromAppKitScreen: appKitScreenPoint(from: viewPoint, in: view))
        if let divider = desktopDivider(at: cg, on: screen) {
            (divider.vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            clearInPlaceDesktopHover()
            return
        }
        NSCursor.crosshair.set()
        setInPlaceDesktopHover(topWindowAtDesktopClick(cg: cg, on: screen)?.wid)
    }

    fileprivate func clearInPlaceDesktopHover() {
        setInPlaceDesktopHover(nil)
    }

    private func setInPlaceDesktopHover(_ wid: UInt32?) {
        guard inPlaceHoverWid != wid else { return }
        inPlaceHoverWid = wid
        refreshBorders()
    }

    private func validSurveyScreen(_ screen: NSScreen?) -> NSScreen? {
        guard let screen, !surveyMembers(on: screen).isEmpty else { return nil }
        return screen
    }

    private func setActiveSurveyScreen(_ screen: NSScreen) {
        if activeSurveyScreen.map(MotionPanel.screenID) != MotionPanel.screenID(screen) {
            pruneActivePicks()
        }
        activeScreenID = MotionPanel.screenID(screen)

        let members = eligible.enumerated().filter { _, entry in self.entry(entry, isOn: screen) }
        let allMembers = surveyScreens().flatMap { surveyMembers(on: $0) }
        guard let first = members.first else { NSSound.beep(); return }
        if !entry(activeEntry, isOn: screen) {
            reticle = first.offset
        }

        lastSide = nil
        prunePicks(on: screen)

        if exposed {
            captureCount = allMembers.count
            if exposeClustersByScreen[MotionPanel.screenID(screen)] == nil {
                rebuildSurveyState(for: screen, resetAim: true)
            }
            syncActiveSurveyState(from: screen)
            if exposeHostsByScreenID.isEmpty {
                installExposeHosts()
            }
            allMembers.forEach { captureThumb(for: $0) }
            rebuildExposeView()
            checkCapturesSettled()
        }

        updateLegend()
        updateStack()
        refreshBorders()
    }

    private func pruneActivePicks() {
        guard let screen = activeSurveyScreen else { return }
        prunePicks(on: screen)
    }

    private func prunePicks(on screen: NSScreen) {
        let memberIDs = Set(eligible.filter { entry($0, isOn: screen) }.map(\.wid))
        selection.retainWindows(memberIDs, on: MotionPanel.screenID(screen))
    }

    private func canvasForScreen(_ screen: NSScreen) -> ExposeCanvas {
        let id = MotionPanel.screenID(screen)
        if let existing = canvasByScreenID[id] {
            return existing
        }
        let newCanvas = ExposeCanvas()
        canvasByScreenID[id] = newCanvas
        return newCanvas
    }

    private func exposeDisplayScope(for screen: NSScreen) -> ExposeView.DisplayScope? {
        let screens = surveyScreens()
        let screenID = MotionPanel.screenID(screen)
        guard screens.contains(where: { MotionPanel.screenID($0) == screenID }) else {
            return nil
        }
        let displayIndex = apiDisplayIndex(for: screen)
        let windows = surveyMembers(on: screen).count
        return ExposeView.DisplayScope(
            index: displayIndex,
            count: screens.count,
            label: screen == NSScreen.main ? "Main" : "Display \(displayIndex + 1)",
            windowCount: windows,
            isActive: activeSurveyScreen.map(MotionPanel.screenID) == screenID
        )
    }

    /// API display indices come from SkyLight, whose order is not guaranteed to
    /// match `NSScreen.screens`. UUID-map the exact Hyper+G panel display so a
    /// user can move the pointer anywhere during the countdown without changing
    /// which setup is captured.
    private func apiDisplayIndex(for screen: NSScreen) -> Int {
        let screens = NSScreen.screens
        let targetID = MotionPanel.screenID(screen)
        for display in WindowTiler.getDisplaySpaces() {
            guard let mapped = DisplayGeometryMapper.screen(for: display, in: screens) else { continue }
            if MotionPanel.screenID(mapped) == targetID { return display.displayIndex }
        }
        return screens.firstIndex(where: { MotionPanel.screenID($0) == targetID }) ?? 0
    }

    private func captureInPlaceSnapshot(on screen: NSScreen,
                                        completion: @escaping (String?) -> Void) {
        let generation = presentationGeneration
        let displayIndex = apiDisplayIndex(for: screen)
        let params: JSON = .object([
            "displayIndex": .int(displayIndex),
            "cursor": .bool(true),
            "clipboard": .bool(true),
            "source": .string("hyperspace"),
            "title": .string("Hyperspace Snapshot"),
        ])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try CaptureController.shared.screenshotDisplay(params: params)
                DispatchQueue.main.async {
                    if let self, self.exposed, !self.dismissed, self.presentationGeneration == generation,
                       self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil { self.makeKey() }
                    DiagnosticLog.shared.info("In-place snapshot — display \(displayIndex) copied + saved")
                    completion(nil)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    if let self, self.exposed, !self.dismissed, self.presentationGeneration == generation,
                       self.newLayerPanel == nil, self.rulePanel == nil, self.commandPanel == nil { self.makeKey() }
                    DiagnosticLog.shared.error("In-place snapshot failed — \(message)")
                    NSSound.beep()
                    completion(message)
                }
            }
        }
    }

    /// Clicking a minimap cell deselects it — the requested "unpluck with the
    /// mouse" path, working in both the survey and plain motion mode.
    private func minimapToggle(_ wid: UInt32) {
        togglePicked(wid)
        if exposed { rebuildExposeView() }
        updateLegend()
        refreshBorders()
        updateStack()
    }

    /// Move the Tab/Space highlight across the spread in layout order.
    private func exposeAimStep(_ delta: Int) {
        guard !exposeOrder.isEmpty else { return }
        let n = exposeOrder.count
        exposeAim = ((exposeAim + delta) % n + n) % n
        if let wid = exposeOrder[safe: exposeAim] { aimWindow(wid) }
        rebuildExposeView()
    }

    private func exposeAimStep(_ delta: Int, on screen: NSScreen) {
        let id = MotionPanel.screenID(screen)
        let order = exposeOrderByScreen[id] ?? []
        guard !order.isEmpty else { return }
        let current = exposeAimByScreen[id] ?? 0
        exposeAimByScreen[id] = keyboardBrowsing
            ? ((current + delta) % order.count + order.count) % order.count
            : (delta < 0 ? order.count - 1 : 0)
        keyboardBrowsing = true
        if activeSurveyScreen.map(MotionPanel.screenID) != id {
            setActiveSurveyScreen(screen)
        } else {
            exposeAim = exposeAimByScreen[id] ?? 0
        }
        if let wid = order[safe: exposeAimByScreen[id] ?? 0] { aimWindow(wid, on: screen) }
        rebuildExposeForScreenInteraction(on: screen)
    }

    /// True if the window's center sits on `screen` (AppKit coords, like screen(for:)).
    private func entry(_ e: WindowEntry, isOn screen: NSScreen) -> Bool {
        MotionPanel.screenID(WindowTiler.screenForWindowFrame(e.frame)) == MotionPanel.screenID(screen)
    }

    /// Run window-raising work while swallowing the transient key-resign it can
    /// trigger, so the overlay doesn't auto-exit mid-operation.
    private func raising(_ body: () -> Void) {
        ignoreResign = true
        didMoveWindows = true        // every real move/raise funnels through here
        body()
        DispatchQueue.main.async { [weak self] in self?.ignoreResign = false }
    }

    // MARK: - AX resolution (cached per window)

    private func ax(for entry: WindowEntry) -> AXUIElement? {
        if let cached = resolved[entry.wid] { return cached }
        let expected = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
        let el = RealWindowAnimator.resolve(wid: entry.wid, pid: entry.pid, expectedFrame: expected)
        resolved[entry.wid] = el
        return el
    }

    /// The window's current on-screen frame in CG (top-left) coords — the live AX
    /// frame when we can resolve it (windows move during a spread/tile), else the
    /// polled frame. Used for click hit-testing so a click lands on what you see.
    private func liveFrame(for entry: WindowEntry) -> CGRect {
        if let el = ax(for: entry), let f = RealWindowAnimator.axFrame(el) { return f }
        return CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
    }

    // MARK: - Borders (drawn in the always-on-top overlay)

    private func setOverviewMarks(_ on: Bool) {
        guard inPlaceMode, overviewMarks != on else { return }
        overviewMarks = on
        refreshBorders()
        updateDesktopHUD()
    }

    /// Every unpicked window on the survey screens, back to front, so the
    /// frontmost window's key draws last. Stacked keys shift right.
    private func overviewMarkEntries(selected: Set<UInt32>) -> [WindowSelectionOverlay.Entry] {
        var entries: [WindowSelectionOverlay.Entry] = []
        var placed: [CGPoint] = []
        for screen in surveyScreens() {
            let hints = hintForByScreen[MotionPanel.screenID(screen)] ?? [:]
            let members = surveyMembers(on: screen)              // front to back
            let frames = members.map { liveAppKitFrame(for: $0) }
            for (index, entry) in members.enumerated().reversed() where !selected.contains(entry.wid) {
                let frame = frames[index]
                let occluders = (frames[..<index] + [HyperspaceDesktopHUD.footprint(on: screen)]).filter { $0.intersects(frame) }
                var shift: CGFloat = 0
                while placed.contains(where: { abs($0.x - (frame.minX + shift)) < 26 && abs($0.y - frame.maxY) < 24 }) {
                    shift += 26
                }
                placed.append(CGPoint(x: frame.minX + shift, y: frame.maxY))
                entries.append(WindowSelectionOverlay.Entry(
                    wid: entry.wid, frame: frame, slot: nil,
                    isHoverTarget: entry.wid == inPlaceHoverWid,
                    hint: hints[entry.wid], hintShift: shift, occluders: Array(occluders)))
            }
        }
        return entries
    }

    private func refreshBorders() {
        guard let root = chromeHost?.layer else { return }
        borderLayers.forEach { $0.removeFromSuperlayer() }
        borderLayers.removeAll()

        // During the screenshot survey the SwiftUI spread (ExposeView) draws
        // everything; Hyper+G is the exception because its survey floats above the
        // live desktop and selected windows need an on-screen selected state.
        if exposed && !inPlaceMode { dividerHandles.clear(); return }

        if inPlaceMode, let screen = activeSurveyScreen {
            dividerHandles.show(HyperspaceLayoutPlanner.dividers(desktopFrames(on: screen, selectedOnly: true)).map { divider in
                (appKitFrame(fromAX: divider.hitFrame), divider.vertical)
            })
        } else { dividerHandles.clear() }

        let activeWid = activeEntry.wid

        // Selected-window chrome on the real desktop. Hyper+G draws via dedicated
        // per-window overlays above the survey panel; plain motion mode uses the
        // chrome host beneath the instruction strip.
        if inPlaceMode {
            var overlayEntries: [WindowSelectionOverlay.Entry] = []
            var selectedWids = Set<UInt32>()
            for (_, order) in pickOrderByScreen {
                for (idx, wid) in order.enumerated() {
                    guard let entry = eligible.first(where: { $0.wid == wid }) else { continue }
                    selectedWids.insert(wid)
                    overlayEntries.append(WindowSelectionOverlay.Entry(
                        wid: wid,
                        frame: liveAppKitFrame(for: entry),
                        slot: idx + 1
                    ))
                }
            }
            if let hoverWid = inPlaceHoverWid,
               !selectedWids.contains(hoverWid),
               let entry = eligible.first(where: { $0.wid == hoverWid }) {
                overlayEntries.append(WindowSelectionOverlay.Entry(
                    wid: hoverWid,
                    frame: liveAppKitFrame(for: entry),
                    slot: nil,
                    isHoverTarget: true
                ))
            }
            if overviewMarks {
                overlayEntries = overviewMarkEntries(selected: selectedWids) + overlayEntries.filter { $0.slot != nil }
            }
            WindowSelectionOverlay.shared.sync(overlayEntries)
            for screen in surveyScreens() {
                let id = MotionPanel.screenID(screen)
                var holes: [(NSRect, UInt32)] = []
                for wid in pickOrderByScreen[id] ?? [] {
                    guard let entry = eligible.first(where: { $0.wid == wid }) else { continue }
                    holes.append((liveAppKitFrame(for: entry), wid))
                }
                if let hoverWid = inPlaceHoverWid,
                   !(pickOrderByScreen[id] ?? []).contains(hoverWid),
                   let entry = eligible.first(where: { $0.wid == hoverWid }),
                   self.entry(entry, isOn: screen) {
                    holes.append((liveAppKitFrame(for: entry), hoverWid))
                }
                let local = holes.map { frame, wid in
                    HyperspaceDimView.Hole(
                        rect: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                        radius: WindowCornerRadius.radius(for: wid))
                }
                desktopDimByScreenID[id]?.holes = local
            }
            if exposed { return }
        } else {
            for (idx, wid) in pickOrder.enumerated() {
                guard group.contains(wid),
                      let entry = eligible.first(where: { $0.wid == wid }) else { continue }
                let local = panelLocal(liveAppKitFrame(for: entry))
                addSelectedWindowChrome(root: root, frame: local, app: entry.app, slot: idx + 1)
            }
        }

        // The aimed window — a *fake* bring-to-front. We never raise the real window
        // (cycling stays ephemeral, nothing on the desktop is re-stacked); instead we
        // lift its live capture on top, at its actual frame, with a soft shadow so it
        // reads as forward in place even when real neighbours overlap it.
        guard let el = ax(for: activeEntry), let axf = RealWindowAnimator.axFrame(el) else { return }
        let local = panelLocal(appKitFrame(fromAX: axf))

        // Only lift the capture while it still matches the window's current size. The
        // shot is cached at one size; after a tile/resize (full-width, half, maximize)
        // the window jumps to a very different shape and a stretched screenshot looks
        // awkward — so we drop it and just frame the correctly-sized real window.
        let sizeMatches = captureFrame[activeWid].map {
            abs($0.width - axf.width) <= max(8, axf.width * 0.03)
                && abs($0.height - axf.height) <= max(8, axf.height * 0.03)
        } ?? false

        if sizeMatches, let img = thumbs[activeWid], let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Shadow plate: its black body is fully covered by the capture above, so
            // only the blurred edge spills out and sells the lift.
            let shadow = CALayer()
            shadow.frame = local
            shadow.cornerRadius = 10
            shadow.cornerCurve = .continuous
            shadow.backgroundColor = NSColor.black.cgColor
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.45
            shadow.shadowRadius = 20
            shadow.shadowOffset = CGSize(width: 0, height: -8)
            root.addSublayer(shadow)
            borderLayers.append(shadow)

            let preview = CALayer()
            preview.frame = local
            preview.cornerRadius = 10
            preview.cornerCurve = .continuous
            preview.masksToBounds = true
            preview.contentsGravity = .resizeAspectFill
            preview.contents = cg
            root.addSublayer(preview)
            borderLayers.append(preview)
        }
        // The capture lands asynchronously (captureThumb → refreshBorders); until it
        // does we draw only the border and the real window shows through underneath.

        let border = CALayer()
        border.frame = local
        border.cornerRadius = 10
        border.cornerCurve = .continuous
        border.borderWidth = 2
        border.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        root.addSublayer(border)
        borderLayers.append(border)
    }

    private func addSelectedWindowChrome(root: CALayer, frame local: CGRect, app: String, slot: Int?) {
        let accent = MotionPanel.selectedChromeColor
        let appTint = MotionPanel.tint(for: app)
        let outerFrame = local.insetBy(dx: -5, dy: -5)

        let glow = CALayer()
        glow.frame = outerFrame
        glow.cornerRadius = 14
        glow.cornerCurve = .continuous
        glow.borderWidth = 3
        glow.borderColor = accent.withAlphaComponent(0.92).cgColor
        glow.backgroundColor = appTint.withAlphaComponent(0.055).cgColor
        glow.shadowColor = accent.cgColor
        glow.shadowOpacity = 0.62
        glow.shadowRadius = 13
        glow.shadowOffset = .zero
        root.addSublayer(glow)
        borderLayers.append(glow)

        let inner = CALayer()
        inner.frame = local.insetBy(dx: 2, dy: 2)
        inner.cornerRadius = 8
        inner.cornerCurve = .continuous
        inner.borderWidth = 1
        inner.borderColor = NSColor.white.withAlphaComponent(0.78).cgColor
        root.addSublayer(inner)
        borderLayers.append(inner)

        if let slot {
            let badge = CATextLayer()
            badge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            badge.string = "\(slot)"
            badge.fontSize = 11
            badge.alignmentMode = .center
            badge.foregroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
            badge.backgroundColor = accent.withAlphaComponent(0.95).cgColor
            badge.cornerRadius = 8
            badge.masksToBounds = true
            badge.frame = CGRect(x: outerFrame.minX + 8, y: outerFrame.maxY - 26, width: 26, height: 18)
            root.addSublayer(badge)
            borderLayers.append(badge)
        }
    }

    // MARK: - Geometry

    private func appKitFrame(fromAX ax: CGRect) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: ax.origin.x, y: primaryH - ax.origin.y - ax.height, width: ax.width, height: ax.height)
    }

    /// Live on-screen frame in global AppKit coords — AX when available, else polled entry.
    private func liveAppKitFrame(for entry: WindowEntry) -> NSRect {
        let axf: CGRect
        if let el = ax(for: entry), let live = RealWindowAnimator.axFrame(el) {
            axf = live
        } else {
            axf = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
        }
        return appKitFrame(fromAX: axf)
    }

    private func panelLocal(_ global: NSRect) -> NSRect {
        NSRect(x: global.minX - frame.origin.x, y: global.minY - frame.origin.y,
               width: global.width, height: global.height)
    }

    private func screen(for entry: WindowEntry) -> NSScreen? {
        WindowTiler.screenForWindowFrame(entry.frame)
    }

    fileprivate static func screenID(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(number.intValue)"
        }
        let f = screen.frame
        return "display-\(Int(f.minX))-\(Int(f.minY))-\(Int(f.width))-\(Int(f.height))"
    }

    private static func screensUnion() -> NSRect {
        NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
    }

    /// A screen's *usable* area (visibleFrame — below the menu bar, above the Dock) in AX/CG
    /// (top-left origin) coords — the same space as `WindowEntry.frame` AND the same rect
    /// `WindowTiler.tileFrame` divides into grid cells. Using visibleFrame (not the full frame)
    /// keeps the placement preview 1:1 with where windows actually land (no size mismatch).
    static func axRect(of screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.visibleFrame
        let axTop = primaryH - vf.maxY
        return CGRect(x: vf.minX, y: axTop, width: vf.width, height: vf.height)
    }

    /// The inset from a screen's full frame to its usable visibleFrame, in SwiftUI top-left
    /// coords — so an overlay sized to the full panel can place content inside the menu bar/Dock.
    static func usableInset(of screen: NSScreen) -> EdgeInsets {
        let f = screen.frame, v = screen.visibleFrame
        return EdgeInsets(top: max(0, f.maxY - v.maxY),
                          leading: max(0, v.minX - f.minX),
                          bottom: max(0, v.minY - f.minY),
                          trailing: max(0, f.maxX - v.maxX))
    }

    /// A window frame as a top-origin fractional rect within `screenAX`, clamped to the
    /// unit square so off-screen spill doesn't blow out the map.
    static func frac(of frame: WindowFrame, in screenAX: CGRect) -> CGRect {
        frac(of: CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h), in: screenAX)
    }

    static func frac(of frame: CGRect, in screenAX: CGRect) -> CGRect {
        guard screenAX.width > 1, screenAX.height > 1 else { return .zero }
        let x = (frame.minX - screenAX.minX) / screenAX.width
        let y = (frame.minY - screenAX.minY) / screenAX.height
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGRect(x: cx, y: cy,
                      width: min(frame.width / screenAX.width, 1 - cx),
                      height: min(frame.height / screenAX.height, 1 - cy))
    }

    static func tint(for app: String) -> NSColor {
        var v: UInt64 = 5381
        for b in app.utf8 { v = (v &* 33) &+ UInt64(b) }
        let hue = CGFloat(v % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.58, brightness: 0.98, alpha: 1)
    }

    static var selectedChromeColor: NSColor { HyperspaceChrome.accentColor }

    // MARK: - Legend

    private func installLegend(on host: NSView) {
        let hosting = NSHostingView(rootView: legendModel())
        let size = hosting.fittingSize
        let screenFrame = (activeSurveyScreen ?? screen(for: activeEntry) ?? NSScreen.main)?.frame ?? frame
        let x = screenFrame.midX - size.width / 2 - frame.origin.x
        let y = screenFrame.minY + 70 - frame.origin.y
        hosting.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        host.addSubview(hosting)
        legendHost = hosting
    }

    private func updateLegend() {
        // Hyper+G owns its own header/shelf chrome on the survey panels above us.
        // Keeping the MotionPanel legend visible lets clicks leak through to desktop selection.
        if !selectionOnly {
            legendHost?.isHidden = true
            return
        }
        legendHost?.isHidden = false
        legendHost?.rootView = legendModel()
        if let hosting = legendHost {
            let size = hosting.fittingSize
            let screenFrame = (activeSurveyScreen ?? screen(for: activeEntry) ?? NSScreen.main)?.frame ?? frame
            hosting.frame = NSRect(x: screenFrame.midX - size.width / 2 - frame.origin.x,
                                   y: screenFrame.minY + 70 - frame.origin.y,
                                   width: size.width, height: size.height)
        }
        raiseLegend()
    }

    /// Keep the instruction strip at the highest z-index at all times — above the
    /// minimap and the Exposé spread — so it stays readable and clickable no matter
    /// what else gets added to the overlay.
    private func raiseLegend() {
        guard let legendHost, let superview = legendHost.superview else { return }
        superview.addSubview(legendHost, positioned: .above, relativeTo: nil)
    }

    private func legendModel() -> MotionLegend {
        let prompt = selectionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if selectionOnly, let prompt, !prompt.isEmpty {
            title = String(prompt.prefix(64))
        } else if selectionOnly {
            title = "Choose a window"
        } else {
            title = activeEntry.app
        }
        return MotionLegend(app: title,
                     tint: Color(nsColor: MotionPanel.tint(for: activeEntry.app)),
                     groupCount: group.count,
                     exposed: exposed,
                     inPlace: inPlaceMode,
                     selectionOnly: selectionOnly,
                     displayCount: surveyScreens().count)
    }

    // MARK: - Snapshot stack (bottom-left)
    //
    // A vertical stack of live window snapshots so the selection is concrete:
    // the active (aimed) window on top, plucked group members below. Snapshots
    // come from ScreenCaptureKit per-window capture, so an occluded window still
    // shows its real content — fixing the "phantom selection" feel.

    private func installStack(on host: NSView) {
        let hosting = NSHostingView(rootView: MotionStack(cells: []))
        // Keep the minimap beneath the instruction strip so the strip is never hidden.
        if let legendHost {
            host.addSubview(hosting, positioned: .below, relativeTo: legendHost)
        } else {
            host.addSubview(hosting)
        }
        stackHost = hosting
        positionStack()
    }

    private func updateStack() {
        let groupMembers = orderedGroup()
        if !selectionOnly {
            LiveTabGroupStore.shared.captureCandidateSelection(groupMembers.map(\.wid))
        }
        guard let stackHost else { return }
        if !selectionOnly {
            stackHost.isHidden = true
            return
        }
        stackHost.isHidden = false
        let activeWid = activeEntry.wid
        // The minimap mirrors the gather plan: the picked windows in the exact
        // balanced grid they'll snap to. Shown only once you've picked something —
        // while you're just browsing there's nothing to plan, so it stays hidden.
        let rects = balancedGrid(groupMembers.count)
        let cells = groupMembers.enumerated().map { (i, m) in
            MotionStack.Cell(
                id: m.wid,
                tint: Color(nsColor: MotionPanel.tint(for: m.app)),
                image: thumbs[m.wid],
                rect: rects[i],
                slot: i + 1,                                                // pick-order slot number
                isActive: m.wid == activeWid
            )
        }
        let screenFrame = (activeSurveyScreen ?? screen(for: activeEntry) ?? NSScreen.main)?.frame ?? frame
        let aspect = screenFrame.height > 0 ? screenFrame.width / screenFrame.height : 1.6

        stackHost.rootView = MotionStack(cells: cells, aspect: aspect,
                                         onToggle: { [weak self] wid in self?.minimapToggle(wid) })
        positionStack()

        // Capture thumbnails for the active window (its in-place preview) + the
        // picked group (the minimap), cached per wid.
        captureThumb(for: activeEntry)
        groupMembers.forEach { captureThumb(for: $0) }
    }

    /// Bottom-left, anchored at the bottom so the stack grows upward as it fills.
    private func positionStack() {
        guard let stackHost else { return }
        let screenFrame = (activeSurveyScreen ?? screen(for: activeEntry) ?? NSScreen.main)?.frame ?? frame
        let size = stackHost.fittingSize
        stackHost.frame = NSRect(
            x: screenFrame.minX + stackMargin - frame.origin.x,
            y: screenFrame.minY + stackMargin - frame.origin.y,
            width: size.width,
            height: size.height
        )
    }

    private func captureThumb(for entry: WindowEntry) {
        let wid = entry.wid
        guard !dismissed, thumbs[wid] == nil, !thumbInFlight.contains(wid) else { return }

        // Reuse the HUD's warm cache: if the shared store already has this window,
        // use it instantly — no capture. (The store's warmer keeps it stocked.)
        if let cached = WindowPreviewStore.shared.image(for: wid) {
            loadTrace?.bump("capture.hit")
            thumbs[wid] = cached
            captureFrame[wid] = liveFrame(for: entry)
            return
        }

        loadTrace?.bump("capture.miss")
        thumbInFlight.insert(wid)
        let generation = presentationGeneration
        let cgWid = CGWindowID(wid)
        let captureT0 = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            let cg = await WindowCapture.image(
                listOption: .optionIncludingWindow,
                windowID: cgWid,
                imageOption: [.boundsIgnoreFraming, .nominalResolution]
            )
            guard let self, !self.dismissed, self.presentationGeneration == generation else { return }
            self.thumbInFlight.remove(wid)
            self.loadTrace?.record("capture#\(wid)", ms: (CACurrentMediaTime() - captureT0) * 1000, warnAbove: 120)
            guard let cg else { self.checkCapturesSettled(); return }
            WindowPreviewStore.shared.ingest(cgImage: cg, for: wid, frame: entry.frame)
            guard let preview = WindowPreviewStore.shared.image(for: wid) else {
                self.checkCapturesSettled()
                return
            }
            self.thumbs[wid] = preview
            self.captureFrame[wid] = self.liveFrame(for: entry)
            self.updateStack()
            self.scheduleCaptureRebuild(for: entry)               // a survey tile's capture just landed
            self.checkCapturesSettled()
            // A fresh capture for the aimed window is its fake bring-to-front image.
            if wid == self.activeEntry.wid { self.refreshBorders() }
        }
    }

    private func scheduleCaptureRebuild(for entry: WindowEntry) {
        guard exposed, !dismissed else { return }
        guard let screen = validSurveyScreen(screen(for: entry)) ?? activeSurveyScreen else {
            rebuildExposeView()
            return
        }
        let id = MotionPanel.screenID(screen)
        guard captureRebuildWorkItemsByScreenID[id] == nil else { return }
        let generation = presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.captureRebuildWorkItemsByScreenID[id] = nil
            guard self.exposed, !self.dismissed else { return }
            self.rebuildExposeView(screens: [screen])
        }
        captureRebuildWorkItemsByScreenID[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    /// Mark (once) the moment every survey tile has its image — captures done,
    /// whether they came from the shared cache or a fresh grab.
    private func checkCapturesSettled() {
        guard exposed, thumbInFlight.isEmpty, capturesAt == 0, loadStart > 0 else { return }
        capturesAt = CACurrentMediaTime()
        DiagnosticLog.shared.info(String(format: "Hyperspace load — captures complete %.1fms · %d windows (from trigger)", (capturesAt - loadStart) * 1000, captureCount))
        let mode = inPlaceMode ? "in-place" : "hyperspace"
        let screens = surveyScreens().count
        loadTrace?.logSummary(
            mode: mode,
            windows: captureCount,
            screens: screens,
            firstPaintMs: firstPaintAt > 0 ? Int(((firstPaintAt - loadStart) * 1000).rounded()) : nil,
            capturesMs: Int(((capturesAt - loadStart) * 1000).rounded())
        )
    }
}

// MARK: - Legend view

private struct MotionLegend: View {
    let app: String
    let tint: Color
    let groupCount: Int
    var exposed: Bool = false
    var inPlace: Bool = false
    var selectionOnly: Bool = false
    var displayCount: Int = 1

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(app)
                    .font(Typo.monoBold(11))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                if groupCount > 0 {
                    Text("+\(groupCount)")
                        .font(Typo.monoBold(10))
                        .foregroundColor(Palette.running)
                }
            }

            Rectangle().fill(Palette.border).frame(width: 1, height: 13)

            if selectionOnly {
                keyHint("a–z", "choose")
                keyHint("Tab", "aim")
                keyHint("⏎", "choose")
                keyHint("esc", "cancel")
            } else if exposed {
                if inPlace {
                    keyHint("click", "select")
                    keyHint("a–z", "select")
                    keyHint("S", "swap 2")
                    keyHint("G", "grid")
                    keyHint("F", "fill")
                    keyHint("drag", "stage")
                    keyHint("⏎", "commit")
                    keyHint("esc", "exit")
                    keyHint("Hyper+␣", "exit")
                } else {
                    keyHint("a–z", "select")
                    keyHint("click", "group")
                    keyHint("⇧a–z", "group")
                    keyHint("Tab", "aim")
                    keyHint("⌘scroll", "zoom")
                    keyHint("⏎", "gather")
                    if groupCount > 0 { keyHint("⌘L", "save layer") }
                    if groupCount > 1 { keyHint("⌘T", "tabs") }
                    keyHint("E", "collapse")
                    keyHint("esc", "cancel")
                }
            } else {
                keyHint("Tab", "aim")
                keyHint("Space", "select")
                keyHint("E", "expose")
                keyHint("G", "grid")
                keyHint("F", "fill")
                if groupCount > 0 { keyHint("⌘L", "save layer") }
                if groupCount > 1 { keyHint("⌘T", "tabs") }
                keyHint("←↑→↓", "half · gap")
                keyHint("⇧/⌥", "nudge/size")
                keyHint("⏎", "confirm")
                keyHint("esc", "cancel")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                )
        )
        .fixedSize()
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border, lineWidth: 0.5))
                )
            Text(label)
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
        }
    }
}

// MARK: - Snapshot stack view

private struct MotionStack: View {
    struct Cell: Identifiable {
        let id: UInt32
        let tint: Color
        let image: NSImage?        // real window capture; falls back to tint while loading
        let rect: CGRect           // normalized 0…1 placement in the minimap
        let slot: Int              // pick-order slot number (matches the gather grid)
        let isActive: Bool         // the aimed window — highlighted
    }

    let cells: [Cell]
    var aspect: CGFloat = 1.6
    var onToggle: (UInt32) -> Void = { _ in }   // tap a cell to deselect it

    // The minimap lives in a constant box and the screen-aspect grid is *contained*
    // inside it, so the panel is one predictable size on any display (no more
    // collapsing into a wide strip that crowds the logo on an ultrawide).
    private let boxW: CGFloat = 196
    private let boxH: CGFloat = 118
    private let gutter: CGFloat = 5

    var body: some View {
        if cells.isEmpty {
            // Nothing picked yet → no panel. The in-place preview is enough while
            // you browse; the plan only appears once there's a plan.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header
                minimap
                caption
                footer
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.74))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 10)
        }
    }

    // Branded title row: a lattice glyph + wordmark, with the live pick count.
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.running)
            Text("Lattices")
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)
                .tracking(0.5)
            Text("hyperspace")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
            Spacer(minLength: 10)
            Text("\(cells.count)")
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.running)
            Text(cells.count == 1 ? "pick" : "picks")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
        }
    }

    // Contain the screen-aspect rectangle inside the fixed box (small inset so
    // cells don't touch the edge). Keeps the gather proportions truthful while the
    // panel stays a constant size.
    private var fittedSize: CGSize {
        let inset: CGFloat = 8
        let availW = boxW - inset, availH = boxH - inset
        let a = max(aspect, 0.3)
        if a >= availW / availH { return CGSize(width: availW, height: (availW / a).rounded()) }
        return CGSize(width: (availH * a).rounded(), height: availH)
    }

    private var minimap: some View {
        let fit = fittedSize
        return ZStack {                                   // centered grid in a constant box
            ZStack(alignment: .topLeading) {
                ForEach(cells) { cell in
                    tile(cell)
                        .frame(width:  max(fit.width  * cell.rect.width  - gutter, 1),
                               height: max(fit.height * cell.rect.height - gutter, 1))
                        .offset(x: fit.width  * cell.rect.minX + gutter / 2,
                                y: fit.height * cell.rect.minY + gutter / 2)
                }
            }
            .frame(width: fit.width, height: fit.height, alignment: .topLeading)
        }
        .frame(width: boxW, height: boxH)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border.opacity(0.8), lineWidth: 0.75))
    }

    private var caption: some View {
        Text("tap a tile to deselect")
            .font(Typo.mono(8))
            .foregroundColor(Palette.textMuted)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            chip("⏎"); Text("gather").font(Typo.mono(9)).foregroundColor(Palette.textMuted)
            Spacer(minLength: 8)
            chip("esc"); Text("cancel").font(Typo.mono(9)).foregroundColor(Palette.textMuted)
        }
    }

    private func chip(_ key: String) -> some View {
        Text(key)
            .font(Typo.monoBold(9))
            .foregroundColor(Palette.text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border, lineWidth: 0.5))
            )
    }

    private func tile(_ cell: Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            cell.tint.opacity(0.9)
            if let image = cell.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            Text("\(cell.slot)")
                .font(Typo.monoBold(9))
                .foregroundColor(Color(red: 0.02, green: 0.03, blue: 0.05))
                .frame(width: 14, height: 14)
                .background(Circle().fill(cell.tint))
                .padding(3)
        }
        .overlay(shape.strokeBorder(cell.isActive ? Color.white.opacity(0.95)
                                                  : Color.white.opacity(0.14),
                                    lineWidth: cell.isActive ? 1.5 : 0.75))
        .contentShape(Rectangle())
        .onTapGesture { onToggle(cell.id) }
    }
}

// MARK: - Cluster rule (user-definable; a cluster IS a named rule)

/// A user-defined cluster from ~/.lattices/clusters.json. A window joins the
/// cluster when it satisfies every present criterion. Smart by-app clusters fill
/// in whatever the user's rules don't claim.
struct ClusterRule: Decodable {
    let name: String
    var app: String?            // app name contains (case-insensitive)
    var titleContains: String?  // window title contains (case-insensitive)

    func matches(_ e: WindowEntry) -> Bool {
        var matched = false
        if let app {
            if !e.app.localizedCaseInsensitiveContains(app) { return false }
            matched = true
        }
        if let titleContains {
            if !e.title.localizedCaseInsensitiveContains(titleContains) { return false }
            matched = true
        }
        return matched
    }

    var summary: String {
        switch (app, titleContains) {
        case let (a?, t?): return "app \(a) · ~\(t)"
        case let (a?, nil): return "app \(a)"
        case let (nil, t?): return "~\(t)"
        default: return "rule"
        }
    }
}

/// A resolved cluster for one survey: a named box of windows.
struct ExposeCluster {
    let id: Int
    let name: String
    let rule: String
    let userDefined: Bool
    let members: [WindowEntry]
}

// MARK: - Expose spread view (the lattice survey)
//
// A clustered lattice of live window captures over a dimmed active display.
// Each tile wears a home-row hint letter; picked tiles get a slot number (the
// order they'll fill the gather grid). Tint = app identity; the box = cluster.
// Renders study 05 ("Converged") from design/hyperspace-lattice-studio.html.

/// A behind-window blur of the live desktop — the frosted-glass backdrop the
/// survey floats on. Forced dark so it reads as a HUD regardless of system theme.
private struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Collects each survey tile's laid-out frame (in the survey coordinate space) so
/// the panel can deal hand-split hint keys by real on-screen position.
private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Reports the Lattice drop-grid's frame (in the root coordinate space) so a drop
/// can be hit-tested to a cell.
private struct ToolCardFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct LatticeFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Collects the Current View screen-map frame (root space) for drop hit-testing.
private struct CurrentViewFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Collects each Layers pile's frame (root space, keyed by layer id / newLayerKey)
/// so a drop can be hit-tested to a pile.
private struct LayerFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Layout-tray cards, in root space, so an overview drag can land on one.
private struct ProposalCanvasKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct LayoutCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The one-shot "landed" ring flashed at a drop target. Expands and fades on appear;
/// keyed by the pulse token (`.id`) so each drop replays it from scratch.
private struct DropPulseRing: View {
    let frame: CGRect
    let tint: Color
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(tint, lineWidth: 2.5)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(on ? 1.08 : 0.97)
            .opacity(on ? 0 : 0.65)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .onAppear { withAnimation(HyperspaceMotion.pulse) { on = true } }
    }
}

/// Live frame-cadence stats for the survey perf harness. `record` is fed each
/// animation tick; the EMA keeps the readout steady, worst-frame surfaces
/// hitches. Reset between A/B runs for a clean comparison.
private final class PerfStats: ObservableObject {
    @Published var fps: Double = 0
    @Published var ms: Double = 0
    @Published var worstMs: Double = 0

    private var last: Double = 0
    private var ema: Double = 0

    func record(_ now: Double) {
        defer { last = now }
        guard last != 0 else { return }
        let dt = (now - last) * 1000
        guard dt > 0.1, dt < 250 else { return }   // ignore tab-away gaps
        ema = ema == 0 ? dt : ema * 0.88 + dt * 0.12
        ms = ema
        fps = 1000 / ema
        if dt > worstMs { worstMs = dt }
    }

    func reset() {
        last = 0; ema = 0; ms = 0; fps = 0; worstMs = 0
    }
}

struct ExposeView: View {
    struct Tile: Identifiable {
        let id: UInt32
        let app: String
        let title: String
        let tint: Color
        let image: NSImage?
        let hint: String
        let pickSlot: Int?
        let isAimed: Bool
        var appIcon: NSImage? = nil
        var staged: String? = nil      // drag-staged location badge, e.g. "¼ 1,0"
        var layerTags: [String] = []   // staged layer memberships (names) — shown as bottom labels
    }

    struct Cluster: Identifiable {
        let id: Int
        let name: String
        let rule: String
        let userDefined: Bool
        let hint: String          // ⇧-letter that plucks the whole cluster
        let searchQuery: String
        let searchActive: Bool
        let tiles: [Tile]
    }

    struct DisplayScope {
        let index: Int
        let count: Int
        let label: String
        let windowCount: Int
        let isActive: Bool
    }

    // A member window of a layer, placed on its screen-map preview at its real
    // (screen-relative, top-origin) fractional rect.
    struct LayerMember: Identifiable {
        let id: UInt32
        let frac: CGRect
        let tint: Color
        let image: NSImage?
        var behind: Bool = false   // covered by a more-front window on this display
    }

    // A layer rendered as a drop "pile": a screen-map preview of its member windows
    // (so you see *what the layer looks like*), its name + on-screen count + rule.
    // `staged` marks a pending join (highlight). The ＋ pile uses
    // HyperspaceDrag.newLayerKey as its id.
    struct LayerPile: Identifiable {
        let id: String
        let name: String
        let count: Int                       // members on the active screen
        var members: [LayerMember] = []      // for the screen-map preview
        var rule: String = ""                // human-readable match rule, e.g. "Chrome · ~dev"
        var clauses: [StudioLayerClause] = []// structured rules, for edit-mode removal
        var held: [WindowEntry] = []         // every window the layer holds, on any display
        var ruleWindows: [[WindowEntry]] = []// each rule's windows, beside `clauses`
        var isNew: Bool = false
        var staged: Bool = false
        var stagedCount: Int = 0             // how many windows are staged to join this pile
    }

    // A window's staged *location* drawn into the Lattice preview as proof of the plan:
    // a translucent app-tinted footprint at its fractional target rect (resolution-
    // agnostic), so the band shows where everything will land before you commit.
    struct StagedMarker: Identifiable {
        let id: UInt32          // wid
        let frac: CGRect        // x,y,w,h in 0…1, top-origin (PlacementSpec.fractions)
        let tint: Color
        let image: NSImage?
        let label: String       // e.g. "¼ 1,0"
    }

    let clusters: [Cluster]
    let tileWidth: CGFloat
    @ObservedObject var canvas: ExposeCanvas
    @ObservedObject var drag: HyperspaceDrag
    @ObservedObject private var liveTabs = LiveTabGroupStore.shared
    var screenID: String = ""
    var bandHeight: CGFloat = 200
    var inPlace: Bool = false
    var unifiedChrome: Bool = false
    var screenAspect: CGFloat = 1.6
    var usableInset = EdgeInsets()   // full panel(frame) → visibleFrame, so the Place stage clears the menu bar/Dock
    var onPick: (UInt32) -> Void = { _ in }
    var onDrop: (UInt32, PlacementSpec?) -> Void = { _, _ in }
    var onDropGridGroup: ([UInt32], LatticeRes, HoverCell) -> Void = { _, _, _ in }
    var onPlaceOnGrid: (Int, Int, LatticeRes) -> Void = { _, _, _ in }
    var onDropLayer: (UInt32, String) -> Void = { _, _ in }
    var onDropLayers: ([UInt32], String) -> Void = { _, _ in }
    var onSwap: (UInt32, UInt32) -> Void = { _, _ in }
    var onGridSelection: () -> Void = {}
    var onStackSelection: () -> Void = {}
    var onSwapFirstTwo: () -> Void = {}
    var onSwapWith: (UInt32, UInt32) -> Void = { _, _ in }
    var onFocusWindow: (UInt32) -> Void = { _ in }
    var onClearSelection: () -> Void = {}
    var onApplyPlacement: (UInt32, PlacementSpec) -> Void = { _, _ in }
    var onFillAvailable: (UInt32) -> Void = { _ in }
    var onOpenHyperspace: () -> Void = {}
    var onSnapshot: (@escaping (String?) -> Void) -> Void = { completion in
        completion("Display capture is unavailable")
    }
    var onCancel: () -> Void = {}
    var onKeep: () -> Void = {}
    var layers: [LayerPile] = []
    var stagedPlan: [StagedMarker] = []
    var hasLayoutProposal = false
    var currentLayout: [LayerMember] = []   // every window on this display — context for the Place stage
    var pickedWids: Set<UInt32> = []      // plucked on this screen — outlined brighter when focused
    var pickedOrder: [UInt32] = []        // pick order — swap uses the first two
    var layoutArea: CGRect = .zero        // desktop area the layout cards measure against
    var screenAX: CGRect = .zero          // full display, the space the proposal is drawn in
    var layoutPreview: HyperspaceLayoutPlan? = nil
    var onChooseLayout: ([UInt32], HyperspaceLayoutPlan) -> Void = { _, _ in }
    var onPlaceInProposal: ([UInt32], HyperspaceLayoutPlan) -> Void = { _, _ in }
    var canCycleLayout = false
    var layoutCycleTitle = ""
    var onCycleLayout: () -> Void = {}
    var hasSessionChanges = false
    var displayScope: DisplayScope?
    var onLayout: ([UInt32: CGRect]) -> Void = { _ in }
    var onHandKeys: (Bool) -> Void = { _ in }
    var onExit: () -> Void = { }              // mouse-driven leave (the ✕ button)
    var onNewLayer: () -> Void = { }          // tap the ＋ pile → open the New Layer authoring flow
    var onRecallLayer: (String) -> Void = { _ in } // add every live match to the survey selection
    var onBeginClusterSearch: (Int) -> Void = { _ in }
    var onClearClusterSearch: (Int) -> Void = { _ in }
    var onPluckGroup: (Int) -> Void = { _ in }
    var onFocusCluster: (Int) -> Void = { _ in }
    var onQuitCluster: (Int) -> Void = { _ in }
    var onEditClause: (String, Int?, StudioLayerClause) -> Void = { _, _, _ in }
    var onRemoveClause: (String, Int) -> Void = { _, _ in }  // edit mode: drop a rule clause (layerId, clauseIndex)
    var onDeleteLayer: (String) -> Void = { _ in }           // edit mode: delete a whole layer (layerId)
    var loadSummary: String = ""

    private let ink = Color(red: 0.02, green: 0.03, blue: 0.05)

    // Scope the light material to the consolidated session. Older callers keep
    // their existing appearance; the application's global palette is unchanged.
    private var chromeText: Color { unifiedChrome ? HyperspaceChrome.ink : Palette.text }
    private var chromeSecondary: Color { unifiedChrome ? HyperspaceChrome.secondary : Palette.textMuted }
    private var chromeAccent: Color { unifiedChrome ? HyperspaceChrome.sage : HUDChrome.cyan }
    private var chromeSelection: Color { unifiedChrome ? HyperspaceChrome.sage : Palette.running }
    private var chromeOnAccent: Color { unifiedChrome ? Color(nsColor: Lens.onAccent) : Palette.bg }
    private var chromeBorder: Color { unifiedChrome ? HyperspaceChrome.border : Palette.border }
    private var chromeWell: Color { unifiedChrome ? HyperspaceChrome.well : Color.white.opacity(0.05) }
    private func chromeBacking(_ darkOpacity: Double) -> Color {
        unifiedChrome ? Color.white.opacity(0.07) : Color.black.opacity(darkOpacity)
    }
    static let surveySpace = "hyperspace.survey"
    static let rootSpace = "hyperspace.root"   // band + survey + ghost share this space
    /// Overview drop tray. Tall enough to read a layout, short enough to leave the survey.
    static let layoutStageHeight: CGFloat = 128
    static let layoutStageGap: CGFloat = 14
    /// Clears the menu-bar HUD, which sits inside the visible frame.
    static let hudLane: CGFloat = 128

    // The lighting rig — all persisted, all live. The survey is lit like a room:
    // an ambient floor, one directional key light you can aim, a focus spotlight
    // that follows the aimed tile, and a warm↔cool temperature gel on the light.
    @AppStorage("hyperspace.ambient")   private var ambient: Double = 0.5
    @AppStorage("hyperspace.keyLight")  private var keyLight: Double = 0.4
    @AppStorage("hyperspace.keyAngle")  private var keyAngle: Int = 0       // 0 ◤ · 1 ▲ · 2 ◥
    @AppStorage("hyperspace.spotlight") private var spotlight: Double = 0.3
    @AppStorage("hyperspace.temp")      private var temp: Double = 0.5       // 0 cool · 1 warm

    // Size & layout. `sizeAuto` fills the display from the window count (the panel
    // does the fit); with it off, `tileScale` biases that base up or down. `layoutTall`
    // drops the per-cluster column cap so the lattice grows downward into the vertical.
    @AppStorage("hyperspace.sizeAuto")   private var sizeAuto: Bool = true
    @AppStorage("hyperspace.tileScale")  private var tileScale: Double = 1.0
    @AppStorage("hyperspace.layoutTall") private var layoutTall: Bool = false

    // Hand-split hint keys (assignment lives in the panel; the toggle pings it).
    @AppStorage("hyperspace.handKeys") private var handKeys: Bool = false

    // Perf A/B harness (diagnostic, not persisted): A = a plain dark-gray fill,
    // B = the full frosted stack. The HUD reads live frame cadence.
    // The visual-settings rig (lighting/size/zoom/keys/perf) lives behind a gear
    // in the top-right; collapsed by default so it doesn't cover the intent band.
    @State private var dialsOpen = false
    @State private var showInPlaceCommands = false
    @State private var showWindowInventory = false
    @State private var snapshotCountdown: Int?
    @State private var snapshotIsCapturing = false
    @State private var snapshotNotice: String?
    @State private var snapshotNoticeIsError = false

    @State private var perfMode = false
    @State private var perfFlat = false                  // A = true, B = false
    @StateObject private var perf = PerfStats()

    var body: some View {
        Group {
            if unifiedChrome && inPlace {
                ZStack {
                    Color.clear.allowsHitTesting(false)
                    placementStage
                }
                .coordinateSpace(name: ExposeView.rootSpace)
            } else {
                surveyBody
            }
        }
        .overlay(alignment: .bottom) {
            if unifiedChrome, !drag.isPlacing, let tool = canvas.tool {
                Group {
                    switch tool {
                    case .layers: layersSection
                    case .grid: gridSection
                    case .map: currentViewSection
                    }
                }
                .frame(width: min(760, (NSScreen.main?.frame.width ?? 900) - 64), height: 220)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ToolCardFrameKey.self,
                                               value: proxy.frame(in: .named(ExposeView.rootSpace)))
                    }
                }
                .padding(.bottom, layoutStageBottomInset + (showsLayoutStage ? Self.layoutStageHeight + Self.layoutStageGap : 0))
                .zIndex(20)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onPreferenceChange(ToolCardFrameKey.self) { frame in
            drag.toolFrames[screenID] = canvas.tool == nil ? .zero : frame
        }
        .animation(HyperspaceMotion.panel, value: canvas.tool)
    }

    /// Keep Hyperspace's existing full-screen survey, grouping, placement and
    /// layer interactions. The shared session only relocates its intent band.
    private var surveyBody: some View {
        ZStack {
            if inPlace {
                inPlaceSignatureBackdrop
            } else {
                backdrop
                VStack(spacing: 0) {
                    if !unifiedChrome {
                        overlayIntentChrome(mode: "hyperspace", detail: "window survey")
                    }
                    Group {
                        // The screen clears the top edge by the settings button's margin.
                        if unifiedChrome { overviewPlace.padding(.top, usableInset.top + 24) }
                        else { survey }
                    }
                        .padding(.bottom, unifiedChrome ? layoutStageBottomInset + Self.layoutStageHeight + Self.layoutStageGap : 0)
                }
            }
            if inPlace, !drag.isPlacing {
                VStack(spacing: 0) {
                    inPlaceHeader
                        .padding(.top, usableInset.top + 10)
                        .padding(.leading, max(12, usableInset.leading + 12))
                        .padding(.trailing, max(12, usableInset.trailing + 12))
                        .contentShape(Rectangle())
                    Spacer(minLength: 0).allowsHitTesting(false)
                    HStack(spacing: 0) {
                        inPlaceActionShelf
                            .contentShape(Rectangle())
                        Spacer(minLength: 0).allowsHitTesting(false)
                    }
                    .padding(.leading, max(16, usableInset.leading + 16))
                    .padding(.trailing, max(16, usableInset.trailing + 16))
                    .padding(.bottom, usableInset.bottom + 14)
                }
                if showWindowInventory {
                    VStack {
                        HStack {
                            Spacer(minLength: 0).allowsHitTesting(false)
                            floatingWindowInventory
                        }
                        Spacer(minLength: 0).allowsHitTesting(false)
                    }
                    .padding(.top, usableInset.top + 72)
                    .padding(.trailing, max(14, usableInset.trailing + 14))
                    .padding(.bottom, usableInset.bottom + 112)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            placementStage
            ghostOverlay
            dropPulseOverlay
        }
        .overlay(alignment: .bottom) { layoutStageOverlay }
        .coordinateSpace(name: ExposeView.rootSpace)    // band, survey, ghost, layout tray share one space
        .onChange(of: showsLayoutStage) { _, shown in
            if !shown {
                drag.layoutCardFrames[screenID] = [:]
                if drag.screenID == screenID { drag.hoverLayoutTitle = nil }
            }
        }
        .animation(HyperspaceMotion.panel, value: rosterPileID)
        .animation(HyperspaceMotion.panel, value: drag.placeWid)
        .animation(HyperspaceMotion.drag, value: drag.placeCell)
        .overlay(alignment: .bottomLeading) {
            if !unifiedChrome, !drag.isPlacing {
                LatticesOverlayWatermarkPlacement()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !inPlace, !drag.isPlacing, !liveTabGroupsOnScreen.isEmpty {
                liveTabGroupShelf
                    .padding(.trailing, 20)
                    .padding(.bottom, showsLayoutStage ? layoutStageBottomInset + Self.layoutStageHeight + Self.layoutStageGap : 20)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !inPlace, !drag.isPlacing {                  // the Place stage owns the screen
                VStack(alignment: .trailing, spacing: 8) {
                    if !unifiedChrome { exitButton }
                    settingsToggle
                    if dialsOpen { dials }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .top) {
            if perfMode {
                perfHUD.padding(.top, 22)
            }
        }
        .overlay(alignment: .top) {
            if !unifiedChrome, !inPlace, !drag.isPlacing {
                planSummaryBar.padding(.top, intentChromeHeight + 4)   // sits just under the intent strip
            }
        }
        .overlay {
            if let id = drag.selectedLayer, let pile = layers.first(where: { $0.id == id }) {
                layerInspector(pile).transition(.opacity)
            }
        }
        .animation(HyperspaceMotion.inspector, value: drag.selectedLayer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveTabGroupsOnScreen: [LiveTabGroup] {
        let visibleWindowIDs = Set(clusters.flatMap(\.tiles).map(\.id))
        return liveTabs.groups.filter { group in
            group.members.contains { visibleWindowIDs.contains($0.id) }
        }
    }

    private var liveTabGroupShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HUDChrome.cyan)
                Text("GROUPINGS")
                    .font(Typo.monoBold(9))
                    .tracking(1.05)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text("\(liveTabGroupsOnScreen.count)")
                    .font(Typo.monoBold(8))
                    .foregroundStyle(Palette.textDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            ForEach(liveTabGroupsOnScreen) { group in
                liveTabGroupShelfRow(group)
            }
        }
        .padding(10)
        .frame(width: 318)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [HUDChrome.baseTop.opacity(0.96), HUDChrome.baseBottom.opacity(0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(HUDChrome.glassStrokeSoft, lineWidth: 0.75)
                )
        )
        .shadow(color: Color.black.opacity(0.44), radius: 18, y: 8)
    }

    private func liveTabGroupShelfRow(_ group: LiveTabGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                liveTabs.activate(id: group.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(group.id == liveTabs.activeGroupID ? HUDChrome.cyan : Palette.textMuted)
                            .frame(width: 5, height: 5)
                        Text(group.name)
                            .font(Typo.heading(11))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Text("\(group.members.count)")
                            .font(Typo.monoBold(8))
                            .foregroundStyle(Palette.textMuted)
                    }
                    HStack(spacing: 4) {
                        ForEach(group.members.prefix(4)) { member in
                            Text(member.app)
                                .font(Typo.caption(8))
                                .foregroundStyle(Palette.textMuted)
                                .lineLimit(1)
                        }
                        if group.members.count > 4 {
                            Text("+\(group.members.count - 4)")
                                .font(Typo.monoBold(8))
                                .foregroundStyle(Palette.textDim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                liveTabs.toggleLayout(id: group.id)
            } label: {
                Image(systemName: group.isExpanded ? "rectangle.stack.fill" : "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(group.isExpanded ? HUDChrome.cyan : Palette.textMuted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help(group.isExpanded ? "Return to tabs" : "Split inside the tab group's bounds")

            Button {
                liveTabs.toggleGuideVisibility(id: group.id)
            } label: {
                Image(systemName: group.isGuideVisible ? "pin.fill" : "pin.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(group.isGuideVisible ? HUDChrome.cyan : Palette.textMuted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help(group.isGuideVisible ? "Hide the floating tab tools" : "Keep the floating tab tools visible")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(group.id == liveTabs.activeGroupID ? HUDChrome.cyan.opacity(0.09) : Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(group.id == liveTabs.activeGroupID ? HUDChrome.cyan.opacity(0.28) : HUDChrome.glassStrokeSoft, lineWidth: 0.6)
                )
        )
        .contextMenu {
            Button(role: .destructive) {
                liveTabs.delete(id: group.id)
            } label: {
                Label("Ungroup", systemImage: "minus.circle")
            }
        }
    }

    // A one-line readout of the whole staged plan, so the grouped intent reads at a
    // glance and the commit/discard affordance is always in view. Shown only when
    // something is staged. Derived from the on-screen tiles (single-screen drag).
    @ViewBuilder
    private var planSummaryBar: some View {
        let tiles = clusters.flatMap(\.tiles)
        let placed = tiles.filter { $0.staged != nil }.count
        let tagged = tiles.filter { !$0.layerTags.isEmpty }.count
        if placed + tagged > 0 {
            HStack(spacing: 10) {
                if placed > 0 { planChip("▦", "\(placed) placed") }
                if tagged > 0 { planChip("▢", "\(tagged) tagged") }
                Rectangle().fill(Palette.border).frame(width: 0.5, height: 12)
                Text("⏎ commit").font(Typo.monoBold(9)).foregroundColor(Palette.running)
                Text("esc discard").font(Typo.mono(9)).foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(Color.black.opacity(0.6))
                    .overlay(Capsule().strokeBorder(Palette.running.opacity(0.4), lineWidth: 0.5))
            )
            .transition(.opacity)
            .animation(HyperspaceMotion.panel, value: placed + tagged)
        }
    }

    private func planChip(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(glyph).font(.system(size: 10)).foregroundColor(Palette.running)
            Text(label).font(Typo.monoBold(9)).foregroundColor(.white.opacity(0.85))
        }
    }

    // The lit room behind everything. Under the perf harness it repaints every
    // frame (and feeds the cadence meter); otherwise it's a static pass.
    @ViewBuilder
    private var backdrop: some View {
        if perfMode {
            TimelineView(.animation) { ctx in
                scrim(phase: ctx.date.timeIntervalSinceReferenceDate)
                    .onChange(of: ctx.date) { _, d in perf.record(d.timeIntervalSinceReferenceDate) }
            }
        } else {
            scrim(phase: 0)
        }
    }

    // The window lattice — the bottom two-thirds. Top-anchored (frame alignment .top)
    // so the lattice sits just under the intent band instead of being centred in the
    // bottom region with a gap above it. Pure view transform (zoom/pan); no real
    // window moves here.
    private var survey: some View {
        FlowLayout(spacing: unifiedChrome ? 28 : 18, lineSpacing: unifiedChrome ? 28 : 18, vAlign: .top) {
            ForEach(clusters) { clusterBox($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: unifiedChrome ? .center : .top)
        .padding(.horizontal, 36)
        .padding(.top, 20)
        .padding(.bottom, 36)
        .coordinateSpace(name: ExposeView.surveySpace)   // tile frames measured here stay un-scaled
        .scaleEffect(canvas.zoom, anchor: .center)        // canvas zoom — transform sits OUTSIDE the space
        .offset(canvas.pan)
        .onPreferenceChange(TileFramesKey.self) { onLayout($0) }
    }

    /// Overview is a screen you place onto, and a lineup you pick from.
    /// Dragging across the screen suggests the same kinds of spots as the desktop.
    private var overviewPlace: some View {
        GeometryReader { geo in
            let lineupH: CGFloat = 124
            let gap: CGFloat = 16
            let available = CGSize(width: max(1, geo.size.width - 48),
                                   height: max(1, geo.size.height - lineupH - gap - 4))
            let box = aspectFit(in: available, aspect: max(0.4, screenAspect))
            let tiles = clusters.flatMap(\.tiles)
            VStack(spacing: gap) {
                overviewScreen(box: box, tiles: tiles)
                    .frame(width: box.width, height: box.height)
                overviewLineup(tiles, width: geo.size.width)
                    .frame(maxWidth: .infinity)
                    .frame(height: lineupH)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPreferenceChange(ProposalCanvasKey.self) { drag.proposalCanvas[screenID] = $0 }
    }

    private func overviewScreen(box: CGSize, tiles: [Tile]) -> some View {
        let draggingHere = drag.isActive && drag.screenID == screenID
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.14))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(draggingHere ? 0.8 : 0.45), lineWidth: draggingHere ? 1.5 : 1)
            // Idle, the screen shows where windows sit now: hairlines, no pictures.
            if unifiedChrome && stagedPlan.isEmpty && !(draggingHere && drag.placementPreview != nil) {
                ForEach(currentLayout) { m in
                    let r = CGRect(x: m.frac.minX * box.width, y: m.frac.minY * box.height,
                                   width: max(2, m.frac.width * box.width), height: max(2, m.frac.height * box.height))
                    let lit = pickedWids.contains(m.id)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(lit ? 0.16 : 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(lit ? 0.6 : 0.3), lineWidth: 0.5))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                .allowsHitTesting(false)
            }
            if stagedPlan.isEmpty && drag.placementPreview == nil && (draggingHere || !unifiedChrome) {
                Text(overviewHint(dragging: draggingHere))
                    .font(Typo.caption(13))
                    .foregroundColor(chromeSecondary)
            }
            ForEach(stagedPlan) { marker in
                if let tile = tiles.first(where: { $0.id == marker.id }) {
                    proposalWindow(tile, frac: marker.frac, box: box, selected: true)
                } else {
                    currentViewWindow(marker.frac, chromeAccent, marker.image, box, staged: true)
                }
            }
            if draggingHere, let preview = drag.placementPreview {
                let bunch = preview.frames.count > 1 && HyperspaceLayoutPlanner.isArrangement(preview.title)
                ForEach(preview.frames.keys.sorted(), id: \.self) { id in
                    if let frame = preview.frames[id] {
                        proposalPlacementWell(frame, in: box,
                                              label: bunch ? nil : (id == drag.wid ? placementLabel(preview.title) : nil),
                                              image: layoutTileImages[id])
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .top) {
            overviewStyleControl(dragging: draggingHere)
                .padding(.top, 12)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ProposalCanvasKey.self,
                                       value: proxy.frame(in: .named(ExposeView.rootSpace)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen")
    }

    /// Centred under the screen; it scrolls only when the tiles outgrow the display.
    private func overviewLineup(_ tiles: [Tile], width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(tiles) { tile in
                    tileView(tile, width: 156)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 2)
            .frame(minWidth: width, alignment: .center)
        }
        .accessibilityLabel("Window lineup")
    }

    /// The existing screen-map window renderer, expanded into the main stage.
    /// The same staged fractions remain available to the precise Grid component.
    private var layoutProposal: some View {
        GeometryReader { geo in
            let tiles = clusters.flatMap(\.tiles)
            let companions = tiles.filter { !stagedPlan.map(\.id).contains($0.id) }
            let rail: CGFloat = companions.isEmpty || geo.size.width < 1000 ? 0 : min(240, geo.size.width * 0.19)
            let available = CGSize(width: max(1, geo.size.width - 96 - rail), height: max(1, geo.size.height - 64))
            let box = aspectFit(in: available, aspect: screenAspect)
            HStack(spacing: 28) {
                ZStack(alignment: .topLeading) {
                    ForEach(stagedPlan) { marker in
                        if let tile = tiles.first(where: { $0.id == marker.id }) {
                            proposalWindow(tile, frac: marker.frac, box: box, selected: true)
                        } else {
                            currentViewWindow(marker.frac, chromeAccent, marker.image, box, staged: true)
                        }
                    }
                    if drag.isActive, drag.screenID == screenID, let preview = drag.placementPreview {
                        let bunch = preview.frames.count > 1 && HyperspaceLayoutPlanner.isArrangement(preview.title)
                        ForEach(preview.frames.sorted { $0.key < $1.key }, id: \.key) { id, frame in
                            proposalPlacementWell(frame, in: box,
                                                  label: bunch ? nil : (id == drag.wid ? placementLabel(preview.title) : nil),
                                                  image: layoutTileImages[id])
                        }
                    }
                }
                .frame(width: box.width, height: box.height)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ProposalCanvasKey.self,
                                               value: proxy.frame(in: .named(ExposeView.rootSpace)))
                    }
                }
                if rail > 0 {
                    ScrollView {
                        VStack(spacing: 18) {
                            ForEach(companions) { tile in
                                tileView(tile, width: rail - 8)
                            }
                        }.padding(4)
                    }
                    .frame(width: rail, height: box.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: ExposeView.surveySpace)
        .onPreferenceChange(TileFramesKey.self) { onLayout($0) }
        .onPreferenceChange(ProposalCanvasKey.self) { drag.proposalCanvas[screenID] = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed window arrangement")
    }

    private func placementLabel(_ title: String) -> String {
        title == "Move window" ? "Here" : layoutCardTitle(.init(title: title, frames: [:]))
    }

    private func overviewHint(dragging: Bool) -> String {
        if dragging { return drag.dragWids.count > 1 ? "Bring them onto the screen" : "Bring it onto the screen" }
        return "Drag a window onto the screen"
    }

    /// The style under the hand while a bunch is carried, or the tap that
    /// advances to the next one once the bunch is on the screen.
    @ViewBuilder
    private func overviewStyleControl(dragging: Bool) -> some View {
        if dragging, let preview = drag.placementPreview, drag.screenID == screenID,
           preview.frames.count > 1, HyperspaceLayoutPlanner.isArrangement(preview.title) {
            overviewStyleCapsule(layoutCardTitle(preview), action: nil)
        } else if !dragging, canCycleLayout, !layoutCycleTitle.isEmpty {
            overviewStyleCapsule(layoutCardTitle(.init(title: layoutCycleTitle, frames: [:])), action: onCycleLayout)
        }
    }

    private func overviewStyleCapsule(_ title: String, action: (() -> Void)?) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(Typo.caption(12))
                .fontWeight(.semibold)
        }
        .foregroundColor(HyperspaceChrome.paperInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.92)))
        .overlay(Capsule().strokeBorder(chromeAccent.opacity(0.45), lineWidth: 1))
        return Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label.allowsHitTesting(false)
            }
        }
        .help(action == nil ? title : "Next layout")
        .accessibilityLabel(action == nil ? title : "Next layout")
        .accessibilityValue(title)
    }

    private func proposalFraction(_ frame: CGRect) -> CGRect {
        guard screenAX.width > 1, screenAX.height > 1 else { return .zero }
        let x = (frame.minX - screenAX.minX) / screenAX.width
        let y = (frame.minY - screenAX.minY) / screenAX.height
        return CGRect(x: x, y: y, width: frame.width / screenAX.width, height: frame.height / screenAX.height)
    }

    private func proposalPlacementWell(_ frame: CGRect, in box: CGSize, label: String?, image: NSImage?) -> some View {
        let frac = proposalFraction(frame)
        let width = max(8, frac.width * box.width - 6)
        let height = max(8, frac.height * box.height - 6)
        let shape = RoundedRectangle(cornerRadius: WindowHoverPreview.plateCornerRadius, style: .continuous)
        let fill = image == nil
            ? WindowHoverPreview.plateFill
            : WindowHoverPreview.plateFill.withAlphaComponent(0.28)
        return ZStack(alignment: .top) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(0.85)
            }
            shape.fill(Color(nsColor: fill))
            shape.strokeBorder(Color(nsColor: WindowHoverPreview.plateStroke), lineWidth: WindowHoverPreview.plateBorderWidth)
            if let label {
                Text(label)
                    .font(Typo.caption(12))
                    .fontWeight(.semibold)
                    .foregroundColor(HyperspaceChrome.paperInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .padding(.top, 12)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .position(x: frac.midX * box.width, y: frac.midY * box.height)
        .allowsHitTesting(false)
        .accessibilityLabel(label ?? "Landing spot")
    }

    /// The current-map renderer remains the preview source. Ordered captions
    /// and existing pick/drag callbacks make the full-size proposal operable.
    private func proposalWindow(_ tile: Tile, frac: CGRect, box: CGSize, selected: Bool) -> some View {
        let width = max(2, frac.width * box.width)
        let height = max(2, frac.height * box.height)
        return ZStack(alignment: .topLeading) {
            currentViewWindow(CGRect(x: 0, y: 0, width: 1, height: 1), chromeAccent, tile.image,
                              CGSize(width: width, height: height), staged: selected)
            HStack(spacing: 7) {
                if let slot = pickedOrder.firstIndex(of: tile.id) {
                    Text("\(slot + 1)").font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.white).frame(width: 18, height: 18)
                        .background(Circle().fill(slotTint(slot + 1)))
                }
                Text(tile.app).font(.system(size: 11, weight: .semibold))
                Text(tile.title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(chromeText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(HyperspaceGlassBackground(cornerRadius: 10))
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(drag.isActive && drag.dragWids.contains(tile.id) ? 0.35 : 1)
        .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 10)
        .position(x: frac.midX * box.width, y: frac.midY * box.height)
        .background(frameReporter(tile.id))
        .contentShape(Rectangle())
        .onTapGesture { onPick(tile.id) }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(ExposeView.rootSpace))
            .onChanged { handleDragChange(tile, tileWidth: min(168, max(96, width * 0.34)), solo: true, $0) }
            .onEnded { handleDragEnd(tile, $0) })
        .contextMenu { windowContextMenu(tile) }
        .accessibilityLabel("\(tile.app), \(tile.title), selected \(pickSlot(for: tile.id) ?? 0)")
    }

    // MARK: - Placement stage — right-click a window, pick its spot life-size
    //
    // A modal, life-size stage over the desktop area: the screen with its current windows drawn
    // faint for context, the right-clicked window as a bright ghost, and a grid of the active
    // resolution you *click* to place it. Mouse-only twin of drag → Grid — clicking a cell runs
    // the same `onDrop` staging path. Click-away or Esc cancels.
    @ViewBuilder
    private var placementStage: some View {
        if let wid = drag.placeWid, drag.placeScreen == screenID {
            let target = currentLayout.first { $0.id == wid }
            GeometryReader { geo in
                // A miniature of *this* monitor — bezel + screen — floating in a heavy scrim that
                // swallows the desktop noise. The screen shows the **projected future** layout (staged
                // moves applied), divided into clickable sections. A contained object, not a takeover:
                // it can't leak off-screen and it reads as a deliberate control.
                let screen = aspectFit(in: CGSize(width: geo.size.width * 0.52,
                                                  height: geo.size.height * 0.56), aspect: screenAspect)
                ZStack {
                    Color.black.opacity(0.96)                          // swallow the noise around the vessel
                        .contentShape(Rectangle())
                        .onTapGesture { drag.endPlacing() }            // click-away cancels
                    // Monitor centred in the screen; caption floats just above it (an overlay, so it
                    // doesn't push the monitor off-centre).
                    monitorVessel(screen: screen, wid: wid, target: target)
                        .overlay(alignment: .top) {
                            placementCaption(wid: wid).fixedSize().offset(y: -34)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    // The miniature monitor: a bezel framing a screen that shows the *projected future* layout —
    // unchanged windows faint, staged moves bright at their new spots, the window being placed
    // tracking the hovered section. The bezel + heavy surrounding scrim make it read as an object.
    private func monitorVessel(screen: CGSize, wid: UInt32, target: ExposeView.LayerMember?) -> some View {
        let bezel: CGFloat = 16
        let screenShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let stagedById = Dictionary(stagedPlan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            screenShape.fill(Color(red: 0.05, green: 0.06, blue: 0.08))           // opaque "screen" — no see-through
                .overlay(screenShape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                                         startPoint: .top, endPoint: .bottom)))
            // The projected future screen: every window where it *will* be after commit.
            ForEach(currentLayout.filter { $0.id != wid }) { m in
                if let s = stagedById[m.id] {
                    zoneRect(s.frac, s.tint, s.image, screen, .staged)     // a staged move — bright, at its new spot
                } else {
                    zoneRect(m.frac, m.tint, nil, screen, .baseline)       // unchanged — a faint footprint
                }
            }
            placementGrid(wid: wid, stage: screen, tint: target?.tint ?? Palette.running)
            placementGhost(target: target, stage: screen)                  // the window being placed
        }
        .frame(width: screen.width, height: screen.height)
        .clipShape(screenShape)
        .overlay(screenShape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, bezel).padding(.top, bezel).padding(.bottom, bezel + 10)   // bezel + chin
        .background(
            RoundedRectangle(cornerRadius: bezel + 8, style: .continuous)
                .fill(Color(white: 0.07))
                .overlay(RoundedRectangle(cornerRadius: bezel + 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
        )
        .overlay(alignment: .bottom) {                                     // a little brand dot on the chin
            Circle().fill(.white.opacity(0.22)).frame(width: 5, height: 5).padding(.bottom, 6)
        }
    }

    // The clickable grid laid over the stage at the active resolution. Hover lights a cell;
    // click stages that position for the window and closes the stage.
    private func placementGrid(wid: UInt32, stage: CGSize, tint: Color) -> some View {
        let (cols, rows) = drag.baseRes.dims
        let cw = stage.width / CGFloat(cols)
        let ch = stage.height / CGFloat(rows)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<rows, id: \.self) { r in
                ForEach(0..<cols, id: \.self) { c in
                    let cell = HoverCell(col: c, row: r)
                    let lit = drag.placeCell == cell
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(lit ? tint.opacity(0.18) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(lit ? tint : .white.opacity(0.22), lineWidth: lit ? 2.5 : 1))
                        .frame(width: cw - 6, height: ch - 6)
                        .contentShape(Rectangle())
                        .onHover { if $0 { drag.placeCell = cell } }
                        .onTapGesture { commitPlacement(wid: wid, col: c, row: r) }
                        .position(x: CGFloat(c) * cw + cw / 2, y: CGFloat(r) * ch + ch / 2)
                }
            }
        }
        .frame(width: stage.width, height: stage.height)
    }

    // The window being placed. While hovering a section the preview snaps to it, *exactly*
    // section-sized (never bigger than the spot). At rest it's just a quiet dashed outline at the
    // window's current/projected spot — so you see which window you're moving and where it is now.
    @ViewBuilder
    private func placementGhost(target: ExposeView.LayerMember?, stage: CGSize) -> some View {
        let tint = target?.tint ?? Palette.running
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let cell = drag.placeCell {
            let (cols, rows) = drag.baseRes.dims
            let frac = CGRect(x: CGFloat(cell.col) / CGFloat(cols), y: CGFloat(cell.row) / CGFloat(rows),
                              width: 1 / CGFloat(cols), height: 1 / CGFloat(rows))
            let r = CGRect(x: frac.minX * stage.width, y: frac.minY * stage.height,
                           width: frac.width * stage.width, height: frac.height * stage.height)
            ZStack {
                shape.fill(tint.opacity(0.26))
                if let img = target?.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).opacity(0.45)
                }
            }
            .frame(width: max(8, r.width - 8), height: max(8, r.height - 8))
            .clipShape(shape)
            .overlay(shape.strokeBorder(tint, lineWidth: 3))
            .shadow(color: tint.opacity(0.5), radius: 14)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
        } else {
            let restFrac: CGRect? = {
                if let wid = drag.placeWid, let s = stagedPlan.first(where: { $0.id == wid }) { return s.frac }
                return target?.frac
            }()
            if let f = restFrac {
                let r = CGRect(x: f.minX * stage.width, y: f.minY * stage.height,
                               width: f.width * stage.width, height: f.height * stage.height)
                shape.fill(tint.opacity(0.10))
                    .overlay(shape.strokeBorder(tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .frame(width: max(8, r.width - 6), height: max(8, r.height - 6))
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func placementCaption(wid: UInt32) -> some View {
        let t = clusters.flatMap(\.tiles).first { $0.id == wid }
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.running)
                Text("Place \(t?.app ?? "window")").font(Typo.monoBold(11)).foregroundColor(.white)
                if let title = t?.title, !title.isEmpty {
                    Text(title).font(Typo.mono(9)).foregroundColor(Palette.textMuted).lineLimit(1)
                }
            }
            Rectangle().fill(Palette.border).frame(width: 0.5, height: 14)
            placeResSelector
            Rectangle().fill(Palette.border).frame(width: 0.5, height: 14)
            Text(inPlace
                 ? "click a section to stage · Keep applies it · esc cancel"
                 : "click a section · esc cancel")
                .font(Typo.mono(9))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.6))
            .overlay(Capsule().strokeBorder(Palette.running.opacity(0.4), lineWidth: 0.5)))
    }

    @ViewBuilder
    private var placeResSelector: some View {
        ForEach(LatticeRes.allCases, id: \.rawValue) { r in
            let active = drag.baseRes == r
            Button { drag.baseRes = r; drag.placeCell = nil } label: {
                resIcon(r, active: active)
                    .padding(.horizontal, 5).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(active ? Palette.running : Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(active ? Palette.running : Palette.border, lineWidth: active ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help(r.name)
        }
    }

    private func commitPlacement(wid: UInt32, col: Int, row: Int) {
        let (cols, rows) = drag.baseRes.dims
        let spec = GridPlacement(columns: cols, rows: rows, column: col, row: row).map(PlacementSpec.grid)
        drag.endPlacing()
        onDrop(wid, spec)
    }

    private enum InPlaceCommandRail { case leading, trailing }

    // In-place command hints flank the Current View mini-map — mouse + keys on the sides.
    private func inPlaceCommandRail(_ side: InPlaceCommandRail) -> some View {
        let leading = side == .leading
        let hints: [(String, String)] = leading
            ? [("a–z", "select"), ("S", "swap"), ("G", "grid"), ("F", "fill"), ("drag", "stage")]
            : [("⏎", "commit"), ("esc", "discard"), ("Hyper+␣", "survey")]
        return VStack(alignment: leading ? .leading : .trailing, spacing: 6) {
            inPlaceMouseCommandHint(side: side)
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                inPlaceCommandHint(key: hint.0, label: hint.1, leading: leading)
            }
        }
        .frame(width: leading ? 76 : 86, alignment: leading ? .leading : .trailing)
    }

    private func inPlaceCommandHint(key: String, label: String, leading: Bool) -> some View {
        HStack(spacing: 5) {
            if !leading { inPlaceCommandLabel(label) }
            inPlaceCommandKey(key)
            if leading { inPlaceCommandLabel(label) }
        }
        .lineLimit(1)
    }

    private func inPlaceCommandLabel(_ label: String) -> some View {
        Text(label)
            .font(Typo.mono(10))
            .foregroundColor(Palette.textDim)
    }

    private func inPlaceCommandKey(_ key: String) -> some View {
        Text(key)
            .font(Typo.monoBold(10))
            .foregroundColor(Palette.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.borderLit, lineWidth: 0.5))
            )
    }

    private func inPlaceMouseCommandHint(side: InPlaceCommandRail) -> some View {
        let leading = side == .leading
        let icon = leading ? "hand.tap.fill" : "contextualmenu.and.cursorarrow"
        let key = leading ? "click" : "right-click"
        let label = leading ? "select" : "actions"
        return HStack(spacing: 5) {
            if !leading { inPlaceCommandLabel(label) }
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Palette.running.opacity(0.9))
            inPlaceCommandKey(key)
            if leading { inPlaceCommandLabel(label) }
        }
        .lineLimit(1)
    }

    // Mouse-driven leave: the keyboard has Enter (commit) / Esc (discard), but there was no
    // way out with the trackpad. This ✕ just *closes* the survey, keeping whatever's on screen
    // (Esc remains the explicit discard/revert). Top-right, above the gear.
    private var exitButton: some View {
        Button { onExit() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(chromeText.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(chromeBacking(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(chromeBorder, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help(inPlace ? "Exit In-Place" : "Exit Hyperspace")
    }

    // The gear that reveals the control rig. Small by default so the intent band
    // and the upper third of the survey stay visible.
    private var settingsToggle: some View {
        Button { dialsOpen.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(dialsOpen ? chromeOnAccent : chromeText.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(dialsOpen ? chromeSelection : chromeBacking(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(chromeBorder, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help("Visual settings")
    }

    // The control rig — a compact stack top-right, clear of the legend (bottom)
    // and minimap (bottom-left). Lighting, then layout, then keys. Every value persists.
    private var dials: some View {
        VStack(alignment: .leading, spacing: 7) {
            dial("moon.stars",         "amb",  $ambient)
            keyRow
            dial("flashlight.on.fill", "spot", $spotlight)
            dial("thermometer.medium", "temp", $temp) { _ in temp < 0.45 ? "cool" : temp > 0.55 ? "warm" : "·" }
            divider
            sizeRow
            zoomRow
            twoWay("rectangle.grid.2x2", "scan", "tall", isFirst: !layoutTall) { layoutTall = !$0 }
            twoWay("keyboard", "read", "hands", isFirst: !handKeys) { handKeys = !$0; onHandKeys(handKeys) }
            divider
            HStack(spacing: 8) {
                perfToggle
                Spacer(minLength: 0)
                if perfMode { abToggle }
            }
            if !loadSummary.isEmpty {
                Text(loadSummary)
                    .font(Typo.mono(8))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        )
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(height: 0.5).padding(.vertical, 1)
    }

    // The key-light row: an intensity slider plus a three-way origin picker (◤ ▲ ◥).
    private var keyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max").font(.system(size: 10)).foregroundColor(.white.opacity(0.6)).frame(width: 14)
            Text("key").font(Typo.mono(9)).foregroundColor(.white.opacity(0.45)).frame(width: 28, alignment: .leading)
            Slider(value: $keyLight, in: 0...1).frame(width: 70).controlSize(.mini).tint(Palette.running)
            HStack(spacing: 2) { angleSeg(0, "◤"); angleSeg(1, "▲"); angleSeg(2, "◥") }
        }
    }

    private func angleSeg(_ a: Int, _ glyph: String) -> some View {
        Button { keyAngle = a } label: {
            Text(glyph).font(.system(size: 9))
                .foregroundColor(keyAngle == a ? Palette.bg : .white.opacity(0.5))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(keyAngle == a ? Palette.running : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    // Size row: an "auto" pill (default on — the panel fits tiles to the window count)
    // plus a manual bias slider. Auto dims the slider; grabbing it takes manual over.
    private var sizeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.6)).frame(width: 14)
            Text("size").font(Typo.mono(9)).foregroundColor(.white.opacity(0.45)).frame(width: 28, alignment: .leading)
            Slider(value: $tileScale, in: 0.55...1.7, onEditingChanged: { editing in if editing { sizeAuto = false } })
                .frame(width: 66).controlSize(.mini).tint(Palette.running)
                .opacity(sizeAuto ? 0.35 : 1)
            pill("auto", sizeAuto) { sizeAuto.toggle() }
            Text(sizeAuto ? "auto" : String(format: "%.2f×", tileScale))
                .font(Typo.mono(9)).foregroundColor(.white.opacity(0.5)).frame(width: 30, alignment: .trailing)
        }
    }

    // Canvas zoom — driven by ⌘-scroll / =/− (not a slider), so this is a live readout
    // plus a "fit" pill that snaps back to 1×. Separate axis from the size dial above:
    // size lays tiles bigger/smaller; zoom magnifies the whole spread to lean into a region.
    private var zoomRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.6)).frame(width: 14)
            Text("zoom").font(Typo.mono(9)).foregroundColor(.white.opacity(0.45)).frame(width: 28, alignment: .leading)
            Text("⌘scroll").font(Typo.mono(9)).foregroundColor(.white.opacity(0.3))
            Spacer(minLength: 0)
            pill("fit", canvas.zoom <= 1.0001) { canvas.reset() }
            Text(String(format: "%.1f×", canvas.zoom))
                .font(Typo.mono(9)).foregroundColor(.white.opacity(0.5)).frame(width: 30, alignment: .trailing)
        }
    }

    private func dial(_ icon: String, _ label: String, _ value: Binding<Double>,
                      in range: ClosedRange<Double> = 0...1,
                      readout: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 14)
            Text(label)
                .font(Typo.mono(9))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 28, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 104)
                .controlSize(.mini)
                .tint(Palette.running)
            Text(readout?(value.wrappedValue) ?? "\(Int((value.wrappedValue * 100).rounded()))")
                .font(Typo.mono(9))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 30, alignment: .trailing)
        }
    }

    // A two-segment pill toggle (label-driven). `isFirst` selects the left segment;
    // `set` is called with the new "is-first" state when either segment is tapped.
    private func twoWay(_ icon: String, _ a: String, _ b: String, isFirst: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.white.opacity(0.6)).frame(width: 14)
            HStack(spacing: 2) {
                pill(a, isFirst)  { set(true) }
                pill(b, !isFirst) { set(false) }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
            Spacer(minLength: 0)
        }
    }

    private func pill(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.monoBold(9))
                .foregroundColor(on ? Palette.bg : .white.opacity(0.55))
                .padding(.horizontal, 9).frame(height: 16)
                .background(Capsule().fill(on ? Palette.running : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // Treatment A vs B. A is a plain opaque dark-gray fill — the cheapest possible
    // backdrop, the baseline. B is the lit room: behind-window blur + an ambient
    // floor + a directional, temperature-gelled key light + a vignette that deepens
    // as the room darkens. `phase` is non-zero only under the perf harness, where it
    // gives the key light a faint breathing drift so the renderer has real work to do.
    @ViewBuilder
    private func scrim(phase: Double) -> some View {
        if unifiedChrome {
            HyperspaceDesktopBackground()
                .ignoresSafeArea()
        } else if perfFlat {
            Color(red: 0.11, green: 0.11, blue: 0.12)   // A — flat fill, no lighting
        } else {
            ZStack {
                // Frosted glass: blur the real desktop into a soft wash.
                VisualEffectBackdrop(material: .hudWindow)
                    .ignoresSafeArea()

                LatticesLatticeGrid(spacing: 26, opacity: 0.04, tint: Palette.running)
                    .ignoresSafeArea()

                // Ambient floor: how lit the room is. Low = near-black and dramatic,
                // high = airy. A little blur always survives so it never goes flat.
                Color.black.opacity(0.82 - ambient * 0.60)

                // Directional key light, gelled warm↔cool by temperature.
                EllipticalGradient(
                    colors: [lightColor.opacity(keyLight * 0.5), .clear],
                    center: keyCenter,
                    startRadiusFraction: 0,
                    endRadiusFraction: 1.0 + 0.06 * CGFloat(sin(phase * 2))
                )

                // Vignette — deepens as the room darkens, so bright vibes stay open.
                EllipticalGradient(
                    colors: [.clear, Color.black.opacity(0.30 * (1 - ambient * 0.5))],
                    center: .center,
                    startRadiusFraction: 0.5,
                    endRadiusFraction: 1.0
                )
            }
        }
    }

    // Where the key light originates: ◤ top-left, ▲ top, ◥ top-right.
    private var keyCenter: UnitPoint {
        switch keyAngle { case 0: return .topLeading; case 2: return .topTrailing; default: return .top }
    }

    // The light's colour along a cool→neutral→warm temperature axis.
    private var lightColor: Color {
        func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
        let cool = (0.60, 0.71, 0.96), neutral = (0.86, 0.88, 0.92), warm = (1.00, 0.83, 0.60)
        if temp < 0.5 {
            let f = temp / 0.5
            return Color(red: lerp(cool.0, neutral.0, f), green: lerp(cool.1, neutral.1, f), blue: lerp(cool.2, neutral.2, f))
        } else {
            let f = (temp - 0.5) / 0.5
            return Color(red: lerp(neutral.0, warm.0, f), green: lerp(neutral.1, warm.1, f), blue: lerp(neutral.2, warm.2, f))
        }
    }

    // Effective tile width — the panel's fill-fit base, optionally biased by the size
    // dial — and the per-cluster column cap (lower in "tall" so the lattice fills the
    // vertical space).
    private var tile: CGFloat {
        sizeAuto ? tileWidth : (tileWidth * CGFloat(tileScale)).rounded()
    }
    private var colCap: Int { layoutTall ? 2 : 4 }

    // MARK: Perf harness UI

    private var perfHUD: some View {
        HStack(spacing: 16) {
            perfStat(perfFlat ? "A · flat fill" : "B · full stack", Palette.running)
            perfStat(String(format: "%.0f fps", perf.fps), .white)
            perfStat(String(format: "%.1f ms", perf.ms), .white)
            perfStat(String(format: "worst %.1f", perf.worstMs), perf.worstMs > 18 ? Palette.detach : .white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        )
    }

    private func perfStat(_ text: String, _ color: Color) -> some View {
        Text(text).font(Typo.monoBold(11)).foregroundColor(color)
    }

    private var perfToggle: some View {
        Button {
            perfMode.toggle(); perf.reset()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speedometer").font(.system(size: 10))
                Text("perf").font(Typo.mono(9))
            }
            .foregroundColor(perfMode ? Palette.bg : .white.opacity(0.6))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(perfMode ? Palette.running : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var abToggle: some View {
        HStack(spacing: 2) {
            abSeg("A", perfFlat)  { perfFlat = true;  perf.reset() }
            abSeg("B", !perfFlat) { perfFlat = false; perf.reset() }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
    }

    private func abSeg(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(Typo.monoBold(9))
                .foregroundColor(on ? Palette.bg : .white.opacity(0.55))
                .frame(width: 20, height: 16)
                .background(Capsule().fill(on ? Palette.running : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intent band (drag targets)
    //
    // The top third: three sections you drag a window thumbnail up into. Layers and
    // Spaces are scaffolded for Phase 2/3; Lattice is live — drop a tile on a cell to
    // stage a location (nothing real moves until gather). See
    // design/hyperspace-drag-drop.md.

    /// All survey tiles on this display — drives the floating inventory roster.
    private var inventoryTiles: [Tile] {
        clusters.flatMap(\.tiles).sorted {
            $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending
        }
    }

    /// The shelf has one visible object model: actions target an explicitly selected
    /// window. The most recently aimed selected window wins; after deselection, fall
    /// back to the last window that remains in pick order.
    private var selectedActionTile: Tile? {
        if let aimed = inventoryTiles.first(where: \.isAimed), pickedWids.contains(aimed.id) {
            return aimed
        }
        for wid in pickedOrder.reversed() {
            if let tile = tileForWid(wid) { return tile }
        }
        return nil
    }

    /// Hyper+G is a transaction over the live desktop. The compact header owns
    /// session-level controls; the shelf owns actions for the aimed/selected windows.
    private var inPlaceHeader: some View {
        HStack(spacing: 10) {
            LatticesMark(size: 16, tint: Palette.running, dimOpacity: 0.28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("lattices")
                        .font(Typo.monoBold(10))
                        .foregroundColor(Palette.text)
                    Text("· arrange")
                        .font(Typo.monoBold(9))
                        .foregroundColor(Palette.running)
                }
                Text("live desktop")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
            }

            Spacer(minLength: 12)

            if let displayScope {
                Button {
                    withAnimation(HyperspaceMotion.panel) { showWindowInventory.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Palette.running)
                        Text(displayScope.label)
                            .font(Typo.monoBold(9))
                            .foregroundColor(Palette.text)
                        Text("· \(displayScope.windowCount) windows")
                            .font(Typo.mono(8))
                            .foregroundColor(Palette.running)
                        if displayScope.count > 1 {
                            Text("\(displayScope.index + 1)/\(displayScope.count)")
                                .font(Typo.mono(8))
                                .foregroundColor(Palette.textMuted)
                        }
                        Image(systemName: showWindowInventory ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Palette.textMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(showWindowInventory ? Palette.running.opacity(0.10) : Color.white.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(showWindowInventory ? Palette.running.opacity(0.30) : Palette.border, lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(showWindowInventory ? "Hide the window drawer" : "Show every window on this display")
                .accessibilityLabel(showWindowInventory ? "Hide window drawer" : "Show window drawer")
            }

            Rectangle()
                .fill(Palette.borderLit)
                .frame(width: 0.5, height: 22)

            inPlaceSnapshotButton
            inPlaceHeaderButton(inPlaceHasChanges ? "Restore" : "Cancel",
                                icon: "arrow.uturn.backward",
                                tint: Palette.textDim) {
                onCancel()
            }
            .help("Discard staged changes, restore live changes, and close (Esc)")
            inPlaceHeaderButton(inPlaceHasChanges ? "Keep changes" : "Done",
                                icon: "checkmark",
                                tint: Palette.running,
                                filled: true) {
                onKeep()
            }
            .help("Apply staged changes, keep live changes, and close (Return)")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.black.opacity(0.42))
                LatticesLatticeGrid(spacing: 20, opacity: 0.055)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Palette.borderLit, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
        .contentShape(Rectangle())
    }

    private func inPlaceHeaderButton(_ title: String,
                                     icon: String,
                                     tint: Color,
                                     filled: Bool = false,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(Typo.monoBold(9))
            }
            .foregroundColor(filled ? Palette.bg : tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(filled ? tint : Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(filled ? tint.opacity(0.95) : Palette.borderLit, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var inPlaceSnapshotButton: some View {
        Button { beginSnapshotCountdown() } label: {
            HStack(spacing: 5) {
                Image(systemName: snapshotCountdown == nil ? "camera" : "timer")
                    .font(.system(size: 9, weight: .bold))
                Text(snapshotCountdown.map(String.init) ?? "Snapshot")
                    .font(Typo.monoBold(9))
                    .monospacedDigit()
            }
            .foregroundColor(HUDChrome.cyan)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HUDChrome.cyan.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(HUDChrome.cyan.opacity(0.28), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(snapshotCountdown != nil || snapshotIsCapturing)
        .opacity(snapshotIsCapturing ? 0 : 1) // keep its slot stable but omit the shutter from the PNG
        .help("Capture this display after a 3-second countdown; copy the PNG and save it to Runs")
        .accessibilityLabel("Snapshot this display")
    }

    private func beginSnapshotCountdown() {
        guard snapshotCountdown == nil, !snapshotIsCapturing else { return }
        snapshotNotice = nil
        snapshotNoticeIsError = false
        Task { @MainActor in
            for count in stride(from: 3, through: 1, by: -1) {
                snapshotCountdown = count
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            snapshotCountdown = nil
            snapshotIsCapturing = true
            // Give SwiftUI one frame to hide the shutter without moving the header.
            try? await Task.sleep(nanoseconds: 120_000_000)
            onSnapshot { errorMessage in
                Task { @MainActor in
                    snapshotIsCapturing = false
                    if let errorMessage {
                        snapshotNotice = "Snapshot failed · \(errorMessage)"
                        snapshotNoticeIsError = true
                    } else {
                        snapshotNotice = "Snapshot copied · saved to Runs"
                        snapshotNoticeIsError = false
                    }
                }
            }
        }
    }

    private var inPlaceActionShelf: some View {
        HStack(alignment: .center, spacing: 0) {
            inPlaceShelfLead

            if let selectedActionTile {
                inPlaceShelfDivider()
                inPlaceShelfActions(for: selectedActionTile)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: inPlaceShelfWidth, height: 56, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.54))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.borderLit, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.46), radius: 24, y: 10)
    }

    private var inPlaceShelfWidth: CGFloat {
        guard selectedActionTile != nil else { return 520 }
        return pickedWids.count >= 2 ? 780 : 640
    }

    private var inPlaceShelfLeadWidth: CGFloat {
        selectedActionTile == nil ? 496 : 224
    }

    private var inPlaceShelfLead: some View {
        let state = inPlaceShelfLeadState
        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(state.tint.opacity(0.16))
                    .frame(width: 26, height: 26)
                Text("\(state.step)")
                    .font(Typo.monoBold(10))
                    .foregroundColor(state.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(Typo.monoBold(9))
                    .foregroundColor(state.tint)
                    .lineLimit(1)
                Text(state.detail)
                    .font(Typo.mono(8))
                    .foregroundColor(snapshotNoticeIsError ? Palette.kill : Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: inPlaceShelfLeadWidth, height: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var inPlaceShelfLeadState: (step: Int, title: String, detail: String, tint: Color) {
        if let snapshotNotice {
            return (inPlaceProgressStep,
                    snapshotNoticeIsError ? "SNAPSHOT FAILED" : "SNAPSHOT SAVED",
                    snapshotNotice,
                    snapshotNoticeIsError ? Palette.kill : HUDChrome.cyan)
        }
        if inPlaceHasChanges {
            let title = pickedWids.isEmpty
                ? "FINISH · CHANGES READY"
                : "FINISH · \(pickedWids.count) SELECTED"
            let tint = hasSessionChanges && inPlaceStagedCount == 0 ? HUDChrome.cyan : Palette.detach
            if let selectedActionTile {
                let slot = selectedActionTile.pickSlot.map { "#\($0) · " } ?? ""
                return (3, title,
                        "Target \(slot)\(selectedActionTile.app) · \(inPlaceChangeSummary)",
                        tint)
            }
            return (3, title, inPlaceChangeSummary, tint)
        }
        if let selectedActionTile {
            let slot = selectedActionTile.pickSlot.map { "#\($0) · " } ?? ""
            return (2,
                    "ARRANGE · \(pickedWids.count) SELECTED",
                    "Target \(slot)\(selectedActionTile.app)",
                    Palette.running)
        }
        return (1,
                "SELECT A WINDOW",
                "Hover for blue outline · click the window",
                HUDChrome.cyan)
    }

    private var inPlaceChangeSummary: String {
        let staged = inPlaceStagedCount
        if hasSessionChanges, staged > 0 { return "Live + \(staged) on Keep" }
        if hasSessionChanges { return "Live now · Restore undoes" }
        if staged > 0 { return "\(staged) on Keep · Keep applies" }
        return ""
    }

    private var inPlaceStagedCount: Int {
        stagedPlan.count + inventoryTiles.filter { !$0.layerTags.isEmpty }.count
    }

    private var inPlaceHasChanges: Bool {
        hasSessionChanges || inPlaceStagedCount > 0
    }

    private var inPlaceProgressStep: Int {
        if inPlaceHasChanges { return 3 }
        if !pickedWids.isEmpty { return 2 }
        return 1
    }

    private func inPlaceShelfDivider(horizontalPadding: CGFloat = 10) -> some View {
        Rectangle()
            .fill(Palette.borderLit)
            .frame(width: 0.5, height: 28)
            .padding(.horizontal, horizontalPadding)
    }

    private func inPlaceTimingLabel(_ title: String,
                                    width: CGFloat,
                                    tint: Color) -> some View {
        Text(title)
            .font(Typo.monoBold(8))
            .foregroundColor(tint)
            .tracking(0.6)
            .frame(width: width, alignment: .leading)
    }

    private func inPlaceShelfActions(for selectedActionTile: Tile) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                inPlaceTimingLabel("NOW", width: 32, tint: HUDChrome.cyan)
                inPlaceShelfButton("Fill", icon: "arrow.up.backward.and.arrow.down.forward", enabled: true) {
                    onFillAvailable(selectedActionTile.id)
                }
                .help("Fill open space with the target window now; Restore puts it back")
                if pickedWids.count >= 2 {
                    inPlaceShelfButton("Grid", icon: "square.grid.2x2", enabled: true) {
                        onGridSelection()
                    }
                    .help("Move the selected windows into a grid now; Restore puts them back")
                    inPlaceShelfButton("Swap", icon: "arrow.left.arrow.right", enabled: true) {
                        onSwapFirstTwo()
                    }
                    .help("Swap the first two selected windows now; Restore puts them back")
                }
            }

            Spacer(minLength: 8)

            inPlaceShelfDivider(horizontalPadding: 8)

            HStack(spacing: 4) {
                inPlaceTimingLabel("KEEP", width: 36, tint: Palette.detach)
                inPlaceShelfButton("Place", icon: "rectangle.dashed", enabled: true) {
                    showWindowInventory = false
                    drag.beginPlacing(selectedActionTile.id, on: screenID)
                }
                .help("Choose a grid position for the target window; Keep applies it")
            }

            inPlaceShelfDivider(horizontalPadding: 8)

            Menu {
                inPlaceTileMenu(selectedActionTile)
            } label: {
                inPlaceShelfControl("More", icon: "ellipsis", enabled: true, minWidth: 68)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .help("More actions for the target window")
        }
    }

    private func inPlaceShelfButton(_ title: String,
                                    icon: String,
                                    enabled: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            inPlaceShelfControl(title, icon: icon, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func inPlaceShelfControl(_ title: String,
                                     icon: String,
                                     enabled: Bool,
                                     minWidth: CGFloat = 60) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(Typo.monoBold(9))
        }
        .foregroundColor(enabled ? Palette.text : Palette.textMuted.opacity(0.55))
        .padding(.horizontal, 9)
        .frame(minWidth: minWidth, minHeight: 32, maxHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(enabled ? Color.white.opacity(0.045) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(enabled ? Palette.border : Color.clear, lineWidth: 0.5)
                )
        )
    }

    // Quiet signature wash under the live desktop — corner mark does the heavy lifting.
    private var inPlaceSignatureBackdrop: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Palette.running.opacity(0.04), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
            .frame(maxHeight: .infinity, alignment: .top)
            LatticesLatticeGrid(spacing: 28, opacity: 0.028, tint: Palette.running)
                .mask(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .allowsHitTesting(false)
    }

    // Inline monitor readout for the strip header — avoids a second top-left chip.
    private func displayScopeChip(_ scope: DisplayScope) -> some View {
        HStack(spacing: 6) {
            Image(systemName: scope.index == 0 ? "display" : "rectangle.on.rectangle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Palette.running)
            Text(scope.label)
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.text)
            if scope.count > 1 {
                Text("\(scope.index + 1)/\(scope.count)")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
            }
            Text("\(scope.windowCount)")
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.running)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Palette.running.opacity(0.12))
                        .overlay(Capsule().strokeBorder(Palette.running.opacity(0.28), lineWidth: 0.5))
                )
        }
        .lineLimit(1)
    }

    /// Header row + intent band — shared by Hyperspace survey and Hyper+G in-place.
    private var intentChromeHeight: CGFloat { bandHeight + 44 }

    private func overlayIntentChrome(mode: String, detail: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                LatticesOverlayStripHeader(mode: mode, detail: detail)
                Spacer(minLength: 0)
                if let displayScope { displayScopeChip(displayScope) }
            }
            .padding(.horizontal, LatticesOverlayMetrics.edgeInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
            intentBand
                .frame(height: bandHeight)
                .clipped()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background { LatticesOverlayStripBackground() }
    }

    // Bottom-right window inventory — compact roster linked to Current View.
    private var floatingWindowInventory: some View {
        let tiles = inventoryTiles
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.running)
                Text("Windows")
                    .font(Typo.monoBold(11))
                    .foregroundColor(.white)
                Text("\(tiles.count)")
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.running)
                Spacer(minLength: 0)
                if !pickedWids.isEmpty {
                    Text("\(pickedWids.count) selected")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.running)
                }
                Text("a–z")
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tiles) { t in
                        inventoryRow(t)
                    }
                }
            }
            .frame(maxHeight: min(380, CGFloat(tiles.count) * 58 + 8))
        }
        .frame(width: 292)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.borderLit, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
        .contentShape(Rectangle())
    }

    private func inventoryRow(_ t: Tile) -> some View {
        let linked = activeLinkWid == t.id
        let picked = t.pickSlot != nil
        let lit = surveyHighlightWids?.contains(t.id) == true
        let hasSelection = !pickedWids.isEmpty
        let dimmed = hasSelection && !picked
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let thumbW: CGFloat = 72
        let thumbH: CGFloat = 44
        return HStack(spacing: 8) {
            if picked {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.running)
                    .frame(width: 3, height: thumbH)
            }
            ZStack {
                shape.fill(t.tint.opacity(picked ? 0.32 : 0.22))
                if let img = t.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                if picked {
                    shape.fill(Palette.running.opacity(0.12))
                }
            }
            .frame(width: thumbW, height: thumbH)
            .clipShape(shape)
            .overlay(shape.strokeBorder(
                linked ? HUDChrome.cyan
                    : (picked ? Palette.running : t.tint.opacity(0.55)),
                lineWidth: linked ? 2 : (picked ? 2 : 0.75)))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.app)
                    .font(Typo.monoBold(10))
                    .foregroundColor(picked ? .white : .white.opacity(dimmed ? 0.65 : 1))
                    .lineLimit(1)
                Text(t.title)
                    .font(Typo.mono(8.5))
                    .foregroundColor(picked ? Palette.running.opacity(0.9) : Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if picked {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.running)
                    if let slot = t.pickSlot {
                        Text("\(slot)")
                            .font(Typo.monoBold(9))
                            .foregroundColor(Palette.bg)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.running))
                    }
                }
            } else if inPlace, !t.hint.isEmpty {
                Text(t.hint)
                    .font(Typo.monoBold(9))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(picked ? Palette.running.opacity(0.14)
                      : (lit ? Color.white.opacity(0.08) : Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(linked ? HUDChrome.cyan.opacity(0.7)
                                    : (picked ? Palette.running.opacity(0.75) : Palette.border),
                                  lineWidth: linked ? 1.5 : (picked ? 1.5 : 0.5)))
        )
        .opacity(dimmed ? 0.48 : 1)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded { onPick(t.id) })
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .named(ExposeView.rootSpace))
                .onChanged { handleDragChange(t, tileWidth: thumbW, $0) }
                .onEnded { handleDragEnd(t, $0) }
        )
        .onHover { over in
            guard !drag.isActive else { return }
            if over { drag.hoverSurveyWid = t.id }
            else if drag.hoverSurveyWid == t.id { drag.hoverSurveyWid = nil }
        }
        .contextMenu { windowContextMenu(t) }
    }

    private func pickSlot(for wid: UInt32) -> Int? {
        pickedOrder.firstIndex(of: wid).map { $0 + 1 }
    }

    @ViewBuilder
    private func windowContextMenu(_ t: Tile) -> some View {
        if inPlace { inPlaceTileMenu(t) } else { tileMenu(t) }
    }

    private var intentBand: some View {
        // Three slots: Layers (pick/tag) · Current View (select) · Grid (drop a cell).
        GeometryReader { geo in
            let compact = unifiedChrome && !inPlace
            let gap = compact ? 12 : (geo.size.width * (inPlace ? 0.01 : 0.018)).rounded()
            let sideW = compact ? max(0, (geo.size.width - gap * 2) / 3) : (geo.size.width * (inPlace ? 0.14 : 0.18)).rounded()
            let centerW = compact ? sideW : (geo.size.width * (inPlace ? 0.44 : 0.18)).rounded()
            HStack(alignment: .top, spacing: gap) {
                layersSection.frame(width: sideW)
                currentViewSection.frame(width: centerW)
                gridSection.frame(width: sideW)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, inPlace ? 2 : 4)
            .padding(.bottom, inPlace ? 2 : 8)
        }
    }

    // Layer piles chunked into rows of two for the 2×N band grid (＋ pile trails last).
    private var layerRows: [[LayerPile]] {
        stride(from: 0, to: layers.count, by: 2).map {
            Array(layers[$0 ..< min($0 + 2, layers.count)])
        }
    }

    // A not-yet-live section — visible so the three-axis model reads, dimmed so it's
    // clearly inert. Replaced by real piles / a Spaces strip in later phases.
    private func stubSection(_ title: String, _ icon: String, _ sub: String, _ phase: String) -> some View {
        sectionCard(title: title, icon: icon, sub: sub, live: false) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(phase)
                    .font(Typo.monoBold(10)).foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                Text("soon").font(Typo.mono(8)).foregroundColor(.white.opacity(0.25))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 220)
        .opacity(0.6)
    }

    // The Layers section (Phase 2): rule-backed layers as drop "piles" — drag a window
    // onto a pile to stage a join (multi-membership; drop again to un-stage), or onto
    // the ＋ pile to stage a brand-new layer seeded from it. Drops only *stage* (badge
    // the tile); workspace.json is written on gather. design/hyperspace-drag-drop.md
    private var layersSection: some View {
        sectionCard(title: "Layers", icon: "square.stack.3d.up", sub: "tag · piles",
                    live: true, armed: dragOnThisScreen && drag.hoverLayer != nil) {
            VStack(alignment: .leading, spacing: 8) {
                controlRow {                                   // mirrors the Lattice selector slot
                    Text("\(max(0, layers.count - 1)) \(layers.count - 1 == 1 ? "layer" : "layers")")
                        .font(unifiedChrome ? Typo.caption(10) : Typo.mono(9)).foregroundColor(chromeText.opacity(0.55))
                    Spacer(minLength: 6)
                    Button(action: onNewLayer) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(chromeOnAccent)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chromeSelection))
                    }
                    .buttonStyle(.plain)
                    .help("New layer")
                }
                // Fixed 2-wide grid: layers fill row-major and the ＋ pile trails as the
                // next free cell ([L1][＋] → [L1][L2]/[＋] → …). Eager VStack/HStack — not a
                // lazy grid — so every pile reports its LayerFrameKey for drag hit-testing.
                GeometryReader { geo in
                    let pileW = layerPileWidth(in: geo.size)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: inPlace ? 6 : 10) {
                            ForEach(layerRows.indices, id: \.self) { r in
                                HStack(alignment: .top, spacing: inPlace ? 6 : 10) {
                                    ForEach(layerRows[r]) { layerPileView($0, mapW: pileW) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .onPreferenceChange(LayerFrameKey.self) { drag.layerFrames[screenID] = $0 }
                }
            }
        }
    }

    // Shared 26pt control-row slot so Layers and Lattice line up under their headers.
    private func controlRow<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .frame(height: 26)
    }

    /// True while a drag started on (and belongs to) this screen.
    private var dragOnThisScreen: Bool { drag.isActive && drag.screenID == screenID }

    // One layer pile — a compact *screen-map* of the layer's windows on this display, so
    // you read what the layer looks like at a glance (design/hyperspace-drag-drop.md). The
    // full-size formation renders in the middle Preview on hover / drop. Lights as a drop
    // target and stays tinted while it holds a staged join. ＋ = a new-layer drop slot.
    private func layerPileView(_ pile: LayerPile, mapW: CGFloat = 104) -> some View {
        let lit = dragOnThisScreen && drag.hoverLayer == pile.id
        let on = lit || pile.staged
        let mapH = layerMapHeight(for: mapW)
        return VStack(spacing: 4) {
            Group {
                if pile.isNew {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? chromeAccent.opacity(0.9) : chromeWell)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(on ? chromeOnAccent : chromeText.opacity(0.6))
                    }
                    .frame(width: mapW, height: mapH)
                } else {
                    layerMap(pile, width: mapW)            // the screen, with its windows
                }
            }
            .overlay(                                       // the "monitor" bezel
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(on ? chromeAccent : chromeBorder, lineWidth: on ? 1.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if !pile.isNew && pile.count > 0 {
                    Text("\(pile.count)")
                        .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8)).foregroundColor(chromeText)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Capsule().fill(chromeBacking(0.6)))
                        .padding(2)
                }
            }
            .overlay(alignment: .topLeading) {       // evidence: how many windows staged to join
                if pile.stagedCount > 0 {
                    Text("＋\(pile.stagedCount)")
                        .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8)).foregroundColor(chromeOnAccent)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Capsule().fill(chromeSelection))
                        .padding(2)
                        .transition(.opacity)
                }
            }
            Text(pile.isNew ? "new" : pile.name)
                .font(unifiedChrome ? Typo.caption(10) : Typo.mono(inPlace ? 8 : 9))
                .foregroundColor(chromeText.opacity(on ? 0.9 : 0.65))
                .lineLimit(1).frame(maxWidth: mapW)
            if !inPlace {
                layerPileMeta(pile, active: on, width: mapW)
            }
        }
        .animation(HyperspaceMotion.badge, value: pile.stagedCount)
        .scaleEffect(lit ? HyperspaceMotion.pileHoverScale : 1)
        .shadow(color: lit ? chromeAccent.opacity(0.35) : .clear, radius: lit ? 4 : 0)
        .animation(HyperspaceMotion.hover, value: lit)
        .background(layerFrameReporter(pile.id))     // hit-test = the compact footprint
        .onHover { hovering in
            if hovering { drag.inspectLayer = pile.id; drag.inspectScreen = screenID }
            else if drag.inspectLayer == pile.id { drag.inspectLayer = nil; drag.inspectScreen = nil }
        }
        .onTapGesture {                                    // ＋ → author a new layer; else open the inspector
            if pile.isNew { onNewLayer() } else { drag.selectedLayer = pile.id }
        }
        .contextMenu { layerPileMenu(pile) }               // right-click → inspect / remove rules, delete layer
    }

    // Right-click menu for a layer pile: see each rule, what it currently matches, and
    // remove it — plus delete the whole layer. The rules are the committed ⌘⌥ layer
    // entries, as rules. Empty for the
    // ＋ pile (it has no layer yet).
    @ViewBuilder
    private func layerPileMenu(_ pile: LayerPile) -> some View {
        if !pile.isNew {
            Text(pile.name)
            Divider()
            Button("Select matching windows") {
                onRecallLayer(pile.id)
            }
            Divider()
            if pile.clauses.isEmpty {
                Text("No rules")
            } else {
                ForEach(Array(pile.clauses.enumerated()), id: \.offset) { idx, clause in
                    let matches = pile.ruleWindows.indices.contains(idx) ? pile.ruleWindows[idx] : []
                    Menu("\(clauseTitle(clause))  ·  \(matches.count)") {
                        if matches.isEmpty {
                            Text("No live windows match")
                        } else {
                            ForEach(matches.prefix(12), id: \.wid) { w in
                                Text(w.title.isEmpty ? w.app : "\(w.app) — \(w.title)")
                            }
                            if matches.count > 12 { Text("+\(matches.count - 12) more") }
                        }
                        Divider()
                        Button("Remove this rule", role: .destructive) { onRemoveClause(pile.id, idx) }
                    }
                }
            }
            Divider()
            Button("Delete layer “\(pile.name)”", role: .destructive) { onDeleteLayer(pile.id) }
        }
    }

    // A rule clause as a readable menu label.
    private func clauseTitle(_ clause: StudioLayerClause) -> String {
        clause.summary
    }

    private func layerPileMeta(_ pile: LayerPile, active: Bool, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: pile.isNew ? "plus.square" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 7.5, weight: .semibold))
            if pile.isNew {
                Text("create")
            } else {
                Text("\(pile.clauses.count) rule\(pile.clauses.count == 1 ? "" : "s")")
                if pile.count == 0 {
                    Text("empty")
                        .foregroundColor(Palette.detach.opacity(active ? 0.9 : 0.65))
                }
            }
        }
        .font(unifiedChrome ? Typo.caption(10) : Typo.mono(7.5))
        .foregroundColor(active ? chromeSelection : chromeText.opacity(0.38))
        .lineLimit(1)
        .frame(maxWidth: width)
    }

    // MARK: - Layer inspector (click a pile to open)
    //
    // A top-area modal: the layer's match rules on the left, the windows they currently
    // resolve to on the right (a table). Backdrop tap / ✕ / esc closes it. Rules are the
    // committed ⌘⌥ layer rules — editable in place (remove), the live source of truth.
    @ViewBuilder
    private func layerInspector(_ pile: LayerPile) -> some View {
        let windows = pile.held
        GeometryReader { geo in
            let panelW = min(760, max(440, geo.size.width * 0.55))
            let panelH = min(440, max(260, geo.size.height * 0.52))
            ZStack(alignment: .top) {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { drag.selectedLayer = nil }
                inspectorPanel(pile, windows: windows)
                    .frame(width: panelW, height: panelH)
                    .padding(.top, max(24, geo.size.height * 0.12))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func inspectorPanel(_ pile: LayerPile, windows: [WindowEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(HUDChrome.cyan)
                Text(pile.name).font(Typo.monoBold(14)).foregroundColor(.white)
                Text("\(windows.count) window\(windows.count == 1 ? "" : "s")")
                    .font(Typo.mono(10)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Button {
                    onRecallLayer(pile.id)
                    drag.selectedLayer = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Select")
                            .font(Typo.monoBold(10))
                    }
                    .foregroundColor(Palette.bg)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Palette.running))
                }
                .buttonStyle(.plain)
                .disabled(windows.isEmpty)
                .opacity(windows.isEmpty ? 0.4 : 1)
                .help("Select matching windows")
                Button { drag.selectedLayer = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Palette.border).frame(height: 0.5)
            inspectorSummary(pile, windows: windows)
            Rectangle().fill(Palette.border).frame(height: 0.5)
            HStack(alignment: .top, spacing: 0) {
                inspectorRules(pile).frame(width: 240)
                Rectangle().fill(Palette.border).frame(width: 0.5)
                inspectorWindows(windows).frame(maxWidth: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.35)))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.borderLit, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private func inspectorSummary(_ pile: LayerPile, windows: [WindowEntry]) -> some View {
        HStack(spacing: 8) {
            inspectorMetric("rules", "\(pile.clauses.count)")
            inspectorMetric("live", "\(windows.count)")
            inspectorMetric("screen", "\(pile.count)")
            Text(pile.rule.isEmpty ? "no rule" : pile.rule)
                .font(Typo.mono(9))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.14))
    }

    private func inspectorMetric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(.white.opacity(0.38))
            Text(value).foregroundColor(.white.opacity(0.82))
        }
        .font(Typo.monoBold(9))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        )
    }

    // Left column: the layer's match rules, each removable.
    private func inspectorRules(_ pile: LayerPile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("RULES").font(Typo.monoBold(9)).foregroundColor(.white.opacity(0.4)).tracking(0.5)
                Spacer()
                Button {
                    onEditClause(pile.id, nil, StudioLayerClause())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Palette.bg)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.running))
                }
                .buttonStyle(.plain)
                .help("Add rule")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(Palette.border).frame(height: 0.5)
            if pile.clauses.isEmpty {
                Text("No rules — matches nothing")
                    .font(Typo.mono(11)).foregroundColor(.white.opacity(0.4)).padding(14)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(pile.clauses.enumerated()), id: \.offset) { idx, clause in
                        inspectorRuleRow(clause, count: pile.ruleWindows.indices.contains(idx) ? pile.ruleWindows[idx].count : 0) {
                            onEditClause(pile.id, idx, clause)
                        } remove: {
                            onRemoveClause(pile.id, idx)
                        }
                    }
                }
                .padding(12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func inspectorRuleRow(
        _ clause: StudioLayerClause,
        count: Int,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(clause.summary)
                    .font(Typo.mono(10))
                    .foregroundColor(clause.not?.isEmpty == false ? Palette.detach : .white.opacity(0.85))
                    .lineLimit(2)
                Text("\(count) live match\(count == 1 ? "" : "es")")
                    .font(Typo.mono(8))
                    .foregroundColor(count == 0 ? Palette.detach.opacity(0.72) : .white.opacity(0.38))
            }
            Spacer(minLength: 4)
            Button(action: edit) {
                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45)).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Edit rule")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35)).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Remove this rule")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 0.5))
        )
    }

    // Right column: the windows the rules currently resolve to — a simple app/title table.
    private func inspectorWindows(_ windows: [WindowEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("APP").frame(width: 84, alignment: .leading)
                Text("WINDOW").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Typo.monoBold(9)).foregroundColor(.white.opacity(0.4)).tracking(0.5)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(Palette.border).frame(height: 0.5)
            if windows.isEmpty {
                Text("No live windows match")
                    .font(Typo.mono(11)).foregroundColor(.white.opacity(0.4)).padding(14)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(windows, id: \.wid) { w in
                            HStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(nsColor: MotionPanel.tint(for: w.app)))
                                        .frame(width: 6, height: 6)
                                    Text(w.app).font(Typo.mono(10)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                                }
                                .frame(width: 84, alignment: .leading)
                                Text(w.title.isEmpty ? "—" : w.title)
                                    .font(Typo.mono(10)).foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            Rectangle().fill(Palette.border.opacity(0.5)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Map height for a given width — the active screen's aspect, clamped so a very wide
    // or very tall display still reads as a tidy tile.
    private func layerMapHeight(for width: CGFloat) -> CGFloat {
        (width / min(max(screenAspect, 1.2), 2.6)).rounded()
    }

    /// Pile thumbnail width for the Layers grid. In-place mode gives the side column a
    /// lot of horizontal space but a short band — size from the vertical budget so piles
    /// don't spill below the reserved intent zone.
    private func layerPileWidth(in size: CGSize) -> CGFloat {
        let colW = max(52, ((size.width - 10) / 2).rounded())
        guard inPlace || unifiedChrome else {
            return max(104, min(220, colW))
        }
        // The overview scrolls additional rows. Fit the first complete row,
        // including its name and rule summary, into the existing card height.
        let rowCount = inPlace ? CGFloat(max(1, layerRows.count)) : 1
        let rowGap: CGFloat = inPlace ? 6 : 10
        let labelStack: CGFloat = inPlace ? 22 : 36
        let hoverPad: CGFloat = 1.08   // pile scaleEffect headroom
        let availH = max(40, size.height)
        let perRowH = (availH - rowGap * (rowCount - 1)) / rowCount
        let mapH = max(22, (perRowH - labelStack) / hoverPad)
        let wFromH = mapH * min(max(screenAspect, 1.2), 2.6)
        return min(colW, wFromH, inPlace ? 132 : 220).rounded()
    }

    // A layer's screen-map: its member windows drawn as app-tinted rects at their real
    // (screen-relative) positions — the "what does this layer look like" preview. `big`
    // (the expanded map) fills rects with the live thumbnail.
    private func layerMap(_ pile: LayerPile, width: CGFloat) -> some View {
        let h = layerMapHeight(for: width)
        let big = unifiedChrome || width > 160
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: big ? 8 : 7, style: .continuous)
                .fill(chromeBacking(0.38))
            if pile.members.isEmpty {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: width * 0.14))
                    .foregroundColor(chromeText.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(pile.members) { m in
                    let r = CGRect(x: m.frac.minX * width, y: m.frac.minY * h,
                                   width: max(big ? 6 : 3, m.frac.width * width),
                                   height: max(big ? 5 : 3, m.frac.height * h))
                    layerMemberRect(m, big: big)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: big ? 8 : 7, style: .continuous))
    }

    private func layerMemberRect(_ m: LayerMember, big: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: big ? 3 : 1.5, style: .continuous)
        return shape
            .fill(m.tint.opacity(0.5))
            .overlay {
                if big, let img = m.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(shape).opacity(0.6)
                }
            }
            .overlay(shape.strokeBorder(m.tint, lineWidth: big ? 1 : 0.5))
    }

    // One window on the Current View map — true fractional size (no 8px floor), with a
    // thumbnail when we have one so the mini-map reads like the desktop, not an abstract grid.
    private func currentViewWindow(_ frac: CGRect, _ tint: Color, _ image: NSImage?,
                                   _ box: CGSize, staged: Bool) -> some View {
        let w = max(2, frac.width * box.width)
        let h = max(2, frac.height * box.height)
        let radius = unifiedChrome ? min(12, min(w, h) * 0.035) : 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let r = CGRect(x: frac.minX * box.width, y: frac.minY * box.height, width: w, height: h)
        return ZStack {
            if unifiedChrome {
                HyperspaceGlassBackground(cornerRadius: radius)
            } else {
                shape.fill(tint.opacity(staged ? 0.42 : 0.22))
            }
            if let image {
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: unifiedChrome ? .fit : .fill)
                    .opacity(unifiedChrome ? 0.92 : staged ? 0.65 : 0.45)
            }
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(unifiedChrome ? (staged ? chromeText.opacity(0.22) : chromeBorder) : staged ? tint : tint.opacity(0.7),
                                    lineWidth: staged ? 1.25 : 0.75))
        .position(x: r.midX, y: r.midY)
    }

    // Visual + hit rects for a layout outline in canvas-local coords. Behind windows peek
    // out from under a front neighbor and get a larger hit pad so stacks stay grabbable.
    private struct LayoutMetrics {
        let visual: CGRect
        let hit: CGRect
    }

    private func layoutMetrics(frac: CGRect, box: CGSize, behind: Bool) -> LayoutMetrics {
        let peek: CGFloat = behind ? 7 : 0
        let minHit: CGFloat = behind ? 28 : 22
        let vw = max(2, frac.width * box.width)
        let vh = max(2, frac.height * box.height)
        let visual = CGRect(x: frac.minX * box.width + peek, y: frac.minY * box.height + peek,
                            width: vw, height: vh)
        let hw = max(minHit, vw)
        let hh = max(minHit, vh)
        let hit = CGRect(x: visual.midX - hw / 2, y: visual.midY - hh / 2, width: hw, height: hh)
        return LayoutMetrics(visual: visual, hit: hit)
    }

    // Cross-link: hover from Current View or the survey lattice.
    private var activeLinkWid: UInt32? {
        drag.hoverLayoutWid ?? drag.hoverSurveyWid
    }

    /// Windows that render a screenshot peek in Current View. In-place mode keeps picks
    /// as lightweight outlines (slot badge + stroke) and only lifts a thumb on hover.
    private var peekWids: Set<UInt32> {
        if inPlace {
            if let w = activeLinkWid { return [w] }
            return []
        }
        var s = pickedWids
        if let w = activeLinkWid { s.insert(w) }
        return s
    }

    /// Survey dim/highlight — layer-roster preview takes priority, then cross-link peeks.
    private var surveyHighlightWids: Set<UInt32>? {
        if let layer = highlightWids { return layer }
        if !peekWids.isEmpty { return peekWids }
        return nil
    }

    // Screenshot peek inside a layout footprint — shown when linked from either direction.
    private func layoutPeekCard(_ rect: CGRect, _ tint: Color, _ image: NSImage?,
                                picked: Bool, hovered: Bool, behind: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let stroke: Color = picked ? chromeSelection : (hovered ? chromeText : chromeAccent)
        let lineW: CGFloat = picked || hovered ? 2 : 1.5
        return ZStack {
            shape.fill(chromeBacking(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.94)
            } else {
                shape.fill(tint.opacity(0.35))
            }
            shape.strokeBorder(stroke, lineWidth: lineW)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .shadow(color: unifiedChrome ? .black.opacity(0.1) : tint.opacity(0.55), radius: hovered ? 8 : 5)
        .scaleEffect(hovered ? 1.07 : 1.03, anchor: .center)
        .position(x: rect.midX, y: rect.midY)
    }

    // Hollow footprint drawn at a canvas-local rect.
    private func currentViewOutlineAt(_ rect: CGRect, _ tint: Color,
                                      picked: Bool, hovered: Bool, dragged: Bool, behind: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let stroke: Color = dragged ? chromeAccent
            : (picked ? chromeSelection : (hovered ? chromeText : tint))
        let lineW: CGFloat = dragged ? 1.5
            : (picked ? 1.5 : (hovered ? 1.25 : (behind ? 0.75 : 1)))
        let fillOpacity = dragged ? 0.1
            : (picked ? 0.08 : (hovered ? 0.05 : (behind ? 0.02 : 0.04)))
        let strokeOpacity = dragged ? 1.0
            : (picked ? 1.0 : (behind ? 0.5 : (hovered ? 1.0 : 0.82)))
        let dash: [CGFloat] = behind && !picked ? [4, 3] : []
        return ZStack {
            shape
                .fill(tint.opacity(picked && inPlace ? 0.08 : fillOpacity))
                .overlay(
                    shape.stroke(
                        stroke.opacity(strokeOpacity),
                        style: StrokeStyle(lineWidth: lineW, dash: dash)
                    )
                )
                .overlay {
                    if picked && inPlace {
                        shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75)
                    }
                }
        }
        .shadow(color: dragged ? chromeAccent.opacity(0.28)
                : (picked && inPlace ? chromeSelection.opacity(0.22)
                   : .clear),
                radius: dragged ? 4 : (picked && inPlace ? 3 : 0))
        .opacity(!picked && !hovered && !dragged && !pickedWids.isEmpty ? 0.38 : 1)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    // Expanded invisible pad + visual outline + grab affordance. The pad is what you
    // actually hit — tiny quarter-tiles on the mini-map would otherwise be un-grabbable.
    private func layoutOutlineInteractive(_ m: LayerMember, box: CGSize) -> some View {
        let metrics = layoutMetrics(frac: m.frac, box: box, behind: m.behind)
        let hovered = drag.hoverLayoutWid == m.id
        let linked = activeLinkWid == m.id
        let picked = pickedWids.contains(m.id)
        let peeking = peekWids.contains(m.id)
        let lifted = drag.wid == m.id && drag.screenID == screenID
        return ZStack {
            Color.white.opacity(0.001)
                .frame(width: metrics.hit.width, height: metrics.hit.height)
                .contentShape(Rectangle())
                .position(x: metrics.hit.midX, y: metrics.hit.midY)
                .highPriorityGesture(TapGesture().onEnded { onPick(m.id) })
                .gesture(layoutDragGesture(m))
            Group {
                if peeking && !lifted {
                    layoutPeekCard(metrics.visual, m.tint, m.image,
                                   picked: picked, hovered: hovered || linked, behind: m.behind)
                } else {
                    currentViewOutlineAt(metrics.visual, m.tint,
                                         picked: picked, hovered: hovered, dragged: lifted, behind: m.behind)
                        .scaleEffect(hovered && !lifted && !picked ? 1.06 : 1, anchor: .center)
                }
            }
            if picked && !lifted && !peeking {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: max(8, min(12, metrics.visual.width * 0.22)), weight: .bold))
                    .foregroundColor(chromeSelection)
                    .shadow(color: .black.opacity(unifiedChrome ? 0.1 : 0.5), radius: 2)
                    .position(x: metrics.visual.maxX - 8, y: metrics.visual.minY + 8)
                    .allowsHitTesting(false)
            }
            if hovered && !lifted && !drag.isActive && !peeking {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(chromeText.opacity(0.92))
                    .shadow(color: .black.opacity(unifiedChrome ? 0.1 : 0.45), radius: 2)
                    .position(x: metrics.visual.midX, y: metrics.visual.midY)
                    .allowsHitTesting(false)
            }
        }
        .opacity(lifted ? 0.3 : (m.behind && !peeking && !picked ? 0.72 : 1))
        .overlay {
            if lifted {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                    .foregroundColor(chromeAccent.opacity(0.85))
                    .frame(width: metrics.visual.width, height: metrics.visual.height)
                    .position(x: metrics.visual.midX, y: metrics.visual.midY)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if picked, let slot = pickSlot(for: m.id), !lifted {
                Text("\(slot)")
                    .font(Typo.monoBold(8))
                    .foregroundColor(chromeOnAccent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(chromeSelection))
                    .position(x: metrics.visual.minX + 10, y: metrics.visual.minY + 8)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(peeking ? 100 : (hovered || picked ? 10 : (m.behind ? 0 : 1)))
        .onHover { over in
            if over {
                drag.hoverLayoutWid = m.id
                if !drag.isActive { NSCursor.openHand.push() }
            } else {
                if drag.hoverLayoutWid == m.id { drag.hoverLayoutWid = nil }
                if !drag.isActive { NSCursor.pop() }
            }
        }
        .contextMenu {
            if inPlace, let t = tileForWid(m.id) { inPlaceTileMenu(t) }
        }
    }

    // Reports a pile's frame (root space) keyed by its id so a drop can hit-test it.
    private func layerFrameReporter(_ key: String) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: LayerFrameKey.self,
                                   value: [key: g.frame(in: .named(ExposeView.rootSpace))])
        }
    }

    // Which pile's roster to reveal on this screen: the drop target while dragging,
    // else a plain mouse-hovered pile. The ＋ pile has no roster.
    private var rosterPileID: String? {
        // Settle, don't chase the cursor: no live layer/placement preview while a drag is in
        // flight — the preview only updates once something *lands* (a drop stages the plan).
        if drag.isActive { return nil }
        guard drag.inspectScreen == screenID, let i = drag.inspectLayer, i != HyperspaceDrag.newLayerKey else { return nil }
        return i
    }

    // The window IDs of the layer being previewed (idle hover of a pile). Drives the
    // bottom survey's dim/highlight: everything fades except this layer's windows.
    private var highlightWids: Set<UInt32>? {
        guard let id = rosterPileID, let p = layers.first(where: { $0.id == id }) else { return nil }
        return Set(p.members.map(\.id))
    }

    /// Current View highlights while hovering an outline or a linked survey tile.
    private var currentViewFocused: Bool {
        drag.inspectCurrentView && drag.inspectScreen == screenID
            || drag.hoverLayoutWid != nil
            || drag.hoverSurveyWid != nil
    }

    /// In-place shortcut rails: on hover, or pinned while windows are selected.
    private var inPlaceCommandsVisible: Bool {
        showInPlaceCommands || !pickedOrder.isEmpty
    }

    private var currentViewSub: String {
        if drag.isActive, drag.screenID == screenID {
            let n = drag.dragWids.count
            if drag.hoverGrid || drag.hoverCell != nil {
                return n > 1 ? "release \(n) on cell" : "release on cell"
            }
            return n > 1 ? "drag \(n) to grid →" : "drag to grid →"
        }
        if !pickedOrder.isEmpty { return "\(pickedOrder.count) selected" }
        if inPlace { return inPlaceCommandsVisible ? "shortcuts" : "hover for shortcuts" }
        return "click or a–z to select"
    }

    // The Current View section (middle): a screen-map of this display's windows at their
    // real positions. Tap two to swap; drag an outline into Grid to stage a cell.
    private var currentViewSection: some View {
        sectionCard(title: "Current View", icon: "rectangle.on.rectangle",
                    sub: currentViewSub,
                    live: true, armed: currentViewFocused || (drag.isActive && drag.dragSource == .currentView)) {
            if inPlace {
                HStack(alignment: .center, spacing: inPlaceCommandsVisible ? 4 : 0) {
                    if inPlaceCommandsVisible {
                        inPlaceCommandRail(.leading)
                            .transition(.opacity)
                    }
                    currentLayoutCanvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inPlaceCommandsVisible {
                        inPlaceCommandRail(.trailing)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.16), value: inPlaceCommandsVisible)
                .onHover { hovering in
                    showInPlaceCommands = hovering
                }
            } else {
                currentLayoutCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Screen-map canvas: always hollow outlines at each window's live fractional rect —
    // a wireframe of the desktop (including stacked-behind windows as dashed footprints).
    private var currentLayoutCanvas: some View {
        let focused = currentViewFocused
        let showHint = !inPlace && focused && activeLinkWid == nil && pickedWids.isEmpty && !drag.isActive
        let showHoverCue = inPlace && !inPlaceCommandsVisible && !drag.isActive
        return GeometryReader { geo in
            let box = aspectFit(in: geo.size, aspect: screenAspect)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chromeBacking(0.38))
                ForEach(currentLayout) { m in
                    layoutOutlineInteractive(m, box: box)
                }
                if showHoverCue {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 8, weight: .semibold))
                        Text("hover for shortcuts")
                            .font(unifiedChrome ? Typo.caption(10) : Typo.mono(9))
                    }
                    .foregroundColor(chromeText.opacity(0.38))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Capsule().fill(chromeBacking(0.32)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if showHint {
                    Text("click windows to select")
                        .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8))
                        .foregroundColor(chromeText.opacity(0.45))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(chromeBacking(0.35)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: box.width, height: box.height)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? chromeAccent : chromeBorder, lineWidth: focused ? 1.5 : 0.5)
            )
            .scaleEffect(focused ? HyperspaceMotion.canvasFocusScale : 1)
            .shadow(color: focused ? chromeAccent.opacity(0.3) : .clear, radius: focused ? 4 : 0)
            .animation(HyperspaceMotion.focus, value: focused)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: CurrentViewFrameKey.self,
                                           value: g.frame(in: .named(ExposeView.rootSpace)))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onHover { hovering in
                if hovering {
                    drag.inspectCurrentView = true
                    drag.inspectScreen = screenID
                } else if drag.inspectScreen == screenID {
                    drag.inspectCurrentView = false
                    drag.inspectScreen = nil
                    drag.hoverLayoutWid = nil
                }
            }
        }
        .onPreferenceChange(CurrentViewFrameKey.self) { drag.currentViewFrames[screenID] = $0 }
    }

    // The HUD carries the layouts. This tray appears only while a window is
    // dragged in overview, as the place to drop it; the Grid and Layers tools
    // still win when the pointer is on them.
    private var showsLayoutStage: Bool {
        unifiedChrome && !inPlace && !drag.isPlacing && drag.isActive && drag.screenID == screenID
    }

    private var layoutStageBottomInset: CGFloat {
        usableInset.bottom + Self.hudLane
    }

    @ViewBuilder
    private var layoutStageOverlay: some View {
        if showsLayoutStage {
            layoutStage
                .frame(width: layoutStageWidth)
                .frame(height: Self.layoutStageHeight)
                .padding(.bottom, layoutStageBottomInset)
                .onPreferenceChange(LayoutCardFramesKey.self) { drag.layoutCardFrames[screenID] = $0 }
        }
    }

    /// The HUD's own width, so the tray and the instrument share both edges.
    private var layoutStageWidth: CGFloat {
        let screen = NSScreen.screens.first { MotionPanel.screenID($0) == screenID } ?? NSScreen.main
        return screen.map { HyperspaceDesktopHUD.instrumentWidth(on: $0) } ?? 820
    }

    private var layoutStage: some View {
        let ids = layoutSubjectIDs
        let plans = layoutPlans(for: ids)
        let draggingHere = drag.isActive && drag.screenID == screenID
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(layoutStageCaption(ids: ids, dragging: draggingHere))
                    .font(Typo.caption(11))
                    .foregroundColor(draggingHere ? chromeAccent : chromeSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 96, alignment: .leading)
            if plans.isEmpty {
                layoutStageEmpty(ids: ids)
            } else {
                HStack(spacing: 8) {
                    ForEach(plans, id: \.title) { plan in
                        layoutCard(plan, ids: ids, dragging: draggingHere)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { HyperspaceGlassBackground(cornerRadius: 14) }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(draggingHere ? chromeAccent.opacity(0.45) : chromeBorder, lineWidth: draggingHere ? 1.5 : 0.75)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.16), value: draggingHere)
    }

    private func layoutStageCaption(ids: [UInt32], dragging: Bool) -> String {
        if dragging { return ids.count > 1 ? "Release \(ids.count) to preview" : "Release to preview" }
        if ids.isEmpty { return "Drag windows here" }
        if !pickedOrder.isEmpty { return "\(ids.count) selected" }
        return "All \(ids.count)"
    }

    private func layoutStageEmpty(ids: [UInt32]) -> some View {
        let message = ids.isEmpty ? "Drag windows here" : "Choose fewer windows"
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(chromeText.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .overlay(
                Text(message)
                    .font(Typo.caption(12))
                    .foregroundColor(chromeSecondary)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(message)
    }

    private func layoutCard(_ plan: HyperspaceLayoutPlan, ids: [UInt32], dragging: Bool) -> some View {
        let title = layoutCardTitle(plan)
        let lit = dragging && drag.hoverLayoutTitle == plan.title
        let chosen = layoutPreview?.frames == plan.frames
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            onChooseLayout(ids, plan)
        } label: {
            VStack(spacing: 6) {
                layoutDiagram(plan, ids: ids, lit: lit || chosen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(title)
                    .font(Typo.caption(11))
                    .fontWeight(lit || chosen ? .semibold : .medium)
                    .foregroundColor(lit ? chromeAccent : chromeText)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(lit ? chromeAccent.opacity(0.1) : Color.white.opacity(chosen ? 0.96 : 0.55)))
            .overlay(shape.strokeBorder(lit ? chromeAccent : chromeText.opacity(chosen ? 0.22 : 0.12), lineWidth: lit ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Preview \(plan.title.lowercased())")
        .accessibilityLabel("\(plan.title), \(ids.count) windows")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: LayoutCardFramesKey.self,
                                       value: [plan.title: proxy.frame(in: .named(ExposeView.rootSpace))])
            }
        }
    }

    private func layoutDiagram(_ plan: HyperspaceLayoutPlan, ids: [UInt32], lit: Bool) -> some View {
        let images = layoutTileImages
        return GeometryReader { geo in
            let box = aspectFit(in: geo.size, aspect: max(0.4, screenAspect))
            let scale = box.width / max(layoutArea.width, 1)
            let origin = CGPoint(x: (geo.size.width - box.width) / 2, y: (geo.size.height - box.height) / 2)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(HyperspaceChrome.ink.opacity(0.05))
                    .frame(width: box.width, height: box.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                ForEach(ids, id: \.self) { id in
                    if let target = plan.frames[id] {
                        let rect = CGRect(
                            x: origin.x + (target.minX - layoutArea.minX) * scale,
                            y: origin.y + (target.minY - layoutArea.minY) * scale,
                            width: max(3, target.width * scale - 1.5),
                            height: max(3, target.height * scale - 1.5))
                        layoutFootprint(rect, image: images[id], lit: lit)
                    }
                }
            }
        }
    }

    private func layoutFootprint(_ rect: CGRect, image: NSImage?, lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return ZStack {
            shape.fill(lit ? chromeAccent.opacity(0.16) : HyperspaceChrome.ink.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.72)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(lit ? chromeAccent : chromeText.opacity(0.45), lineWidth: lit ? 1 : 0.6))
        .position(x: rect.midX, y: rect.midY)
    }

    private var layoutTileImages: [UInt32: NSImage] {
        var images: [UInt32: NSImage] = [:]
        for cluster in clusters {
            for tile in cluster.tiles {
                if let image = tile.image { images[tile.id] = image }
            }
        }
        return images
    }

    private var screenWindowIDs: [UInt32] {
        var seen = Set<UInt32>()
        var ids: [UInt32] = []
        for cluster in clusters {
            for tile in cluster.tiles where seen.insert(tile.id).inserted {
                ids.append(tile.id)
            }
        }
        return ids
    }

    /// Selection while idle. A drag keeps that selection when every held window
    /// is already in it, and retargets the cards when it is holding something else.
    private var layoutSubjectIDs: [UInt32] {
        if drag.isActive, drag.screenID == screenID, !drag.dragWids.isEmpty {
            let dragging = drag.dragWids
            if !pickedOrder.isEmpty, dragging.allSatisfy({ pickedWids.contains($0) }) {
                return pickedOrder
            }
            return dragging
        }
        if !pickedOrder.isEmpty { return pickedOrder }
        return screenWindowIDs
    }

    private func layoutPlans(for ids: [UInt32]) -> [HyperspaceLayoutPlan] {
        guard ids.count == Set(ids).count,
              layoutArea.width >= HyperspaceLayoutPlanner.minimumSize.width,
              layoutArea.height >= HyperspaceLayoutPlanner.minimumSize.height else { return [] }
        return HyperspaceLayoutPlanner.options(ids, in: layoutArea)
    }

    private func layoutCardTitle(_ plan: HyperspaceLayoutPlan) -> String {
        if plan.title == "Fill display" { return "Fill" }
        if plan.title.contains("columns") { return "Columns" }
        if plan.title == "Balanced grid" { return "Grid" }
        return plan.title
    }

    // The Grid section (right): a resolution selector above a grid of drop positions.
    // Dropping a window on a cell stages that position.
    private var gridSection: some View {
        let draggingHere = dragOnThisScreen && drag.isActive
        let dragN = drag.dragWids.count
        let sub: String = {
            guard draggingHere else {
                if pickedWids.isEmpty { return "select windows, then click" }
                return pickedWids.count > 1 ? "click a side" : "click a cell"
            }
            if drag.hoverCell != nil {
                return dragN > 1 ? "release \(dragN) here" : "release here"
            }
            if drag.hoverGrid { return dragN > 1 ? "pick anchor cell" : "pick a cell" }
            return dragN > 1 ? "drop \(dragN) here" : "drop here"
        }()
        let armed = dragOnThisScreen && drag.isActive && (drag.hoverCell != nil || drag.hoverGrid)
        return sectionCard(title: "Grid", icon: "rectangle.split.2x2", sub: sub,
                    live: true, armed: armed) {
            VStack(spacing: 8) {
                controlRow { resSelector }
                latticeGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // The placement-resolution picker. Each option is a *real mini-grid* of its own
    // dims (2×1, 3×1, 2×2, 4×4) — far clearer than the old ½⅓¼▦ glyphs, where ▦ read as
    // "fullscreen". Modifiers override it live mid-drag (⇧ halves · ⌥ thirds · ⌘ fine ·
    // ⌃ dense); releasing returns to the selection. A name readout sits at the trailing edge.
    @ViewBuilder
    private var resSelector: some View {
        ForEach(LatticeRes.allCases, id: \.rawValue) { r in
            let active = drag.res == r
            Button {
                drag.baseRes = r
                if !drag.isActive || Self.modifierRes() == nil { drag.res = r }
            } label: {
                resIcon(r, active: active)
                    .padding(.horizontal, 7).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? chromeSelection : chromeWell))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(active ? chromeSelection : chromeBorder, lineWidth: active ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help(r.name)
        }
        Spacer(minLength: 6)
        // Mode readout: the active resolution by name, with the held-modifier glyph when
        // one is overriding the selector — so "⌘ fine" reads at a glance.
        if let g = resOverrideGlyph {
            Text(g).font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(9)).foregroundColor(chromeSelection)
        }
        Text(drag.res.name)
            .font(unifiedChrome ? Typo.caption(10) : Typo.mono(9))
            .foregroundColor(resOverrideGlyph != nil ? chromeSelection : chromeText.opacity(0.5))
            .animation(.easeOut(duration: 0.12), value: drag.res)
    }

    // A tiny true-to-life grid icon for a resolution: cols×rows cells in a screen-ish box.
    private func resIcon(_ r: LatticeRes, active: Bool) -> some View {
        let (cols, rows) = r.dims
        let bw: CGFloat = 22, bh: CGFloat = 15, gap: CGFloat = 1.5
        let cw = (bw - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (bh - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let color = active ? chromeOnAccent : chromeSecondary
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color).frame(width: cw, height: ch)
                    }
                }
            }
        }
        .frame(width: bw, height: bh)
    }

    /// The glyph of the modifier currently overriding the resolution (mid-drag), or nil.
    private var resOverrideGlyph: String? {
        guard drag.isActive else { return nil }
        switch Self.modifierRes() {
        case .dense:   return "⌃"
        case .fine:    return "⌘"
        case .thirds:  return "⌥"
        case .halves:  return "⇧"
        default:       return nil
        }
    }

    // The drop grid: cols×rows cells laid out at the screen's aspect ratio, centered
    // in the available space. Reports its frame (root space) for hit-testing; the cell
    // under the cursor lights while dragging.
    private var latticeGrid: some View {
        let (cols, rows) = drag.res.dims
        return GeometryReader { geo in
            let box = aspectFit(in: geo.size, aspect: screenAspect)
            let cw = box.width / CGFloat(cols)
            let ch = box.height / CGFloat(rows)
            let active = drag.isActive && drag.screenID == screenID
            let warm = active && drag.hoverGrid && drag.hoverCell == nil
            let aim = drag.hoverCell
            let span = aim.map {
                gridClickSpan(col: $0.col, row: $0.row, cols: cols, rows: rows,
                              count: max(1, active ? drag.dragWids.count : pickedOrder.count))
            }
            VStack(spacing: 3) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0..<cols, id: \.self) { c in
                            let cell = HoverCell(col: c, row: r)
                            let lit = active ? drag.hoverCell == cell : (span?.contains(col: c, row: r) == true)
                            gridCell(lit: lit, warm: warm,
                                     w: max(8, cw - 3), h: max(8, ch - 3))
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    guard !drag.isActive else { return }
                                    if inside {
                                        drag.hoverCell = cell
                                        drag.hoverGrid = true
                                    }
                                }
                                .onTapGesture { onPlaceOnGrid(c, r, drag.res) }
                        }
                    }
                }
            }
            .onHover { inside in
                guard !drag.isActive, !inside else { return }
                drag.hoverCell = nil
                drag.hoverGrid = false
            }
            // Glide the highlight between cells instead of snapping.
            .animation(HyperspaceMotion.drag, value: drag.hoverCell)
            .frame(width: box.width, height: box.height)
            .clipped()
            .background(                                          // measure the fixed grid box…
                GeometryReader { g in
                    Color.clear.preference(key: LatticeFrameKey.self,
                                           value: g.frame(in: .named(ExposeView.rootSpace)))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // …then center it in the section
            .clipped()
        }
        .onPreferenceChange(LatticeFrameKey.self) { drag.latticeFrames[screenID] = $0 }
    }

    // One drop-grid cell — a plain target that lights under the cursor. The actual
    // placement preview now renders in the middle Preview canvas, not in the cell.
    private func gridCell(lit: Bool, warm: Bool, w: CGFloat, h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let fill = lit ? chromeSelection.opacity(0.32)
            : (warm ? chromeSelection.opacity(0.12) : chromeWell)
        let stroke = lit ? chromeSelection : (warm ? chromeSelection.opacity(0.45)
            : (unifiedChrome ? HyperspaceChrome.ink.opacity(0.3) : chromeBorder))
        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(stroke, lineWidth: lit ? 1.5 : (warm || unifiedChrome ? 1 : 0.5)))
            .frame(width: w, height: h)
            .scaleEffect(lit ? HyperspaceMotion.gridCellLitScale : (warm ? HyperspaceMotion.gridCellWarmScale : 1))
            .shadow(color: lit ? chromeSelection.opacity(0.35)
                    : (warm ? chromeSelection.opacity(0.15) : .clear),
                    radius: lit ? 5 : (warm ? 3 : 0))
            .zIndex(lit ? 1 : 0)
            .animation(HyperspaceMotion.hover, value: lit)
    }

    // MARK: - Preview — a dedicated slot that always shows the screen's zones
    //
    // The middle band slot. Never empty: by default it renders the *current* layout of this
    // display (so it's always useful), with staged moves and a hovered layer drawn on top.
    // Display-only — drops still land on the Layers/Grid controls.

    private enum ZoneStyle { case baseline, staged, live }

    // A window zone on the placement stage. `baseline` = a faint "currently here" footprint;
    // `staged` = a bright planned move; `live` = the spot you're about to pick.
    private func zoneRect(_ frac: CGRect, _ tint: Color, _ image: NSImage?, _ box: CGSize, _ style: ZoneStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let r = CGRect(x: frac.minX * box.width, y: frac.minY * box.height,
                       width: max(8, frac.width * box.width), height: max(7, frac.height * box.height))
        let fillOpacity: Double = style == .baseline ? 0.14 : (style == .live ? 0.34 : 0.42)
        let imageOpacity: Double = style == .baseline ? 0.28 : 0.6
        let strokeColor: Color = style == .baseline ? .white.opacity(0.18) : tint
        let strokeW: CGFloat = style == .live ? 2 : (style == .baseline ? 0.75 : 1)
        // Clip the *framed container*, not the image: with aspectRatio(.fill) the image scales up to
        // cover (width-led), so clipping it directly lets its height overflow the zone. Framing the
        // ZStack then clipping confines it to the zone in both dimensions.
        return ZStack {
            shape.fill(tint.opacity(fillOpacity))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).opacity(imageOpacity)
            }
        }
        .frame(width: r.width - 2, height: r.height - 2)
        .clipShape(shape)
        .overlay(shape.strokeBorder(strokeColor, lineWidth: strokeW))
        .position(x: r.midX, y: r.midY)
    }

    // Fit a rect of the given aspect (w/h) inside `size`, leaving a little air.
    private func aspectFit(in size: CGSize, aspect: CGFloat) -> CGSize {
        let avail = CGSize(width: max(1, size.width - 4), height: max(1, size.height - 4))
        var w = avail.width
        var h = w / max(0.1, aspect)
        if h > avail.height { h = avail.height; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    // Shared chrome for a band section: a titled card. `live` tints it on-brand;
    // `armed` lights it up while the cursor is over it mid-drag, so you can see which
    // axis (location vs layer) you're about to commit.
    private func sectionCard<Content: View>(title: String, icon: String, sub: String,
                                            live: Bool, armed: Bool = false,
                                            @ViewBuilder content: () -> Content) -> some View {
        sectionCard(title: title, icon: icon, sub: sub, live: live, armed: armed,
                    trailing: { EmptyView() }, content: content)
    }

    private func sectionCard<Content: View, Trailing: View>(title: String, icon: String, sub: String,
                                            live: Bool, armed: Bool = false,
                                            @ViewBuilder trailing: () -> Trailing,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(chromeText.opacity(live ? 0.85 : 0.5))
                Text(title)
                    .font(unifiedChrome ? Typo.heading(12) : Typo.monoBold(11)).foregroundColor(chromeText).tracking(0.3)
                Text(sub)
                    .font(unifiedChrome ? Typo.caption(10) : Typo.mono(8.5)).foregroundColor(armed ? chromeAccent : chromeSecondary)
                Spacer(minLength: 0)
                trailing()
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .padding(.horizontal, inPlace ? 8 : 12).padding(.top, inPlace ? 7 : 9).padding(.bottom, inPlace ? 6 : 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if unifiedChrome { HyperspaceGlassBackground() }
            else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: unifiedChrome ? 18 : 14, style: .continuous)
                .strokeBorder(armed ? chromeAccent.opacity(0.5) : chromeBorder, lineWidth: armed ? 1.5 : 0.75)
        )
        .shadow(color: armed ? chromeAccent.opacity(0.12) : Color.black.opacity(unifiedChrome ? 0.08 : 0.3), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.16), value: armed)
    }

    // The dragged thumbnail, following the cursor on the owning screen only. Over a
    // live drop target (a grid cell or a layer pile) it shrinks — a clear "about to
    // land here" tell that also previews how small the window reads in the target.
    @ViewBuilder
    private var ghostOverlay: some View {
        if drag.isActive, drag.screenID == screenID, drag.image != nil || drag.ghostTint != nil {
            let armed = drag.hoverCell != nil || drag.hoverLayer != nil || drag.hoverLayoutTitle != nil || drag.placementPreview != nil
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            Group {
                if let img = drag.image {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fill)
                } else if let tint = drag.ghostTint {
                    ZStack {
                        shape.fill(tint.opacity(0.38))
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: drag.tileSize.width, height: drag.tileSize.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(armed ? chromeAccent : Palette.running, lineWidth: armed ? 2.5 : 2))
            .shadow(color: .black.opacity(armed ? 0.6 : 0.5), radius: armed ? 10 : 16, x: 0, y: armed ? 4 : 8)
            .scaleEffect(armed ? HyperspaceMotion.ghostArmedScale : 1, anchor: .center)
            .opacity(armed ? 1 : 0.92)
            .animation(HyperspaceMotion.drag, value: armed)
            .overlay(alignment: .topTrailing) {
                if drag.dragWids.count > 1 {
                    Text("\(drag.dragWids.count)")
                        .font(Typo.monoBold(10))
                        .foregroundColor(Palette.bg)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.running))
                        .offset(x: 8, y: -8)
                }
            }
            .position(drag.location)
            .allowsHitTesting(false)
        }
    }

    // The "landed" ring at the last drop target — fires the instant you release, so a
    // drop reads as confirmed even after the hover highlight has cleared.
    @ViewBuilder
    private var dropPulseOverlay: some View {
        if let p = drag.dropPulse, drag.screenID == screenID {
            DropPulseRing(frame: p.frame, tint: Palette.running)
                .id(p.id)
        }
    }

    // MARK: - Drag handling

    /// Modifier-driven resolution while a drag is held — overrides the selector.
    private static func modifierRes() -> LatticeRes? {
        let f = NSEvent.modifierFlags
        if f.contains(.control) { return .dense }
        if f.contains(.command) { return .fine }
        if f.contains(.option)  { return .thirds }
        if f.contains(.shift)   { return .halves }
        return nil
    }

    private func handleDragChange(_ t: Tile, tileWidth: CGFloat, solo: Bool = false, _ v: DragGesture.Value) {
        handleDragChange(wid: t.id, image: t.image, ghostTint: t.tint, source: .survey,
                         tileW: tileWidth, tileH: (tileWidth * 0.62).rounded(), solo: solo, v)
    }

    private func popDragCursor() {
        NSCursor.pop()
    }

    private func layoutDragGesture(_ m: LayerMember) -> some Gesture {
        let ghostW: CGFloat = 72
        let ghostH = (ghostW * 0.62).rounded()
        return DragGesture(minimumDistance: 10, coordinateSpace: .named(ExposeView.rootSpace))
            .onChanged { handleDragChange(wid: m.id, image: m.image, ghostTint: m.tint,
                                          source: .currentView, tileW: ghostW, tileH: ghostH, $0) }
            .onEnded { handleLayoutDragEnd(m, $0) }
    }

    private func dragWidsFor(_ wid: UInt32) -> [UInt32] {
        if pickedWids.contains(wid), pickedOrder.count >= 2 { return pickedOrder }
        return [wid]
    }

    private func handleDragChange(wid: UInt32, image: NSImage?, ghostTint: Color? = nil,
                                  source: HyperspaceDrag.DragSource,
                                  tileW: CGFloat, tileH: CGFloat, solo: Bool = false, _ v: DragGesture.Value) {
        drag.location = v.location
        let dist = hypot(v.translation.width, v.translation.height)
        if drag.wid == nil {
            guard dist >= 10 else { return }
            drag.wid = wid
            let bunch = dragWidsFor(wid)
            let onScreen = layoutPreview?.frames[wid] != nil
            drag.dragWids = (solo && onScreen) ? [wid] : bunch
            drag.image = image
            drag.ghostTint = image == nil ? ghostTint : nil
            drag.screenID = screenID
            drag.dragSource = source
            drag.tileSize = CGSize(width: tileW, height: tileH)
            if source == .currentView {
                NSCursor.pop()                 // openHand from hover
                NSCursor.closedHand.push()
            }
        }
        drag.res = Self.modifierRes() ?? drag.baseRes
        updateHoverCell()
        updateHoverCurrentView()
        updateHoverLayer()
        updateHoverLayout()
        updateProposalLanding()
    }

    private func handleLayoutDragEnd(_ m: LayerMember, _ v: DragGesture.Value) {
        handleDragEnd(wid: m.id, source: .currentView, onTap: { onPick(m.id) }, v)
    }

    private func handleDragEnd(_ t: Tile, _ v: DragGesture.Value) {
        handleDragEnd(wid: t.id, source: .survey, onTap: { onPick(t.id) }, v)
    }

    private func handleDragEnd(wid: UInt32, source: HyperspaceDrag.DragSource,
                               onTap: () -> Void, _ v: DragGesture.Value) {
        let dist = hypot(v.translation.width, v.translation.height)
        let wasDragging = drag.wid != nil
        let dragWids = drag.dragWids.isEmpty ? [wid] : drag.dragWids
        // Resolve the drop target before reset() clears the hover state. Priority:
        // Grid cell → layer pile → miss.
        var gridCell: HoverCell?
        var pulseFrame: CGRect?
        if wasDragging,
           let frame = drag.latticeFrames[screenID], frame.contains(v.location),
           let cell = drag.hoverCell {
            gridCell = cell
            let (cols, rows) = drag.res.dims
            let cw = frame.width / CGFloat(cols), ch = frame.height / CGFloat(rows)
            if dragWids.count > 1,
               let cells = balancedGridCells(count: dragWids.count, latticeCols: cols, latticeRows: rows,
                                             anchorCol: cell.col, anchorRow: cell.row),
               let last = cells.last {
                let spanCols = last.col - cell.col + 1
                let spanRows = last.row - cell.row + 1
                pulseFrame = CGRect(x: frame.minX + CGFloat(cell.col) * cw,
                                    y: frame.minY + CGFloat(cell.row) * ch,
                                    width: cw * CGFloat(spanCols), height: ch * CGFloat(spanRows))
            } else {
                pulseFrame = CGRect(x: frame.minX + CGFloat(cell.col) * cw,
                                    y: frame.minY + CGFloat(cell.row) * ch, width: cw, height: ch)
            }
        }
        let layerKey = (wasDragging && gridCell == nil) ? drag.hoverLayer : nil
        let dropRes = drag.res
        if let layerKey { pulseFrame = drag.layerFrames[screenID]?[layerKey] }
        // A layout card is the ordinary overview target. A grid cell or a layer
        // pile still wins when those tools are open and the pointer is on them.
        var chosenPlan: HyperspaceLayoutPlan?
        var chosenIDs: [UInt32] = []
        if wasDragging, gridCell == nil, layerKey == nil, let title = drag.hoverLayoutTitle,
           let plan = layoutPlans(for: layoutSubjectIDs).first(where: { $0.title == title }) {
            chosenPlan = plan
            chosenIDs = layoutSubjectIDs
            pulseFrame = drag.layoutCardFrames[screenID]?[title]
        }
        let placement = (wasDragging && gridCell == nil && layerKey == nil && chosenPlan == nil)
            ? drag.placementPreview : nil
        if let placement {
            if placement.frames.count > 1, HyperspaceLayoutPlanner.isArrangement(placement.title),
               let canvas = drag.proposalCanvas[screenID], canvas.width > 1 {
                pulseFrame = canvas
            } else if let widFrame = placement.frames[wid] {
                pulseFrame = proposalSlotFrames()[wid] ?? proposalCanvasRect(widFrame)
            }
        }
        let fromLayout = drag.dragSource == .currentView
        drag.reset()
        if fromLayout { popDragCursor() }
        if !wasDragging && dist < 12 {
            onTap()
        } else if let layerKey {
            onDropLayers(dragWids, layerKey)
            if let pulseFrame { drag.firePulse(at: pulseFrame) }
        } else if let cell = gridCell {
            if dragWids.count > 1 {
                onDropGridGroup(dragWids, dropRes, cell)
            } else {
                let (cols, rows) = dropRes.dims
                let spec = GridPlacement(columns: cols, rows: rows, column: cell.col, row: cell.row).map(PlacementSpec.grid)
                onDrop(wid, spec)
            }
            if let pulseFrame { drag.firePulse(at: pulseFrame) }
        } else if let plan = chosenPlan {
            onChooseLayout(chosenIDs, plan)
            if let pulseFrame { drag.firePulse(at: pulseFrame) }
        } else if let placement {
            onPlaceInProposal(dragWids, placement)
            if let pulseFrame { drag.firePulse(at: pulseFrame) }
        } else {
            onDrop(wid, nil)
        }
    }

    private func updateHoverCurrentView() {
        guard let frame = drag.currentViewFrames[screenID], frame.width > 1 else {
            if drag.hoverCurrentView { drag.hoverCurrentView = false }
            return
        }
        let hit = frame.contains(drag.location)
        if drag.hoverCurrentView != hit { drag.hoverCurrentView = hit }
    }

    private func updateHoverLayer() {
        let frames = drag.layerFrames[screenID] ?? [:]
        let hit = frames.first { $0.value.width > 1 && $0.value.contains(drag.location) }?.key
        if drag.hoverLayer != hit { drag.hoverLayer = hit }
    }

    private func updateHoverLayout() {
        guard drag.isActive, drag.screenID == screenID, drag.hoverCell == nil, drag.hoverLayer == nil else {
            if drag.screenID == screenID, drag.hoverLayoutTitle != nil { drag.hoverLayoutTitle = nil }
            return
        }
        let frames = drag.layoutCardFrames[screenID] ?? [:]
        var best: String?
        var bestDist = CGFloat.infinity
        for (title, frame) in frames where frame.width > 1 {
            let hit = frame.insetBy(dx: -6, dy: -8)
            guard hit.contains(drag.location) else { continue }
            let distance = hypot(drag.location.x - frame.midX, drag.location.y - frame.midY)
            if distance < bestDist { bestDist = distance; best = title }
        }
        if drag.hoverLayoutTitle != best { drag.hoverLayoutTitle = best }
    }

    private func proposalCanvasRect(_ frame: CGRect) -> CGRect {
        guard let canvas = drag.proposalCanvas[screenID], canvas.width > 1, canvas.height > 1 else { return .zero }
        let frac = proposalFraction(frame)
        return CGRect(x: canvas.minX + frac.minX * canvas.width,
                      y: canvas.minY + frac.minY * canvas.height,
                      width: frac.width * canvas.width,
                      height: frac.height * canvas.height)
    }

    /// Slot rectangles in the same root space as the drag. They match the
    /// frames drawn on the proposal, so a drop lands on the window you see.
    private func proposalSlotFrames() -> [UInt32: CGRect] {
        guard let canvas = drag.proposalCanvas[screenID], canvas.width > 1, canvas.height > 1 else { return [:] }
        var slots: [UInt32: CGRect] = [:]
        for marker in stagedPlan where marker.frac.width > 0.01 && marker.frac.height > 0.01 {
            slots[marker.id] = CGRect(x: canvas.minX + marker.frac.minX * canvas.width,
                                     y: canvas.minY + marker.frac.minY * canvas.height,
                                     width: marker.frac.width * canvas.width,
                                     height: marker.frac.height * canvas.height)
        }
        return slots
    }

    private func updateProposalLanding() {
        guard drag.isActive, drag.screenID == screenID, let wid = drag.wid,
              drag.hoverCell == nil, drag.hoverLayer == nil, drag.hoverLayoutTitle == nil,
              let canvas = drag.proposalCanvas[screenID], canvas.width > 1, canvas.height > 1,
              screenAX.width > 1, screenAX.height > 1, layoutArea.width > 1 else {
            if drag.placementPreview != nil { drag.placementPreview = nil }
            return
        }
        let near = canvas.insetBy(dx: -36, dy: -36).contains(drag.location)
        guard near else {
            if drag.placementPreview != nil { drag.placementPreview = nil }
            return
        }
        let fx = min(1, max(0, (drag.location.x - canvas.minX) / canvas.width))
        let fy = min(1, max(0, (drag.location.y - canvas.minY) / canvas.height))
        let point = CGPoint(x: screenAX.minX + fx * screenAX.width, y: screenAX.minY + fy * screenAX.height)
        let ids = drag.dragWids.count >= 2 ? drag.dragWids : [wid]
        let preview: HyperspaceLayoutPlan?
        if ids.count >= 2 {
            preview = HyperspaceLayoutPlanner.arrangements(ids, in: layoutArea).first
        } else {
            if drag.placementAnchor == nil { drag.placementAnchor = point }
            let original = layoutPreview?.frames[wid] ?? CGRect(
                x: layoutArea.midX - layoutArea.width * 0.22,
                y: layoutArea.midY - layoutArea.height * 0.28,
                width: layoutArea.width * 0.44,
                height: layoutArea.height * 0.56)
            let neighbors = (layoutPreview?.frames ?? [:]).filter { $0.key != wid }.map { ($0.key, $0.value) }
            preview = HyperspaceLayoutPlanner.spot(wid, original: original, start: drag.placementAnchor ?? point,
                                                   at: point, in: layoutArea, neighbors: neighbors,
                                                   fraction: CGPoint(x: fx, y: fy))
        }
        if drag.placementPreview != preview { drag.placementPreview = preview }
    }

    private func updateHoverCell() {
        guard let frame = drag.latticeFrames[screenID], frame.width > 1 else {
            if drag.hoverCell != nil { drag.hoverCell = nil }
            if drag.hoverGrid { drag.hoverGrid = false }
            return
        }
        // Forgiving hit: pad the grid bounds so you don't have to thread the needle.
        let pad: CGFloat = drag.isActive ? 14 : 0
        let hitFrame = frame.insetBy(dx: -pad, dy: -pad)
        guard hitFrame.contains(drag.location) else {
            if drag.hoverCell != nil { drag.hoverCell = nil }
            if drag.hoverGrid { drag.hoverGrid = false }
            return
        }
        if !drag.hoverGrid { drag.hoverGrid = true }
        let (cols, rows) = drag.res.dims
        let cw = frame.width / CGFloat(cols)
        let ch = frame.height / CGFloat(rows)
        // Snap to the nearest cell center — more forgiving than strict rect partitions.
        var bestCol = 0
        var bestRow = 0
        var bestDist = CGFloat.infinity
        for r in 0..<rows {
            for c in 0..<cols {
                let cx = frame.minX + (CGFloat(c) + 0.5) * cw
                let cy = frame.minY + (CGFloat(r) + 0.5) * ch
                let d = hypot(drag.location.x - cx, drag.location.y - cy)
                if d < bestDist { bestDist = d; bestCol = c; bestRow = r }
            }
        }
        let cell = HoverCell(col: bestCol, row: bestRow)
        if drag.hoverCell != cell { drag.hoverCell = cell }
    }

    private func clusterFullyPicked(_ c: Cluster) -> Bool {
        !c.tiles.isEmpty && c.tiles.allSatisfy { pickedWids.contains($0.id) }
    }

    private func clusterPartiallyPicked(_ c: Cluster) -> Bool {
        c.tiles.contains { pickedWids.contains($0.id) }
    }

    private func clusterQuickActions(_ c: Cluster) -> some View {
        let picked = clusterPartiallyPicked(c)
        return HStack(spacing: 6) {
            Button { onFocusCluster(c.id) } label: {
                clusterActionChip("Open", icon: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .help("Bring \(c.name) to the front")
            Button { onPluckGroup(c.id) } label: {
                clusterActionChip(clusterFullyPicked(c) ? "Deselect" : "Select",
                                  icon: clusterFullyPicked(c) ? "minus.circle" : "plus.circle",
                                  accent: true)
            }
            .buttonStyle(.plain)
            if picked {
                Button { onGridSelection() } label: {
                    clusterActionChip("Gather", icon: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .help("Arrange the selected windows in a grid")
            }
            Button(role: .destructive) { onQuitCluster(c.id) } label: {
                clusterActionChip("Quit", icon: "xmark.circle", destructive: true)
            }
            .buttonStyle(.plain)
            .help("Quit \(c.name)")
        }
    }

    private func clusterActionChip(_ title: String,
                                   icon: String,
                                   accent: Bool = false,
                                   destructive: Bool = false) -> some View {
        let hue: Color = destructive ? Palette.kill : (accent ? chromeSelection : chromeText)
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(9))
        }
        .foregroundColor(hue)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule()
                .fill(chromeBacking(0.55))
                .overlay(Capsule().fill(hue.opacity(destructive || accent ? 0.16 : 0.08)))
                .overlay(Capsule().strokeBorder(
                    destructive ? Palette.kill.opacity(0.55)
                        : (accent ? chromeSelection.opacity(0.55) : chromeBorder),
                    lineWidth: 0.5))
        )
    }

    private func clusterBox(_ c: Cluster) -> some View {
        let expanded = isExpandedTerminalCluster(c)
        let shown = filteredTiles(in: c)
        let localTile = clusterTileWidth(c)
        let cap = clusterColumnCap(c)
        let cols = min(max(shown.count, 1), cap)
        let innerW = localTile * CGFloat(cols) + 8 * CGFloat(max(0, cols - 1))
        let groupPicked = clusterFullyPicked(c)
        let groupPartial = clusterPartiallyPicked(c)
        return VStack(alignment: .leading, spacing: 9) {
            if unifiedChrome {
                HStack(spacing: 10) {
                    if let icon = c.tiles.first?.appIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 22, weight: .regular)).foregroundColor(chromeSecondary)
                    }
                    Button { onPluckGroup(c.id) } label: {
                        HStack(spacing: 8) {
                            Text(c.name).font(.system(size: 14, weight: .semibold)).foregroundColor(chromeText)
                            Text("\(c.tiles.count)").font(.system(size: 12)).foregroundColor(chromeSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Select all \(c.name) windows · ⇧\(c.hint)")
                    Spacer(minLength: 8)
                    Menu { clusterContextMenu(c) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).foregroundColor(chromeSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(c.name) group actions")
                }
                .frame(height: 32)
                .padding(.horizontal, 3)
                .contextMenu { clusterContextMenu(c) }
            } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if !c.hint.isEmpty {
                        Text("⇧\(c.hint)")
                            .font(Typo.monoBold(9))
                            .foregroundColor(c.userDefined ? chromeOnAccent : chromeText)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(c.userDefined ? chromeSelection : chromeWell)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
                            )
                            .help("Select the whole \(c.name) group")
                    }
                    Text(c.name)
                        .font(unifiedChrome ? Typo.heading(13) : Typo.monoBold(11)).foregroundColor(chromeText).tracking(0.3)
                    Text(c.rule)
                        .font(unifiedChrome ? Typo.caption(10) : Typo.mono(9)).foregroundColor(chromeSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(chromeBorder, lineWidth: 0.5))
                        )
                    if expanded {
                        Text("\(c.tiles.count)")
                            .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8))
                            .tracking(0.6)
                            .foregroundColor(chromeAccent.opacity(0.9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(chromeAccent.opacity(0.10))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(chromeAccent.opacity(0.35), lineWidth: 0.5))
                            )
                            .help("\(c.tiles.count) windows in this terminal group")
                    }
                    Spacer(minLength: 16)
                    Text(c.userDefined ? "you" : "smart")
                        .font(unifiedChrome ? Typo.caption(10) : Typo.mono(8))
                        .tracking(0.6)
                        .foregroundColor(c.userDefined ? chromeSelection : chromeSecondary)
                }
                if !inPlace {
                    clusterQuickActions(c)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onPluckGroup(c.id) }
            .contextMenu { clusterContextMenu(c) }
            .help("Click to select all \(c.name) windows")
            }
            if expanded {
                clusterSearchBar(c, visibleCount: shown.count)
                    .frame(width: innerW, alignment: .leading)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if shown.isEmpty {
                    emptyClusterSearchState(c)
                } else {
                    ForEach(shown) { tileView($0, width: localTile) }
                }
            }
            .frame(maxWidth: innerW, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 11)
        .background {
            if unifiedChrome { Color.clear }
            else {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(groupPicked ? 0.06 : (expanded ? 0.032 : (c.userDefined ? 0.03 : 0.018))))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: unifiedChrome ? 16 : 13, style: .continuous)
                .strokeBorder(unifiedChrome ? Color.clear : groupPicked ? chromeSelection.opacity(0.55)
                              : (groupPartial ? chromeSelection.opacity(0.28)
                                 : (expanded ? chromeAccent.opacity(0.30)
                                    : chromeBorder)),
                              lineWidth: groupPicked ? 1.35 : (expanded ? 1.15 : 1))
        )
    }

    @ViewBuilder
    private func clusterContextMenu(_ c: Cluster) -> some View {
        Button { onPluckGroup(c.id) } label: {
            Label(clusterFullyPicked(c) ? "Deselect Group" : "Select Group",
                  systemImage: clusterFullyPicked(c) ? "minus.circle" : "plus.circle")
        }
        Button { onFocusCluster(c.id) } label: {
            Label("Open \(c.name)", systemImage: "arrow.up.forward.square")
        }
        if clusterPartiallyPicked(c) {
            Button { onGridSelection() } label: {
                Label("Gather Selection", systemImage: "square.grid.2x2")
            }
        }
        Divider()
        Button(role: .destructive) { onQuitCluster(c.id) } label: {
            Label("Quit \(c.name)", systemImage: "xmark.circle")
        }
    }

    private func isExpandedTerminalCluster(_ c: Cluster) -> Bool {
        guard c.tiles.count >= 10 else { return false }
        let needles = ["iterm", "terminal", "warp", "ghostty", "wezterm", "kitty", "alacritty"]
        let clusterName = c.name.lowercased()
        return needles.contains { needle in
            clusterName.contains(needle) ||
                c.tiles.contains { $0.app.lowercased().contains(needle) }
        }
    }

    private func clusterColumnCap(_ c: Cluster) -> Int {
        if isExpandedTerminalCluster(c) { return layoutTall ? 3 : 6 }
        return colCap
    }

    private func clusterTileWidth(_ c: Cluster) -> CGFloat {
        guard isExpandedTerminalCluster(c) else { return tile }
        return min((tile * 1.16).rounded(), tile + 36)
    }

    private func filteredTiles(in c: Cluster) -> [Tile] {
        let q = c.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return c.tiles }
        return c.tiles.filter { tileMatchesClusterSearch($0, query: q) }
    }

    private func tileMatchesClusterSearch(_ t: Tile, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return true }
        let haystack = "\(t.title) \(t.app) \(t.hint)".lowercased()
        return terms.allSatisfy { haystack.range(of: String($0)) != nil }
    }

    private func clusterSearchBar(_ c: Cluster, visibleCount: Int) -> some View {
        let active = c.searchActive
        let query = c.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(active ? chromeAccent : chromeSecondary)
            Text(query.isEmpty ? "filter \(c.name)" : query)
                .font(unifiedChrome ? Typo.caption(10) : Typo.mono(10))
                .foregroundColor(query.isEmpty ? chromeSecondary : chromeText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !query.isEmpty {
                Text("\(visibleCount)/\(c.tiles.count)")
                    .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8))
                    .foregroundColor(visibleCount > 0 ? chromeAccent.opacity(0.9) : Palette.detach)
                Button { onClearClusterSearch(c.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(chromeSecondary)
                }
                .buttonStyle(.plain)
            } else if active {
                Text("typing")
                    .font(unifiedChrome ? Typo.heading(10) : Typo.monoBold(8))
                    .foregroundColor(chromeAccent.opacity(0.8))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            shape.fill(chromeBacking(active ? 0.34 : 0.24))
                .overlay(shape.strokeBorder(active ? chromeAccent.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture { onBeginClusterSearch(c.id) }
        .help("Click, type to filter \(c.name), Return selects matches")
    }

    private func emptyClusterSearchState(_ c: Cluster) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
            Text("no matches")
                .font(unifiedChrome ? Typo.caption(10) : Typo.mono(10))
        }
        .foregroundColor(chromeSecondary)
        .frame(width: clusterTileWidth(c), height: (clusterTileWidth(c) * 0.62).rounded())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4])))
        )
    }

    private func tileForWid(_ wid: UInt32) -> Tile? {
        clusters.flatMap(\.tiles).first { $0.id == wid }
    }

    // Hyper+G inventory / Current View menu — selection-aware actions, not just placements.
    @ViewBuilder
    private func inPlaceTileMenu(_ t: Tile) -> some View {
        inPlaceSelectionActions(t)
        Divider()
        Button { onFocusWindow(t.id) } label: {
            Label("Focus on Desktop", systemImage: "macwindow.on.rectangle")
        }
        Divider()
        inPlacePlacementMenus(t)
        inPlaceLayerMenu(t)
        Divider()
        Button { onOpenHyperspace() } label: {
            Label("Open Hyperspace Survey", systemImage: "rectangle.on.rectangle.angled")
        }
    }

    @ViewBuilder
    private func inPlaceSelectionActions(_ t: Tile) -> some View {
        let picked = t.pickSlot != nil
        let pickCount = pickedWids.count
        Button { onPick(t.id) } label: {
            Label(picked ? "Deselect" : "Select", systemImage: picked ? "minus.circle" : "plus.circle")
        }
        if pickCount > 0 {
            Divider()
            Button { onGridSelection() } label: {
                Label(pickCount >= 2 ? "Grid \(pickCount) Windows · Live Now" : "Grid Selection",
                      systemImage: "square.grid.2x2")
            }
            .disabled(pickCount < 2)
            if pickCount >= 2 {
                Button { onStackSelection() } label: {
                    Label("Create Tab Group from \(pickCount) Windows · Close Hyperspace",
                          systemImage: "rectangle.stack")
                }
                Button { onSwapFirstTwo() } label: {
                    Label("Swap First Two · Live Now (S)", systemImage: "arrow.left.arrow.right")
                }
            }
            inPlaceSwapWithMenu(t)
            Button(role: .destructive) { onClearSelection() } label: {
                Label("Clear Selection", systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder
    private func inPlaceSwapWithMenu(_ t: Tile) -> some View {
        let picked = t.pickSlot != nil
        let others = pickedOrder.filter { $0 != t.id }
        if picked, !others.isEmpty {
            Menu("Swap with…", systemImage: "arrow.triangle.swap") {
                ForEach(others, id: \.self) { wid in
                    Button(tileForWid(wid)?.app ?? "Window") { onSwapWith(t.id, wid) }
                }
            }
        }
    }

    @ViewBuilder
    private func inPlacePlacementMenus(_ t: Tile) -> some View {
        Button { onFillAvailable(t.id) } label: {
            Label("Fill Available Space · Live Now (F)", systemImage: "arrow.up.backward.and.arrow.down.forward")
        }
        Menu("Apply Position · Live Now", systemImage: "arrow.up.left.and.arrow.down.right") {
            placementQuickItems(wid: t.id, handler: onApplyPlacement)
        }
        Menu("Stage Position for Keep", systemImage: "clock.badge.checkmark") {
            Button { drag.beginPlacing(t.id, on: screenID) } label: {
                Label("Place…", systemImage: "rectangle.dashed")
            }
            Divider()
            placementQuickItems(wid: t.id) { wid, spec in onDrop(wid, spec) }
        }
    }

    @ViewBuilder
    private func inPlaceLayerMenu(_ t: Tile) -> some View {
        Divider()
        Menu("Add to Layer on Keep", systemImage: "square.stack.3d.up") {
            Button("New Layer") { onNewLayer() }
            let joinable = layers.filter { !$0.isNew }
            if !joinable.isEmpty {
                Divider()
                ForEach(joinable) { p in
                    Button(p.name) { onDropLayer(t.id, p.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func placementQuickItems(wid: UInt32,
                                     handler: @escaping (UInt32, PlacementSpec) -> Void) -> some View {
        Button("Left Half")   { handler(wid, GridPlacement(columns: 2, rows: 1, column: 0, row: 0).map(PlacementSpec.grid)!) }
        Button("Right Half")  { handler(wid, GridPlacement(columns: 2, rows: 1, column: 1, row: 0).map(PlacementSpec.grid)!) }
        Button("Top Half")    { handler(wid, GridPlacement(columns: 1, rows: 2, column: 0, row: 0).map(PlacementSpec.grid)!) }
        Button("Bottom Half") { handler(wid, GridPlacement(columns: 1, rows: 2, column: 0, row: 1).map(PlacementSpec.grid)!) }
        Menu("Quarter") {
            Button("Top Left")     { handler(wid, GridPlacement(columns: 2, rows: 2, column: 0, row: 0).map(PlacementSpec.grid)!) }
            Button("Top Right")    { handler(wid, GridPlacement(columns: 2, rows: 2, column: 1, row: 0).map(PlacementSpec.grid)!) }
            Button("Bottom Left")  { handler(wid, GridPlacement(columns: 2, rows: 2, column: 0, row: 1).map(PlacementSpec.grid)!) }
            Button("Bottom Right") { handler(wid, GridPlacement(columns: 2, rows: 2, column: 1, row: 1).map(PlacementSpec.grid)!) }
        }
        Button("Maximize") { handler(wid, GridPlacement(columns: 1, rows: 1, column: 0, row: 0).map(PlacementSpec.grid)!) }
    }

    // The right-click menu for a window: quick tile presets (stage immediately), a visual
    // "Place…" that opens the life-size stage, layer joins, and pluck. Options, not actions —
    // nothing real moves until ⏎/G, same as the rest of Hyperspace.
    @ViewBuilder
    private func tileMenu(_ t: Tile) -> some View {
        let picked = t.pickSlot != nil
        let pickCount = pickedWids.count
        Button { onPick(t.id) } label: {
            Label(picked ? "Remove from Selection" : "Add to Selection",
                  systemImage: picked ? "minus.circle" : "plus.circle")
        }
        if pickCount >= 2 {
            Button { onStackSelection() } label: {
                Label("Create Tab Group from \(pickCount) Windows", systemImage: "rectangle.stack")
            }
            Button { onGridSelection() } label: {
                Label("Arrange \(pickCount) Side by Side", systemImage: "rectangle.split.2x1")
            }
        }
        Divider()
        Button { drag.beginPlacing(t.id, on: screenID) } label: {
            Label("Place…", systemImage: "rectangle.dashed")
        }
        Divider()
        placementQuickItems(wid: t.id) { wid, spec in onDrop(wid, spec) }
        let joinable = layers.filter { !$0.isNew }
        if !joinable.isEmpty {
            Divider()
            Menu("Add to Layer") {
                ForEach(joinable) { p in
                    Button(p.name) { onDropLayer(t.id, p.id) }
                }
            }
        }
    }

    private func stagePlacement(_ wid: UInt32, _ gp: GridPlacement?) {
        onDrop(wid, gp.map(PlacementSpec.grid))
    }

    private func tileView(_ t: Tile, width: CGFloat? = nil) -> some View {
        let w = width ?? tile
        let h = (w * 0.62).rounded()
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let picked = t.pickSlot != nil
        let staged = t.staged != nil || !t.layerTags.isEmpty
        let beingDragged = drag.wid == t.id && drag.screenID == screenID
        // Cross-link + layer roster: highlighted tiles pop, the rest sink.
        let inHighlight = surveyHighlightWids?.contains(t.id)
        let highlightLit = inHighlight == true
        let highlightDimmed = inHighlight == false && surveyHighlightWids != nil
        let crossLinked = activeLinkWid == t.id
        let lit = t.isAimed || picked || highlightLit
        // Unified chrome: one hairline for every lit state, coral only on window 1.
        let first = t.pickSlot == 1
        let strokeColor: Color = unifiedChrome
            ? (first || crossLinked ? chromeAccent
               : (picked || staged || highlightLit || t.isAimed ? chromeText.opacity(0.5) : chromeBorder))
            : (staged ? chromeAccent
               : (crossLinked ? chromeAccent
                  : (picked ? chromeAccent : (highlightLit ? chromeSelection
                     : (t.isAimed ? chromeAccent : chromeBorder)))))
        let strokeW: CGFloat = unifiedChrome
            ? (first || crossLinked ? 1.5 : (picked || staged || highlightLit || t.isAimed ? 1 : 0.5))
            : (staged ? 2
               : (crossLinked ? 2.5 : (picked || highlightLit ? 2 : (t.isAimed ? 1.5 : 0.75))))
        let veil: Double = highlightLit || lit ? 0 : spotlight * (unifiedChrome ? 0.12 : 0.5)
        let bloom: Color = t.isAimed && !unifiedChrome ? lightColor.opacity(0.7 * spotlight) : .clear
        let bloomR: CGFloat = t.isAimed ? 8 + spotlight * 22 : 0
        return tileBody(t, w: w, h: h, shape: shape)
            .opacity(unifiedChrome && highlightDimmed ? 0.4 : 1)
            .overlay(shape.fill(Color.black.opacity(veil)))    // spotlight: off-stage tiles sink to shadow
            .overlay(shape.strokeBorder(strokeColor, lineWidth: strokeW))
            .overlay(alignment: .topTrailing) {
                // The key letter shows on the tile under the hand or the keyboard.
                if !unifiedChrome || handKeys || t.isAimed || drag.hoverSurveyWid == t.id { hintChip(t) }
            }
            .overlay(alignment: .topLeading) { if let s = t.pickSlot { slotBadge(s, unifiedChrome ? slotTint(s) : chromeAccent) } }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    if !t.layerTags.isEmpty { layerTagRow(t.layerTags) }
                    titleLabel(t)
                }
                .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                if let s = t.staged {
                    stagedBadge(s).transition(.opacity)
                }
            }
            .animation(HyperspaceMotion.badge, value: t.staged)
            .animation(HyperspaceMotion.badge, value: t.layerTags)
            .overlay {
                if crossLinked {
                    shape.strokeBorder(chromeAccent, lineWidth: 2)
                        .shadow(color: chromeAccent.opacity(0.35), radius: 5)
                } else if highlightLit && !unifiedChrome {
                    shape.strokeBorder(chromeSelection, lineWidth: 2)
                }
            }
            .scaleEffect(crossLinked ? HyperspaceMotion.tileLinkScale : 1, anchor: .center)
            .animation(HyperspaceMotion.focus, value: crossLinked)
            // While this tile is the one being dragged, hollow it out so it keeps its
            // slot (no reflow) but reads as "lifted" — the ghost is what moves.
            .opacity(beingDragged ? 0.22 : (highlightDimmed && !unifiedChrome ? 0.26 : 1))
            .overlay {
                if beingDragged {
                    shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundColor(chromeAccent.opacity(0.8))
                }
            }
            .background(frameReporter(t.id))
            .shadow(color: .black.opacity(unifiedChrome ? 0.10 : (picked ? 0.5 : 0.35)), radius: picked ? 14 : 8, x: 0, y: 5)
            .shadow(color: crossLinked ? chromeAccent.opacity(0.4)
                    : (highlightLit ? chromeSelection.opacity(0.3) : bloom),
                    radius: crossLinked ? 8 : (highlightLit ? 8 : bloomR * 0.6))
            .contentShape(Rectangle())
            .onHover { over in
                guard !drag.isActive else { return }
                if over {
                    drag.hoverSurveyWid = t.id
                } else if drag.hoverSurveyWid == t.id {
                    drag.hoverSurveyWid = nil
                }
            }
            // Right-click → a menu of options (not a surprise action). Quick tile presets stage
            // immediately; "Place…" opens the life-size stage for a visual pick.
            .contextMenu { tileMenu(t) }
            .highPriorityGesture(TapGesture().onEnded { onPick(t.id) })
            .highPriorityGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(ExposeView.rootSpace))
                    .onChanged { handleDragChange(t, tileWidth: w, $0) }
                    .onEnded { handleDragEnd(t, $0) }
            )
    }

    private func stagedBadge(_ text: String) -> some View {
        Text(text)
            .font(Typo.monoBold(9))
            .foregroundColor(chromeOnAccent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(chromeAccent))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
            .padding(5)
    }

    // The tile's image + app-tint accent, clipped to the rounded card.
    private func tileBody(_ t: Tile, w: CGFloat, h: CGFloat, shape: RoundedRectangle) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Color.white.opacity(0.04)
                if let img = t.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: w, height: h)
            .clipShape(shape)

            VStack(spacing: 0) {                                   // a light top edge, not an app colour
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                Spacer(minLength: 0)
            }
        }
        .frame(width: w, height: h)
        .clipShape(shape)
    }

    // Reports this tile's laid-out frame up to the panel for hand-split key dealing.
    private func frameReporter(_ id: UInt32) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: TileFramesKey.self,
                                   value: [id: g.frame(in: .named(ExposeView.surveySpace))])
        }
    }

    private func hintChip(_ t: Tile) -> some View {
        Text(t.hint.uppercased())
            .font(Typo.monoBold(11))
            .foregroundColor(ink)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(unifiedChrome ? Color(nsColor: HyperspaceChrome.ivory) : t.tint))
            .padding(5)
    }

    /// Window 1 is coral; the rest share one neutral grey, as on the HUD.
    private func slotTint(_ n: Int) -> Color {
        n == 1 ? HyperspaceChrome.accent : Color(nsColor: Lens.srgb(0x7d848b))
    }

    private func slotBadge(_ n: Int, _ tint: Color) -> some View {
        Text("\(n)")
            .font(unifiedChrome ? .system(size: 10, weight: .bold).monospacedDigit() : Typo.monoBold(11))
            .foregroundColor(unifiedChrome ? (n == 1 ? Color(nsColor: Lens.onAccent) : .white) : ink)
            .frame(width: unifiedChrome ? 18 : 20, height: unifiedChrome ? 18 : 20)
            .background(Circle().fill(tint))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
            .padding(5)
    }

    // The window title — inset is provided by the enclosing bottom-leading VStack
    // (which also carries any layer labels), so no outer padding here.
    private func titleLabel(_ t: Tile) -> some View {
        Text(t.title)
            .font(unifiedChrome ? Typo.caption(10) : Typo.mono(8))
            .foregroundColor(chromeText.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(chromeBacking(0.5)))
    }

    // Staged layer memberships as small on-brand pills along the tile's bottom — a
    // label, since layer membership is non-exclusive and never moves the window.
    private func layerTagRow(_ tags: [String]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(Typo.monoBold(8))
                    .foregroundColor(chromeOnAccent)
                    .lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Capsule().fill(chromeAccent))
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(Typo.monoBold(8)).foregroundColor(chromeAccent)
            }
        }
    }
}

// MARK: - Flow layout
//
// Wraps subviews left-to-right onto centered rows, and centers the whole block
// in its bounds. Used twice: clusters flow across the survey, tiles flow inside
// each cluster.

struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12
    var alignment: HorizontalAlignment = .center   // row packing: centered (default) or left/right
    var vAlign: VerticalAlignment = .center         // block placement within the bounds

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        let totalH = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        var y: CGFloat
        if vAlign == .top {
            y = bounds.minY
        } else if vAlign == .bottom {
            y = bounds.maxY - totalH
        } else {
            y = bounds.minY + max(0, (bounds.height - totalH) / 2)
        }
        for row in rows {
            var x: CGFloat
            if alignment == .leading {
                x = bounds.minX
            } else if alignment == .trailing {
                x = bounds.maxX - row.width
            } else {
                x = bounds.minX + max(0, (bounds.width - row.width) / 2)
            }
            for idx in row.indices {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            let projected = row.indices.isEmpty ? s.width : row.width + spacing + s.width
            if !row.indices.isEmpty && projected > maxWidth {
                rows.append(row)
                row = Row(indices: [i], width: s.width, height: s.height)
            } else {
                row.width = row.indices.isEmpty ? s.width : row.width + spacing + s.width
                row.indices.append(i)
                row.height = max(row.height, s.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

private extension Array {
    /// Bounds-checked access — nil instead of a crash for out-of-range indices.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
