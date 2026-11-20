import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Lattices

final class VideoStreamerTests: XCTestCase {
    func testRequestDefaultsAndClamps() throws {
        let plain = try VideoStreamRequest(params: nil)
        XCTAssertEqual(plain, try VideoStreamRequest(params: .object(["displayIndex": .int(1)])).with(target: .display))
        XCTAssertEqual(plain.maxWidth, 1920)
        XCTAssertEqual(plain.fps, 30)
        XCTAssertTrue(plain.showsCursor)

        let low = try VideoStreamRequest(params: .object(["maxWidth": .int(10), "fps": .int(1)]))
        XCTAssertEqual(low.maxWidth, 320)
        XCTAssertEqual(low.fps, 5)
        let high = try VideoStreamRequest(params: .object(["maxWidth": .int(9000), "fps": .int(240)]))
        XCTAssertEqual(high.maxWidth, 3840)
        XCTAssertEqual(high.fps, 60)
    }

    func testRequestCursorPolicyIsExplicitForEveryTarget() throws {
        let targets: [[String: JSON]] = [[:], ["wid": .int(42)], ["width": .int(100), "height": .int(100)]]
        for target in targets {
            XCTAssertTrue(try VideoStreamRequest(params: .object(target)).showsCursor)
            for cursor in [false, true] {
                var params = target
                params["cursor"] = .bool(cursor)
                XCTAssertEqual(try VideoStreamRequest(params: .object(params)).showsCursor, cursor)
            }
        }
    }

    func testRequestTargetsFollowCaptureStill() throws {
        XCTAssertEqual(try VideoStreamRequest(params: .object(["wid": .int(42)])).target, .window(42))
        let region = try VideoStreamRequest(params: .object(["x": .int(0), "y": .int(0), "width": .int(10), "height": .int(10), "wid": .int(42)]))
        XCTAssertEqual(region.target, .region)
        XCTAssertEqual(try VideoStreamRequest(params: .object(["codec": .string("H264")])).target, .display)
        XCTAssertThrowsError(try VideoStreamRequest(params: .object(["codec": .string("hevc")])))
        XCTAssertThrowsError(try VideoStreamRequest(params: .object(["wid": .int(-1)])))
    }

    func testOutputSizeKeepsAspectAndEvenDimensions() {
        // A Retina 1512×982 display capped at 1920 wide.
        let retina = VideoStreamMath.outputSize(points: CGSize(width: 1512, height: 982), scale: 2, maxWidth: 1920)
        XCTAssertEqual(retina.width, 1920)
        XCTAssertEqual(retina.height, 1246)
        // Never upscaled past native pixels.
        let small = VideoStreamMath.outputSize(points: CGSize(width: 801, height: 601), scale: 1, maxWidth: 1920)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
        // A tall window stays inside the encoder's longest edge.
        let tall = VideoStreamMath.outputSize(points: CGSize(width: 1000, height: 6000), scale: 2, maxWidth: 3840)
        XCTAssertLessThanOrEqual(tall.height, 4096)
        XCTAssertEqual(tall.width % 2, 0)
        XCTAssertEqual(VideoStreamMath.outputSize(points: .zero, scale: 2, maxWidth: 1920).width, 2)
    }

    func testBitRateScalesWithPixelsAndIsCapped() {
        XCTAssertEqual(VideoStreamMath.bitRate(width: 1920, height: 1080, fps: 30), 6_220_800)
        XCTAssertEqual(VideoStreamMath.bitRate(width: 3840, height: 2160, fps: 60), 20_000_000)
        XCTAssertEqual(VideoStreamMath.bitRate(width: 320, height: 200, fps: 5), 500_000)
    }

