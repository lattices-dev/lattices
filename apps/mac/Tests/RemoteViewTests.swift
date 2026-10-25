import AppKit
import XCTest
@testable import Lattices

final class RemoteViewTests: XCTestCase {
    func testFitLetterboxesAWidePictureInATallView() {
        let shown = RemoteView.fit(CGSize(width: 1600, height: 900), in: CGSize(width: 800, height: 900))
        XCTAssertEqual(shown, CGRect(x: 0, y: 225, width: 800, height: 450))
    }

    func testClickMapsThroughTheFrameTheHostReported() {
        // A 1280×720 still of a 2560×1440 monitor that sits right of a 1920 one.
        let frame = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let view = CGSize(width: 640, height: 400)
        let image = CGSize(width: 1280, height: 720)
        // Picture fills 640×360, letterboxed 20pt top and bottom.
        XCTAssertEqual(RemoteView.remotePoint(CGPoint(x: 320, y: 200), view: view, image: image, frame: frame), CGPoint(x: 3200, y: 720))
        XCTAssertEqual(RemoteView.remotePoint(CGPoint(x: 0, y: 20), view: view, image: image, frame: frame), CGPoint(x: 1920, y: 0))
        XCTAssertNil(RemoteView.remotePoint(CGPoint(x: 320, y: 10), view: view, image: image, frame: frame))
    }

    func testVideoMapsThroughTheStreamFrameAndPictureSize() {
        // A stream scaled to 1280×800 of a 1440×900 window at (200, 100), shown aspect-fit like resizeAspect.
        let frame = CGRect(x: 200, y: 100, width: 1440, height: 900)
        let picture = CGSize(width: 1280, height: 800)
        let view = CGSize(width: 1000, height: 700)
        // Fits 1000×625, letterboxed 37.5pt top and bottom.
        XCTAssertEqual(RemoteView.remotePoint(CGPoint(x: 500, y: 350), view: view, image: picture, frame: frame), CGPoint(x: 920, y: 550))
        XCTAssertEqual(RemoteView.remoteRegion(from: CGPoint(x: 0, y: 37.5), to: CGPoint(x: 500, y: 350), view: view, image: picture, frame: frame),
                       CGRect(x: 200, y: 100, width: 720, height: 450))
    }

