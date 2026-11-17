import XCTest
@testable import Lattices

final class SpaceCanvasVisualTests: XCTestCase {
    func testOverviewLeavesRoomAroundEqualDesktopTilesWithoutChangingTheirGeometry() {
        for room in rooms {
            for count in [1, 3, 16, 17] {
                let layout = SpaceCanvasLayout(count: count, room: room)
                let camera = layout.opening(on: count - 1)
                let atlas = layout.view(CGRect(origin: .zero, size: layout.world), camera: camera)
                XCTAssertGreaterThan(atlas.minX, layout.stage.minX)
                XCTAssertGreaterThan(atlas.minY, layout.stage.minY)
                XCTAssertLessThan(atlas.maxX, layout.stage.maxX)
                XCTAssertLessThan(atlas.maxY, layout.stage.maxY)
                let size = layout.view(layout.cell(0), camera: camera).size
                for index in 0..<count {
                    let tile = layout.view(layout.cell(index), camera: camera)
                    XCTAssertEqual(tile.width, size.width, accuracy: 1e-8)
                    XCTAssertEqual(tile.height, size.height, accuracy: 1e-8)
                    XCTAssertEqual(tile.width / tile.height, room.width / room.height, accuracy: 1e-8)
                    XCTAssertEqual(layout.index(at: CGPoint(x: tile.midX, y: tile.midY), camera: camera), index)
                }
                // Working room must not act like another desktop or the last short-row cell.
                XCTAssertNil(layout.index(at: CGPoint(x: atlas.minX - 1, y: atlas.midY), camera: camera))
                XCTAssertNil(layout.index(at: CGPoint(x: atlas.maxX + 1, y: atlas.midY), camera: camera))
            }
        }
    }

    func testOverviewPansFreelyAndFitRecoversTheWholeAtlas() {
        let layout = SpaceCanvasLayout(count: 16, room: CGSize(width: 1440, height: 900))
        let fit = layout.opening(on: 5)
        let left = layout.clamped(.init(center: CGPoint(x: -10_000, y: fit.center.y), scale: fit.scale))
        let right = layout.clamped(.init(center: CGPoint(x: 10_000, y: fit.center.y), scale: fit.scale))
        XCTAssertLessThan(left.center.x, fit.center.x, "The whole-map view must have room to pan")
        XCTAssertGreaterThan(right.center.x, fit.center.x)
        XCTAssertEqual(left.scale, fit.scale)
        XCTAssertEqual(right.scale, fit.scale)
        XCTAssertEqual(left.center.x, -10_000)
        XCTAssertEqual(right.center.x, 10_000)
        let vertical = layout.clamped(.init(center: CGPoint(x: fit.center.x, y: 10_000), scale: fit.scale))
        XCTAssertEqual(vertical.center.y, 10_000, "Both axes have the same freedom")
        XCTAssertEqual(layout.clamped(left), left)
        XCTAssertEqual(layout.clamped(right), right)
        XCTAssertEqual(layout.opening(on: 15), fit, "Fit must recover the same complete atlas")
    }

    func testDirectEntryStartsAtCurrentDesktopEvenWhenAnotherDesktopIsSelected() throws {
        for room in rooms {
            let view = canvas(room: room, selected: 12, current: 3)
            view.open(from: nil, reduceMotion: false)
            let plane = try layer("SpaceCanvas.plane", in: XCTUnwrap(view.layer))
            let entry = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
            let samples = try XCTUnwrap(entry.values as? [NSValue])
            let first = try XCTUnwrap(samples.first).caTransform3DValue
            let cell = view.layout.cell(3)
            let base = view.layout.openingScale
            let displayed = CGRect(x: cell.minX * base * first.m11 + first.m41,
                                   y: cell.minY * base * first.m22 + first.m42,
                                   width: cell.width * base * first.m11,
                                   height: cell.height * base * first.m22)
            XCTAssertEqual(displayed.minX, 0, accuracy: 1e-6)
            XCTAssertEqual(displayed.minY, 0, accuracy: 1e-6)
            XCTAssertEqual(displayed.width, room.width, accuracy: 1e-6)
            XCTAssertEqual(displayed.height, room.height, accuracy: 1e-6)
            XCTAssertEqual(view.camera, view.layout.here(on: 3))
            XCTAssertEqual(view.selected, 3, "The entry stays with the current screen")
            let scales = samples.map { $0.caTransform3DValue.m11 }
            XCTAssertTrue(zip(scales, scales.dropFirst()).allSatisfy { $0.0 >= $0.1 })
            XCTAssertEqual(entry.duration, SpaceCanvasView.entryDuration)
        }
    }

