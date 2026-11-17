import ActionCore
import AppKit
import ApplicationServices
import AVFoundation

/// A movable camera over the persistent display. One display point occupies one view
/// point; resizing reveals more desktop and never shrinks the applications.
@MainActor
final class ActionMonitorPreview: NSObject, ActionLayerPreview, NSWindowDelegate {
    let destinationDisplayID: CGDirectDisplayID
    let previewFull: Bool
    let previewViewport = true
    var hasOwner = false
    var onDismiss: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onTakeOver: (() -> Void)?
    var onGoToOwner: (() -> Void)?
    var onOperatorActivity: (() -> Void)?
    var onBorrowWindow: ((CGWindowID) -> String?)?
    var state: ActionAgentLayerLiveState = .live

    private let feed: ActionAgentLayerFeed
    private let logger: DebugLogger
    private let workspace: String
    private let destinationSerial: UInt32
    private let sourceSerial: UInt32
    private let returnRequestURL: URL
    private var panel: ActionMonitorPanel?
    private var surface: ActionMonitorSurface?
    private var screenObserver: NSObjectProtocol?
    private var inputLifetime = ActionMonitorInputLifetime()
    private static let inputQueue = DispatchQueue(label: "action.monitor.operator")

    init(feed: ActionAgentLayerFeed, startedAt: Date, logger: DebugLogger,
         destinationDisplayID: CGDirectDisplayID, noteURL: URL?, workspace: String, previewFull: Bool,
         returnRequestURL: URL) {
        self.feed = feed
        self.logger = logger
        self.destinationDisplayID = destinationDisplayID
        self.destinationSerial = CGDisplaySerialNumber(destinationDisplayID)
        self.sourceSerial = CGDisplaySerialNumber(feed.displayID)
        self.workspace = workspace
        self.previewFull = previewFull
        self.returnRequestURL = returnRequestURL
        super.init()
    }

    func start(expectsWindows: Bool, state: ActionAgentLayerLiveState) async throws {
        self.state = state
        inputLifetime = ActionMonitorInputLifetime()
        guard let screen = destinationScreen else {
            throw ActionHostError.unsupportedOS("The monitor viewer destination is unavailable")
        }
        let available = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let size = CGSize(width: min(1440, available.width), height: min(900, available.height - 28))
        let rect = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                          width: size.width, height: size.height)
        let panel = ActionMonitorPanel(contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Action · \(workspace) · Monitor"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = CGSize(width: 760, height: 420)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        let surface = ActionMonitorSurface(frame: CGRect(origin: .zero, size: size),
            displayID: feed.displayID, displayBounds: feed.displayBounds)
        surface.onActivity = { [weak self] in self?.onOperatorActivity?() }
        surface.onReturn = { [weak self] in self?.returnToMac() }
        surface.canvas.allowsInteraction = { [weak self] in
            guard let self else { return false }
            return self.inputLifetime.isActive && !FileManager.default.fileExists(atPath: self.returnRequestURL.path)
        }
        surface.onBorrow = { [weak self] id in self?.onBorrowWindow?(id) }
        surface.onInput = { [weak self] input in
            guard let self else { return }
            self.onOperatorActivity?()
            let origin = self.feed.displayBounds.origin
            let sourceID = self.feed.displayID
            let sourceBounds = self.feed.displayBounds
            let sourceSerial = self.sourceSerial
            let logger = self.logger
            let lifetime = self.inputLifetime
            let requestURL = self.returnRequestURL
            Self.inputQueue.async {
                guard lifetime.isActive, !FileManager.default.fileExists(atPath: requestURL.path) else { return }
                func global(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
                do {
                    guard CGDisplayIsOnline(sourceID) != 0,
                          CGDisplaySerialNumber(sourceID) == sourceSerial,
                          CGDisplayBounds(sourceID) == sourceBounds else {
                        throw ActionHostError.unsupportedOS("The virtual monitor changed. Reopen its viewer before interacting.")
                    }
                    let detail: String
                    switch input {
                    case .click(let point):
                        detail = try ActionBlinkInput.click(at: global(point), holdMs: 40,
                            accessibilityFirst: false, anyDisplay: false, pointerEventLogPath: nil, handBack: false)
                    case .drag(let start, let end, let duration):
                        detail = try ActionBlinkInput.drag(from: global(start), to: global(end), durationMs: duration,
                            anyDisplay: false, pointerEventLogPath: nil, handBack: false)
                    case .scroll(let point, let dx, let dy):
                        detail = try ActionBlinkInput.scroll(at: global(point), deltaX: dx, deltaY: dy,
                            durationMs: 16, anyDisplay: false)
                    }
                    logger.log("monitor: operator \(detail)")
                } catch {
                    logger.log("monitor: input failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        guard lifetime.isActive else { return }
                        self?.surface?.show(error.localizedDescription)
                    }
                }
            }
        }
        panel.contentView = surface
        self.panel = panel
        self.surface = surface
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        feed.attach(surface.canvas.videoLayer) { [weak self] in self?.panel?.orderFrontRegardless() }
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.destinationScreen == nil || CGDisplayIsOnline(self.feed.displayID) == 0
                    || CGDisplaySerialNumber(self.feed.displayID) != self.sourceSerial
                    || CGDisplayBounds(self.feed.displayID) != self.feed.displayBounds { self.dismiss() }
            }
        }
        logger.log("monitor: viewport up display=\(feed.displayID) bounds=\(feed.displayBounds) scale=1")
    }

    func stop(animated: Bool) {
        inputLifetime.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        surface?.invalidate()
        feed.detach()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        surface = nil
    }

    func mark(_ act: ActionAgentLayerAct) {
        guard let point = act.point else { return }
        surface?.canvas.mark(CGPoint(x: point.x - feed.displayBounds.minX, y: point.y - feed.displayBounds.minY))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { returnToMac(); return false }

    private func returnToMac() {
        inputLifetime.invalidate()
        surface?.beginReturn()
        onStop?()
    }

    func showReturnError(_ message: String) {
        surface?.show("Return to Mac could not start: \(message). Try the exit button again.")
    }

    private func dismiss() { stop(animated: false); onDismiss?() }

    private var destinationScreen: NSScreen? {
        guard destinationDisplayID != feed.displayID,
              CGDisplaySerialNumber(destinationDisplayID) == destinationSerial else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == destinationDisplayID
        }
    }
}

