import ActionCore
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

@MainActor
final class ActionAgentLayerController: NSObject {
    private struct DisplayManifest: Decodable, Equatable {
        let schemaVersion: Int
        let pid: pid_t
        let displayId: CGDirectDisplayID
        let startedAt: String
        let width: Double
        let height: Double
        let serialNumber: UInt32
        let workspace: String?
    }

    private struct MovedWindow {
        let element: AXUIElement
        let pid: pid_t
        let bundleId: String?
        let title: String?
        let original: CGRect
        /// Opened for or by the agent after the layer went up. It never sat on the
        /// operator's screen, so the layer closes it instead of putting it back.
        let born: Bool
    }

    private let displayManifest: DisplayManifest
    private let workspace: ActionVirtualWorkspace
    private let displayStateFile: URL
    private let displaySessionLock: Int32
    private let requestedWidth: String?
    private let requestedHeight: String?
    private var showsPiP: Bool
    private var previewDisplayID: CGDirectDisplayID?
    private var previewFull: Bool
    private var previewLease: ActionWorkspaceLock?
    private var subjectLease: ActionWorkspaceLock?
    private let startedAt = Date()
    /// The subject app. Nil until launched when the layer was asked for a bundle id
    /// that isn't running.
    private var target: NSRunningApplication?
    /// The subject's bundle id, launched in the background when it isn't running.
    private let targetBundleId: String?
    /// Opened in the subject without activating it, once its windows are on the layer.
    private let openURL: URL?
    /// The caller brings its own window (a browser making one on the layer through
    /// DevTools), so an app with nothing to move isn't asked for one.
    private let windowless: Bool
    /// The open request already carried the URL or the reopen; don't send it twice.
    private var openedOnLaunch = false
    /// Windows found after the first look at the subject were opened for the agent.
    private var adoptsBornWindows = false
    private let stopFile: String?
    private let stateFile: String?
    private let parentProcessID: pid_t?
    /// The processes driving this layer, nearest first: where "go to owner" goes.
    private let ownerPIDs: [pid_t]
    /// Owners that were alive at open. A detached CLI exits right away, so it doesn't count.
    private let liveOwnerPIDs: [pid_t]
    /// How long a detached layer may go without an act, a control request, or the
    /// operator touching the viewer. Nil for a layer whose parent is watched.
    private let idleLimit: TimeInterval?
    private var lastActivity = Date()
    /// Narrow the move to one window, so a layer can borrow a single browser window
    /// without taking the operator's others.
    private let windowID: CGWindowID?
    private let windowTitle: String?
    private let writer: ResponseWriter
    private let logger: DebugLogger

    private var displayID: CGDirectDisplayID { displayManifest.displayId }
    private var bounds: CGRect = .zero
    private var moved: [MovedWindow] = []
    private var feed: ActionAgentLayerFeed?
    private var pip: ActionAgentLayerPiP?
    private var pollTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    /// Start finished: the display is up and the open's windows are placed. Ticks adopt after that.
    private var layerReady = false
    /// The operator paused the agent from the viewer; the director refuses its acts.
    private var paused = false
    private var actObserver: NSObjectProtocol?

