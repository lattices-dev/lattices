import AppKit
import ScreenCaptureKit

// MARK: - Layer Preview

/// The frozen side of a ⌘⌥ flip. A flip aims at its layer and moves
/// nothing until ⌘⌥ comes up (`LayerAim`); pressing Space while ⌘⌥ is
/// still down freezes on the layer aimed at instead, and lays the whole
/// layer out like Mission Control: every window it matched,
/// wherever it is, then what it shows beyond its entries (its scene, drawn
/// with a dashed edge) and what it keeps put away, each captured and scaled
/// without changing its shape. What it keeps put away is dimmed; a window
/// that isn't showing now (hidden, parked, another desktop) has a badge
/// saying where it is.
///
/// Frozen, one tile is picked: the arrows pick the nearest one that way,
/// Tab and ⇧Tab step through them, and the pointer picks the one under it.
/// Space puts the picked window away in this layer, or brings a dimmed one
/// back (`LayerStage.setTucked`); a window on another display can't be put
/// away, since a switch leaves that display be. L steps the layer's layout
/// through none, auto, columns and master-stack. A bare digit sends the
/// picked window to the layer in that slot, and Delete takes it out of this
/// one. ⌘⌥ arrows and ⌘⌥1–9 browse other layers without touching a window.
///
/// Each choice is saved as it's made, and no window moves until Enter moves
/// in: windows on another desktop of the display are carried to this one
/// (`WindowSpaceCarry`), then the layer switches as a flip would, which
/// puts away and lays out what the choices say. A layer that isn't entered
/// keeps them for when it is. Escape leaves every window where it is.
///
/// A freeze holds the keys only while its panel is up or coming up. Besides
/// Escape and Enter, it ends when another app comes forward, when the panel
/// goes, and after a spell with no key; a key or ⌘⌥ release that finds no
/// panel goes through and ends it.
final class LayerPreview {
    static let shared = LayerPreview()

    private let lock = NSLock()
    /// Set by a flip while ⌘⌥ is held; Space freezes, releasing ⌘⌥ disarms.
    private var armed = false
    private var frozen = false
    /// Space froze it and the panel isn't up yet.
    private var pending = false
    /// The panel is up for this freeze.
    private var showing = false
    /// When Space froze it.
    private var frozenAt = Date.distantPast
    /// Bumped on every freeze and close, so a key queued in one freeze
    /// can't act after it ends.
    private var generation = 0
    /// Ends a freeze no key has touched in `idleLimit`.
    private var idle: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var panel: NSPanel?
    private var previewView: LayerPreviewView?
    /// The layer on show while frozen.
    private var index = 0
    /// Kept between freezes, so a window shows its last shot at once while a
    /// fresh one comes in. `fresh` is what this freeze has captured.
    private var captures: [UInt32: NSImage] = [:]
    private var fresh: Set<UInt32> = []
    private var captureTask: Task<Void, Never>?

    /// Carries per Enter. Each takes a few seconds with Mission Control up.
    private static let carryLimit = 6
    /// How long a freeze waits on no key before it ends.
    private static let idleLimit: TimeInterval = 30
    /// How long after Space an app coming forward is still the flip's own
    /// raise landing, not a click elsewhere.
    private static let activationGrace: TimeInterval = 1