    func testRegionIsClampedToThePictureAndIgnoresTinyDrags() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let view = CGSize(width: 500, height: 250)
        let region = RemoteView.remoteRegion(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 600, y: -40), view: view, image: frame.size, frame: frame)
        XCTAssertEqual(region, CGRect(x: 800, y: 0, width: 200, height: 400))
        XCTAssertNil(RemoteView.remoteRegion(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 14), view: view, image: frame.size, frame: frame))
    }

    func testPaceIsFastAfterInputAndCalmWhenIdle() {
        let busy = RemoteView.pace(roundTrip: 0.02, sinceInput: 0.5)
        XCTAssertEqual(busy.delay, 0.03, accuracy: 0.001)
        XCTAssertEqual(busy.quality, 60)
        XCTAssertEqual(RemoteView.pace(roundTrip: 0.3, sinceInput: 0.5), .init(delay: 0, quality: 45))
        XCTAssertEqual(RemoteView.pace(roundTrip: 0.1, sinceInput: 60), .init(delay: 0.4, quality: 75))
    }

    func testEngagedStillsStayResponsiveAndSharpWithoutInput() {
        let active = RemoteView.pace(roundTrip: 0.02, sinceInput: 60, engaged: true)
        XCTAssertEqual(active.delay, 0.03, accuracy: 0.001)
        XCTAssertEqual(active.quality, 75)
        // Slow requests must not accrue additional delay or sacrifice text quality.
        XCTAssertEqual(RemoteView.pace(roundTrip: 0.3, sinceInput: 60, engaged: true), .init(delay: 0, quality: 75))
    }

    func testForegroundStreamUsesFullFrameRateAndViewportResolution() {
        XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: 3500), .init(fps: 60, maxWidth: 3500))
        XCTAssertEqual(RemoteView.streamProfile(engaged: false, requestWidth: 3500), .init(fps: 30, maxWidth: 2560))
        XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: 9000), .init(fps: 60, maxWidth: 3840))
        XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: 10), .init(fps: 60, maxWidth: 320))
        // Expanding an active viewer must change the requested profile.
        XCTAssertNotEqual(RemoteView.streamProfile(engaged: true, requestWidth: 1600),
                          RemoteView.streamProfile(engaged: true, requestWidth: 3200))
    }

    func testAutomaticResolutionRetainsViewportAndEngagementCaps() {
        XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: 3500, resolution: .automatic),
                       .init(fps: 60, maxWidth: 3500))
        XCTAssertEqual(RemoteView.streamProfile(engaged: false, requestWidth: 3500, resolution: .automatic),
                       .init(fps: 30, maxWidth: 2560))
        XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: 9000, resolution: .automatic),
                       .init(fps: 60, maxWidth: 3840))
        XCTAssertEqual(RemoteView.streamProfile(engaged: false, requestWidth: 10, resolution: .automatic),
                       .init(fps: 30, maxWidth: 320))
    }

    func testExplicitResolutionKeepsItsWidthAcrossViewportAndEngagementChanges() {
        let choices: [(RemoteView.Resolution, Int)] = [
            (.width1280, 1280), (.width1920, 1920), (.width2560, 2560), (.width3840, 3840),
        ]
        for (resolution, width) in choices {
            for viewport in [320, 1600, 3500, 9000] {
                XCTAssertEqual(RemoteView.streamProfile(engaged: true, requestWidth: viewport, resolution: resolution),
                               .init(fps: 60, maxWidth: width))
                XCTAssertEqual(RemoteView.streamProfile(engaged: false, requestWidth: viewport, resolution: resolution),
                               .init(fps: 30, maxWidth: width))
            }
        }
    }

    func testResolutionLabelsDescribeWidthWithoutAssumingAspectRatio() {
        XCTAssertEqual(RemoteView.Resolution.allCases.map(\.label),
                       ["Auto", "1280 px wide", "1920 px wide", "2560 px wide", "3840 px wide"])
        XCTAssertNil(RemoteView.Resolution.automatic.maxWidth)
    }

    @MainActor
    func testSessionResolutionSurvivesResizeRetargetAndStop() {
        let session = RemoteViewSession(host: "Test", address: "127.0.0.1", port: 1,
                                        target: .display(index: 0, name: "Monitor"))
        XCTAssertEqual(session.resolution, .automatic)
        session.resolution = .width3840
        session.updateViewport(width: 400, backingScale: 2)
        session.engaged = true
        session.target = .window(wid: 42, app: "Test", title: "Window")
        session.stop()
        XCTAssertEqual(session.resolution, .width3840)
        XCTAssertEqual(session.requestWidth, 800)
        XCTAssertNil(session.deliveredSize)
    }

    func testStreamProbeChecksResultInsteadOfRPCSuccess() {
        XCTAssertTrue(RemoteView.streamIsAlive(["ok": true]))
        XCTAssertFalse(RemoteView.streamIsAlive(["ok": false]))
        XCTAssertFalse(RemoteView.streamIsAlive(["streamId": 1]))
        XCTAssertFalse(RemoteView.streamIsAlive(nil))
    }

    func testTemporaryStreamStartFailureCanRecoverAfterFreshStillCapture() {
        var recovery = RemoteView.StreamRecovery()
        recovery.failed(.startFailed, at: 10)
        XCTAssertFalse(recovery.hasReceivedVideo)
        XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: 11.99))
        XCTAssertTrue(recovery.shouldRetry(afterSuccessfulStillAt: 12))
        recovery.beginRetry()
        XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: 100), "Each fallback schedules one attempt")
    }

    func testRelayWithoutVideoPicturesDoesNotRepeatedlyInterruptStills() {
        var recovery = RemoteView.StreamRecovery()
        recovery.failed(.streamInterrupted, at: 10)
        XCTAssertNil(recovery.retryAt)
        XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: 1000))
        recovery.failed(.invalidReply, at: 20)
        XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: 1000), "An incompatible start reply is not a temporary capture failure")
    }

    func testPreviouslyWorkingVideoRetriesAnInterruptedStream() {
        var recovery = RemoteView.StreamRecovery()
        recovery.receivedVideo(at: 0)
        recovery.failed(.streamInterrupted, at: 1)
        XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: 2.99))
        XCTAssertTrue(recovery.shouldRetry(afterSuccessfulStillAt: 3))
    }

    func testStreamRecoveryBackoffIsCappedAndDoesNotResetOnAStartReply() {
        var recovery = RemoteView.StreamRecovery()
        var now: TimeInterval = 0
        let delays: [TimeInterval] = [2, 4, 8, 16, 30, 30, 30]
        for delay in delays {
            recovery.failed(.startFailed, at: now)
            XCTAssertEqual(recovery.retryAt, now + delay)
            XCTAssertFalse(recovery.shouldRetry(afterSuccessfulStillAt: now + delay - 0.01))
            XCTAssertTrue(recovery.shouldRetry(afterSuccessfulStillAt: now + delay))
            recovery.beginRetry()
            recovery.streamStarting()
            now += delay
        }
    }

    func testOnlySustainedHealthyVideoResetsRecoveryBackoff() {
        var recovery = RemoteView.StreamRecovery()
        recovery.failed(.startFailed, at: 0)
        recovery.beginRetry()
        recovery.streamStarting()
        recovery.receivedVideo(at: 2)
        recovery.confirmedHealthy(at: 31.99)
        recovery.failed(.streamInterrupted, at: 32)
        XCTAssertEqual(recovery.retryAt, 36, "A brief recovery retains the increased backoff")

        recovery.beginRetry()
        recovery.streamStarting()
        recovery.receivedVideo(at: 36)
        recovery.confirmedHealthy(at: 66)
        recovery.failed(.streamInterrupted, at: 67)
        XCTAssertEqual(recovery.retryAt, 69, "Thirty healthy seconds, including verified idle time, restore the first delay")
    }

    func testStreamRestartCannotCountEarlierPlaybackTowardHealthyRecovery() {
        var recovery = RemoteView.StreamRecovery()
        recovery.failed(.startFailed, at: 0)
        recovery.receivedVideo(at: 2)
        recovery.streamStarting()
        recovery.receivedVideo(at: 40)
        recovery.failed(.streamInterrupted, at: 41)
        XCTAssertEqual(recovery.retryAt, 45)
    }

    @MainActor
    func testVideoRetryDoesNotStartAnUnconnectedSession() {
        let session = RemoteViewSession(host: "Test", address: "127.0.0.1", port: 1,
                                        target: .display(index: 0, name: "Monitor"))
        XCTAssertFalse(session.canRetryVideo)
        session.retryVideo()
        XCTAssertEqual(session.status, .connecting)
        XCTAssertNil(session.videoFallbackReason)
        XCTAssertFalse(session.isRecoveringVideo)
    }

    func testActivityRequiresExplicitHostEvidenceAndValidRates() {
        let report: [String: Any] = ["source": "host", "state": "idle", "activeFPS": 60, "idleFPS": 0, "revision": 2]
        let activity = RemoteView.StreamActivity(report)
        XCTAssertEqual(activity?.state, .idle)
        XCTAssertEqual(activity?.activeFPS, 60)
        XCTAssertEqual(activity?.idleFPS, 0)
        XCTAssertNil(RemoteView.StreamActivity(nil), "Older hosts cannot be inferred idle")
        XCTAssertNil(RemoteView.StreamActivity(["ok": true]))
        for (key, value) in [("source", "viewer"), ("state", "disconnected")] {
            var invalid = report
            invalid[key] = value
            XCTAssertNil(RemoteView.StreamActivity(invalid))
        }
        for (key, value) in [("activeFPS", 0), ("activeFPS", 61), ("idleFPS", -1), ("idleFPS", 61), ("revision", -1)] {
            var invalid = report
            invalid[key] = value
            XCTAssertNil(RemoteView.StreamActivity(invalid))
        }
        var unknown = report
        unknown["state"] = "unknown"
        XCTAssertEqual(RemoteView.StreamActivity(unknown)?.state, .unknown)
    }

    func testDelayedAcknowledgementCannotReplaceNewerHostActivity() throws {
        let idle = try XCTUnwrap(RemoteView.StreamActivity([
            "source": "host", "state": "idle", "activeFPS": 60, "idleFPS": 0, "revision": 3,
        ]))
        let resumed = try XCTUnwrap(RemoteView.StreamActivity([
            "source": "host", "state": "active", "activeFPS": 60, "idleFPS": 0, "revision": 4,
        ]))
        XCTAssertTrue(idle.supersedes(nil))
        XCTAssertTrue(resumed.supersedes(idle))
        XCTAssertTrue(resumed.supersedes(resumed))
        XCTAssertFalse(idle.supersedes(resumed))
    }

    func testFrameRateDecaysWithoutNewFramesAndRecoversAfterIdle() {
        var meter = RemoteView.FrameRateMeter()
        XCTAssertEqual(meter.rate(at: 0), 0)
        for frame in 0...60 { meter.record(at: Double(frame) / 60) }
        XCTAssertEqual(meter.rate(at: 1), 60, accuracy: 0.001)
        XCTAssertLessThan(meter.rate(at: 1.5), 60)
        XCTAssertEqual(meter.rate(at: 3.1), 0, "No new frames must not leave the old rate on screen")
        for frame in 0...30 { meter.record(at: 5 + Double(frame) / 30) }
        XCTAssertEqual(meter.rate(at: 6), 30, accuracy: 0.001)
    }

    func testRequestWidthFollowsTheViewOnThisScreen() {
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 800, backingScale: 2), 1600)
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 3000, backingScale: 2), 3840)
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 1600, backingScale: 1), 1600)
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 1600, backingScale: 2), 3200)
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 50, backingScale: 1), 320)
    }

    func testKeysBecomeTextOrNamedPresses() {
        XCTAssertEqual(RemoteView.key(keyCode: 0, characters: "a", ignoringModifiers: "a", modifiers: []), .text("a"))
        XCTAssertEqual(RemoteView.key(keyCode: 0, characters: "A", ignoringModifiers: "a", modifiers: .shift), .text("A"))
        XCTAssertEqual(RemoteView.key(keyCode: 36, characters: "\r", ignoringModifiers: "\r", modifiers: []), .press(key: "enter", modifiers: []))
        XCTAssertEqual(RemoteView.key(keyCode: 8, characters: "c", ignoringModifiers: "c", modifiers: .command), .press(key: "c", modifiers: ["command"]))
        XCTAssertEqual(RemoteView.key(keyCode: 123, characters: "\u{F702}", ignoringModifiers: "\u{F702}", modifiers: [.shift, .option]),
                       .press(key: "left", modifiers: ["option", "shift"]))
        XCTAssertNil(RemoteView.key(keyCode: 200, characters: "\u{F704}", ignoringModifiers: nil, modifiers: []))
    }

    func testMacTypingIsAvailableWithoutLinuxPhysicalKeyboardCapability() {
        XCTAssertEqual(RemoteView.keyboardSupport(platform: "macos", methods: ["computer.pressKey"], interactive: nil),
                       .init(canSend: true, canCapture: false))
        XCTAssertEqual(RemoteView.keyboardSupport(platform: "macos", methods: ["computer.click"], interactive: nil),
                       .init(canSend: false, canCapture: false))
    }

    func testLinuxKeyboardKeepsPhysicalAndTextOnlyTransportsDistinct() {
        XCTAssertEqual(RemoteView.keyboardSupport(platform: "linux", methods: ["computer.pressKey"], interactive: ["keyboard": true]),
                       .init(canSend: true, canCapture: true))
        XCTAssertEqual(RemoteView.keyboardSupport(platform: "linux", methods: ["computer.pressKey", "computer.typeText"], interactive: nil),
                       .init(canSend: true, canCapture: false))
        XCTAssertEqual(RemoteView.keyboardSupport(platform: "linux", methods: [], interactive: ["keyboard": true]),
                       .init(canSend: false, canCapture: false))
    }

    @MainActor
    func testTransientInputReleasePreservesKeyboardChoiceButControlOffDisablesIt() {
        let session = RemoteViewSession(host: "Test", address: "127.0.0.1", port: 1,
                                        target: .display(index: 0, name: "Monitor"))
        session.controlling = true
        session.keyboardEnabled = true
        session.releaseInput()
        XCTAssertTrue(session.keyboardEnabled, "Switching away from the viewer must not turn typing off")
        XCTAssertFalse(session.keyboardCaptured)
        session.resumeInput()
        XCTAssertFalse(session.keyboardCaptured, "An inactive or unsupported host must not capture local keys")
        session.target = .display(index: 1, name: "Another monitor")
        XCTAssertTrue(session.keyboardEnabled, "Changing the viewed monitor preserves the explicit typing choice")
        session.controlling = false
        XCTAssertFalse(session.keyboardEnabled)
        session.keyboardEnabled = true
        session.stop()
        XCTAssertFalse(session.keyboardEnabled, "Closing the session disables typing")
    }

    func testMacGlobalTypingMapsShiftedPunctuationToSupportedBaseKeys() {
        XCTAssertEqual(RemoteView.macTextKeys("A?@_+{}|:\"~"), [
            .press(key: "a", modifiers: ["shift"]), .press(key: "/", modifiers: ["shift"]),
            .press(key: "2", modifiers: ["shift"]), .press(key: "-", modifiers: ["shift"]),
            .press(key: "=", modifiers: ["shift"]), .press(key: "[", modifiers: ["shift"]),
            .press(key: "]", modifiers: ["shift"]), .press(key: "\\", modifiers: ["shift"]),
            .press(key: ";", modifiers: ["shift"]), .press(key: "'", modifiers: ["shift"]),
            .press(key: "`", modifiers: ["shift"]),
        ])
        XCTAssertEqual(RemoteView.macTextKeys("a /\n\t"), [
            .press(key: "a", modifiers: []), .press(key: "space", modifiers: []),
            .press(key: "/", modifiers: []), .press(key: "enter", modifiers: []),
            .press(key: "tab", modifiers: []),
        ])
    }

    func testUnsupportedMacGlobalTextIsRejectedBeforePartOfItIsSent() {
        XCTAssertNil(RemoteView.macTextKeys("before 🦋 after"))
        XCTAssertNil(RemoteView.macTextKeys("café"))
        XCTAssertEqual(RemoteView.macTextKeys(""), [])
    }

    func testTargetsAskForWhatTheyShow() {
        XCTAssertEqual(RemoteView.Target.display(index: 1, name: "DP-2").params["displayIndex"] as? Int, 1)
        XCTAssertEqual(RemoteView.Target.window(wid: 42, app: "Ghostty", title: "Ghostty").label, "Ghostty")
        XCTAssertEqual(RemoteView.Target.region(CGRect(x: 10, y: 20, width: 300, height: 200)).params["width"] as? Double, 300)
    }

    func testDisplaysParseFromLinuxAndMacShapes() {
        let displays = RemoteView.parseDisplays([
            ["displayIndex": 0, "displayId": "DP-1", "frame": ["x": 0.0, "y": 0.0, "w": 2560.0, "h": 1440.0], "scale": 1.25],
            ["index": 1, "name": "Studio Display", "frame": ["x": 2560.0, "y": 0.0, "w": 2560.0, "h": 1440.0]],
            ["index": 2, "frame": ["x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0]],
        ])
        XCTAssertEqual(displays.map(\.name), ["DP-1", "Studio Display"])
        XCTAssertEqual(displays[0].scale, 1.25)
        XCTAssertEqual(displays[1].frame.minX, 2560)
    }
}
