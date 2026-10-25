import CoreGraphics
import CoreVideo
import XCTest
@testable import Lattices

final class VideoStreamerTests: XCTestCase {
    func testRequestDefaultsAndClamps() throws {
        let plain = try VideoStreamRequest(params: nil)
        XCTAssertEqual(plain, try VideoStreamRequest(params: .object(["displayIndex": .int(1)])).with(target: .display))
        XCTAssertEqual(plain.maxWidth, 1920)
        XCTAssertEqual(plain.fps, 30)

        let low = try VideoStreamRequest(params: .object(["maxWidth": .int(10), "fps": .int(1)]))
        XCTAssertEqual(low.maxWidth, 320)
        XCTAssertEqual(low.fps, 5)
        let high = try VideoStreamRequest(params: .object(["maxWidth": .int(9000), "fps": .int(240)]))
        XCTAssertEqual(high.maxWidth, 3840)
        XCTAssertEqual(high.fps, 60)
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
            XCTAssertEqual(flow.emitted(now: 0), UInt32(expected))
        }
        XCTAssertFalse(flow.canFeed)
        XCTAssertTrue(flow.ack(2, now: 1))
        XCTAssertEqual(flow.unacked, 2)
        XCTAssertTrue(flow.canFeed)
        // Stale and future acks change nothing.
        XCTAssertFalse(flow.ack(1, now: 1))
        XCTAssertFalse(flow.ack(9, now: 1))
        XCTAssertEqual(flow.unacked, 2)
    }

    func testFlowWindowCountsFramesStillEncoding() {
        var flow = VideoFlowWindow()
        flow.fed(); flow.fed(); flow.fed()
        _ = flow.emitted(now: 0)
        flow.fed()
        XCTAssertFalse(flow.canFeed)
        flow.dropped()
        XCTAssertTrue(flow.canFeed)
    }

    func testAckTimeoutOnlyWhileFramesAreUnacked() {
        var flow = VideoFlowWindow()
        XCTAssertFalse(flow.timedOut(now: 100))
        flow.fed()
        _ = flow.emitted(now: 10)
        XCTAssertFalse(flow.timedOut(now: 12.9))
        XCTAssertTrue(flow.timedOut(now: 13.1))
        flow.ack(1, now: 13)
        // A static screen sends nothing and owes nothing.
        XCTAssertFalse(flow.timedOut(now: 1000))
        flow.fed()
        _ = flow.emitted(now: 2000)
        flow.fed()
        _ = flow.emitted(now: 2002)
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