    func testReducedMotionDirectEntryImmediatelyShowsHere() throws {
        let view = canvas(selected: 12, current: 3)
        view.open(from: nil, reduceMotion: true)
        let plane = try layer("SpaceCanvas.plane", in: XCTUnwrap(view.layer))
        XCTAssertNil(plane.animation(forKey: "transform"))
        XCTAssertEqual(view.camera, view.layout.here(on: 3))
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func testDepartureStillMatchesCurrentTileAndReleasesWhenItsWindowLayoutChanges() throws {
        let view = canvas(selected: 12, current: 3)
        let image = try image()
        view.installDepartureStill(image)
        view.open(from: nil, reduceMotion: false)
        let root = try XCTUnwrap(view.layer)
        let still = try layer("SpaceCanvas.departureStill", in: root)
        let current = try layer("SpaceCanvas.windows.4", in: root)
        XCTAssertEqual(still.frame, current.frame)
        XCTAssertTrue(still.contents as AnyObject? === image)
        let camera = view.camera
        for visual in [false, true] {
            view.setVisual(visual)
            XCTAssertEqual(still.isHidden, !visual)
            XCTAssertEqual(still.opacity, 0, "The departure wallpaper must keep retiring in either appearance")
            XCTAssertTrue(still.contents as AnyObject? === image)
        }
        var cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        XCTAssertFalse(view.refresh(cards: cards))
        XCTAssertNotNil(still.superlayer)
        cards[3] = .init(id: 4, number: 4, windows: [
            .init(rect: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6), app: "Editor", wid: 99)
        ])
        XCTAssertTrue(view.refresh(cards: cards))
        XCTAssertNil(still.superlayer, "Changed positions must replace the captured desktop layout")
        XCTAssertEqual(view.camera, camera)
    }

    func testDepartureStillRetiresOnAnimationCompletionWithoutResurrectingAfterModeChanges() throws {
        let view = canvas(selected: 12, current: 3)
        view.installDepartureStill(try image())
        let root = try XCTUnwrap(view.layer)
        let still = try layer("SpaceCanvas.departureStill", in: root)
        let clock = SpaceOverlayAnimationClock(layer: root)
        view.open(from: nil, reduceMotion: false)
        let fade = try XCTUnwrap(still.animation(forKey: "opacity"))
        for visual in [false, true] {
            view.setVisual(visual)
            let after = try XCTUnwrap(still.animation(forKey: "opacity"))
            XCTAssertTrue(after.delegate === fade.delegate, "Mode changes must not cancel retirement")
            XCTAssertEqual(still.opacity, 0)
            XCTAssertNotNil(still.superlayer, "A paused entrance still owns its cover")
        }
        clock.resume()
        fade.delegate?.animationDidStop?(fade, finished: true)
        XCTAssertNil(still.superlayer)
        XCTAssertNil(still.contents, "Release the full-display capture after the handoff")
        view.installDepartureStill(try image())
        let plane = try layer("SpaceCanvas.plane", in: root)
        XCTAssertFalse(plane.sublayers?.contains { $0.name == "SpaceCanvas.departureStill" } == true)
    }

    func testReducedMotionDoesNotLeaveASecondWallpaperInsideTheCurrentTile() throws {
        let view = canvas(selected: 12, current: 3)
        view.installDepartureStill(try image())
        let still = try layer("SpaceCanvas.departureStill", in: XCTUnwrap(view.layer))
        view.open(from: nil, reduceMotion: true)
        XCTAssertNil(still.superlayer)
        XCTAssertNil(still.contents)
    }

    func testWallpaperRemainsAtDisplaySizeThroughEntryZoomAndAppearanceChanges() throws {
        for room in rooms {
            let view = canvas(room: room, selected: 12, current: 3)
            let image = try image()
            view.installWallpaper(.init(cgImage: image))
            view.open(from: nil, reduceMotion: false)
            let root = try XCTUnwrap(view.layer)
            let wallpaper = try layer("SpaceCanvas.wallpaper", in: root)
            let plane = try layer("SpaceCanvas.plane", in: root)
            let before = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
            XCTAssertTrue(wallpaper.superlayer === root, "The background must not inherit the desktop camera")
            XCTAssertEqual(root.sublayers?.filter { $0.name == "SpaceCanvas.wallpaper" }.count, 1)
            for visual in [false, true] {
                view.setVisual(visual)
                XCTAssertEqual(wallpaper.frame, CGRect(origin: .zero, size: room))
                XCTAssertTrue(CATransform3DIsIdentity(wallpaper.transform))
                XCTAssertNil(wallpaper.animation(forKey: "transform"))
                XCTAssertEqual(wallpaper.opacity > 0, visual)
                XCTAssertTrue(wallpaper.contents as AnyObject? === image)
                for id in 1...16 {
                    let region = try layer("SpaceCanvas.region.\(id)", in: root)
                    XCTAssertEqual(region.backgroundColor?.alpha == 1, !visual)
                    XCTAssertTrue(region.sublayers?.isEmpty ?? true, "No wallpaper repeats inside a tile")
                }
                let after = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
                XCTAssertEqual(after.values as? [NSValue], before.values as? [NSValue])
            }
            view.land(reduceMotion: true, arrived: {})
            XCTAssertEqual(wallpaper.frame, CGRect(origin: .zero, size: room))
            XCTAssertTrue(CATransform3DIsIdentity(wallpaper.transform))
            view.reveal(reduceMotion: true)
            XCTAssertEqual(wallpaper.opacity, 0)
            view.installWallpaper(.init(cgImage: try self.image()))
            XCTAssertTrue(wallpaper.contents as AnyObject? === image, "Late arrivals cannot replace a departing backdrop")
            XCTAssertEqual(wallpaper.opacity, 0)
        }
    }