    init(options: CommandOptions) throws {
        let workspace = try ActionVirtualWorkspace(options.options["workspace"] ?? "default")
        self.workspace = workspace
        if let value = options.options["preview-full"]?.lowercased() {
            guard ["on", "true", "1", "yes", "off", "false", "0", "no"].contains(value) else {
                throw ActionHostError.unsupportedOS("preview-full must be a boolean")
            }
            self.previewFull = ["on", "true", "1", "yes"].contains(value)
        } else {
            self.previewFull = false
        }
        if let destination = options.options["preview-display-id"] {
            guard let identifier = CGDirectDisplayID(destination), identifier != 0 else {
                throw ActionHostError.unsupportedOS("preview-display-id must be a positive display identifier")
            }
            self.previewDisplayID = identifier
        }
        self.writer = ResponseWriter(replyFile: options.options["reply-file"])
        self.logger = DebugLogger(path: options.options["debug-log"])
        let displayID = try options.required("display-id")
        let displayOwnerPID = try options.required("display-owner-pid")
        let displayStartedAt = try options.required("display-started-at")
        let displayStateFile = URL(fileURLWithPath: try options.required("display-state-file"))
        let lockPath = displayStateFile.deletingLastPathComponent().appendingPathComponent("display-session.lock").path
        let lockDescriptor = Darwin.open(lockPath, O_WRONLY | O_CREAT | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard lockDescriptor >= 0 else {
            throw ActionHostError.unsupportedOS("could not open the persistent display session lock")
        }
        var initialized = false
        defer {
            if !initialized { Darwin.close(lockDescriptor) }
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ActionHostError.unsupportedOS("the persistent display already has a session or is being released")
        }
        let manifest = try JSONDecoder().decode(DisplayManifest.self, from: Data(contentsOf: displayStateFile))
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard manifest.schemaVersion == 1,
              manifest.pid > 1, manifest.pid == pid_t(displayOwnerPID),
              manifest.displayId != 0, manifest.displayId == CGDirectDisplayID(displayID),
              manifest.startedAt == displayStartedAt,
              ISO8601DateFormatter().date(from: manifest.startedAt) != nil || fractionalDateFormatter.date(from: manifest.startedAt) != nil,
              manifest.width.isFinite, manifest.width > 0,
              manifest.height.isFinite, manifest.height > 0,
              (manifest.workspace ?? "default") == workspace.name,
              manifest.serialNumber == workspace.serialNumber else {
            throw ActionHostError.unsupportedOS("the persistent display manifest does not match the requested display owner")
        }
        self.displayManifest = manifest
        self.displayStateFile = displayStateFile
        self.displaySessionLock = lockDescriptor
        self.requestedWidth = options.options["width"]
        self.requestedHeight = options.options["height"]
        self.showsPiP = !["off", "false", "0", "no"].contains(options.options["pip"]?.lowercased() ?? "on")
        self.stopFile = options.options["stop-file"]
        self.stateFile = options.options["state-file"]
        self.parentProcessID = options.options["parent-pid"].flatMap { pid_t($0) }
        self.ownerPIDs = (options.options["owner-pids"] ?? "").split(separator: ",").compactMap { pid_t($0) }
        self.liveOwnerPIDs = ownerPIDs.filter { kill($0, 0) == 0 }
        let idleSeconds = options.double("idle-timeout", default: 30 * 60)
        self.idleLimit = parentProcessID == nil && idleSeconds > 0 ? idleSeconds : nil
        self.windowID = options.options["window-id"].flatMap { CGWindowID($0) }
        self.windowTitle = options.options["window-title"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.openURL = ActionBackgroundOpen.url(from: options.options["url"])
        self.windowless = options.options["windowless"] == "1"
        if options.options["pid"] != nil || options.options["bundle-path"] != nil {
            self.targetBundleId = nil
            self.target = try resolveTargetApplication(from: options)
        } else if let bundleId = options.options["bundle-id"], !bundleId.isEmpty {
            self.targetBundleId = bundleId
            // Not running is fine: start() launches it in the background.
            self.target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        } else {
            self.targetBundleId = nil
            self.target = nil
        }
        initialized = true
    }

    deinit {
        Darwin.close(displaySessionLock)
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.shutdown() }
            }
            source.resume()
            signalSources.append(source)
        }
        // SIGUSR1 brings the viewer back after the operator dismissed it (`layer pip`).
        signal(SIGUSR1, SIG_IGN)
        let showSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        showSource.setEventHandler { [weak self] in
            Task { @MainActor in
                do { try await self?.showPiP() }
                catch { self?.logger.log("agent-layer: preview refused: \(error.localizedDescription)") }
            }
        }
        showSource.resume()
        signalSources.append(showSource)
        // SIGUSR2: a control request is waiting (`layer snapshot`, `layer record`).
        signal(SIGUSR2, SIG_IGN)
        let snapSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        snapSource.setEventHandler { [weak self] in
            Task { @MainActor in await self?.answerControl() }
        }
        snapSource.resume()
        signalSources.append(snapSource)

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        Task { @MainActor in
            do {
                try await self.start()
            } catch {
                self.logger.log("agent-layer: failed: \(error.localizedDescription)")
                try? self.writer.write(ActionHostResponse(status: "error", outputPath: nil, detail: error.localizedDescription))
                self.shutdown(exitCode: 1)
            }
        }
        app.run()
    }

    // MARK: Start

    private func start() async throws {
        bounds = try validateDisplayAttachment()
        if showsPiP { _ = try previewDestination() }
        logDisplayDiagnostic("attached-to-persistent-display")
        logger.log("agent-layer: attached to display \(displayID), owner \(displayManifest.pid), at \(bounds)")

        if target == nil, let targetBundleId {
            target = try await ActionBackgroundOpen.open(bundleId: targetBundleId, url: openURL)
            openedOnLaunch = true
            logger.log("agent-layer: launched \(targetBundleId) in the background")
        }
        _ = try validateDisplayAttachment()
        if let target {
            subjectLease = try ActionWorkspaceLock(url: registryURL.appendingPathComponent("subject-\(target.processIdentifier).lock"))
            await takeWindows(of: target)
        }
        _ = try validateDisplayAttachment()
        let feed = ActionAgentLayerFeed(
            displayID: displayID,
            displayBounds: bounds,
            subjectPID: target?.processIdentifier,
            logger: logger
        )
        do {
            try await feed.start()
            self.feed = feed
        } catch {
            // The layer still works without it; only the viewer and snapshots go dark.
            logger.log("agent-layer: feed failed: \(error.localizedDescription)")
        }
        _ = try validateDisplayAttachment()
        try writeState()
        if showsPiP { try await showPiP() }
        layerReady = true
        try writer.write(
            ActionHostResponse(
                status: "agent-layer-running",
                outputPath: stateFile,
                detail: String(ProcessInfo.processInfo.processIdentifier)
            )
        )

        // The host posts where each blink act landed; accessibility acts don't move the
        // pointer, so the viewer rings the spot instead.
        actObserver = DistributedNotificationCenter.default().addObserver(
            forName: ActionAgentLayerDisplay.actNotification, object: nil, queue: .main
        ) { [weak self] note in
            let act = ActionAgentLayerAct(info: note.userInfo ?? [:])
            Task { @MainActor in
                guard let self,
                      act.point.map(self.bounds.contains) ?? act.frame.map(self.bounds.intersects) ?? false else { return }
                self.lastActivity = Date()
                self.pip?.mark(act)
            }
        }

    }

    private var liveState: ActionAgentLayerLiveState {
        paused ? .paused : (feed?.recordingPath != nil ? .recording : .live)
    }

    private var registryURL: URL {
        ActionLayerSafetyGate.defaultURL.deletingLastPathComponent()
    }

    private func previewDestination() throws -> CGDirectDisplayID {
        let displays = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        let destination = previewDisplayID ?? displays.first(where: { !ActionAgentLayerDisplay.isAgentLayer($0) })
        guard let destination, destination != displayID,
              CGDisplayIsOnline(destination) != 0, CGDisplayIsActive(destination) != 0,
              displays.contains(destination) else {
            throw ActionHostError.unsupportedOS("The preview destination is unavailable or would capture itself")
        }
        return destination
    }

    private func acquirePreviewLease(destination: CGDirectDisplayID) throws -> ActionWorkspaceLock? {
        var directories = [registryURL]
        directories += (try? FileManager.default.contentsOfDirectory(at: registryURL.appendingPathComponent("workspaces"), includingPropertiesForKeys: nil)) ?? []
        var edges: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        var destinationDirectory: URL?
        for directory in directories {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("display.json")),
               let manifest = try? JSONDecoder().decode(DisplayManifest.self, from: data),
               manifest.displayId == destination,
               manifest.pid > 1, kill(manifest.pid, 0) == 0,
               let identity = try? ActionVirtualWorkspace(manifest.workspace ?? "default"),
               manifest.serialNumber == identity.serialNumber,
               CGDisplaySerialNumber(destination) == manifest.serialNumber {
                destinationDirectory = directory
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = state["pid"] as? Int32, pid > 1, kill(pid, 0) == 0,
               state["pip"] as? Bool == true,
               let source = state["displayId"] as? UInt32,
               let target = state["previewDisplayId"] as? UInt32 {
                edges[source] = target
            }
        }
        guard !ActionVirtualWorkspace.previewWouldCycle(source: displayID, destination: destination, edges: edges) else {
            throw ActionHostError.unsupportedOS("Preview routing would create a recursive display capture")
        }
        guard ActionAgentLayerDisplay.isAgentLayer(destination) else { return nil }
        guard let destinationDirectory else {
            throw ActionHostError.unsupportedOS("The preview destination has no matching live Action display owner")
        }
        return try ActionWorkspaceLock(url: destinationDirectory.appendingPathComponent("display-preview.lock"), shared: true)
    }

    private func showPiP() async throws {
        guard !shuttingDown, let feed else {
            throw ActionHostError.unsupportedOS("The layer has no preview feed")
        }
        let routingLock = try ActionWorkspaceLock(url: registryURL.appendingPathComponent("preview-routing.lock"))
        defer { withExtendedLifetime(routingLock) {} }
        let destination = try previewDestination()
        if pip?.destinationDisplayID == destination, pip?.previewFull == previewFull { return }
        let lease = try acquirePreviewLease(destination: destination)
        _ = try previewDestination()
        pip?.stop(animated: false)
        previewLease = lease
        previewDisplayID = destination
        lastActivity = Date()
        let noteURL = stateFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("notes.jsonl") }
        let pip = ActionAgentLayerPiP(feed: feed, startedAt: startedAt, logger: logger, destinationDisplayID: destination,
                                      noteURL: noteURL, workspace: workspace.name, previewFull: previewFull)
        pip.hasOwner = !ownerPIDs.isEmpty
        pip.onTogglePause = { [weak self] in self?.togglePause() }
        pip.onStop = { [weak self] in self?.stopByOperator() }
        pip.onTakeOver = { [weak self] in self?.takeOver() }
        pip.onGoToOwner = { [weak self] in self?.goToOwner() }
        pip.onDismiss = { [weak self] in
            // The operator closed the viewer; the layer keeps working unseen.
            guard let self else { return }
            self.pip = nil
            self.previewLease = nil
            self.showsPiP = false
            try? self.writeState()
            self.logger.log("agent-layer: pip dismissed")
        }
        self.pip = pip
        showsPiP = true
        try writeState()
        do {
            try await pip.start(expectsWindows: !moved.isEmpty, state: liveState)
        } catch {
            pip.stop(animated: false)
            self.pip = nil
            showsPiP = false
            previewLease = nil
            try? writeState()
            throw error
        }
    }

    // MARK: Operator controls

    private func togglePause() {
        lastActivity = Date()
        paused.toggle()
        pip?.state = liveState
        try? writeState()
        logger.log("agent-layer: \(paused ? "paused" : "resumed") by the operator")
    }

    private func writeHandoff(action: String, reason: String) {
        if let stateFile {
            let url = URL(fileURLWithPath: stateFile).deletingLastPathComponent().appendingPathComponent("handoff.json")
            let note: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "bundleId": target?.bundleIdentifier ?? NSNull(),
                "action": action,
                "reason": reason,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "displayId": Int(displayID),
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func stopByOperator() {
        paused = true
        pip?.state = liveState
        try? writeState()
        writeHandoff(action: "stop", reason: "The operator stopped this layer task.")
        logger.log("agent-layer: stopped by the operator")
        shutdown()
    }

    private func takeOver() {
        paused = true
        pip?.state = liveState
        try? writeState()
        writeHandoff(action: "takeover", reason: "The operator took over this layer task.")
        logger.log("agent-layer: taken over by the operator")
        shutdown()
        // Bring the subject forward on the operator's display once it's back.
        if let target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { target.activate() }
        }
    }

    /// Focus whatever is driving the layer: the nearest owner process with a window of
    /// its own (a terminal, an editor), else the terminal window Lattices maps its tty to.
    private func goToOwner() {
        for pid in ownerPIDs {
            for ancestor in processAncestry(pid) {
                if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                    app.activate()
                    logger.log("agent-layer: owner \(pid) -> \(app.bundleIdentifier ?? "?")")
                    return
                }
            }
        }
        let owners = ownerPIDs
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ActionAgentLayerOwner.raiseTerminal(ownerPIDs: owners)
            DispatchQueue.main.async { [weak self] in
                self?.logger.log("agent-layer: owner via lattices \(found ? "raised" : "not found")")
                if !found { NSSound.beep() }
            }
        }
    }

    private func logDisplayDiagnostic(_ stage: String, displayID: CGDirectDisplayID? = nil, result: String? = nil) {
        logger.log(ActionAgentLayerDiagnostics.snapshot(stage: stage, layerDisplayID: displayID ?? self.displayID, requestedSize: bounds.size, result: result))
    }

    private func validateDisplayAttachment() throws -> CGRect {
        guard !shuttingDown else {
            throw ActionHostError.unsupportedOS("the agent layer session is closing")
        }
        let current = try JSONDecoder().decode(DisplayManifest.self, from: Data(contentsOf: displayStateFile))
        guard current == displayManifest, kill(displayManifest.pid, 0) == 0,
              CGDisplayIsOnline(displayID) != 0,
              ActionAgentLayerDisplay.isAgentLayer(displayID),
              CGDisplaySerialNumber(displayID) == displayManifest.serialNumber else {
            throw ActionHostError.unsupportedOS("the persistent display owner is unavailable or its identity changed")
        }
        let currentBounds = CGDisplayBounds(displayID)
        guard currentBounds.width == displayManifest.width,
              currentBounds.height == displayManifest.height,
              bounds == .zero || bounds == currentBounds else {
            throw ActionHostError.unsupportedOS("the persistent display geometry changed; the session cannot attach or continue")
        }
        for (name, requested, actual) in [("width", requestedWidth, currentBounds.width), ("height", requestedHeight, currentBounds.height)] {
            if let requested {
                guard let dimension = Double(requested), dimension.isFinite, dimension > 0, dimension == actual else {
                    throw ActionHostError.unsupportedOS("requested \(name) does not match the persistent display; configure the display explicitly before opening a session")
                }
            }
        }
        return currentBounds
    }

    // MARK: Windows

    /// The subject's windows onto the layer at open. A URL, or an app with nothing to
    /// move, is opened in the background next, and the window that brings is waited
    /// for, so the open returns with the window the agent is about to drive.
    private func takeWindows(of app: NSRunningApplication) async {
        if !openedOnLaunch {
            adoptWindows(of: app)
        }
        adoptsBornWindows = true
        let asksForWindow = openURL != nil || (moved.isEmpty && windowID == nil && !windowless)
        if asksForWindow, !openedOnLaunch {
            // Not awaited: an app can take seconds to acknowledge an open (Safari with
            // a URL), and the window poll below is what the layer actually waits for.
            let url = openURL
            let logger = logger
            Task { @MainActor in
                do {
                    _ = try await ActionBackgroundOpen.open(app, url: url)
                    logger.log("agent-layer: opened \(url?.absoluteString ?? "a window") in \(targetLabel(for: app))")
                } catch {
                    logger.log("agent-layer: background open failed: \(error.localizedDescription)")
                }
            }
        }
        // A freshly launched app, or one asked for a window, shows it a moment later.
        for attempt in 1...50 where moved.isEmpty && !windowless {
            try? await Task.sleep(for: .milliseconds(100))
            if adoptWindows(of: app) > 0 {
                logger.log("agent-layer: windows visible after \(attempt) retries")
            }
        }
        if moved.isEmpty {
            logger.log("agent-layer: \(targetLabel(for: app)) exposes no matching windows")
        }
    }

    /// Moves the subject's windows that aren't on the layer yet: at open, and on every
    /// tick after, so a window the agent opens (a new window, a popup) lands on the layer
    /// instead of the operator's screen. A layer that borrowed one window by id adopts
    /// nothing more. Returns how many moved.
    @discardableResult
    private func adoptWindows(of app: NSRunningApplication) -> Int {
        guard !shuttingDown, !app.isTerminated, (try? validateDisplayAttachment()) != nil else { return 0 }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let windows = (copyAttribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter(isSelected)

        // Clear of the layer's menu bar, cascaded so every window stays reachable.
        let inset = CGPoint(x: bounds.minX + 24, y: bounds.minY + 48)
        let room = CGSize(width: bounds.width - 48, height: bounds.height - 72)
        var count = 0
        for window in windows {
            if moved.contains(where: { CFEqual($0.element, window) }) { continue }
            if (copyAttribute(window, kAXMinimizedAttribute) as? Bool) == true { continue }
            guard let origin = axPoint(copyAttribute(window, kAXPositionAttribute)),
                  let extent = axSize(copyAttribute(window, kAXSizeAttribute)) else { continue }
            let original = CGRect(origin: origin, size: extent)
            let step = CGFloat(moved.count % 8) * 28
            var frame = CGRect(
                x: inset.x + step,
                y: inset.y + step,
                width: min(extent.width, room.width - step),
                height: min(extent.height, room.height - step)
            )
            frame.size.width = max(frame.size.width, 200)
            frame.size.height = max(frame.size.height, 120)
            setFrame(window, frame)
            moved.append(
                MovedWindow(
                    element: window,
                    pid: app.processIdentifier,
                    bundleId: app.bundleIdentifier,
                    title: copyAttribute(window, kAXTitleAttribute) as? String,
                    original: original,
                    born: adoptsBornWindows
                )
            )
            count += 1
        }
        if count > 0 {
            logger.log("agent-layer: moved \(count) window(s) of \(targetLabel(for: app)), \(moved.count) on the layer")
        }
        return count
    }

    private func isSelected(_ window: AXUIElement) -> Bool {
        if let windowID, axWindowID(window) != windowID { return false }
        if let windowTitle {
            let title = (copyAttribute(window, kAXTitleAttribute) as? String)?.lowercased() ?? ""
            if !title.contains(windowTitle) { return false }
        }
        return true
    }

    private func restoreWindows() {
        var closed = 0
        for window in moved.reversed() {
            if window.born {
                // Opened for the agent: it never belonged on the operator's screens.
                // One that asks before closing (several tabs, unsaved changes) goes to
                // the Dock instead of landing on their desktop.
                if close(window.element) {
                    closed += 1
                } else {
                    AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            } else {
                setFrame(window.element, window.original)
            }
        }
        logger.log("agent-layer: restored \(moved.count(where: { !$0.born })) window(s), closed \(closed) opened on the layer")
        moved.removeAll()
    }

    /// Presses the window's close button and waits out the close animation. A window
    /// that asks first stays open.
    private func close(_ window: AXUIElement) -> Bool {
        guard let button = copyAttribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else { return false }
        for _ in 0..<50 {
            if copyAttribute(window, kAXRoleAttribute) == nil { return true }
            usleep(20_000)
        }
        return false
    }

    /// Size, then position, then size again: a window that doesn't fit where it's going
    /// gets clamped by the system, and the second size lands once it's there.
    private func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var size = frame.size
        var origin = frame.origin
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let pointValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    // MARK: State

    private func writeState() throws {
        guard let stateFile else { return }
        let state: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "displayId": Int(displayID),
            "workspace": workspace.name,
            "previewDisplayId": previewDisplayID.map { Int($0) } ?? NSNull(),
            "previewFull": previewFull,
            "displayOwnerPid": Int(displayManifest.pid),
            "displayStartedAt": displayManifest.startedAt,
            "bounds": rectJSON(bounds),
            "pip": showsPiP,
            "paused": paused,
            "recording": feed?.recordingPath ?? NSNull(),
            "windows": moved.map { window in
                [
                    "pid": Int(window.pid),
                    "bundleId": window.bundleId ?? NSNull(),
                    "title": window.title ?? NSNull(),
                    "original": rectJSON(window.original),
                    "born": window.born,
                ] as [String: Any]
            },
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: stateFile)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private var controlPaths: (request: URL, reply: URL)? {
        guard let stateFile else { return nil }
        let dir = URL(fileURLWithPath: stateFile).deletingLastPathComponent()
        return (dir.appendingPathComponent("control.request.json"), dir.appendingPathComponent("control.reply.json"))
    }

    /// Answers the request the director left next to the state file: a snapshot, or
    /// starting or stopping a recording, all off the running feed.
    private func answerControl() async {
        guard let paths = controlPaths,
              let data = try? Data(contentsOf: paths.request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["id"] as? String else {
            logger.log("agent-layer: control signal without a readable request")
            return
        }
        lastActivity = Date()
        var reply: [String: Any]
        if json["op"] as? String == "mark" {
            // An act the director ran itself (DevTools input into a browser on the
            // layer): show it on the viewer the way a blink's notification would.
            pip?.mark(ActionAgentLayerAct(info: json))
            reply = ["ok": true]
        } else if let feed {
            switch json["op"] as? String {
            case "show":
                let previous = previewDisplayID
                let previousFull = previewFull
                do {
                    if let raw = json["previewDisplayId"] {
                        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue > 0, number.doubleValue <= Double(UInt32.max),
                              number.doubleValue.rounded() == number.doubleValue else {
                            throw ActionHostError.unsupportedOS("previewDisplayId must be a positive display identifier")
                        }
                        previewDisplayID = number.uint32Value
                    }
                    if let raw = json["previewFull"] {
                        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                            throw ActionHostError.unsupportedOS("previewFull must be a boolean")
                        }
                        previewFull = number.boolValue
                    }
                    try await showPiP()
                    reply = ["ok": true, "previewDisplayId": previewDisplayID.map { Int($0) } ?? NSNull(), "previewFull": previewFull]
                } catch {
                    previewDisplayID = previous
                    previewFull = previousFull
                    try? writeState()
                    reply = ["ok": false, "detail": error.localizedDescription]
                }
            case "snapshot":
                reply = ActionAgentLayerSnapshotRequest(json: json).map(feed.snapshot)
                    ?? ["ok": false, "detail": "snapshot needs an out path"]
            case "record-start":
                if #unavailable(macOS 15.0) {
                    reply = ["ok": false, "detail": "recording the layer needs macOS 15"]
                } else if let out = json["out"] as? String {
                    do {
                        try await feed.startRecording(to: out)
                        reply = ["ok": true, "path": out]
                    } catch {
                        reply = ["ok": false, "detail": error.localizedDescription]
                    }
                } else {
                    reply = ["ok": false, "detail": "record-start needs an out path"]
                }
                try? writeState()
                pip?.state = liveState
            case "record-stop":
                guard #available(macOS 15.0, *) else {
                    reply = ["ok": false, "detail": "recording the layer needs macOS 15"]
                    break
                }
                do {
                    reply = ["ok": true, "path": try await feed.stopRecording()]
                } catch {
                    reply = ["ok": false, "detail": error.localizedDescription]
                }
                try? writeState()
                pip?.state = liveState
            default:
                reply = ["ok": false, "detail": "unknown op \(json["op"] ?? "none")"]
            }
        } else {
            reply = ["ok": false, "detail": "the layer has no feed"]
        }
        reply["id"] = id
        if let out = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) {
            try? out.write(to: paths.reply, options: .atomic)
        }
    }

    private func rectJSON(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    // MARK: Teardown

    private func tick() {
        guard !shuttingDown else { return }
        do {
            _ = try validateDisplayAttachment()
        } catch {
            logger.log("agent-layer: display attachment lost: \(error.localizedDescription)")
            shutdown(exitCode: 1)
            return
        }
        if let stopFile, FileManager.default.fileExists(atPath: stopFile) {
            logger.log("agent-layer: stop file received")
            shutdown()
            return
        }
        if let parentProcessID, kill(parentProcessID, 0) != 0 {
            logger.log("agent-layer: parent \(parentProcessID) is gone, closing")
            shutdown()
            return
        }
        if layerReady, windowID == nil, let target, adoptWindows(of: target) > 0 {
            try? writeState()
        }
        guard parentProcessID == nil else { return }
        if !liveOwnerPIDs.isEmpty, liveOwnerPIDs.allSatisfy({ kill($0, 0) != 0 }) {
            logger.log("agent-layer: owners \(liveOwnerPIDs) are gone, closing")
            shutdown()
            return
        }
        // A take in progress is the operator's to stop; it never expires underneath them.
        if let idleLimit, feed?.recordingPath == nil, Date().timeIntervalSince(lastActivity) > idleLimit {
            logger.log("agent-layer: idle for \(Int(idleLimit))s, closing")
            shutdown()
        }
    }

    private func shutdown(exitCode: Int32 = 0) {
        guard !shuttingDown else { return }
        shuttingDown = true
        pollTimer?.invalidate()
        pollTimer = nil

        pip?.stop(animated: false)
        pip = nil
        previewLease = nil
        // A take in progress has to be finished, or the movie is unreadable.
        Task { @MainActor in
            await self.feed?.stop()
            self.feed = nil
            self.finishShutdown(exitCode: exitCode)
        }
    }

    private func finishShutdown(exitCode: Int32) {
        restoreWindows()
        logDisplayDiagnostic("detached-from-persistent-display")
        if let stateFile { try? FileManager.default.removeItem(atPath: stateFile) }
        if let stopFile { try? FileManager.default.removeItem(atPath: stopFile) }

        // Same reason as the drape: an accessory app with no key window never dequeues
        // the event `NSApplication.stop` waits for, so leaving is the whole teardown.
        logger.log("agent-layer: down")
        Darwin.exit(exitCode)
    }
}

