import AppKit
import XCTest
@testable import Lattices

final class SpaceCanvasHereTests: XCTestCase {
    func testHereFitsOneRecognizableDesktopAtEveryDisplayAspect() {
        for room in rooms {
            for count in [1, 3, 16, 17] {
                let layout = SpaceCanvasLayout(count: count, room: room)
                for index in Set([0, count / 2, count - 1]) {
                    let frame = layout.view(layout.cell(index), camera: layout.here(on: index))
                    XCTAssertTrue(layout.stage.contains(frame), "Here keeps the monitor clear of navigation chrome")
                    XCTAssertEqual(frame.midX, layout.stage.midX, accuracy: 1e-8)
                    XCTAssertEqual(frame.midY, layout.stage.midY, accuracy: 1e-8)
                    XCTAssertEqual(frame.width / frame.height, room.width / room.height, accuracy: 1e-8)
                    XCTAssertGreaterThan(max(frame.width / layout.stage.width,
                                             frame.height / layout.stage.height), 0.9)
                    XCTAssertGreaterThanOrEqual(layout.here(on: index).scale, layout.fitScale)
                    XCTAssertEqual(layout.index(at: CGPoint(x: frame.midX, y: frame.midY),
                                                camera: layout.here(on: index)), index)
                }
            }
        }
    }

    func testDirectAndStripEntryStayHereWithoutChoosingOrLanding() {
        for reduceMotion in [false, true] {
            for aperture in [nil, CGRect(x: 520, y: 380, width: 168, height: 105)] as [CGRect?] {
                let recorder = Recorder()
                let view = canvas(selected: 2, current: 0, recorder: recorder)
                XCTAssertEqual(view.camera, view.layout.here(on: 0))
                XCTAssertEqual(view.selected, 0)
                XCTAssertEqual(view.selectedWindowID, 102)
                view.open(from: aperture, reduceMotion: reduceMotion)
                XCTAssertEqual(view.camera, view.layout.here(on: 0))
                XCTAssertEqual(view.selected, 0)
                XCTAssertTrue(recorder.choices.isEmpty, "Rendering must not switch or choose a real desktop")
                XCTAssertEqual(recorder.lands, 0)
                XCTAssertTrue(recorder.activations.isEmpty)
                if reduceMotion {
                    XCTAssertNil(find("SpaceCanvas.plane", in: view.layer)?.animation(forKey: "transform"))
                }
            }
        }
    }

    func testHereRestoresOriginalCameraAndNavigatorDestinationAfterInspectionAndFreePan() {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let home = view.camera
        view.showOverview(reduceMotion: true)
        view.selectWindow(id: 201, at: 1, approach: true, reduceMotion: true)
        XCTAssertEqual(view.selectedWindowID, 201)
        pan(view, by: CGPoint(x: 50_000, y: -30_000))
        XCTAssertNotEqual(view.camera, home)
        view.returnHere(reduceMotion: true)
        XCTAssertEqual(view.camera, home)
        XCTAssertEqual(view.selected, 0)
        XCTAssertEqual(view.selectedWindowID, 102)
        XCTAssertEqual(recorder.choices.last, 0, "Enter's navigator destination must agree with the returned camera")
        XCTAssertEqual(recorder.lands, 0)
        XCTAssertTrue(recorder.activations.isEmpty, "Here only navigates the preview")
        let choices = recorder.choices.count
        view.returnHere(reduceMotion: true)
        XCTAssertEqual(recorder.choices.count, choices + 1,
                       "Here must resynchronize external destination even when local selection already matches")
    }

    func testUnavailableCurrentIndexUsesValidSelectedDesktopAsReturnAnchor() {
        let recorder = Recorder()
        let view = canvas(selected: 2, current: 99, focusedWindowID: 301, recorder: recorder)
        XCTAssertEqual(view.selected, 2)
        XCTAssertEqual(view.camera, view.layout.here(on: 2))
        view.showOverview(reduceMotion: true)
        view.selectWindow(id: 101, at: 0, approach: true, reduceMotion: true)
        view.returnHere(reduceMotion: true)
        XCTAssertEqual(view.selected, 2)
        XCTAssertEqual(view.camera, view.layout.here(on: 2))
        XCTAssertEqual(recorder.choices.last, 2)
    }

    func testProductionEntryRejectsMissingCurrentSpaceInsteadOfInventingHere() {
        // Fullscreen Spaces are absent from the desktop-only filmstrip.
        // Its selected thumbnail cannot stand in for the actual current Space.
        XCTAssertNil(SpaceSwitchCanvasEntry(spaceIDs: [10, 20, 30], currentSpaceID: 99, selected: 1))
        XCTAssertNil(SpaceSwitchCanvasEntry(spaceIDs: [], currentSpaceID: 10))
    }

