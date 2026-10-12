import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let shared = MenuBarController()

    /// Mini-Home popover: rail (~100pt) + pane, fixed size.
    static let popoverHeight: CGFloat = 430
    static let popoverWidth: CGFloat = 500

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var contextMenu: NSMenu?
    private weak var actionMenuItem: NSMenuItem?
    private weak var visitMenuItem: NSMenuItem?
    private weak var longMenuItem: NSMenuItem?

    var isPopoverShown: Bool {
        popover?.isShown == true
    }

    private override init() {
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = Self.menuBarIcon
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        contextMenu = buildContextMenu()
        contextMenu?.delegate = self
    }

    func warmUpPopover() {
        let popover = makePopover()
        _ = popover.contentViewController?.view
    }

    func dismissPopover() {
        popover?.performClose(nil)
    }

    /// Resize the menu-bar popover's content area.
    func setPopoverContentHeight(_ height: CGFloat) {
        guard let popover else { return }
        let size = NSSize(width: Self.popoverWidth, height: height)
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }

    private func showProjectsPopover() {
        guard let button = statusItem?.button else { return }
        let popover = makePopover()
        popover.contentSize = NSSize(
            width: Self.popoverWidth,
            height: Self.popoverHeight
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let window = pinPopoverToActiveSpace(popover)
        window?.sharingType = .readOnly
        window?.makeKey()
        DiagnosticLog.shared.info(
            "menuBar.popover shown=\(popover.isShown) visible=\(window?.isVisible == true) onScreen=\(window?.occlusionState.contains(.visible) == true) frame=\(window.map { NSStringFromRect($0.frame) } ?? "nil")"
        )
    }

    /// The status item is on every Space. `NSPopover` is not: it keeps the
    /// window on the Space where it was first ordered in, so a later left
    /// click on the current Space only toggles an off-screen panel.
    @discardableResult
    private func pinPopoverToActiveSpace(_ popover: NSPopover) -> NSWindow? {
        guard let window = popover.contentViewController?.view.window else { return nil }
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.orderFrontRegardless()
        return window
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No `guard let event` — action deliveries without a current event
        // (AX presses, synthetic triggers) must still open the popover.
        let eventType = NSApp.currentEvent?.type
        DiagnosticLog.shared.info(
            "menuBar.click event=\(eventType.map { "\($0.rawValue)" } ?? "nil") shown=\(popover?.isShown == true)"
        )

        if eventType == .rightMouseUp {
            CompanionAppsMenu.refresh()
            contextMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else if let shown = popover, shown.isShown {
            // `isShown` and `isVisible` stay true for a popover parked on
            // another Space. Closing that ghost is what makes left-click
            // look dead. Only dismiss a panel that is already on this Space.
            let alreadyHere = shown.contentViewController?.view.window?
                .occlusionState.contains(.visible) == true
            if alreadyHere {
                shown.performClose(sender)
            } else {
                let window = pinPopoverToActiveSpace(shown)
                if window?.occlusionState.contains(.visible) != true {
                    shown.performClose(sender)
                    showProjectsPopover()
                }
            }
        } else {
            showProjectsPopover()
        }
    }

    private func makePopover() -> NSPopover {
        if let popover { return popover }
        let timed = DiagnosticLog.shared.startTimed("makePopover")
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: MainView(scanner: ProjectScanner.shared))
        // .semitransient, not .transient: a menu-bar popover must survive the
        // app losing activation (menu-bar auto-hide reorders the status item
        // window, other apps retake focus) — .transient closes on any
        // deactivation, which made left-click appear to do nothing.
        popover.behavior = .semitransient
        // Keep resize of contentSize (Move expand/collapse) non-animated —
        // animating NSPopover + SwiftUI layout has crashed with nested material
        // resolve (EXC_BAD_ACCESS / stack guard) on recent macOS builds.
        popover.animates = false
        popover.contentSize = NSSize(
            width: Self.popoverWidth,
            height: Self.popoverHeight
        )
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        self.popover = popover
        DiagnosticLog.shared.finish(timed)
        return popover
    }

    func popoverWillShow(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            pinPopoverToActiveSpace(popover)
        }
        NotificationCenter.default.post(name: .latticesPopoverWillShow, object: nil)
        // Defer the activation-policy refresh until after the popover finishes
        // ordering in — flipping accessory→regular mid-show can dismiss a
        // transient popover before it ever renders.
        DispatchQueue.main.async { AppActivationCoordinator.shared.refresh() }
    }

    func popoverDidClose(_ notification: Notification) {
        DiagnosticLog.shared.info("menuBar.popover closed")
        AppActivationCoordinator.shared.refresh()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let actions: [(String, String, Selector)] = [
            ("Assistant", "⌘⇧A", #selector(menuAssistant)),
            ("Home", "", #selector(menuWorkspace)),
            ("Studio", "", #selector(menuLayout)),
            ("Layers…", "", #selector(menuEditor)),
            ("Command Bar", "", #selector(menuSearch)),
        ]
        for (title, shortcut, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if !shortcut.isEmpty {
                // Display-only; the actual hotkey is global.
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        FrontWindowPlacementMenu.attach(to: menu)
        CompanionAppsMenu.attach(to: menu)
        let machines = NSMenuItem(title: "Machines", action: nil, keyEquivalent: "")
        machines.submenu = NSMenu(title: "Machines")
        menu.addItem(machines)

        let long = NSMenuItem(title: "Long", action: #selector(menuLong), keyEquivalent: "")
        long.target = self
        menu.addItem(long)
        longMenuItem = long

        let visit = NSMenuItem(title: "Visiting Cursor", action: #selector(menuVisit), keyEquivalent: "")
        visit.target = self
        visit.isHidden = true
        menu.addItem(visit)
        visitMenuItem = visit

        let home = NSMenuItem(title: "Bring Cursor Home", action: #selector(menuCursorHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)

        menu.addItem(.separator())

        let cliActions: [(String, Selector)] = [
            ("Projects…", #selector(menuProjects)),
            ("Initialize Project in Terminal…", #selector(menuInitializeProject)),
            ("Launch Project in Terminal…", #selector(menuLaunchProject)),
        ]
        for (title, action) in cliActions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let runs = NSMenuItem(title: "Runs…", action: #selector(menuRuns), keyEquivalent: "")
        runs.target = self
        menu.addItem(runs)

        let activityLog = NSMenuItem(title: "Activity Log…", action: #selector(menuActivityLog), keyEquivalent: "")
        activityLog.target = self
        menu.addItem(activityLog)

        let update = NSMenuItem(title: "Update Lattices…", action: #selector(menuUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let action = NSMenuItem(title: actionMenuTitle(), action: #selector(menuAction), keyEquivalent: "")
        action.target = self
        menu.addItem(action)
        actionMenuItem = action

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Help & Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Lattices", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func menuAssistant() { AssistantAccess.show() }
    @objc private func menuWorkspace() { ScreenMapWindowController.shared.showPage(.home) }
    @objc private func menuEditor() { EditorWindowController.shared.show() }
    @objc private func menuLayout() { ScreenMapWindowController.shared.showPage(.overview) }
    @objc private func menuSearch() { UnifiedCommandBarWindow.shared.toggle(mode: .search) }
    @objc private func menuProjects() { DispatchQueue.main.async { self.showProjectsPopover() } }
    @objc private func menuInitializeProject() { CliActionLauncher.initializeProjectInTerminal() }
    @objc private func menuLaunchProject() { CliActionLauncher.launchProjectInTerminal() }
    @objc private func menuCursorHome() { PointerHome.bringHome() }
    @MainActor @objc private func menuLong() { DesktopLong.shared.shown ? DesktopLong.shared.hide() : DesktopLong.shared.show() }
    @objc private func menuVisit() { VisitController.shared.arm(!VisitController.shared.armed) }
    private func refreshPointerItems() {
        longMenuItem?.state = MainActor.assumeIsolated { DesktopLong.shared.shown } ? .on : .off
        visitMenuItem?.isHidden = VisitTrust.shared.list().isEmpty
        visitMenuItem?.state = VisitController.shared.armed ? .on : .off
    }
    @objc private func menuRuns() { ScreenMapWindowController.shared.showPage(.runs) }
    @objc private func menuActivityLog() { ScreenMapWindowController.shared.showPage(.activity) }
    @MainActor @objc private func menuUpdate() { AppUpdater.shared.promptForUpdate() }

    private func actionMenuTitle() -> String {
        ActionProduct.isInstalled ? "Open Action" : "Install Action…"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        actionMenuItem?.title = actionMenuTitle()
        refreshPointerItems()
        if let submenu = menu.items.first(where: { $0.title == "Machines" })?.submenu {
            submenu.removeAllItems()
            for row in BrowseMenu.machinesSection().filter({ $0.title.hasPrefix("Visit ") || $0.title.hasPrefix("Bring everything to ") }) {
                let item = NSMenuItem(title: row.title, action: #selector(menuMachineAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = row.action
                submenu.addItem(item)
            }
        }
    }

    @objc private func menuMachineAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    @objc private func menuAction() {
        if ActionProduct.isInstalled {
            ActionProduct.open()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Action?"
        alert.informativeText = "Action is native computer-use for macOS — observe, act, and record through a local agent. Lattices will download the latest signed release and install it to /Applications."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if ActionProduct.install() {
            let started = NSAlert()
            started.alertStyle = .informational
            started.messageText = "Installing Action"
            started.informativeText = "The download is running in the background. Action will open when it finishes — grant Accessibility and Screen Recording when prompted."
            started.addButton(withTitle: "OK")
            started.runModal()
        } else {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Could Not Start the Installer"
            failed.informativeText = "The lattices CLI was not found on this machine. Install Action manually from lattices.dev/action."
            failed.addButton(withTitle: "Open lattices.dev/action")
            failed.addButton(withTitle: "Cancel")
            if failed.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(ActionProduct.siteURL)
            }
        }
    }

    @objc private func menuSettings() { SettingsWindowController.shared.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private static let menuBarIcon: NSImage = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let pad: CGFloat = 2
            let gap: CGFloat = 1.5
            let cellSize = (size - 2 * pad - 2 * gap) / 3
            let solidCells: Set<Int> = [0, 3, 6, 7, 8]

            for row in 0..<3 {
                for column in 0..<3 {
                    let index = row * 3 + column
                    let x = pad + CGFloat(column) * (cellSize + gap)
                    let y = pad + CGFloat(row) * (cellSize + gap)
                    let rect = NSRect(x: x, y: y, width: cellSize, height: cellSize)

                    if solidCells.contains(index) {
                        NSColor.black.setFill()
                    } else {
                        NSColor.black.withAlphaComponent(0.25).setFill()
                    }
                    let path = NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
                    path.fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
