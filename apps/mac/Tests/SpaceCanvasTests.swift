import XCTest
@testable import Lattices

final class SpaceCanvasTests: XCTestCase {
    func testClosingWaitsForAnimationCompletionThroughPausedClock() throws {
        _ = NSApplication.shared
        for completed in [false, true] {
            let view = SpaceCanvasView(cards: [.init(id: 1, number: 1, windows: [])], selected: 0, current: 0,
                room: CGSize(width: 1440, height: 900), scale: 2,
                handlers: .init(choose: { _ in }, land: {}, cancel: {}))
            let root = try XCTUnwrap(view.layer)
            let now = CACurrentMediaTime()
            let clock = SpaceOverlayAnimationClock(layer: root, now: now)
            var removals = 0
            view.dissolve(reduceMotion: false) { removals += 1 }
            let fade = try XCTUnwrap(root.animation(forKey: "opacity"))
            XCTAssertNotNil(fade.delegate)
            XCTAssertEqual(root.convertTime(now + 1, from: nil), now, accuracy: 0.001)
            XCTAssertEqual(removals, 0)
            clock.resume(now: now + 1)
            fade.delegate?.animationDidStop?(fade, finished: completed)
            XCTAssertEqual(removals, completed ? 1 : 0)
        }
    }

    func testLandingRevealWaitsForDelayedZonesAndShade() throws {
        _ = NSApplication.shared
        let view = SpaceCanvasView(cards: [.init(id: 1, number: 1, windows: [])], selected: 0, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        let root = try XCTUnwrap(view.layer)
        var removals = 0
        view.reveal(reduceMotion: false) { removals += 1 }
        let shade = try XCTUnwrap(namedLayer("SpaceCanvas.shade", in: root).animation(forKey: "backgroundColor"))
        let zones = try XCTUnwrap(namedLayer("SpaceCanvas.windows.1", in: root).animation(forKey: "opacity"))
        XCTAssertGreaterThan(zones.beginTime, 0)
        XCTAssertEqual(zones.fillMode, .backwards)
        XCTAssertNotNil(zones.delegate)
        shade.delegate?.animationDidStop?(shade, finished: true)
        XCTAssertEqual(removals, 0, "The zones still cover the real desktop")
        zones.delegate?.animationDidStop?(zones, finished: true)
        XCTAssertEqual(removals, 1)
    }

    func testStripFadeCompletionRejectsInterruptedDismissal() throws {
        _ = NSApplication.shared
        let view = NSView(); view.wantsLayer = true
        var removals = 0
        SpaceSwitchBezel.fade(view, to: 0, duration: 0.12) { removals += 1 }
        let fade = try XCTUnwrap(view.layer?.animation(forKey: "visibility"))
        fade.delegate?.animationDidStop?(fade, finished: false)
        fade.delegate?.animationDidStop?(fade, finished: true)
        XCTAssertEqual(removals, 0)
    }

    func testStripHandoffWaitsForCanvasFadeAndRejectsInterruptedEntrance() throws {
        _ = NSApplication.shared
        for completed in [false, true] {
            let view = SpaceCanvasView(cards: [.init(id: 1, number: 1, windows: [])], selected: 0, current: 0,
                room: CGSize(width: 1440, height: 900), scale: 2,
                handlers: .init(choose: { _ in }, land: {}, cancel: {}))
            let root = try XCTUnwrap(view.layer)
            let began = CACurrentMediaTime()
            let clock = SpaceOverlayAnimationClock(layer: root, now: began)
            var transfers = 0
            view.open(from: nil, reduceMotion: false) { transfers += 1 }
            let entrance = try XCTUnwrap(root.animation(forKey: "opacity"))
            XCTAssertNotNil(entrance.delegate)
            XCTAssertEqual(root.convertTime(began + 0.5, from: nil), began, accuracy: 0.001)
            XCTAssertEqual(transfers, 0, "Window ordering and a freeze must not expire the strip handoff")
            clock.resume(now: began + 0.5)
            entrance.delegate?.animationDidStop?(entrance, finished: completed)
            XCTAssertEqual(transfers, completed ? 1 : 0)
            entrance.delegate?.animationDidStop?(entrance, finished: true)
            XCTAssertEqual(transfers, completed ? 1 : 0, "An interrupted or completed entrance can never transfer twice")
        }
    }

    func testInventoryRefreshRepairsEmptyPreviewDuringOpeningAndZoomWithoutRestartingMotion() throws {
        _ = NSApplication.shared
        let empty = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        var fresh = empty
        fresh[0] = SpaceFilmstripCard(id: 1, number: 1, windows: [
            SpaceFilmstripWindow(rect: CGRect(x: 0.05, y: 0.1, width: 0.55, height: 0.8), app: "Editor"),
            SpaceFilmstripWindow(rect: CGRect(x: 0.5, y: 0.2, width: 0.45, height: 0.65), app: "Terminal")
        ])
        for zooming in [false, true] {
            let view = SpaceCanvasView(cards: empty, selected: 7, current: 0,
                room: CGSize(width: 1440, height: 900), scale: 2,
                handlers: .init(choose: { _ in XCTFail("Refresh must not choose") },
                                land: { XCTFail("Refresh must not land") }, cancel: {}))
            view.open(from: CGRect(x: 636, y: 394, width: 168, height: 105), reduceMotion: false)
            if zooming { view.zoom(out: false) }
            let root = try XCTUnwrap(view.layer)
            let plane = try namedLayer("SpaceCanvas.plane", in: root)
            let minimap = try namedLayer("SpaceCanvas.minimap", in: root)
            let header = try namedLayer("SpaceCanvas.header", in: root)
            let container = try namedLayer("SpaceCanvas.windows.1", in: root)
            let unchanged = try namedLayer("SpaceCanvas.windows.2", in: root)
            let unchangedEmpty = try XCTUnwrap(unchanged.sublayers?.first)
            let title = try XCTUnwrap(namedLayer("SpaceCanvas.title", in: root) as? CATextLayer)
            let zones = try XCTUnwrap(namedLayer("SpaceCanvas.minimapZones", in: root) as? CAShapeLayer)
            let camera = view.camera
            let rootLayers = root.sublayers ?? []
            let planeLayers = plane.sublayers ?? []
            let miniLayers = minimap.sublayers ?? []
            let motions = [root, plane, minimap, header].map { layer -> (CALayer, [String: CAAnimation]) in
                let sentinel = CABasicAnimation(keyPath: "opacity")
                sentinel.fromValue = 0.5
                sentinel.toValue = 1
                sentinel.beginTime = CACurrentMediaTime() + 1
                sentinel.duration = 5
                layer.add(sentinel, forKey: "refresh-preservation")
                return (layer, Dictionary(uniqueKeysWithValues: (layer.animationKeys() ?? []).compactMap { key in
                    layer.animation(forKey: key).map { (key, $0) }
                }))
            }
            XCTAssertNotNil(plane.animation(forKey: "transform"))
            XCTAssertNotNil(minimap.animation(forKey: "opacity"))
            XCTAssertNotNil(root.animation(forKey: "opacity"))
            XCTAssertNotNil(header.animation(forKey: "opacity"))
            XCTAssertTrue(zones.path?.isEmpty == true)

            for _ in 0..<3 {
                XCTAssertTrue(view.refresh(cards: fresh))
                XCTAssertEqual(container.sublayers?.count, 2)
                XCTAssertTrue(container.sublayers?.allSatisfy { $0.name == "SpaceCanvas.window" } == true)
                XCTAssertEqual(title.string as? String, "16 desktops · 15 empty")
                XCTAssertFalse(try XCTUnwrap(zones.path).isEmpty)
                let previews = container.sublayers ?? []
                XCTAssertFalse(view.refresh(cards: fresh), "An identical poll must be a no-op")
                XCTAssertEqual(container.sublayers?.map(ObjectIdentifier.init), previews.map(ObjectIdentifier.init))

                XCTAssertTrue(view.refresh(cards: empty), "A genuinely emptied desktop must also update")
                XCTAssertEqual(container.sublayers?.count, 1)
                XCTAssertEqual(container.sublayers?.first?.name, "SpaceCanvas.empty")
                XCTAssertEqual(title.string as? String, "16 desktops · 16 empty")
                XCTAssertTrue(zones.path?.isEmpty == true)
            }
            XCTAssertEqual(view.camera, camera)
            XCTAssertEqual(view.selected, 7)
            XCTAssertTrue(unchanged.sublayers?.first === unchangedEmpty)
            XCTAssertEqual(root.sublayers?.map(ObjectIdentifier.init), rootLayers.map(ObjectIdentifier.init))
            XCTAssertEqual(plane.sublayers?.map(ObjectIdentifier.init), planeLayers.map(ObjectIdentifier.init))
            XCTAssertEqual(minimap.sublayers?.map(ObjectIdentifier.init), miniLayers.map(ObjectIdentifier.init))
            for (layer, animations) in motions {
                XCTAssertEqual(Set(layer.animationKeys() ?? []), Set(animations.keys))
                for (key, before) in animations {
                    let after = try XCTUnwrap(layer.animation(forKey: key))
                    XCTAssertEqual(after.beginTime, before.beginTime)
                    XCTAssertEqual(after.duration, before.duration)
                    if let before = before as? CABasicAnimation, let after = after as? CABasicAnimation {
                        XCTAssertEqual(after.keyPath, before.keyPath)
                        XCTAssertEqual(after.fromValue as? NSValue, before.fromValue as? NSValue)
                        XCTAssertEqual(after.toValue as? NSValue, before.toValue as? NSValue)
                    }
                }
            }
        }
    }

    func testInventoryRefreshRejectsChangedDesktopTopology() throws {
        let cards = [SpaceFilmstripCard(id: 11, number: 1, windows: []),
                     SpaceFilmstripCard(id: 12, number: 3, windows: [])]
        let view = SpaceCanvasView(cards: cards, selected: 1, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        let root = try XCTUnwrap(view.layer)
        let container = try namedLayer("SpaceCanvas.windows.11", in: root)
        let empty = try XCTUnwrap(container.sublayers?.first)
        let camera = view.camera
        XCTAssertFalse(view.refresh(cards: Array(cards.reversed())))
        XCTAssertFalse(view.refresh(cards: Array(cards.prefix(1))))
        XCTAssertFalse(view.refresh(cards: [SpaceFilmstripCard(id: 11, number: 2, windows: []), cards[1]]))
        XCTAssertTrue(container.sublayers?.first === empty)
        XCTAssertEqual(view.selected, 1)
        XCTAssertEqual(view.camera, camera)
    }

    private func namedLayer(_ name: String, in root: CALayer) throws -> CALayer {
        func find(_ layer: CALayer) -> CALayer? {
            if layer.name == name { return layer }
            return layer.sublayers?.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root), "Missing layer \(name)")
    }

    func testPointerHighlightThenUpZoomsTowardThatDesktopWithoutLanding() throws {
        _ = NSApplication.shared
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        for target in [3, 6, 15] {
            var choices: [Int] = []
            var landed = 0
            let view = SpaceCanvasView(cards: cards, selected: 0, current: 0,
                room: CGSize(width: 1440, height: 900), scale: 2,
                handlers: .init(choose: { choices.append($0) }, land: { landed += 1 }, cancel: {}))
            let opening = view.camera
            let cell = view.layout.view(view.layout.cell(target), camera: opening)
            view.highlight(at: CGPoint(x: cell.midX, y: cell.midY))
            XCTAssertEqual(view.selected, target)
            XCTAssertEqual(choices, [target])
            XCTAssertEqual(view.camera, opening, "Hovering must never pan or zoom")
            let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
            view.keyDown(with: up)
            XCTAssertGreaterThan(view.camera.scale, opening.scale)
            XCTAssertEqual(view.selected, target, "Up changes distance, not grid row")
            let targetCell = view.layout.cell(target)
            let expected = view.layout.clamped(SpaceCanvasCamera(
                center: CGPoint(x: targetCell.midX, y: targetCell.midY), scale: opening.scale * 1.4))
            XCTAssertEqual(view.camera, expected)
            XCTAssertEqual(landed, 0)
            let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
            view.keyDown(with: down)
            XCTAssertEqual(view.camera.scale, opening.scale, accuracy: 0.001)
            XCTAssertEqual(view.selected, target)
        }
    }

    func testHoverIgnoresHeaderAndMinimapAndKeyboardSelectionWinsUntilPointerMoves() {
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 6, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2,
            handlers: .init(choose: { _ in XCTFail("Chrome must not choose a desktop") }, land: {}, cancel: {}))
        view.highlight(at: CGPoint(x: 100, y: 20))
        let map = view.layout.minimap
        view.highlight(at: CGPoint(x: map.midX, y: map.midY))
        XCTAssertEqual(view.selected, 6)
        view.select(7, animated: false)
        view.zoom(out: false, reduceMotion: true)
        XCTAssertEqual(view.selected, 7)
        XCTAssertGreaterThan(view.camera.center.x, view.layout.world.width / 2)
    }

