import AppKit
import Carbon
import HudsonObservability

extension Notification.Name {
    static let latticesPopoverWillShow = Notification.Name("latticesPopoverWillShow")
    static let latticesShowGeneralSettings = Notification.Name("latticesShowGeneralSettings")
    static let latticesShowAssistantSettings = Notification.Name("latticesShowAssistantSettings")
    static let latticesShowSettingsSection = Notification.Name("latticesShowSettingsSection")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notificationObservers: [NSObjectProtocol] = []
    private var systemSettingsWasFrontmost = false
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var inputLease: AppInputLease?

    static func updateActivationPolicy() {
        AppActivationCoordinator.shared.refresh()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LatticesRecordingProbeAppRunner.startFromCommandLineIfNeeded() {
            return
        }

        // Refuse before creating controllers or changing any global input state.
        // The peer check also covers older versions that predate the lease.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let peer = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && AppInputLease.isPeer(
                bundleIdentifier: $0.bundleIdentifier, pid: $0.processIdentifier, ownPID: ownPID
            )
        }) {
            NSLog("Lattices input startup refused: peer pid=%d bundle=%@", peer.processIdentifier,
                  peer.bundleURL?.path ?? "unknown")
            exit(EXIT_FAILURE)
        }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattices")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            inputLease = try AppInputLease(path: directory.appendingPathComponent("app-input.lock").path)
        } catch {
            NSLog("Lattices input startup refused: %@", String(describing: error))
            exit(EXIT_FAILURE)
        }

        HudLoggerSinks.install(HudLogStore.shared)
        HudLoggerSinks.install(LatticesLogDiskSink.shared)
        #if LATTICES_BUNDLE
        LatticesBundle.register()
        #endif
        DiagnosticLog.shared.info("Lattices tier: \(LatticesTier.current.rawValue) [\(BundleModules.ids.joined(separator: ", "))]")
        traceBuildIdentity()
        HudLogger(category: "lattices").info("Lattices booted", metadata: ["state": "ready"])

        AppFocusRingSuppressor.install()
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        registerDeepLinkHandler()
        installSystemInputBoundaryObservers()

        MenuBarController.shared.start()
        registerVisibleSurfaces()
        HotkeyBootstrap.registerHotkeys()

        DispatchQueue.main.async { HUDController.shared.warmUp() }
        DispatchQueue.main.async { MenuBarController.shared.warmUpPopover() }
        DispatchQueue.main.async { ScreenOverlayCanvasController.shared.warmUp() }

        WindowDragSnapController.shared.start()
        TilePointerController.shared.start()
        MouseGestureController.shared.start()
        VisitController.shared.restore()
        DesktopLong.shared.start()
        BundleModules.start()
        WindowQuickMenu.shared.start()
        KeyboardRemapController.shared.start()
        SpaceSwitchInterceptor.shared.start()
        DispatchQueue.main.async { SpaceNumberMark.shared.refresh() }
        SecureEventInputMonitor.shared.start()
        installTerminationSignalHandlers()
        // A crash can leave layer-parked windows in the corner; put them back.
        DispatchQueue.global(qos: .userInitiated).async {
            LayerStage.shared.restoreParked(reason: "launch")
        }

        if !OnboardingWindowController.shared.showIfNeeded() {
            PermissionChecker.shared.check()
        }

        AppServicesBootstrap.start()

        Task {
            await AppUpdater.shared.checkIfNeeded()
        }

        // --diagnostics flag: auto-open diagnostics panel on launch
        if CommandLine.arguments.contains("--diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ScreenMapWindowController.shared.showPage(.activity)
            }
        }

        // --screen-map flag: auto-open layout on launch
        if CommandLine.arguments.contains("--screen-map") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ScreenMapWindowController.shared.showPage(.overview)
            }
        }

        // Explicit preview entry point for development/demo flows. This still
        // requires a launch argument; the assistant never opens automatically.
        if CommandLine.arguments.contains("--permissions-assistant") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PermissionsAssistantWindowController.shared.show()
            }
        }
    }

    /// Leave an unmistakable identity line in the persistent log for every
    /// launch. This is especially useful when a local dev bundle and an older
    /// installed copy are both present on the machine.
    private func traceBuildIdentity() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let revision = LatticesRuntime.buildRevision ?? "unknown"
        let timestamp = LatticesRuntime.buildTimestamp ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? "unknown"

        let trace = "BUILD TRACE | channel=\(LatticesRuntime.buildChannel) version=\(version) build=\(build) revision=\(revision) builtAt=\(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier) bundleID=\(bundleID) bundle=\(bundlePath) executable=\(executablePath)"
        HudLogger(category: "build").info(trace)
        NSLog("%@", trace)
    }

    /// `applicationWillTerminate` only runs for a graceful quit. The dev loop
    /// (`bin/lattices-app.ts`) stops the app with `pkill -x Lattices`, i.e.
    /// SIGTERM, whose default disposition kills us without ever reaching
    /// AppKit's terminate path — so global input state we set is left behind.
    /// The visible symptom is a Caps Lock latch that survives the rebuild and
    /// reads as "the Hyper key is stuck".
    ///
    /// SIGKILL (the `pkill -9` escalation) is uncatchable by design; nothing
    /// can be done for that case, which is the more reason to make the
    /// catchable one clean.
    private func installTerminationSignalHandlers() {
        // A peer that hangs up must cost one failed write, not the app.
        // SIGPIPE's default disposition kills us with no crash report and no
        // applicationWillTerminate, only "(2, 13, 13)" in the RunningBoard
        // log. Pipe writes must use `write(contentsOf:)`: the legacy
        // `FileHandle.write(_:)` raises on EPIPE instead of throwing.
        signal(SIGPIPE, SIG_IGN)

        for sig in [SIGTERM, SIGINT] {
            // Ignore the default disposition so the process survives long
            // enough for the dispatch source below to run.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                KeyboardRemapController.shared.flushGlobalStateForAbruptTermination()
                LayerStage.shared.restoreParked(reason: "signal \(sig)")
                SpaceSwitchHotkeys.restoreForTermination()
                exit(128 + sig)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LayerStage.shared.restoreParked(reason: "quit")
        FocusModeController.shared.resetForTermination()
        removeSystemInputBoundaryObservers()
        SecureEventInputMonitor.shared.stop()
        SpaceSwitchInterceptor.shared.stop()
        KeyboardRemapController.shared.stop()
        BundleModules.stop()
        AppServicesBootstrap.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        resetInputCapture(reason: "app became active")
        PermissionChecker.shared.passiveRecheck(reason: "app became active")
    }

    func applicationWillResignActive(_ notification: Notification) {
        resetInputCapture(reason: "app resigned active")
    }

    private func registerVisibleSurfaces() {
        let coordinator = AppActivationCoordinator.shared
        coordinator.registerSurface(id: "menuBarPopover") { MenuBarController.shared.isPopoverShown }
        coordinator.registerSurface(id: "commandMode") { CommandModeWindow.shared.isVisible }
        coordinator.registerSurface(id: "mainWindow") { MainWindow.shared.isVisible }
        coordinator.registerSurface(id: "onboarding") { OnboardingWindowController.shared.isVisible }
        coordinator.registerSurface(id: "permissionsAssistant") { PermissionsAssistantWindowController.shared.isVisible }
        coordinator.registerSurface(id: "permissionDragAssistant") { PermissionDragAssistantWindowController.shared.isVisible }
        coordinator.registerSurface(id: "screenMap") { ScreenMapWindowController.shared.isVisible }
        coordinator.registerSurface(id: "diagnosticWindow") { DiagnosticWindow.shared.isVisible }
        coordinator.registerSurface(id: "mouseInputEventViewer") { MouseInputEventViewer.shared.isVisible }
        coordinator.registerSurface(id: "unifiedCommandBar") { UnifiedCommandBarWindow.shared.isVisible }
        coordinator.registerSurface(id: "gridPlacement") { GridPlacementWindow.shared.isVisible }
    }

    private func installSystemInputBoundaryObservers() {
        let center = NSWorkspace.shared.notificationCenter
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetInputCapture(reason: "system will sleep")
        })
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetInputCapture(reason: "system did wake")
        })
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetInputCapture(reason: "screens did wake")
        })
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetInputCapture(reason: "screens did sleep")
        })
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.handleFrontmostApplicationChanged(app)
        })
        notificationObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            SpaceNumberMark.shared.refresh()
            // System-initiated Space change (Dock app activation, trackpad
            // swipe, Mission Control). Switches Lattices performs show their
            // own bezel — skip those so it doesn't double up.
            guard CFAbsoluteTimeGetCurrent() - WindowTiler.lastProgrammaticSwitchAt > 0.8 else { return }
            WindowTiler.showSpaceSwitchBezelForCurrentSpace()
        })
    }

    private func removeSystemInputBoundaryObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func resetInputCapture(reason: String) {
        InputCaptureResetCenter.reset(reason: reason)
    }

    private func handleFrontmostApplicationChanged(_ app: NSRunningApplication) {
        let isSettings = Self.isSystemSettings(app)
        let isThisApp = app.processIdentifier == ProcessInfo.processInfo.processIdentifier

        if isSettings || systemSettingsWasFrontmost || isThisApp {
            PermissionChecker.shared.passiveRecheck(reason: "frontmost app changed")
        }

        systemSettingsWasFrontmost = isSettings
    }

    private static func isSystemSettings(_ app: NSRunningApplication) -> Bool {
        switch app.bundleIdentifier {
        case "com.apple.systempreferences", "com.apple.SystemSettings":
            return true
        default:
            return app.localizedName == "System Settings"
        }
    }

    // MARK: - Deep Links

    private func registerDeepLinkHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard
            let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: value)
        else {
            return
        }
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.localizedCaseInsensitiveCompare("lattices") == .orderedSame else {
            return
        }

        let host = url.host?.lowercased()
        let action = url.pathComponents
            .first { $0 != "/" }?
            .lowercased()

        switch host {
        case "editor":
            // lattices://editor opens only the read-only Editor surface.
            EditorWindowController.shared.show()
            DiagnosticLog.shared.info("DeepLink: opened Editor")
        case "companion":
            handleCompanionDeepLink(action: action)
        case "daemon":
            handleDaemonDeepLink(action: action)
        case "page":
            // lattices://page/<name> opens a page of the main window.
            if let action, let page = AppPage.named(action) {
                ScreenMapWindowController.shared.showPage(page)
            } else {
                ScreenMapWindowController.shared.show()
            }
        case "settings":
            // lattices://settings/<section> jumps straight to a sidebar tab.
            if let action, !action.isEmpty {
                SettingsWindowController.shared.show(section: action)
            } else {
                SettingsWindowController.shared.show()
            }
        default:
            SettingsWindowController.shared.show()
        }
    }

    private func handleCompanionDeepLink(action: String?) {
        switch action {
        case "enable", "start":
            Preferences.shared.companionBridgeEnabled = true
            SettingsWindowController.shared.showCompanion()
        case "disable", "stop":
            Preferences.shared.companionBridgeEnabled = false
            SettingsWindowController.shared.showCompanion()
        default:
            SettingsWindowController.shared.showCompanion()
        }
    }

    private func handleDaemonDeepLink(action: String?) {
        // The daemon runs in-process with the app. If this handler fires, the
        // app is up — which means the daemon is up. No UI pop required.
        DiagnosticLog.shared.info(
            "DeepLink: lattices://daemon/\(action ?? "") — daemon already running"
        )
    }

}
