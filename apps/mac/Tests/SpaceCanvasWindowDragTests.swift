import XCTest
@testable import Lattices

final class SpaceCanvasWindowDragTests: XCTestCase {
    func testDragThresholdCapturesFrontmostRealWindowWithoutMovingCamera() throws {
        let recorder = Recorder()
        let back = window(101)
        let front = window(102)
        let view = canvas(cards: cards(source: [back, front]), recorder: recorder)
        let root = try XCTUnwrap(view.layer)
        let source = try zone(102, in: root)
        let start = point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view)
        let camera = view.camera

        view.beginPointer(at: start)
        view.dragPointer(to: CGPoint(x: start.x + 2, y: start.y))
        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
        XCTAssertFalse(concealed(source))
        XCTAssertEqual(view.camera, camera)
        view.endPointer(at: CGPoint(x: start.x + 2, y: start.y))
        XCTAssertTrue(recorder.drops.isEmpty, "A click with slight pointer movement must not move a real window")
        view.showOverview(reduceMotion: true)

        let end = CGPoint(x: start.x + 24, y: start.y + 12)
        view.beginPointer(at: start)
        view.dragPointer(to: end)
        let ghost = try XCTUnwrap(find("SpaceCanvas.draggedWindow", in: root))
        XCTAssertEqual(ghost.superlayer?.name, "SpaceCanvas.plane")
        XCTAssertTrue(concealed(source))
        XCTAssertEqual(view.camera, camera)
        XCTAssertFalse(concealed(try zone(101, in: root)))
        view.endPointer(at: end)