/// `pid` and its parents, nearest first.
private func processAncestry(_ pid: pid_t) -> [pid_t] {
    var chain: [pid_t] = []
    var current = pid
    while current > 1, chain.count < 32 {
        chain.append(current)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        current = info.kp_eproc.e_ppid
    }
    return chain
}

/// Owners that live under a daemonized multiplexer have no GUI parent; Lattices knows
/// which terminal window shows their tty.
enum ActionAgentLayerOwner {
    static func raiseTerminal(ownerPIDs: [pid_t]) -> Bool {
        let owners = Set(ownerPIDs.flatMap(processAncestry).map(Int.init))
        guard !owners.isEmpty, let json = lattices(["call", "terminals.search", "{}"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        let instances = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["instances"] as? [[String: Any]]) ?? []
        for instance in instances {
            let pids = ((instance["processes"] as? [[String: Any]]) ?? []).compactMap { ($0["pid"] as? NSNumber)?.intValue }
            guard pids.contains(where: owners.contains), let wid = (instance["windowId"] as? NSNumber)?.intValue else { continue }
            return lattices(["call", "windows.focus", "{\"wid\":\(wid)}"]) != nil
        }
        return false
    }

    private static func lattices(_ arguments: [String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.bun/bin/lattices", "/opt/homebrew/bin/lattices", "/usr/local/bin/lattices"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - AX helpers

private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axPoint(_ value: AnyObject?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

private func axSize(_ value: AnyObject?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

// MARK: - Feed

/// One ScreenCaptureKit stream on the layer, up for the layer's whole life: the viewer
/// draws from it, snapshots read its latest frame, and recordings hang off it, so none
/// of them pays for a capture setup. It captures the layer's display, not the subject
/// app: an app-targeted stream makes macOS badge the app's windows as shared, and the
/// badge lands in every frame. Framing to the subject happens downstream, by crop.
/// The stream only delivers when something changes, so an idle layer costs next to nothing.
@MainActor
final class ActionAgentLayerFeed {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    /// The app whose windows the viewer and snapshots frame; nil frames the whole layer.
    let subjectPID: pid_t?
    private let logger: DebugLogger
    private let output = ActionAgentLayerStreamOutput()
    private var stream: SCStream?

    init(displayID: CGDirectDisplayID, displayBounds: CGRect, subjectPID: pid_t?, logger: DebugLogger) {
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.subjectPID = subjectPID
        self.logger = logger
    }

    func start() async throws {
        var content: SCShareableContent?
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content?.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard content != nil, let scDisplay else {
            throw ActionHostError.captureFailed("ScreenCaptureKit never listed the agent layer display")
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(displayID)
        config.width = mode?.pixelWidth ?? Int(displayBounds.width)
        config.height = mode?.pixelHeight ?? Int(displayBounds.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // The feed holds the latest frame for snapshots; leave the stream room past it.
        config.queueDepth = 5
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
        logger.log("agent-layer feed: display \(displayID) \(config.width)x\(config.height) subject=\(subjectPID.map(String.init) ?? "all")")
    }

    func stop() async {
        output.detach()
        if #available(macOS 15.0, *), recording != nil { _ = try? await stopRecording() }
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: Recording

    /// `SCRecordingOutput` and its delegate, typed loosely so the feed builds before macOS 15.
    private var recording: (output: AnyObject, delegate: AnyObject, path: String)?

    var recordingPath: String? { recording?.path }

    /// Start writing the feed to a movie: the same stream the viewer shows, joined
    /// mid-flight, so the take starts on the next frame with no capture setup.
    @available(macOS 15.0, *)
    func startRecording(to path: String) async throws {
        guard let stream else { throw ActionHostError.captureFailed("the layer has no feed") }
        guard recording == nil else { throw ActionHostError.captureFailed("already recording to \(recording!.path)") }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let config = SCRecordingOutputConfiguration()
        config.outputURL = url
        config.outputFileType = .mov
        config.videoCodecType = .h264
        let delegate = ActionAgentLayerRecordingDelegate()
        let output = SCRecordingOutput(configuration: config, delegate: delegate)
        try stream.addRecordingOutput(output)
        recording = (output, delegate, path)
        do {
            try await delegate.started()
        } catch {
            try? stream.removeRecordingOutput(output)
            recording = nil
            throw error
        }
        logger.log("agent-layer feed: recording to \(path)")
    }

    /// Finish the movie and return its path. The feed keeps running.
    @available(macOS 15.0, *)
    func stopRecording() async throws -> String {
        guard let stream, let recording,
              let output = recording.output as? SCRecordingOutput,
              let delegate = recording.delegate as? ActionAgentLayerRecordingDelegate else {
            throw ActionHostError.captureFailed("not recording")
        }
        self.recording = nil
        try stream.removeRecordingOutput(output)
        try await delegate.finished()
        logger.log("agent-layer feed: recording finished \(recording.path)")
        return recording.path
    }

    /// Route frames into `layer`. `onFrame` fires once, on the main queue, when a frame
    /// is on it: straight away if the feed already has one.
    func attach(_ layer: AVSampleBufferDisplayLayer, onFrame: @escaping @MainActor () -> Void) {
        output.attach(layer) {
            DispatchQueue.main.async { MainActor.assumeIsolated { onFrame() } }
        }
    }

    func detach() {
        output.detach()
    }

    /// Display-local frames of the windows the feed shows, front to back.
    func windowFrames() -> [(id: CGWindowID, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 40, rect.height > 40,
                  displayBounds.intersects(rect) else { return nil }
            if let subjectPID, (window[kCGWindowOwnerPID as String] as? pid_t) != subjectPID { return nil }
            return (id, rect.intersection(displayBounds).offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY))
        }
    }

    /// Display-local rect around every window the feed shows; nil when there are none.
    func windowsRect(padding: CGFloat) -> CGRect? {
        let frames = windowFrames().map(\.frame)
        guard let first = frames.first else { return nil }
        let full = CGRect(origin: .zero, size: displayBounds.size)
        return frames.dropFirst().reduce(first) { $0.union($1) }
            .insetBy(dx: -padding, dy: -padding)
            .intersection(full)
            .integral
    }

    /// Write the latest frame as a PNG, cropped to one window (by id), to the subject's
    /// windows, or to the whole layer. No capture happens here: the frame is already in hand.
    func snapshot(_ request: ActionAgentLayerSnapshotRequest) -> [String: Any] {
        guard let (pixels, receivedAt) = output.latest() else {
            return ["ok": false, "detail": "the layer has not produced a frame yet"]
        }
        let full = CGRect(origin: .zero, size: displayBounds.size)
        let crop: CGRect
        if let windowID = request.windowID {
            guard let frame = windowFrames().first(where: { $0.id == windowID })?.frame else {
                return ["ok": false, "detail": "window \(windowID) is not on the layer"]
            }
            crop = frame
        } else if request.full {
            crop = full
        } else {
            crop = windowsRect(padding: 0) ?? full
        }

        let image = CIImage(cvPixelBuffer: pixels)
        let scale = image.extent.width / max(displayBounds.width, 1)
        // CIImage runs bottom-up; the display's points run top-down.
        let pixelCrop = CGRect(
            x: crop.minX * scale,
            y: image.extent.height - crop.maxY * scale,
            width: crop.width * scale,
            height: crop.height * scale
        ).integral.intersection(image.extent)
        guard let cgImage = CIContext().createCGImage(image, from: pixelCrop) else {
            return ["ok": false, "detail": "could not read the frame"]
        }

        let url = URL(fileURLWithPath: request.out)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, "public.png" as CFString, 1, nil) else {
            return ["ok": false, "detail": "could not write \(request.out)"]
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return ["ok": false, "detail": "could not write \(request.out)"]
        }
        _ = try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            return ["ok": false, "detail": error.localizedDescription]
        }
        return [
            "ok": true,
            "path": request.out,
            "width": cgImage.width,
            "height": cgImage.height,
            "crop": ["x": crop.minX, "y": crop.minY, "width": crop.width, "height": crop.height],
            "windowId": request.windowID.map { Int($0) } ?? NSNull(),
            // How long the screen has been unchanged, not how stale the picture is:
            // the stream delivers whenever anything on the layer changes.
            "unchangedMs": Int(Date().timeIntervalSince(receivedAt) * 1000),
        ]
    }
}

/// Bridges `SCRecordingOutput`'s delegate callbacks to awaitable start and finish.
@available(macOS 15.0, *)
private final class ActionAgentLayerRecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var startResult: Result<Void, Error>?
    private var finishResult: Result<Void, Error>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<Void, Error>?

    func started() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let startResult { continuation.resume(with: startResult) } else { startWaiter = continuation }
            }
        }
    }

    func finished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let finishResult { continuation.resume(with: finishResult) } else { finishWaiter = continuation }
            }
        }
    }

    private func settle(start: Result<Void, Error>?, finish: Result<Void, Error>?) {
        lock.withLock {
            if let start, startResult == nil {
                startResult = start
                startWaiter?.resume(with: start)
                startWaiter = nil
            }
            if let finish, finishResult == nil {
                finishResult = finish
                finishWaiter?.resume(with: finish)
                finishWaiter = nil
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        settle(start: .success(()), finish: nil)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        settle(start: nil, finish: .success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        settle(start: .failure(error), finish: .failure(error))
    }
}

struct ActionAgentLayerSnapshotRequest {
    let id: String
    let out: String
    let windowID: CGWindowID?
    let full: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let out = json["out"] as? String else { return nil }
        self.id = id
        self.out = out
        self.windowID = (json["windowId"] as? NSNumber).map { CGWindowID($0.uint32Value) }
        self.full = json["full"] as? Bool ?? false
    }
}

// MARK: - Picture in picture

/// What the viewer's dot says, the only state it shows at rest.
enum ActionAgentLayerLiveState {
    /// Solid coral: the agent can act.
    case live
    /// Coral, breathing: a take is being recorded.
    case recording
    /// Hollow: the operator paused the agent; its acts are refused.
    case paused
}

@MainActor
final class ActionAgentLayerPiP {
    private static let width: CGFloat = 380
    private static let margin: CGFloat = 16
    private static let cropPadding: CGFloat = 12
    /// How long a drive note stays on the viewer.
    private static let noteLifetime: TimeInterval = 12
    /// Operator input borrows the pointer, so it runs in order and off the main thread.
    private static let operatorQueue = DispatchQueue(label: "action.agent-layer.operator")

    private let feed: ActionAgentLayerFeed
    private let logger: DebugLogger
    private let startedAt: Date
    let destinationDisplayID: CGDirectDisplayID
    let previewFull: Bool
    private let workspace: String
    private let destinationSerialNumber: UInt32
    private let noteURL: URL?
    private var panel: NSPanel?
    private var viewer: ActionAgentLayerViewerView?
    private var crop: CGRect = .zero
    private var cropTimer: Timer?
    /// The panel's corner frame while it's enlarged, to go back to.
    private var compactFrame: CGRect?
    private var presented = false
    private var shownNoteAt: String?

    /// The operator's controls. `onDismiss` fires after the viewer has gone.
    var onDismiss: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onTakeOver: (() -> Void)?
    var onGoToOwner: (() -> Void)?
    var hasOwner = false

    init(feed: ActionAgentLayerFeed, startedAt: Date, logger: DebugLogger, destinationDisplayID: CGDirectDisplayID, noteURL: URL?, workspace: String, previewFull: Bool) {
        self.feed = feed
        self.startedAt = startedAt
        self.logger = logger
        self.destinationDisplayID = destinationDisplayID
        self.destinationSerialNumber = CGDisplaySerialNumber(destinationDisplayID)
        self.noteURL = noteURL
        self.workspace = workspace
        self.previewFull = previewFull
    }

    private var fullCrop: CGRect { CGRect(origin: .zero, size: feed.displayBounds.size) }

    func start(expectsWindows: Bool, state: ActionAgentLayerLiveState) async throws {
        crop = previewFull ? fullCrop : (feed.windowsRect(padding: Self.cropPadding) ?? fullCrop)
        // Windows the layer just moved reach the window list a beat later; launching on
        // the full display would snap to the window half a second in.
        if expectsWindows && !previewFull {
            for _ in 0..<15 where crop == fullCrop {
                try? await Task.sleep(for: .milliseconds(40))
                crop = feed.windowsRect(padding: Self.cropPadding) ?? fullCrop
            }
        }
        guard operatorScreen != nil else {
            throw ActionHostError.unsupportedOS("The preview destination disappeared before presentation")
        }
        showPanel()
        guard let viewer else { return }
        viewer.state = state
        // Launch on a frame, so the viewer grows in already showing the layer rather
        // than as an empty box. A feed that never delivers still gets a viewer.
        feed.attach(viewer.videoLayer) { [weak self] in
            // Enqueued isn't drawn yet; give the frame a couple of refreshes to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.present() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.present() }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.operatorScreen != nil else {
                    self.dismiss()
                    return
                }
                self.followWindows()
                self.readNote()
            }
        }
        cropTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        logger.log("agent-layer pip: up crop=\(crop)")
    }

    func stop(animated: Bool) {
        cropTimer?.invalidate()
        cropTimer = nil
        feed.detach()
        guard let panel else { return }
        self.panel = nil
        guard animated, !Self.reduceMotion else {
            panel.orderOut(nil)
            return
        }
        // Settle back toward the corner it came from, fading as it goes.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(Self.tucked(panel.frame, scale: 0.94), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Idle overlays leave the window list, not just go transparent.
            panel.orderOut(nil)
        })
    }

    var state: ActionAgentLayerLiveState {
        get { viewer?.state ?? .live }
        set { viewer?.state = newValue }
    }

    /// Show an act on the viewer: the pointer setting off for it, or where it landed.
    /// Global top-left coordinates, as the blink reported them.
    func mark(_ act: ActionAgentLayerAct) {
        let bounds = feed.displayBounds
        guard act.point.map(bounds.contains) ?? act.frame.map(bounds.intersects) ?? false else { return }
        let origin = bounds.origin
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        viewer?.mark(ActionAgentLayerAct(
            kind: act.kind,
            point: act.point.map(local),
            from: act.from.map(local),
            frame: act.frame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
            deltaY: act.deltaY
        ))
    }

    private func dismiss() {
        stop(animated: true)
        onDismiss?()
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `frame` shrunk toward its bottom-right corner, nudged down: where the viewer
    /// launches from and settles back to.
    private static func tucked(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: frame.maxX - size.width, y: frame.minY - 10, width: size.width, height: size.height)
    }

    // MARK: Panel

    private var operatorScreen: NSScreen? {
        guard destinationDisplayID != feed.displayID,
              CGDisplayIsOnline(destinationDisplayID) != 0,
              CGDisplaySerialNumber(destinationDisplayID) == destinationSerialNumber else { return nil }
        return NSScreen.screens.first(where: { screenNumber($0) == destinationDisplayID })
    }

    private func showPanel() {
        guard let screen = operatorScreen else { return }
        let height = (Self.width * crop.height / max(crop.width, 1)).rounded() + ActionAgentLayerPreviewView.chromeHeight
        let visible = screen.visibleFrame
        let frame = CGRect(
            x: visible.maxX - Self.width - Self.margin,
            y: visible.minY + Self.margin,
            width: Self.width,
            height: height
        )

        let panel = ActionAgentLayerPreviewPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.destinationDisplayID = destinationDisplayID
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // The viewer drags itself, so a double-click can reach it.
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.title = "Action · \(workspace)"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityLabel(panel.title)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = CGSize(width: 380, height: 180)

        let content = ActionAgentLayerViewerView(frame: CGRect(origin: .zero, size: frame.size), displaySize: feed.displayBounds.size)
        content.crop = crop
        content.onDoubleClick = { [weak self] in self?.toggleEnlarged() }
        let origin = feed.displayBounds.origin
        content.onOperatorInput = { [logger] input in
            Self.operatorQueue.async {
                func global(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
                do {
                    // A real click: the layer's app keeps the focus it takes, so the
                    // operator's typing follows. No accessibility press, no hand-back.
                    let detail: String
                    switch input {
                    case let .click(p):
                        detail = try ActionBlinkInput.click(at: global(p), holdMs: 40, accessibilityFirst: false, anyDisplay: false, pointerEventLogPath: nil, handBack: false)
                    case let .drag(a, b, ms):
                        detail = try ActionBlinkInput.drag(from: global(a), to: global(b), durationMs: ms, anyDisplay: false, pointerEventLogPath: nil, handBack: false)
                    case let .scroll(p, dx, dy):
                        detail = try ActionBlinkInput.scroll(at: global(p), deltaX: dx, deltaY: dy, durationMs: 16, anyDisplay: false)
                    }
                    logger.log("agent-layer: operator \(detail)")
                } catch {
                    logger.log("agent-layer: operator failed: \(error)")
                }
            }
        }
        content.addControl(symbol: "pause.fill", label: "Pause", toggledSymbol: "play.fill", toggledLabel: "Resume") { [weak self] in
            self?.onTogglePause?()
        }
        content.addControl(symbol: "stop.fill", label: "Stop") { [weak self] in
            self?.onStop?()
        }
        content.addControl(symbol: "person.crop.circle", label: "Agent", enabled: hasOwner) { [weak self] in
            self?.onGoToOwner?()
        }
        content.addControl(symbol: "arrow.uturn.backward", label: "Take over") { [weak self] in
            self?.onTakeOver?()
        }
        let preview = ActionAgentLayerPreviewView(frame: CGRect(origin: .zero, size: frame.size), viewer: content, workspace: workspace)
        preview.onDoubleClick = { [weak self] in self?.toggleEnlarged() }
        preview.onHide = { [weak self] in self?.dismiss() }
        panel.contentView = preview
        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        for case let button as ActionAgentLayerControlButton in content.controls.arrangedSubviews {
            switch button.title {
            case "Stop": button.toolTip = "Stop this layer task without bringing its app forward"
            case "Agent": button.toolTip = "Go to the local app or terminal that opened this layer"
            case "Take over": button.toolTip = "End automation and take control; task-created windows may close"
            default: break
            }
        }
        self.panel = panel
        self.viewer = content
        logger.log("agent-layer pip: layout panel=\(panel.frame) viewer=\(content.frame) controls=\(content.controls.frame) buttons=\(content.controls.arrangedSubviews.map(\.frame))")
    }

    /// Launch: grow out of the screen corner and fade up, expo out. Runs once.
    private func present() {
        guard !presented, let panel else { return }
        presented = true
        let frame = panel.frame
        panel.contentView?.layoutSubtreeIfNeeded()
        guard !Self.reduceMotion else {
            panel.orderFrontRegardless()
            finishPresentation(panel)
            return
        }
        panel.alphaValue = 0
        panel.setFrame(Self.tucked(frame, scale: 0.82), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.finishPresentation(panel)
            self?.logger.log("agent-layer pip: presented frame=\(panel.frame) alpha=\(panel.alphaValue)")
        })
        finishPresentation(panel)
    }

    private func finishPresentation(_ panel: NSPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            for child in view.subviews {
                invalidate(child)
            }
        }
        if let content = panel.contentView {
            invalidate(content)
        }
        panel.display()
        NSApplication.shared.updateWindows()
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }

    /// Double-click: grow to a large centred view of the layer, and back to the corner.
    private func toggleEnlarged() {
        guard let panel, let screen = operatorScreen else { return }
        let target: CGRect
        if let compactFrame {
            target = compactFrame
            self.compactFrame = nil
        } else {
            compactFrame = panel.frame
            let visible = screen.visibleFrame
            let aspect = crop.height / max(crop.width, 1)
            var width = (visible.width * 0.72).rounded()
            if width * aspect + ActionAgentLayerPreviewView.chromeHeight > visible.height * 0.82 {
                width = ((visible.height * 0.82 - ActionAgentLayerPreviewView.chromeHeight) / aspect).rounded()
            }
            let height = (width * aspect).rounded() + ActionAgentLayerPreviewView.chromeHeight
            target = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        }
        animate(panel, to: target, duration: 0.32)
    }

    private func animate(_ panel: NSPanel, to frame: CGRect, duration: TimeInterval) {
        guard !Self.reduceMotion, presented else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func followWindows() {
        guard !previewFull else { return }
        let next = feed.windowsRect(padding: Self.cropPadding) ?? fullCrop
        guard abs(next.minX - crop.minX) > 4 || abs(next.minY - crop.minY) > 4
            || abs(next.width - crop.width) > 4 || abs(next.height - crop.height) > 4 else { return }
        crop = next
        viewer?.crop = next
        guard let panel else { return }
        // Width stays, height follows the crop: from the bottom edge in the corner, from
        // the middle when enlarged.
        let frame = panel.frame
        let height = (frame.width * next.height / max(next.width, 1)).rounded() + ActionAgentLayerPreviewView.chromeHeight
        let y = compactFrame == nil ? frame.minY : frame.midY - height / 2
        animate(panel, to: CGRect(x: frame.minX, y: y, width: frame.width, height: height), duration: 0.28)
    }

    /// The latest `action.drive.note`, while it's fresh and from this layer's lifetime.
    private func readNote() {
        guard let noteURL, let note = Self.latestNote(at: noteURL), note.at != shownNoteAt else { return }
        guard let date = ISO8601DateFormatter.withFractions.date(from: note.at) ?? ISO8601DateFormatter().date(from: note.at),
              date > startedAt, Date().timeIntervalSince(date) < Self.noteLifetime else { return }
        shownNoteAt = note.at
        viewer?.show(note: note.line, for: Self.noteLifetime - Date().timeIntervalSince(date))
    }

    private static func latestNote(at notesURL: URL) -> (at: String, line: String)? {
        guard let handle = try? FileHandle(forReadingFrom: notesURL) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8),
              let last = text.split(separator: "\n").last,
              let json = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              let at = json["at"] as? String, let line = json["line"] as? String else { return nil }
        return (at, line)
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum ActionAgentLayerOperatorInput {
    case click(CGPoint)
    case drag(CGPoint, CGPoint, Int)
    case scroll(CGPoint, Double, Double)
}

private final class ActionAgentLayerPreviewPanel: NSPanel {
    var destinationDisplayID: CGDirectDisplayID?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard let destinationDisplayID else {
            super.setFrame(frameRect, display: flag)
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == destinationDisplayID
        }) else {
            orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        let width = min(frameRect.width, visible.width)
        let height = min(frameRect.height, visible.height)
        let origin = CGPoint(x: min(max(frameRect.minX, visible.minX), visible.maxX - width),
                             y: min(max(frameRect.minY, visible.minY), visible.maxY - height))
        super.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: flag)
    }
}

