import CoreGraphics
import XCTest
@testable import Lattices

final class MachineCanvasCameraTests: XCTestCase {
    func testFitCentresContentAndReadsAsHundredPercent() {
        let content = CGRect(x: -1920, y: 0, width: 6000, height: 1440)
        let cam = MachineCanvasCamera.fitting(content, in: CGSize(width: 800, height: 300))
        XCTAssertEqual(cam.percent, 100)
        let r = cam.viewportRect(content)
        XCTAssertEqual(r.midX, 400, accuracy: 0.5)
        XCTAssertEqual(r.midY, 150, accuracy: 0.5)
        XCTAssertLessThanOrEqual(r.width, 800 - 56 + 0.5)
    }

    func testZoomKeepsTheAnchorStill() {
        let cam = MachineCanvasCamera.fitting(CGRect(x: 0, y: 0, width: 4000, height: 2000), in: CGSize(width: 800, height: 400))
        let anchor = CGPoint(x: 200, y: 120)
        let before = cam.worldPoint(anchor)
        let zoomed = cam.zoomed(by: 2, around: anchor)
        XCTAssertEqual(zoomed.percent, 200)
        XCTAssertEqual(zoomed.worldPoint(anchor).x, before.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.worldPoint(anchor).y, before.y, accuracy: 0.001)
    }

    func testZoomIsLimitedAroundTheFit() {
        let cam = MachineCanvasCamera.fitting(CGRect(x: 0, y: 0, width: 4000, height: 2000), in: CGSize(width: 800, height: 400))
        XCTAssertEqual(cam.zoomed(by: 0.01).percent, 50)
        XCTAssertEqual(cam.zoomed(by: 1000).scale, cam.maximumScale, accuracy: 0.0001)
    }

    func testPanCannotLoseTheContent() {
        let content = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let cam = MachineCanvasCamera.fitting(content, in: CGSize(width: 800, height: 400))
        let far = cam.panned(by: CGSize(width: 5000, height: -5000)).clamped(to: content)
        let r = far.viewportRect(content)
        XCTAssertEqual(r.minX, 800 - 80, accuracy: 0.5)
        XCTAssertEqual(r.maxY, 80, accuracy: 0.5)
        XCTAssertEqual(cam.clamped(to: content), cam)
    }

    func testBandFollowsTheContentShape() {
        let wide = MachineCanvasCamera.bandHeight(content: CGRect(x: 0, y: 0, width: 10000, height: 1440), width: 900, available: 900)
        let tall = MachineCanvasCamera.bandHeight(content: CGRect(x: 0, y: 0, width: 4000, height: 3500), width: 900, available: 900)
        XCTAssertEqual(wide, 220)
        XCTAssertGreaterThan(tall, wide)
        XCTAssertLessThanOrEqual(tall, 540)
        XCTAssertEqual(MachineCanvasCamera.bandHeight(content: .null, width: 900, available: 900), 220)
    }

    func testRegionMapsIntoHostCoordinates() {
        let tile = CGRect(x: 1000, y: 0, width: 1720, height: 720)
        let monitor = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let region = MachineCanvasCamera.hostRegion(CGRect(x: 1860, y: 360, width: 860, height: 360), tile: tile, monitor: monitor)
        XCTAssertEqual(region, CGRect(x: 1720, y: 720, width: 1720, height: 720))
        // Dragged up and left, and spilling past the tile.
        let flipped = MachineCanvasCamera.hostRegion(CGRect(x: 3000, y: 900, width: -1140, height: -540), tile: tile, monitor: monitor)
        XCTAssertEqual(flipped, CGRect(x: 1720, y: 720, width: 1720, height: 720))
        XCTAssertNil(MachineCanvasCamera.hostRegion(CGRect(x: 1000, y: 0, width: 5, height: 5), tile: tile, monitor: monitor))
    }

    func testSceneQueuesUnplacedMachinesAndScalesMonitors() {
        let screens: [VisitController.Screen] = [
            .init(number: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), main: true, elsewhere: false, displayID: 1),
        ]
        let machines = MachineInventory.merge([.init(name: "a", address: "a.invalid"), .init(name: "b", address: "b.invalid")])
        let monitors: [String: [MachineArrangementStore.Monitor]] = ["a": [
            .init(name: "L", frame: .init(x: 0, y: 0, width: 1920, height: 1080)),
            .init(name: "R", frame: .init(x: 1920, y: 0, width: 1920, height: 1080)),
        ]]
        let scene = MachineCanvasScene(screens: screens, machines: machines,
                                       monitors: { MachineCanvasScene.monitors($0, fixtures: monitors) }, placement: { _ in nil })
        XCTAssertEqual(scene.nodes[0].rect, CGRect(x: 3160, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(scene.nodes[1].rect.minY, 1380)
        XCTAssertEqual(scene.nodes[0].tiles()[1], CGRect(x: 5080, y: 0, width: 1920, height: 1080))
        let moved = MachineCanvasScene(screens: screens, machines: machines, monitors: { MachineCanvasScene.monitors($0, fixtures: monitors) },
                                       placement: { _ in nil }, machineDraft: [machines[0].id: CGRect(x: 2560, y: 0, width: 3840, height: 1080)])
        XCTAssertEqual(moved.signature, scene.signature)
        XCTAssertEqual(moved.nodes[0].rect.minX, 2560)
    }
}