private final class ActionMonitorInputLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}

/// Keeping this panel out of the key-window chain lets real keyboard input follow
/// the application clicked on the virtual display, including its IME and shortcuts.
private final class ActionMonitorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ActionMonitorSurface: NSView {
    let canvas: ActionMonitorCanvas
    var onReturn: (() -> Void)?
    var onBorrow: ((CGWindowID) -> String?)?
    var onActivity: (() -> Void)?
    var onInput: ((ActionAgentLayerOperatorInput) -> Void)? {
        didSet { canvas.onInput = onInput }
    }
    private let back = NSButton(title: "←", target: nil, action: nil)
    private let forward = NSButton(title: "→", target: nil, action: nil)
    private let add = NSButton(title: "Add window…", target: nil, action: nil)
    private let restore = NSButton(title: "Return to Mac  ⌃⌥⌘ Esc", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "Virtual desktop")
    private let escapeHint = NSTextField(labelWithString: "⌃⌥⌘ Esc returns you home from any app")
    private var returning = false
    private let position = NSTextField(labelWithString: "100%")
    private let hint = NSTextField(labelWithString: "⌥ drag or scroll to pan · Click to type · Content drags complete on release")
    private let horizontal = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let vertical = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)

    init(frame: CGRect, displayID: CGDirectDisplayID, displayBounds: CGRect) {
        canvas = ActionMonitorCanvas(frame: .zero, displayID: displayID, displayBounds: displayBounds)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for view in [canvas, back, forward, add, restore, heading, escapeHint, position, hint, horizontal, vertical] { addSubview(view) }
        for button in [back, forward, add, restore] {
            button.bezelStyle = .rounded
            button.target = self
        }
        back.action = #selector(pageBack)
        forward.action = #selector(pageForward)
        add.action = #selector(addWindow)
        restore.action = #selector(returnWindows)
        back.toolTip = "Pan left by one viewport"
        forward.toolTip = "Pan right by one viewport"
        restore.toolTip = "Bring every window back to your Mac, then disconnect the virtual monitor"
        restore.bezelColor = .controlAccentColor
        restore.font = .systemFont(ofSize: 13, weight: .semibold)
        restore.setAccessibilityLabel("Return to Mac. Control Option Command Escape.")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        escapeHint.font = .systemFont(ofSize: 11)
        escapeHint.textColor = .secondaryLabelColor
        horizontal.target = self
        horizontal.action = #selector(sliderChanged)
        horizontal.isContinuous = true
        horizontal.setAccessibilityLabel("Horizontal camera position")
        vertical.target = self
        vertical.action = #selector(sliderChanged)
        vertical.isContinuous = true
        vertical.setAccessibilityLabel("Vertical camera position")
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        canvas.onChange = { [weak self] in self?.updateControls() }
        canvas.onActivity = { [weak self] in self?.onActivity?() }
        canvas.onNotice = { [weak self] text in self?.show(text) }
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let footer: CGFloat = 74
        let header: CGFloat = 56
        canvas.frame = CGRect(x: 0, y: footer, width: bounds.width, height: max(1, bounds.height - footer - header))
        heading.frame = CGRect(x: 14, y: bounds.height - 25, width: 250, height: 18)
        escapeHint.frame = CGRect(x: 14, y: bounds.height - 43, width: 360, height: 15)
        restore.frame = CGRect(x: bounds.width - 258, y: bounds.height - 44, width: 244, height: 34)
        back.frame = CGRect(x: 10, y: 39, width: 34, height: 26)
        forward.frame = CGRect(x: 47, y: 39, width: 34, height: 26)
        position.frame = CGRect(x: 92, y: 44, width: 180, height: 16)
        horizontal.frame = CGRect(x: 275, y: 42, width: max(60, bounds.width - 510), height: 20)
        vertical.frame = CGRect(x: bounds.width - 222, y: 42, width: 75, height: 20)
        add.frame = CGRect(x: bounds.width - 130, y: 39, width: 118, height: 26)
        hint.frame = CGRect(x: 12, y: 13, width: max(1, bounds.width - 24), height: 16)
        canvas.resizeCamera()
        updateControls()
    }

    func show(_ text: String) { hint.stringValue = text }

    func beginReturn() {
        returning = true
        canvas.invalidate()
        add.isEnabled = false
        updateControls()
        show("Returning all windows to your Mac…")
    }

    func invalidate() {
        onInput = nil
        onActivity = nil
        onBorrow = nil
        onReturn = nil
        canvas.invalidate()
    }

    private func updateControls() {
        let camera = canvas.camera
        horizontal.maxValue = max(1, camera.displaySize.width - camera.viewportSize.width)
        vertical.maxValue = max(1, camera.displaySize.height - camera.viewportSize.height)
        horizontal.doubleValue = camera.origin.x
        vertical.doubleValue = camera.origin.y
        horizontal.isEnabled = !returning && camera.displaySize.width > camera.viewportSize.width
        vertical.isEnabled = !returning && camera.displaySize.height > camera.viewportSize.height
        back.isEnabled = !returning && camera.origin.x > 0
        forward.isEnabled = !returning && camera.visibleRect.maxX < camera.displaySize.width
        position.stringValue = "100% · \(Int(camera.origin.x)), \(Int(camera.origin.y))"
    }

    @objc private func pageBack() { canvas.page(-1); onActivity?() }
    @objc private func pageForward() { canvas.page(1); onActivity?() }
    @objc private func returnWindows() { onReturn?() }
    @objc private func sliderChanged() {
        canvas.pan(CGPoint(x: horizontal.doubleValue - canvas.camera.origin.x, y: vertical.doubleValue - canvas.camera.origin.y))
        onActivity?()
    }

    @objc private func addWindow() {
        guard !returning, canvas.allowsInteraction() else { return }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { show("The window list is unavailable"); return }
        let menu = NSMenu()
        let physical = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  !ActionAgentLayerDisplay.isAgentLayer(id) else { return nil }
            return CGDisplayBounds(id)
        }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw), frame.width > 80, frame.height > 60,
                  physical.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  !canvas.displayBounds.intersects(frame) else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? "Application"
            let title = window[kCGWindowName as String] as? String ?? ""
            let item = NSMenuItem(title: title.isEmpty ? owner : "\(owner) — \(title)", action: #selector(borrowWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: id)
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No available windows on physical displays", action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: CGPoint(x: add.frame.minX, y: add.frame.minY), in: self)
    }

    @objc private func borrowWindow(_ item: NSMenuItem) {
        guard !returning, canvas.allowsInteraction() else { return }
        guard let id = (item.representedObject as? NSNumber)?.uint32Value, let onBorrow else { return }
        if let error = onBorrow(id) { show(error) }
        else { show("Window added · Click its preview to focus and type"); onActivity?() }
    }
}