private final class ActionAgentLayerPreviewView: NSView {
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 38
    static var chromeHeight: CGFloat { headerHeight + footerHeight }

    private let viewer: ActionAgentLayerViewerView
    private let hostname = ActionAgentLayerHostnameLabel(labelWithString: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    private let hideButton = ActionAgentLayerControlButton(symbol: nil, label: "Hide", toggledSymbol: nil, toggledLabel: nil)
    var onHide: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(frame: CGRect, viewer: ActionAgentLayerViewerView, workspace: String) {
        self.viewer = viewer
        super.init(frame: frame)
        hostname.stringValue = "\(workspace) · \(hostname.stringValue)"
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        hostname.font = .systemFont(ofSize: 11, weight: .medium)
        hostname.textColor = .secondaryLabelColor
        hostname.lineBreakMode = .byTruncatingMiddle
        hostname.maximumNumberOfLines = 1
        hostname.toolTip = hostname.stringValue
        hostname.setAccessibilityLabel("Virtual workspace and host: \(hostname.stringValue)")
        hideButton.toolTip = "Hide the viewer; the layer task continues"
        hideButton.onPress = { [weak self] in self?.onHide?() }
        addSubview(viewer)
        addSubview(viewer.controls)
        addSubview(hostname)
        addSubview(hideButton)
        layoutContent()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    private func layoutContent() {
        let headerY = bounds.height - Self.headerHeight
        hostname.frame = CGRect(x: 10, y: headerY + 5, width: max(bounds.width - 70, 0), height: 16)
        hideButton.frame = CGRect(x: bounds.width - 54, y: headerY + 1, width: 46, height: 24)
        viewer.controls.frame = CGRect(x: 8, y: 6, width: max(bounds.width - 16, 0), height: 26)
        let availableHeight = max(bounds.height - Self.chromeHeight, 1)
        let aspect = max(viewer.crop.width, 1) / max(viewer.crop.height, 1)
        let width = min(bounds.width, availableHeight * aspect)
        let height = width / aspect
        viewer.frame = CGRect(x: (bounds.width - width) / 2, y: Self.footerHeight + (availableHeight - height) / 2, width: width, height: height)
        viewer.controls.layoutSubtreeIfNeeded()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= bounds.height - Self.headerHeight else { return }
        if event.clickCount == 2 { onDoubleClick?() }
        else { window?.performDrag(with: event) }
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: bounds.height - Self.headerHeight, width: max(bounds.width - 58, 0), height: Self.headerHeight), cursor: .openHand)
    }
}

private final class ActionAgentLayerHostnameLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ActionAgentLayerViewerView: NSView {
    private static let ink = NSColor(srgbRed: 0x10 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1)
    private static let coral = NSColor(srgbRed: 0xEF / 255, green: 0x6A / 255, blue: 0x47 / 255, alpha: 1)

    let videoLayer = AVSampleBufferDisplayLayer()
    private let displaySize: CGSize
    private let marks = CALayer()
    /// The agent's pointer at viewer scale: it glides to each point act and rests there
    /// until the layer goes quiet.
    private let pointer = CAShapeLayer()
    private var pointerAt: CGPoint?
    private var pointerHide: DispatchWorkItem?
    private var pointerArrives: CFTimeInterval = 0
    private let dot = CALayer()
    let controls = NSStackView()
    private let note = NSTextField(labelWithString: "")
    private var noteHide: DispatchWorkItem?
    var onDoubleClick: (() -> Void)?
    /// The operator clicking, dragging or scrolling in the picture, in display-local points.
    var onOperatorInput: ((ActionAgentLayerOperatorInput) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var crop: CGRect = .zero { didSet { needsLayout = true } }
    var state: ActionAgentLayerLiveState = .live { didSet { applyState() } }

    init(frame: NSRect, displaySize: CGSize) {
        self.displaySize = displaySize
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.cornerRadius = 10
        root.cornerCurve = .continuous
        root.masksToBounds = true
        root.backgroundColor = Self.ink.cgColor
        root.borderWidth = 1
        root.borderColor = NSColor(white: 0.95, alpha: 0.16).cgColor

        videoLayer.videoGravity = .resize
        root.addSublayer(videoLayer)
        marks.zPosition = 1
        root.addSublayer(marks)
        pointer.path = ActionCursorGlyph.path(scale: 0.44)
        pointer.fillColor = NSColor(white: 0.98, alpha: 1).cgColor
        pointer.strokeColor = Self.ink.cgColor
        pointer.lineWidth = 0.9
        pointer.lineJoin = .round
        pointer.shadowColor = NSColor.black.cgColor
        pointer.shadowOpacity = 0.3
        pointer.shadowRadius = 1.5
        pointer.shadowOffset = CGSize(width: 0.5, height: -0.5)
        pointer.opacity = 0
        pointer.zPosition = 1.5
        // A slight lean, as the operator overlay draws it.
        pointer.setAffineTransform(CGAffineTransform(rotationAngle: 18 * .pi / 180))
        root.addSublayer(pointer)

        // Bottom-right: the top-left corner is where the subject's traffic lights land.
        dot.frame = CGRect(x: frame.width - 16, y: 10, width: 6, height: 6)
        dot.autoresizingMask = [.layerMinXMargin]
        dot.cornerRadius = 3
        dot.zPosition = 2
        root.addSublayer(dot)
        applyState()

        note.font = .systemFont(ofSize: 11, weight: .medium)
        note.textColor = NSColor(white: 0.95, alpha: 1)
        note.lineBreakMode = .byTruncatingTail
        note.maximumNumberOfLines = 1
        note.drawsBackground = false
        note.alphaValue = 0
        note.wantsLayer = true
        note.layer?.backgroundColor = Self.ink.withAlphaComponent(0.78).cgColor
        note.layer?.cornerRadius = 4
        addSubview(note)

        controls.orientation = .horizontal
        controls.spacing = 6
        controls.distribution = .fillEqually
    }

    required init?(coder: NSCoder) { nil }

    func addControl(symbol: String?, label: String, enabled: Bool = true, toggledSymbol: String? = nil, toggledLabel: String? = nil, action: @escaping () -> Void) {
        let button = ActionAgentLayerControlButton(symbol: symbol, label: label, toggledSymbol: toggledSymbol, toggledLabel: toggledLabel)
        button.isEnabled = enabled
        button.onPress = action
        controls.addArrangedSubview(button)
        needsLayout = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var operatorPress: (at: CGPoint, time: TimeInterval)?
    private var scrollPending = CGVector.zero
    private var scrollAt: CGPoint?
    private var scrollFlush: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let grabs = onOperatorInput == nil
            || event.modifierFlags.contains(.command)
        guard grabs else {
            operatorPress = (point, event.timestamp)
            return
        }
        operatorPress = nil
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = operatorPress, let onOperatorInput else { return }
        operatorPress = nil
        let end = convert(event.locationInWindow, from: nil)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if hypot(end.x - start.at.x, end.y - start.at.y) < 4 {
            ring(at: start.at, reduce: reduce, size: 18)
            onOperatorInput(.click(layerPoint(start.at)))
        } else {
            let ms = min(max(Int((event.timestamp - start.time) * 1000), 120), 900)
            fadeOut(trail(from: start.at, to: end, duration: 0), after: 0.4)
            onOperatorInput(.drag(layerPoint(start.at), layerPoint(end), ms))
        }
    }

    /// Wheel deltas gather for a beat and go over as one scroll, so a trackpad flick is a
    /// handful of borrows rather than one per frame.
    override func scrollWheel(with event: NSEvent) {
        guard onOperatorInput != nil else { return super.scrollWheel(with: event) }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollPending.dx += event.scrollingDeltaX * k / scale
        scrollPending.dy += event.scrollingDeltaY * k / scale
        scrollAt = layerPoint(convert(event.locationInWindow, from: nil))
        guard scrollFlush == nil else { return }
        let flush = DispatchWorkItem { [weak self] in
            guard let self, let at = self.scrollAt else { return }
            let delta = self.scrollPending
            self.scrollPending = .zero
            self.scrollFlush = nil
            guard abs(delta.dx) >= 1 || abs(delta.dy) >= 1 else { return }
            self.onOperatorInput?(.scroll(at, delta.dx, delta.dy))
        }
        scrollFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: flush)
    }