    private init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.appActivated(notification)
        })
    }

    var isFrozen: Bool {
        lock.lock(); defer { lock.unlock() }
        return frozen
    }

    /// Whether a freeze has the keys: its panel is up, or on its way. A
    /// freeze whose panel is gone ends here instead, so ⌘⌥ flips again.
    func holdsKeys() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        let frozen = self.frozen
        let pending = self.pending
        let showing = self.showing
        lock.unlock()
        guard frozen else { return false }
        if pending || (showing && panel?.isVisible == true) { return true }
        close()
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return frozen && self.generation == generation
    }

    // MARK: Hotkey entry points

    /// After a ⌘⌥ flip to a workspace layer: while ⌘⌥ stays down, Space
    /// freezes on it.
    func arm() {
        dispatchPrecondition(condition: .onQueue(.main))
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.contains(.maskCommand), flags.contains(.maskAlternate) else { return }
        guard ensureTap() else { return }
        lock.lock()
        armed = true
        lock.unlock()
    }

    /// A ⌘⌥ arrow from the hotkeys: the tap has already browsed while
    /// frozen, so this only says whether to skip the flip (`holdsKeys`).
    func step(_ direction: LayerSlots.Direction) -> Bool { holdsKeys() }

    /// ⌘⌥N from the hotkeys; see `step`.
    func select(slot: Int) -> Bool { holdsKeys() }

    private func browse(_ direction: LayerSlots.Direction) {
        let count = WorkspaceManager.shared.config?.layers?.count ?? 0
        if let next = LayerSlots.neighbour(of: index, direction, count: count) {
            show(index: next)
        }
    }

    private func browse(toSlot slot: Int) {
        let count = WorkspaceManager.shared.config?.layers?.count ?? 0
        if let next = LayerSlots.index(forSlot: slot), next < count {
            show(index: next)
        }
    }

    // MARK: Sending windows

    /// A bare digit: the picked window goes to the layer in slot `slot`.
    private func send(toSlot slot: Int) {
        let workspace = WorkspaceManager.shared
        guard let view = previewView, let wid = view.picked,
              let window = DesktopModel.shared.windows[wid] else { return }
        guard let target = LayerSlots.index(forSlot: slot), workspace.layers.indices.contains(target) else {
            view.flash("No layer on \(slot)")
            return
        }
        let name = workspace.layers[target].label
        do {
            switch try workspace.moveWindow(window, from: index, to: target) {
            case .moved: view.flash("Sent to \(name)")
            case .copied: view.flash("Also in \(name); an entry here still matches it")
            case .unchanged: view.flash("Already in \(name)")
            }
        } catch {
            view.flash(error.localizedDescription)
        }
        show(index: index)
    }

    /// Delete: the picked window leaves the layer on show.
    private func removePicked() {
        guard let view = previewView, let wid = view.picked else { return }
        do {
            view.flash(try WorkspaceManager.shared.removeWindow(wid, fromLayer: index)
                ? "Removed" : "An entry that matches other windows holds it")
        } catch {
            view.flash(error.localizedDescription)
        }
        show(index: index)
    }

    // MARK: Choices

    /// Space: the picked window stays put away in the layer on show, or,
    /// dimmed, comes back. Saved at once; the next switch to the layer acts
    /// on it, Enter's included.
    private func togglePicked() {
        let layers = WorkspaceManager.shared.layers
        guard let view = previewView, let wid = view.picked, layers.indices.contains(index) else { return }
        let id = layers[index].id
        let tuck = !LayerStage.shared.tucked(id).contains(wid)
        if tuck, view.spot(of: wid)?.canPutAway == false {
            view.flash("Only the main display")
            return
        }
        LayerStage.shared.setTucked(wid, tuck, layer: id)
        view.setChoices(tucked: LayerStage.shared.tucked(id))
    }

    /// L: the layer on show takes the next layout (`LayerLayout.next`).
    /// Saved at once; the next switch to the layer lays it out.
    private func cycleLayout() {
        let workspace = WorkspaceManager.shared
        guard workspace.layers.indices.contains(index) else { return }
        do {
            try workspace.setLayout(LayerLayout.next(after: workspace.layers[index].layout), forLayer: index)
        } catch {
            previewView?.flash(error.localizedDescription)
        }
        show(index: index)
    }

    // MARK: Freeze, commit, cancel

    private func freeze(_ generation: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(generation) else { return }
        let workspace = WorkspaceManager.shared
        guard let layers = workspace.config?.layers, !layers.isEmpty else {
            unfreeze()
            return
        }
        // At once: the bezel sits above the preview and would fade over it.
        LayerBezel.shared.dismiss(animated: false)
        fresh = []
        previewView?.resetPick()
        DesktopModel.shared.refreshNow()
        let live = Set(DesktopModel.shared.windows.keys)
        captures = captures.filter { live.contains($0.key) }
        // The layer the flip aimed at; this freeze owns the aim now.
        let aimed = LayerAim.shared.take() ?? workspace.activeLayerIndex
        show(index: min(max(aimed, 0), layers.count - 1))

        lock.lock()
        pending = false
        showing = panel?.isVisible == true
        let up = showing
        lock.unlock()
        // No panel came up: don't keep the keys.
        guard up else {
            close()
            return
        }
        extendIdle(generation)
    }

    private func show(index: Int) {
        let workspace = WorkspaceManager.shared
        guard let layers = workspace.config?.layers, layers.indices.contains(index) else { return }
        if index != self.index { previewView?.resetPick() }
        self.index = index
        let windows = DesktopModel.shared.allWindows()
        let overviews = workspace.overviews(in: windows)
        guard let overview = overviews.first(where: { $0.index == index }) else { return }
        let layer = layers[index]
        let tucked = LayerStage.shared.tucked(layer.id)
        let extras = Self.extras(
            of: layer,
            active: index == workspace.activeLayerSelection,
            tucked: tucked,
            owned: Set(overviews.flatMap(\.windows).map(\.wid)),
            in: windows
        )
        let shown = overview.windows + extras

        let (panel, view) = ensurePanel()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen, panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        view.frame = CGRect(origin: .zero, size: panel.frame.size)
        view.update(
            overview: overview,
            extras: extras,
            tucked: tucked,
            filled: Set((0..<min(layers.count, LayerSlots.ordered.count)).compactMap(LayerSlots.slot(forIndex:))),
            // Until this freeze's shot lands: the last one, or the warm pool's.
            captures: Dictionary(shown.compactMap { window in
                (captures[window.wid] ?? WindowPreviewStore.shared.image(for: window.wid)).map { (window.wid, $0) }
            }, uniquingKeysWith: { first, _ in first })
        )
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Over a close's fade that hasn't finished, too.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 1
        }
        capture(shown.map(\.wid).filter { !fresh.contains($0) })
    }

    /// What the layer shows beyond its entries, as the preview lists it. For
    /// the layer you're on, what's showing now that no layer holds, which a
    /// switch back to it keeps; for another, what it had showing when it was
    /// last left (`LayerStage.scene`). Then what it keeps put away, or was
    /// just let show, that no layer holds. `owned` is every window a layer
    /// holds.
    private static func extras(
        of layer: Layer,
        active: Bool,
        tucked: Set<UInt32>,
        owned: Set<UInt32>,
        in windows: [WindowEntry]
    ) -> [LayerOverview.Window] {
        var scene: [UInt32]
        if active {
            scene = LayerStage.Stage.current().map {
                LayerStage.scene(of: windows, stage: $0, claimed: owned, settling: LayerStage.shared.settling())
            } ?? []
        } else {
            scene = LayerStage.shared.scene(for: layer)
        }
        scene += tucked.sorted() + LayerStage.shared.untucked(layer.id).sorted()
        let byWid = Dictionary(windows.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
        let context = LayerRoster.Context.current()
        let main = CGDisplayBounds(CGMainDisplayID())
        var seen = owned
        return scene.compactMap { wid -> LayerOverview.Window? in
            guard seen.insert(wid).inserted, let entry = byWid[wid], DesktopModel.isContent(entry),
                  let spot = LayerRoster.spot(of: entry, place: context.place(of: entry.spaceIds), main: main)
            else { return nil }
            return LayerOverview.Window(wid: wid, app: entry.app, title: entry.title, spot: spot)
        }
    }

    private func commit() {
        dispatchPrecondition(condition: .onQueue(.main))
        let target = index
        close()

        let workspace = WorkspaceManager.shared
        let focusGeneration = workspace.layerFocus.generation
        guard let layers = workspace.config?.layers, layers.indices.contains(target),
              let overview = workspace.overviews(in: DesktopModel.shared.allWindows()).first(where: { $0.index == target })
        else { return }

        // Windows on another desktop of their display come to the one it
        // shows, less the ones the layer keeps put away.
        let displays = WindowTiler.getDisplaySpaces()
        let tucked = LayerStage.shared.tucked(layers[target].id)
        var carries: [(wid: UInt32, pid: Int32, to: Int)] = []
        for window in overview.windows where !tucked.contains(window.wid) {
            switch window.spot {
            case .at(.desktop), .parked(desktop: _?), .hidden:
                break
            default:
                continue
            }
            guard let entry = DesktopModel.shared.windows[window.wid], entry.spaceIds.count == 1,
                  let display = displays.first(where: { $0.spaces.contains { $0.id == entry.spaceIds[0] } }),
                  display.currentSpaceId != entry.spaceIds[0]
            else { continue }
            carries.append((window.wid, entry.pid, display.currentSpaceId))
        }
        if carries.count > Self.carryLimit {
            DiagnosticLog.shared.warn("LayerPreview: \(carries.count) windows away; carrying the first \(Self.carryLimit)")
            carries = Array(carries.prefix(Self.carryLimit))
        }

        guard !carries.isEmpty else {
            switchTo(target)
            return
        }
        LayerBezel.shared.acknowledge(carries.count == 1 ? "Bringing 1 window" : "Bringing \(carries.count) windows")
        DispatchQueue.global(qos: .userInitiated).async {
            for carry in carries {
                guard DispatchQueue.main.sync(execute: { workspace.layerFocus.generation == focusGeneration }) else { return }
                // A hidden app's windows can't be carried; show it first.
                if let app = NSRunningApplication(processIdentifier: carry.pid), app.isHidden {
                    guard DispatchQueue.main.sync(execute: {
                        guard workspace.layerFocus.generation == focusGeneration else { return false }
                        _ = app.unhide()
                        return true
                    }) else { return }
                    let deadline = Date().addingTimeInterval(1.0)
                    while app.isHidden, Date() < deadline { usleep(30_000) }
                }
                // Exit may have happened while waiting for the app to unhide.
                guard DispatchQueue.main.sync(execute: { workspace.layerFocus.generation == focusGeneration }) else { return }
                if case .failed(let reason) = WindowSpaceCarry.carry(wid: carry.wid, pid: carry.pid, to: carry.to) {
                    DiagnosticLog.shared.warn("LayerPreview: couldn't carry wid=\(carry.wid): \(reason)")
                }
            }
            DispatchQueue.main.async {
                guard workspace.layerFocus.generation == focusGeneration else { return }
                DesktopModel.shared.refreshNow()
                self.switchTo(target)
            }
        }
    }

    private func switchTo(_ target: Int) {
        WorkspaceManager.shared.focusLayer(index: target)
    }

    /// Also used by Exit Layers to release captured input immediately.
    func dismiss() { close() }

    private func close() {
        unfreeze()
        captureTask?.cancel()
        captureTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.isFrozen == false else { return }
            panel.orderOut(nil)
        })
    }

    private func unfreeze() {
        lock.lock()
        generation += 1
        frozen = false
        pending = false
        showing = false
        armed = false
        lock.unlock()
        idle?.cancel()
        idle = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
    }

    /// Ends the freeze once no key has touched it for `idleLimit`.
    private func extendIdle(_ generation: Int) {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            DiagnosticLog.shared.info("LayerPreview: no key in \(Int(Self.idleLimit)) s — closing")
            self.close()
        }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit, execute: item)
    }

    /// Another app came forward, a click elsewhere: the keys are its now.
    private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lock.lock()
        let settled = frozen && Date().timeIntervalSince(frozenAt) > Self.activationGrace
        lock.unlock()
        if settled { close() }
    }

    // MARK: Captures

    /// Captures `wids` a little larger than a tile can get, keeping their
    /// shape, and redraws as each lands. A window ScreenCaptureKit can't
    /// reach keeps its app icon.
    private func capture(_ wids: [UInt32]) {
        guard !wids.isEmpty, WindowCapture.hasScreenRecordingAccess() else { return }
        let previous = captureTask
        captureTask = Task { [weak self] in
            await previous?.value
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            else { return }
            await withTaskGroup(of: (UInt32, CGImage?).self) { group in
                for wid in wids {
                    guard let window = content.windows.first(where: { $0.windowID == wid }) else { continue }
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        let configuration = SCStreamConfiguration()
                        let scale = min(1, 900 / max(window.frame.width, window.frame.height, 1))
                        let backing = CGFloat(filter.pointPixelScale)
                        configuration.width = max(1, Int(window.frame.width * scale * backing))
                        configuration.height = max(1, Int(window.frame.height * scale * backing))
                        configuration.scalesToFit = true
                        configuration.preservesAspectRatio = true
                        configuration.showsCursor = false
                        configuration.ignoreShadowsSingleWindow = true
                        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                        return (wid, image)
                    }
                }
                for await (wid, image) in group {
                    guard let image, !Task.isCancelled else { continue }
                    await MainActor.run { [weak self] in
                        guard let self, self.isFrozen else { return }
                        let picture = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                        self.captures[wid] = picture
                        self.fresh.insert(wid)
                        self.previewView?.setCapture(picture, for: wid)
                    }
                }
            }
        }
    }

    // MARK: Panel

    private func ensurePanel() -> (NSPanel, LayerPreviewView) {
        if let panel, let previewView { return (panel, previewView) }
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let view = LayerPreviewView(frame: CGRect(origin: .zero, size: frame.size))
        view.onExit = { WorkspaceManager.shared.exitLayers() }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // Just under the bezel, which a commit shows as this fades.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        // Closed or off the screen while frozen (ordered out, its app
        // hidden): the freeze ends with it.
        for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak panel] _ in
                guard let self, let panel, self.isFrozen else { return }
                if name == NSWindow.willCloseNotification || !panel.isVisible { self.close() }
            })
        }
        self.panel = panel
        self.previewView = view
        return (panel, view)
    }

    // MARK: Event tap

    /// Created on the first arm and left disabled between flips.
    private func ensureTap() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        var mask = CGEventMask(0)
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            DiagnosticLog.shared.warn("LayerPreview: couldn't install the key tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        if let source { EventTapThread.overlay.add(source: source) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private enum Key {
        static let space: Int64 = 49
        static let returnKey: Int64 = 36
        static let enter: Int64 = 76
        static let escape: Int64 = 53
        static let arrows: [Int64: LayerSlots.Direction] = [123: .left, 124: .right, 125: .down, 126: .up]
        static let tab: Int64 = 48
        static let delete: Int64 = 51
        static let forwardDelete: Int64 = 117
        static let l: Int64 = 37
        /// Key codes of 1–9, on the top row and the numpad, to their digit.
        static let digits: [Int64: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
        ]
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let preview = Unmanaged<LayerPreview>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Stay usable: Escape has to keep working while frozen.
            if preview.isFrozen, let tap = preview.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let chord = flags.contains(.maskCommand) && flags.contains(.maskAlternate)
        preview.lock.lock()
        let armed = preview.armed
        let frozen = preview.frozen
        let holds = preview.pending || preview.showing
        let generation = preview.generation
        preview.lock.unlock()

        // Frozen with no panel up: end it on main, and let this through.
        func endAndPass() -> Unmanaged<CGEvent>? {
            DispatchQueue.main.async {
                if preview.isCurrent(generation) { preview.close() }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            if armed, !frozen, !chord {
                preview.lock.lock()
                preview.armed = false
                preview.lock.unlock()
                DispatchQueue.main.async {
                    if !preview.isFrozen, let tap = preview.eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
                }
            }
            if frozen, !holds, !chord { return endAndPass() }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if !frozen {
            guard armed, chord, key == Key.space else { return Unmanaged.passUnretained(event) }
            preview.lock.lock()
            preview.frozen = true
            preview.pending = true
            preview.showing = false
            preview.frozenAt = Date()
            preview.generation += 1
            let frozenGeneration = preview.generation
            preview.lock.unlock()
            DispatchQueue.main.async { preview.freeze(frozenGeneration) }
            return nil
        }
        guard holds else { return endAndPass() }

        // Desktop navigation and the app switcher must remain an escape path
        // even while the preview owns its editing keys.
        if passesSystemNavigation(key: key, flags: flags) { return endAndPass() }

        // Frozen: every key stops here, so nothing types into the app
        // underneath and ⌘⌥Space doesn't open Finder's search. ⌘⌥ arrows
        // and digits browse; bare arrows pick, a bare digit sends, bare
        // Space puts away or brings back, bare L steps the layout. Any other
        // mix does nothing, so Space with ⌘⌥ still down doesn't toggle.
        guard !isRepeat || Key.arrows[key] != nil || key == Key.tab else { return nil }
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        let browsing = modifiers == [.maskCommand, .maskAlternate]
        let bare = modifiers.isEmpty
        let backward = modifiers == .maskShift
        DispatchQueue.main.async {
            guard preview.isCurrent(generation) else { return }
            preview.extendIdle(generation)
            if let direction = Key.arrows[key] {
                if browsing { preview.browse(direction) } else if bare { preview.previewView?.pick(toward: direction) }
                return
            }
            if let digit = Key.digits[key] {
                if browsing { preview.browse(toSlot: digit) } else if bare { preview.send(toSlot: digit) }
                return
            }
            switch key {
            case Key.returnKey, Key.enter: preview.commit()
            case Key.escape:
                if modifiers == .maskShift { WorkspaceManager.shared.exitLayers() }
                else { preview.close() }
            case Key.tab: preview.previewView?.pickNext(backward: backward)
            case Key.delete, Key.forwardDelete: preview.removePicked()
            case Key.space where bare: preview.togglePicked()
            case Key.l where bare: preview.cycleLayout()
            default: break
            }
        }
        return nil
    }

    static func passesSystemNavigation(key: Int64, flags: CGEventFlags) -> Bool {
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return (modifiers == .maskControl && Key.arrows[key] != nil)
            || (key == Key.tab && (modifiers == .maskCommand || modifiers == [.maskCommand, .maskShift]))
            || (key == Key.escape && modifiers == [.maskCommand, .maskAlternate])
    }
}

// MARK: - Preview View

/// The frozen layer: its pad slot, name, chord and layout along the top,
/// its windows in rows under it, each drawn at its own shape. The ones it
/// keeps put away are dimmed; a note says where a window is when that isn't
/// here. The ones beyond its entries have a dashed edge. Entries that
/// matched no window are named along the foot.
final class LayerPreviewView: NSView {
    var onExit: (() -> Void)?
    private lazy var exitButton: NSButton = {
        let button = NSButton(title: "Exit Layers", target: self, action: #selector(exitLayers))
        button.bezelStyle = .rounded
        button.toolTip = "Restore windows and leave layer focus (Shift–Escape)."
        button.setAccessibilityLabel("Exit Layers")
        addSubview(button)
        return button
    }()

    @objc private func exitLayers() { onExit?() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        _ = exitButton
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        _ = exitButton
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let button = exitButton
        button.sizeToFit()
        button.frame.origin = CGPoint(x: max(16, bounds.width - button.frame.width - 32), y: 34)
    }
    private struct Tile {
        let window: LayerOverview.Window
        let icon: NSImage?
        let aspect: CGFloat
        /// Shown beyond the layer's entries (its scene), or kept put away
        /// without one.
        let extra: Bool
        var rect: CGRect = .zero
    }

    private var label = ""
    private var slot: Int?
    private var chord: String?
    private var layerLayout: String?
    private var filled: Set<Int> = []
    private var tiles: [Tile] = []
    private var missing: [String] = []
    /// What the layer keeps put away (`LayerStage.tucked`).
    private var tucked: Set<UInt32> = []
    /// Kept between freezes, so a window shows its last shot at once while a
    /// fresh one comes in. `fresh` is what this freeze has captured.
    private var captures: [UInt32: NSImage] = [:]
    private var fresh: Set<UInt32> = []
    /// The window the keys act on: the front one until an arrow, Tab or the
    /// pointer picks another.
    private(set) var picked: UInt32?
    private var note: String?
    private var noteClear: DispatchWorkItem?

    private static let coral = NSColor(srgbRed: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255, alpha: 1)
    private static let ink = NSColor(white: 0.95, alpha: 1)
    private static let dim = NSColor(white: 0.95, alpha: 0.5)
    private static let hairline = NSColor(white: 1, alpha: 0.14)
    private static let captionHeight: CGFloat = 26

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A new freeze or another layer: the next update picks the front window.
    func resetPick() {
        picked = nil
    }

    /// `extras` are what the layer shows beyond its entries, `tucked` what it
    /// keeps put away.
    func update(
        overview: LayerOverview,
        extras: [LayerOverview.Window],
        tucked: Set<UInt32>,
        filled: Set<Int>,
        captures: [UInt32: NSImage]
    ) {
        let pickedAt = tiles.firstIndex { $0.window.wid == picked }
        label = overview.label
        slot = overview.slot
        chord = LayerOverview.chord(forIndex: overview.index)
        layerLayout = overview.layout
        self.filled = filled
        self.tucked = tucked
        self.captures = captures
        let windows = DesktopModel.shared.windows
        func tile(_ window: LayerOverview.Window, extra: Bool) -> Tile {
            let entry = windows[window.wid]
            // A hidden app's window can read 1×1 until AX gives its frame.
            var aspect: CGFloat = 1.6
            if let frame = entry?.frame, frame.w > 40, frame.h > 40 {
                aspect = CGFloat(frame.w / frame.h)
            }
            let icon = entry.flatMap { Self.icon(for: $0.pid) }
            return Tile(window: window, icon: icon, aspect: min(max(aspect, 0.4), 4), extra: extra)
        }
        tiles = overview.windows.map { tile($0, extra: false) } + extras.map { tile($0, extra: true) }
        missing = overview.entries.compactMap { entry in
            entry.missing.map { "\(entry.name) · \($0.note ?? "")" }
        }
        // Keep the pick; if it left, the tile that took its place; with
        // none yet, the front window.
        if let pickedAt, !tiles.contains(where: { $0.window.wid == picked }) {
            picked = tiles.isEmpty ? nil : tiles[min(pickedAt, tiles.count - 1)].window.wid
        } else if picked == nil {
            picked = tiles.min { (windows[$0.window.wid]?.zIndex ?? .max) < (windows[$1.window.wid]?.zIndex ?? .max) }?.window.wid
        }
        layoutTiles()
        needsDisplay = true
    }

    func pickNext(backward: Bool) {
        guard !tiles.isEmpty else { return }
        let at = tiles.firstIndex { $0.window.wid == picked } ?? 0
        picked = tiles[(at + (backward ? tiles.count - 1 : 1)) % tiles.count].window.wid
        needsDisplay = true
    }

    /// An arrow: the nearest tile that way (`neighbour`). At the edge the
    /// pick stays.
    func pick(toward direction: LayerSlots.Direction) {
        guard let at = tiles.firstIndex(where: { $0.window.wid == picked }) else {
            picked = tiles.first?.window.wid
            needsDisplay = true
            return
        }
        guard let next = Self.neighbour(of: at, in: tiles.map(\.rect), toward: direction) else { return }
        picked = tiles[next].window.wid
        needsDisplay = true
    }

    /// The rect in `rects` an arrow goes to from `rects[index]`: of the ones
    /// whose centre lies that way, one that shares its row (or column for
    /// up and down) first, then the nearest, counting a step aside twice.
    /// Nil at the edge. Rects are flipped, y growing down.
    nonisolated static func neighbour(of index: Int, in rects: [CGRect], toward direction: LayerSlots.Direction) -> Int? {
        guard rects.indices.contains(index) else { return nil }
        let from = rects[index]
        var best: (index: Int, lined: Bool, distance: CGFloat)?
        for (i, rect) in rects.enumerated() where i != index {
            let along: CGFloat, aside: CGFloat, lined: Bool
            switch direction {
            case .left, .right:
                along = direction == .right ? rect.midX - from.midX : from.midX - rect.midX
                aside = abs(rect.midY - from.midY)
                lined = rect.minY < from.maxY && rect.maxY > from.minY
            case .up, .down:
                along = direction == .down ? rect.midY - from.midY : from.midY - rect.midY
                aside = abs(rect.midX - from.midX)
                lined = rect.minX < from.maxX && rect.maxX > from.minX
            }
            guard along > 0 else { continue }
            let distance = along + 2 * aside
            if let current = best {
                if current.lined && !lined { continue }
                if current.lined == lined && current.distance <= distance { continue }
            }
            best = (i, lined, distance)
        }
        return best?.index
    }

    /// Put away: drawn dimmed. The rest shows when the layer is moved into,
    /// wherever it is now.
    func isAway(_ wid: UInt32) -> Bool {
        tucked.contains(wid)
    }

    /// Where the window on `wid`'s tile is.
    func spot(of wid: UInt32) -> LayerOverview.Spot? {
        tiles.first { $0.window.wid == wid }?.window.spot
    }

    /// After Space: what the layer keeps put away.
    func setChoices(tucked: Set<UInt32>) {
        self.tucked = tucked
        needsDisplay = true
    }

    /// A line under the name for a moment, saying what a key did.
    func flash(_ text: String) {
        note = text
        noteClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            self?.note = nil
            self?.needsDisplay = true
        }
        noteClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: clear)
        needsDisplay = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { pick(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { pick(at: convert(event.locationInWindow, from: nil)) }

    private func pick(at point: CGPoint) {
        guard let tile = tiles.first(where: { $0.rect.insetBy(dx: -8, dy: -8).contains(point) }),
              tile.window.wid != picked else { return }
        picked = tile.window.wid
        needsDisplay = true
    }

    /// Loading an app's icon costs tens of milliseconds the first time.
    private static var icons: [pid_t: NSImage] = [:]
    private static func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    func setCapture(_ image: NSImage, for wid: UInt32) {
        captures[wid] = image
        if let tile = tiles.first(where: { $0.window.wid == wid }) {
            setNeedsDisplay(tile.rect.insetBy(dx: -2, dy: -2))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTiles()
    }

    // MARK: Layout

    private var stageRect: CGRect {
        let top: CGFloat = 148
        let bottom: CGFloat = missing.isEmpty ? 56 : 88
        return CGRect(x: 72, y: top, width: bounds.width - 144, height: bounds.height - top - bottom)
    }

    private func layoutTiles() {
        let rects = Self.rows(aspects: tiles.map(\.aspect), in: stageRect, gap: 28, caption: Self.captionHeight)
        for i in tiles.indices { tiles[i].rect = rects[i] }
    }

    /// Mission Control's rows: windows in order, split into the number of
    /// rows that draws them largest, all at one height, each at its own
    /// shape. Captions sit under each row.
    static func rows(aspects: [CGFloat], in area: CGRect, gap: CGFloat, caption: CGFloat) -> [CGRect] {
        guard !aspects.isEmpty, area.width > 0, area.height > 0 else { return aspects.map { _ in .zero } }
        let maxHeight = area.height * 0.62
        var best: (height: CGFloat, rows: [[Int]])?
        for count in 1...aspects.count {
            let rows = split(aspects, into: count)
            let widest = rows.map { row -> CGFloat in
                let span: CGFloat = row.reduce(0) { $0 + aspects[$1] }
                let room: CGFloat = area.width - gap * CGFloat(row.count - 1)
                return room / span
            }.min() ?? 0
            let tallest = (area.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count) - caption
            let height = min(widest, tallest, maxHeight)
            guard height > 0 else { continue }
            if best == nil || height > best!.height * 1.001 { best = (height, rows) }
        }
        guard let best else { return aspects.map { _ in .zero } }

        var rects = Array(repeating: CGRect.zero, count: aspects.count)
        let rowHeight = best.height + caption
        let total = rowHeight * CGFloat(best.rows.count) + gap * CGFloat(best.rows.count - 1)
        var y = area.minY + (area.height - total) / 2
        for row in best.rows {
            let width = row.reduce(0) { $0 + aspects[$1] * best.height } + gap * CGFloat(row.count - 1)
            var x = area.minX + (area.width - width) / 2
            for i in row {
                rects[i] = CGRect(x: x, y: y, width: aspects[i] * best.height, height: best.height).integral
                x += aspects[i] * best.height + gap
            }
            y += rowHeight + gap
        }
        return rects
    }

    /// `aspects` in order, in `count` runs of about equal width.
    private static func split(_ aspects: [CGFloat], into count: Int) -> [[Int]] {
        let target = aspects.reduce(0, +) / CGFloat(count)
        var rows: [[Int]] = [[]]
        var width: CGFloat = 0
        for (i, aspect) in aspects.enumerated() {
            let left = aspects.count - i
            let rowsLeft = count - rows.count
            let over = width + aspect / 2 > target && !rows[rows.count - 1].isEmpty
            if rowsLeft > 0, over || left <= rowsLeft {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(i)
            width += aspect
        }
        return rows.filter { !$0.isEmpty }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.04, alpha: 0.9).setFill()
        bounds.fill()

        drawHeader()
        for tile in tiles where tile.rect.insetBy(dx: -6, dy: -6 - Self.captionHeight).intersects(dirtyRect) {
            drawTile(tile)
        }
        if tiles.isEmpty {
            text("No windows", font: .systemFont(ofSize: 15, weight: .medium), color: Self.dim)
                .draw(centeredIn: stageRect)
        }
        if !missing.isEmpty {
            let line = text(missing.joined(separator: "     "), font: .systemFont(ofSize: 12, weight: .medium), color: Self.dim)
            line.draw(at: CGPoint(x: (bounds.width - line.size().width) / 2, y: bounds.height - 64))
        }
        let space = picked.map(isAway) == true ? "␣ Show" : "␣ Put away"
        let hints = ["↵ Move in", space, "L Layout", "1–9 Send", "⌫ Remove", "⌘⌥ ← → ↑ ↓ Layers", "esc Cancel", "⇧esc Exit Layers"]
        let keys = text(hints.joined(separator: "     "), font: .systemFont(ofSize: 11, weight: .medium), color: Self.dim)
        keys.draw(at: CGPoint(x: (bounds.width - keys.size().width) / 2, y: bounds.height - 34))
    }

    private func drawHeader() {
        // The pad, small, fixed at the centre so browsing never moves it: the
        // lit slot in coral, filled ones in ink. The name sits centred under,
        // its chord and layout after it.
        let cell: CGFloat = 12, gap: CGFloat = 3
        let padWidth = cell * 3 + gap * 2
        let origin = CGPoint(x: round((bounds.width - padWidth) / 2), y: 44)
        for n in 1...9 {
            let r = CGRect(
                x: origin.x + CGFloat((n - 1) % 3) * (cell + gap),
                y: origin.y + CGFloat((n - 1) / 3) * (cell + gap),
                width: cell, height: cell
            )
            let color: NSColor = n == slot ? Self.coral : filled.contains(n) ? NSColor(white: 1, alpha: 0.32) : NSColor(white: 1, alpha: 0.08)
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let metaFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let title = text(label, font: titleFont, color: Self.ink)
        let at = CGPoint(x: round((bounds.width - title.size().width) / 2), y: origin.y + padWidth + 12)
        title.draw(at: at)
        let meta = text([chord, LayerLayout.title(layerLayout)].compactMap { $0 }.joined(separator: " · "), font: metaFont, color: Self.dim)
        meta.draw(at: CGPoint(x: at.x + title.size().width + 12, y: at.y + round(titleFont.ascender - metaFont.ascender)))
        if let note {
            let line = text(note, font: .systemFont(ofSize: 13, weight: .medium), color: Self.coral)
            line.draw(at: CGPoint(x: round((bounds.width - line.size().width) / 2), y: origin.y + padWidth + 42))
        }
    }

    private func drawTile(_ tile: Tile) {
        let rect = tile.rect
        let wid = tile.window.wid
        let away = isAway(wid)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        rect.fill()
        if let image = captures[wid] {
            image.draw(in: Self.aspectFit(image.size, in: rect), from: .zero, operation: .sourceOver,
                       fraction: away ? 0.55 : 1, respectFlipped: true, hints: nil)
        } else if let icon = tile.icon {
            let side = min(rect.width, rect.height) * 0.36
            icon.draw(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: away ? 0.5 : 0.9, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()

        // A dashed edge on what the layer shows beyond its entries.
        let edge = wid == picked
            ? NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
            : path
        edge.lineWidth = wid == picked ? 2 : 1
        if tile.extra { edge.setLineDash([5, 4], count: 2, phase: 0) }
        (wid == picked ? Self.coral : Self.hairline).setStroke()
        edge.stroke()

        // Where it is, when that isn't here, or that the layer keeps it put away.
        let note: String? = tucked.contains(wid) ? "Put away" : tile.window.spot.note
        if let note {
            let badge = text(note, font: .systemFont(ofSize: 11, weight: .semibold), color: Self.ink)
            let size = badge.size()
            let plate = CGRect(x: rect.maxX - size.width - 18, y: rect.minY + 8, width: size.width + 12, height: size.height + 6)
            NSColor(white: 0.02, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 4, yRadius: 4).fill()
            badge.draw(at: CGPoint(x: plate.minX + 6, y: plate.minY + 3))
        }

        // App icon and title under it.
        let iconSide: CGFloat = 16
        var x = rect.minX
        if let icon = tile.icon {
            icon.draw(in: CGRect(x: x, y: rect.maxY + 7, width: iconSide, height: iconSide),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSide + 6
        }
        let name = tile.window.title.isEmpty ? tile.window.app : tile.window.title
        let caption = text(name, font: .systemFont(ofSize: 12, weight: .medium), color: away ? Self.dim : Self.ink)
        caption.draw(with: CGRect(x: x, y: rect.maxY + 7, width: max(0, rect.maxX - x), height: 18),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private func text(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

private extension NSAttributedString {
    func draw(centeredIn rect: CGRect) {
        let size = size()
        draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