@MainActor
private final class ActionMonitorCanvas: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    let displayBounds: CGRect
    private let displayID: CGDirectDisplayID
    private(set) var camera: ActionMonitorViewport
    var onInput: ((ActionAgentLayerOperatorInput) -> Void)?
    var onChange: (() -> Void)?
    var onActivity: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var allowsInteraction: () -> Bool = { true }
    private var press: (view: CGPoint, display: CGPoint, time: TimeInterval, pan: Bool)?
    private var movingWindow: ActionMonitorWindowMove?
    private var movedWindow = false
    private var lastPanPoint: CGPoint?
    private var markPoint: CGPoint?
    private let clickRing = CAShapeLayer()
    private var markClear: DispatchWorkItem?
    private var scrollDelta = CGVector.zero
    private var scrollPoint: CGPoint?
    private var scrollFlush: DispatchWorkItem?

    init(frame: CGRect, displayID: CGDirectDisplayID, displayBounds: CGRect) {
        self.displayBounds = displayBounds
        self.displayID = displayID
        self.camera = ActionMonitorViewport(displaySize: displayBounds.size, viewportSize: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        videoLayer.videoGravity = .resize
        layer?.addSublayer(videoLayer)
        clickRing.fillColor = nil
        clickRing.strokeColor = NSColor.controlAccentColor.cgColor
        clickRing.lineWidth = 2
        clickRing.zPosition = 1
        clickRing.isHidden = true
        layer?.addSublayer(clickRing)
        setAccessibilityLabel("Virtual monitor at one hundred percent. Option-drag to pan.")
    }

    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resizeCamera() {
        guard camera.viewportSize != bounds.size else { return }
        cancelGesture()
        camera.resize(viewportSize: bounds.size)
        drawCamera()
    }

    func pan(_ delta: CGPoint) { camera.pan(delta: delta); drawCamera(); onChange?() }
    func page(_ direction: Int) { camera.page(direction: direction); drawCamera(); onChange?() }

    private func drawCamera() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = CGRect(x: -camera.origin.x,
            y: bounds.height + camera.origin.y - displayBounds.height,
            width: displayBounds.width, height: displayBounds.height)
        CATransaction.commit()
        updateMark()
    }

    private func topDown(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        cancelGesture()
        guard allowsInteraction() else { return }
        let p = topDown(event)
        guard let destination = camera.displayPoint(forViewPoint: p) else { return }
        let isPan = event.modifierFlags.contains(.option)
        press = (p, destination, event.timestamp, isPan)
        lastPanPoint = p
        if !isPan {
            movingWindow = ActionMonitorWindowMove.at(
                CGPoint(x: displayBounds.minX + destination.x, y: displayBounds.minY + destination.y),
                within: displayBounds, displayID: displayID)
        }
        onActivity?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsInteraction() else { cancelGesture(); return }
        guard let start = press else { return }
        let p = topDown(event)
        if start.pan, let previous = lastPanPoint {
            pan(CGPoint(x: previous.x - p.x, y: previous.y - p.y))
            lastPanPoint = p
        } else if hypot(p.x - start.view.x, p.y - start.view.y) >= 4, let movingWindow {
            let delta = CGPoint(x: p.x - start.view.x, y: p.y - start.view.y)
            if movingWindow.move(by: delta) { movedWindow = true }
            else { onNotice?("This window cannot be moved through Accessibility") }
        }
        onActivity?()
    }

    override func mouseUp(with event: NSEvent) {
        guard allowsInteraction() else { cancelGesture(); return }
        guard let start = press else { return }
        let alreadyMoved = movedWindow
        // Release the exclusive input lease before queuing a normal blink click.
        cancelGesture()
        guard !start.pan, !alreadyMoved else { return }
        let p = topDown(event)
        let clamped = CGPoint(x: min(max(p.x, 0), camera.visibleRect.width - 0.01),
                              y: min(max(p.y, 0), camera.visibleRect.height - 0.01))
        guard let end = camera.displayPoint(forViewPoint: clamped) else { return }
        if hypot(p.x - start.view.x, p.y - start.view.y) < 4 {
            mark(end)
            onInput?(.click(end))
        } else {
            let ms = min(max(Int((event.timestamp - start.time) * 1000), 120), 900)
            onInput?(.drag(start.display, end, ms))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsInteraction() else { return }
        guard press == nil else { return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.option) {
            pan(CGPoint(x: -event.scrollingDeltaX * k, y: -event.scrollingDeltaY * k))
            onActivity?()
            return
        }
        guard let p = camera.displayPoint(forViewPoint: topDown(event)) else { return }
        scrollDelta.dx += event.scrollingDeltaX * k
        scrollDelta.dy += event.scrollingDeltaY * k
        scrollPoint = p
        guard scrollFlush == nil else { return }
        let flush = DispatchWorkItem { [weak self] in
            guard let self, self.allowsInteraction(), let p = self.scrollPoint else { return }
            let delta = self.scrollDelta
            self.scrollDelta = .zero
            self.scrollFlush = nil
            self.onInput?(.scroll(p, delta.dx, delta.dy))
        }
        scrollFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: flush)
    }

    func cancelGesture() {
        press = nil
        movingWindow = nil
        movedWindow = false
        lastPanPoint = nil
    }

    func invalidate() {
        cancelGesture()
        scrollFlush?.cancel()
        scrollFlush = nil
        scrollPoint = nil
        scrollDelta = .zero
        markClear?.cancel()
        markClear = nil
        markPoint = nil
        updateMark()
        onInput = nil
        onActivity = nil
        onChange = nil
        onNotice = nil
    }

    func mark(_ point: CGPoint) {
        markClear?.cancel()
        markPoint = point
        updateMark()
        let clear = DispatchWorkItem { [weak self] in self?.markPoint = nil; self?.updateMark() }
        markClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: clear)
    }

    private func updateMark() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clickRing.frame = bounds
        clickRing.isHidden = markPoint == nil
        if let p = markPoint {
            clickRing.path = CGPath(ellipseIn: CGRect(x: p.x - camera.origin.x - 9,
                y: bounds.height - p.y + camera.origin.y - 9, width: 18, height: 18), transform: nil)
        }
        CATransaction.commit()
    }
}

