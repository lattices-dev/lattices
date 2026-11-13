import ActionCore
import ActionVirtualDisplay
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class ActionAgentDisplayController {
    private struct State: Codable {
        let schemaVersion: Int
        let pid: pid_t
        let displayId: CGDirectDisplayID
        let startedAt: String
        let width: Int
        let height: Int
        let serialNumber: UInt32
        let workspace: String
        let returnToMac: Bool
        let returnShortcut: String?
    }

    private let workspace: ActionVirtualWorkspace
    private let size: CGSize
    private let stateURL: URL
    private let stopURL: URL
    private let writer: ResponseWriter
    private let logger: DebugLogger
    private let returnToMac: Bool
    private var display: CGVirtualDisplay?
    private var lockDescriptor: Int32 = -1
    private var topologyLock: ActionWorkspaceLock?
    private var setupLeaseDescriptor: Int32 = -1
    private var state: State?
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var shuttingDown = false
    private var recovery: ActionMonitorReturn?
    private var recovering = false
    private var lastReturnRequest: Data?
    private var returnWhilePreparing = false

    init(options: CommandOptions) throws {
        workspace = try ActionVirtualWorkspace(options.options["workspace"] ?? "default")
        let width = options.double("width", default: 1440)
        let height = options.double("height", default: 900)
        guard width.isFinite, height.isFinite, width.rounded() == width, height.rounded() == height,
              width >= 640, height >= 400, width <= 8192, height <= 8192 else {
            throw ActionHostError.unsupportedOS("Display size must be whole pixels between 640x400 and 8192x8192")
        }
        size = CGSize(width: width, height: height)
        stateURL = URL(fileURLWithPath: try options.required("state-file"))
        stopURL = URL(fileURLWithPath: try options.required("stop-file"))
        writer = ResponseWriter(replyFile: options.options["reply-file"])
        logger = DebugLogger(path: options.options["debug-log"])
        if let raw = options.options["return-to-mac"], !["true", "false", "1", "0", "yes", "no"].contains(raw.lowercased()) {
            throw ActionHostError.unsupportedOS("return-to-mac must be a boolean")
        }
        returnToMac = options.bool("return-to-mac", default: false)
    }

    func run() throws {
        if let refusal = ActionLayerSafetyGate.refusal(for: ActionLayerSafetyGate.read()) {
            throw ActionHostError.unsupportedOS(refusal)
        }
        let lockURL = ActionLayerSafetyGate.defaultURL.deletingLastPathComponent()
            .appendingPathComponent(workspace.ownerLockName)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ActionHostError.unsupportedOS("An Action display owner is already running; reuse its prepared display")
        }
        topologyLock = try ActionWorkspaceLock(url: topologyLockURL)
        guard !ActionAgentLayerDisplay.displays().contains(where: { CGDisplaySerialNumber($0) == workspace.serialNumber }) else {
            throw ActionHostError.unsupportedOS("An Action display already uses this workspace identity; reuse its owner instead of preparing another")
        }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let leaseURL = stateURL.deletingLastPathComponent().appendingPathComponent("display-session.lock")
        setupLeaseDescriptor = Darwin.open(leaseURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard setupLeaseDescriptor >= 0, flock(setupLeaseDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ActionHostError.unsupportedOS("A task session or display release is still using this display state directory")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.stopIfUnused() }
            }
            source.resume()
            signals.append(source)
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.checkReturnRequest()
                if FileManager.default.fileExists(atPath: self.stopURL.path) {
                    self.stopIfUnused()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in
            do {
                try await self.prepare()
            } catch {
                self.logger.log("agent-display: failed: \(error.localizedDescription)")
                try? self.writer.write(ActionHostResponse(status: "error", outputPath: nil, detail: error.localizedDescription))
                self.shutdown(exitCode: 1)
            }
        }
        app.run()
    }

    private func prepare() async throws {
        if returnToMac {
            let recovery = ActionMonitorReturn(directory: stateURL.deletingLastPathComponent(), logger: logger)
            self.recovery = recovery
            try await recovery.prepare { [weak self] in self?.requestReturnToMac() }
        }
        log("display-owner-pre-create")
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = workspace.name == "default" ? "Action Agent Layer" : "Action · \(workspace.name)"
        // Room for the 2x backing store; the display still lays out in points.
        descriptor.maxPixelsWide = UInt32(size.width * 2)
        descriptor.maxPixelsHigh = UInt32(size.height * 2)
        descriptor.sizeInMillimeters = CGSize(width: size.width / 110 * 25.4, height: size.height / 110 * 25.4)
        descriptor.vendorID = ActionAgentLayerDisplay.vendorID
        descriptor.productID = ActionAgentLayerDisplay.productID
        descriptor.serialNum = workspace.serialNumber
        if descriptor.responds(to: NSSelectorFromString("setSerialNumber:")) {
            descriptor.serialNumber = workspace.serialNumber
        }
        guard let created = CGVirtualDisplay(descriptor: descriptor) else {
            throw ActionHostError.unsupportedOS("Could not prepare the Action virtual display")
        }
        display = created
        log("display-owner-post-init")
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(size.width * 2), height: UInt(size.height * 2), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: 60),
        ]
        let applied = created.apply(settings)
        log("display-owner-post-apply", result: String(applied))
        guard applied else {
            throw ActionHostError.unsupportedOS("The prepared display refused its mode")
        }
        for _ in 0..<60 {
            if CGDisplayIsOnline(created.displayID) != 0, CGDisplayIsActive(created.displayID) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard CGDisplayIsOnline(created.displayID) != 0, CGDisplayIsActive(created.displayID) != 0,
              CGDisplaySerialNumber(created.displayID) == workspace.serialNumber else {
            throw ActionHostError.unsupportedOS("The prepared display did not become available with its stable identity")
        }
        try selectRetinaMode(created.displayID)
        try placeOffCorner(created.displayID)
        let bounds = CGDisplayBounds(created.displayID)
        guard bounds.width == size.width, bounds.height == size.height else {
            throw ActionHostError.unsupportedOS("The prepared display's actual size does not match the requested size")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = State(schemaVersion: 1, pid: getpid(), displayId: created.displayID,
                          startedAt: formatter.string(from: Date()), width: Int(size.width),
                          height: Int(size.height), serialNumber: workspace.serialNumber, workspace: workspace.name,
                          returnToMac: returnToMac, returnShortcut: returnToMac ? ActionMonitorReturn.shortcut : nil)
        self.state = state
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        log("display-owner-ready")
        try writer.write(ActionHostResponse(status: "agent-display-running", outputPath: stateURL.path, detail: String(getpid())))
        Darwin.close(setupLeaseDescriptor)
        setupLeaseDescriptor = -1
        topologyLock = nil
        if returnWhilePreparing { requestReturnToMac() }
    }

    /// Picks the requested point size backed at 2x, so captures of the layer are Retina.
    private func selectRetinaMode(_ displayID: CGDirectDisplayID) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        guard let retina = modes.first(where: {
            $0.width == Int(size.width) && $0.height == Int(size.height) && $0.pixelWidth == Int(size.width) * 2
        }) else {
            log("display-owner-no-retina-mode", result: modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }.joined(separator: ","))
            return
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw ActionHostError.unsupportedOS("Could not start display mode selection")
        }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, retina, nil) == .success,
              CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw ActionHostError.unsupportedOS("Could not select the 2x display mode")
        }
        log("display-owner-retina-mode", result: "\(retina.width)x\(retina.height)@\(retina.pixelWidth)")
    }

    private func placeOffCorner(_ displayID: CGDirectDisplayID) throws {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw ActionHostError.unsupportedOS("Could not enumerate physical displays")
        }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else {
            throw ActionHostError.unsupportedOS("Could not enumerate physical displays")
        }
        let others = identifiers.prefix(Int(count)).filter { $0 != displayID }
        guard others.contains(where: { !ActionAgentLayerDisplay.isAgentLayer($0) }),
              let origin = ActionVirtualWorkspace.offscreenOrigin(otherBounds: others.map(CGDisplayBounds)) else {
            throw ActionHostError.unsupportedOS("A physical display is required before preparing the agent display")
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw ActionHostError.unsupportedOS("Could not start display placement")
        }
        guard CGConfigureDisplayOrigin(configuration, displayID, Int32(origin.x), Int32(origin.y)) == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw ActionHostError.unsupportedOS("Could not place the prepared display")
        }
        guard CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success else {
            throw ActionHostError.unsupportedOS("Could not complete display placement")
        }
    }

    private func stopIfUnused() {
        guard !recovering else { return }
        // Explicit release of an interactive monitor must use the same recovery
        // transaction as its button/shortcut, including manually moved windows.
        if returnToMac, state != nil {
            try? FileManager.default.removeItem(at: stopURL)
            requestReturnToMac()
            return
        }
        let previewLock: ActionWorkspaceLock
        do {
            previewLock = try ActionWorkspaceLock(url: stateURL.deletingLastPathComponent().appendingPathComponent("display-preview.lock"))
        } catch {
            logger.log("agent-display: close previews hosted on this display before releasing it")
            try? FileManager.default.removeItem(at: stopURL)
            return
        }
        defer { withExtendedLifetime(previewLock) {} }
        let leaseURL = stateURL.deletingLastPathComponent().appendingPathComponent("display-session.lock")
        let leaseDescriptor = Darwin.open(leaseURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard leaseDescriptor >= 0 else {
            logger.log("agent-display: could not acquire the session lease for release")
            return
        }
        guard flock(leaseDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(leaseDescriptor)
            logger.log("agent-display: close the attached task session before releasing its display")
            try? FileManager.default.removeItem(at: stopURL)
            return
        }
        defer { Darwin.close(leaseDescriptor) }
        let sessionURL = stateURL.deletingLastPathComponent().appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            guard let data = try? Data(contentsOf: sessionURL),
                  let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = session["pid"] as? Int32 else {
                logger.log("agent-display: refusing release with an unreadable session state")
                try? FileManager.default.removeItem(at: stopURL)
                return
            }
            if kill(pid, 0) == 0 || errno == EPERM {
                logger.log("agent-display: close the live task session before releasing its display")
                try? FileManager.default.removeItem(at: stopURL)
                return
            }
        }
        do {
            topologyLock = try ActionWorkspaceLock(url: topologyLockURL)
            shutdown(exitCode: 0)
        } catch {
            logger.log("agent-display: topology change is busy; retry release")
        }
    }

    private var topologyLockURL: URL {
        ActionLayerSafetyGate.defaultURL.deletingLastPathComponent().appendingPathComponent("display-topology.lock")
    }

    private func requestReturnToMac() {
        guard !shuttingDown, !recovering, let recovery else { return }
        guard let state else { returnWhilePreparing = true; return }
        let request = ActionMonitorReturn.Request(requestId: UUID().uuidString, workspace: workspace.name,
            displayId: state.displayId, displayOwnerPid: state.pid, displayStartedAt: state.startedAt, reason: "operator")
        do { try recovery.writeRequest(request); checkReturnRequest() }
        catch { recovery.status("failed", request: request, detail: error.localizedDescription) }
    }

    private func checkReturnRequest() {
        guard !recovering, !shuttingDown, let recovery, let state,
              let data = try? Data(contentsOf: recovery.requestURL), data != lastReturnRequest else { return }
        lastReturnRequest = data
        guard let request = try? JSONDecoder().decode(ActionMonitorReturn.Request.self, from: data),
              !request.requestId.isEmpty, request.workspace == workspace.name,
              request.displayId == state.displayId, request.displayOwnerPid == state.pid,
              request.displayStartedAt == state.startedAt else {
            logger.log("return-to-mac: rejected request with mismatched monitor identity")
            return
        }
        recovering = true
        recovery.status("recovering", request: request, detail: "Returning every window to a physical desktop…")
        Task { @MainActor in
            do {
                let held = try await recovery.recover(request: request, serial: self.workspace.serialNumber)
                defer { withExtendedLifetime(held) {} }
                try recovery.verifyBeforeDisconnect(held, request: request, serial: self.workspace.serialNumber)
                self.log("display-owner-before-return-release")
                self.display = nil
                self.log("display-owner-after-return-release")
                try await recovery.finish(held, request: request)
                // The shortcut and status item remain alive through verification.
                self.shuttingDown = true
                self.timer?.invalidate()
                try? FileManager.default.removeItem(at: self.stateURL)
                try? FileManager.default.removeItem(at: self.stopURL)
                Darwin.exit(0)
            } catch {
                self.recovering = false
                recovery.status("failed", request: request, detail: error.localizedDescription)
            }
        }
    }

    private func shutdown(exitCode: Int32) {
        guard !shuttingDown else { return }
        shuttingDown = true
        timer?.invalidate()
        log("display-owner-before-release")
        display = nil
        log("display-owner-after-release")
        if state != nil { try? FileManager.default.removeItem(at: stateURL) }
        try? FileManager.default.removeItem(at: stopURL)
        Darwin.exit(exitCode)
    }

    private func log(_ stage: String, result: String? = nil) {
        logger.log(ActionAgentLayerDiagnostics.snapshot(stage: stage, layerDisplayID: display?.displayID ?? 0,
                                                        requestedSize: size, result: result))
    }
}
