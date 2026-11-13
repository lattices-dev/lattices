import AppKit
import XCTest
@testable import Lattices

final class SpaceCanvasNavigationTests: XCTestCase {
    private let rooms = [CGSize(width: 1440, height: 900), CGSize(width: 3440, height: 1440),
                         CGSize(width: 900, height: 1440)]

    private func assertCamera(_ actual: SpaceCanvasCamera, _ expected: SpaceCanvasCamera,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.center.x, expected.center.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.center.y, expected.center.y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.scale, expected.scale, accuracy: 1e-9, file: file, line: line)
    }

    func testTapAndHeldZoomShareTheExistingSmoothCameraPath() {
        for room in rooms {
            let layout = SpaceCanvasLayout(count: 17, room: room)
            for index in [0, 8, 16] {
                let route = SpaceCanvasNavigation(overview: layout.opening(on: index), focused: layout.filling(index))
                let path = SpaceCanvasCamera.path(from: route.overview, to: route.focused, steps: 60)
                for camera in path { assertCamera(route.camera(atScale: camera.scale), camera) }
                XCTAssertEqual(route.camera(atScale: 0), route.overview)
                XCTAssertEqual(route.camera(atScale: layout.maxScale * 2), route.focused)
            }
        }
    }

    func testZoomOutAndBackReturnsToEveryIntermediateCamera() {
        for room in rooms {
            let layout = SpaceCanvasLayout(count: 16, room: room)
            let route = SpaceCanvasNavigation(overview: layout.opening(on: 15), focused: layout.filling(15))
            for fraction in [0.3, 0.5, 0.8, 1.0] {
                let scale = layout.fitScale * pow(layout.maxScale / layout.fitScale, fraction)
                let start = route.camera(atScale: scale)
                let out = route.camera(atScale: scale / 1.4)
                let back = route.camera(atScale: out.scale * 1.4)
                assertCamera(back, start)
                // A held reversal may supply fractional deltas rather than a notch.
                let heldOut = route.camera(atScale: scale * exp(-0.17))
                assertCamera(route.camera(atScale: heldOut.scale * exp(0.17)), start)
            }
        }
    }

    func testRebaseRetainsPanAtEveryZoomWithoutCreatingAMidpointLimit() {
        for room in rooms {
            let layout = SpaceCanvasLayout(count: 16, room: room)
            let initial = SpaceCanvasNavigation(overview: layout.opening(on: 0), focused: layout.filling(0))
            for fraction in [0.0, 0.000001, 0.3, 0.7, 0.999999, 1.0] {
                var route = initial
                let scale = layout.fitScale * pow(layout.maxScale / layout.fitScale, fraction)
                var anchor = route.camera(atScale: scale)
                anchor.center.x += 3.25
                anchor.center.y -= 2.75
                route.rebase(at: anchor)
                assertCamera(route.camera(atScale: scale), anchor)
                XCTAssertEqual(route.overview.scale, initial.overview.scale)
                XCTAssertEqual(route.focused.scale, initial.focused.scale)
                if fraction <= 0.5 { XCTAssertEqual(route.focused, initial.focused) }
                else { XCTAssertEqual(route.overview, initial.overview) }
                XCTAssertLessThan(abs(route.overview.center.x), 20)
                XCTAssertLessThan(abs(route.focused.center.x), 20,
                                  "A pan close to a limit must not be magnified by extrapolation")
                let outScale = max(layout.fitScale, scale / 1.2)
                _ = route.camera(atScale: outScale)
                assertCamera(route.camera(atScale: scale), anchor)
            }
        }
    }

    func testExplicitDestinationChangeKeepsThePannedOverview() {
        let layout = SpaceCanvasLayout(count: 16, room: CGSize(width: 3440, height: 1440))
        var route = SpaceCanvasNavigation(overview: layout.opening(on: 0), focused: layout.filling(0))
        var panned = route.overview
        panned.center.x += 8
        panned.center.y -= 5
        route.rebase(at: panned)
        route.retarget(focused: layout.filling(15))
        XCTAssertEqual(route.camera(atScale: layout.maxScale), layout.filling(15))
        XCTAssertEqual(route.camera(atScale: layout.fitScale), panned)
    }

    private final class SelectionRelay {
        weak var view: SpaceCanvasView?
        var choices: [Int] = []
        func choose(_ index: Int) {
            choices.append(index)
            view?.select(index, animated: false)
        }
    }

    private func makeView(room: CGSize = CGSize(width: 3440, height: 1440), selected: Int = 3,
                          current: Int? = nil, overview: Bool = true) -> SpaceCanvasView {
        _ = NSApplication.shared
        let relay = SelectionRelay()
        let view = SpaceCanvasView(cards: (1...16).map { .init(id: $0, number: $0, windows: []) },
            selected: selected, current: current ?? selected, room: room, scale: 2,
            handlers: .init(choose: { relay.choose($0) },
                            land: { XCTFail("Navigation must not land") }, cancel: {}))
        relay.view = view
        if overview { view.showOverview(reduceMotion: true) }
        return view
    }

    private func pan(_ view: SpaceCanvasView, by delta: CGPoint) {
        let start = CGPoint(x: view.layout.stage.midX, y: view.layout.stage.midY)
        let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        view.beginPointer(at: start)
        view.dragPointer(to: end)
        view.endPointer(at: end)
    }

    private func hold(_ key: Int64, in view: SpaceCanvasView, at time: TimeInterval) {
        view.zoomKey(key, pressed: true, reduceMotion: true, time: time)
        for frame in 1...180 { view.advanceKeyboardZoom(to: time + Double(frame) / 60) }
        view.zoomKey(key, pressed: false, time: time + 3)
    }

    func testViewNotchRoundtripPreservesPannedCameraAtIntermediateScalesAndLimits() {
        for room in rooms {
            for steps in [-1, 0, 1, 3, 20] {
                let view = makeView(room: room)
                if steps < 0 {
                    view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
                    for frame in 1...23 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
                    view.zoomKey(126, pressed: false, time: 23.0 / 60)
                } else {
                    for _ in 0..<steps { view.zoom(out: false, reduceMotion: true) }
                }
                pan(view, by: CGPoint(x: 1273, y: -931))
                let start = view.camera
                let firstOut = start.scale > view.layout.fitScale
                view.zoom(out: firstOut, reduceMotion: true)
                view.zoom(out: !firstOut, reduceMotion: true)
                assertCamera(view.camera, start)
            }
        }
    }

    func testHeldRoundtripReturnsToTheSameFreelyPannedFullCamera() {
        let view = makeView()
        for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
        pan(view, by: CGPoint(x: 723, y: -391))
        let start = view.camera
        XCTAssertFalse(view.locked)
        hold(125, in: view, at: 0)
        XCTAssertEqual(view.camera.scale, view.layout.fitScale)
        view.zoomKey(126, pressed: true, reduceMotion: true, time: 4)
        for frame in 1...180 { view.advanceKeyboardZoom(to: 4 + Double(frame) / 60) }
        assertCamera(view.camera, start)
        XCTAssertFalse(view.locked, "Returning to a panned full-scale view must not snap to a desktop")
        // Beginning another gesture stops the drive without changing its endpoint.
        let middle = CGPoint(x: view.layout.stage.midX, y: view.layout.stage.midY)
        view.beginPointer(at: middle)
        assertCamera(view.camera, start)
        view.zoomKey(126, pressed: false, time: 7)
    }

    func testPassiveHoverDoesNotRedirectTheOriginalZoomDestination() {
        let view = makeView(selected: 3)
        let target = view.layout.view(view.layout.cell(15), camera: view.camera)
        view.highlight(at: CGPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(view.selected, 15, "The pointer can still highlight another desktop")
        for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
        assertCamera(view.camera, view.layout.filling(3))
        XCTAssertEqual(view.selected, 3)
    }

    func testEntryZoomReturnUsesCurrentDesktopForDirectAndStripEntry() {
        let aperture = CGRect(x: 1300, y: 600, width: 240, height: 100)
        for reduceMotion in [false, true] {
            for card in [nil, aperture] as [CGRect?] {
                let view = makeView(selected: 12, current: 3, overview: false)
                view.open(from: card, reduceMotion: reduceMotion)
                assertCamera(view.camera, view.layout.here(on: 3))
                XCTAssertEqual(view.selected, 3, "Both entry paths begin at the current screen")
                for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
                assertCamera(view.camera, view.layout.filling(3))
                XCTAssertEqual(view.selected, 3)
            }
        }
    }

    func testClickingTheHoveredDesktopExplicitlyRetargetsZoom() {
        let view = makeView(selected: 3)
        let target = view.layout.view(view.layout.cell(15), camera: view.camera)
        let point = CGPoint(x: target.midX, y: target.midY)
        view.highlight(at: point)
        view.beginPointer(at: point)
        view.endPointer(at: point)
        for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
        assertCamera(view.camera, view.layout.filling(15))
    }

    func testExplicitKeyboardDestinationAtHighZoomRemainsExact() {
        let view = makeView(selected: 3)
        for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
        view.zoom(out: true, reduceMotion: true)
        view.moveSelection(offset: 1)
        XCTAssertEqual(view.selected, 4)
        for _ in 0..<20 { view.zoom(out: false, reduceMotion: true) }
        assertCamera(view.camera, view.layout.filling(4))
        XCTAssertTrue(view.locked)
    }

    func testHorizontalAndVerticalPanRemainFreeAndReverseImmediatelyThenFitRecovers() {
        for delta in [CGPoint(x: 100_000, y: 0), CGPoint(x: 0, y: -100_000)] {
            let view = makeView()
            let original = view.camera
            let start = CGPoint(x: view.layout.stage.midX, y: view.layout.stage.midY)
            let far = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
            view.beginPointer(at: start)
            view.dragPointer(to: far)
            assertCamera(view.camera, SpaceCanvasCamera(center: CGPoint(
                x: original.center.x - delta.x / original.scale,
                y: original.center.y - delta.y / original.scale), scale: original.scale))
            let atFar = view.camera
            let reverse = CGPoint(x: delta.x == 0 ? 0 : -20, y: delta.y == 0 ? 0 : 20)
            let returned = CGPoint(x: far.x + reverse.x, y: far.y + reverse.y)
            view.dragPointer(to: returned)
            assertCamera(view.camera, SpaceCanvasCamera(center: CGPoint(
                x: atFar.center.x - reverse.x / original.scale,
                y: atFar.center.y - reverse.y / original.scale), scale: original.scale))
            view.endPointer(at: returned)
            view.handleKey(29, pressed: true, repeated: false)
            assertCamera(view.camera, view.layout.opening(on: view.selected))
            view.zoom(out: false, reduceMotion: true)
            view.zoom(out: true, reduceMotion: true)
            assertCamera(view.camera, view.layout.opening(on: view.selected))
        }
    }
}