    func testCanvasMatchesApertureAndHitTestsEveryDesktop() {
        for count in [1, 2, 5, 16, 18] {
            let layout = SpaceCanvasLayout(count: count, room: CGSize(width: 1440, height: 900))
            let aperture = CGRect(x: 600, y: 360, width: 200, height: CGFloat(layout.rows) / 1.6 / CGFloat(layout.columns) * 200)
            let camera = layout.camera(fitting: aperture)
            let world = CGRect(origin: .zero, size: layout.world)
            let projected = layout.view(world, camera: camera)
            XCTAssertEqual(projected.minX, aperture.minX, accuracy: 0.001)
            XCTAssertEqual(projected.minY, aperture.minY, accuracy: 0.001)
            XCTAssertEqual(projected.width, aperture.width, accuracy: 0.001)
            XCTAssertEqual(projected.height, aperture.height, accuracy: 0.001)
            for index in 0..<count {
                let frame = layout.view(layout.cell(index), camera: camera)
                XCTAssertEqual(layout.index(at: CGPoint(x: frame.midX, y: frame.midY), camera: camera), index)
            }
        }
    }

    func testCanvasSelectionUsesSpaceIdentityAcrossFullscreenGaps() throws {
        var selection = try XCTUnwrap(SpaceSwitchSelection(ordered: [11, 90, 12, 91, 13], current: 11))
        selection.hold()
        selection.choose(13)
        XCTAssertEqual(selection.index, 4)
        XCTAssertTrue(selection.scrubbing)
        selection.choose(1000)
        XCTAssertEqual(selection.target, 13)
        selection.release()
        XCTAssertFalse(selection.scrubbing)
    }

