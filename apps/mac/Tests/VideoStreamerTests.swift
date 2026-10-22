import CoreGraphics
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
