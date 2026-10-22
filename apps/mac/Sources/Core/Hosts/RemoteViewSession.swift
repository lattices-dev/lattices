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
    @Published private(set) var latency: Int = 0
    @Published private(set) var canStill = true
    @Published private(set) var canControl = false
    @Published var controlling = false { didSet { if oldValue != controlling, streamID != nil { wake() } } }
    @Published var selectingRegion = false
    @Published var notice: String?

    /// Set by the view: how many pixels across are worth asking for.
    var requestWidth = 1600
    var visible = false { didSet { if visible != oldValue { visible ? resume() : pause() } } }

    private var connection: RemoteHostConnection?
    private var loop: Task<Void, Never>?
    private var lastInput = Date.distantPast
    private var frameTimes: [Date] = []
    private var windowFrames: [UInt32: CGRect] = [:]
    private var nudge: CheckedContinuation<Void, Never>?

    let video = RemoteVideoStream()
    private var canStream = false
    /// Stills only until the target changes or the host reconnects.
    private var streamFallback = false
    private var streamRetried = false
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
    init(host: String, address: String, port: UInt16, target: RemoteView.Target) {
        self.host = host
        self.address = address
        self.port = port
        self.target = target
    }

    var title: String { "\(host) · \(target.label)" }

    // MARK: - Lifecycle

    func start() {
        guard connection == nil else { return }
        status = .connecting
        let connection = RemoteHostConnection(address: address, port: port)
        connection.onReady = { [weak self] in
            guard let self, self.connection === connection else { return }
            Task { await self.ready() }
        }
        connection.onEvent = { [weak self] event in
            guard let self, self.connection === connection, event == "windows.changed" else { return }
            Task { await self.loadWindows() }
        }
        connection.onEventData = { [weak self] event, data in
            guard let self, self.connection === connection, event == "capture.stream.ended",
                  let id = (data?["streamId"] as? NSNumber)?.uint32Value, id == self.streamID else { return }
            self.streamEnded = true
            self.wake()
        }
        let video = video
        connection.onBinary = { data in video.receive(data) }
        video.configure(.init(
            ack: { [weak self, weak connection] id, seq in
                Task {
                    let sent = Date()
                    guard (try? await connection?.call("capture.stream.ack", params: ["streamId": Int(id), "seq": Int(seq)], timeout: 3)) != nil else { return }
                    await self?.acked(Date().timeIntervalSince(sent))
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
            self.loop?.cancel(); self.loop = nil
            self.video.detach()
            self.status = .failed(reason ?? "Disconnected")
        }
        self.connection = connection
        connection.start()
    }

    func stop() {
        loop?.cancel(); loop = nil
        wake()
        video.detach()
        video.configure(nil)
        connection?.cancel(); connection = nil
    }

    func reconnect() {
        stop()
        streamFallback = false
        streamRetried = false
        videoReceived = false
        start()
    }

    private func ready() async {
        guard let connection else { return }
        if let info = try? await connection.call("host.describe", timeout: 5) as? [String: Any] {
            platform = info["platform"] as? String
            displays = RemoteView.parseDisplays(info["displays"])
            let capabilities = Set(info["capabilities"] as? [String] ?? [])
            let methods = Set(info["methods"] as? [String] ?? [])
            canStill = methods.isEmpty || methods.contains("capture.still")
            canStream = capabilities.contains("capture.stream")
            canControl = methods.contains("computer.click") && (platform == "macos" || capabilities.contains("input.pointer"))
            if case .display(let index, let name) = target, name.isEmpty, let d = displays.first(where: { $0.index == index }) {
                target = .display(index: index, name: d.name)
            }
        }
        _ = try? await connection.call("events.subscribe", params: ["events": ["windows.changed"]])
        await loadWindows()
        guard canStill || canStream else {
            status = .failed("\(host) can't stream frames yet. Use Screen Sharing.")
            return
        }
        status = visible ? .live : .paused
        if visible { resume() }
    }

    private func loadWindows() async {
        guard let connection, let list = try? await connection.call("windows.list") as? [[String: Any]] else { return }
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

    private func resume() {
        guard visible, connection != nil, canStill || canStream, loop == nil else { return }
        if case .connecting = status { return }
        status = .live
        loop = Task { [weak self] in await self?.run() }
    }

    private func pause() {
        loop?.cancel(); loop = nil
        wake()
        if status == .live { status = .paused }
        fps = 0
    }

    private func retarget() {
        image = nil
        frame = .zero
        frameTimes.removeAll()
        selectingRegion = false
        if videoReceived {
            streamFallback = false
            streamRetried = false
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
                status = .failed("\(host) can't stream frames yet. Use Screen Sharing.")
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
        let rate = controlling ? 60 : 30
        var params = asked.params
        params["maxWidth"] = max(320, min(3840, requestWidth))
        params["fps"] = rate
        params["codec"] = "h264"
        streamOwner += 1
        let owner = streamOwner
        let owns = { [unowned self] in self.streamOwner == owner }
        video.begin()
        streamEnded = false
        let result: [String: Any]?
        do {
            result = try await connection.call("capture.stream.start", params: params, timeout: 8) as? [String: Any]
        } catch {
            if owns() { video.detach() }
            guard !Task.isCancelled, self.connection === connection else { return }
            fallBack()
            return
        }
        guard let id = (result?["streamId"] as? NSNumber)?.uint32Value else {
            if owns() { video.detach() }
            guard !Task.isCancelled else { return }
            fallBack()
            return
        }
        guard !Task.isCancelled, visible, asked == target, self.connection === connection, owns() else {
            if owns() { video.detach() }
            Task { _ = try? await connection.call("capture.stream.stop", params: ["streamId": Int(id)], timeout: 3) }
            return
        }
        streamID = id
        let started = Date()
        if let rect = RemoteView.rect(result?["frame"]) { frame = rect }
        video.attach(id)

        var stalled = false
        var probed = started
        while !Task.isCancelled, visible, asked == target, rate == (controlling ? 60 : 30), !streamEnded, self.connection === connection {
            await sleep(1)
            if lastVideoFrame <= started {
                // No first picture: the encoder never came up.
                if Date().timeIntervalSince(started) > 6 { stalled = true; break }
            } else if Date().timeIntervalSince(max(probed, lastVideoFrame)) > 4 {
                // A still screen sends nothing, so quiet alone isn't a stall: a
                // stale ack is a no-op that fails only once the stream is gone.
                probed = Date()
                let alive = (try? await connection.call("capture.stream.ack", params: ["streamId": Int(id), "seq": 0], timeout: 3)) != nil
                if !alive, !Task.isCancelled, self.connection === connection { stalled = true; break }
            }
            // A stream that has run a while earns another restart.
            if lastVideoFrame > started, Date().timeIntervalSince(started) > 30 { streamRetried = false }
        }
        let ended = owns() && streamEnded
        if owns() {
            video.detach()
            streamID = nil
            streamEnded = false
        }
        if !ended {
            Task { _ = try? await connection.call("capture.stream.stop", params: ["streamId": Int(id)], timeout: 3) }
        }
        if (ended || stalled), !Task.isCancelled, self.connection === connection {
            if streamRetried { fallBack() } else { streamRetried = true }
        }
    }

    private func fallBack() {
        streamFallback = true
        if showingVideo {
            showingVideo = false
            video.detach(clear: true)
        }
        frameTimes.removeAll()
    }

    private func shown(_ picture: RemoteVideoStream.Picture) {
        guard streamID != nil else { return }
        lastVideoFrame = Date()
        videoReceived = true
        if !showingVideo {
            showingVideo = true
            image = nil
        }
        if videoSize != picture.size { videoSize = picture.size }
        if picture.frame.width > 0, frame != picture.frame { frame = picture.frame }
        if notice?.hasPrefix("Frame") == true { notice = nil }
        tick()
    }

    private func acked(_ roundTrip: TimeInterval) {
        ackMilliseconds = Int(roundTrip * 1000)
    }

    // MARK: - Stills

    private func runStills() async {
        var roundTrip: TimeInterval = 0
        while !Task.isCancelled, visible, !streaming, let connection {
            let pace = RemoteView.pace(roundTrip: roundTrip, sinceInput: Date().timeIntervalSince(lastInput))
            let asked = target
            var params = asked.params
            params["maxWidth"] = requestWidth
            params["quality"] = pace.quality
            let started = Date()
            do {
                let result = try await connection.call("capture.still", params: params, timeout: 10) as? [String: Any]
                roundTrip = Date().timeIntervalSince(started)
                guard !Task.isCancelled, asked == target else { continue }
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
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = "Frame failed: \(error.localizedDescription)"
                if case .window = target, windowFrames[target.wid ?? 0] == nil { await loadWindows() }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if pace.delay > 0 { await sleep(pace.delay) }
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
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        let rate = frameTimes.count > 1 ? Double(frameTimes.count - 1) / max(0.001, now.timeIntervalSince(frameTimes[0])) : 0
        guard showingVideo else { fps = rate; return }
        // Video ticks up to 60 times a second; publish twice a second.
        guard now.timeIntervalSince(statsPublished) >= 0.5 else { return }
        statsPublished = now
        fps = rate
        latency = ackMilliseconds
    }

    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nudge = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.wake()
            }
        }
    }

    /// Ends the current wait so the next frame is pulled now.
    private func wake() {
        nudge?.resume()
        nudge = nil
    }

    // MARK: - Input

    private func act(_ method: String, _ params: [String: Any]) {
        guard controlling, let connection else { return }
        lastInput = Date()
        var params = params
        params["treatment"] = "execute"
        if platform == "macos" {
            // The Mac daemon targets windows; a monitor or region view has none.
            params["transport"] = "pointer"
            params["capture"] = false
            params["source"] = "remote-viewer"
            if params["wid"] == nil { params["allowGlobal"] = true }
        }
        Task {
            do {
                _ = try await connection.call(method, params: params, timeout: 8)
                if notice?.hasPrefix("Frame") == false { notice = nil }
            } catch {
                notice = "\(method.replacingOccurrences(of: "computer.", with: "").capitalized) failed: \(error.localizedDescription)"
            }
            wake()
        }
        wake()
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
                for character in text {
                    let lower = character.lowercased()
                    let shifted = String(character) != lower
                    act("computer.pressKey", ["key": lower, "modifiers": shifted ? ["shift"] : []])
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

    /// Full remote desktop in macOS Screen Sharing. A Linux host starts its
    /// wayvnc on request; a Mac answers on its own Screen Sharing service,
    /// which asks for that Mac's login.
    func openScreenSharing() {
        Task {
            var url = URL(string: "vnc://\(address)")
            if platform != "macos", let connection {
                var params: [String: Any] = [:]
                if case .display(let index, _) = target { params["displayIndex"] = index }
                do {
                    let result = try await connection.call("capture.live", params: params, timeout: 15) as? [String: Any]
                    if let raw = result?["url"] as? String { url = URL(string: raw) }
                } catch {
                    notice = "Screen Sharing: \(error.localizedDescription)"
                    return
                }
            }
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}