    override func layout() {
        super.layout()
        layoutNote()
        guard crop.width > 0, crop.height > 0 else { return }
        // Scale so the crop's width fills ours; lay the whole display out from its top-left,
        // shifted so the crop's top-left lands on ours. Layer space runs bottom-up.
        let k = scale
        let height = displaySize.height * k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = CGRect(
            x: -crop.minX * k,
            y: bounds.height + crop.minY * k - height,
            width: displaySize.width * k,
            height: height
        )
        marks.frame = bounds
        CATransaction.commit()
    }

    private var scale: CGFloat { bounds.width / max(crop.width, 1) }

    /// Display-local top-left point to our bottom-up coordinates.
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - crop.minX) * scale, y: bounds.height - (point.y - crop.minY) * scale)
    }

    /// Our bottom-up coordinates back to a display-local top-left point.
    private func layerPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale + crop.minX, y: (bounds.height - point.y) / scale + crop.minY)
    }

    private func applyState() {
        dot.removeAnimation(forKey: "breathe")
        switch state {
        case .live, .recording:
            dot.backgroundColor = Self.coral.cgColor
            dot.borderWidth = 0
        case .paused:
            dot.backgroundColor = NSColor.clear.cgColor
            dot.borderColor = Self.coral.cgColor
            dot.borderWidth = 1.25
        }
        if state == .recording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.3
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(breathe, forKey: "breathe")
        }
        for case let button as ActionAgentLayerControlButton in controls.arrangedSubviews where button.toggles {
            button.isToggled = state == .paused
        }
    }

    /// Sends the pointer to `target` along a shallow arc, quicker for short hops, and
    /// returns when it gets there (as a media time).
    @discardableResult
    private func movePointer(to target: CGPoint, reduceMotion: Bool, straight: Bool = false, duration fixed: CFTimeInterval? = nil) -> CFTimeInterval {
        let from = pointer.presentation()?.position ?? pointerAt ?? target
        let wasShown = pointerAt != nil && pointer.opacity > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = target
        pointer.opacity = 1
        CATransaction.commit()
        let now = CACurrentMediaTime()
        var arrives = now
        let distance = hypot(target.x - from.x, target.y - from.y)
        if reduceMotion || distance < 1 {
            pointerArrives = now
        } else if !wasShown {
            // Appears where it's going, settling in from a touch further out.
            let appear = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let settle = CABasicAnimation(keyPath: "position")
            settle.fromValue = NSValue(point: CGPoint(x: target.x + 14, y: target.y - 14))
            settle.toValue = NSValue(point: target)
            appear.animations = [fade, settle]
            appear.duration = 0.26
            appear.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            pointer.add(appear, forKey: "glide")
            arrives = now + appear.duration
        } else {
            let duration = fixed ?? min(0.62, max(0.26, 0.2 + Double(distance) / 700))
            let path = CGMutablePath()
            path.move(to: from)
            if straight {
                path.addLine(to: target)
            } else {
                // Bow to the left of travel by a fraction of the hop, the way a hand swings.
                let mid = CGPoint(x: (from.x + target.x) / 2, y: (from.y + target.y) / 2)
                let bow = min(distance * 0.16, 36) / distance
                let control = CGPoint(x: mid.x - (target.y - from.y) * bow, y: mid.y + (target.x - from.x) * bow)
                path.addQuadCurve(to: target, control: control)
            }
            let glide = CAKeyframeAnimation(keyPath: "position")
            glide.path = path
            glide.duration = duration
            glide.timingFunction = straight
                ? CAMediaTimingFunction(name: .easeInEaseOut)
                : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.15, 1)
            glide.calculationMode = .paced
            pointer.add(glide, forKey: "glide")
            arrives = now + duration
        }
        pointerAt = target
        pointerArrives = arrives
        pointerHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            self.pointer.opacity = 0
            CATransaction.commit()
        }
        pointerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + (arrives - now) + 3.5, execute: hide)
        return arrives
    }

    /// Runs `body` once the pointer has arrived.
    private func onArrival(_ body: @escaping () -> Void) {
        let wait = pointerArrives - CACurrentMediaTime()
        if wait > 0.01 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: body)
        } else {
            body()
        }
    }

    /// A press: the pointer dips and springs back.
    private func press() {
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.78, 1.06, 1]
        dip.keyTimes = [0, 0.3, 0.7, 1]
        dip.duration = 0.26
        dip.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        pointer.add(dip, forKey: "press")
    }

    func mark(_ act: ActionAgentLayerAct) {
        guard crop.width > 0 else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let frame = act.frame {
            // Typing and keys: the pointer drifts to the field's leading edge and the
            // field lights up.
            let a = viewPoint(frame.origin)
            let b = viewPoint(CGPoint(x: frame.maxX, y: frame.maxY))
            movePointer(to: CGPoint(x: a.x + min(14, (b.x - a.x) / 2), y: (a.y + b.y) / 2 - 2), reduceMotion: reduce)
            onArrival { [weak self] in self?.markField(from: a, to: b) }
            return
        }
        guard let point = act.point else { return }
        let center = viewPoint(point)
        switch act.kind {
        case "aim":
            movePointer(to: center, reduceMotion: reduce)
        case "drag":
            let start = act.from.map(viewPoint) ?? center
            if pointerAt.map({ hypot($0.x - start.x, $0.y - start.y) > 2 }) ?? true {
                movePointer(to: start, reduceMotion: reduce)
            }
            onArrival { [weak self] in
                guard let self else { return }
                self.press()
                let trail = self.trail(from: start, to: center, duration: reduce ? 0 : 0.5)
                self.movePointer(to: center, reduceMotion: reduce, straight: true, duration: 0.5)
                self.onArrival { [weak self] in
                    self?.ring(at: center, reduce: reduce, size: 16)
                    self?.fadeOut(trail, after: 0.15)
                }
            }
        case "scroll":
            if pointerAt.map({ hypot($0.x - center.x, $0.y - center.y) > 2 }) ?? true {
                movePointer(to: center, reduceMotion: reduce)
            }
            onArrival { [weak self] in self?.nudge(down: act.deltaY < 0, reduce: reduce) }
        default:
            if pointerAt.map({ hypot($0.x - center.x, $0.y - center.y) > 2 }) ?? true {
                movePointer(to: center, reduceMotion: reduce)
            }
            onArrival { [weak self] in
                self?.press()
                self?.ring(at: center, reduce: reduce, size: 24)
            }
        }
    }

    /// A coral ring that opens and fades where a click landed.
    private func ring(at center: CGPoint, reduce: Bool, size: CGFloat) {
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = Self.coral.cgColor
        shape.lineWidth = 1.75
        shape.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        shape.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        if !reduce {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 1.3
            grow.duration = 0.7
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            shape.add(grow, forKey: "grow")
        }
        marks.addSublayer(shape)
        fadeOut(shape, after: 0.25)
    }

    /// The field typing went into: its own edges, snapped to pixels, rounded like the pill
    /// or box it most likely sits in, with a tint so it reads at PiP scale.
    private func markField(from a: CGPoint, to b: CGPoint) {
        let pixel = 1 / max(window?.backingScaleFactor ?? 2, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value / pixel).rounded() * pixel }
        let rect = CGRect(x: snap(a.x), y: snap(b.y), width: snap(b.x - a.x), height: snap(a.y - b.y))
        guard rect.width >= 4, rect.height >= 4 else { return }
        let shape = CAShapeLayer()
        let radius = min(rect.height / 2, 6)
        shape.lineWidth = 1.25
        shape.strokeColor = Self.coral.cgColor
        shape.fillColor = Self.coral.withAlphaComponent(0.14).cgColor
        shape.path = CGPath(
            roundedRect: rect.insetBy(dx: shape.lineWidth / 2, dy: shape.lineWidth / 2),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        marks.addSublayer(shape)
        fadeOut(shape, after: 0.6)
    }

    /// The line a drag draws, laid down behind the pointer.
    private func trail(from start: CGPoint, to end: CGPoint, duration: CFTimeInterval) -> CAShapeLayer {
        let line = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        line.path = path
        line.strokeColor = Self.coral.withAlphaComponent(0.85).cgColor
        line.lineWidth = 1.5
        line.lineCap = .round
        line.lineDashPattern = [1, 4]
        line.fillColor = nil
        marks.addSublayer(line)
        if duration > 0 {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = duration
            draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            line.add(draw, forKey: "draw")
        }
        return line
    }

    /// A scroll: the pointer rolls a couple of notches the way the content went.
    private func nudge(down: Bool, reduce: Bool) {
        guard !reduce else { return }
        let travel: CGFloat = down ? -7 : 7
        let roll = CAKeyframeAnimation(keyPath: "transform.translation.y")
        roll.values = [0, travel, 0, travel, 0]
        roll.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        roll.duration = 0.5
        roll.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        roll.isAdditive = true
        pointer.add(roll, forKey: "roll")
    }

    private func fadeOut(_ shape: CALayer, after delay: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = 0.5
        fade.fillMode = .both
        shape.opacity = 0
        shape.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    func show(note text: String, for seconds: TimeInterval) {
        note.stringValue = " \(text) "
        needsLayout = true
        noteHide?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            note.animator().alphaValue = 1
        }
        let hide = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.note.animator().alphaValue = 0
            }
        }
        noteHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 1), execute: hide)
    }

    private func layoutNote() {
        let size = note.fittingSize
        let width = min(size.width, bounds.width - 32)
        note.frame = CGRect(x: 8, y: 8, width: width, height: size.height + 2)
    }
}