        let drop = try XCTUnwrap(recorder.drops.first)
        XCTAssertEqual(drop.window.wid, 102, "Hit testing follows allWindows front-to-back")
        XCTAssertEqual(drop.sourceSpaceID, 10)
        XCTAssertEqual(drop.destinationSpaceID, 10)
        XCTAssertEqual(recorder.drops.count, 1)
        recorder.finish(.failure(TestFailure.rejected))
        flushMainQueue()
        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
        XCTAssertFalse(concealed(try zone(102, in: root)))
        XCTAssertEqual(view.camera, camera)
    }

    func testWithinDesktopDropPreservesGrabOffsetAndUsesActualReturnedFrame() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let camera = view.camera
        let start = point(CGPoint(x: 0.275, y: 0.325), in: 0, view: view)
        let end = point(CGPoint(x: 0.55, y: 0.6), in: 0, view: view)
        drag(view, from: start, to: end)

        let drop = try XCTUnwrap(recorder.drops.first)
        XCTAssertEqual(drop.sourceSpaceID, 10)
        XCTAssertEqual(drop.destinationSpaceID, 10)
        assertPoint(drop.normalizedOrigin, CGPoint(x: 0.475, y: 0.475))
        XCTAssertEqual(drop.window.rect, window(101).rect)
        let actual = CGRect(x: 0.43, y: 0.44, width: 0.31, height: 0.29)
        recorder.finish(.success(actual))
        flushMainQueue()

        let root = try XCTUnwrap(view.layer)
        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
        assertRect(try normalizedFrame(101, space: 10, in: root), actual)
        XCTAssertEqual(view.camera, camera, "A window move must not change the canvas camera")
        XCTAssertEqual(recorder.lands, 0)
    }

    func testClippedWindowDropUsesItsFullFrameForTheGrabOffset() throws {
        let recorder = Recorder()
        let clipped = SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0.2, width: 0.3, height: 0.3),
            app: "Editor", pid: 123, title: "Partially outside the display", wid: 101,
            contentsRect: CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        let view = canvas(cards: cards(source: [clipped]), recorder: recorder)
        // The full window starts at x=-0.1 and is 0.4 wide. Grabbing x=0.1
        // therefore keeps a 0.2 offset when the pointer crosses to desktop 2.
        drag(view,
             from: point(CGPoint(x: 0.1, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.6, y: 0.5), in: 1, view: view))
        let drop = try XCTUnwrap(recorder.drops.first)
        assertPoint(drop.normalizedOrigin, CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(drop.window.contentsRect, clipped.contentsRect)
        let actual = CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.3)
        recorder.finish(.success(actual))
        flushMainQueue()
        assertRect(try normalizedFrame(101, space: 20, in: XCTUnwrap(view.layer)), actual)
    }

    func testAcrossDesktopDropChangesMembershipAndNextDragUsesReconciledGeometry() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let camera = view.camera
        drag(view,
             from: point(CGPoint(x: 0.275, y: 0.325), in: 0, view: view),
             to: point(CGPoint(x: 0.65, y: 0.55), in: 1, view: view))

        let drop = try XCTUnwrap(recorder.drops.first)
        XCTAssertEqual(drop.sourceSpaceID, 10)
        XCTAssertEqual(drop.destinationSpaceID, 20)
        assertPoint(drop.normalizedOrigin, CGPoint(x: 0.575, y: 0.425))
        let actual = CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.3)
        recorder.finish(.success(actual))
        flushMainQueue()

        let root = try XCTUnwrap(view.layer)
        let oldContainer = try XCTUnwrap(find("SpaceCanvas.windows.10", in: root))
        XCTAssertNil(find("SpaceCanvas.photo.101", in: oldContainer))
        assertRect(try normalizedFrame(101, space: 20, in: root), actual)
        XCTAssertEqual(view.camera, camera)
        drag(view,
             from: point(CGPoint(x: 0.6, y: 0.5), in: 1, view: view),
             to: point(CGPoint(x: 0.65, y: 0.55), in: 1, view: view))
        XCTAssertEqual(recorder.drops.count, 2)
        let next = try XCTUnwrap(recorder.drops.last)
        XCTAssertEqual(next.sourceSpaceID, 20)
        XCTAssertEqual(next.destinationSpaceID, 20)
        assertRect(next.window.rect, actual)
        assertPoint(next.normalizedOrigin, CGPoint(x: 0.55, y: 0.45))
        recorder.finish(.failure(TestFailure.rejected))
        flushMainQueue()
    }

    func testOutsideTileDropAndEscapeCancelWithoutMovingOrClosingCanvas() throws {
        for escape in [false, true] {
            let recorder = Recorder()
            let view = canvas(recorder: recorder)
            let root = try XCTUnwrap(view.layer)
            let camera = view.camera
            let start = point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view)
            let end = escape ? point(CGPoint(x: 0.55, y: 0.55), in: 1, view: view)
                : point(CGPoint(x: -0.15, y: 0.3), in: 0, view: view)
            view.beginPointer(at: start)
            view.dragPointer(to: end)
            XCTAssertNotNil(find("SpaceCanvas.draggedWindow", in: root))
            if escape { view.handleKey(53, pressed: true, repeated: false) }
            view.endPointer(at: end)

            XCTAssertTrue(recorder.drops.isEmpty)
            XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
            XCTAssertFalse(concealed(try zone(101, in: root)))
            assertRect(try normalizedFrame(101, space: 10, in: root), window(101).rect)
            XCTAssertEqual(recorder.cancels, 0, "The first Escape cancels the drag and leaves the chooser open")
            XCTAssertEqual(recorder.lands, 0)
            XCTAssertEqual(view.camera, camera)
        }
    }

    func testPendingMoveRejectsNavigationUntilCompletion() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let camera = view.camera
        let selected = view.selected
        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.5, y: 0.5), in: 1, view: view))
        XCTAssertEqual(recorder.drops.count, 1)
        let elsewhere = point(CGPoint(x: 0.8, y: 0.8), in: 1, view: view)
        view.highlight(at: elsewhere)
        view.moveSelection(offset: 1)
        for key in [Int64(124), 126, 36, 53, 29] {
            view.handleKey(key, pressed: true, repeated: false)
        }
        _ = view.zoom(out: false, reduceMotion: true)
        view.beginPointer(at: elsewhere)
        view.dragPointer(to: CGPoint(x: elsewhere.x + 30, y: elsewhere.y + 20))
        view.endPointer(at: elsewhere)

        XCTAssertEqual(view.camera, camera)
        XCTAssertEqual(view.selected, selected)
        XCTAssertTrue(recorder.choices.isEmpty)
        XCTAssertEqual(recorder.lands, 0)
        XCTAssertEqual(recorder.cancels, 0)
        XCTAssertEqual(recorder.drops.count, 1)
        recorder.finish(.failure(TestFailure.rejected))
        flushMainQueue()
        view.handleKey(53, pressed: true, repeated: false)
        XCTAssertEqual(recorder.cancels, 1, "Completion must restore normal chooser input")
    }

    func testActiveWindowDragKeepsCameraAndNavigationCapturedUntilEscape() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let camera = view.camera
        let selected = view.selected
        let start = point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view)
        view.beginPointer(at: start)
        view.dragPointer(to: CGPoint(x: start.x + 30, y: start.y + 20))
        for key in [Int64(124), 126, 36, 29] {
            view.handleKey(key, pressed: true, repeated: false)
        }
        view.moveSelection(offset: 1)
        _ = view.zoom(out: false, reduceMotion: true)
        XCTAssertEqual(view.camera, camera)
        XCTAssertEqual(view.selected, selected)
        XCTAssertTrue(recorder.choices.isEmpty)
        XCTAssertEqual(recorder.lands, 0)
        XCTAssertEqual(recorder.cancels, 0)
        XCTAssertTrue(recorder.drops.isEmpty)
        XCTAssertNotNil(find("SpaceCanvas.draggedWindow", in: try XCTUnwrap(view.layer)))

        view.handleKey(53, pressed: true, repeated: false)
        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: try XCTUnwrap(view.layer)))
        XCTAssertEqual(recorder.cancels, 0)
    }

    func testFailedMoveRestoresSourceAndAppliesDeferredInventory() throws {
        let recorder = Recorder()
        let other = window(202, rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))
        let view = canvas(cards: cards(destination: [other]), recorder: recorder)
        let root = try XCTUnwrap(view.layer)
        let changed = window(202, rect: CGRect(x: 0.55, y: 0.55, width: 0.25, height: 0.25))
        let camera = view.camera
        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.4, y: 0.4), in: 1, view: view))
        _ = view.refresh(cards: cards(destination: [changed]))
        assertRect(try normalizedFrame(202, space: 20, in: root), other.rect)
        XCTAssertNotNil(find("SpaceCanvas.draggedWindow", in: root))
        recorder.finish(.failure(TestFailure.rejected))
        flushMainQueue()

        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
        XCTAssertFalse(concealed(try zone(101, in: root)))
        assertRect(try normalizedFrame(101, space: 10, in: root), window(101).rect)
        assertRect(try normalizedFrame(202, space: 20, in: root), changed.rect)
        XCTAssertEqual(view.camera, camera)
        XCTAssertEqual(recorder.lands, 0)
    }

    func testFailedMoveStatusSurvivesInventoryRefreshUntilAnotherMoveCompletes() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let root = try XCTUnwrap(view.layer)
        let title = try XCTUnwrap(find("SpaceCanvas.title", in: root) as? CATextLayer)
        let originalTitle = title.string as? String
        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.5, y: 0.5), in: 1, view: view))
        recorder.finish(.failure(TestFailure.rejected))
        flushMainQueue()
        let message = TestFailure.rejected.localizedDescription
        XCTAssertEqual(title.string as? String, message)

        let discovered = window(202, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertTrue(view.refresh(cards: cards(destination: [discovered])))
        assertRect(try normalizedFrame(202, space: 20, in: root), discovered.rect)
        XCTAssertEqual(title.string as? String, message,
                       "A changed inventory must not erase the explanation of a failed move")

        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.45, y: 0.45), in: 0, view: view))
        XCTAssertEqual(title.string as? String, "Moving Editor…")
        recorder.finish(.success(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))
        flushMainQueue()
        XCTAssertEqual(title.string as? String, originalTitle,
                       "A later success clears the error and restores the current monitor identity")
    }

    func testSuccessReconcilesMoveAfterAnInventoryCapturedBeforeTheDrop() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let root = try XCTUnwrap(view.layer)
        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.5, y: 0.5), in: 1, view: view))
        let discovered = window(202, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        _ = view.refresh(cards: cards(destination: [discovered]))
        XCTAssertNil(find("SpaceCanvas.photo.202", in: root))
        let actual = CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3)
        recorder.finish(.success(actual))
        flushMainQueue()

        let source = try XCTUnwrap(find("SpaceCanvas.windows.10", in: root))
        XCTAssertNil(find("SpaceCanvas.photo.101", in: source), "A stale deferred inventory must not undo the confirmed move")
        assertRect(try normalizedFrame(101, space: 20, in: root), actual)
        assertRect(try normalizedFrame(202, space: 20, in: root), discovered.rect)
    }

    func testBackgroundPansWhileUnknownWindowsAndMissingHandlerNeverFakeAMove() throws {
        let recorder = Recorder()
        let view = canvas(recorder: recorder)
        let camera = view.camera
        let background = point(CGPoint(x: 0.8, y: 0.8), in: 0, view: view)
        drag(view, from: background, to: CGPoint(x: background.x + 70, y: background.y - 30))
        XCTAssertNotEqual(view.camera.center, camera.center)
        XCTAssertEqual(view.camera.scale, camera.scale)
        XCTAssertTrue(recorder.drops.isEmpty)

        for enabled in [false, true] {
            let recorder = Recorder()
            let id: UInt32 = enabled ? 0 : 101
            let view = canvas(cards: cards(source: [window(id)]), recorder: recorder, movingEnabled: enabled)
            let root = try XCTUnwrap(view.layer)
            drag(view,
                 from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
                 to: point(CGPoint(x: 0.5, y: 0.5), in: 1, view: view))
            XCTAssertTrue(recorder.drops.isEmpty)
            XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
            if id != 0 {
                XCTAssertFalse(concealed(try zone(id, in: root)))
                assertRect(try normalizedFrame(id, space: 10, in: root), window(id).rect)
            }
        }
    }

    func testUnknownFrontmostWindowOccludesMovableWindowBehindIt() throws {
        let recorder = Recorder()
        let view = canvas(cards: cards(source: [window(101), window(0)]), recorder: recorder)
        let root = try XCTUnwrap(view.layer)
        drag(view,
             from: point(CGPoint(x: 0.3, y: 0.3), in: 0, view: view),
             to: point(CGPoint(x: 0.5, y: 0.5), in: 1, view: view))
        XCTAssertTrue(recorder.drops.isEmpty, "A nonmovable foreground window must not expose a hidden drag target")
        XCTAssertNil(find("SpaceCanvas.draggedWindow", in: root))
        XCTAssertFalse(concealed(try zone(101, in: root)))
        assertRect(try normalizedFrame(101, space: 10, in: root), window(101).rect)
    }

    private enum TestFailure: Error { case rejected }

    private final class Recorder {
        var drops: [SpaceCanvasWindowDrop] = []
        var pending: ((Result<CGRect, Error>) -> Void)?
        var choices: [Int] = []
        var lands = 0
        var cancels = 0

        func finish(_ result: Result<CGRect, Error>, file: StaticString = #filePath, line: UInt = #line) {
            guard let completion = pending else { return XCTFail("No pending window move", file: file, line: line) }
            pending = nil
            completion(result)
        }
    }

    private func canvas(cards models: [SpaceFilmstripCard]? = nil, recorder: Recorder,
                        movingEnabled: Bool = true) -> SpaceCanvasView {
        _ = NSApplication.shared
        var handlers = SpaceCanvasView.Handlers(choose: { recorder.choices.append($0) },
            land: { recorder.lands += 1 }, cancel: { recorder.cancels += 1 })
        if movingEnabled {
            handlers.moveWindow = { drop, completion in
                recorder.drops.append(drop)
                recorder.pending = completion
            }
        }
        let view = SpaceCanvasView(cards: models ?? cards(), selected: 0, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2, handlers: handlers)
        view.showOverview(reduceMotion: true)
        return view
    }

    private func cards(source: [SpaceFilmstripWindow]? = nil, destination: [SpaceFilmstripWindow] = []) -> [SpaceFilmstripCard] {
        let windows = source ?? [window(101)]
        return [
            .init(id: 10, number: 1, windows: Array(windows.suffix(1)), canvasWindows: windows),
            .init(id: 20, number: 2, windows: destination),
            .init(id: 30, number: 3, windows: []),
            .init(id: 40, number: 4, windows: [])
        ]
    }

    private func window(_ id: UInt32, rect: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)) -> SpaceFilmstripWindow {
        .init(rect: rect, app: "Editor", pid: 123, title: "Document \(id)", wid: id)
    }

    private func point(_ normalized: CGPoint, in index: Int, view: SpaceCanvasView) -> CGPoint {
        let cell = view.layout.view(view.layout.cell(index), camera: view.camera)
        return CGPoint(x: cell.minX + normalized.x * cell.width, y: cell.minY + normalized.y * cell.height)
    }

    private func drag(_ view: SpaceCanvasView, from start: CGPoint, to end: CGPoint) {
        view.beginPointer(at: start)
        view.dragPointer(to: end)
        view.endPointer(at: end)
    }

    private func find(_ name: String, in layer: CALayer) -> CALayer? {
        if layer.name == name { return layer }
        return layer.sublayers?.lazy.compactMap { self.find(name, in: $0) }.first
    }

    private func zone(_ id: UInt32, in root: CALayer) throws -> CALayer {
        try XCTUnwrap(find("SpaceCanvas.photo.\(id)", in: root)?.superlayer)
    }

    private func concealed(_ layer: CALayer) -> Bool { layer.isHidden || layer.opacity == 0 }

    private func normalizedFrame(_ id: UInt32, space: Int, in root: CALayer) throws -> CGRect {
        let container = try XCTUnwrap(find("SpaceCanvas.windows.\(space)", in: root))
        let frame = try zone(id, in: container).frame
        return CGRect(x: frame.minX / container.bounds.width, y: frame.minY / container.bounds.height,
                      width: frame.width / container.bounds.width, height: frame.height / container.bounds.height)
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6, file: file, line: line)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        assertPoint(actual.origin, expected.origin, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-6, file: file, line: line)
    }

    private func flushMainQueue() {
        let drained = expectation(description: "Window move completion applied")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