    func testProductionEntryKeepsActualHereSeparateFromStripThumbnail() throws {
        let entry = try XCTUnwrap(SpaceSwitchCanvasEntry(spaceIDs: [10, 20, 30], currentSpaceID: 20, selected: 2))
        XCTAssertEqual(entry.current, 1)
        XCTAssertEqual(entry.selected, 2, "The entry animation may retain a different thumbnail without redefining Here")
        for selected in [nil, -1, 3, 99] as [Int?] {
            let fallback = try XCTUnwrap(SpaceSwitchCanvasEntry(spaceIDs: [10, 20, 30], currentSpaceID: 20,
                                                              selected: selected))
            XCTAssertEqual(fallback.current, 1)
            XCTAssertEqual(fallback.selected, 1)
        }
    }

    func testHereAndKeyboardShortcutStopHeldZoomWithoutLanding() {
        for useKeyboard in [false, true] {
            let recorder = Recorder()
            let view = canvas(recorder: recorder)
            view.showOverview(reduceMotion: true)
            view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
            view.advanceKeyboardZoom(to: 1)
            if useKeyboard { view.handleKey(4, pressed: true, repeated: false) }
            else { view.returnHere(reduceMotion: true) }
            let returned = view.camera
            XCTAssertEqual(returned, view.layout.here(on: 0))
            view.advanceKeyboardZoom(to: 5)
            view.zoomKey(126, pressed: false, time: 5)
            XCTAssertEqual(view.camera, returned, "The old held key cannot pull the returned camera away again")
            XCTAssertEqual(recorder.choices.last, 0)
            XCTAssertEqual(recorder.lands, 0)
        }
    }

    func testOverviewAndHereKeepWindowCoordinatesOverlapAndLayerIdentity() throws {
        let view = canvas(recorder: Recorder())
        let root = try XCTUnwrap(view.layer)
        let containers = try [10, 20, 30].map { try XCTUnwrap(find("SpaceCanvas.windows.\($0)", in: root)) }
        let frames = containers.map { $0.sublayers?.map(\.frame) ?? [] }
        let identities = containers.map { $0.sublayers?.map(ObjectIdentifier.init) ?? [] }
        let containerFrames = containers.map(\.frame)
        let home = view.camera
        for _ in 0..<3 {
            view.showOverview(reduceMotion: true)
            XCTAssertEqual(view.camera, view.layout.opening(on: 0), "The complete existing overview stays available")
            view.selectWindow(id: 301, at: 2, approach: true, reduceMotion: true)
            view.returnHere(reduceMotion: true)
            XCTAssertEqual(view.camera, home)
            XCTAssertEqual(containers.map(\.frame), containerFrames)
            XCTAssertEqual(containers.map { $0.sublayers?.map(\.frame) ?? [] }, frames)
            XCTAssertEqual(containers.map { $0.sublayers?.map(ObjectIdentifier.init) ?? [] }, identities)
        }
    }

    func testClickSelectsFrontmostWindowAndEnterActivatesThatIdentityOnly() {
        let recorder = Recorder()
        let view = canvas(focusedWindowID: nil, recorder: recorder)
        let overlap = point(CGPoint(x: 0.4, y: 0.4), at: 0, in: view)
        view.beginPointer(at: overlap)
        view.endPointer(at: overlap)
        XCTAssertEqual(view.selectedWindowID, 102, "The foreground window occludes the one behind it")
        XCTAssertTrue(recorder.activations.isEmpty, "A selection remains reviewable before activation")
        XCTAssertTrue(recorder.drops.isEmpty)
        view.handleKey(36, pressed: true, repeated: false)
        XCTAssertEqual(recorder.activations.map(\.wid), [102])
        XCTAssertEqual(recorder.activations.first?.pid, 4102)
        XCTAssertEqual(recorder.lands, 0, "A chosen window uses the window activation path")
    }

    func testDoubleClickActivatesFrontmostWindowAndUnknownWindowDoesNotExposeOneBehind() {
        let recorder = Recorder()
        let view = canvas(focusedWindowID: nil, recorder: recorder)
        view.beginPointer(at: point(CGPoint(x: 0.4, y: 0.4), at: 0, in: view), clickCount: 2)
        XCTAssertEqual(recorder.activations.map(\.wid), [102])
        XCTAssertEqual(recorder.lands, 0)

        let unknown = window(0, title: "Unidentified foreground window")
        let blocked = Recorder()
        var obscured = cards()
        obscured[0] = .init(id: 10, number: 2, windows: [window(101), unknown])
        let obscuredView = canvas(cards: obscured, focusedWindowID: nil, recorder: blocked)
        let overlap = point(CGPoint(x: 0.4, y: 0.4), at: 0, in: obscuredView)
        obscuredView.beginPointer(at: overlap)
        obscuredView.endPointer(at: overlap)
        obscuredView.activateSelectedWindow()
        XCTAssertNil(obscuredView.selectedWindowID)
        XCTAssertTrue(blocked.activations.isEmpty, "Missing identity cannot target an occluded real window")
    }