/// Only a non-control title region of a standard, movable AX window takes this
/// route. All content gestures keep their normal pointer semantics.
@MainActor
private final class ActionMonitorWindowMove {
    private let window: AXUIElement
    private let original: CGRect
    private let display: CGRect
    private let displayID: CGDirectDisplayID
    private let displaySerial: UInt32
    private let lease: ActionWorkspaceLock
    private var raised = false

    private init(window: AXUIElement, original: CGRect, display: CGRect,
                 displayID: CGDirectDisplayID, lease: ActionWorkspaceLock) {
        self.window = window
        self.original = original
        self.display = display
        self.displayID = displayID
        self.displaySerial = CGDisplaySerialNumber(displayID)
        self.lease = lease
    }

    static func at(_ point: CGPoint, within display: CGRect, displayID: CGDirectDisplayID) -> ActionMonitorWindowMove? {
        guard CGDisplayIsOnline(displayID) != 0, CGDisplayBounds(displayID) == display else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.05)
        let role = attribute(hit, kAXRoleAttribute) as? String
        guard role == kAXWindowRole || role == kAXStaticTextRole else { return nil }
        var candidate = hit
        for _ in 0..<5 {
            if attribute(candidate, kAXRoleAttribute) as? String == kAXWindowRole { break }
            guard let parent = attribute(candidate, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            candidate = parent as! AXUIElement
        }
        AXUIElementSetMessagingTimeout(candidate, 0.05)
        guard attribute(candidate, kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(candidate, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              (attribute(candidate, "AXFullScreen") as? NSNumber)?.boolValue != true,
              let positionValue = attribute(candidate, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(candidate, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let frame = CGRect(origin: origin, size: size)
        guard frame.width > 180, frame.height > 80, display.contains(CGPoint(x: frame.midX, y: frame.midY)),
              point.y >= frame.minY + 3, point.y < frame.minY + 28,
              point.x > frame.minX + 85, point.x < frame.maxX - 30 else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(candidate, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let lease = try? ActionWorkspaceLock(url: ActionLayerSafetyGate.defaultURL.deletingLastPathComponent().appendingPathComponent("native-input.lock")) else { return nil }
        return ActionMonitorWindowMove(window: candidate, original: frame, display: display,
            displayID: displayID, lease: lease)
    }

    func move(by delta: CGPoint) -> Bool {
        guard CGDisplayIsOnline(displayID) != 0, CGDisplaySerialNumber(displayID) == displaySerial,
              CGDisplayBounds(displayID) == display else { return false }
        if !raised {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            var pid: pid_t = 0
            if AXUIElementGetPid(window, &pid) == .success {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
            raised = true
        }
        var position = CGPoint(
            x: min(max(original.minX + delta.x, display.minX), display.maxX - min(original.width, display.width)),
            y: min(max(original.minY + delta.y, display.minY), display.maxY - min(original.height, display.height)))
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
