import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

// MARK: - Pure pieces

/// What `capture.stream.start` asked for, clamped to the contract.
struct VideoStreamRequest: Equatable {
    enum Target: Equatable {
        case display
        case window(CGWindowID)
        case region
    }

    var target: Target
    var maxWidth: Int
    var fps: Int

    static let defaultMaxWidth = 1920
    static let defaultFPS = 30

    /// Same target precedence as `capture.still`: region, then wid, then display.
    init(params: JSON?) throws {
        if let codec = params?["codec"]?.stringValue, codec.lowercased() != "h264" {
            throw RouterError.custom("Unsupported codec \(codec); this host streams h264")
        }
        if params?["width"] != nil || params?["w"] != nil {
            target = .region
        } else if let wid = params?["wid"]?.intValue {
            guard wid > 0, wid <= Int(UInt32.max) else { throw RouterError.custom("Invalid wid \(wid)") }
            target = .window(CGWindowID(wid))
        } else {
            target = .display
        }
        maxWidth = max(320, min(3840, params?["maxWidth"]?.intValue ?? Self.defaultMaxWidth))
        fps = max(5, min(60, params?["fps"]?.intValue ?? Self.defaultFPS))
    }
}

enum VideoStreamMath {
    /// Encoded size for content of `points` at `scale` pixels per point: no
    /// wider than `maxWidth` or the native pixels, aspect kept, even for 4:2:0.
    static func outputSize(points: CGSize, scale: CGFloat, maxWidth: Int, maxEdge: Int = 4096) -> (width: Int, height: Int) {
        guard points.width > 0, points.height > 0 else { return (2, 2) }
        let density = scale.isFinite && scale > 0 ? scale : 1
        var width = min(Double(maxWidth), Double(points.width * density))
        var height = width * Double(points.height / points.width)
        let longest = max(width, height)
        if longest > Double(maxEdge) {
            width *= Double(maxEdge) / longest
            height *= Double(maxEdge) / longest
        }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        return (even(width), even(height))
    }

    /// About 0.1 bit per pixel per frame, between 0.5 and 20 Mbps.
    static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let bits = Double(width) * Double(height) * Double(fps) * 0.1
        return Int(min(20_000_000, max(500_000, bits)))
    }

    /// The part of `region` on `display`, in that display's local points;
    /// nil when they don't meet. Both rects are host-space.
    static func localSourceRect(region: CGRect, display: CGRect) -> (local: CGRect, covered: CGRect)? {
        let clipped = region.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return (clipped.offsetBy(dx: -display.minX, dy: -display.minY), clipped)
    }

    /// The display holding the region's centre, else the first it touches.
    static func displayIndex(for region: CGRect, among frames: [CGRect]) -> Int? {
        let centre = CGPoint(x: region.midX, y: region.midY)
        return frames.firstIndex(where: { $0.contains(centre) }) ?? frames.firstIndex(where: { $0.intersects(region) })
    }
}

/// Flow control for one stream: at most `limit` frames encoding or sent but
/// unacked. Encoded frames are never dropped, so the window gates what is fed
/// to the encoder.
struct VideoFlowWindow: Equatable {
    var limit = 4
    private(set) var lastSent: UInt32 = 0
    private(set) var lastAcked: UInt32 = 0
    private(set) var encoding = 0
    /// When unacked frames last made progress; nil when nothing is unacked.
    private(set) var waitingSince: TimeInterval?

    var unacked: Int { Int(lastSent &- lastAcked) }
    var canFeed: Bool { unacked + encoding < limit }

    mutating func fed() { encoding += 1 }

    /// The encoder gave nothing back for a fed frame.
    mutating func dropped() { encoding = max(0, encoding - 1) }

    /// The next sequence number, for a frame about to be sent.
    mutating func emitted(now: TimeInterval) -> UInt32 {
        encoding = max(0, encoding - 1)
        if unacked == 0 { waitingSince = now }
        lastSent &+= 1
        return lastSent
    }

    /// Acks are cumulative; stale or unknown ones change nothing.
    @discardableResult
    mutating func ack(_ seq: UInt32, now: TimeInterval) -> Bool {
        guard seq > lastAcked, seq <= lastSent else { return false }
        lastAcked = seq
        waitingSince = unacked == 0 ? nil : now
        return true
    }

    func timedOut(now: TimeInterval, after limit: TimeInterval = 3) -> Bool {
        guard let waitingSince else { return false }
        return now - waitingSince > limit
    }
}

// MARK: - Registry