    func testDoubleClickKeepsFirstWindowIdentityAfterCameraApproachesIt() {
        let recorder = Recorder()
        let view = canvas(focusedWindowID: nil, recorder: recorder)
        view.showOverview(reduceMotion: true)
        let overview = view.camera
        let firstClick = point(CGPoint(x: 0.4, y: 0.6), at: 2, in: view)
        view.beginPointer(at: firstClick)
        view.endPointer(at: firstClick)
        XCTAssertEqual(view.selectedWindowID, 301)
        XCTAssertEqual(view.selected, 2)
        XCTAssertNotEqual(view.camera, overview, "The first click starts approaching the off-center window")
        let topLeft = point(CGPoint(x: 0.2, y: 0.2), at: 2, in: view)
        let bottomRight = point(CGPoint(x: 0.65, y: 0.65), at: 2, in: view)
        let approachedWindow = CGRect(x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        XCTAssertFalse(approachedWindow.contains(firstClick), "The camera goal has moved the window away from the pointer")
        XCTAssertTrue(recorder.activations.isEmpty)

        view.beginPointer(at: firstClick, clickCount: 2)
        XCTAssertEqual(recorder.activations.map(\.wid), [301],
                       "A stationary second click belongs to the first window despite the moving camera")
        XCTAssertEqual(recorder.lands, 0)
        XCTAssertTrue(recorder.drops.isEmpty)
    }

    func testTabStaysWithinVisibleDesktopAndEnterUsesSelectedRealWindow() {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        view.handleKey(48, pressed: true, repeated: false)
        XCTAssertNotEqual(view.selectedWindowID, 102)
        XCTAssertEqual(view.selectedWindowID, 101)
        view.handleKey(36, pressed: true, repeated: false)
        XCTAssertEqual(recorder.activations.map(\.wid), [101])
        XCTAssertEqual(recorder.lands, 0)
    }

    func testRemovedSelectedWindowCannotBeActivatedFromStaleInventory() {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        var fresh = cards()
        fresh[0] = .init(id: 10, number: 2, windows: [window(101)])
        XCTAssertTrue(view.refresh(cards: fresh))
        XCTAssertNil(view.selectedWindowID)
        view.activateSelectedWindow()
        XCTAssertTrue(recorder.activations.isEmpty)
        view.returnHere(reduceMotion: true)
        XCTAssertNil(view.selectedWindowID, "Here cannot resurrect a closed initial window")
    }

    func testHereKeepsDisplayNameAndSpaceIdentityWhenDesktopNumbersRepeat() throws {
        let recorder = Recorder()
        let view = canvas(selected: 0, current: 1, focusedWindowID: 201, recorder: recorder)
        XCTAssertEqual(view.selected, 1)
        XCTAssertEqual(view.camera, view.layout.here(on: 1))
        let labels = text(in: try XCTUnwrap(view.layer)).joined(separator: " ")
        XCTAssertTrue(labels.contains("Studio Display"), "Current-screen identity must include its monitor")
        XCTAssertTrue(labels.contains("Desktop 2"))
        view.selectWindow(id: 101, at: 0, approach: true, reduceMotion: true)
        view.returnHere(reduceMotion: true)
        XCTAssertEqual(recorder.choices.last, 1,
                       "The original Space's identity wins over a repeated human-readable desktop number")
        XCTAssertEqual(view.selectedWindowID, 201)
    }

    func testSameSpaceIDsOnTwoMonitorsProjectOnlyTheirOwnWindowGeometry() throws {
        // With separate Spaces disabled, the Space IDs can match while the
        // physical monitor and its global CG origin are different.
        let spaces = [SpaceInfo(id: 71, index: 2, display: 0, isCurrent: true),
                      SpaceInfo(id: 72, index: 3, display: 0, isCurrent: false)]
        let leftBounds = CGRect(x: -900, y: -400, width: 900, height: 1440)
        let rightBounds = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let inventory = [
            WindowEntry(wid: 701, app: "Editor", pid: -1, title: "Portrait",
                frame: WindowFrame(x: -810, y: -256, w: 450, h: 720),
                spaceIds: [71], isOnScreen: true, latticesSession: nil, zIndex: 0),
            WindowEntry(wid: 702, app: "Terminal", pid: -1, title: "Wide",
                frame: WindowFrame(x: 344, y: 144, w: 1720, h: 720),
                spaceIds: [71], isOnScreen: true, latticesSession: nil, zIndex: 1)
        ]
        for (bounds, expectedID, name) in [(leftBounds, UInt32(701), "Portrait display"),
                                           (rightBounds, UInt32(702), "Wide display")] {
            let projected = SpaceFilmstripLayout.cards(spaces: spaces, windows: inventory, bounds: bounds)
            XCTAssertEqual(projected.map(\.id), [71, 72])
            XCTAssertEqual(projected[0].allWindows.map(\.wid), [expectedID])
            XCTAssertTrue(projected[1].allWindows.isEmpty)
            let window = try XCTUnwrap(projected[0].allWindows.first)
            XCTAssertEqual(window.rect.minX, 0.1, accuracy: 1e-8)
            XCTAssertEqual(window.rect.minY, 0.1, accuracy: 1e-8)
            XCTAssertEqual(window.rect.width, 0.5, accuracy: 1e-8)
            XCTAssertEqual(window.rect.height, 0.5, accuracy: 1e-8)
            let view = SpaceCanvasView(cards: projected, selected: 1, current: 0, room: bounds.size,
                scale: 2, displayName: name, focusedWindowID: expectedID,
                handlers: .init(choose: { _ in }, land: {}, cancel: {}))
            view.open(from: nil, reduceMotion: true)
            XCTAssertEqual(view.camera, view.layout.here(on: 0))
            XCTAssertEqual(view.selectedWindowID, expectedID)
            XCTAssertTrue(text(in: try XCTUnwrap(view.layer)).joined(separator: " ").contains(name))
        }
    }

    private let rooms = [CGSize(width: 1440, height: 900), CGSize(width: 3440, height: 1440),
                         CGSize(width: 900, height: 1440)]

    private final class Recorder {
        weak var view: SpaceCanvasView?
        var choices: [Int] = []
        var activations: [SpaceFilmstripWindow] = []
        var drops: [SpaceCanvasWindowDrop] = []
        var lands = 0
        func choose(_ index: Int) {
            choices.append(index)
            view?.select(index, animated: false)
        }
    }

    private func canvas(cards: [SpaceFilmstripCard]? = nil, selected: Int = 0, current: Int = 0,
                        focusedWindowID: UInt32? = 102, recorder: Recorder) -> SpaceCanvasView {
        _ = NSApplication.shared
        let view = SpaceCanvasView(cards: cards ?? self.cards(), selected: selected, current: current,
            room: CGSize(width: 1440, height: 900), scale: 2,
            displayName: "Studio Display", focusedWindowID: focusedWindowID,
            handlers: .init(choose: { recorder.choose($0) }, land: { recorder.lands += 1 }, cancel: {},
                activateWindow: { recorder.activations.append($0) },
                moveWindow: { drop, _ in recorder.drops.append(drop) }))
        recorder.view = view
        return view
    }

    private func cards() -> [SpaceFilmstripCard] {
        [.init(id: 10, number: 2, windows: [window(101), window(102)]),
         .init(id: 20, number: 2, windows: [window(201)]),
         .init(id: 30, number: 5, windows: [window(301)])]
    }

    private func window(_ id: UInt32, title: String = "Fixture") -> SpaceFilmstripWindow {
        .init(rect: CGRect(x: 0.2, y: 0.2, width: 0.45, height: 0.45), app: "Editor",
              pid: Int32(id) + 4000, title: title, wid: id)
    }

    private func point(_ local: CGPoint, at index: Int, in view: SpaceCanvasView) -> CGPoint {
        let frame = view.layout.view(view.layout.cell(index), camera: view.camera)
        return CGPoint(x: frame.minX + local.x * frame.width, y: frame.minY + local.y * frame.height)
    }

    private func pan(_ view: SpaceCanvasView, by delta: CGPoint) {
        let start = point(CGPoint(x: 0.85, y: 0.2), at: view.selected, in: view)
        let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        view.beginPointer(at: start)
        view.dragPointer(to: end)
        view.endPointer(at: end)
    }

    private func find(_ name: String, in root: CALayer?) -> CALayer? {
        guard let root else { return nil }
        if root.name == name { return root }
        return root.sublayers?.lazy.compactMap { self.find(name, in: $0) }.first
    }

    private func text(in root: CALayer) -> [String] {
        ([(root as? CATextLayer)?.string as? String].compactMap { $0 })
            + (root.sublayers ?? []).flatMap { text(in: $0) }
    }
}
