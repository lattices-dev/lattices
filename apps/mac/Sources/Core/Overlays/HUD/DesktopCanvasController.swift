import AppKit
import Carbon

final class DesktopCanvasController {
    static let shared = DesktopCanvasController()
    private(set) var active = false
    private var ready = false
    private var shortcutsReady = false
    private var ignoreScrollUntil: TimeInterval = 0
    private var busy = false
    private var returning = false
    private var epoch = 0
    private var panel: DesktopCanvasPanel?
    private var returnPanel: NSPanel?
    private var status: NSStatusItem?
    private var view: DesktopCanvasView?
    private var screen: NSScreen?
    private var screenFrame = CGRect.zero
    private var space = 0
    private var display = ""
    private var model: DesktopCanvasModel?
    private var entryModel: DesktopCanvasModel?
    private var layouts: [String: DesktopCanvasModel] = [:]
    private var images: [UInt32: CGImage] = [:]
    private var capture: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var materialized: [UInt32: CGRect] = [:]
    private let session = DesktopCanvasSession.shared
    private var placementCancellation: DesktopCanvasSession.Cancellation?

    func start() {
        let keys = HotkeyManager.shared
        let enter = keys.registerSingle(id: 9030, keyCode: 125, modifiers: UInt32(controlKey | cmdKey)) { [weak self] in self?.open() }
        let exit = keys.registerSingle(id: 9031, keyCode: 126, modifiers: UInt32(controlKey | cmdKey)) { [weak self] in self?.returnToNormal() }
        let escape = keys.registerSingle(id: 9032, keyCode: 53, modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in self?.returnToNormal() }
        shortcutsReady = enter && exit && escape
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(boundaryChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(boundaryChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        session.queue.async { [weak self] in
            let restored = DesktopCanvasSession.shared.restore()
            DispatchQueue.main.async {
                guard let self else { return }
                self.ready = enter && exit && escape && restored
                DiagnosticLog.shared.info("DesktopCanvas: ready=\(self.ready) recovered=\(restored)")
                if !restored { self.active = true; self.showStuckControls() }
            }
        }
    }

    @objc private func boundaryChanged() {
        guard active, !returning else { return }
        // An ordinary Space change should not pull the user back. Explicit
        // Return can revisit the original Space if its windows need recovery.
        returnToNormal(revisitSpace: false)
    }

    func scroll(delta: Double, point: CGPoint) {
        guard ProcessInfo.processInfo.systemUptime >= ignoreScrollUntil else {
            ignoreScrollUntil = ProcessInfo.processInfo.systemUptime + 0.25
            return
        }
        guard !busy else { return }
        if let view, panel?.isVisible == true {
            view.zoom(by: CGFloat(exp(max(-80, min(80, delta)) * 0.012)))
        } else if delta < 0 { open(point: point) }
    }

    func open(point: CGPoint? = nil) {
        let started = ProcessInfo.processInfo.systemUptime
        guard ready, !busy else {
            DiagnosticLog.shared.warn("DesktopCanvas: entry deferred ready=\(ready) busy=\(busy)")
            return
        }
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            return
        }
        guard let plan = WindowTiler.planAdjacentSpaceSwitch(offset: 0, from: point),
              plan.display.spaces.contains(where: { $0.id == plan.currentSpaceId }),
              let targetScreen = WindowTiler.screen(for: plan) else { return }
        if active && (space != plan.currentSpaceId || display != plan.display.displayId) {
            returnToNormal { [weak self] in self?.open(point: point) }
            return
        }
        guard SpaceSwitchInterceptor.shared.prepareForDesktopCanvas() else { return }
        epoch += 1
        screen = targetScreen
        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        screenFrame = DisplayGeometryMapper.topLeftFrame(targetScreen.visibleFrame, primaryHeight: primaryHeight)
        space = plan.currentSpaceId
        display = plan.display.displayId
        // Entry needs current z-order and frames: a window focused or moved
        // immediately before the gesture may not be in the published poll yet.
        let entries = DesktopModel.shared.refreshNow().filter {
            $0.pid != getpid() && $0.axVerified && !$0.appHidden && !$0.collapsed && $0.spaceIds == [space]
                && $0.frame.w >= 120 && $0.frame.h >= 80
                && screenFrame.contains(CGPoint(x: $0.frame.x + $0.frame.w / 2, y: $0.frame.y + 16))
        }
        let candidates = entries.compactMap { entry -> DesktopCanvasModel.Item? in
            var item = DesktopCanvasModel.Item(id: entry.wid, pid: entry.pid, title: entry.app + " · " + entry.title,
                frame: CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h))
            guard let state = session.candidateState(item, space: space), !state.minimized else { return nil }
            item.frame = state.frame
            return item
        }
        let candidateIDs = Set(candidates.map(\.id))
        let stationaryApps = Set(entries.filter { !candidateIDs.contains($0.wid) }.map(\.app)).sorted()
        if !active {
            previousApp = NSWorkspace.shared.frontmostApplication
            let original = candidates.map { item in
                DesktopCanvasModel.Item(id: item.id, pid: item.pid, title: item.title,
                    frame: item.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
            }
            var fresh = DesktopCanvasModel(items: original, viewport: CGRect(origin: .zero, size: screenFrame.size))
            entryModel = fresh
            if let saved = layouts[key] {
                for i in fresh.items.indices {
                    if let prior = saved.items.first(where: { $0.id == fresh.items[i].id && $0.pid == fresh.items[i].pid }) {
                        fresh.items[i].frame = prior.frame
                    }
                }
                fresh.extent = saved.extent
            }
            model = fresh
            active = true
        } else if var current = model {
            current.items.removeAll { session.exists($0) == false }
            // Only real moves made after landing update the logical layout;
            // boundary clamping itself must not destroy the saved coordinates.
            for index in current.items.indices {
                let item = current.items[index]
                if let expected = materialized[item.id], let state = session.read(item), !state.minimized,
                   state.frame != expected {
                    current.items[index].frame = DesktopCanvasModel.logicalFrame(state.frame, viewport: current.viewport, screen: screenFrame)
                }
            }
            for item in candidates where !current.items.contains(where: { $0.id == item.id }) {
                current.items.append(.init(id: item.id, pid: item.pid, title: item.title,
                    frame: DesktopCanvasModel.logicalFrame(item.frame, viewport: current.viewport, screen: screenFrame)))
            }
            model = current
        }
        guard var current = model else { return }
        current.expand(); model = current
        returnPanel?.orderOut(nil)
        let canvas = DesktopCanvasView(frame: CGRect(origin: .zero, size: targetScreen.visibleFrame.size), model: current, images: images)
        canvas.stationaryApps = stationaryApps
        canvas.message = "Drag windows to arrange · Enter confirms · Esc undoes"
        canvas.prepareEntrance()
        canvas.onChange = { [weak self] model in self?.model = model }
        canvas.onWork = { [weak self] in self?.workHere(focus: $0) }
        canvas.onExit = { [weak self] in self?.returnToNormal(discardArrangement: true) }
        let window = DesktopCanvasPanel(contentRect: targetScreen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        // Keep the actual desktop visible while taking one composited frame.
        // The key window still owns Escape throughout this short preparation.
        window.alphaValue = 0
        canvas.isBusy = true; busy = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
        panel = window; view = canvas
        showStatus()
        capture?.cancel()
        let generation = epoch
        let captureFrame = screenFrame
        let ids = current.items.map(\.id)
        images = images.filter { ids.contains($0.key) }
        capture = Task { @MainActor [weak self] in
            let desktop = await WindowCapture.region(rect: captureFrame, showsCursor: false)
            guard !Task.isCancelled, let self, self.active, self.epoch == generation else { return }
            canvas.installDesktopCover(desktop)
            self.busy = false; canvas.isBusy = false
            window.alphaValue = 1
            canvas.animateEntrance()
            DiagnosticLog.shared.info("DesktopCanvas: interactive ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            await WindowCapture.thumbnails(windowIDs: Array(ids.prefix(48)), maximumPixelSize: 1600, ignoreShadows: true, nativeResolution: true, onBatch: { [weak self] shots in
                await self?.receivePreviews(shots, generation: generation)
            })
            guard !Task.isCancelled, self.epoch == generation, !self.busy else { return }
            canvas.revealWindowPreviews()
            DiagnosticLog.shared.info("DesktopCanvas: previews ready ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        }
        DiagnosticLog.shared.info("DesktopCanvas: opened space=\(space) windows=\(current.items.count) preparedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
    }

    @MainActor private func receivePreviews(_ shots: [UInt32: CGImage], generation: Int) {
        guard active, epoch == generation, !busy, panel?.isVisible == true else { return }
        images.merge(shots) { _, new in new }
        view?.images = images
    }

    private var key: String { "\(display):\(space)" }

    private func workHere(focus: UInt32?) {
        guard !busy, let current = model else { return }
        busy = true; view?.isBusy = true
        capture?.cancel()
        view?.message = "Opening this area at normal size…"
        let generation = epoch, frame = screenFrame, target = space
        let started = ProcessInfo.processInfo.systemUptime
        let cancellation = DesktopCanvasSession.Cancellation()
        placementCancellation = cancellation
        let handoff = DesktopCanvasHandoff()
        let finish: () -> Void = { [weak self] in
            guard let self, self.epoch == generation, self.active else { return }
            self.placementCancellation = nil
            self.busy = false; self.view?.isBusy = false
            self.panel?.orderOut(nil)
            let parked = current.items.count - self.materialized.count
            self.showReturnControls(message: "Working here · Normal size",
                                    hint: parked > 0 ? "Keep makes this layout permanent. \(parked) window\(parked == 1 ? "" : "s") outside the frame stay in the Dock."
                                                     : "Keep makes this layout permanent. Arrange to change it.")
            let visible = current.items.filter { self.materialized[$0.id] != nil }
            if let item = visible.first(where: { $0.id == focus }) ?? visible.first,
               WindowTiler.getSpacesForWindow(item.id) == [target],
               let ax = EditorMutationJournal.axWindow(item.id, pid: item.pid) {
                NSRunningApplication(processIdentifier: item.pid)?.activate()
                AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            }
            DiagnosticLog.shared.info("DesktopCanvas: native viewport=\(current.viewport) visible=\(self.materialized.count) handoffMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        }
        // Motion acknowledges Enter immediately, while the recovery-protected
        // native work happens behind the cover. Neither completion may expose
        // a partially placed desktop, and Escape invalidates both via epoch.
        view?.animateLanding { if handoff.arrive(.motion) { finish() } }
        session.queue.async { [weak self] in
            let success = DesktopCanvasSession.shared.apply(current, screen: frame, space: target, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self, self.epoch == generation else { return }
                guard success else { self.busy = false; self.returnToNormal(discardArrangement: true); return }
                self.layouts[self.key] = current
                self.materialized = Dictionary(uniqueKeysWithValues: current.items.compactMap { item in
                    DesktopCanvasModel.physicalFrame(item.frame, viewport: current.viewport, screen: frame).map { (item.id, $0) }
                })
                if handoff.arrive(.native) { finish() }
            }
        }
    }

    func returnToNormal(revisitSpace: Bool = true, discardArrangement: Bool = false, completion: (() -> Void)? = nil) {
        guard active else { completion?(); return }
        guard !returning else { return }
        ignoreScrollUntil = ProcessInfo.processInfo.systemUptime + 0.4
        epoch += 1; let generation = epoch
        placementCancellation?.cancel(); placementCancellation = nil
        busy = true; returning = true; view?.isBusy = true
        view?.message = "Restoring every window to its original position…"
        capture?.cancel()
        if !discardArrangement, let model { layouts[key] = model }
        let handoff = DesktopCanvasHandoff()
        let finish: () -> Void = { [weak self] in
            guard let self, generation == self.epoch else { return }
            self.endSession()
            completion?()
        }
        if panel?.isVisible == true, let view {
            view.animateReturn(to: entryModel) { if handoff.arrive(.motion) { finish() } }
        } else { _ = handoff.arrive(.motion) }
        session.queue.async { [weak self] in
            if revisitSpace, let target = DesktopCanvasSession.shared.recoverySpace {
                // AX may stop exposing parked windows on another Space. Use
                // the existing verified switch path before restoring them.
                WindowTiler.switchToSpace(spaceId: target)
            }
            let restored = DesktopCanvasSession.shared.restore()
            DispatchQueue.main.async {
                guard let self, generation == self.epoch else { return }
                if restored {
                    if handoff.arrive(.native) { finish() }
                } else {
                    self.busy = false; self.returning = false; self.view?.isBusy = false
                    self.view?.message = "Some windows could not be restored. Return to normal will retry."
                    self.showStuckControls()
                }
                DiagnosticLog.shared.info("DesktopCanvas: return restored=\(restored)")
            }
        }
    }

    private func endSession() {
        busy = false; returning = false
        panel?.orderOut(nil); returnPanel?.orderOut(nil)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { previousApp?.activate() }
        previousApp = nil
        panel = nil; view = nil; model = nil; entryModel = nil
        materialized = [:]; images = [:]; active = false
        ready = shortcutsReady
        if let status { NSStatusBar.system.removeStatusItem(status) }; status = nil
    }

    /// Retrying can't fix a window the app refuses to move. Name it and let
    /// the user keep it where it is instead of looping on Return to normal.
    private func showStuckControls() {
        let apps = session.pendingApps
        let names = apps.isEmpty ? "Some windows" : ListFormatter.localizedString(byJoining: apps)
        showReturnControls(message: "\(names) didn't move back",
                           hint: "Return to normal retries. Leave as is keeps the windows where they are now.",
                           stuck: true)
    }

    /// Confirm what is on screen: windows stay where they are, the journal is
    /// dropped and the session ends. Parked windows stay minimized in the Dock.
    private func keepView() {
        guard active, !busy, !returning else { return }
        epoch += 1; let generation = epoch
        busy = true
        session.queue.async { [weak self] in
            let kept = DesktopCanvasSession.shared.abandon()
            DispatchQueue.main.async {
                guard let self, generation == self.epoch else { return }
                DiagnosticLog.shared.info("DesktopCanvas: kept view=\(kept)")
                if kept { self.layouts[self.key] = nil; self.endSession() } else { self.busy = false }
            }
        }
    }

    private func leaveAsIs() {
        guard active, !busy else { return }
        epoch += 1; let generation = epoch
        busy = true
        session.queue.async { [weak self] in
            let left = DesktopCanvasSession.shared.abandon()
            DispatchQueue.main.async {
                guard let self, generation == self.epoch else { return }
                if left { self.layouts[self.key] = nil; self.endSession() } else { self.busy = false; self.showStuckControls() }
            }
        }
    }

    private func showStatus() {
        guard status == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Canvas"
        let menu = NSMenu()
        let arrange = menu.addItem(withTitle: "Arrange this desktop  ⌃⌘↓", action: #selector(arrangeAction), keyEquivalent: "")
        arrange.target = self
        let keep = menu.addItem(withTitle: "Keep this layout", action: #selector(keepAction), keyEquivalent: "")
        keep.target = self
        let exit = menu.addItem(withTitle: "Return to normal  ⌃⌘↑", action: #selector(exitAction), keyEquivalent: "")
        exit.target = self
        menu.addItem(.separator())
        for title in ["Canvas zoom: Control + Command + scroll", "Desktop overview: Control + Option + scroll", "Emergency return: Control + Option + Command + Escape"] {
            let hint = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            hint.isEnabled = false
        }
        item.menu = menu; status = item
    }

    private func showReturnControls(message: String,
                                    hint hintText: String = "Type in apps normally. Open Arrange to pan or zoom.",
                                    stuck: Bool = false) {
        showStatus()
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let window = returnPanel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(CGRect(x: area.midX - 440, y: area.minY + 16, width: 880, height: 64), display: true)
        window.level = .floating; window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.backgroundColor = .windowBackgroundColor
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 880, height: 64))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        window.isOpaque = false
        window.backgroundColor = .clear
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = NSTextField(labelWithString: message)
        label.frame = CGRect(x: 16, y: 34, width: 410, height: 20); label.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(label)
        let hint = NSTextField(labelWithString: hintText)
        hint.frame = CGRect(x: 16, y: 13, width: 410, height: 16)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        content.addSubview(hint)
        if stuck {
            let leave = NSButton(title: "Leave as is", target: self, action: #selector(leaveAction))
            leave.frame = CGRect(x: 554, y: 18, width: 126, height: 28)
            leave.toolTip = "Stop restoring these windows and keep them where they are now."
            content.addSubview(leave)
        } else {
            let keep = NSButton(title: "Keep", target: self, action: #selector(keepAction))
            keep.frame = CGRect(x: 434, y: 18, width: 116, height: 28)
            keep.bezelColor = .controlAccentColor
            keep.toolTip = "Keep this layout and finish. Windows stay where they are."
            content.addSubview(keep)
            let arrange = NSButton(title: "Arrange ⌃⌘↓", target: self, action: #selector(arrangeAction))
            arrange.frame = CGRect(x: 554, y: 18, width: 126, height: 28)
            arrange.toolTip = "Control + Command + Down opens the larger canvas. Arrow keys pan only in Arrange."
            content.addSubview(arrange)
        }
        let exit = NSButton(title: "Return to normal ⌃⌘↑", target: self, action: #selector(exitAction))
        exit.frame = CGRect(x: 684, y: 18, width: 180, height: 28)
        exit.toolTip = "Control + Command + Up restores every window to its original position."
        content.addSubview(exit)
        window.contentView = content; window.orderFrontRegardless(); returnPanel = window
    }
    @objc private func arrangeAction() { open() }
    @objc private func exitAction() { returnToNormal() }
    @objc private func leaveAction() { leaveAsIs() }
    @objc private func keepAction() { keepView() }
}

final class DesktopCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