/// `capture.stream.*`: H.264 pushed as binary frames on the caller's socket.
/// Streams belong to the connection that started them.
final class VideoStreamer {
    static let shared = VideoStreamer()

    private let lock = NSLock()
    private var streams: [UInt32: VideoStream] = [:]
    private var nextID: UInt32 = 0

    static func registerEndpoints(_ api: LatticesApi) {
        let streamID = Param(name: "streamId", type: "int", required: true, description: "Stream from capture.stream.start")
        api.register(Endpoint(
            method: "capture.stream.start",
            description: "Stream a display, window or region as H.264 binary frames on this connection until stopped or the connection closes.",
            access: .read,
            params: [
                Param(name: "displayIndex", type: "int", required: false, description: "Display to stream; defaults to the display under the pointer"),
                Param(name: "wid", type: "int", required: false, description: "Window to stream instead of a display"),
                Param(name: "x", type: "double", required: false, description: "Region left edge, with y/width/height"),
                Param(name: "y", type: "double", required: false, description: "Region top edge"),
                Param(name: "width", type: "double", required: false, description: "Region width"),
                Param(name: "height", type: "double", required: false, description: "Region height"),
                Param(name: "maxWidth", type: "int", required: false, description: "Largest coded width, 320-3840 (default 1920)"),
                Param(name: "fps", type: "int", required: false, description: "Frame rate cap, 5-60 (default 30)"),
                Param(name: "codec", type: "string", required: false, description: "h264 (the only codec)"),
            ],
            returns: .custom("Object with streamId, codec, width, height, the streamed frame in layout coordinates, and display"),
            handler: { try shared.start(params: $0) }
        ))
        api.register(Endpoint(
            method: "capture.stream.ack", description: "Acknowledge frames up to seq; the host keeps at most 4 unacknowledged.",
            access: .read,
            params: [streamID, Param(name: "seq", type: "int", required: true, description: "Highest frame received")],
            returns: .ok, handler: { try shared.ack(params: $0) }
        ))
        api.register(Endpoint(
            method: "capture.stream.keyframe", description: "Make the stream's next frame a keyframe.",
            access: .read, params: [streamID], returns: .ok, handler: { try shared.keyframe(params: $0) }
        ))
        api.register(Endpoint(
            method: "capture.stream.stop", description: "Stop a stream.",
            access: .read, params: [streamID], returns: .ok, handler: { try shared.stop(params: $0) }
        ))
    }

