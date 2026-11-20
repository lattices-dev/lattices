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
    var showsCursor: Bool

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
        showsCursor = params?["cursor"]?.boolValue ?? true
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

/// Motion is decided by the capturing host, independently of ACK progress.
/// Silence alone is not evidence: ScreenCaptureKit may be stalled or suspended.
struct VideoCaptureActivity: Equatable {
    enum State: String { case active, idle, unknown }

    static let settleInterval: TimeInterval = 1
    private(set) var state: State = .unknown
    private var lastChangeAt: TimeInterval?
    private var hasUnchangedEvidence = false

    mutating func changed(now: TimeInterval) {
        state = .active
        lastChangeAt = now
        hasUnchangedEvidence = false
    }

    mutating func unchanged(now: TimeInterval) {
        guard lastChangeAt != nil else { return }
        hasUnchangedEvidence = true
        advance(now: now)
    }

    mutating func advance(now: TimeInterval) {
        guard hasUnchangedEvidence, let lastChangeAt,
              now - lastChangeAt >= Self.settleInterval else { return }
        state = .idle
    }

    mutating func unavailable() {
        state = .unknown
        lastChangeAt = nil
        hasUnchangedEvidence = false
    }

    static func report(state: State, fps: Int, revision: Int) -> JSON {
        .object([
            "state": .string(state.rawValue), "source": .string("host"), "revision": .int(revision),
            "activeFPS": .int(fps), "idleFPS": .int(0),
        ])
    }
}

/// An exact copy of the visible pixels, not a fingerprint or a sampled grid.
/// ScreenCaptureKit dirty rectangles include redraws, which can leave identical
/// pixels. Comparing both NV12 planes avoids encoding those duplicate frames.
/// Row padding is deliberately excluded: it is not part of the picture.
struct VideoPixelSnapshot {
    private struct Plane {
        var rowBytes: Int
        var height: Int
        var bytes: Data
    }

    private var format: OSType?
    private var planes: [Plane] = []

    mutating func reset() { format = nil; planes = [] }

    mutating func hasChanged(_ pixels: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
            reset()
            return true
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixels)
        var source: [(base: UnsafeRawPointer, stride: Int, rowBytes: Int, height: Int)] = []
        if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
           CVPixelBufferGetPlaneCount(pixels) == 2 {
            for index in 0..<2 {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, index) else {
                    reset()
                    return true
                }
                source.append((UnsafeRawPointer(base), CVPixelBufferGetBytesPerRowOfPlane(pixels, index),
                               CVPixelBufferGetWidthOfPlane(pixels, index) * (index == 0 ? 1 : 2),
                               CVPixelBufferGetHeightOfPlane(pixels, index)))
            }
        } else if pixelFormat == kCVPixelFormatType_32BGRA,
                  let base = CVPixelBufferGetBaseAddress(pixels) {
            source.append((UnsafeRawPointer(base), CVPixelBufferGetBytesPerRow(pixels),
                           CVPixelBufferGetWidth(pixels) * 4, CVPixelBufferGetHeight(pixels)))
        } else {
            // An unknown layout must never hide an update.
            reset()
            return true
        }
        guard source.allSatisfy({ $0.rowBytes > 0 && $0.height > 0 && $0.stride >= $0.rowBytes }) else {
            reset()
            return true
        }

        var changed = format != pixelFormat || planes.count != source.count
        if !changed {
            for (old, current) in zip(planes, source) {
                guard old.rowBytes == current.rowBytes, old.height == current.height else {
                    changed = true
                    break
                }
                let equal = old.bytes.withUnsafeBytes { previous in
                    (0..<current.height).allSatisfy { row in
                        memcmp(previous.baseAddress!.advanced(by: row * current.rowBytes),
                               current.base.advanced(by: row * current.stride), current.rowBytes) == 0
                    }
                }
                if !equal { changed = true; break }
            }
        }
        guard changed else { return false }

        planes = source.map { current in
            var bytes = Data(count: current.rowBytes * current.height)
            bytes.withUnsafeMutableBytes { destination in
                for row in 0..<current.height {
                    memcpy(destination.baseAddress!.advanced(by: row * current.rowBytes),
                           current.base.advanced(by: row * current.stride), current.rowBytes)
                }
            }
            return Plane(rowBytes: current.rowBytes, height: current.height, bytes: bytes)
        }
        format = pixelFormat
        return true
    }
}

