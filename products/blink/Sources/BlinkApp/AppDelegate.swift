import AppKit
import BlinkCore
import BlinkPeer
import HudsonObservability
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var contextMenu: NSMenu!
    private var store: NoteStore!
    private var panelManager: PanelManager!
    private var model: AppModel!
    private let readerLayer = ReaderLayer()
    private var settingsWindow: NSWindow?
    private var guideWindow: NSWindow?
    private var commandPaletteController: BlinkCommandPaletteController?
    private var activityCatalog: BlinkActivityCatalog?
    private var commandRequestObserver: NSObjectProtocol?
    private var notesWatcher: DirectoryWatcher?
    private var peerServer: BlinkLANPeerServer?
    private var peerStartupFailure: String?
    private var socketServer: BlinkSocketServer?
    private var socketNoteObservers: [NSObjectProtocol] = []
    private let peerSyncStatus = PeerSyncStatus()
    private let log = HudLogger(category: "blink.app")

    static func notesDirectory() -> URL {
        BlinkPaths.notes()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HudLoggerSinks.install(HudLogStore.shared)
        log.info("[BLINK] booted", metadata: ["milestone": "M1"])
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        store = NoteStore(
            fileStore: NoteFileStore(
                directory: Self.notesDirectory(),
                ledger: NoteEditLedger(fileURL: BlinkPaths.edits())
            ),
            tombstoneStore: BlinkTombstoneStore(fileURL: BlinkPaths.tombstones())
        )

        startPeerServer()
        panelManager = PanelManager(store: store)
        startSocketServer()
        model = AppModel(store: store, panelManager: panelManager)
        panelManager.onWorkspaceScopeRequested = { [weak self] scope in
            self?.model.selectWorkspace(scope)
        }
        panelManager.startObservingStore()
        readerLayer.onKeep = { [weak self] text in
            Task { await self?.model.createNote(content: text, initialMode: "read") }
        }
        configureDiscovery()
        commandRequestObserver = NotificationCenter.default.addObserver(
            forName: .blinkCommandPaletteRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleCommandPalette(from: nil)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveDeskCommand(_:)),
            name: BlinkDeskCommand.notificationName,
            object: nil
        )

        // The filesystem is the API: external writers (the blink CLI, agents)
        // touch the Notes directory; reconcile diffs disk against memory and
        // posts the same notifications in-app mutations do, so the popover and
        // open panels pick external changes up live.
        notesWatcher = DirectoryWatcher(directory: Self.notesDirectory()) { [weak self] in
            guard let self else { return }
            Task {
                let diff = await self.store.reconcile()
                if !diff.isEmpty {
                    self.log.info(
                        "[BLINK] external changes reconciled",
                        metadata: [
                            "created": "\(diff.created.count)",
                            "updated": "\(diff.updated.count)",
                            "deleted": "\(diff.deleted.count)",
                            "tombstoneFailures": "\(diff.tombstoneFailures.count)",
                        ]
                    )
                }
            }
        }

        // Light/dark: resolve the config's appearance axis before the first
        // theme pass, and re-theme AppKit surfaces on a system-driven flip
        // (the SwiftUI popover observes AppearanceManager itself).
        AppearanceManager.shared.apply(BlinkConfigStore.shared.config.appearance)
        AppearanceManager.shared.onChange = { [weak self] _ in
            self?.panelManager.applyTheme(BlinkConfigStore.shared.config)
            self?.readerLayer.applyTheme(BlinkConfigStore.shared.config)
        }

        // Agent-first config: hot-apply file edits to every live surface.
        BlinkConfigStore.shared.onChange = { [weak self] config in
            // Appearance first, so applyTheme paints the resolved scheme.
            AppearanceManager.shared.apply(config.appearance)
            self?.panelManager.applyTheme(config)
            self?.readerLayer.applyTheme(config)
            CompanionMenuBarVisibility.shared.alwaysShow = config.behavior.alwaysShowMenuBarIcon
            self?.applyHotkeys(config)
            self?.applyLoginItem(config)
            self?.updatePeerServer()
            // Reflect an appearance change (or any state) in the menu checkmarks.
            self?.contextMenu = self?.buildContextMenu()
        }

        Task {
            await panelManager.restoreSession()
            await model.start()
            panelManager.applyTheme(BlinkConfigStore.shared.config)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = BlinkIcon.menuBar(armed: false)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        CompanionMenuBarVisibility.shared.usePreference(alwaysShow: BlinkConfigStore.shared.config.behavior.alwaysShowMenuBarIcon) { value in
            guard BlinkConfigStore.shared.config.behavior.alwaysShowMenuBarIcon != value else { return }
            BlinkConfigStore.shared.update { $0.behavior.alwaysShowMenuBarIcon = value }
        }
        CompanionMenuBarVisibility.shared.onChange = { [weak self] visible in self?.statusItem?.isVisible = visible }
        statusItem.isVisible = CompanionMenuBarVisibility.shared.isVisible
        contextMenu = buildContextMenu()

        applyHotkeys(BlinkConfigStore.shared.config)
        applyLoginItem(BlinkConfigStore.shared.config)
        if !CompanionMenuBarVisibility.shared.isVisible { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Accessory apps do not show a menu bar, but AppKit still uses the main
    /// menu's key equivalents to route standard editing actions through the
    /// responder chain. Without this menu, WKWebView never receives them.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Canvas")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        func appItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags = .command
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            item.keyEquivalentModifierMask = modifiers
            appMenu.addItem(item)
        }

        appItem("Commands…", action: #selector(menuCommands), keyEquivalent: "k")
        appItem(
            "Help & Shortcuts",
            action: #selector(menuGuide),
            keyEquivalent: "?",
            modifiers: [.command]
        )
        appMenu.addItem(.separator())
        appItem("Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appItem("Quit Canvas", action: #selector(menuQuit), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        func addItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags = .command
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = nil
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }

        addItem("Undo", action: Selector(("undo:")), keyEquivalent: "z")
        addItem(
            "Redo", action: Selector(("redo:")), keyEquivalent: "z", modifiers: [.command, .shift]
        )
        editMenu.addItem(.separator())
        addItem("Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        addItem("Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        addItem("Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        addItem("Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// Sync the SMAppService login item with config. Only touches the service
    /// when the desired state differs from the registered one, so launch never
    /// spams registration calls (or re-prompts) needlessly.
    private func applyLoginItem(_ config: BlinkConfig) {
        let service = SMAppService.mainApp
        let isEnabled = service.status == .enabled
        guard config.behavior.launchAtLogin != isEnabled else { return }
        do {
            if config.behavior.launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
            log.info(
                "[BLINK] launch at login",
                metadata: ["enabled": "\(config.behavior.launchAtLogin)"]
            )
        } catch {
            log.error(
                "[BLINK] launch-at-login change failed",
                metadata: ["error": "\(error)"]
            )
        }
    }

    /// Register (or re-register on hot reload) the global hotkeys from config.
    /// An invalid or modifier-less chord is logged and the previous binding kept —
    /// a bad config edit must never leave the app unreachable.
    private var appliedHotkeys: [UInt32: String] = [:]

    private func applyHotkeys(_ config: BlinkConfig) {
        registerGlobalHotkey(id: 1, chord: config.hotkeys.newNote, name: "newNote") { [weak self] in
            self?.newNote()
        }
        // The blink: shows every note, then none.
        registerGlobalHotkey(id: 2, chord: config.hotkeys.blink, name: "blink") { [weak self] in
            self?.panelManager.toggleBlink()
        }
        registerGlobalHotkey(id: 3, chord: config.hotkeys.grid, name: "grid") { [weak self] in
            self?.panelManager.toggleGridOverlay()
        }
        registerGlobalHotkey(id: 4, chord: config.hotkeys.reader, name: "reader") { [weak self] in
            self?.readerLayer.toggle()
        }
        if let chord = KeyChord.parse(config.hotkeys.newNote) {
            statusItem?.button?.toolTip = "Canvas — \(chord.display) for a new note"
        }
    }

    private func registerGlobalHotkey(
        id: UInt32, chord raw: String, name: String, callback: @escaping () -> Void
    ) {
        guard appliedHotkeys[id] != raw else { return }
        guard let chord = KeyChord.parse(raw), !chord.eventModifiers.isEmpty else {
            log.error(
                "[BLINK] invalid hotkey — keeping previous binding",
                metadata: ["hotkey": name, "value": raw]
            )
            return
        }
        if HotkeyManager.shared.register(
            id: id, keyCode: chord.keyCode, modifiers: chord.carbonModifiers, callback: callback
        ) {
            appliedHotkeys[id] = raw
            log.info("[BLINK] hotkey bound", metadata: ["hotkey": name, "chord": chord.display])
        } else {
            log.error(
                "[BLINK] hotkey registration failed (chord taken by another app?)",
                metadata: ["hotkey": name, "value": raw]
            )
        }
    }

    /// Flush pending note saves before quitting — never drop edits (v1 lesson).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        panelManager.prepareForTermination()
        Task {
            await panelManager.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        socketNoteObservers.forEach(NotificationCenter.default.removeObserver)
        peerServer?.stop()
        HotkeyManager.shared.unregisterAll()
        if let commandRequestObserver {
            NotificationCenter.default.removeObserver(commandRequestObserver)
        }
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: BlinkDeskCommand.notificationName,
            object: nil
        )
    }

    private func startSocketServer() {
        let server = BlinkSocketServer { [weak self] data, client in
            await self?.handleSocketRequest(data, client: client)
        }
        do {
            try server.start(); socketServer = server
            panelManager.onPlacementChanged = { [weak server] id, method in
                server?.publish(method: method, params: ["id": id])
            }
            for name in [Notification.Name.blinkNoteCreated, .blinkNoteUpdated, .blinkNoteDeleted] {
                socketNoteObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak server] notification in
                    let method = name == .blinkNoteCreated ? "note.created" : (name == .blinkNoteUpdated ? "note.updated" : "note.deleted")
                    server?.publish(method: method, params: ["id": notification.userInfo?["id"] as? String ?? ""])
                })
            }
            log.info("[BLINK] agent socket listening", metadata: ["path": BlinkPaths.socket().path])
        } catch {
            log.error("[BLINK] agent socket failed", metadata: ["error": "\(error)"])
        }
    }

    private func handleSocketRequest(_ data: Data, client: BlinkSocketServer.Client) async {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String
        else { socketServer?.send(rpcError(id: NSNull(), code: -32600, message: "Invalid Request"), to: client); return }
        let id = request["id"] ?? NSNull()
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result: Any
            switch method {
            case "system.hello":
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                result = ["protocol": "2.0", "version": version, "app": "Blink", "displayName": "Canvas"]
            case "placements.list": result = panelManager.placementList()
            case "notes.list":
                result = await store.all().map { ["id": $0.id, "title": $0.title, "updated": ISO8601DateFormatter().string(from: $0.updatedAt)] }
            case "notes.get":
                guard let noteID = params["id"] as? String, let note = await store.note(id: noteID) else { throw RPCFailure(code: -32004, message: "Note not found") }
                var value: [String: Any] = ["id": note.id, "title": note.title, "frontmatter": note.extraFrontmatter]
                if params["content"] as? Bool == true { value["content"] = note.content }
                result = value
            case "notes.present":
                guard let rawID = params["id"] as? String else { throw RPCFailure(code: -32602, message: "id is required") }
                let noteID = Slug.generate(from: rawID); let now = Date(); let disk = NoteFileStore(directory: BlinkPaths.notes(), ledger: NoteEditLedger(fileURL: BlinkPaths.edits()))
                var note = (try? disk.load(id: noteID)) ?? Note(id: noteID, content: "", createdAt: now, updatedAt: now)
                if let content = params["content"] as? String { note.content = content }
                if let slot = params["slot"] as? Int { note.presentation.slot = slot }
                if let style = params["style"] as? String { note.presentation.style = style }
                note.presentation.lastWriter = "agent-socket"; note.updatedAt = now
                try disk.save(note, writer: "agent-socket"); _ = await store.reconcile(); _ = panelManager.openPanel(for: note)
                result = ["id": note.id]
            case "desk.save":
                guard let name = params["name"] as? String else { throw RPCFailure(code: -32602, message: "name is required") }
                let layout = panelManager.deskLayout(named: try DeskLayoutStore.validate(name)); try DeskLayoutStore().save(layout); result = layoutJSON(layout)
            case "desk.restore":
                guard let name = params["name"] as? String else { throw RPCFailure(code: -32602, message: "name is required") }
                let layout = try DeskLayoutStore().load(name); await panelManager.restoreDesk(layout); result = layoutJSON(layout)
            case "events.subscribe": client.subscribed = true; result = ["subscribed": params["topics"] ?? []]
            default: throw RPCFailure(code: -32601, message: "Method not found")
            }
            socketServer?.send(["jsonrpc": "2.0", "id": id, "result": result], to: client)
        } catch let failure as RPCFailure {
            socketServer?.send(rpcError(id: id, code: failure.code, message: failure.message), to: client)
        } catch { socketServer?.send(rpcError(id: id, code: -32000, message: error.localizedDescription), to: client) }
    }

    private struct RPCFailure: Error { let code: Int; let message: String }
    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private func layoutJSON(_ layout: DeskLayout) -> [String: Any] {
        ["name": layout.name, "updated": ISO8601DateFormatter().string(from: layout.updated), "panels": layout.panels.count]
    }

    /// Realize the CLI's narrow live-desk verbs through AppModel and
    /// PanelManager. Content never crosses this channel; files remain the
    /// durable API and PanelManager remains the sole panel lifecycle owner.
    @objc
    private func receiveDeskCommand(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestID = userInfo[BlinkDeskCommand.Key.requestID] as? String,
              let requestedHome = userInfo[BlinkDeskCommand.Key.home] as? String,
              requestedHome == BlinkDeskCommand.canonicalHomePath()
        else { return }

        guard
              let rawVerb = userInfo[BlinkDeskCommand.Key.verb] as? String,
              let verb = BlinkDeskCommand.Verb(rawValue: rawVerb),
              let noteID = userInfo[BlinkDeskCommand.Key.noteID] as? String
        else {
            log.error("[BLINK] ignored malformed desk command")
            sendDeskResponse(
                requestID: requestID,
                success: false,
                error: "Canvas received a malformed desk command"
            )
            return
        }

        let request = DeskCommandRequest(
            verb: verb,
            noteID: noteID,
            x: deskNumber(.x, in: userInfo),
            y: deskNumber(.y, in: userInfo),
            width: deskNumber(.width, in: userInfo),
            height: deskNumber(.height, in: userInfo),
            display: (userInfo[BlinkDeskCommand.Key.display] as? NSNumber)?.intValue,
            animated: (userInfo[BlinkDeskCommand.Key.animated] as? NSNumber)?.boolValue ?? true
        )
        Task {
            let result = await handleDeskCommand(request)
            sendDeskResponse(
                requestID: requestID,
                success: result.success,
                error: result.error
            )
        }
    }

    private func handleDeskCommand(_ request: DeskCommandRequest) async -> DeskCommandResult {
        let verb = request.verb
        let noteID = request.noteID
        let applied: Bool

        switch verb {
        case .open:
            applied = await model.openNote(
                id: noteID,
                deskFrame: request.hasFrame ? request.deskFrame : nil
            )
        case .move:
            guard await model.openNote(id: noteID) else {
                return .failure("Note “\(noteID)” was not found")
            }
            applied = panelManager.applyDeskFrame(
                noteID: noteID,
                x: request.x,
                y: request.y,
                width: request.width,
                height: request.height,
                display: request.display,
                animated: request.animated
            )
        case .focus:
            applied = await model.openNote(id: noteID)
        case .close:
            applied = panelManager.closePanel(noteID: noteID)
        }

        guard applied else {
            return .failure("Canvas could not \(verb.rawValue) note “\(noteID)”")
        }

        log.info(
            "[BLINK] desk command applied",
            metadata: ["verb": verb.rawValue, "id": noteID]
        )
        return .success
    }

    private func sendDeskResponse(requestID: String, success: Bool, error: String?) {
        var userInfo: [AnyHashable: Any] = [
            BlinkDeskCommand.Key.requestID: requestID,
            BlinkDeskCommand.Key.success: success,
        ]
        if let error { userInfo[BlinkDeskCommand.Key.error] = error }
        DistributedNotificationCenter.default().post(
            name: BlinkDeskCommand.responseNotificationName,
            object: nil,
            userInfo: userInfo
        )
    }

    private enum DeskNumberKey {
        case x, y, width, height

        var rawValue: String {
            switch self {
            case .x: BlinkDeskCommand.Key.x
            case .y: BlinkDeskCommand.Key.y
            case .width: BlinkDeskCommand.Key.width
            case .height: BlinkDeskCommand.Key.height
            }
        }
    }

    private struct DeskCommandRequest: Sendable {
        let verb: BlinkDeskCommand.Verb
        let noteID: String
        let x: CGFloat?
        let y: CGFloat?
        let width: CGFloat?
        let height: CGFloat?
        let display: Int?
        let animated: Bool

        var hasFrame: Bool {
            x != nil || y != nil || width != nil || height != nil || display != nil
        }

        var deskFrame: DeskFrameRequest {
            DeskFrameRequest(x: x, y: y, width: width, height: height, display: display)
        }
    }

    private struct DeskCommandResult {
        let success: Bool
        let error: String?

        static let success = DeskCommandResult(success: true, error: nil)

        static func failure(_ error: String) -> DeskCommandResult {
            DeskCommandResult(success: false, error: error)
        }
    }

    private func deskNumber(
        _ key: DeskNumberKey,
        in userInfo: [AnyHashable: Any]
    ) -> CGFloat? {
        (userInfo[key.rawValue] as? NSNumber).map { CGFloat($0.doubleValue) }
    }


    private func newNote() {
        log.info("[BLINK] new-note requested", metadata: ["source": "hotkey"])
        Task { await model.createNote() }
    }

    @objc
    private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem.button else {
            return
        }

        if event.type == .rightMouseUp {
            // Rebuild so live state (e.g. the Background checkmark) is current.
            contextMenu = buildContextMenu()
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }

        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let popover = makePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        setMenuBarArmed(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        setMenuBarArmed(false)
        popover?.contentViewController = nil
        popover = nil
    }

    private func setMenuBarArmed(_ armed: Bool) {
        statusItem?.button?.image = BlinkIcon.menuBar(armed: armed)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: AppearanceManager.shared.scheme.nsAppearanceName)
        popover.contentSize = CapturePopoverView.contentSize
        let host = NSHostingController(
            rootView: CapturePopoverView(
                model: model,
                dismiss: { [weak self] in self?.popover?.performClose(nil) },
                openSettings: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.openSettings()
                },
                openGuide: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.openGuide()
                },
                showCommands: { [weak self] in
                    let invocationWindow = self?.popover?.contentViewController?.view.window
                    self?.popover?.performClose(nil)
                    self?.toggleCommandPalette(from: invocationWindow)
                },
                toggleBlink: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.panelManager.toggleBlink()
                },
                showGrid: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.panelManager.toggleGridOverlay()
                },
                quit: {
                    NSApp.terminate(nil)
                },
                beginDictation: { [weak self] in
                    self?.beginPopoverDictation()
                },
                trustedPeerCount: peerServer?.trustedPeers.count ?? 0,
                peerSyncStatus: peerSyncStatus
            )
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.popover = popover
        return popover
    }

    /// System dictation briefly promotes its own HUD outside Blink. A normal
    /// transient popover interprets that as an outside interaction and closes,
    /// destroying the target text field. Hold the popover through handoff,
    /// then restore its normal click-away behavior once the HUD is established.
    private func beginPopoverDictation() {
        guard let popover, popover.isShown else { return }
        popover.behavior = .applicationDefined
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak popover] in
            guard let popover, popover.isShown else { return }
            popover.behavior = .transient
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let newNoteItem = NSMenuItem(title: "New Note", action: #selector(menuNewNote), keyEquivalent: "")
        newNoteItem.target = self
        menu.addItem(newNoteItem)

        menu.addItem(.separator())

        // Background: quick control over the drape (the full-screen blur/dim
        // behind the notes) without a trip through config.json.
        let backgroundItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let backgroundMenu = NSMenu()
        let level = drapeLevel(BlinkConfigStore.shared.config)
        for (title, target) in [("Off", DrapeLevel.off), ("Light", .light), ("Full", .full)] {
            let item = NSMenuItem(title: title, action: #selector(menuBackgroundLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.state = (level == target) ? .on : .off
            backgroundMenu.addItem(item)
        }
        backgroundItem.submenu = backgroundMenu
        menu.addItem(backgroundItem)

        // Appearance: light/dark override (or Auto to follow macOS), without a
        // trip through config.json. Mirrors config.appearance.
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        let current = BlinkConfigStore.shared.config.appearance.lowercased()
        let activeAppearance = (current == "light" || current == "dark") ? current : "auto"
        for (title, value) in [("Auto", "auto"), ("Light", "light"), ("Dark", "dark")] {
            let item = NSMenuItem(title: title, action: #selector(menuAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (activeAppearance == value) ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        menu.addItem(.separator())

        let accessItem = NSMenuItem(title: "Mobile Access", action: nil, keyEquivalent: "")
        let accessMenu = NSMenu()
        let toggleAccess = NSMenuItem(title: "Enable Mobile Access", action: #selector(menuToggleMobileAccess), keyEquivalent: "")
        toggleAccess.target = self
        toggleAccess.state = BlinkConfigStore.shared.config.behavior.mobileAccess ? .on : .off
        accessMenu.addItem(toggleAccess)
        accessMenu.addItem(.separator())
        let trustedPeers = peerServer?.trustedPeers ?? []
        if let peerSyncUnavailableReason {
            let unavailableItem = NSMenuItem(
                title: "Unavailable",
                action: nil,
                keyEquivalent: ""
            )
            unavailableItem.isEnabled = false
            accessMenu.addItem(unavailableItem)
            let reasonItem = NSMenuItem(
                title: peerSyncUnavailableReason,
                action: nil,
                keyEquivalent: ""
            )
            reasonItem.isEnabled = false
            accessMenu.addItem(reasonItem)
        } else if trustedPeers.isEmpty {
            let emptyItem = NSMenuItem(title: "No approved devices", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            accessMenu.addItem(emptyItem)
        } else {
            for peer in trustedPeers {
                let item = NSMenuItem(
                    title: "Revoke “\(peer.name)”…",
                    action: #selector(menuRevokePeer(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = peer.id
                accessMenu.addItem(item)
            }
        }
        accessMenu.addItem(.separator())
        let accessHelp = NSMenuItem(
            title: peerSyncUnavailableReason == nil
                ? "New devices ask for approval on this Mac"
                : "Check local-network access, then relaunch Canvas",
            action: nil,
            keyEquivalent: ""
        )
        accessHelp.isEnabled = false
        accessMenu.addItem(accessHelp)
        accessItem.submenu = accessMenu
        menu.addItem(accessItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Canvas", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// The three quick background presets. `Off` kills the drape; `Light` and
    /// `Full` set its overall presence (opacity) but leave `dim`/`material` as
    /// configured, so a tuned drape keeps its character.
    private enum DrapeLevel: String {
        case off, light, full
    }

    private func drapeLevel(_ config: BlinkConfig) -> DrapeLevel {
        guard config.drape.enabled else { return .off }
        return config.drape.opacity <= 0.7 ? .light : .full
    }

    @objc private func menuBackgroundLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = DrapeLevel(rawValue: raw) else { return }
        BlinkConfigStore.shared.update { config in
            switch level {
            case .off:   config.drape.enabled = false
            case .light: config.drape.enabled = true; config.drape.opacity = 0.4
            case .full:  config.drape.enabled = true; config.drape.opacity = 1.0
            }
        }
    }

    @objc private func menuAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        BlinkConfigStore.shared.update { $0.appearance = value }
    }

    @objc private func menuNewNote() {
        newNote()
    }

    @objc private func menuSettings() {
        openSettings()
    }

    @objc private func menuCommands() {
        toggleCommandPalette(from: NSApp.keyWindow)
    }

    @objc private func menuGuide() {
        openGuide()
    }

    @objc private func menuRevokePeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let peer = peerServer?.trustedPeers.first(where: { $0.id == id })
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke access for \(peer.name)?"
        alert.informativeText = "This device will stop syncing immediately. It must be approved again before it can read notes from this Mac."
        alert.addButton(withTitle: "Revoke Access")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if try peerServer?.revokeTrustedPeer(id: id) == true {
                log.info("[BLINK] revoked LAN device access", metadata: ["device": peer.name])
            }
        } catch {
            peerSyncStatus.unavailableReason = peerSyncUnavailableReason
            log.error(
                "[BLINK] failed to persist LAN device revocation",
                metadata: ["device": peer.name, "error": error.localizedDescription]
            )
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Couldn’t Revoke Access"
            failure.informativeText = "Canvas couldn’t update its secure device list. Access remains approved. \(error.localizedDescription)"
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    @objc private func menuToggleMobileAccess() {
        BlinkConfigStore.shared.update { $0.behavior.mobileAccess.toggle() }
    }

    private func updatePeerServer() {
        if BlinkConfigStore.shared.config.behavior.mobileAccess {
            if peerServer == nil { startPeerServer() }
        } else {
            peerServer?.stop(); peerServer = nil
            peerSyncStatus.unavailableReason = peerSyncUnavailableReason
        }
    }

    private func startPeerServer() {
        guard BlinkConfigStore.shared.config.behavior.mobileAccess else {
            peerSyncStatus.unavailableReason = "Mobile access is disabled"
            return
        }
        if BlinkPaths.hasHomeOverride() {
            peerSyncStatus.unavailableReason = "Disabled while CANVAS_HOME or BLINK_HOME is set"
            log.info("[BLINK] mobile sync disabled for custom home")
            return
        }
        peerStartupFailure = nil

        let defaults = UserDefaults.standard
        let hostIDKey = "blink.peer.host-id"
        let hostID: String
        if let saved = defaults.string(forKey: hostIDKey) {
            hostID = saved
        } else {
            hostID = UUID().uuidString.lowercased()
            defaults.set(hostID, forKey: hostIDKey)
        }

        let machineName = Host.current().localizedName ?? "Mac"
        var displayName = "Canvas · \(machineName)"
        while displayName.utf8.count > 60 { displayName.removeLast() }
        let server: BlinkLANPeerServer
        do {
            server = try BlinkLANPeerServer(
                hostID: hostID,
                displayName: displayName,
                snapshotService: BlinkSnapshotService(
                    builder: BlinkSnapshotBuilder(notesDirectory: Self.notesDirectory()),
                    tombstoneStore: BlinkTombstoneStore(fileURL: BlinkPaths.tombstones())
                ),
                approvalHandler: { identity in
                    await Self.requestPeerApproval(for: identity)
                }
            )
        } catch {
            let reason = "Secure Mac identity unavailable: \(error.localizedDescription)"
            peerStartupFailure = reason
            peerSyncStatus.unavailableReason = reason
            log.error("[BLINK] encrypted LAN sync unavailable", metadata: ["error": reason])
            return
        }
        peerServer = server
        server.observeStatus { [weak self] in
            Task { @MainActor [weak self] in
                self?.peerSyncStatus.unavailableReason = self?.peerSyncUnavailableReason
            }
        }
        server.start()
        peerSyncStatus.unavailableReason = peerSyncUnavailableReason
        log.info("[BLINK] starting encrypted LAN sync", metadata: ["hostID": hostID])
    }

    private var peerSyncUnavailableReason: String? {
        if !BlinkConfigStore.shared.config.behavior.mobileAccess { return "Mobile access is disabled" }
        if BlinkPaths.hasHomeOverride() {
            return "Disabled while CANVAS_HOME or BLINK_HOME is set"
        }
        if let peerStartupFailure { return peerStartupFailure }
        if let failure = peerServer?.advertisingFailure {
            return "Advertising failed: \(failure)"
        }
        if let failure = peerServer?.trustPersistenceFailure {
            return "Approvals won’t persist: \(failure)"
        }
        return peerServer == nil ? "Mobile sync did not start" : nil
    }

    @MainActor
    private static func requestPeerApproval(for identity: BlinkPeerClientIdentity) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow \(identity.name) to read your Canvas notes?"
        alert.informativeText = "This request came from a nearby device on your local network. Allowing it creates an encrypted, read-only offline copy. You can revoke access from Canvas’s menu."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func configureDiscovery() {
        let handlers = BlinkActivityCatalog.Handlers(
            newNote: { [weak self] in self?.newNote() },
            toggleBlink: { [weak self] in self?.panelManager.toggleBlink() },
            showGrid: { [weak self] in self?.panelManager.toggleGridOverlay() },
            openSettings: { [weak self] in self?.openSettings() },
            openGuide: { [weak self] in self?.openGuide() },
            revealNotesFolder: {
                NSWorkspace.shared.activateFileViewerSelecting([Self.notesDirectory()])
            },
            openConfigFile: {
                NSWorkspace.shared.open(BlinkConfigStore.shared.fileURL)
            },
            toggleCurrentNoteMode: { [weak self] in self?.panelManager.toggleCommandNoteMode() },
            toggleCurrentNoteFocus: { [weak self] in self?.panelManager.toggleCommandNoteFocus() },
            chooseCurrentNoteStyle: { [weak self] in self?.panelManager.chooseCommandNoteStyle() },
            hideCurrentNote: { [weak self] in self?.panelManager.hideCommandNote() },
            closeCurrentNote: { [weak self] in self?.panelManager.closeCommandNote() },
            copyCurrentNoteID: { [weak self] in self?.panelManager.copyCommandNoteID() },
            copyCurrentNoteMarkdown: { [weak self] in self?.panelManager.copyCommandNoteMarkdown() },
            copyCurrentNoteFilePath: { [weak self] in self?.panelManager.copyCommandNoteFilePath() },
            openCurrentNoteFile: { [weak self] in self?.panelManager.openCommandNoteFile() },
            revealCurrentNoteInFinder: { [weak self] in self?.panelManager.revealCommandNoteInFinder() },
            currentNoteAvailable: { [weak self] in self?.panelManager.hasCommandNotePanel ?? false }
        )
        let catalog = BlinkActivityCatalog(handlers: handlers)
        activityCatalog = catalog
        commandPaletteController = BlinkCommandPaletteController(
            model: model,
            activities: { [weak self] in self?.activityCatalog?.paletteActivities ?? [] }
        )
    }

    private func toggleCommandPalette(from invocationWindow: NSWindow?) {
        popover?.performClose(nil)
        commandPaletteController?.toggle(from: invocationWindow)
    }

    private func openGuide() {
        guard let activities = activityCatalog?.activities else { return }
        // Blink owns one durable utility surface at a time. Commands remains a
        // transient interstitial; Help and Settings replace one another instead
        // of accumulating as unrelated document windows on the desktop.
        commandPaletteController?.dismiss()
        settingsWindow?.orderOut(nil)
        if guideWindow == nil {
            let host = NSHostingController(rootView: BlinkGuideView(activities: activities))
            let window = NSWindow(contentViewController: host)
            window.title = "Canvas Help & Shortcuts"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 610))
            window.contentMinSize = NSSize(width: 720, height: 520)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("blink.guide")
            if window.frame.origin == .zero { window.center() }
            guideWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        commandPaletteController?.dismiss()
        guideWindow?.orderOut(nil)
        if settingsWindow == nil {
            let host = NSHostingController(
                rootView: SettingsView(store: .shared, notesDirectory: Self.notesDirectory())
            )
            let window = NSWindow(contentViewController: host)
            window.title = "Canvas Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            WindowFrameChrome.configure(window)
            window.setContentSize(NSSize(width: 780, height: 580))
            window.contentMinSize = NSSize(width: 620, height: 460)
            // No explicit appearance — inherit NSApp.appearance, which
            // AppearanceManager pins (light/dark) or clears (auto → the OS).
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("blink.settings")
            if window.frame.origin == .zero { window.center() }
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let blinkCommandPaletteRequested = Notification.Name("blink.commandPaletteRequested")
}