    func testCanvasEdgesAndShortLastRowStayInBounds() {
        let layout = SpaceCanvasLayout(count: 18, room: CGSize(width: 1440, height: 900))
        XCTAssertEqual(layout.neighbour(of: 17, dx: 1, dy: 0), 17)
        XCTAssertEqual(layout.neighbour(of: 0, dx: -1, dy: 0), 0)
        XCTAssertEqual(layout.neighbour(of: 14, dx: 0, dy: 1), 17)
        for index in 0..<18 {
            let camera = layout.opening(on: index)
            let cell = layout.view(layout.cell(index), camera: camera)
            XCTAssertTrue(layout.stage.intersects(cell))
            let map = CGRect(x: 10, y: 10, width: 160, height: 100)
            XCTAssertFalse(layout.viewport(camera: camera, map: map).isNull)
        }
    }

    func testCanvasOpensWithEveryDesktopVisibleAndZoomNeverLands() {
        for count in [1, 5, 16, 18] {
            let cards = (1...count).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
            var landed = 0
            let view = SpaceCanvasView(cards: cards, selected: count - 1, current: 0,
                room: CGSize(width: 1440, height: 900), scale: 2,
                handlers: .init(choose: { _ in }, land: { landed += 1 }, cancel: {}))
            XCTAssertEqual(view.camera.scale, view.layout.fitScale)
            for index in 0..<count {
                XCTAssertTrue(view.layout.stage.insetBy(dx: -0.001, dy: -0.001)
                    .contains(view.layout.view(view.layout.cell(index), camera: view.camera)))
            }
            for _ in 0..<20 { XCTAssertTrue(view.zoom(out: false, reduceMotion: true)) }
            XCTAssertEqual(view.camera.scale, view.layout.maxScale, accuracy: 0.001)
            for _ in 0..<20 { XCTAssertTrue(view.zoom(out: true, reduceMotion: true)) }
            XCTAssertEqual(view.camera.scale, view.layout.fitScale, accuracy: 0.001)
            XCTAssertEqual(landed, 0, "Zooming, including at either limit, cannot commit a desktop")
        }
    }

