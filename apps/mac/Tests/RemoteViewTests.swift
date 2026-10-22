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

    func testRequestWidthFollowsTheViewOnThisScreen() {
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 800, backingScale: 2), 1600)
        XCTAssertEqual(RemoteView.requestWidth(viewWidth: 3000, backingScale: 2), 2560)
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
