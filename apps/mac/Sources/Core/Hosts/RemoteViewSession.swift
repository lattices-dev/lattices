import AppKit
import Foundation

/// One live view of another machine: a monitor, an app's window, or a region.
///
/// A host with `capture.stream` pushes H.264 over its own socket while the
/// viewer is on screen; otherwise frames are pulled with `capture.still`, one
/// at a time. Input goes back as the host's `computer.*` methods, and only
/// after the viewer turns control on.
@MainActor
final class RemoteViewSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        case connecting
        case live
        case paused
        case failed(String)
    }

    let host: String
    let address: String
    let port: UInt16
    let id = UUID()

    @Published private(set) var status: Status = .connecting
    @Published var target: RemoteView.Target { didSet { if oldValue != target { retarget() } } }
    @Published var resolution: RemoteView.Resolution = .automatic { didSet {
        if oldValue != resolution { wake() }
    } }
    @Published private(set) var image: NSImage?
    /// The picture comes from `video.layer` rather than `image`.
    @Published private(set) var showingVideo = false
    @Published private(set) var videoSize: CGSize = .zero
    /// What the current picture covers, in the host's layout coordinates.
    @Published private(set) var frame: CGRect = .zero
    @Published private(set) var displays: [RemoteView.Display] = []
    @Published private(set) var windows: [RemoteHostsModel.Window] = []
    @Published private(set) var platform: String?
    @Published private(set) var fps: Double = 0
    @Published private(set) var streamActivity: RemoteView.StreamActivity?
    @Published private(set) var videoFallbackReason: String?
    @Published private(set) var isRecoveringVideo = false
    @Published private(set) var latency: Int = 0
    @Published private(set) var canStill = true
    @Published private(set) var canControl = false
    @Published var controlling = false { didSet {
        if oldValue != controlling {
            DiagnosticLog.shared.info("RemoteKeyboard: \(host) control=\(controlling) physical=\(canCaptureKeyboard)")
            if controlling { keyboardEnabled = canSendKeyboard }
            else {
                keyboardEnabled = false
                releaseInput()
            }
            if streamID != nil { wake() }
        }
    } }
    @Published private(set) var livePointer = false
    @Published private(set) var canSendKeyboard = false
    @Published private(set) var canCaptureKeyboard = false
    /// The user's typing choice is independent of the host's physical-key protocol.
    @Published var keyboardEnabled = false { didSet {
        guard keyboardEnabled != oldValue else { return }
        if !keyboardEnabled {
            inputQueue.removeAll { RemoteView.isKeyboardMethod($0.0) }
            keyboardCaptured = false
        } else {
            resumeInput()
        }
    } }
    @Published private(set) var keyboardCaptured = false { didSet {
        guard keyboardCaptured != oldValue else { return }
        if !keyboardCaptured, canCaptureKeyboard { enqueueInput("computer.pressKey", ["phase": "reset"]) }
        updateInputHeartbeat()
    } }
    @Published var selectingRegion = false { didSet { if selectingRegion && !oldValue { releaseInput() } } }
    @Published var notice: String?

    /// Set by the view: how many pixels across are worth asking for.
    private(set) var requestWidth = 1600
    /// Foreground viewing raises quality without granting remote input access.
    var engaged = false { didSet { if engaged != oldValue { wake() } } }
    var visible = false { didSet { if visible != oldValue { visible ? resume() : pause() } } }

    private var connection: RemoteHostConnection?
    private var loop: Task<Void, Never>?
    private var lastInput = Date.distantPast
    private var frameRate = RemoteView.FrameRateMeter()
    private var windowFrames: [UInt32: CGRect] = [:]
    private var nudge: CheckedContinuation<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var sleepToken: UUID?
    private var viewportUpdate: Task<Void, Never>?
    private var pendingWidth = 1600
    private var canHover = false
    private var inputQueue: [(String, [String: Any])] = []
    private var inputTask: Task<Void, Never>?
    private var inputHeartbeat: Task<Void, Never>?
    private var heldButtons = Set<String>()
    private var inputGeneration = 0
    private var lastMotionSent = Date.distantPast

    let video = RemoteVideoStream()
    private var canStream = false
    /// Stills remain usable while recoverable video failures wait for a retry.
    private var streamFallback = false
    private var streamRetried = false
    private var streamRecovery = RemoteView.StreamRecovery()
    /// A picture has come over this connection; without one, a fallback
    /// (binary dropped by a relay) holds across targets until reconnect.
    private var videoReceived = false
    private var streamID: UInt32?
    /// Bumped per `runStream`; a cancelled loop finishing late leaves a newer one's stream alone.
    private var streamOwner = 0
    private var streamEnded = false
    private var lastVideoFrame = Date.distantPast
    private var ackMilliseconds = 0
    private var statsPublished = Date.distantPast
    private var firstFramePending = false
    private var streamRequestedAt = Date.distantPast
    init(host: String, address: String, port: UInt16, target: RemoteView.Target) {
        self.host = host
        self.address = address
        self.port = port
        self.target = target
    }

    var title: String { "\(host) · \(target.label)" }

    var canRetryVideo: Bool {
        guard canStream, visible, connection != nil,
              videoFallbackReason != nil, !isRecoveringVideo else { return false }
        switch status {
        case .live, .failed: return true
        case .connecting, .paused: return false
        }
    }

    /// Retry the video transport without discarding the last still picture or
    /// reconnecting input and the host's metadata subscriptions.
    func retryVideo() {
        guard canRetryVideo, visible, connection != nil else { return }
        streamRecovery.beginRetry()
        streamFallback = false
        streamRetried = false
        if case .failed = status { status = .live }
        wake()
        resume()
    }

    /// Encoded pixels actually delivered, which may be smaller than the chosen cap.
    var deliveredSize: CGSize? {
        if showingVideo {
            return videoSize.width > 0 && videoSize.height > 0 ? videoSize : nil
        }
        guard let representation = image?.representations
            .filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    // MARK: - Lifecycle

    func start() {
        guard connection == nil else { return }
        status = .connecting
        let connection = RemoteHostConnection(address: address, port: port)
        connection.onReady = { [weak self] in
            guard let self, self.connection === connection else { return }
            Task { await self.ready(connection) }
        }
        connection.onEvent = { [weak self] event in
            guard let self, self.connection === connection, event == "windows.changed" else { return }
            Task { await self.loadWindows() }
        }
        connection.onEventData = { [weak self] event, data in
            guard let self, self.connection === connection,
                  let id = (data?["streamId"] as? NSNumber)?.uint32Value, id == self.streamID else { return }
            switch event {
            case "capture.stream.ended":
                self.streamEnded = true
                self.streamActivity = nil
                self.wake()
            case "capture.stream.activity":
                self.updateActivity(data?["activity"])
            default: break
            }
        }
        let video = video
        connection.onBinary = { data in video.receive(data) }
        video.configure(.init(
            ack: { [weak self, weak connection] id, seq in
                Task { @MainActor in
                    let sent = Date()
                    guard let self, let connection,
                          let response = try? await connection.call("capture.stream.ack", params: ["streamId": Int(id), "seq": Int(seq)], timeout: 3),
                          self.connection === connection, self.streamID == id else { return }
                    self.acked(Date().timeIntervalSince(sent), response: response)
                }
            },
            keyframe: { [weak connection] id in
                Task { _ = try? await connection?.call("capture.stream.keyframe", params: ["streamId": Int(id)], timeout: 3) }
            },
            shown: { [weak self] picture in
                Task { @MainActor in self?.shown(picture) }
            }))
        connection.onClose = { [weak self] reason in
            guard let self, self.connection === connection else { return }
            self.connection = nil
            self.inputGeneration += 1
            self.inputTask?.cancel(); self.inputTask = nil
            self.keyboardEnabled = false
            self.releaseInput()
            self.loop?.cancel(); self.loop = nil
            self.streamOwner += 1
            self.streamID = nil
            self.streamActivity = nil
            self.isRecoveringVideo = false
            self.fps = 0
            self.wake()
            self.video.detach()
            self.status = .failed(reason ?? "Disconnected")
        }
        self.connection = connection
        connection.start()
    }

    func stop() {
        keyboardEnabled = false
        releaseInput()
        inputGeneration += 1
        inputTask?.cancel(); inputTask = nil
        inputQueue.removeAll()
        loop?.cancel(); loop = nil
        viewportUpdate?.cancel(); viewportUpdate = nil
        requestWidth = pendingWidth
        streamOwner += 1
        streamID = nil
        streamActivity = nil
        isRecoveringVideo = false
        fps = 0
        wake()
        video.detach()
        video.configure(nil)
        connection?.cancel(); connection = nil
    }

    func reconnect() {
        stop()
        streamFallback = false
        streamRetried = false
        streamRecovery = RemoteView.StreamRecovery()
        videoFallbackReason = nil
        videoReceived = false
        start()
    }

    private func ready(_ connection: RemoteHostConnection) async {
        let info = try? await connection.call("host.describe", timeout: 5) as? [String: Any]
        guard self.connection === connection else { return }
        if let info {
            platform = info["platform"] as? String
            displays = RemoteView.parseDisplays(info["displays"])
            let capabilities = Set(info["capabilities"] as? [String] ?? [])
            let methods = Set(info["methods"] as? [String] ?? [])
            canStill = methods.isEmpty || methods.contains("capture.still")
            canStream = capabilities.contains("capture.stream")
            canControl = methods.contains("computer.click") && (platform == "macos" || capabilities.contains("input.pointer"))
            canHover = methods.contains("computer.aim")
            let interactive = info["interactiveInput"] as? [String: Any]
            livePointer = interactive?["pointer"] as? Bool == true && methods.contains("computer.drag")
            let keyboard = RemoteView.keyboardSupport(platform: platform, methods: methods, interactive: interactive)
            canSendKeyboard = keyboard.canSend
            canCaptureKeyboard = keyboard.canCapture
            DiagnosticLog.shared.info("RemoteKeyboard: \(host) capabilities platform=\(platform ?? "unknown") keys=\(methods.contains("computer.pressKey")) physical=\(canCaptureKeyboard)")
            if case .display(let index, let name) = target, name.isEmpty, let d = displays.first(where: { $0.index == index }) {
                target = .display(index: index, name: d.name)
            }
        }
        guard canStill || canStream else {
            status = .failed("\(host) can't stream frames yet. Use Screen Sharing.")
            return
        }
        status = visible ? .live : .paused
        if visible { resume() }
        // The first picture does not depend on populating the target menu.
        _ = try? await connection.call("events.subscribe", params: ["events": ["windows.changed"]])
        guard self.connection === connection else { return }
        await loadWindows()
    }

    private func loadWindows() async {
        guard let connection, let list = try? await connection.call("windows.list") as? [[String: Any]],
              self.connection === connection else { return }
        var frames: [UInt32: CGRect] = [:]
        windows = list.compactMap { item in
            guard let wid = (item["wid"] as? NSNumber)?.uint32Value else { return nil }
            if let rect = RemoteView.rect(item["frame"]) { frames[wid] = rect }
            if item["isOnScreen"] as? Bool == false { return nil }
            return RemoteHostsModel.Window(id: wid, app: item["app"] as? String ?? "", title: item["title"] as? String ?? "",
                                           space: (item["spaceIds"] as? [Int])?.first, isFocused: item["isFocused"] as? Bool ?? false)
        }
        windowFrames = frames
    }

    // MARK: - Frames

    /// Coalesce live resizing; a newly opened viewer gets its measured size immediately.
    func updateViewport(width: CGFloat, backingScale: CGFloat) {
        let width = RemoteView.requestWidth(viewWidth: width, backingScale: backingScale)
        guard width != pendingWidth else { return }
        pendingWidth = width
        viewportUpdate?.cancel(); viewportUpdate = nil
        guard width != requestWidth else { return }
        if loop == nil {
            requestWidth = width
            return
        }
        viewportUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.requestWidth = width
            self.viewportUpdate = nil
            self.wake()
        }
    }

    private var streamProfile: RemoteView.StreamProfile {
        RemoteView.streamProfile(engaged: engaged, requestWidth: requestWidth, resolution: resolution)
    }

    private var stillWidth: Int { resolution.maxWidth ?? requestWidth }

    private func resume() {
        guard visible, connection != nil, canStill || canStream, loop == nil else { return }
        if case .connecting = status { return }
        status = .live
        loop = Task { [weak self] in await self?.run() }
    }

    private func pause() {
        releaseInput()
        loop?.cancel(); loop = nil
        wake()
        if status == .live { status = .paused }
        streamActivity = nil
        isRecoveringVideo = false
        fps = 0
    }

    private func retarget() {
        releaseInput()
        image = nil
        frame = .zero
        frameRate = RemoteView.FrameRateMeter()
        streamActivity = nil
        fps = 0
        selectingRegion = false
        if videoReceived {
            streamFallback = false
            streamRetried = false
            streamRecovery.targetChanged()
            videoFallbackReason = nil
        }
        if showingVideo {
            showingVideo = false
            video.detach(clear: true)
        }
        wake()
    }

    private var streaming: Bool { canStream && !streamFallback }

    private func run() async {
        while !Task.isCancelled, visible, connection != nil {
            if streaming {
                await runStream()
            } else if canStill {
                await runStills()
            } else {
                status = .failed(videoFallbackReason.map { "Video unavailable: \($0)" }
                                 ?? "\(host) can't stream frames yet. Use Screen Sharing.")
                loop = nil
                return
            }
        }
    }

    // MARK: - Video

    /// One `capture.stream`, from start to stop. Returns when it ends, the
    /// target or rate changes, or the viewer goes away.
    private func runStream() async {
        guard let connection else { return }
        let asked = target
        let profile = streamProfile
        var params = asked.params
        params["maxWidth"] = profile.maxWidth
        params["fps"] = profile.fps
        params["codec"] = "h264"
        streamOwner += 1
        let owner = streamOwner
        let owns = { [unowned self] in self.streamOwner == owner }
        isRecoveringVideo = videoFallbackReason != nil
        defer { if owns() { isRecoveringVideo = false } }
        streamRecovery.streamStarting()
        video.begin()
        streamActivity = nil
        frameRate = RemoteView.FrameRateMeter()
        fps = 0
        streamEnded = false
        let requestedAt = Date()
        DiagnosticLog.shared.info("RemoteView: \(host) request \(asked.label) \(profile.maxWidth)px @\(profile.fps)fps engaged=\(engaged)")
        let result: [String: Any]?
        do {
            result = try await connection.call("capture.stream.start", params: params, timeout: 8) as? [String: Any]
        } catch {
            if owns() { video.detach() }
            guard !Task.isCancelled, visible, asked == target, profile == streamProfile,
                  self.connection === connection, owns() else { return }
            fallBack(error.localizedDescription, failure: .startFailed)
            return
        }
        guard let id = (result?["streamId"] as? NSNumber)?.uint32Value else {
            if owns() { video.detach() }
            guard !Task.isCancelled, visible, asked == target, profile == streamProfile,
                  self.connection === connection, owns() else { return }
            fallBack("Stream start returned no stream ID", failure: .invalidReply)
            return
        }
        guard !Task.isCancelled, visible, asked == target, profile == streamProfile, self.connection === connection, owns() else {
            if owns() { video.detach() }
            Task { _ = try? await connection.call("capture.stream.stop", params: ["streamId": Int(id)], timeout: 3) }
            return
        }
        streamID = id
        streamActivity = RemoteView.StreamActivity(result?["activity"])
        streamRequestedAt = requestedAt
        firstFramePending = true
        let started = Date()
        // Keep retained pixels paired with their own input geometry until the
        // first new picture arrives. The source may have moved while offline.
        if image == nil, !showingVideo, let rect = RemoteView.rect(result?["frame"]) { frame = rect }
        video.attach(id)

        var stalled = false
        var probed = started
        while !Task.isCancelled, visible, asked == target, profile == streamProfile, !streamEnded, self.connection === connection, owns() {
            await sleep(1)
            guard !Task.isCancelled, visible, asked == target, profile == streamProfile,
                  !streamEnded, self.connection === connection, owns() else { break }
            publishStats()
            if lastVideoFrame <= started {
                // No first picture: the encoder never came up.
                if Date().timeIntervalSince(started) > 6 { stalled = true; break }
            } else if Date().timeIntervalSince(max(probed, lastVideoFrame)) > 4 {
                // A still screen sends nothing, so quiet alone isn't a stall: a
                // stale ack is a no-op that fails only once the stream is gone.
                probed = Date()
                let response = try? await connection.call("capture.stream.ack", params: ["streamId": Int(id), "seq": 0], timeout: 3)
                let alive = RemoteView.streamIsAlive(response)
                if !Task.isCancelled, self.connection === connection, owns(), streamID == id {
                    acked(Date().timeIntervalSince(probed), response: response)
                }
                if !alive, !Task.isCancelled, self.connection === connection { stalled = true; break }
            }
            // A stream that has run a while earns another restart.
            if lastVideoFrame > started {
                streamRecovery.confirmedHealthy(at: Date().timeIntervalSinceReferenceDate)
                if Date().timeIntervalSince(started) > 30 { streamRetried = false }
            }
        }
        let ended = owns() && streamEnded
        if owns() {
            video.detach()
            streamID = nil
            streamActivity = nil
            streamEnded = false
        }
        if !ended {
            Task { _ = try? await connection.call("capture.stream.stop", params: ["streamId": Int(id)], timeout: 3) }
        }
        if (ended || stalled), !Task.isCancelled, visible, asked == target, profile == streamProfile,
           self.connection === connection, owns() {
            if streamRetried {
                fallBack(ended ? "Stream ended after retry" : "Stream stalled after retry", failure: .streamInterrupted)
            } else { streamRetried = true }
        }
    }

    private func fallBack(_ reason: String, failure: RemoteView.StreamRecovery.Failure) {
        DiagnosticLog.shared.warn("RemoteView: \(host) \(target.label) fallback to stills: \(reason)")
        streamFallback = true
        videoFallbackReason = reason
        isRecoveringVideo = false
        firstFramePending = false
        streamRecovery.failed(failure, at: Date().timeIntervalSinceReferenceDate)
        if showingVideo {
            showingVideo = false
            video.detach(clear: true)
        }
        frameRate = RemoteView.FrameRateMeter()
        streamActivity = nil
        fps = 0
    }

    private func shown(_ picture: RemoteVideoStream.Picture) {
        guard streamID != nil else { return }
        if firstFramePending {
            firstFramePending = false
            DiagnosticLog.shared.info("RemoteView: \(host) first video frame \(Int(picture.size.width))x\(Int(picture.size.height)) after \(Int(Date().timeIntervalSince(streamRequestedAt) * 1000))ms")
        }
        lastVideoFrame = Date()
        videoReceived = true
        streamRecovery.receivedVideo(at: lastVideoFrame.timeIntervalSinceReferenceDate)
        videoFallbackReason = nil
        isRecoveringVideo = false
        if !showingVideo {
            showingVideo = true
            image = nil
        }
        if videoSize != picture.size { videoSize = picture.size }
        if picture.frame.width > 0, frame != picture.frame { frame = picture.frame }
        if notice?.hasPrefix("Frame") == true { notice = nil }
        tick()
    }

    private func acked(_ roundTrip: TimeInterval, response: Any?) {
        ackMilliseconds = Int(roundTrip * 1000)
        // Old hosts omit this field. They continue streaming normally, but
        // the viewer cannot call their quiet periods intentional idle.
        updateActivity((response as? [String: Any])?["activity"])
    }

    private func updateActivity(_ value: Any?) {
        guard let activity = RemoteView.StreamActivity(value), activity.supersedes(streamActivity) else { return }
        streamActivity = activity
    }

    // MARK: - Stills

    private func runStills() async {
        var roundTrip: TimeInterval = 0
        while !Task.isCancelled, visible, !streaming, let connection {
            let pace = RemoteView.pace(roundTrip: roundTrip, sinceInput: Date().timeIntervalSince(lastInput), engaged: engaged)
            let asked = target
            let width = stillWidth
            var params = asked.params
            params["maxWidth"] = width
            params["quality"] = pace.quality
            let started = Date()
            do {
                let result = try await connection.call("capture.still", params: params, timeout: 10) as? [String: Any]
                roundTrip = Date().timeIntervalSince(started)
                guard !Task.isCancelled, self.connection === connection, asked == target, width == stillWidth else { continue }
                if let encoded = result?["data"] as? String, let data = Data(base64Encoded: encoded), let picture = NSImage(data: data) {
                    if showingVideo {
                        showingVideo = false
                        video.detach(clear: true)
                    }
                    image = picture
                    frame = RemoteView.rect(result?["frame"]) ?? fallbackFrame(asked) ?? frame
                    latency = Int(roundTrip * 1000)
                    tick()
                    if notice != nil, notice?.hasPrefix("Frame") == true { notice = nil }
                    if canStream, streamFallback,
                       streamRecovery.shouldRetry(afterSuccessfulStillAt: Date().timeIntervalSinceReferenceDate) {
                        DiagnosticLog.shared.info("RemoteView: \(host) retrying video after successful still capture")
                        streamRecovery.beginRetry()
                        streamFallback = false
                        // This is already a recovery attempt; a new failure
                        // returns to stills and the next backoff interval.
                        streamRetried = true
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self.connection === connection, asked == target, width == stillWidth else { continue }
                notice = "Frame failed: \(error.localizedDescription)"
                if case .window = target, windowFrames[target.wid ?? 0] == nil { await loadWindows() }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // Use the request that just completed, including any focus change
            // during it, rather than adding a delay based on the previous RTT.
            let delay = RemoteView.pace(roundTrip: roundTrip, sinceInput: Date().timeIntervalSince(lastInput), engaged: engaged).delay
            if delay > 0 { await sleep(delay) }
        }
    }

    /// Older hosts don't report the captured frame; derive it from what we know.
    private func fallbackFrame(_ target: RemoteView.Target) -> CGRect? {
        switch target {
        case .display(let index, _): return displays.first { $0.index == index }?.frame
        case .window(let wid, _, _): return windowFrames[wid]
        case .region(let rect): return rect
        }
    }

    private func tick() {
        let now = Date()
        frameRate.record(at: now.timeIntervalSinceReferenceDate)
        publishStats(at: now)
    }

    private func publishStats(at now: Date = Date()) {
        // Video ticks up to 60 times a second; publish twice a second.
        guard !showingVideo || now.timeIntervalSince(statsPublished) >= 0.5 else { return }
        statsPublished = now
        fps = frameRate.rate(at: now.timeIntervalSinceReferenceDate)
        if showingVideo { latency = ackMilliseconds }
    }

    private func sleep(_ seconds: TimeInterval) async {
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake()
            let token = UUID()
            sleepToken = token
            nudge = continuation
            sleepTimer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard self?.sleepToken == token else { return }
                self?.wake()
            }
        }
    }

    /// Ends the current wait so the next frame is pulled now.
    private func wake() {
        sleepTimer?.cancel(); sleepTimer = nil
        sleepToken = nil
        let waiting = nudge
        nudge = nil
        waiting?.resume()
    }

    // MARK: - Input

    /// Drop queued input and held keys on transient focus/target changes without
    /// changing the user's Keyboard choice. Control-off, disconnect and stop
    /// disable that choice explicitly. The host also releases on a missed heartbeat.
    func releaseInput() {
        inputQueue.removeAll()
        heldButtons.removeAll()
        keyboardCaptured = false
        inputHeartbeat?.cancel(); inputHeartbeat = nil
        if livePointer { enqueueInput("computer.drag", ["phase": "reset"]) }
        if canCaptureKeyboard { enqueueInput("computer.pressKey", ["phase": "reset"]) }
    }

    /// Called by the picture when it owns input again. Window/app activation
    /// alone is insufficient: the view must also keep local toolbar/menu input local.
    func resumeInput() {
        let capture = keyboardEnabled && canCaptureKeyboard && controlling
            && engaged && visible && status == .live && !selectingRegion
        if keyboardCaptured != capture { keyboardCaptured = capture }
    }

    private func updateInputHeartbeat() {
        inputHeartbeat?.cancel(); inputHeartbeat = nil
        guard keyboardCaptured || !heldButtons.isEmpty else { return }
        inputHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.act(self.keyboardCaptured ? "computer.pressKey" : "computer.drag", ["phase": "keepalive"])
            }
        }
    }

    func hover(_ point: CGPoint) {
        guard canHover else { return }
        var params: [String: Any] = ["x": Double(point.x), "y": Double(point.y)]
        if livePointer { params["interactive"] = true }
        act("computer.aim", params)
    }

    func pointerButton(_ button: String, down: Bool, at point: CGPoint) {
        guard livePointer, controlling else { return }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        act("computer.drag", ["phase": down ? "down" : "up", "button": button, "x": Double(point.x), "y": Double(point.y)])
        updateInputHeartbeat()
    }

    func physicalKey(_ code: Int, down: Bool) {
        guard keyboardEnabled, keyboardCaptured, canCaptureKeyboard else { return }
        act("computer.pressKey", ["code": code, "phase": down ? "down" : "up"])
    }

    private func act(_ method: String, _ params: [String: Any]) {
        guard controlling, connection != nil else { return }
        lastInput = Date()
        enqueueInput(method, params)
        wake()
    }

    private func enqueueInput(_ method: String, _ params: [String: Any]) {
        guard let connection else { return }
        var params = params
        params["treatment"] = "execute"
        if platform == "macos" {
            // The Mac daemon targets windows; a monitor or region view has none.
            params["transport"] = "pointer"
            params["capture"] = false
            params["source"] = "remote-viewer"
            if params["wid"] == nil { params["allowGlobal"] = true }
        }
        // Coalesce motion only until the next key/button boundary. A click
        // must never overtake the move or modifier that preceded it.
        if method == "computer.aim", inputQueue.last?.0 == method { inputQueue.removeLast() }
        inputQueue.append((method, params))
        guard inputTask == nil else { return }
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.inputGeneration == generation { self.inputTask = nil } }
            while !self.inputQueue.isEmpty, self.connection === connection, !Task.isCancelled {
                if self.inputQueue.first?.0 == "computer.aim" {
                    let delay = 1.0 / 30 - Date().timeIntervalSince(self.lastMotionSent)
                    if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
                }
                guard !self.inputQueue.isEmpty else { break }
                let (method, params) = self.inputQueue.removeFirst()
                if method == "computer.aim" { self.lastMotionSent = Date() }
                do {
                    _ = try await connection.call(method, params: params, timeout: 2)
                } catch {
                    guard self.inputGeneration == generation else { return }
                    if RemoteView.isKeyboardMethod(method) {
                        // Remote errors can echo a key or typed text. Keep them out of logs.
                        DiagnosticLog.shared.warn("RemoteKeyboard: \(self.host) input failed method=\(method)")
                    } else {
                        DiagnosticLog.shared.warn("RemoteKeyboard: \(self.host) input failed method=\(method) error=\(error.localizedDescription)")
                    }
                    self.notice = "Input paused: \(error.localizedDescription)"
                    self.controlling = false
                    self.releaseInput()
                    // Reset failures should not recursively enqueue more resets.
                    if params["phase"] as? String == "reset" { self.inputQueue.removeAll() }
                }
                self.wake()
            }
        }
    }

    func click(_ point: CGPoint, button: String = "left", count: Int = 1) {
        var params: [String: Any] = ["x": Double(point.x), "y": Double(point.y), "button": button, "count": count]
        if let wid = target.wid { params["wid"] = Int(wid) }
        act(count >= 2 ? "computer.doubleClick" : button == "right" ? "computer.rightClick" : "computer.click", params)
    }

    func drag(from a: CGPoint, to b: CGPoint) {
        var params: [String: Any] = ["fromX": Double(a.x), "fromY": Double(a.y), "toX": Double(b.x), "toY": Double(b.y)]
        if let wid = target.wid { params["wid"] = Int(wid) }
        act("computer.drag", params)
    }

    func scroll(at point: CGPoint, dx: Double, dy: Double) {
        // Linux takes wheel notches, positive down; the Mac takes pixels, positive up.
        var params: [String: Any] = ["x": Double(point.x), "y": Double(point.y)]
        if platform == "macos" {
            params["deltaX"] = -dx * 40
            params["deltaY"] = -dy * 40
        } else {
            params["dx"] = dx
            params["dy"] = dy
        }
        if let wid = target.wid { params["wid"] = Int(wid) }
        act("computer.scroll", params)
    }

    func key(_ key: RemoteView.Key) {
        guard keyboardEnabled, canSendKeyboard else { return }
        var params: [String: Any] = [:]
        if let wid = target.wid { params["wid"] = Int(wid) }
        switch key {
        case .text(let text) where platform == "macos":
            // The Mac's typeText is for terminals. A window takes typeWindowText;
            // a monitor or region gets the keys one by one at the focused app.
            if params["wid"] != nil {
                params["text"] = text
                act("computer.typeWindowText", params)
            } else {
                guard let keys = RemoteView.macTextKeys(text) else {
                    notice = "Some characters need an app view on this Mac. Select the app to type them."
                    return
                }
                for case let .press(name, modifiers) in keys {
                    act("computer.pressKey", ["key": name, "modifiers": modifiers])
                }
            }
        case .text(let text):
            params["text"] = text
            act("computer.typeText", params)
        case .press(let name, let modifiers):
            params["key"] = name
            if !modifiers.isEmpty { params["modifiers"] = modifiers }
            act("computer.pressKey", params)
        }
    }

    // MARK: - Screen Sharing

    /// VNC has its own endpoint and optional SSH transport. It does not go
    /// through capture.live on the gateway, which intentionally denies VNC.
    func openScreenSharing() {
        controlling = false
        releaseInput()
        var displayIndex: Int?
        if case .display(let index, _) = target { displayIndex = index }
        RemoteVNCWindows.shared.show(host: host, address: address, platform: platform, displayIndex: displayIndex)
    }
}
