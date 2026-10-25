import AppKit
import CoreGraphics

/// A grid where the window you are in takes the stage.
///
/// The mode is on or off. How many windows are on this display decides the
/// grid, including one window and including none. A window that shows up
/// while the mode is on joins the grid. A window that leaves goes back to
/// where it was when it joined. Escape, or toggling the mode, puts every
/// window back.
final class StageModeController {
    static let shared = StageModeController()

    private struct Member {
        let wid: UInt32
        let pid: Int32
        let original: CGRect
    }

    private var active = false
    private var stageScreen: NSScreen?
    private var members: [Member] = []
    private var engaged: UInt32?
    private var applying = false
    private var quietUntil = Date.distantPast
    private var watchTimer: Timer?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var indicator: StageIndicatorPanel?

    private init() {}

    var isActive: Bool { active }

    var memberCount: Int { members.count }

    func toggle() {
        isActive ? exit() : enter()
    }

    func enter() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !active else { return }
        let visible = DesktopModel.shared.allWindows().filter(Self.isStageWindow)
        stageScreen = screenForStage(visible)
        active = true
        installKeyTap()
        showIndicator()
        refresh(raise: true)
        startWatching()
        DiagnosticLog.shared.success("Stage: on, \(members.count) windows")
    }

    func exit() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active else { return }
        let restore = members.map { (wid: $0.wid, pid: $0.pid, frame: $0.original) }
        active = false
        stageScreen = nil
        members = []
        engaged = nil
        stopWatching()
        removeKeyTap()
        hideIndicator()
        WindowTiler.batchMoveWindows(restore)
        DiagnosticLog.shared.info("Stage: exited")
    }

    func resetForTermination() {
        guard active else { return }
        let restore = members.map { (wid: $0.wid, pid: $0.pid, frame: $0.original) }
        active = false
        stageScreen = nil
        members = []
        engaged = nil
        stopWatching()
        removeKeyTap()
        hideIndicator()
        WindowTiler.batchMoveWindows(restore)
    }

    /// Move the stage to the next or previous window in the set.
    func cycle(by delta: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive, !members.isEmpty, delta != 0 else { return }
        let current = members.firstIndex { $0.wid == engaged } ?? 0
        let count = members.count
        let next = (current + delta % count + count) % count
        apply(active: next, raise: true)
    }

    // MARK: - Layout

    private func apply(active index: Int, raise: Bool) {
        guard members.indices.contains(index) else { return }
        guard let screen = stageScreen else { return }
        let boxes = StageLayout.frames(count: members.count, active: index)
        let moves = zip(members, boxes).map { member, box in
            (
                wid: member.wid,
                pid: member.pid,
                frame: WindowTiler.tileFrame(
                    fractions: (box.minX, box.minY, box.width, box.height),
                    on: screen
                )
            )
        }
        applying = true
        quietUntil = Date().addingTimeInterval(raise ? 0.85 : 0.35)
        WindowTiler.batchMoveWindows(moves)
        engaged = members[index].wid
        if raise {
            let member = members[index]
            WindowTiler.focusWindow(wid: member.wid, pid: member.pid)
        }
        applying = false
    }

    /// The display the focused window is on, or the main display.
    private func screenForStage(_ windows: [WindowEntry]) -> NSScreen? {
        if let focus = focusedWindowID(),
           let focused = windows.first(where: { $0.wid == focus }) {
            return WindowTiler.screenForWindowFrame(focused.frame)
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Membership

    /// Pull the current windows on the stage display into the grid. Windows
    /// already in the set keep their place and the frame they had on joining.
    /// New windows are appended. Windows that left are put back.
    private func refresh(raise: Bool) {
        guard active, let screen = stageScreen else { return }
        let found = windows(on: screen)
        var next: [Member] = []
        var kept = Set<UInt32>()
        for member in members {
            guard let entry = found.first(where: { $0.wid == member.wid }) else { continue }
            next.append(Member(wid: member.wid, pid: entry.pid, original: member.original))
            kept.insert(member.wid)
        }
        let departed = members.filter { !kept.contains($0.wid) }
        for entry in found where !kept.contains(entry.wid) {
            next.append(Member(
                wid: entry.wid,
                pid: entry.pid,
                original: CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h)
            ))
        }
        let membershipChanged = next.map(\.wid) != members.map(\.wid)
        if !departed.isEmpty {
            WindowTiler.batchMoveWindows(departed.map { (wid: $0.wid, pid: $0.pid, frame: $0.original) })
        }
        members = next
        guard !members.isEmpty else {
            engaged = nil
            return
        }
        let index = preferredIndex()
        if membershipChanged || members[index].wid != engaged || raise {
            apply(active: index, raise: raise)
        }
    }

    private func preferredIndex() -> Int {
        if let focus = focusedWindowID(),
           let index = members.firstIndex(where: { $0.wid == focus }) {
            return index
        }
        if let engaged, let index = members.firstIndex(where: { $0.wid == engaged }) {
            return index
        }
        return 0
    }

    private func windows(on screen: NSScreen) -> [WindowEntry] {
        let bounds = screen.frame.insetBy(dx: -8, dy: -8)
        return DesktopModel.shared.allWindows()
            .filter(Self.isStageWindow)
            .filter { bounds.contains(appKitCenter($0.frame)) }
            .sorted { lhs, rhs in
                let a = appKitCenter(lhs.frame)
                let b = appKitCenter(rhs.frame)
                if abs(a.y - b.y) > 80 { return a.y > b.y }
                return a.x < b.x
            }
    }

    private static func isStageWindow(_ entry: WindowEntry) -> Bool {
        entry.isOnScreen
            && !entry.appHidden
            && entry.pid != getpid()
            && entry.hasTitle
            && entry.frame.w >= 200
            && entry.frame.h >= 160
    }

    private func appKitCenter(_ frame: WindowFrame) -> CGPoint {
        appKitCenter(CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h))
    }

    private func appKitCenter(_ frame: CGRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
    }

    // MARK: - Focus follow

    private func startWatching() {
        stopWatching()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func tick() {
        guard active, !applying, Date() >= quietUntil else { return }
        refresh(raise: false)
    }

    private func focusedWindowID() -> UInt32? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !LatticesRuntime.isLatticesBundleIdentifier(application.bundleIdentifier) else {
            return nil
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focused as! AXUIElement, &wid) == .success, wid != 0 else { return nil }
        return UInt32(wid)
    }

    // MARK: - Keys

    private func installKeyTap() {
        removeKeyTap()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.keyTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            DiagnosticLog.shared.warn("Stage: could not watch Escape and Tab")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyTap = tap
        keyTapSource = source
        if let source { EventTapThread.overlay.add(source: source) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeKeyTap() {
        if let source = keyTapSource {
            EventTapThread.overlay.remove(source: source)
        }
        keyTapSource = nil
        if let tap = keyTap { CFMachPortInvalidate(tap) }
        keyTap = nil
    }

    private static let keyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<StageModeController>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = controller.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)
        if key == 53 {
            DispatchQueue.main.async { controller.exit() }
            return nil
        }
        // ⌃⌥⇥ moves through the set. Plain Tab still reaches the focused app.
        if key == 48, control, option {
            let delta = shift ? -1 : 1
            DispatchQueue.main.async { controller.cycle(by: delta) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func showIndicator() {
        guard let screen = stageScreen else { return }
        let panel = indicator ?? StageIndicatorPanel()
        indicator = panel
        panel.place(on: screen)
        panel.orderFrontRegardless()
    }

    private func hideIndicator() {
        indicator?.orderOut(nil)
        indicator = nil
    }
}

/// A small mark at the top of the stage display while Stage is on. It takes
/// no clicks and never becomes key, so it can't pull focus off the stage.
private final class StageIndicatorPanel: NSPanel {
    private let mark = StageIndicatorView(frame: NSRect(origin: .zero, size: StageIndicatorView.fittingSize))

    init() {
        super.init(
            contentRect: mark.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = mark
    }

    /// Top centre, just under the menu bar, or under the top edge when the
    /// menu bar hides. Above `.mainMenu`, so a revealed menu bar can't cover it.
    func place(on screen: NSScreen) {
        let size = mark.frame.size
        let visible = screen.visibleFrame
        let frame = CGRect(
            x: round(visible.midX - size.width / 2),
            y: round(visible.maxY - size.height - 6),
            width: size.width,
            height: size.height
        )
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StageIndicatorView: NSView {
    private static let height: CGFloat = 24
    private static let pad: CGFloat = 11
    private static let dot: CGFloat = 6
    private static let gap: CGFloat = 7
    private static let label = NSAttributedString(
        string: "Stage",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
    )

    static var fittingSize: CGSize {
        CGSize(width: ceil(pad + dot + gap + label.size().width + pad), height: height)
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        NSColor(srgbRed: 16 / 255, green: 21 / 255, blue: 24 / 255, alpha: 0.86).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        // Coral marks a live mode, as in the other marks.
        let dotY = round((bounds.height - Self.dot) / 2)
        LatticesPointer.coral.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.pad, y: dotY, width: Self.dot, height: Self.dot)).fill()

        let text = Self.label.size()
        Self.label.draw(at: NSPoint(x: Self.pad + Self.dot + Self.gap, y: round((bounds.height - text.height) / 2)))
    }
}
