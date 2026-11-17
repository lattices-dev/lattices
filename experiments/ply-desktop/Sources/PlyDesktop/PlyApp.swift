import AppKit
import OSLog
import SwiftUI

@main
struct PlyDesktopApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        do {
            let delegate = PlyAppDelegate(atlas: try PlyAtlas())
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ply’s artwork could not be loaded."
            alert.informativeText = "Rebuild Ply with script/build_and_run.sh. \(error.localizedDescription)"
            alert.runModal()
        }
    }
}

@MainActor
final class PlyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let atlas: PlyAtlas
    private let view: PlyView
    private let panel: PlyPanel
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.arach.lattices.ply-preview", category: "desktop")
    private var status: NSStatusItem?
    private var settle: DispatchWorkItem?
    private var selectedPose: PlyPose?
    private var greetingCount = 0
    private var workspaceOpenCount = 0
    private let workspacePopover = NSPopover()
    private let workspaces: PlyWorkspaceStore
    private let selfCheckPath: String?
    private let selfCheckDomain: String?

    init(atlas: PlyAtlas) {
        let args = ProcessInfo.processInfo.arguments
        let checkIndex = args.firstIndex(of: "--self-test")
        selfCheckPath = checkIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        selfCheckDomain = checkIndex == nil ? nil : "dev.arach.lattices.ply-selfcheck.\(UUID().uuidString)"
        defaults = selfCheckDomain.map { UserDefaults(suiteName: $0)! } ?? .standard
        let client = PlyLatticesClient.bundled()
        workspaces = PlyWorkspaceStore { request in
            // Native self-checks never mutate the user's workspace.
            if checkIndex != nil {
                return Data("{\"layers\":[],\"active\":null,\"focusActive\":false}".utf8)
            }
            guard let client else { throw PlyWorkspaceError.unavailable }
            return try await client.call(request)
        }
        self.atlas = atlas
        view = PlyView(atlas: atlas)
        panel = PlyPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.title = "Ply"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
        view.onHover = { [weak self] entered in
            guard let self else { return }
            self.settle?.cancel()
            self.view.show(entered && !self.workspacePopover.isShown ? .noticed : self.basePose)
        }
        view.onPress = { [weak self] in self?.openWorkspaces() }
        view.onDragStart = { [weak self] in
            self?.settle?.cancel()
            self?.workspacePopover.performClose(nil)
            self?.view.show(.noticed)
        }
        view.onDrop = { [weak self] in
            self?.placeOnScreen()
            self?.saveHome()
            self?.flash(.happy, for: 1.2, bounce: true)
        }
        view.onContext = { [weak self] event, host in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: host)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = atlas.image(.rest, size: 21)
        status?.button?.toolTip = "Ply — click your companion to switch workspaces"
        status?.button?.setAccessibilityLabel("Ply menu")
        status?.menu = makeMenu()
        workspacePopover.behavior = .transient
        workspacePopover.delegate = self
        workspacePopover.contentViewController = NSHostingController(rootView:
            PlyWorkspaceView(store: workspaces) { [weak self] in self?.workspacePopover.performClose(nil) })
        workspaces.onChange = { [weak self] phase in
            guard let self else { return }
            if case .success = phase { self.flash(.happy, for: 1.5, bounce: true) }
            else if self.workspacePopover.isShown { self.settle?.cancel(); self.view.show(phase.pose) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAccessibility), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshAccessibility()
        let size = defaults.object(forKey: "size") as? Double ?? 128
        resize(to: [96.0, 128.0, 176.0].contains(size) ? size : 128)
        if let saved = defaults.string(forKey: "home") { panel.setFrameOrigin(NSPointFromString(saved)) }
        else if let frame = NSScreen.screens.first?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.maxX - panel.frame.width - 28, y: frame.minY + 68))
        }
        placeOnScreen()
        if !defaults.bool(forKey: "hidden") || selfCheckPath != nil { show() }
        logger.info("Ply launched; desktop sprite ready")
        if let path = selfCheckPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.runSelfCheck(to: path) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        settle?.cancel()
        if let selfCheckDomain { defaults.removePersistentDomain(forName: selfCheckDomain) }
    }

    private var basePose: PlyPose { workspacePopover.isShown ? workspaces.phase.pose : (selectedPose ?? .rest) }

    @objc private func openWorkspaces() {
        workspaceOpenCount += 1
        if workspacePopover.isShown { workspacePopover.performClose(nil); return }
        show()
        // The companion commonly sits at the bottom edge. A side attachment
        // can extend below the physical screen on a nonactivating panel.
        let visible = panel.screen?.visibleFrame ?? .zero
        let edge: NSRectEdge = visible.maxY - panel.frame.maxY >= 460 ? .maxY : .minY
        workspacePopover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        Task { await workspaces.refresh() }
    }

    func popoverDidClose(_ notification: Notification) {
        workspaces.dismiss()
        settle?.cancel()
        // AppKit can still report isShown while delivering this callback.
        view.show(selectedPose ?? .rest)
    }

    private func greet() {
        greetingCount += 1
        flash(.happy, for: 1.2, bounce: true)
    }
    private func flash(_ pose: PlyPose, for seconds: TimeInterval, bounce: Bool = false) {
        settle?.cancel()
        view.show(pose, bounce: bounce)
        let next = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.view.show(self.basePose)
        }
        settle = next
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: next)
    }

    private func show() {
        defaults.set(false, forKey: "hidden")
        placeOnScreen()
        view.show(basePose)
        panel.orderFrontRegardless()
    }
    private func hide() {
        workspacePopover.performClose(nil)
        settle?.cancel()
        defaults.set(true, forKey: "hidden")
        panel.orderOut(nil)
    }
    private func resize(to size: Double) {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
        defaults.set(size, forKey: "size")
        placeOnScreen()
    }
    private func placeOnScreen() {
        let frame = PlyPlacement.clamped(panel.frame, to: NSScreen.screens.map(\.visibleFrame))
        panel.setFrame(frame, display: true)
    }
    private func saveHome() { defaults.set(NSStringFromPoint(panel.frame.origin), forKey: "home") }

    @objc private func screenChanged() { placeOnScreen(); saveHome() }
    @objc private func refreshAccessibility() {
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if view.reduceMotion { view.layer?.sublayers?.forEach { $0.removeAllAnimations() } }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Ply")
        menu.delegate = self
        populate(menu)
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "Ply · workspace companion", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        item("Switch workspace…", #selector(openWorkspaces), in: menu)
        item(panel.isVisible ? "Hide Ply" : "Show Ply", #selector(toggleVisibility), in: menu)
        item("Say hello", #selector(sayHello), in: menu)
        let sizeMenu = NSMenu(title: "Size")
        for (title, size) in [("Small", 96), ("Medium", 128), ("Large", 176)] {
            let choice = item(title, #selector(changeSize(_:)), in: sizeMenu)
            choice.tag = size
            choice.state = Int(panel.frame.width) == size ? .on : .off
        }
        let sizeParent = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu; menu.addItem(sizeParent)
        let expressions = NSMenu(title: "Expression")
        let automatic = item("React to me", #selector(chooseExpression(_:)), in: expressions)
        automatic.tag = -1; automatic.state = selectedPose == nil ? .on : .off
        expressions.addItem(.separator())
        for pose in PlyPose.allCases {
            let choice = item(pose.title, #selector(chooseExpression(_:)), in: expressions)
            choice.tag = pose.rawValue; choice.state = selectedPose == pose ? .on : .off
        }
        let expressionParent = NSMenuItem(title: "Expression", action: nil, keyEquivalent: "")
        expressionParent.submenu = expressions; menu.addItem(expressionParent)
        menu.addItem(.separator())
        item("Bring back into view", #selector(bringIntoView), in: menu)
        menu.addItem(.separator())
        let quit = item("Quit Ply", #selector(quit), in: menu)
        quit.keyEquivalent = "q"
    }
    @discardableResult private func item(_ title: String, _ action: Selector, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    @objc private func toggleVisibility() { panel.isVisible ? hide() : show() }
    @objc private func sayHello() { show(); greet() }
    @objc private func changeSize(_ sender: NSMenuItem) { resize(to: Double(sender.tag)); saveHome() }
    @objc private func chooseExpression(_ sender: NSMenuItem) {
        selectedPose = PlyPose(rawValue: sender.tag)
        settle?.cancel(); view.show(basePose); show()
    }
    @objc private func bringIntoView() {
        if let frame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.maxX - panel.frame.width - 28, y: frame.minY + 68))
        }
        show(); saveHome()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func runSelfCheck(to path: String) {
        var checks: [[String: Any]] = []
        func check(_ pass: Bool, _ name: String) { checks.append(["name": name, "pass": pass]) }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check(panel.isVisible && !panel.isOpaque && panel.backgroundColor.alphaComponent == 0, "Transparent native panel is visible")
        check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow, "Companion does not take keyboard focus")
        check(atlas.frames.count == 8 && atlas.alpha(at: CGPoint(x: 0.02, y: 0.02), pose: .rest) < 0.02, "Eight model-rendered poses have transparent margins")
        let origin = panel.frame.origin
        let before = greetingCount
        let openedBefore = workspaceOpenCount
        view.beginDrag(at: CGPoint(x: 400, y: 400), origin: origin)
        view.continueDrag(to: CGPoint(x: 402, y: 401)); view.endDrag()
        check(workspaceOpenCount == openedBefore + 1 && workspacePopover.isShown && panel.frame.origin == origin,
              "Small pointer movement opens the workspace picker")
        workspacePopover.performClose(nil)
        view.beginDrag(at: CGPoint(x: 400, y: 400), origin: origin)
        view.continueDrag(to: CGPoint(x: 340, y: 420))
        check(panel.frame.minX == origin.x - 60 && panel.frame.minY == origin.y + 20 && view.pose == .noticed, "Pickup moves the actual panel with an eager pose")
        view.endDrag()
        check(view.pose == .happy && greetingCount == before && workspaceOpenCount == openedBefore + 1 && defaults.string(forKey: "home") != nil, "Drop smiles, remembers placement, and does not open the picker")
        hide(); check(!panel.isVisible, "Hide removes the panel")
        show(); check(panel.isVisible, "Menu can restore the hidden companion")
        let menu = makeMenu()
        check(menu.items.contains { $0.title == "Quit Ply" } && menu.items.contains { $0.title == "Size" }, "Menu includes quit and size controls")
        view.reduceMotion = true; view.show(.thinking, bounce: true)
        check(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.contains("greeting") != true } == true, "Reduced Motion suppresses new bounce animations")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Showing and moving the companion preserves the frontmost app")
        let passed = checks.allSatisfy { $0["pass"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "windowID": panel.windowNumber, "scope": "Native panel lifecycle and shared event handlers; not OS input routing or real tool activity"]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { logger.error("Self-check report failed: \(error.localizedDescription, privacy: .public)") }
        NSApp.terminate(nil)
    }
}