/// A captured update stays owed until the encoder accepts an attempt. If that
/// attempt fails, keep it owed even when the source becomes completely static.
/// The backoff is driven by capture/ACK/health callbacks, never a retry loop.
struct VideoFrameFeed {
    static let initialRetryDelay: TimeInterval = 0.1
    static let maximumRetryDelay: TimeInterval = 1
    private(set) var pendingFresh = false
    private(set) var retryAt: TimeInterval?
    private var nextRetryDelay = Self.initialRetryDelay

    mutating func captured(changed: Bool) {
        if changed { pendingFresh = true }
    }

    mutating func request() { pendingFresh = true }

    mutating func take(now: TimeInterval) -> Bool {
        guard pendingFresh, retryAt.map({ now >= $0 }) ?? true else { return false }
        pendingFresh = false
        return true
    }

    mutating func failed(now: TimeInterval) {
        pendingFresh = true
        retryAt = now + nextRetryDelay
        nextRetryDelay = min(Self.maximumRetryDelay, nextRetryDelay * 2)
    }

    mutating func succeeded() {
        retryAt = nil
        nextRetryDelay = Self.initialRetryDelay
    }
}

/// Credits include encoder reservations. Only a valid timed ACK enables
/// adaptive admission, so even the frames sent before opt-in need a ledger.
struct VideoFlowWindow {
    enum Ack: Equatable {
        case ignored, credited
        case timed(rtt: TimeInterval, viewerDelay: TimeInterval)
    }

    private struct Sent {
        let seq: UInt32
        let at: TimeInterval
        let bytes: Int
    }

    static let byteLimit = 4 * 1024 * 1024
    let fps: Int
    private(set) var limit = 4
    private(set) var lastSent: UInt32 = 0
    private(set) var lastAcked: UInt32 = 0
    private(set) var encoding = 0
    private(set) var unackedBytes = 0
    private var ledger: [Sent] = []
    private var rawRTT: TimeInterval?
    private var waitingSince: TimeInterval?

    init(fps: Int = VideoStreamRequest.defaultFPS) { self.fps = fps }

    var adaptive: Bool { rawRTT != nil }
    var nextSeq: UInt32 { lastSent == .max ? 1 : lastSent + 1 } // zero is a probe
    var unacked: Int { ledger.count }
    var canFeed: Bool { unacked + encoding < limit && (!adaptive || unackedBytes < Self.byteLimit) }

    func canSend(bytes: Int) -> Bool {
        unacked < limit && (!adaptive || bytes <= Self.byteLimit - unackedBytes)
    }

    mutating func fed() { encoding += 1 }
    mutating func finishedEncoding() { encoding -= 1 }

    /// Count the serialized frame at socket handoff, not at capture or encode time.
    mutating func sent(bytes: Int, now: TimeInterval) {
        if ledger.isEmpty { waitingSince = now }
        lastSent = nextSeq
        ledger.append(Sent(seq: lastSent, at: now, bytes: bytes))
        unackedBytes += bytes
    }

    /// Only the named frame supplies a sample; the entire prefix returns credit.
    @discardableResult
    mutating func ack(_ seq: UInt32, viewerDelayMs: Double? = nil, now: TimeInterval) -> Ack {
        guard let i = ledger.firstIndex(where: { $0.seq == seq }), now >= ledger[i].at else { return .ignored }
        let elapsed = now - ledger[i].at
        for frame in ledger[...i] { unackedBytes -= frame.bytes }
        ledger.removeFirst(i + 1)
        lastAcked = seq
        waitingSince = ledger.isEmpty ? nil : now
        guard let ms = viewerDelayMs, ms.isFinite, ms >= 0, ms / 1000 <= elapsed else { return .credited }
        let average = rawRTT.map { $0 + (elapsed - $0) / 4 } ?? elapsed
        rawRTT = average
        limit = Int(min(12, max(4, ceil(Double(fps) * average) + 1)))
        return .timed(rtt: elapsed, viewerDelay: ms / 1000)
    }