    /// Whether `capture.stream` can run here now.
    static var isAvailable: Bool { CGPreflightScreenCaptureAccess() }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return streams.count
    }

    func start(params: JSON?) throws -> JSON {
        guard let owner = DaemonContext.current?.connection else {
            throw RouterError.custom("capture.stream needs a daemon socket connection")
        }
        let request = try VideoStreamRequest(params: params)
        guard Self.isAvailable else {
            throw RouterError.custom("Screen Recording permission is not granted")
        }
        let plan = try plan(request, params: params)

        lock.lock()
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let id = nextID
        lock.unlock()

        let stream = try VideoStream(id: id, owner: owner, plan: plan, fps: request.fps, maxWidth: request.maxWidth)
        stream.onEnd = { [weak self] ended in self?.remove(ended) }
        lock.lock()
        streams[id] = stream
        lock.unlock()
        do {
            try stream.startCapture()
        } catch {
            remove(stream)
            stream.end(reason: "start-failed", notify: false)
            throw error
        }

        let ownerID = owner.connectionID
        owner.onClose { [weak self] in self?.stopAll(connectionID: ownerID) }
        // Frames follow the reply, so the viewer knows the stream id first.
        DaemonContext.afterReply { stream.activate() }

        DiagnosticLog.shared.info("VideoStreamer: stream \(id) \(plan.label) \(stream.width)x\(stream.height)@\(request.fps)")
        return .object([
            "streamId": .int(Int(id)),
            "codec": .string("h264"),
            "width": .int(stream.width),
            "height": .int(stream.height),
            "frame": .object(["x": .double(plan.frame.minX), "y": .double(plan.frame.minY), "w": .double(plan.frame.width), "h": .double(plan.frame.height)]),
            "display": plan.display,
        ])
    }

    func ack(params: JSON?) throws -> JSON {
        // Acks still in flight when a stream ends are expected; drop them quietly.
        guard let stream = try? owned(params) else { return .object(["ok": .bool(false)]) }
        guard let seq = params?["seq"]?.intValue, seq >= 0, seq <= Int(UInt32.max) else { throw RouterError.missingParam("seq") }
        stream.ack(UInt32(seq))
        return .object(["ok": .bool(true)])
    }

    func keyframe(params: JSON?) throws -> JSON {
        try owned(params).requestKeyframe()
        return .object(["ok": .bool(true)])
    }

    func stop(params: JSON?) throws -> JSON {
        let stream = try owned(params)
        remove(stream)
        stream.end(reason: "stopped", notify: false)
        return .object(["ok": .bool(true)])
    }

    func stopAll(connectionID: UUID) {
        lock.lock()
        let owned = streams.values.filter { $0.owner.connectionID == connectionID }
        owned.forEach { streams.removeValue(forKey: $0.id) }
        lock.unlock()
        owned.forEach { $0.end(reason: "connection-closed", notify: false) }
    }

    private func remove(_ stream: VideoStream) {
        lock.lock()
        if streams[stream.id] === stream { streams.removeValue(forKey: stream.id) }
        lock.unlock()
    }

    /// Only the connection that started a stream may drive it.
    private func owned(_ params: JSON?) throws -> VideoStream {
        guard let raw = params?["streamId"]?.intValue, raw > 0, raw <= Int(UInt32.max) else { throw RouterError.missingParam("streamId") }
        lock.lock()
        let stream = streams[UInt32(raw)]
        lock.unlock()
        guard let stream, stream.owner.connectionID == DaemonContext.current?.connection.connectionID else {
            throw RouterError.notFound("stream \(raw)")
        }
        return stream
    }

    // MARK: Target resolution

    struct Plan {
        let filter: SCContentFilter
        let sourceRect: CGRect?
        let points: CGSize
        let scale: CGFloat
        let frame: CGRect
        let windowID: CGWindowID?
        let display: JSON
        let label: String
    }

    private func plan(_ request: VideoStreamRequest, params: JSON?) throws -> Plan {
        let capture = CaptureController.shared
        switch request.target {
        case .display:
            let resolved = try capture.resolveDisplay(params: params)
            let content = try Self.waitFor { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            guard let display = content.displays.first(where: { $0.displayID == resolved.displayID }) else {
                throw RouterError.notFound("display \(resolved.index)")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            filter.includeMenuBar = true
            return Plan(filter: filter, sourceRect: nil, points: resolved.frame.size,
                        scale: CGFloat(SCShareableContent.info(for: filter).pointPixelScale), frame: resolved.frame, windowID: nil,
                        display: .object(["index": .int(resolved.index), "name": .string(resolved.name)]),
                        label: "display \(resolved.index)")
        case .region:
            let region = try capture.resolveRegion(params: params).rect
            let content = try Self.waitFor { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            guard let index = VideoStreamMath.displayIndex(for: region, among: content.displays.map(\.frame)),
                  let selection = VideoStreamMath.localSourceRect(region: region, display: content.displays[index].frame) else {
                throw RouterError.notFound("display for region")
            }
            let filter = SCContentFilter(display: content.displays[index], excludingWindows: [])
            filter.includeMenuBar = true
            return Plan(filter: filter, sourceRect: selection.local, points: selection.local.size,
                        scale: CGFloat(SCShareableContent.info(for: filter).pointPixelScale), frame: selection.covered, windowID: nil,
                        display: .null, label: "region")
        case .window(let wid):
            let target = try capture.resolveWindow(params: params)
            let content = try Self.waitFor { try await SCShareableContent.current }
            guard let window = content.windows.first(where: { $0.windowID == wid }) else {
                throw RouterError.notFound("window \(wid)")
            }
            // Desktop-independent: the window alone, without its menus or popovers.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let frame = window.frame.isEmpty
                ? CGRect(x: target.frame.x, y: target.frame.y, width: target.frame.w, height: target.frame.h)
                : window.frame
            return Plan(filter: filter, sourceRect: nil, points: frame.size,
                        scale: CGFloat(SCShareableContent.info(for: filter).pointPixelScale), frame: frame, windowID: wid,
                        display: .null, label: "window \(wid)")
        }
    }

    private final class Box<T> {
        var result: Result<T, Error>?
    }

    /// Bridges ScreenCaptureKit's async calls onto the daemon's request threads.
    static func waitFor<T>(timeout: TimeInterval = 5, _ body: @escaping () async throws -> T) throws -> T {
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.result else {
            throw RouterError.custom("Timed out talking to ScreenCaptureKit")
        }
        return try result.get()
    }
}

// MARK: - One stream

/// One SCStream feeding one VTCompressionSession. Everything mutable lives on
/// `queue`, which is also the capture sample queue; encoded frames hop back to
/// it and are written to the owner's socket from there.
final class VideoStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let id: UInt32
    let owner: DaemonConnection
    let fps: Int
    let maxWidth: Int
    let windowID: CGWindowID?
    private(set) var width: Int
    private(set) var height: Int
    var onEnd: ((VideoStream) -> Void)?

    private let queue: DispatchQueue
    private let scale: CGFloat
    private let filter: SCContentFilter
    private let configuration = SCStreamConfiguration()
    private var capture: SCStream?
    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var flow = VideoFlowWindow()
    private var frame: CGRect
    private var configuredPoints: CGSize
    private var latest: (buffer: CVPixelBuffer, frame: CGRect)?
    private var pendingFresh = false
    private var live = false
    private var ended = false
    private var forceKeyframe = true
    private var lastKeyframeAt: TimeInterval = 0
    private var lastPTS: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var lastWindowCheck: TimeInterval = 0

    static let keyframeInterval: TimeInterval = 2

    init(id: UInt32, owner: DaemonConnection, plan: VideoStreamer.Plan, fps: Int, maxWidth: Int) throws {
        self.id = id
        self.owner = owner
        self.fps = fps
        self.maxWidth = maxWidth
        self.windowID = plan.windowID
        self.scale = plan.scale
        self.filter = plan.filter
        self.frame = plan.frame
        self.configuredPoints = plan.points
        self.queue = DispatchQueue(label: "lattices.video-stream.\(id)", qos: .userInteractive)
        let size = VideoStreamMath.outputSize(points: plan.points, scale: plan.scale, maxWidth: maxWidth)
        width = size.width
        height = size.height
        super.init()

        configuration.width = width
        configuration.height = height
        if let source = plan.sourceRect { configuration.sourceRect = source }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 4
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if plan.windowID != nil {
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
        }
    }

    func startCapture() throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try VideoStreamer.waitFor { try await stream.startCapture() }
        queue.sync { capture = stream }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        queue.sync { watchdog = timer }
    }

    /// Called once the start reply is on the wire.
    func activate() {
        queue.async { [self] in
            guard !ended else { return }
            live = true
            forceKeyframe = true
            feedLatest()
        }
    }

    func ack(_ seq: UInt32) {
        queue.async { [self] in
            guard !ended, flow.ack(seq, now: Self.now()), pendingFresh else { return }
            feedLatest()
        }
    }

    /// A static screen produces no frames, so the last picture is re-encoded as the IDR.
    func requestKeyframe() {
        queue.async { [self] in
            guard !ended else { return }
            forceKeyframe = true
            pendingFresh = true
            feedLatest()
        }
    }

    func end(reason: String, notify: Bool) {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            live = false
            watchdog?.cancel()
            watchdog = nil
            latest = nil
            if let capture {
                Task { try? await capture.stopCapture() }
            }
            capture = nil
            invalidateSession()
            if notify {
                owner.sendEvent(DaemonEvent(event: "capture.stream.ended", data: .object([
                    "streamId": .int(Int(id)), "reason": .string(reason),
                ])))
            }
            DiagnosticLog.shared.info("VideoStreamer: stream \(id) ended (\(reason))")
            onEnd?(self)
            onEnd = nil
        }
    }

    // MARK: Capture

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !ended, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if windowID != nil, let screenRect = info[.screenRect].flatMap({ Self.rect($0 as CFTypeRef) }), !screenRect.isEmpty {
            frame = screenRect
            followWindowSize(screenRect.size)
        }
        latest = (pixels, frame)
        pendingFresh = true
        feedLatest()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        end(reason: "capture-stopped: \(nsError.domain)#\(nsError.code)", notify: true)
    }

    /// Keeps a window's picture at its aspect as it resizes; the encoder
    /// follows when the new size arrives.
    private func followWindowSize(_ points: CGSize) {
        guard abs(points.width - configuredPoints.width) > 1 || abs(points.height - configuredPoints.height) > 1 else { return }
        configuredPoints = points
        let size = VideoStreamMath.outputSize(points: points, scale: scale, maxWidth: maxWidth)
        guard size.width != configuration.width || size.height != configuration.height else { return }
        configuration.width = size.width
        configuration.height = size.height
        capture?.updateConfiguration(configuration) { error in
            if let error { DiagnosticLog.shared.warn("VideoStreamer: resize failed — \(error.localizedDescription)") }
        }
    }

    private func checkHealth() {
        guard !ended else { return }
        let now = Self.now()
        if flow.timedOut(now: now) {
            end(reason: "ack-timeout", notify: true)
            return
        }
        if let windowID, now - lastWindowCheck >= 1 {
            lastWindowCheck = now
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
            if list.isEmpty { end(reason: "window-closed", notify: true) }
        }
    }

    // MARK: Encode

    private func feedLatest() {
        guard live, !ended, pendingFresh, flow.canFeed, let latest else { return }
        pendingFresh = false
        encode(latest.buffer, frame: latest.frame)
    }

    private func encode(_ pixels: CVPixelBuffer, frame: CGRect) {
        let size = (width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if session == nil || size != sessionSize {
            invalidateSession()
            guard let created = makeSession(width: size.width, height: size.height) else {
                end(reason: "encoder-failed", notify: true)
                return
            }
            session = created
            sessionSize = size
            width = size.width
            height = size.height
            forceKeyframe = true
        }
        guard let session else { return }

        let now = Self.now()
        let keyframe = forceKeyframe || now - lastKeyframeAt >= Self.keyframeInterval
        forceKeyframe = false
        if keyframe { lastKeyframeAt = now }
        let pts = max(lastPTS + 1, Self.hostMicroseconds())
        lastPTS = pts
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil

        flow.fed()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            self?.queue.async { self?.emit(status: status, sample: sample, frame: frame, forced: keyframe) }
        }
        if status != noErr {
            flow.dropped()
            if keyframe { forceKeyframe = true }
            DiagnosticLog.shared.warn("VideoStreamer: encode failed \(status)")
        }
    }

    private func emit(status: OSStatus, sample: CMSampleBuffer?, frame: CGRect, forced: Bool) {
        guard !ended else { return }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
              let encoded = Self.encodedFrame(sample) else {
            flow.dropped()
            if forced { forceKeyframe = true; pendingFresh = true }
            feedLatest()
            return
        }
        let seq = flow.emitted(now: Self.now())
        let message = RemoteVideoFrame(
            streamID: id, seq: seq, keyframe: encoded.keyframe, codec: .h264, pts: encoded.pts,
            width: UInt32(encoded.width), height: UInt32(encoded.height), frame: frame,
            parameterSets: encoded.parameterSets, accessUnit: encoded.accessUnit
        ).encoded()
        // A failed write closes the socket; its close handler stops this stream.
        owner.sendBinary(message)
    }

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        let isLowLatency = status == noErr
        if !isLowLatency {
            DiagnosticLog.shared.warn("VideoStreamer: low-latency encoder unavailable (\(status)); using the default encoder")
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { return nil }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr { DiagnosticLog.shared.warn("VideoStreamer: \(key) rejected (\(result))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Low-latency rate control only does the constrained High profile (no B-frames, 4:2:0).
        set(kVTCompressionPropertyKey_ProfileLevel, isLowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, VideoStreamMath.bitRate(width: width, height: height, fps: fps) as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Self.keyframeInterval as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// Flushes pending frames through `emit` first, so the flow window stays balanced.
    private func invalidateSession() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        sessionSize = (0, 0)
    }

    // MARK: Helpers

    struct Encoded {
        var keyframe: Bool
        var pts: UInt64
        var width: Int
        var height: Int
        var parameterSets: [Data]
        var accessUnit: Data
    }

    /// The access unit is already AVCC (4-byte lengths); parameter sets ride on keyframes.
    static func encodedFrame(_ sample: CMSampleBuffer) -> Encoded? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let keyframe = !notSync

        var sets: [Data] = []
        var headerLength: Int32 = 4
        if keyframe {
            var count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr else { return nil }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                sets.append(Data(bytes: pointer, count: size))
            }
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        if headerLength != 4 {
            guard let units = splitLengthPrefixed(data, headerLength: Int(headerLength)) else { return nil }
            data = RemoteVideoFrame.lengthPrefixed(units)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : hostMicroseconds()
        return Encoded(keyframe: keyframe, pts: micros, width: Int(dimensions.width), height: Int(dimensions.height),
                       parameterSets: sets, accessUnit: data)
    }

    /// NAL units from a buffer whose length prefixes are `headerLength` bytes.
    static func splitLengthPrefixed(_ data: Data, headerLength: Int) -> [Data]? {
        guard (1...4).contains(headerLength) else { return nil }
        let bytes = [UInt8](data)
        var units: [Data] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + headerLength <= bytes.count else { return nil }
            var length = 0
            for i in 0..<headerLength { length = length << 8 | Int(bytes[offset + i]) }
            offset += headerLength
            guard offset + length <= bytes.count else { return nil }
            units.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        return units
    }

    private static func rect(_ value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        return CGRect(dictionaryRepresentation: value as! CFDictionary)
    }

    static func hostMicroseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }

    private static func now() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }
}