    func testWallpaperArrivingInShapesStaysHiddenUntilVisualIsSelected() throws {
        let view = canvas(selected: 12, current: 3)
        view.setVisual(false)
        view.installWallpaper(.init(cgImage: try image()))
        let root = try XCTUnwrap(view.layer)
        let wallpaper = try layer("SpaceCanvas.wallpaper", in: root)
        XCTAssertEqual(wallpaper.opacity, 0)
        XCTAssertEqual(try layer("SpaceCanvas.region.1", in: root).backgroundColor?.alpha, 1)
        view.setVisual(true)
        XCTAssertGreaterThan(wallpaper.opacity, 0)
        XCTAssertLessThan(try XCTUnwrap(layer("SpaceCanvas.region.1", in: root).backgroundColor?.alpha), 1)
    }

    func testVisualAndShapesKeepAllWindowPositionsSnapshotsAndCameraMotion() throws {
        _ = NSApplication.shared
        let windows = (0..<8).map { index in
            SpaceFilmstripWindow(rect: CGRect(x: CGFloat(index) * 0.055, y: CGFloat(index) * 0.06,
                                             width: 0.4, height: 0.35),
                                 app: "Editor", wid: UInt32(101 + index))
        }
        var cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        cards[0] = .init(id: 1, number: 1, windows: Array(windows.suffix(6)), canvasWindows: windows)
        let view = SpaceCanvasView(cards: cards, selected: 3, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2, handlers: handlers())
        let image = try image()
        view.installPreviews(Dictionary(uniqueKeysWithValues: windows.map { ($0.wid, image) }), at: 0)
        view.open(from: nil, reduceMotion: false)
        let root = try XCTUnwrap(view.layer)
        let plane = try layer("SpaceCanvas.plane", in: root)
        let container = try layer("SpaceCanvas.windows.1", in: root)
        let zones = try XCTUnwrap(container.sublayers)
        XCTAssertEqual(zones.count, windows.count, "The atlas must retain windows beyond the strip's six")
        let camera = view.camera
        let motion = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        let identities = zones.map(ObjectIdentifier.init)
        let frames = zones.map(\.frame)
        for (zone, window) in zip(zones, windows) {
            XCTAssertEqual(zone.frame.minX / container.bounds.width, window.rect.minX, accuracy: 1e-8)
            XCTAssertEqual(zone.frame.minY / container.bounds.height, window.rect.minY, accuracy: 1e-8)
            XCTAssertEqual(zone.frame.width / container.bounds.width, window.rect.width, accuracy: 1e-8)
            XCTAssertEqual(zone.frame.height / container.bounds.height, window.rect.height, accuracy: 1e-8)
        }
        for visual in [false, true] {
            view.setVisual(visual)
            XCTAssertEqual(view.camera, camera)
            XCTAssertEqual(container.sublayers?.map(ObjectIdentifier.init), identities)
            XCTAssertEqual(container.sublayers?.map(\.frame), frames)
            let after = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
            XCTAssertEqual(after.values as? [NSValue], motion.values as? [NSValue])
            XCTAssertEqual(after.duration, motion.duration)
            for window in windows {
                let photo = try layer("SpaceCanvas.photo.\(window.wid)", in: root)
                let pixels = try layer("SpaceCanvas.pixels", in: photo)
                XCTAssertEqual(photo.opacity, visual ? 1 : 0)
                XCTAssertTrue(pixels.contents as AnyObject? === image, "Switching appearance must retain captures")
            }
        }
    }

    private var rooms: [CGSize] {
        [CGSize(width: 1440, height: 900), CGSize(width: 3440, height: 1440), CGSize(width: 900, height: 1440)]
    }

    private func canvas(room: CGSize = CGSize(width: 1440, height: 900), selected: Int, current: Int) -> SpaceCanvasView {
        _ = NSApplication.shared
        return SpaceCanvasView(cards: (1...16).map { .init(id: $0, number: $0, windows: []) },
            selected: selected, current: current, room: room, scale: 2, handlers: handlers())
    }

    private func handlers() -> SpaceCanvasView.Handlers {
        .init(choose: { _ in XCTFail("Rendering must not choose a desktop") },
              land: { XCTFail("Rendering must not land") }, cancel: {})
    }

    private func layer(_ name: String, in root: CALayer) throws -> CALayer {
        func find(_ candidate: CALayer) -> CALayer? {
            if candidate.name == name { return candidate }
            return candidate.sublayers?.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root), "Missing layer \(name)")
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.orange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