    func testAdaptiveBitRateRequiresSustainedExcessAndRecoversAtFivePercentPerSecond() {
        var controller = VideoBitRateController(startingRate: 2_000_000)
        XCTAssertNil(controller.record(rtt: 0.020, now: 0))
        // A spike and jitter alone are insufficient.
        XCTAssertNil(controller.record(rtt: 0.160, now: 0.125))
        for tick in 2...8 {
            XCTAssertNil(controller.record(rtt: 0.020, now: Double(tick) / 8))
        }

        var cuts: [Int] = []
        for tick in 9...19 {
            if let proposal = controller.record(rtt: 0.120, now: Double(tick) / 8) {
                cuts.append(proposal)
                controller.didAccept(proposal)
            }
            if tick < 14 { XCTAssertTrue(cuts.isEmpty) }
        }
        XCTAssertEqual(cuts, [1_600_000, 1_280_000])

        for tick in 20...28 {
            if let proposal = controller.record(rtt: 0.020, now: Double(tick) / 8) {
                controller.didAccept(proposal)
            }
        }
        let cleanRate = controller.acceptedRate
        for tick in 29...36 {
            if let proposal = controller.record(rtt: 0.020, now: Double(tick) / 8) {
                controller.didAccept(proposal)
            }
        }
        XCTAssertEqual(controller.acceptedRate, cleanRate + 100_000)
        for tick in 37...120 {
            if let proposal = controller.record(rtt: 0.020, now: Double(tick) / 8) {
                controller.didAccept(proposal)
            }
        }
        XCTAssertEqual(controller.acceptedRate, 2_000_000)
    }

    func testAdaptiveBitRateIgnoresViewerDelayButCutsForNetworkDelay() {
        var flow = VideoFlowWindow(fps: 30)
        var controller = VideoBitRateController(startingRate: 2_000_000)
        for tick in 0...16 {
            let now = 1 + Double(tick) / 4
            // Both phases take 140 ms to ACK. Only the first is viewer work.
            let elapsed: TimeInterval = tick == 0 ? 0.020 : 0.140
            let viewerDelayMs: Double = (1...8).contains(tick) ? 120 : 0
            flow.sent(bytes: 1000, now: now - elapsed)
            guard case .timed(let rtt, let viewerDelay) = flow.ack(flow.lastSent, viewerDelayMs: viewerDelayMs, now: now) else {
                return XCTFail("Expected a valid timed ACK")
            }
            if let proposal = controller.record(rtt: rtt, viewerDelay: viewerDelay, now: now) {
                controller.didAccept(proposal)
            }
            if tick <= 8 {
                XCTAssertEqual(controller.acceptedRate, 2_000_000)
            }
        }
        XCTAssertLessThan(controller.acceptedRate, 2_000_000)
    }

    func testAdaptiveBitRateIdleBreaksEvidenceAndAgesOutTheBaseline() {
        var controller = VideoBitRateController(startingRate: 1_000_000)
        XCTAssertNil(controller.record(rtt: 0.020, now: 0))
        XCTAssertNil(controller.record(rtt: 0.200, now: 0.125))
        XCTAssertNil(controller.record(rtt: 0.200, now: 0.250))
        // Idle is not elapsed congestion time. The resumed samples need a
        // fresh sustained interval, but still compare against the recent floor.
        for tick in 0...3 {
            XCTAssertNil(controller.record(rtt: 0.200, now: 10 + Double(tick) / 8))
        }
        XCTAssertEqual(controller.record(rtt: 0.200, now: 10.5), 800_000)
        controller.didAccept(800_000)
        XCTAssertNil(controller.record(rtt: 0.020, now: 12))
        XCTAssertEqual(controller.record(rtt: 0.020, now: 12.125), 806_250)
        controller.didAccept(806_250)
        // Once the old lower RTT expires, a new stable path is not congested.
        XCTAssertNil(controller.record(rtt: 0.200, now: 43))
        XCTAssertEqual(controller.record(rtt: 0.200, now: 43.125), 812_500)
    }