    func timedOut(now: TimeInterval, after limit: TimeInterval = 3) -> Bool {
        guard let waitingSince else { return false }
        return now - waitingSince > limit
    }
}

/// At most one complete LVF1 message may wait for send credit. On loss,
/// invalidate outstanding encoder callbacks, not the compression session.
struct VideoEncodedBacklog {
    struct Packet {
        let message: Data
        let keyframe: Bool
        let encodedAt: TimeInterval
        let wireBytes: Int

        init(message: Data, keyframe: Bool, encodedAt: TimeInterval) {
            self.message = message
            self.keyframe = keyframe
            self.encodedAt = encodedAt
            wireBytes = message.count + WebSocketClient.frameHeader(opcode: 0x2, length: message.count).count
        }
    }

    enum Action { case none, wait, send(Packet), recover(backoff: Bool) }
    static let maximumAge: TimeInterval = 0.2
    private var held: Packet?
    private(set) var generation: UInt64 = 0
    private(set) var recovering = false
    private var blockedAtAck: UInt32?

    func canEncode(_ flow: VideoFlowWindow) -> Bool {
        guard held == nil, blockedAtAck != flow.lastAcked else { return false }
        return !recovering || flow.encoding == 0
    }

    mutating func offer(_ packet: Packet, flow: VideoFlowWindow, now: TimeInterval) -> Action {
        guard flow.adaptive else { return .send(packet) }
        if held != nil {
            // A reservation made before credit tightened has also completed.
            // Neither frame may become the base for a later delta.
            return discard(flow: flow, blocked: true, backoff: false)
        }
        if packet.wireBytes > VideoFlowWindow.byteLimit || (recovering && !packet.keyframe) {
            return discard(flow: flow, blocked: !flow.canSend(bytes: packet.wireBytes), backoff: true)
        }
        held = packet
        return drain(flow: flow, now: now)
    }

    mutating func drain(flow: VideoFlowWindow, now: TimeInterval) -> Action {
        guard let packet = held else { return .none }
        let fits = flow.canSend(bytes: packet.wireBytes)
        guard now <= packet.encodedAt + Self.maximumAge else {
            return discard(flow: flow, blocked: !fits, backoff: false)
        }
        guard fits else { return .wait }
        held = nil
        recovering = false
        blockedAtAck = nil
        return .send(packet)
    }

    private mutating func discard(flow: VideoFlowWindow, blocked: Bool, backoff: Bool) -> Action {
        held = nil
        generation &+= 1
        recovering = true
        blockedAtAck = blocked && flow.unacked > 0 ? flow.lastAcked : nil
        return .recover(backoff: backoff)
    }
}

/// Converts corrected, monotonic RTT samples into encoder bitrate proposals.
/// A proposal isn't the current bitrate until the encoder accepts it.
struct VideoBitRateController {
    private let startingRate: Int
    private(set) var acceptedRate: Int
    private(set) var isEnabled = true
    private var minima: [(at: TimeInterval, rtt: TimeInterval)] = []
    private var smoothedRTT: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var highSince: TimeInterval?
    private var wasClean = false

    init(startingRate: Int) {
        self.startingRate = startingRate
        acceptedRate = startingRate
    }

    mutating func record(rtt: TimeInterval, viewerDelay: TimeInterval = 0, now: TimeInterval) -> Int? {
        let correctedRTT = rtt - viewerDelay
        guard isEnabled, correctedRTT.isFinite, correctedRTT >= 0, now.isFinite,
              lastSampleAt.map({ now > $0 }) ?? true else { return nil }
        let elapsed = lastSampleAt.map { now - $0 } ?? 0
        if elapsed - rtt > 0.35 {
            // A long gap before this frame was even sent is not sustained
            // evidence. Time actually spent awaiting its ACK is not idle.
            pause()
        }
        lastSampleAt = now
        // Monotonic queue: an older sample >= this one will never be a minimum
        // again. Keep the raw minimum independent from the smoothed signal.
        while let first = minima.first, first.at < now - 30 { minima.removeFirst() }
        while let last = minima.last, last.rtt >= correctedRTT { minima.removeLast() }
        minima.append((now, correctedRTT))
        let smoothed = smoothedRTT.map { $0 + 0.25 * (correctedRTT - $0) } ?? correctedRTT
        smoothedRTT = smoothed
        let excess = smoothed - minima[0].rtt
        let nextRate: Int
        if excess > 0.030 {
            wasClean = false
            let since = highSince ?? now
            highSince = since
            guard now - since >= 0.5 else { return nil }
            highSince = now
            nextRate = max(500_000, acceptedRate * 4 / 5)
        } else {
            highSince = nil
            let remainedClean = wasClean && excess < 0.010
            wasClean = excess < 0.010
            guard remainedClean else { return nil }
            let increase = Int((Double(startingRate) * 0.05 * elapsed).rounded())
            nextRate = min(startingRate, acceptedRate + increase)
        }
        return nextRate == acceptedRate ? nil : nextRate
    }

