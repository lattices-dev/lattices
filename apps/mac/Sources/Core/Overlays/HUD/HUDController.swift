import AppKit
import Combine
import SwiftUI

// MARK: - KeyableHUDPanel

private class KeyableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Suppress NSBeep — our local event monitor handles all keys
    override func keyDown(with event: NSEvent) {
        // Don't call super — that's what triggers the system bonk sound
    }

    /// Allow performKeyEquivalent to pass through for event monitor
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

// MARK: - HUDController (singleton, cockpit-style HUD)
//
// Speed strategy:
//   1. Panels are pre-built at launch with content already rendered
//   2. Panels stay ordered (never orderOut on dismiss — just alpha=0)
//   3. Show = synchronous alphaValue=1 + makeKey (zero animation, instant paint)
//   4. Data refresh happens AFTER first paint
//   5. Dismiss = short slide-out animation (non-blocking, delightful)

final class HUDController {
    static let shared = HUDController()

    private var topPanel: NSPanel?
    private var bottomPanel: NSPanel?
    private var leftPanel: NSPanel?
    private var rightPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var minimapPanels: [NSPanel] = []
    private let hintBezels = HUDWindowHintBezels()
    private let liveTabChromes = HUDLiveTabChromes()
    private var windowHintObserver: AnyCancellable?
    private var liveTabObserver: AnyCancellable?
    private var liveTabGeometryObserver: AnyCancellable?
    private var pendingLiveTabGeometryRefresh: DispatchWorkItem?
    private var liveTabFocusObserver: AnyCancellable?
    private var focusedWindowObserver: AnyCancellable?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var mouseMovedMonitor: Any?
    private var minimapObserver: AnyCancellable?
    private var sidebarWidthObserver: AnyCancellable?
    private var selectionObserver: AnyCancellable?
    private var previewObserver: AnyCancellable?
    private var previewImageObserver: AnyCancellable?
    private var experienceObserver: AnyCancellable?
    private var panelMoveObservers: [Any] = []
    private var lastMouseUpdate: Date = .distantPast
    private var suppressOutsideDismissUntil: Date = .distantPast
    private let state = HUDState()
    private let previewModel = WindowPreviewStore.shared

    private let topHeight: CGFloat = 44
    private let bottomHeight: CGFloat = 48
    private let rightWidth: CGFloat = 400
    private let previewWidth: CGFloat = 380
    private let previewHeight: CGFloat = 240
    private let previewGap: CGFloat = 14
    private let expandedMapWidth: CGFloat = 380
    private let expandedMapHeight: CGFloat = 240

    private var leftWidth: CGFloat { state.leftSidebarWidth }

    /// Track which screen panels are positioned on (for multi-monitor repositioning)
    private var positionedScreen: NSScreen?
    private var previewSettledItemID: String?
    private var previewSettledAnchorScreenY: CGFloat?

    var isVisible: Bool { leftPanel?.alphaValue ?? 0 > 0.5 }
    private(set) var voiceBarVisible: Bool = false
    private var voiceBarObserver: AnyCancellable?

    func toggle() {
        if isVisible { dismiss() } else { show() }
    }

    // MARK: - Voice bar (top panel only, for HandsOff mode)

    private var voiceBarKeyMonitor: Any?