    private func zoomFixture() -> SpaceCanvasView {
        _ = NSApplication.shared
        return SpaceCanvasView(cards: (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) },
            selected: 5, current: 0, room: CGSize(width: 1440, height: 900), scale: 2,
            handlers: .init(choose: { _ in XCTFail("Zoom must preserve selection") },
                            land: { XCTFail("Zoom must not land") }, cancel: { XCTFail("A hold must not exit") }))
    }

    func testZoomTapKeepsOnePreciseStepAndHeldKeyNeedsNoRepeat() {
        let view = zoomFixture()
        view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
        let tapped = view.camera
        XCTAssertEqual(tapped.scale, view.layout.fitScale * 1.4, accuracy: 1e-9)
        view.advanceKeyboardZoom(to: 0.08)
        view.zoomKey(126, pressed: false, time: 0.08)
        for frame in 1...60 { view.advanceKeyboardZoom(to: 0.08 + Double(frame) / 60) }
        XCTAssertEqual(view.camera, tapped)

        view.zoomKey(126, pressed: true, reduceMotion: true, time: 2)
        for frame in 1...90 { view.advanceKeyboardZoom(to: 2 + Double(frame) / 60) }
        XCTAssertEqual(view.camera, view.layout.filling(5))
        XCTAssertTrue(view.locked)
        view.zoomKey(126, pressed: false, time: 3.5)
        view.zoomKey(125, pressed: true, reduceMotion: true, time: 4)
        for frame in 1...120 { view.advanceKeyboardZoom(to: 4 + Double(frame) / 60) }
        XCTAssertEqual(view.camera, view.layout.opening(on: 5))
        XCTAssertTrue(view.atMinimum)
        XCTAssertFalse(view.locked)
    }

    func testReleasingHeldZoomBrakesAndThenStaysPut() {
        let view = zoomFixture()
        view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
        for frame in 1...21 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
        let released = view.camera
        view.zoomKey(126, pressed: false, time: 0.35)
        for frame in 1...18 { view.advanceKeyboardZoom(to: 0.35 + Double(frame) / 60) }
        let stopped = view.camera
        XCTAssertGreaterThan(stopped.scale, released.scale)
        XCTAssertLessThan(stopped.scale / released.scale, 1.1, "The brake must be short and bounded")
        XCTAssertFalse(view.locked)
        for frame in 1...60 { view.advanceKeyboardZoom(to: 0.65 + Double(frame) / 60) }
        XCTAssertEqual(view.camera, stopped)
    }

    func testReversalNearFullScaleDoesNotLatchTheWrongDirectionAtTheBoundary() {
        let view = zoomFixture()
        view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
        var time = 0.0
        while view.camera.scale < view.layout.maxScale * 0.96 && time < 2 {
            time += 1.0 / 120
            view.advanceKeyboardZoom(to: time)
        }
        XCTAssertFalse(view.locked)
        view.zoomKey(125, pressed: true, reduceMotion: true, time: time)
        for frame in 1...120 { view.advanceKeyboardZoom(to: time + Double(frame) / 120) }
        XCTAssertLessThan(view.camera.scale, view.layout.maxScale / 2)
        XCTAssertFalse(view.locked, "Coasting into full size must not suppress the held Down direction")
    }

    func testOpeningHoldWaitsForEntryAndClosingCancelsTheDrive() {
        for landing in [false, true] {
            let view = zoomFixture()
            let opening = view.camera
            view.zoomKey(126, pressed: true, opening: true, reduceMotion: true, time: 0)
            for frame in 1...17 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
            XCTAssertEqual(view.camera, opening, "The opening key must not reverse the map entrance")
            for frame in 18...30 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
            XCTAssertGreaterThan(view.camera.scale, opening.scale)
            if landing { view.land(reduceMotion: true, arrived: {}) }
            else { view.dissolve(reduceMotion: true) }
            let closed = view.camera
            for frame in 31...120 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
            XCTAssertEqual(view.camera, closed, "An old held tick must not overwrite closing motion")
        }
    }

    func testFitCommandCancelsHeldMotion() throws {
        let view = zoomFixture()
        view.zoomKey(126, pressed: true, reduceMotion: true, time: 0)
        for frame in 1...24 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
        view.keyDown(with: try key(29))
        let fitted = view.camera
        XCTAssertEqual(fitted.scale, view.layout.fitScale)
        for frame in 25...120 { view.advanceKeyboardZoom(to: Double(frame) / 60) }
        XCTAssertEqual(view.camera, fitted)
    }

    func testHeldCameraDistanceFollowsTheGlidePathAndStopsAtExactEndpoints() {
        let layout = SpaceCanvasLayout(count: 16, room: CGSize(width: 1440, height: 900))
        let opening = layout.opening(on: 15)
        let full = layout.filling(15)
        let delta = log(full.scale / opening.scale) / 20
        var camera = opening
        let expected = SpaceCanvasCamera.path(from: opening, to: full, steps: 20)
        for index in 1...20 {
            camera = camera.advanced(toward: full, logarithmicDelta: delta)
            XCTAssertEqual(camera.scale, expected[index].scale, accuracy: 1e-9)
            XCTAssertEqual(camera.center.x, expected[index].center.x, accuracy: 1e-9)
            XCTAssertEqual(camera.center.y, expected[index].center.y, accuracy: 1e-9)
        }
        XCTAssertEqual(camera.advanced(toward: full, logarithmicDelta: 1), full)
        XCTAssertEqual(full.advanced(toward: opening, logarithmicDelta: -10), opening)
    }

    // MARK: Endpoints and transitions

    private static let rooms = [CGSize(width: 1920, height: 1080), CGSize(width: 3440, height: 1440),
                                CGSize(width: 1440, height: 900), CGSize(width: 1512, height: 982),
                                CGSize(width: 2560, height: 1600), CGSize(width: 1080, height: 1920),
                                CGSize(width: 1024, height: 768)]

    private func key(_ code: UInt16, up: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    private func animations(in root: CALayer) -> [String: CAAnimation] {
        var found: [String: CAAnimation] = [:]
        func walk(_ layer: CALayer, _ path: String) {
            for key in layer.animationKeys() ?? [] { found["\(path)/\(key)"] = layer.animation(forKey: key) }
            for (i, child) in (layer.sublayers ?? []).enumerated() { walk(child, "\(path).\(i)") }
            if let mask = layer.mask { walk(mask, "\(path).mask") }
        }
        walk(root, "root")
        return found
    }

    func testFilledDesktopIsExactlyTheDisplayAtEveryAspectAndIndex() {
        for room in Self.rooms {
            let bounds = CGRect(origin: .zero, size: room)
            for count in [1, 2, 3, 5, 9, 16, 18] {
                let layout = SpaceCanvasLayout(count: count, room: room)
                XCTAssertEqual(layout.aspect, room.width / room.height, accuracy: 1e-9)
                XCTAssertEqual(layout.stage.midX, bounds.midX, accuracy: 1e-9)
                XCTAssertEqual(layout.stage.midY, bounds.midY, accuracy: 1e-9)
                for index in 0..<count {
                    let fill = layout.filling(index)
                    XCTAssertEqual(fill.scale, layout.maxScale, accuracy: 1e-9)
                    let frame = layout.view(layout.cell(index), camera: fill)
                    XCTAssertEqual(frame.minX, 0, accuracy: 1e-6, "\(room) \(count) \(index)")
                    XCTAssertEqual(frame.minY, 0, accuracy: 1e-6, "\(room) \(count) \(index)")
                    XCTAssertEqual(frame.width, room.width, accuracy: 1e-6, "\(room) \(count) \(index)")
                    XCTAssertEqual(frame.height, room.height, accuracy: 1e-6, "\(room) \(count) \(index)")
                    XCTAssertEqual(layout.nearest(to: fill.center), index)
                    XCTAssertEqual(layout.index(at: CGPoint(x: bounds.midX, y: bounds.midY), camera: fill), index)
                    XCTAssertTrue(layout.locks(fill.scale))
                }
            }
        }
    }

    func testEntryPlacesTheSelectedDesktopExactlyOverTheStripCard() throws {
        _ = NSApplication.shared
        let card = CGRect(x: 876, y: 487, width: 168, height: 105)
        for room in Self.rooms {
            let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
            let view = SpaceCanvasView(cards: cards, selected: 9, current: 2, room: room, scale: 2,
                handlers: .init(choose: { _ in XCTFail("Opening must not choose") },
                                land: { XCTFail("Opening must not land") }, cancel: {}))
            let start = view.layout.camera(placing: 9, onto: card)
            let placed = view.layout.view(view.layout.cell(9), camera: start)
            XCTAssertEqual(placed.midX, card.midX, accuracy: 1e-6)
            XCTAssertEqual(placed.midY, card.midY, accuracy: 1e-6)
            XCTAssertTrue(card.insetBy(dx: -1e-6, dy: -1e-6).contains(placed))
            XCTAssertTrue(abs(placed.width - card.width) < 1e-6 || abs(placed.height - card.height) < 1e-6)
            view.open(from: card, reduceMotion: false)
            let plane = try namedLayer("SpaceCanvas.plane", in: try XCTUnwrap(view.layer))
            let entry = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
            let from = try XCTUnwrap(entry.values?.first as? NSValue).caTransform3DValue
            XCTAssertEqual(from.m11 * view.layout.openingScale, start.scale, accuracy: 1e-6)
            XCTAssertEqual(view.camera, view.layout.opening(on: 9), "One move, to the whole map")
        }
    }

    func testKeyboardZoomLocksTheSelectedDesktopAtTheFullDisplayAndNeverLands() throws {
        _ = NSApplication.shared
        for room in Self.rooms {
            let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
            var landed = 0
            var choices: [Int] = []
            let view = SpaceCanvasView(cards: cards, selected: 5, current: 0, room: room, scale: 2,
                handlers: .init(choose: { choices.append($0) }, land: { landed += 1 }, cancel: {}))
            for _ in 0..<20 { view.keyDown(with: try key(126)); view.keyUp(with: try key(126, up: true)) }
            XCTAssertEqual(view.camera, view.layout.filling(5), "\(room)")
            XCTAssertTrue(view.locked)
            XCTAssertEqual(choices, [])
            // Arrows at the full display move between full-display endpoints.
            view.keyDown(with: try key(124))
            XCTAssertEqual(choices, [6])
            view.select(6, animated: false)
            XCTAssertEqual(view.camera, view.layout.filling(6))
            view.keyDown(with: try key(125))
            view.keyUp(with: try key(125, up: true))
            XCTAssertFalse(view.locked)
            XCTAssertLessThan(view.camera.scale, view.layout.maxScale)
            for _ in 0..<20 { view.keyDown(with: try key(126)); view.keyUp(with: try key(126, up: true)) }
            XCTAssertEqual(view.camera, view.layout.filling(6))
            XCTAssertEqual(landed, 0, "Zoom, even at the full display, is still a preview")
        }
    }

    func testContinuousZoomIntoTheLimitLocksTheDesktopUnderTheCentre() {
        _ = NSApplication.shared
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        var choices: [Int] = []
        let view = SpaceCanvasView(cards: cards, selected: 0, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { choices.append($0) }, land: { XCTFail("Zoom must not land") }, cancel: {}))
        let target = view.layout.view(view.layout.cell(10), camera: view.camera)
        for _ in 0..<20 { view.zoom(out: false, about: CGPoint(x: target.midX, y: target.midY), reduceMotion: true) }
        XCTAssertEqual(view.selected, 10)
        XCTAssertEqual(choices.last, 10)
        XCTAssertEqual(view.camera, view.layout.filling(10))
    }

    func testHoldingEitherLimitDoesNoAnimationWork() throws {
        _ = NSApplication.shared
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 5, current: 0,
            room: CGSize(width: 1512, height: 982), scale: 2,
            handlers: .init(choose: { _ in }, land: { XCTFail("Zoom must not land") }, cancel: {}))
        let root = try XCTUnwrap(view.layer)
        let center = CGPoint(x: 756, y: 491)
        for _ in 0..<12 { view.zoom(out: false) }
        XCTAssertEqual(view.camera, view.layout.filling(5))
        let atFill = animations(in: root)
        XCTAssertFalse(atFill.isEmpty, "The last step is still gliding into place")
        for _ in 0..<5 {
            view.zoom(out: false)
            view.zoom(out: false, about: center)
            view.keyDown(with: try key(126))
        }
        let held = animations(in: root)
        XCTAssertEqual(Set(held.keys), Set(atFill.keys))
        for (key, animation) in atFill { XCTAssertTrue(held[key] === animation, "Replaced \(key) at the fill limit") }

        for _ in 0..<12 { view.zoom(out: true) }
        XCTAssertEqual(view.camera.scale, view.layout.fitScale, accuracy: 1e-9)
        let atFit = animations(in: root)
        for _ in 0..<5 { view.zoom(out: true); view.keyDown(with: try key(125)) }
        let heldFit = animations(in: root)
        XCTAssertEqual(Set(heldFit.keys), Set(atFit.keys))
        for (key, animation) in atFit { XCTAssertTrue(heldFit[key] === animation, "Replaced \(key) at the fit limit") }
    }

    func testDepartingCanvasRejectsLateHoverAndKeyboardSelection() {
        let cards = (1...18).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        for landing in [false, true] {
            let view = SpaceCanvasView(cards: cards, selected: 2, current: 0,
                room: CGSize(width: 3440, height: 1440), scale: 1,
                handlers: .init(choose: { _ in XCTFail("Departure must retain its committed desktop") },
                                land: { XCTFail("Late Enter") }, cancel: { XCTFail("Late Escape") }))
            let other = view.layout.view(view.layout.cell(12), camera: view.camera)
            view.zoomKey(126, pressed: true, time: 1)
            view.endInteraction()
            // Model events delivered by AppKit while panels are ordered out,
            // before the actual landing/dissolve animation is authored.
            view.highlight(at: CGPoint(x: other.midX, y: other.midY))
            for key: Int64 in [123, 124, 36, 53] {
                view.handleKey(key, pressed: true, repeated: false)
            }
            view.zoomKey(126, pressed: true, time: 2)
            view.advanceKeyboardZoom(to: 3)
            XCTAssertEqual(view.selected, 2)
            if landing {
                view.land(reduceMotion: true, arrived: {})
                XCTAssertEqual(view.camera, view.layout.filling(2))
            } else {
                view.dissolve(reduceMotion: true)
                XCTAssertEqual(view.camera, view.layout.filling(0))
            }
            XCTAssertFalse(view.zoom(out: false))
        }
    }

    func testLandingArrivesAtTheExactFillBeforeAnythingFades() throws {
        _ = NSApplication.shared
        let cards = (1...9).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        for reduceMotion in [false, true] {
            let view = SpaceCanvasView(cards: cards, selected: 4, current: 0,
                room: CGSize(width: 3440, height: 1440), scale: 2,
                handlers: .init(choose: { _ in }, land: {}, cancel: {}))
            let root = try XCTUnwrap(view.layer)
            let plane = try namedLayer("SpaceCanvas.plane", in: root)
            let arrived = expectation(description: "arrived")
            view.land(reduceMotion: reduceMotion) { arrived.fulfill() }
            XCTAssertEqual(view.camera, view.layout.filling(4))
            XCTAssertEqual(root.opacity, 1, "The canvas is the landing cover; its owner fades it after the switch")
            XCTAssertEqual(plane.opacity, 1)
            XCTAssertEqual(try namedLayer("SpaceCanvas.header", in: root).opacity, 0)
            if reduceMotion {
                XCTAssertNil(plane.animation(forKey: "transform"))
            } else {
                let landing = try XCTUnwrap(plane.animation(forKey: "transform"))
                XCTAssertNotNil(landing.delegate, "Arrival is reported by the camera, not a timer")
                landing.delegate?.animationDidStop?(landing, finished: true)
            }
            wait(for: [arrived], timeout: 1)
        }
    }

    func testEscapeReturnsIntoTheCurrentDesktopAndDissolves() throws {
        _ = NSApplication.shared
        let cards = (1...9).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 7, current: 2,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: { XCTFail("Escape must not land") }, cancel: {}))
        view.dissolve(reduceMotion: false)
        XCTAssertEqual(view.camera, view.layout.filling(2))
        XCTAssertEqual(view.selected, 7, "Escape leaves the selection alone; the navigator drops it")
        XCTAssertEqual(try XCTUnwrap(view.layer).opacity, 0)
    }

    func testCameraPathZoomsAtAConstantRatioAboutItsFixedPoint() {
        let stage = CGPoint(x: 860, y: 360)
        func screen(_ p: CGPoint, _ c: SpaceCanvasCamera) -> CGPoint {
            CGPoint(x: (p.x - c.center.x) * c.scale + stage.x, y: (p.y - c.center.y) * c.scale + stage.y)
        }
        let cases: [(SpaceCanvasCamera, SpaceCanvasCamera)] = [
            (SpaceCanvasCamera(center: CGPoint(x: 2, y: 1.2), scale: 400), SpaceCanvasCamera(center: CGPoint(x: 3.5, y: 0.5), scale: 1720)),
            (SpaceCanvasCamera(center: CGPoint(x: 3.5, y: 0.5), scale: 1720), SpaceCanvasCamera(center: CGPoint(x: 2, y: 1.2), scale: 400)),
            (SpaceCanvasCamera(center: CGPoint(x: 0.5, y: 0.2), scale: 300), SpaceCanvasCamera(center: CGPoint(x: 1.8, y: 0.9), scale: 420)),
        ]
        for (a, b) in cases {
            let path = SpaceCanvasCamera.path(from: a, to: b, steps: 24)
            XCTAssertEqual(path.count, 25)
            XCTAssertEqual(path.first, a)
            XCTAssertEqual(path.last, b)
            let fixed = CGPoint(x: (a.center.x * a.scale - b.center.x * b.scale) / (a.scale - b.scale),
                                y: (a.center.y * a.scale - b.center.y * b.scale) / (a.scale - b.scale))
            let anchor = screen(fixed, a)
            let ratio = path[1].scale / path[0].scale
            for (prev, next) in zip(path, path.dropFirst()) {
                XCTAssertEqual(next.scale / prev.scale, ratio, accuracy: 1e-9, "Equal steps are equal zoom")
            }
            for camera in path {
                let p = screen(fixed, camera)
                XCTAssertEqual(p.x, anchor.x, accuracy: 1e-6)
                XCTAssertEqual(p.y, anchor.y, accuracy: 1e-6)
            }
        }
        let pan = SpaceCanvasCamera.path(from: SpaceCanvasCamera(center: .zero, scale: 500),
                                         to: SpaceCanvasCamera(center: CGPoint(x: 2, y: 1), scale: 500), steps: 4)
        XCTAssertEqual(pan.map(\.center.x), [0, 0.5, 1, 1.5, 2])
        XCTAssertTrue(pan.allSatisfy { $0.scale == 500 })
    }

    func testCameraMovesTravelTheSampledPathFromWhatIsShown() throws {
        _ = NSApplication.shared
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 5, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        let card = CGRect(x: 880, y: 500, width: 160, height: 90)
        view.open(from: card, reduceMotion: false)
        let root = try XCTUnwrap(view.layer)
        let plane = try namedLayer("SpaceCanvas.plane", in: root)
        let entry = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        let values = try XCTUnwrap(entry.values as? [NSValue])
        XCTAssertEqual(values.count, SpaceCanvasView.pathSteps + 1)
        // Before anything is shown, the move starts over the strip's card.
        let start = view.layout.camera(placing: 5, onto: card)
        let first = values[0].caTransform3DValue
        XCTAssertEqual(first.m11 * view.layout.openingScale, start.scale, accuracy: 1e-6)
        XCTAssertEqual(values.last?.caTransform3DValue.m11 ?? 0, view.camera.scale / view.layout.openingScale, accuracy: 1e-9)
        XCTAssertEqual(entry.timingFunction, SpaceCanvasView.entryTiming, "One curve across the whole path")
    }

    func testLandingTurnsOpaqueBeforeItAuthorisesTheSwitch() throws {
        _ = NSApplication.shared
        let cards = (1...9).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 4, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        view.open(from: nil, reduceMotion: false)
        let root = try XCTUnwrap(view.layer)
        let shade = try namedLayer("SpaceCanvas.shade", in: root)
        var covered = 0
        view.land(reduceMotion: false, covered: { covered += 1 }, arrived: {})
        XCTAssertEqual(root.opacity, 1, "An Enter during the entry fade still covers fully")
        XCTAssertEqual(shade.backgroundColor?.alpha, 1)
        let cover = try XCTUnwrap(shade.animation(forKey: "backgroundColor"))
        XCTAssertEqual(cover.duration, SpaceCanvasView.coverDuration)
        cover.delegate?.animationDidStop?(cover, finished: false)
        XCTAssertEqual(covered, 0, "A replaced cover must not authorise an unfrozen switch")
        let again = expectation(description: "covered")
        view.land(reduceMotion: false, covered: { again.fulfill() }, arrived: {})
        let next = try XCTUnwrap(shade.animation(forKey: "backgroundColor"))
        let rootCover = try XCTUnwrap(root.animation(forKey: "opacity"))
        next.delegate?.animationDidStop?(next, finished: true)
        rootCover.delegate?.animationDidStop?(rootCover, finished: true)
        wait(for: [again], timeout: 1)
    }

    func testAlreadyOpaqueShadeStillWaitsForTheEntryFade() throws {
        _ = NSApplication.shared
        let cards = (1...4).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 1, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        view.open(from: nil, reduceMotion: false)
        let root = try XCTUnwrap(view.layer)
        let shade = try namedLayer("SpaceCanvas.shade", in: root)
        // The same starting state as Reduce Transparency, without changing
        // the user's system accessibility preference.
        shade.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        var covered = false
        let ready = expectation(description: "root and shade opaque")
        view.land(reduceMotion: false, covered: { covered = true; ready.fulfill() }, arrived: {})
        let rootCover = try XCTUnwrap(root.animation(forKey: "opacity"))
        XCTAssertNil(shade.animation(forKey: "backgroundColor"))
        DispatchQueue.main.async {
            XCTAssertFalse(covered, "An already opaque shade cannot bypass the root fade")
            rootCover.delegate?.animationDidStop?(rootCover, finished: true)
        }
        wait(for: [ready], timeout: 1)
    }

    func testRevealHandsTheSchematicOverToTheRealDesktopInTwoStages() throws {
        _ = NSApplication.shared
        let cards = (1...4).map { SpaceFilmstripCard(id: $0, number: $0, windows: [
            SpaceFilmstripWindow(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7), app: "Editor", title: "notes.md")]) }
        let view = SpaceCanvasView(cards: cards, selected: 1, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        view.land(reduceMotion: false, arrived: {})
        let total = view.reveal(reduceMotion: false)
        XCTAssertEqual(total, SpaceCanvasView.revealDuration + SpaceCanvasView.revealZoneDelay, accuracy: 1e-9)
        let root = try XCTUnwrap(view.layer)
        XCTAssertEqual(try namedLayer("SpaceCanvas.shade", in: root).backgroundColor?.alpha, 0)
        let zones = try namedLayer("SpaceCanvas.windows.2", in: root)
        XCTAssertEqual(zones.opacity, 0)
        let fade = try XCTUnwrap(zones.animation(forKey: "opacity"))
        XCTAssertGreaterThan(fade.beginTime, zones.convertTime(CACurrentMediaTime(), from: nil),
                             "Zones hold over the real windows for a beat")
        XCTAssertEqual(fade.fillMode, .backwards)
        XCTAssertEqual(view.reveal(reduceMotion: true), 0)
    }

    func testOnlyALockedDesktopPaysForSharpText() throws {
        _ = NSApplication.shared
        let cards = (1...9).map { SpaceFilmstripCard(id: $0, number: $0, windows: [
            SpaceFilmstripWindow(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7), app: "Editor", title: "notes.md")]) }
        let view = SpaceCanvasView(cards: cards, selected: 4, current: 0,
            room: CGSize(width: 3440, height: 1440), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        let root = try XCTUnwrap(view.layer)
        func textScales(_ name: String) throws -> [CGFloat] {
            var out: [CGFloat] = []
            var stack = [try namedLayer(name, in: root)]
            while let layer = stack.popLast() {
                if layer is CATextLayer { out.append(layer.contentsScale) }
                stack.append(contentsOf: layer.sublayers ?? [])
            }
            return out
        }
        XCTAssertTrue(try textScales("SpaceCanvas.windows.5").allSatisfy { $0 == 4 })
        for _ in 0..<12 { view.zoom(out: false) }
        let needed = 2 * view.layout.filling(4).scale / view.layout.openingScale
        XCTAssertGreaterThan(needed, 4)
        let sharp = try textScales("SpaceCanvas.windows.5")
        XCTAssertFalse(sharp.isEmpty)
        XCTAssertTrue(sharp.allSatisfy { abs($0 - needed) < 1e-9 })
        XCTAssertTrue(try textScales("SpaceCanvas.windows.1").allSatisfy { $0 == 4 }, "Other desktops keep the overview backing")
    }

    func testFreshDownAtTheMinimumIsTheOnlyExit() throws {
        _ = NSApplication.shared
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let view = SpaceCanvasView(cards: cards, selected: 5, current: 0,
            room: CGSize(width: 1920, height: 1080), scale: 2,
            handlers: .init(choose: { _ in }, land: {}, cancel: {}))
        view.zoom(out: false)
        XCTAssertFalse(view.atMinimum)
        while view.camera.scale > view.layout.fitScale * 1.0001 {
            XCTAssertFalse(view.atMinimum, "A press that reaches the minimum only zooms")
            view.zoom(out: true)
        }
        XCTAssertTrue(view.atMinimum)
        XCTAssertTrue(SpaceZoomKey.exitsAtMinimum(keyCode: 125))
        for code: Int64 in [126, 27, 24, 123, 124] { XCTAssertFalse(SpaceZoomKey.exitsAtMinimum(keyCode: code)) }
    }
}