    private mutating func pause() {
        lastSampleAt = nil
        smoothedRTT = nil
        highSince = nil
        wasClean = false
    }

    mutating func didAccept(_ rate: Int) { acceptedRate = rate }
    mutating func didReject() { isEnabled = false }
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
                Param(name: "cursor", type: "bool", required: false, description: "Include the host pointer in captured frames (default true)"),
            ],
            returns: .custom("Object with streamId, codec, width, height, cursor, the streamed frame in layout coordinates, and display"),
            handler: { try shared.start(params: $0) }
        ))
        api.register(Endpoint(
            method: "capture.stream.ack", description: "Acknowledge frames up to seq; optional viewer timing enables adaptive credit.",
            access: .read,
            params: [streamID, Param(name: "seq", type: "int", required: true, description: "Highest frame received"),
                     Param(name: "viewerDelayMs", type: "double", required: false, description: "Milliseconds from receipt of this frame to ACK dispatch; omit for probes")],
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

        let stream = try VideoStream(id: id, owner: owner, plan: plan, fps: request.fps,
                                     maxWidth: request.maxWidth, showsCursor: request.showsCursor)
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
            "cursor": .bool(stream.showsCursor),
            "frame": .object(["x": .double(plan.frame.minX), "y": .double(plan.frame.minY), "w": .double(plan.frame.width), "h": .double(plan.frame.height)]),
            "display": plan.display,
            "activity": stream.activityInfo,
        ])
    }

    func ack(params: JSON?) throws -> JSON {
        // Acks still in flight when a stream ends are expected; drop them quietly.
        guard let stream = try? owned(params) else { return .object(["ok": .bool(false)]) }
        guard let seq = params?["seq"]?.intValue, seq >= 0, seq <= Int(UInt32.max) else { throw RouterError.missingParam("seq") }
        stream.ack(UInt32(seq), viewerDelayMs: params?["viewerDelayMs"]?.numericDouble)
        return .object(["ok": .bool(true), "activity": stream.activityInfo])
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
    let showsCursor: Bool
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
    private let adaptiveBitRate = ProcessInfo.processInfo.environment["LATTICES_VIDEO_ADAPTIVE_BITRATE"] == "1"
    private var bitRateController: VideoBitRateController?
    private var sessionSize = (width: 0, height: 0)
    private var flow: VideoFlowWindow
    private var backlog = VideoEncodedBacklog()
    private var activity = VideoCaptureActivity()
    private var pixelSnapshot = VideoPixelSnapshot()
    // Request handling must not wait for this stream's capture/encoder/socket
    // queue just to read its state. ACK processing remains asynchronous.
    private let activityLock = NSLock()
    private var reportedActivity: VideoCaptureActivity.State = .unknown
    private var reportedActivityRevision = 0
    private var frame: CGRect
    private var configuredPoints: CGSize
    private var latest: (buffer: CVPixelBuffer, frame: CGRect)?
    private var frameFeed = VideoFrameFeed()
    private var live = false
    private var ended = false
    private var forceKeyframe = true
    private var lastKeyframeAt: TimeInterval = 0
    private var lastPTS: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var lastWindowCheck: TimeInterval = 0

    static let keyframeInterval: TimeInterval = 2

    init(id: UInt32, owner: DaemonConnection, plan: VideoStreamer.Plan, fps: Int, maxWidth: Int, showsCursor: Bool) throws {
        self.id = id
        self.owner = owner
        self.fps = fps
        self.flow = VideoFlowWindow(fps: fps)
        self.maxWidth = maxWidth
        self.showsCursor = showsCursor
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
        configuration.showsCursor = showsCursor
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
            reportActivity(force: true)
            feedLatest()
        }
    }

    var activityInfo: JSON {
        activityLock.lock()
        let state = reportedActivity
        let revision = reportedActivityRevision
        activityLock.unlock()
        return VideoCaptureActivity.report(state: state, fps: fps, revision: revision)
    }

    private func reportActivity(force: Bool = false) {
        activityLock.lock()
        let changed = reportedActivity != activity.state
        if changed { reportedActivityRevision += 1 }
        reportedActivity = activity.state
        activityLock.unlock()
        guard live, changed || force else { return }
        owner.sendEvent(DaemonEvent(event: "capture.stream.activity", data: .object([
            "streamId": .int(Int(id)), "activity": activityInfo,
        ])))
    }

    func ack(_ seq: UInt32, viewerDelayMs: Double?) {
        let receivedAt = Self.now()
        queue.async { [self] in
            guard !ended else { return }
            switch flow.ack(seq, viewerDelayMs: viewerDelayMs, now: receivedAt) {
            case .ignored: return
            case .credited: break
            case .timed(let rtt, let viewerDelay):
                tuneBitRate(rtt: rtt, viewerDelay: viewerDelay, now: receivedAt)
            }
            handle(backlog.drain(flow: flow, now: Self.now()))
            feedLatest()
        }
    }

    /// A static screen produces no frames, so the last picture is re-encoded as the IDR.
    func requestKeyframe() {
        queue.async { [self] in
            guard !ended else { return }
            forceKeyframe = true
            frameFeed.request()
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
            pixelSnapshot.reset()
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
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let now = Self.now()
        switch status {
        case .idle:
            // This is explicit host evidence that the display did not change.
            activity.unchanged(now: now)
            reportActivity()
            return
        case .blank, .suspended, .stopped:
            activity.unavailable()
            pixelSnapshot.reset()
            reportActivity()
            return
        case .complete:
            break
        default:
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let previousFrame = frame
        if windowID != nil, let screenRect = info[.screenRect].flatMap({ Self.rect($0 as CFTypeRef) }), !screenRect.isEmpty {
            frame = screenRect
            followWindowSize(screenRect.size)
        }
        let pixelsChanged = pixelSnapshot.hasChanged(pixels)
        let changed = pixelsChanged || previousFrame != frame
        frameFeed.captured(changed: changed)
        if changed {
            activity.changed(now: now)
            latest = (pixels, frame)
        } else {
            activity.unchanged(now: now)
            // A duplicate must not erase a changed frame waiting for an ACK.
        }
        reportActivity()
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
        activity.advance(now: now)
        reportActivity()
        if flow.timedOut(now: now) {
            end(reason: "ack-timeout", notify: true)
            return
        }
        if let windowID, now - lastWindowCheck >= 1 {
            lastWindowCheck = now
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
            if list.isEmpty {
                end(reason: "window-closed", notify: true)
                return
            }
        }
        // A failed encode still needs a retry if the screen is now static.
        feedLatest()
    }

    // MARK: Encode

    private func feedLatest() {
        guard live, !ended, flow.canFeed, backlog.canEncode(flow), let latest, frameFeed.take(now: Self.now()) else { return }
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

        let generation = backlog.generation
        flow.fed()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            let encodedAt = Self.now()
            self?.queue.async { self?.emit(status: status, sample: sample, frame: frame, generation: generation, encodedAt: encodedAt) }
        }
        if status != noErr {
            flow.finishedEncoding()
            frameFeed.failed(now: Self.now())
            forceKeyframe = true
            DiagnosticLog.shared.warn("VideoStreamer: encode failed \(status)")
        }
    }

    private func emit(status: OSStatus, sample: CMSampleBuffer?, frame: CGRect, generation: UInt64, encodedAt: TimeInterval) {
        guard !ended else { return }
        flow.finishedEncoding()
        guard generation == backlog.generation else {
            feedLatest() // Last dependent callback can release a recovery reservation.
            return
        }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
              let encoded = Self.encodedFrame(sample) else {
            frameFeed.failed(now: Self.now())
            // A missing access unit may break inter-frame references. Recover
            // with an IDR, including when the failed attempt was a P-frame.
            forceKeyframe = true
            return
        }
        let message = RemoteVideoFrame(
            streamID: id, seq: flow.nextSeq, keyframe: encoded.keyframe, codec: .h264, pts: encoded.pts,
            width: UInt32(encoded.width), height: UInt32(encoded.height), frame: frame,
            parameterSets: encoded.parameterSets, accessUnit: encoded.accessUnit
        ).encoded()
        let packet = VideoEncodedBacklog.Packet(message: message, keyframe: encoded.keyframe, encodedAt: encodedAt)
        let now = Self.now()
        let action = backlog.offer(packet, flow: flow, now: now)
        if case .wait = action {
            queue.asyncAfter(deadline: .now() + max(0, encodedAt + VideoEncodedBacklog.maximumAge - now)) { [weak self] in
                guard let self, !self.ended else { return }
                self.handle(self.backlog.drain(flow: self.flow, now: Self.now()))
                self.feedLatest()
            }
        }
        handle(action)
        if flow.adaptive { feedLatest() }
    }

    private func handle(_ action: VideoEncodedBacklog.Action) {
        switch action {
        case .none, .wait: break
        case .send(let packet):
            flow.sent(bytes: packet.wireBytes, now: Self.now())
            // A failed write closes the socket; its close handler stops this stream.
            owner.sendBinary(packet.message)
            frameFeed.succeeded()
        case .recover(let backoff):
            forceKeyframe = true
            if backoff { frameFeed.failed(now: Self.now()) } else { frameFeed.request() }
        }
    }

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let startingRate = VideoStreamMath.bitRate(width: width, height: height, fps: fps)
        var encoder = Self.makeEncoderSession(width: width, height: height, fps: fps,
                                              startingRate: startingRate, lowLatency: true)
        if encoder.session == nil {
            DiagnosticLog.shared.warn("VideoStreamer: low-latency encoder unavailable (\(encoder.status)); using the default encoder")
            encoder = Self.makeEncoderSession(width: width, height: height, fps: fps,
                                              startingRate: startingRate, lowLatency: false)
        }
        if adaptiveBitRate, encoder.initialRateAccepted {
            bitRateController = VideoBitRateController(startingRate: startingRate)
        }
        return encoder.session
    }

    /// Called only for an opt-in timed ACK, on the capture/encoder queue.
    private func tuneBitRate(rtt: TimeInterval, viewerDelay: TimeInterval, now: TimeInterval) {
        guard let session,
              let proposal = bitRateController?.record(rtt: rtt, viewerDelay: viewerDelay, now: now) else { return }
        let status = Self.setEncoderBitRate(session, rate: proposal)
        if status == noErr {
            bitRateController?.didAccept(proposal)
        } else {
            bitRateController?.didReject()
            DiagnosticLog.shared.warn("VideoStreamer: stream \(id) stopped bitrate tuning; encoder rejected update (\(status))")
        }
    }

    static func setEncoderBitRate(_ session: VTCompressionSession, rate: Int) -> OSStatus {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: rate as CFNumber)
    }

    static func makeEncoderSession(width: Int, height: Int, fps: Int, startingRate: Int, lowLatency: Bool)
        -> (session: VTCompressionSession?, status: OSStatus, initialRateAccepted: Bool) {
        var session: VTCompressionSession?
        let specification = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { return (nil, status, false) }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr { DiagnosticLog.shared.warn("VideoStreamer: \(key) rejected (\(result))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Low-latency rate control only does the constrained High profile (no B-frames, 4:2:0).
        set(kVTCompressionPropertyKey_ProfileLevel, lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel)
        let rateStatus = setEncoderBitRate(session, rate: startingRate)
        if rateStatus != noErr { DiagnosticLog.shared.warn("VideoStreamer: initial average bitrate rejected (\(rateStatus))") }
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Self.keyframeInterval as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        return (session, status, rateStatus == noErr && prepareStatus == noErr)
    }

    /// Flushes pending frames through `emit` first, so the flow window stays balanced.
    private func invalidateSession() {
        bitRateController = nil
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
