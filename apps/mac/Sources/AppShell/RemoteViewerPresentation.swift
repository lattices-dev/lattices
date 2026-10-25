import AppKit
import Combine

/// Local window chrome owns no stream geometry. Hover reveals the overlay;
/// only menus and keyboard navigation temporarily own keyboard input.
@MainActor
final class RemoteViewerPresentation: NSObject, ObservableObject {
    @Published private(set) var isFullScreen = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var localControlsActive = false
    weak var window: NSWindow?
    var localInteractionBegan: (() -> Void)?
    var remoteInteractionRequested: (() -> Void)?
    var remoteInputIsFirstResponder: (() -> Bool)?

    private var edgeHovered = false
    private var controlsHovered = false
    private var controlsFocused = false
    private var keyboardFocus = false
    private var trackingMenus = 0
    private var hideWork: DispatchWorkItem?
    private var inputMonitor: Any?
    private var lastKeyboardRoute: String?
    private var closed = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown {
                    let responder = self.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                    let route = "local=\(self.localControlsActive) responder=\(responder)"
                    if route != self.lastKeyboardRoute {
                        self.lastKeyboardRoute = route
                        DiagnosticLog.shared.info("RemoteKeyboard: window key routing \(route)")
                    }
                    if event.keyCode == 48 { self.noteKeyboardNavigation() }
                } else {
                    self.notePointerInteraction()
                }
                return event
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    func setFullScreen(_ fullScreen: Bool) {
        guard !closed else { return }
        hideWork?.cancel()
        isFullScreen = fullScreen
        edgeHovered = false
        controlsHovered = false
        controlsFocused = false
        keyboardFocus = false
        controlsVisible = !fullScreen
        updateInteraction()
    }

    func toggleFullScreen() {
        localInteractionBegan?()
        window?.toggleFullScreen(nil)
    }

    func close() {
        guard !closed else { return }
        localInteractionBegan?()
        window?.performClose(nil)
    }

    func setEdgeHovered(_ hovered: Bool) {
        // A remote drag must keep its mouse-up even when it reaches the top.
        guard !hovered || NSEvent.pressedMouseButtons == 0 else { return }
        edgeHovered = hovered
        updateInteraction()
    }

    func setControlsHovered(_ hovered: Bool) {
        controlsHovered = hovered
        updateInteraction()
    }

    func setControlsFocused(_ focused: Bool) {
        controlsFocused = focused
        if !focused { keyboardFocus = false }
        updateInteraction()
    }

    func noteKeyboardNavigation() {
        // Tab belongs to the remote app while its input surface has focus.
        // A stale SwiftUI focus binding must not turn it into toolbar navigation.
        guard remoteInputIsFirstResponder?() != true else { return }
        keyboardFocus = true
        updateInteraction()
    }

    /// An explicit Control/Keyboard action or picture click returns keyboard
    /// ownership to the remote surface, even while local chrome stays revealed.
    func requestRemoteInput() {
        guard !closed else { return }
        let wasLocal = localControlsActive
        controlsFocused = false
        keyboardFocus = false
        updateInteraction()
        // Ending local ownership already requests this handoff. If a menu is
        // still tracking, its dismissal will request it instead.
        if !wasLocal && !localControlsActive { remoteInteractionRequested?() }
    }

    func notePointerInteraction() {
        keyboardFocus = false
        updateInteraction()
    }

    func setMenuTracking(_ tracking: Bool) {
        trackingMenus = max(0, trackingMenus + (tracking ? 1 : -1))
        updateInteraction()
    }

    @objc private func menuBegan() {
        guard window?.isKeyWindow == true else { return }
        setMenuTracking(true)
    }

    @objc private func menuEnded() {
        guard trackingMenus > 0 else { return }
        setMenuTracking(false)
    }

    private func updateInteraction() {
        guard !closed else { return }
        let active = (controlsFocused && keyboardFocus) || trackingMenus > 0
        if active != localControlsActive {
            localControlsActive = active
            DiagnosticLog.shared.info("RemoteKeyboard: local ownership=\(active) hover=\(controlsHovered) keyboardFocus=\(keyboardFocus) menus=\(trackingMenus)")
            if active { localInteractionBegan?() }
            else { remoteInteractionRequested?() }
        }
        hideWork?.cancel()
        hideWork = nil
        if !isFullScreen || edgeHovered || controlsHovered || active {
            controlsVisible = true
        } else {
            let work = DispatchWorkItem { [weak self] in self?.hideControlsIfIdle() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Recheck ownership when the delayed hide runs: a menu or keyboard focus
    /// may have taken over since the pointer left the controls.
    func hideControlsIfIdle() {
        guard !closed, isFullScreen, !edgeHovered, !controlsHovered, !localControlsActive else { return }
        controlsVisible = false
    }

    func invalidate() {
        closed = true
        hideWork?.cancel()
        hideWork = nil
        localInteractionBegan = nil
        remoteInteractionRequested = nil
        remoteInputIsFirstResponder = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }
}