    func testSparseAcksOnABusyLinkAreNotAnIdleGap() {
        var controller = VideoBitRateController(startingRate: 1_000_000)
        XCTAssertNil(controller.record(rtt: 0.020, now: 0))
        XCTAssertNil(controller.record(rtt: 0.600, now: 0.600))
        XCTAssertEqual(controller.record(rtt: 0.600, now: 1.200), 800_000)
    }

    func testAdaptiveBitRateClampsAndRejectionKeepsLastAcceptedRate() {
        var controller = VideoBitRateController(startingRate: 1_000_000)
        XCTAssertNil(controller.record(rtt: 0.020, now: 0))
        for tick in 1...40 {
            if let proposal = controller.record(rtt: 0.200, now: Double(tick) / 8) {
                controller.didAccept(proposal)
            }
        }
        XCTAssertEqual(controller.acceptedRate, 500_000)
        let proposals = (41...60).compactMap { controller.record(rtt: 0.020, now: Double($0) / 8) }
        XCTAssertFalse(proposals.isEmpty)
        controller.didReject()
        XCTAssertEqual(controller.acceptedRate, 500_000)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.record(rtt: 0.020, now: 60.125))
    }

    func testAdaptiveBitRateUnderLoadOnLowLatencyEncoder() throws {
        try assertAdaptiveBitRateUnderLoad(lowLatency: true)
    }

    func testAdaptiveBitRateUnderLoadOnDefaultEncoder() throws {
        try assertAdaptiveBitRateUnderLoad(lowLatency: false)
    }

    private func assertAdaptiveBitRateUnderLoad(lowLatency: Bool) throws {
        let width = 960, height = 540, fps = 30
        let startingRate = VideoStreamMath.bitRate(width: width, height: height, fps: fps)
        let encoder = VideoStream.makeEncoderSession(width: width, height: height, fps: fps,
                                                     startingRate: startingRate, lowLatency: lowLatency)
        if lowLatency, encoder.session == nil,
           encoder.status == kVTCouldNotFindVideoEncoderErr || encoder.status == kVTVideoEncoderNotAvailableNowErr {
            throw XCTSkip("Low-latency H.264 encoder unavailable on this host (\(encoder.status))")
        }
        let session = try XCTUnwrap(encoder.session, "Encoder creation failed (\(encoder.status))")
        defer { VTCompressionSessionInvalidate(session) }
        XCTAssertTrue(encoder.initialRateAccepted)
        var controller = VideoBitRateController(startingRate: startingRate)
        let outputs = EncoderOutputs()
        let pending = DispatchSemaphore(value: 4)

        // Use the same session with no frame flush or forced keyframe between
        // the phases. Bound in-flight frames like the streaming flow window.
        var reducedRate = startingRate
        for index in 0..<180 {
            let slot = pending.wait(timeout: .now() + 2)
            XCTAssertEqual(slot, .success, "Encoder stopped delivering callbacks")
            guard slot == .success else { return }
            let rtt = (40..<120).contains(index) ? 0.200 : 0.020
            if let proposal = controller.record(rtt: rtt, now: Double(index) / Double(fps)) {
                let status = VideoStream.setEncoderBitRate(session, rate: proposal)
                XCTAssertEqual(status, noErr, "Active encoder rejected a bitrate update")
                if status == noErr { controller.didAccept(proposal) } else { controller.didReject() }
            }
            if index == 119 { reducedRate = controller.acceptedRate }
            let pixels = try encoderPixels(width: width, height: height, index: index)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: Int32(fps)),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                outputs.record(index: index, status: status, sample: sample)
                pending.signal()
            }
            XCTAssertEqual(encodeStatus, noErr)
            guard encodeStatus == noErr else { return }
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertLessThan(reducedRate, startingRate)
        XCTAssertGreaterThan(controller.acceptedRate, reducedRate)
        var accepted: CFTypeRef?
        let propertyStatus = withUnsafeMutablePointer(to: &accepted) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, allocator: nil, valueOut: $0)
        }
        XCTAssertEqual(propertyStatus, noErr)
        XCTAssertEqual((accepted as? NSNumber)?.intValue, controller.acceptedRate)
        let before = outputs.byteCount(in: 10..<40)
        let after = outputs.byteCount(in: 90..<120)
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThan(after, before, "Same encoder should produce smaller access units after tuning")
    }

    private final class EncoderOutputs: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Int: Int] = [:]

        func record(index: Int, status: OSStatus, sample: CMSampleBuffer?) {
            guard status == noErr, let sample, let data = CMSampleBufferGetDataBuffer(sample) else { return }
            lock.lock()
            bytes[index] = CMBlockBufferGetDataLength(data)
            lock.unlock()
        }

        func byteCount(in range: Range<Int>) -> Int {
            lock.lock()
            defer { lock.unlock() }
            for index in range { XCTAssertGreaterThan(bytes[index] ?? 0, 0, "No access unit for frame \(index)") }
            return range.reduce(0) { $0 + (bytes[$1] ?? 0) }
        }
    }

    private func encoderPixels(width: Int, height: Int, index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 1))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        memset(chroma, 0x80, chromaStride * height / 2)
        // Pan a textured scene rather than using independent noise frames,
        // which can exceed the encoder's quantizer limits at either bitrate.
        for y in 0..<height {
            let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt32.self)
            let yTile = (y + index * 3) / 8
            for x in 0..<(width / 4) {
                let xTile = x + index
                var hash = UInt32((xTile << 16) | yTile) &* 0x45d9f3b
                hash = (hash ^ (hash >> 16)) &* 0x45d9f3b
                let value = UInt32(40) + (hash >> 25)
                row[x] = value &* 0x0101_0101
            }
        }
        return pixels
    }

    func testRegionMapsToTheDisplayHoldingItsCentre() {
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 2560, height: 1440)]
        let region = CGRect(x: 1800, y: 100, width: 600, height: 300)
        let index = VideoStreamMath.displayIndex(for: region, among: displays)
        XCTAssertEqual(index, 1)
        let selection = VideoStreamMath.localSourceRect(region: region, display: displays[1])
        XCTAssertEqual(selection?.local, CGRect(x: 0, y: 100, width: 480, height: 300))
        XCTAssertEqual(selection?.covered, CGRect(x: 1920, y: 100, width: 480, height: 300))
        XCTAssertNil(VideoStreamMath.localSourceRect(region: CGRect(x: 5000, y: 0, width: 10, height: 10), display: displays[0]))
        XCTAssertNil(VideoStreamMath.displayIndex(for: CGRect(x: -500, y: -500, width: 10, height: 10), among: displays))
    }

    func testFlowWindowStopsFeedingAtFourUnacked() {
        var flow = VideoFlowWindow()
        for expected in 1...4 {
            XCTAssertTrue(flow.canFeed)
            flow.fed()
            flow.finishedEncoding()
            flow.sent(bytes: 100, now: 0)
            XCTAssertEqual(flow.lastSent, UInt32(expected))
        }
        XCTAssertFalse(flow.canFeed)
        XCTAssertEqual(flow.ack(2, now: 1), .credited)
        XCTAssertEqual(flow.unacked, 2)
        XCTAssertTrue(flow.canFeed)
        // Stale and future acks change nothing.
        XCTAssertEqual(flow.ack(1, now: 1), .ignored)
        XCTAssertEqual(flow.ack(9, now: 1), .ignored)
        XCTAssertEqual(flow.unacked, 2)
    }

    func testFlowWindowCountsFramesStillEncoding() {
        var flow = VideoFlowWindow()
        flow.fed(); flow.fed(); flow.fed()
        flow.finishedEncoding()
        flow.sent(bytes: 100, now: 0)
        flow.fed()
        XCTAssertFalse(flow.canFeed)
        flow.finishedEncoding()
        XCTAssertTrue(flow.canFeed)
    }

    func testOnlyValidFreshTimedAcksOptIn() {
        var flow = VideoFlowWindow(fps: 60)
        XCTAssertTrue(flow.canSend(bytes: VideoFlowWindow.byteLimit + 1), "Legacy has no byte cap")
        for ms: Double? in [nil, -.infinity, .infinity, .nan, -1, 251] {
            flow.sent(bytes: 50, now: 0)
            XCTAssertEqual(flow.ack(flow.lastSent, viewerDelayMs: ms, now: 0.25), .credited)
            XCTAssertFalse(flow.adaptive)
            XCTAssertEqual(flow.limit, 4)
            XCTAssertEqual(flow.unackedBytes, 0)
        }
        flow.sent(bytes: 200, now: 10)
        for seq: UInt32 in [0, flow.lastAcked, flow.nextSeq] {
            XCTAssertEqual(flow.ack(seq, viewerDelayMs: 0, now: 10.5), .ignored)
            XCTAssertEqual(flow.unackedBytes, 200)
            XCTAssertFalse(flow.adaptive)
        }
        // A cumulative ACK samples the named frame, not the oldest frame.
        flow.sent(bytes: 300, now: 10.875)
        XCTAssertEqual(flow.ack(flow.lastSent, viewerDelayMs: 125, now: 11), .timed(rtt: 0.125, viewerDelay: 0.125))
        XCTAssertTrue(flow.adaptive)
        XCTAssertEqual(flow.limit, 9) // ceil(60 * 0.125) + 1, even when corrected RTT is zero
        XCTAssertFalse(flow.canSend(bytes: VideoFlowWindow.byteLimit + 1))
        flow.sent(bytes: 100, now: 20)
        XCTAssertEqual(flow.ack(flow.lastSent, now: 21), .credited)
        XCTAssertEqual(flow.limit, 9, "Missing timing still retires credit without resizing")
    }

    func testWindowShrinksWithoutExpiringOutstandingFrames() {
        var flow = VideoFlowWindow(fps: 60)
        flow.sent(bytes: 80, now: 0)
        flow.ack(1, viewerDelayMs: 0, now: 0.2)
        XCTAssertEqual(flow.limit, 12)
        for _ in 1...12 {
            XCTAssertTrue(flow.canFeed)
            flow.sent(bytes: 80, now: 1)
        }
        flow.ack(2, viewerDelayMs: 0, now: 1.001)
        XCTAssertEqual(flow.limit, 11)
        XCTAssertEqual(flow.unacked, 11)
        flow.ack(3, viewerDelayMs: 0, now: 1.002)
        XCTAssertEqual(flow.limit, 8)
        XCTAssertEqual(flow.unacked, 10)
        XCTAssertFalse(flow.canFeed)
        XCTAssertFalse(flow.canSend(bytes: 1))
        XCTAssertFalse(flow.timedOut(now: 1.5))
        XCTAssertEqual(flow.unackedBytes, 800)
        flow.ack(12, now: 1.6)
        XCTAssertEqual(flow.unackedBytes, 80)
        XCTAssertTrue(flow.canFeed)
        for _ in 0..<24 {
            flow.sent(bytes: 10, now: 2)
            flow.ack(flow.lastSent, viewerDelayMs: 0, now: 2.001)
        }
        XCTAssertEqual(flow.limit, 4)
    }

    func testSerializedByteCapAndDeadlineBoundaries() {
        var flow = VideoFlowWindow()
        flow.sent(bytes: 100, now: 0)
        flow.ack(1, viewerDelayMs: 0, now: 0.01)
        let cap = VideoFlowWindow.byteLimit
        let packet = VideoEncodedBacklog.Packet(message: Data(count: cap - 10), keyframe: true, encodedAt: 1)
        XCTAssertEqual(packet.wireBytes, cap) // Includes the unmasked WebSocket header.
        var backlog = VideoEncodedBacklog()
        flow.sent(bytes: 1, now: 0.5)
        guard case .wait = backlog.offer(packet, flow: flow, now: 1) else { return XCTFail("one byte over remaining credit") }
        XCTAssertFalse(backlog.canEncode(flow))
        XCTAssertEqual(flow.unackedBytes, 1, "Held bytes are not sent bytes")
        flow.ack(2, now: 1.2)
        guard case .send(let ready) = backlog.drain(flow: flow, now: 1.2) else { return XCTFail("200ms is still fresh") }
        flow.sent(bytes: ready.wireBytes, now: 1.2)
        XCTAssertEqual(flow.unackedBytes, cap)
        XCTAssertFalse(flow.canFeed)
        XCTAssertFalse(flow.canSend(bytes: 1))
        flow.ack(3, now: 1.3)
        let oversized = VideoEncodedBacklog.Packet(message: Data(count: cap - 9), keyframe: true, encodedAt: 2)
        guard case .recover(backoff: true) = backlog.offer(oversized, flow: flow, now: 2)
        else { return XCTFail("must reject a packet one byte too large even with full credit") }
        XCTAssertEqual(flow.unacked, 0)
    }

    func testExpiredOrOverflowedBacklogDiscardsDependentChain() {
        for overflow in [false, true] {
            var flow = VideoFlowWindow()
            flow.sent(bytes: 1, now: 0)
            flow.ack(1, viewerDelayMs: 0, now: 0.01)
            flow.sent(bytes: VideoFlowWindow.byteLimit - 1, now: 0.9)
            var backlog = VideoEncodedBacklog()
            let delta = VideoEncodedBacklog.Packet(message: Data(count: 30), keyframe: false, encodedAt: 1)
            guard case .wait = backlog.offer(delta, flow: flow, now: 1) else { return XCTFail("must hold exactly one") }
            let generation = backlog.generation
            let action = overflow ? backlog.offer(delta, flow: flow, now: 1.05) : backlog.drain(flow: flow, now: 1.200001)
            guard case .recover(backoff: false) = action else { return XCTFail("must recover") }
            XCTAssertNotEqual(generation, backlog.generation, "Ignore encoder callbacks from the broken chain")
            XCTAssertFalse(backlog.canEncode(flow))
            XCTAssertEqual(flow.unackedBytes, VideoFlowWindow.byteLimit - 1)
            flow.ack(2, now: 1.25)
            guard case .none = backlog.drain(flow: flow, now: 1.25) else { return XCTFail("never replay the discarded delta") }
            XCTAssertTrue(backlog.canEncode(flow))
            flow.fed()
            XCTAssertFalse(backlog.canEncode(flow), "Only one recovery encode until the IDR is sent")
            flow.finishedEncoding()
            let idr = VideoEncodedBacklog.Packet(message: Data(count: 40), keyframe: true, encodedAt: 1.3)
            guard case .send = backlog.offer(idr, flow: flow, now: 1.3) else { return XCTFail("recovery IDR") }
            XCTAssertFalse(backlog.recovering)
        }
    }

    func testAckTimeoutOnlyWhileFramesAreUnacked() {
        var flow = VideoFlowWindow()
        XCTAssertFalse(flow.timedOut(now: 100))
        flow.fed()
        flow.finishedEncoding()
        flow.sent(bytes: 100, now: 10)
        XCTAssertFalse(flow.timedOut(now: 12.9))
        XCTAssertTrue(flow.timedOut(now: 13.1))
        flow.ack(1, now: 13)
        // A static screen sends nothing and owes nothing.
        XCTAssertFalse(flow.timedOut(now: 1000))
        flow.fed()
        flow.finishedEncoding()
        flow.sent(bytes: 100, now: 2000)
        flow.fed()
        flow.finishedEncoding()
        flow.sent(bytes: 100, now: 2002)
        flow.ack(2, now: 2002.5)
        XCTAssertFalse(flow.timedOut(now: 2005))
        XCTAssertTrue(flow.timedOut(now: 2005.6))
    }

    func testHostActivityNeedsEvidenceRatherThanMissingFrames() {
        var activity = VideoCaptureActivity()
        activity.advance(now: 100)
        activity.unchanged(now: 101)
        XCTAssertEqual(activity.state, .unknown)

        activity.changed(now: 200)
        activity.advance(now: 300)
        XCTAssertEqual(activity.state, .active, "Capture silence is not proof of an unchanged screen")
    }

    func testHostActivitySettlesAndResumesOnTheFirstChange() {
        var activity = VideoCaptureActivity()
        activity.changed(now: 10)
        activity.unchanged(now: 10.2)
        activity.advance(now: 10.99)
        XCTAssertEqual(activity.state, .active)
        activity.advance(now: 11)
        XCTAssertEqual(activity.state, .idle)

        activity.changed(now: 11.01)
        XCTAssertEqual(activity.state, .active)
        activity.advance(now: 100)
        XCTAssertEqual(activity.state, .active, "Old idle evidence must not survive new motion")
        activity.unchanged(now: 100)
        XCTAssertEqual(activity.state, .idle)
    }

    func testUnavailableCaptureClearsIdleEvidence() {
        var activity = VideoCaptureActivity()
        activity.changed(now: 1)
        activity.unchanged(now: 1.5)
        activity.unavailable()
        activity.advance(now: 5)
        activity.unchanged(now: 6)
        XCTAssertEqual(activity.state, .unknown)
        activity.changed(now: 7)
        XCTAssertEqual(activity.state, .active)
    }

    func testActivityReportStatesHostPolicyWithoutConflatingActualFrameRate() {
        let report = VideoCaptureActivity.report(state: .idle, fps: 60, revision: 4)
        XCTAssertEqual(report, .object([
            "state": .string("idle"), "source": .string("host"), "revision": .int(4),
            "activeFPS": .int(60), "idleFPS": .int(0),
        ]))
    }

    func testPixelComparisonIgnoresPaddingAndChecksEveryVisiblePlane() throws {
        var snapshot = VideoPixelSnapshot()
        let initial = try makeNV12(padding: 0x00)
        XCTAssertTrue(snapshot.hasChanged(initial))
        XCTAssertFalse(snapshot.hasChanged(initial))
        let identical = try makeNV12(padding: 0xFF)
        XCTAssertFalse(snapshot.hasChanged(identical), "Row padding is not visible motion")

        // A chroma-only change at the last visible byte must wake the stream.
        try changeLastVisibleByte(identical, plane: 1, value: 0x72)
        XCTAssertTrue(snapshot.hasChanged(identical))
        XCTAssertFalse(snapshot.hasChanged(identical))

        // Mutating the same CVPixelBuffer also changes the exact snapshot.
        try changeLastVisibleByte(identical, plane: 0, value: 0x42)
        XCTAssertTrue(snapshot.hasChanged(identical))
        XCTAssertFalse(snapshot.hasChanged(identical))
    }

    func testPixelComparisonTreatsResolutionAndCaptureResetAsChanges() throws {
        var snapshot = VideoPixelSnapshot()
        let initial = try makeNV12()
        XCTAssertTrue(snapshot.hasChanged(initial))
        XCTAssertFalse(snapshot.hasChanged(initial))
        let resized = try makeNV12(width: 12, height: 8)
        XCTAssertTrue(snapshot.hasChanged(resized))
        XCTAssertFalse(snapshot.hasChanged(resized))
        snapshot.reset()
        XCTAssertTrue(snapshot.hasChanged(resized))
    }

    private func makeNV12(width: Int = 10, height: Int = 6, padding: UInt8 = 0) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            XCTAssertGreaterThan(stride, rowBytes)
            memset(base, Int32(padding), stride * rows)
            for row in 0..<rows { memset(base.advanced(by: row * stride), plane == 0 ? 0x20 : 0x80, rowBytes) }
        }
        return buffer
    }

    private func changeLastVisibleByte(_ buffer: CVPixelBuffer, plane: Int, value: UInt8) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        base.storeBytes(of: value, toByteOffset: (rows - 1) * stride + rowBytes - 1, as: UInt8.self)
    }

    func testFailedStaticFrameRemainsPendingUntilBoundedRetry() {
        var feed = VideoFrameFeed()
        feed.captured(changed: true)
        XCTAssertTrue(feed.take(now: 1))
        XCTAssertFalse(feed.pendingFresh)
        // Both synchronous rejection and an asynchronous dropped access unit
        // restore the obligation, without needing a changed capture sample.
        feed.failed(now: 1.01)
        feed.captured(changed: false)
        XCTAssertTrue(feed.pendingFresh)
        XCTAssertFalse(feed.take(now: 1.1), "Repeated callbacks must not spin on the failed frame")
        XCTAssertTrue(feed.take(now: 1.12), "A health tick can retry an otherwise static screen")
        feed.failed(now: 1.13)
        XCTAssertFalse(feed.take(now: 1.3))
        XCTAssertTrue(feed.take(now: 1.34))
        feed.succeeded()
        XCTAssertFalse(feed.pendingFresh)
        XCTAssertFalse(feed.take(now: 10))
    }

    func testFrameRetryBackoffIsCappedAndResetsAfterRecovery() {
        var feed = VideoFrameFeed()
        var now: TimeInterval = 0
        for delay: TimeInterval in [0.1, 0.2, 0.4, 0.8, 1, 1, 1] {
            feed.failed(now: now)
            XCTAssertEqual(feed.retryAt!, now + delay, accuracy: 0.000_001)
            feed.captured(changed: false)
            XCTAssertFalse(feed.take(now: now + delay - 0.01))
            now += delay
            XCTAssertTrue(feed.take(now: now))
        }
        feed.succeeded()
        feed.failed(now: 10)
        XCTAssertEqual(feed.retryAt!, 10.1, accuracy: 0.000_001)
    }

    func testDuplicateFrameDoesNotErasePendingUpdateOrRecoveryRequest() {
        var feed = VideoFrameFeed()
        feed.captured(changed: true)
        feed.captured(changed: false)
        XCTAssertTrue(feed.take(now: 0))
        feed.succeeded()
        // Explicit recovery is allowed while the host still reports idle.
        feed.request()
        feed.captured(changed: false)
        XCTAssertTrue(feed.take(now: 1))
        XCTAssertFalse(feed.take(now: 2))
    }

    func testSplitLengthPrefixedReadsShortHeaders() {
        let twoByte = Data([0, 2, 0xAA, 0xBB, 0, 1, 0xCC])
        XCTAssertEqual(VideoStream.splitLengthPrefixed(twoByte, headerLength: 2), [Data([0xAA, 0xBB]), Data([0xCC])])
        XCTAssertNil(VideoStream.splitLengthPrefixed(Data([0, 5, 1]), headerLength: 2))
        XCTAssertEqual(RemoteVideoFrame.lengthPrefixed([Data([0xAA, 0xBB])]), Data([0, 0, 0, 2, 0xAA, 0xBB]))
    }

    func testWebSocketHeaderLengths() {
        XCTAssertEqual(WebSocketClient.frameHeader(opcode: 0x2, length: 125), Data([0x82, 125]))
        XCTAssertEqual(WebSocketClient.frameHeader(opcode: 0x1, length: 300), Data([0x81, 126, 0x01, 0x2C]))
        XCTAssertEqual(WebSocketClient.frameHeader(opcode: 0x2, length: 70_000), Data([0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70]))
    }

    func testStreamVerbsNeedASocket() {
        XCTAssertThrowsError(try VideoStreamer.shared.start(params: nil))
        XCTAssertThrowsError(try VideoStreamer.shared.stop(params: .object(["streamId": .int(1)])))
    }
}

private extension VideoStreamRequest {
    func with(target: Target) -> VideoStreamRequest {
        var copy = self
        copy.target = target
        return copy
    }
}