    func showVoiceBar() {
        guard !isVisible else { return } // full HUD is showing, no need
        ensurePanels()

        state.voiceActive = true

        let screen = mouseScreen()
        if positionedScreen != screen { positionAllPanels(on: screen) }

        // Show only top + bottom bars
        topPanel?.alphaValue = 1
        topPanel?.orderFront(nil)
        bottomPanel?.alphaValue = 1
        bottomPanel?.orderFront(nil)
        voiceBarVisible = true

        // Escape key dismisses the voice bar
        if voiceBarKeyMonitor == nil {
            voiceBarKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape
                    DispatchQueue.main.async { self?.hideVoiceBar() }
                }
            }
        }

        // Auto-hide 3s after HandsOff goes idle (turn complete)
        voiceBarObserver = HandsOffSession.shared.$state.sink { [weak self] hsState in
            if hsState == .idle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard let self, self.voiceBarVisible,
                          HandsOffSession.shared.state == .idle else { return }
                    self.hideVoiceBar()
                }
            }
        }
    }

    func hideVoiceBar() {
        guard voiceBarVisible else { return }
        voiceBarObserver = nil
        if let m = voiceBarKeyMonitor { NSEvent.removeMonitor(m); voiceBarKeyMonitor = nil }
        state.voiceActive = false
        voiceBarVisible = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            topPanel?.animator().alphaValue = 0
            bottomPanel?.animator().alphaValue = 0
        })
    }

    // MARK: - Warm up (call at launch)

    func warmUp() {
        ensurePanels()

        let screen = NSScreen.main ?? NSScreen.screens.first!
        positionAllPanels(on: screen)

        // Order into window server at alpha 0 — instant show later
        for p in allPanels {
            p.orderFrontRegardless()
            p.alphaValue = 0
            p.ignoresMouseEvents = true
        }
    }

    // MARK: - Show (instant first paint)

    func show() {
        ensurePanels()

        state.query = ""
        state.selectedIndex = 0
        state.selectedItem = nil
        state.pinnedItem = nil
        state.hoveredPreviewItem = nil
        state.hoverPreviewAnchorScreenY = nil
        state.previewInteractionActive = false
        state.selectedItems = []
        state.focus = .list
        previewSettledItemID = nil
        previewSettledAnchorScreenY = nil
        state.resetSectionDefaults(hasRunningProjects: ProjectScanner.shared.projects.contains(where: \.isRunning))

        let screen = mouseScreen()
        if positionedScreen != screen { positionAllPanels(on: screen) }

        // Pre-compute tile grid BEFORE showing panels (captures real z-order)
        DesktopModel.shared.poll()
        precomputeTileGrid(on: screen)
        prewarmLikelyPreviews()
        // ── INSTANT SHOW ── alphaValue flip, zero animation
        let isExpanded = state.minimapMode == .expanded
        let showChrome = HUDExperienceStore.shared.showChrome
        topPanel?.alphaValue = showChrome ? 1 : 0
        topPanel?.ignoresMouseEvents = !showChrome
        bottomPanel?.alphaValue = showChrome ? 1 : 0
        bottomPanel?.ignoresMouseEvents = !showChrome
        leftPanel?.alphaValue = 1
        leftPanel?.ignoresMouseEvents = false
        updateRightPanelVisibility(animated: false)
        updatePreviewPanelVisibility(animated: false)
        if isExpanded {
            for panel in minimapPanels {
                panel.alphaValue = 1
                panel.ignoresMouseEvents = false
            }
        } else {
            for panel in minimapPanels {
                panel.ignoresMouseEvents = true
            }
        }
        leftPanel?.makeKey()

        installMonitors()
        applyExperienceToAllPanels()
        refreshHintBezels()
        refreshLiveTabChromes()
        // Window managers may report the old bounds for a few frames after the
        // native apps make room for the rail. Re-anchor the composite once the
        // content rect has settled so its outer frame never jumps on selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard self?.isVisible == true else { return }
            DesktopModel.shared.forcePoll()
            self?.refreshLiveTabChromes()
        }

        let xp = HUDExperienceStore.shared
        if xp.has(.mouseSpecular) || xp.has(.meshLight) {
            installMouseMovedMonitor()
        }
        if xp.has(.liveCapture) {
            captureDesktop()
        }

        DispatchQueue.main.async { ProjectScanner.shared.scan() }
    }

    // MARK: - Dismiss (animated, delightful)

    func dismiss() {
        guard isVisible else { return }
        removeMonitors()
        removeMouseMovedMonitor()
        hintBezels.setRevealed(false)
        // Live tab groups are persistent composite windows. Dismissing Hyper-3
        // removes only the HUD; their enclosure and reserved rail stay put.
        refreshLiveTabChromes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshLiveTabChromes()
        }

        // Restore untiled windows only if user actually tiled something
        if !state.tiledWindows.isEmpty {
            restoreUntiled()
        } else {
            state.tileSnapshot = []
            state.tileMode = false
        }

        if state.voiceActive {
            if HandsOffSession.shared.state == .listening { HandsOffSession.shared.toggle() }
            state.voiceActive = false
        }

        let xp = HUDExperienceStore.shared
        let sf = (positionedScreen ?? mouseScreen()).visibleFrame

        let isAmbient = xp.has(.ambientPresence) && xp.currentPreset.ambientOpacity > 0
        if isAmbient || !xp.showChrome {
            // Floating sidebar or ambient — simple fade, no slide-out
            let targetAlpha = isAmbient ? xp.currentPreset.ambientOpacity : 0.0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                for p in self.allPanels { p.animator().alphaValue = targetAlpha }
            }
            for p in allPanels { p.ignoresMouseEvents = true }
        } else {
            // Chrome layout — original slide-out animation
            NSAnimationContext.runAnimationGroup({ [weak self] ctx in
                guard let self else { return }
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                let sideHeight = max(0, sf.height - topHeight - bottomHeight)

                topPanel?.animator().setFrame(
                    NSRect(x: sf.minX, y: sf.maxY,
                           width: sf.width, height: topHeight), display: false)
                bottomPanel?.animator().setFrame(
                    NSRect(x: sf.minX, y: sf.minY - bottomHeight,
                           width: sf.width, height: bottomHeight), display: false)
                leftPanel?.animator().setFrame(
                    NSRect(x: sf.minX - leftWidth * 0.3, y: sf.minY + bottomHeight,
                           width: leftWidth, height: sideHeight), display: false)
                rightPanel?.animator().setFrame(
                    NSRect(x: sf.maxX + rightWidth * 0.3 - rightWidth, y: sf.minY + bottomHeight,
                           width: rightWidth, height: sideHeight), display: false)
                for p in allPanels { p.animator().alphaValue = 0 }
            }) { [weak self] in
                guard let self, let screen = self.positionedScreen else { return }
                self.positionAllPanels(on: screen)
                for panel in self.allPanels { panel.ignoresMouseEvents = true }
            }
        }
    }

    // MARK: - Position panels on screen

    private var allPanels: [NSPanel] {
        [topPanel, bottomPanel, leftPanel, rightPanel, previewPanel].compactMap { $0 } + minimapPanels
    }

    private func positionAllPanels(on screen: NSScreen) {
        let sf = screen.visibleFrame
        let sideHeight = max(0, sf.height - topHeight - bottomHeight)
        let isFreeform = HUDExperienceStore.shared.has(.freeformWidgets)
        let wps = WidgetPositionStore.shared

        func place(_ panel: NSPanel?, widget: WidgetPositionStore.Widget, default defaultFrame: NSRect) {
            guard let panel else { return }
            let frame = isFreeform ? (wps.position(for: widget, on: screen) ?? defaultFrame) : defaultFrame
            panel.setFrame(frame, display: false)
        }

        place(topPanel,    widget: .top,    default: NSRect(x: sf.minX, y: sf.maxY - topHeight, width: sf.width, height: topHeight))
        place(bottomPanel, widget: .bottom, default: NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: bottomHeight))

        let showChrome = HUDExperienceStore.shared.showChrome
        if showChrome {
            place(leftPanel,  widget: .left,  default: NSRect(x: sf.minX, y: sf.minY + bottomHeight, width: leftWidth, height: sideHeight))
            place(rightPanel, widget: .right, default: NSRect(x: sf.maxX - rightWidth, y: sf.minY + bottomHeight, width: rightWidth, height: sideHeight))
        } else {
            let inset:  CGFloat = 10
            let vInset: CGFloat = 12
            let floatH  = sf.height - vInset * 2
            place(leftPanel,  widget: .left,  default: NSRect(x: sf.minX + inset, y: sf.minY + vInset, width: leftWidth, height: floatH))
            place(rightPanel, widget: .right, default: NSRect(x: sf.minX + inset + leftWidth + 10, y: sf.minY + vInset, width: rightWidth, height: floatH))
        }
        if let previewPanel,
           let frame = previewFrame(on: screen, itemID: previewSettledItemID ?? state.transientPreviewItem?.id) {
            previewPanel.setFrame(frame, display: false)
        }
        positionMinimapPanels()
        positionedScreen = screen
        refreshHintBezels()
        refreshLiveTabChromes()
    }

    private func buildMinimapPanels(dismiss: @escaping () -> Void) {
        minimapPanels.forEach { $0.orderOut(nil) }
        minimapPanels.removeAll()

        for i in 0..<NSScreen.screens.count {
            let mp = makePanel()
            let hosting = NSHostingView(rootView:
                HUDMinimap(state: state, onDismiss: dismiss, screenIndex: i).preferredColorScheme(.dark))
            hosting.sizingOptions = []
            mp.contentView = hosting
            mp.alphaValue = 0
            minimapPanels.append(mp)
        }
    }

    private func positionMinimapPanels() {
        let screens = NSScreen.screens
        let hudScreen = positionedScreen ?? screens.first!

        for (i, mp) in minimapPanels.enumerated() {
            guard i < screens.count else { continue }
            let screen = screens[i]
            let sf = screen.visibleFrame

            if screen == hudScreen {
                // On HUD screen: attach to left bar + bottom bar corner
                mp.setFrame(NSRect(
                    x: sf.minX + leftWidth,
                    y: sf.minY + bottomHeight,
                    width: expandedMapWidth,
                    height: expandedMapHeight
                ), display: false)
            } else {
                // On other screens: bottom-left corner
                mp.setFrame(NSRect(
                    x: sf.minX + 12,
                    y: sf.minY + 12,
                    width: expandedMapWidth,
                    height: expandedMapHeight
                ), display: false)
            }
        }
    }

    // MARK: - Build panels (once)

    private func ensurePanels() -> Void {
        guard topPanel == nil else { return }
        let dismiss: () -> Void = { [weak self] in self?.dismiss() }

        let tp = makePanel()
        let tpHosting = NSHostingView(rootView:
            HUDTopBar(state: state, onDismiss: dismiss).preferredColorScheme(.dark))
        tpHosting.sizingOptions = []
        tp.contentView = tpHosting

        let bp = makePanel()
        let bpHosting = NSHostingView(rootView:
            HUDBottomBar(state: state, onDismiss: dismiss).preferredColorScheme(.dark))
        bpHosting.sizingOptions = []
        bp.contentView = bpHosting

        let lp = makePanel(keyable: true)
        let lpHosting = NSHostingView(rootView:
            HUDLeftBar(state: state, onDismiss: dismiss).preferredColorScheme(.dark))
        lpHosting.sizingOptions = []
        lp.contentView = lpHosting

        let rp = makePanel()
        let rpHosting = NSHostingView(rootView:
            HUDRightBar(state: state, onDismiss: dismiss).preferredColorScheme(.dark))
        rpHosting.sizingOptions = []
        rp.contentView = rpHosting

        let pp = makePanel()
        pp.hasShadow = true
        pp.isMovableByWindowBackground = true
        pp.contentMinSize = NSSize(width: previewWidth, height: previewHeight)
        pp.contentMaxSize = NSSize(width: previewWidth, height: previewHeight)
        let ppHosting = NSHostingView(rootView:
            HUDHoverPreviewView(state: state)
                .frame(width: previewWidth, height: previewHeight)
                .preferredColorScheme(.dark))
        ppHosting.sizingOptions = []
        pp.contentView = ppHosting

        self.topPanel = tp
        self.bottomPanel = bp
        self.leftPanel = lp
        self.rightPanel = rp
        self.previewPanel = pp

        // Create one minimap panel per screen
        buildMinimapPanels(dismiss: dismiss)

        // Observe minimap mode changes to show/hide expanded panels
        minimapObserver = state.$minimapMode.sink { [weak self] mode in
            guard let self else { return }
            if mode == .expanded {
                self.positionMinimapPanels()
                for mp in self.minimapPanels {
                    mp.alphaValue = 1
                    mp.orderFront(nil)
                }
            } else {
                for mp in self.minimapPanels { mp.alphaValue = 0 }
            }
        }

        sidebarWidthObserver = state.$leftSidebarWidth
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let screen = self.positionedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
                self.positionAllPanels(on: screen)
            }

        selectionObserver = state.$pinnedItem
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRightPanelVisibility(animated: true)
            }

        previewObserver = Publishers.CombineLatest4(
            state.$hoveredPreviewItem
                .map { $0?.id }
                .removeDuplicates(),
            state.$pinnedItem
                .map { $0?.id }
                .removeDuplicates(),
            state.$selectedItem
                .map { $0?.id }
                .removeDuplicates(),
            state.$focus
                .removeDuplicates()
        )
        .sink { [weak self] _, _, _, _ in
            DispatchQueue.main.async {
                self?.updatePreviewPanelVisibility(animated: true)
            }
        }

        previewImageObserver = previewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updatePreviewPanelVisibility(animated: true)
                }
            }

        // A grouped app may need a synthetic click to become key. Treat that
        // click as part of the tab action instead of as a click outside HUD.
        liveTabFocusObserver = NotificationCenter.default.publisher(for: .liveTabGroupWillFocusWindow)
            .sink { [weak self] _ in
                // AX/AppleScript focus can synthesize its click noticeably after
                // the request on a busy desktop. Keep that owned click from
                // dismissing the stable composite during a tab swap.
                self?.suppressOutsideDismissUntil = Date().addingTimeInterval(3.0)
            }

        // If the user focuses a grouped app directly, reflect the real window
        // on top so the selected tab never lies about what is being shown.
        focusedWindowObserver = DesktopModel.shared.$focusedWindowID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windowID in
                LiveTabGroupStore.shared.syncSelection(toFocusedWindow: windowID)
                self?.refreshLiveTabChromes()
            }

        // Rebuild on-window jump badges whenever the hint assignment changes
        windowHintObserver = state.$windowHints
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHintBezels() }

        // Live stacks can be edited from Hyperspace, the HUD, the CLI, or an
        // agent. Keep their spatial chrome in sync regardless of entry point.
        liveTabObserver = LiveTabGroupStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshLiveTabChromes() }
            }

        // Native layout changes settle asynchronously in some apps. Coalesce
        // their follow-up inventory/positioning into one refresh; selection-only
        // tab swaps intentionally stay on the immediate path above.
        liveTabGeometryObserver = NotificationCenter.default.publisher(for: .liveTabGroupGeometryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pendingLiveTabGeometryRefresh?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    DesktopModel.shared.forcePoll()
                    self?.refreshLiveTabChromes()
                }
                self.pendingLiveTabGeometryRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }

        // Re-apply experience settings when preset changes
        experienceObserver = HUDExperienceStore.shared.$presetIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyExperienceToAllPanels() }

        // Save panel positions while dragged in freeform mode
        let panels: [(NSPanel?, WidgetPositionStore.Widget)] = [
            (tp, .top), (bp, .bottom), (lp, .left), (rp, .right)
        ]
        for (panel, widget) in panels {
            guard let panel else { continue }
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self, weak panel] _ in
                guard let self, let panel,
                      HUDExperienceStore.shared.has(.freeformWidgets),
                      let screen = panel.screen ?? self.positionedScreen else { return }
                WidgetPositionStore.shared.save(position: panel.frame, for: widget, on: screen)
            }
            panelMoveObservers.append(obs)
        }
        // Preview panel snaps back to sidebar on next hover via updatePreviewPanelVisibility.

        // Preview panel snaps back to sidebar on next hover via updatePreviewPanelVisibility —
        // no didMoveNotification observer needed (fires at 60fps during animations).
    }

    private func updateRightPanelVisibility(animated: Bool) {
        guard let rightPanel else { return }
        let shouldShow = isVisible && state.pinnedItem != nil
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        rightPanel.ignoresMouseEvents = !shouldShow

        guard rightPanel.alphaValue != targetAlpha else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rightPanel.animator().alphaValue = targetAlpha
            }
        } else {
            rightPanel.alphaValue = targetAlpha
        }
    }

    private func updatePreviewPanelVisibility(animated: Bool) {
        guard let previewPanel else { return }
        let targetItem = state.transientPreviewItem
        let motionItem = commitPreviewMotionTarget(from: targetItem)

        if let screen = positionedScreen ?? NSScreen.main ?? NSScreen.screens.first,
           let frame = previewFrame(on: screen, itemID: motionItem?.id) {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    previewPanel.animator().setFrame(frame, display: false)
                }
            } else {
                previewPanel.setFrame(frame, display: false)
            }
        }
        let shouldShow = isVisible && motionItem != nil
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        previewPanel.ignoresMouseEvents = !shouldShow

        guard previewPanel.alphaValue != targetAlpha else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                previewPanel.animator().alphaValue = targetAlpha
            }
        } else {
            previewPanel.alphaValue = targetAlpha
        }
    }

    private func makePanel(keyable: Bool = false) -> NSPanel {
        let p: NSPanel
        if keyable {
            p = KeyableHUDPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        } else {
            p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        }
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.alphaValue = 0
        // Visible to screen recorders (default .readWrite allows capture)
        p.sharingType = .readOnly
        // Keep composited even when transparent — eliminates ordering cost on show
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    private func previewFrame(on screen: NSScreen, itemID: String?) -> NSRect? {
        guard itemID != nil else { return nil }
        let sf = screen.visibleFrame
        let leftFrame = leftPanel?.frame ?? NSRect(
            x: sf.minX,
            y: sf.minY + bottomHeight,
            width: leftWidth,
            height: max(0, sf.height - topHeight - bottomHeight)
        )

        let proposedX = leftFrame.maxX - 1
        let maxX = sf.maxX - previewWidth - previewGap
        let previewX = min(proposedX, maxX)

        let anchorY = previewAnchorY(fallbackFrame: leftFrame)
        let minY = leftFrame.minY + previewGap
        let maxY = leftFrame.maxY - previewHeight - previewGap
        let previewY = min(max(anchorY - previewHeight / 2, minY), maxY)

        return NSRect(x: previewX, y: previewY, width: previewWidth, height: previewHeight)
    }

    private func previewAnchorY(fallbackFrame: NSRect) -> CGFloat {
        previewSettledAnchorScreenY ?? state.hoverPreviewAnchorScreenY ?? fallbackFrame.midY
    }

    private func commitPreviewMotionTarget(from targetItem: HUDItem?) -> HUDItem? {
        guard let targetItem else {
            previewSettledItemID = nil
            previewSettledAnchorScreenY = nil
            return nil
        }

        let targetID = targetItem.id

        if previewCanSettle(for: targetItem) {
            previewSettledItemID = targetID
            previewSettledAnchorScreenY = state.hoverPreviewAnchorScreenY ?? previewSettledAnchorScreenY
        }

        if previewSettledItemID == nil {
            return previewCanSettle(for: targetItem) ? targetItem : nil
        }

        if previewSettledItemID == targetID {
            return targetItem
        }

        return state.flatItems.first(where: { $0.id == previewSettledItemID }) ?? targetItem
    }

    private func previewCanSettle(for item: HUDItem) -> Bool {
        guard let window = previewWindow(for: item) else { return false }
        return previewModel.hasSettled(window.wid)
    }

    private func previewWindow(for item: HUDItem) -> WindowEntry? {
        switch item {
        case .window(let window):
            return window
        case .project(let project):
            guard project.isRunning else { return nil }
            return DesktopModel.shared.windowForSession(project.sessionName)
        }
    }

    // MARK: - Keyboard routing

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode

        // Escape: tile mode → exit tile, search → list, otherwise dismiss
        if keyCode == 53 {
            if state.tileMode {
                exitTileMode()
                return nil
            }
            if state.focus == .search {
                state.focus = .list
                return nil
            }
            dismiss()
            return nil
        }

        // ⌥+letter: jump straight to the window wearing that badge (any focus).
        // `v`/`x` are reserved out of the hint alphabet, so ⌥V / ⌥X still fall
        // through to voice / experience below.
        if event.modifierFlags.contains(.option),
           let ch = event.charactersIgnoringModifiers?.lowercased(),
           ch.count == 1,
           let wid = state.hintWid(for: ch),
           let win = DesktopModel.shared.windows[wid] {
            activateItem(.window(win))
            return nil
        }

        // Tab: cycle between search and list
        if keyCode == 48 {
            switch state.focus {
            case .search:
                if !state.flatItems.isEmpty {
                    state.focus = .list
                    if state.selectedItem == nil {
                        state.selectedIndex = 0
                        state.selectedItem = state.flatItems[safe: 0]
                    }
                }
            case .list, .inspector:
                state.focus = .search
            }
            return nil
        }

        // Down arrow (Shift = extend multi-select)
        if keyCode == 125 {
            let shift = event.modifierFlags.contains(.shift)
            if state.focus == .search {
                state.focus = .list
                if let firstItem = state.flatItems[safe: 0] {
                    state.selectSingle(firstItem, index: 0)
                }
            } else if state.focus == .list {
                state.moveSelection(by: 1, extend: shift)
            }
            return nil
        }

        // Up arrow (Shift = extend multi-select)
        if keyCode == 126 {
            let shift = event.modifierFlags.contains(.shift)
            if state.focus == .list {
                if state.selectedIndex == 0 && !shift {
                    state.focus = .search
                } else if state.selectedIndex > 0 {
                    state.moveSelection(by: -1, extend: shift)
                }
            }
            return nil
        }

        // Enter: activate
        if keyCode == 36 {
            if let item = state.selectedItem, state.focus != .search {
                activateItem(item)
            }
            return nil
        }

        // Option+V: toggle voice from ANY context (including search)
        if keyCode == 9 && event.modifierFlags.contains(.option) {
            toggleVoice()
            return nil
        }

        // Option+X: cycle experience preset from ANY context (including search)
        if keyCode == 7 && event.modifierFlags.contains(.option) {
            let name = HUDExperienceStore.shared.cyclePreset()
            state.showFeedback(name, autoClearAfter: 1.4)
            applyExperienceToAllPanels()
            return nil
        }

        // V key (keyCode 9): toggle voice mode (works from any non-search context)
        if keyCode == 9 && state.focus != .search {
            toggleVoice()
            return nil
        }

        // C key (keyCode 8): toggle top/bottom chrome bars
        if keyCode == 8 && state.focus != .search {
            toggleChrome()
            return nil
        }

        // X key (keyCode 7): cycle HUD experience preset
        if keyCode == 7 && state.focus != .search {
            let name = HUDExperienceStore.shared.cyclePreset()
            state.showFeedback(name, autoClearAfter: 1.4)
            applyExperienceToAllPanels()
            return nil
        }

        // M key (keyCode 46): cycle minimap mode (hidden → docked → expanded → hidden)
        if keyCode == 46 && state.focus != .search {
            switch state.minimapMode {
            case .hidden:   state.minimapMode = .docked
            case .docked:   state.minimapMode = .expanded
            case .expanded: state.minimapMode = .hidden
            }
            return nil
        }

        // T key (keyCode 17): tile selected windows or toggle tile mode
        if keyCode == 17 && state.focus != .search {
            DiagnosticLog.shared.info("[TileKey] tileMode=\(state.tileMode) multiSelection=\(state.multiSelectionCount) items=\(state.effectiveSelectionIDs)")
            if state.tileMode {
                exitTileMode()
            } else if !selectedWindowsForActions().isEmpty {
                tileSelectedItems()
            } else {
                enterTileMode()
            }
            return nil
        }

        // D key (keyCode 2): detach selected projects or distribute selected windows
        if keyCode == 2 && state.focus != .search {
            if detachSelectedProjects() {
                return nil
            }
            if distributeSelectedWindows() {
                return nil
            }
        }

        // Tile mode keys — H/J/K/L/F for tiling selected window
        if state.tileMode && state.focus != .search {
            let tileMap: [UInt16: TilePosition] = [
                4:  .left,       // H = left half
                37: .right,      // L = right half
                40: .top,        // K = top half
                38: .bottom,     // J = bottom half
                3:  .maximize,   // F = maximize/fullscreen
                // Quadrants: Y U B N
                16: .topLeft,    // Y = top-left
                32: .topRight,   // U = top-right
                11: .bottomLeft, // B = bottom-left
                45: .bottomRight,// N = bottom-right
            ]
            if let position = tileMap[keyCode] {
                tileSelectedWindow(to: position)
                return nil
            }
        }

        // / key (keyCode 44): enter search mode
        if keyCode == 44 && state.focus != .search {
            state.focus = .search
            return nil
        }

        // [ key (keyCode 33): cycle layer prev
        if keyCode == 33 && state.focus != .search {
            let ws = WorkspaceManager.shared
            if let layers = ws.config?.layers, !layers.isEmpty {
                let prev = ws.activeLayerIndex <= 0 ? layers.count - 1 : ws.activeLayerIndex - 1
                ws.focusLayer(index: prev)
            }
            return nil
        }

        // ] key (keyCode 30): cycle layer next
        if keyCode == 30 && state.focus != .search {
            let ws = WorkspaceManager.shared
            if let layers = ws.config?.layers, !layers.isEmpty {
                let next = (ws.activeLayerIndex + 1) % layers.count
                ws.focusLayer(index: next)
            }
            return nil
        }

        // Number keys 1-2: jump to section (when not in search)
        if state.focus != .search {
            let numberMap: [UInt16: Int] = [18: 1, 19: 2]
            if let num = numberMap[keyCode] {
                if !state.isSectionExpanded(num) {
                    state.toggleSection(num)
                }
                if let offset = state.sectionOffsets[num] {
                    state.focus = .list
                    if let item = state.flatItems[safe: offset] {
                        state.selectSingle(item, index: offset)
                    }
                }
                return nil
            }
        }

        // In search mode, pass through to text field
        if state.focus == .search { return event }

        return event
    }

    private func toggleVoice() {
        let enabling = !state.voiceActive
        let timed = AppFeedback.shared.beginTimed(
            "HUD voice toggle",
            state: state,
            feedback: enabling ? "Voice on" : "Voice off"
        )
        state.voiceActive.toggle()
        HandsOffSession.shared.setAudibleFeedbackEnabled(state.voiceActive)
        if state.voiceActive {
            HandsOffSession.shared.start()
            HandsOffSession.shared.toggle()
        } else {
            if HandsOffSession.shared.state == .listening {
                HandsOffSession.shared.toggle()
            }
        }
        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
    }

    // MARK: - Tile mode

    /// Pre-compute tile grid on HUD show — top 10 frontmost windows, grid positions ready
    private func precomputeTileGrid(on screen: NSScreen) {
        let sf = screen.visibleFrame
        let primaryH = NSScreen.screens.first?.frame.height ?? 900
        let screenCGX = sf.origin.x
        let screenCGY = primaryH - sf.origin.y - sf.height

        // Get the focused window's wid via AX (always include it)
        let focusedWid: UInt32? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var focusedValue: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success else { return nil }
            let axWin = focusedValue as! AXUIElement
            var widValue: CGWindowID = 0
            let result = _AXUIElementGetWindow(axWin, &widValue)
            return result == .success ? UInt32(widValue) : nil
        }()

        // Front 6 by z-order (most recently used first).
        let allOnScreen = DesktopModel.shared.allWindows()
            .filter { $0.isOnScreen && $0.app != "Lattices" && !$0.title.isEmpty }
            .filter { win in
                let cx = win.frame.x + win.frame.w / 2
                let cy = win.frame.y + win.frame.h / 2
                return cx >= Double(screenCGX) && cx < Double(screenCGX + sf.width) &&
                       cy >= Double(screenCGY) && cy < Double(screenCGY + sf.height)
            }

        let log = DiagnosticLog.shared
        log.info("[TileGrid.input] screenSize=\(sf.width)x\(sf.height) onScreen=\(allOnScreen.count)")
        for (i, w) in allOnScreen.prefix(10).enumerated() {
            log.info("[TileGrid.eval] #\(i) z=\(w.zIndex) app=\(w.app) title=\(w.title.prefix(30))")
        }

        var windows = Array(allOnScreen.prefix(6))

        // Ensure the focused window is always included
        if let fwid = focusedWid,
           !windows.contains(where: { $0.wid == fwid }),
           let focusedWin = allOnScreen.first(where: { $0.wid == fwid }) {
            if windows.count >= 6 {
                windows[windows.count - 1] = focusedWin // swap out last
            } else {
                windows.append(focusedWin)
            }
            log.info("[TileGrid.focused] swapped in focusedWid=\(fwid) (\(focusedWin.app): \(focusedWin.title.prefix(30)))")
        }

        log.info("[TileGrid.result] picked=\(windows.count)")

        let count = windows.count
        guard count > 0 else { state.precomputedGrid = []; return }

        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = sf.width / CGFloat(cols)
        let cellH = sf.height / CGFloat(rows)
        let gap: CGFloat = 2

        state.precomputedGrid = windows.enumerated().map { (i, win) in
            let col = i % cols
            let row = i / cols
            let frame = CGRect(
                x: screenCGX + CGFloat(col) * cellW + gap,
                y: screenCGY + CGFloat(row) * cellH + gap,
                width: cellW - gap * 2,
                height: cellH - gap * 2
            )
            return (win.wid, win.pid, frame)
        }
    }

    private func prewarmLikelyPreviews() {
        let desktop = DesktopModel.shared
        let windows = desktop.allWindows()
            .filter { $0.app != "Lattices" }
            .filter { !$0.title.isEmpty }
            .filter { $0.title != $0.app }
            .sorted { lhs, rhs in
                let lhsDate = desktop.lastInteractionDate(for: lhs.wid) ?? .distantPast
                let rhsDate = desktop.lastInteractionDate(for: rhs.wid) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.zIndex < rhs.zIndex
            }

        previewModel.prewarm(windows: windows, limit: 4)
    }

    private func enterTileMode() {
        guard !state.precomputedGrid.isEmpty else { return }
        let timed = AppFeedback.shared.beginTimed(
            "HUD enter tile mode",
            state: state,
            feedback: "Tile mode"
        )

        // Snapshot current positions (for restore on dismiss)
        state.tileSnapshot = state.precomputedGrid.map { move in
            // Look up current frame from DesktopModel
            let win = DesktopModel.shared.windows[move.wid]
            let currentFrame = win.map {
                CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h)
            } ?? CGRect.zero
            return HUDState.WindowSnapshot(wid: move.wid, pid: move.pid, frame: currentFrame)
        }
        state.tiledWindows = []
        state.tileMode = true

        // Apply pre-computed grid — instant
        WindowTiler.batchMoveAndRaiseWindows(state.precomputedGrid)

        // Auto-expand minimap
        if state.minimapMode != .expanded {
            state.minimapMode = .expanded
        }

        // Select first window
        let firstWid = state.precomputedGrid.first?.wid
        if let wid = firstWid,
           let win = DesktopModel.shared.windows[wid],
           let idx = state.flatItems.firstIndex(of: .window(win)) {
            state.focus = .list
            state.selectedIndex = idx
            state.selectedItem = .window(win)
        }

        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        playCue("Tiled.")
    }

    private func exitTileMode() {
        AppFeedback.shared.acknowledge(
            "HUD exit tile mode",
            state: state,
            feedback: "Tile mode off"
        )
        state.tileMode = false
    }

    private func tileSelectedWindow(to position: TilePosition) {
        guard let item = state.selectedItem,
              case .window(let win) = item else { return }
        let timed = AppFeedback.shared.beginTimed(
            "HUD tile window",
            state: state,
            feedback: "Tiling \(win.title)"
        )

        let screen = positionedScreen ?? mouseScreen()
        let frame = WindowTiler.tileFrame(for: position, on: screen)
        WindowTiler.batchMoveAndRaiseWindows([(win.wid, win.pid, frame)])

        state.tiledWindows.insert(win.wid)
        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        playCue("Tiled.")
    }

    /// Restore windows that weren't explicitly tiled back to their original positions
    private func restoreUntiled() {
        guard !state.tileSnapshot.isEmpty else { return }

        var restores: [(wid: UInt32, pid: Int32, frame: CGRect)] = []
        for snap in state.tileSnapshot {
            if !state.tiledWindows.contains(snap.wid) {
                restores.append((snap.wid, snap.pid, snap.frame))
            }
        }

        if !restores.isEmpty {
            WindowTiler.batchMoveAndRaiseWindows(restores)
        }

        state.tileSnapshot = []
        state.tiledWindows = []
        state.tileMode = false
    }

    /// Tile only the multi-selected windows from the sidebar
    private func tileSelectedItems() {
        let windows = selectedWindowsForActions()
        guard !windows.isEmpty else { return }
        let screen = positionedScreen ?? mouseScreen()
        let slots = WindowTiler.computeGridSlots(count: windows.count, screen: screen)
        guard slots.count == windows.count else { return }
        let timed = AppFeedback.shared.beginTimed(
            "HUD tile selection",
            state: state,
            feedback: "Tiling \(windows.count) window\(windows.count == 1 ? "" : "s")"
        )

        // Snapshot for restore
        state.tileSnapshot = windows.map { win in
            HUDState.WindowSnapshot(
                wid: win.wid, pid: win.pid,
                frame: CGRect(x: win.frame.x, y: win.frame.y,
                              width: win.frame.w, height: win.frame.h)
            )
        }
        state.tiledWindows = []
        state.tileMode = true

        // Use the same row order and contiguous slots as distribute and arrange.
        let moves: [(wid: UInt32, pid: Int32, frame: CGRect)] = zip(windows, slots).map { win, frame in
            (wid: win.wid, pid: win.pid, frame: frame)
        }

        WindowTiler.batchMoveAndRaiseWindows(moves)
        state.precomputedGrid = moves

        // Expand minimap
        if state.minimapMode != .expanded { state.minimapMode = .expanded }

        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        playCue("Tiled.")
        DiagnosticLog.shared.info("[TileGrid.selected] tiled \(windows.count) selected windows")
    }

    private func detachSelectedProjects() -> Bool {
        let projects = selectedProjectsForActions().filter(\.isRunning)
        guard !projects.isEmpty else { return false }
        let timed = AppFeedback.shared.beginTimed(
            "HUD detach selection",
            state: state,
            feedback: "Detaching \(projects.count) project\(projects.count == 1 ? "" : "s")"
        )

        for project in projects {
            SessionManager.detach(project: project)
        }

        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        playCue("Done.")
        DiagnosticLog.shared.info("[Detach.selected] detached \(projects.count) project(s)")
        dismiss()
        return true
    }

    private func distributeSelectedWindows() -> Bool {
        let windows = selectedWindowsForActions()
        guard windows.count > 1 else { return false }
        let timed = AppFeedback.shared.beginTimed(
            "HUD distribute selection",
            state: state,
            feedback: "Distributing \(windows.count) windows"
        )

        WindowTiler.batchRaiseAndDistribute(windows: windows.map { (wid: $0.wid, pid: $0.pid) })
        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        playCue("Distributed.")
        DiagnosticLog.shared.info("[Distribute.selected] distributed \(windows.count) window(s)")
        return true
    }

    private func selectedProjectsForActions() -> [Project] {
        let ids = state.effectiveSelectionIDs
        guard !ids.isEmpty else { return [] }

        return state.flatItems.compactMap { item in
            guard ids.contains(item.id), case .project(let project) = item else { return nil }
            return project
        }
    }

    private func selectedWindowsForActions() -> [WindowEntry] {
        let ids = state.effectiveSelectionIDs
        guard !ids.isEmpty else { return [] }

        var seen = Set<UInt32>()
        var windows: [WindowEntry] = []

        for item in state.flatItems {
            guard ids.contains(item.id) else { continue }

            switch item {
            case .window(let window):
                if seen.insert(window.wid).inserted {
                    windows.append(window)
                }
            case .project(let project):
                guard project.isRunning else { continue }
                let projectWindows = DesktopModel.shared.allWindows().filter { $0.latticesSession == project.sessionName }
                for window in projectWindows where seen.insert(window.wid).inserted {
                    windows.append(window)
                }
            }
        }

        return windows
    }

    private func activateItem(_ item: HUDItem) {
        let (label, feedback): (String, String) = {
            switch item {
            case .project(let p):
                let verb = p.isRunning ? "Focus" : "Launch"
                return ("HUD \(verb.lowercased()) project", "\(verb) \(p.name)")
            case .window(let w):
                return ("HUD focus window", "Focus \(w.title)")
            }
        }()
        let timed = AppFeedback.shared.beginTimed(label, state: state, feedback: feedback)
        switch item {
        case .project(let p):
            SessionManager.launch(project: p)
            playCue(p.isRunning ? "Focused." : "Done.")
        case .window(let w):
            _ = WindowTiler.focusWindow(wid: w.wid, pid: w.pid)
            playCue("Focused.")
        }
        DispatchQueue.main.async {
            AppFeedback.shared.finish(timed)
        }
        dismiss()
    }

    private func playCue(_ phrase: String) {
        HandsOffSession.shared.playCachedCue(phrase)
    }

    // MARK: - Experience helpers

    private func toggleChrome() {
        let xp = HUDExperienceStore.shared
        xp.toggleChrome()
        guard let screen = positionedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        positionAllPanels(on: screen)
        let show = xp.showChrome
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            topPanel?.animator().alphaValue = show ? 1 : 0
            bottomPanel?.animator().alphaValue = show ? 1 : 0
        }
        topPanel?.ignoresMouseEvents = !show
        bottomPanel?.ignoresMouseEvents = !show
        state.showFeedback(show ? "Chrome on" : "Chrome off", autoClearAfter: 1.2)
    }

    private func applyExperienceToAllPanels() {
        let isFreeform = HUDExperienceStore.shared.has(.freeformWidgets)
        for p in allPanels { p.isMovableByWindowBackground = isFreeform }
        // Sidebar and preview are always draggable; position is only persisted in freeform mode
        leftPanel?.isMovableByWindowBackground = true
        previewPanel?.isMovableByWindowBackground = true
    }

    private func installMouseMovedMonitor() {
        guard mouseMovedMonitor == nil else { return }
        mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastMouseUpdate) > 0.033 else { return } // ~30 fps cap
            self.lastMouseUpdate = now
            let pos = NSEvent.mouseLocation
            DispatchQueue.main.async {
                HUDExperienceStore.shared.mousePosition = pos
            }
        }
    }

    private func removeMouseMovedMonitor() {
        if let m = mouseMovedMonitor { NSEvent.removeMonitor(m); mouseMovedMonitor = nil }
    }

    private func captureDesktop() {
        guard let screen = positionedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        Task {
            let image = await DesktopCapture.shared.captureScreen(screen)
            await MainActor.run {
                HUDExperienceStore.shared.capturedBackground = image
            }
        }
    }

    // MARK: - Event monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss() }
                return
            }
            let loc = NSEvent.mouseLocation
            let inAny = self.allPanels
                .compactMap { $0 }
                .contains { $0.frame.contains(loc) } || self.liveTabChromes.contains(loc)
            let isOwnedLiveTabFocus = Date() < self.suppressOutsideDismissUntil
            if !inAny && !isOwnedLiveTabFocus { self.dismiss() }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - Window jump badges

    /// Reposition + reveal the ⌥+letter badges over each on-screen window.
    private func refreshHintBezels() {
        guard isVisible else { hintBezels.setRevealed(false); return }
        var obscured: [NSRect] = []
        if let leftPanel { obscured.append(leftPanel.frame) }
        if let rightPanel, rightPanel.alphaValue > 0.5 { obscured.append(rightPanel.frame) }
        hintBezels.update(
            hints: state.windowHints,
            windows: DesktopModel.shared.windows,
            obscuredBy: obscured
        )
        hintBezels.setRevealed(true)
    }

    /// Position browser-like tab bars on the actual grouped windows. This is
    /// intentionally Hyper-3-only for now; the runtime group itself persists
    /// after dismissal, ready for a future always-on chrome mode.
    private func refreshLiveTabChromes() {
        LiveTabGroupStore.shared.syncSelection(toFocusedWindow: DesktopModel.shared.focusedWindowID)
        let obscured = (isVisible ? [topPanel, leftPanel, rightPanel] : [])
            .compactMap { panel -> NSRect? in
                guard let panel, panel.alphaValue > 0.5 else { return nil }
                return panel.frame
            }
        liveTabChromes.update(
            groups: LiveTabGroupStore.shared.groups,
            windows: DesktopModel.shared.windows,
            obscuredBy: obscured
        )
        liveTabChromes.setRevealed(true)
    }

    private func mouseScreen() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
            ?? NSScreen.main ?? NSScreen.screens.first!
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