/// Keeps the feed's latest frame and hands frames to an attached display layer, on
/// the capture queue.
private final class ActionAgentLayerStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.arach.action.agent-layer.feed")
    private let lock = NSLock()
    private var layer: AVSampleBufferDisplayLayer?
    private var onAttachedFrame: (() -> Void)?
    private var latestBuffer: CMSampleBuffer?
    private var latestAt = Date.distantPast

    func attach(_ layer: AVSampleBufferDisplayLayer, onFrame: @escaping () -> Void) {
        queue.async { [self] in
            lock.withLock {
                self.layer = layer
                self.onAttachedFrame = onFrame
            }
            // A feed that's been running has a frame already; show it now.
            if let latest = lock.withLock({ latestBuffer }) { deliver(latest) }
        }
    }

    func detach() {
        lock.withLock {
            layer = nil
            onAttachedFrame = nil
        }
    }

    func latest() -> (CVPixelBuffer, Date)? {
        lock.withLock {
            guard let buffer = latestBuffer, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
            return (pixels, latestAt)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer) else { return }
        lock.withLock {
            latestBuffer = sampleBuffer
            latestAt = Date()
        }
        deliver(sampleBuffer)
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer) {
        let (layer, onFrame) = lock.withLock { () -> (AVSampleBufferDisplayLayer?, (() -> Void)?) in
            let pending = onAttachedFrame
            onAttachedFrame = nil
            return (self.layer, pending)
        }
        guard let layer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        if #available(macOS 15.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sampleBuffer)
        } else {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sampleBuffer)
        }
        onFrame?()
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The WindowServer id behind an accessibility window, matching `kCGWindowNumber`.
private func axWindowID(_ window: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
}

private final class ActionAgentLayerControlButton: NSButton {
    var onPress: (() -> Void)?
    var isToggled = false { didSet { applyLabel() } }
    var toggles: Bool { toggledSymbol != nil }
    private let symbol: String?
    private let label: String
    private let toggledSymbol: String?
    private let toggledLabel: String?

    init(symbol: String?, label: String, toggledSymbol: String?, toggledLabel: String?) {
        self.symbol = symbol
        self.label = label
        self.toggledSymbol = toggledSymbol
        self.toggledLabel = toggledLabel
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11)
        imagePosition = .imageLeading
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
        applyLabel()
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyLabel() {
        title = isToggled ? (toggledLabel ?? label) : label
        let symbolName = isToggled ? (toggledSymbol ?? symbol) : symbol
        image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        setAccessibilityLabel(title)
        if toggles { toolTip = isToggled ? "Resume layer actions" : "Pause layer actions" }
    }

    @objc private func pressed() {
        guard isEnabled else { return }
        onPress?()
    }
}

/// What the host told the layer about an act: `aim` before a pointer act sets off,
/// then `click`, `drag` (with `from`), `scroll` (with its wheel delta) or `field`.
struct ActionAgentLayerAct: Sendable {
    let kind: String
    let point: CGPoint?
    let from: CGPoint?
    let frame: CGRect?
    let deltaY: CGFloat
}

extension ActionAgentLayerAct {
    /// From an act notification's userInfo or a `mark` control request: `kind`, `x`/`y`,
    /// `fromX`/`fromY`, `fx`/`fy`/`fw`/`fh` and `dy`, in global top-left points.
    init<Key: Hashable>(info: [Key: Any]) {
        func number(_ key: String) -> CGFloat? {
            guard let key = key as? Key else { return nil }
            return (info[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        func point(_ x: String, _ y: String) -> CGPoint? {
            number(x).flatMap { x in number(y).map { CGPoint(x: x, y: $0) } }
        }
        let frame: CGRect? = {
            guard let x = number("fx"), let y = number("fy"), let w = number("fw"), let h = number("fh") else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }()
        self.init(
            kind: ("kind" as? Key).flatMap { info[$0] as? String } ?? "click",
            point: point("x", "y"),
            from: point("fromX", "fromY"),
            frame: frame,
            deltaY: number("dy") ?? 0
        )
    }
}
