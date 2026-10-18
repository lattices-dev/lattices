import XCTest
@testable import Lattices

final class SpaceCanvasDetailTests: XCTestCase {
    func testDetailAppearsOnlyWithinOnePointTwoTimesFullSize() {
        let fill: CGFloat = 1440
        let hiddenRatios: [CGFloat] = [0, 0.2, SpaceCanvasDetail.prepareRatio, 1 / 1.2]
        for ratio in hiddenRatios {
            XCTAssertEqual(SpaceCanvasDetail.opacity(scale: fill * ratio, fillScale: fill), 0)
        }
        let middle = (CGFloat(1 / 1.2) + 0.98) / 2
        XCTAssertEqual(SpaceCanvasDetail.opacity(scale: fill * middle, fillScale: fill), 0.5, accuracy: 0.0001)
        let fullRatios: [CGFloat] = [0.98, 1, 1.2]
        for ratio in fullRatios {
            XCTAssertEqual(SpaceCanvasDetail.opacity(scale: fill * ratio, fillScale: fill), 1)
        }
        XCTAssertEqual(SpaceCanvasDetail.opacity(scale: 1, fillScale: 0), 0)
    }

    func testFarMapDoesNotAttachPixelsFromAnEarlyArrival() throws {
        let view = canvas()
        let photo = try layer("SpaceCanvas.photo.101", in: XCTUnwrap(view.layer))
        let pixels = try layer("SpaceCanvas.pixels", in: photo)
        let camera = view.camera

        view.installPreviews([101: try image()], at: 0)

        XCTAssertEqual(photo.opacity, 0)
        XCTAssertNil(pixels.contents)
        XCTAssertEqual(view.camera, camera)
    }

    func testNearArrivalPreservesCameraAndInFlightZoom() throws {
        let view = canvas()
        zoomToFull(view)
        view.zoom(out: true, reduceMotion: true)
        view.zoom(out: false)
        let root = try XCTUnwrap(view.layer)
        let plane = try layer("SpaceCanvas.plane", in: root)
        let photo = try layer("SpaceCanvas.photo.101", in: root)
        let pixels = try layer("SpaceCanvas.pixels", in: photo)
        let motion = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        let camera = view.camera
        let layers = plane.sublayers?.map(ObjectIdentifier.init)
        let still = try image()

        view.installPreviews([101: still], at: 0)

        XCTAssertNotNil(pixels.contents)
        XCTAssertEqual(pixels.opacity, 1)
        XCTAssertEqual(photo.opacity, 1)
        XCTAssertEqual(view.camera, camera)
        XCTAssertEqual(plane.sublayers?.map(ObjectIdentifier.init), layers)
        let after = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        XCTAssertEqual(after.beginTime, motion.beginTime)
        XCTAssertEqual(after.duration, motion.duration)
        XCTAssertEqual(after.values as? [NSValue], motion.values as? [NSValue])
        XCTAssertEqual(after.keyTimes, motion.keyTimes)
    }

    func testInventoryTitleAndFrameRefreshPreservesPhotoAndActiveZoomFades() throws {
        let view = canvas()
        zoomToFull(view)
        view.zoom(out: true, reduceMotion: true)
        view.zoom(out: false)
        let root = try XCTUnwrap(view.layer)
        let plane = try layer("SpaceCanvas.plane", in: root)
        let photo = try layer("SpaceCanvas.photo.101", in: root)
        let pixels = try layer("SpaceCanvas.pixels", in: photo)
        view.installPreviews([101: try image()], at: 0)
        let camera = view.camera
        let cameraMotion = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        let photoMotion = try XCTUnwrap(photo.animation(forKey: "opacity") as? CAKeyframeAnimation)
        let pixelFade = CABasicAnimation(keyPath: "opacity")
        pixelFade.fromValue = 0.25
        pixelFade.toValue = 1
        pixelFade.beginTime = CACurrentMediaTime() + 0.25
        pixelFade.duration = 2
        pixels.add(pixelFade, forKey: "opacity")
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7)
        let changed = SpaceFilmstripWindow(
            rect: CGRect(x: 0.15, y: 0.2, width: 0.75, height: 0.7),
            app: "Editor", title: "Renamed document", wid: 101, contentsRect: crop)

        XCTAssertTrue(view.refresh(cards: cards(first: changed)))

        XCTAssertTrue(try layer("SpaceCanvas.photo.101", in: root) === photo)
        XCTAssertTrue(try layer("SpaceCanvas.pixels", in: photo) === pixels)
        XCTAssertNotNil(pixels.contents)
        XCTAssertEqual(pixels.contentsRect, crop)
        XCTAssertEqual(view.camera, camera)
        let cameraAfter = try XCTUnwrap(plane.animation(forKey: "transform") as? CAKeyframeAnimation)
        let photoAfter = try XCTUnwrap(photo.animation(forKey: "opacity") as? CAKeyframeAnimation)
        XCTAssertEqual(cameraAfter.values as? [NSValue], cameraMotion.values as? [NSValue])
        XCTAssertEqual(cameraAfter.beginTime, cameraMotion.beginTime)
        XCTAssertEqual(cameraAfter.duration, cameraMotion.duration)
        XCTAssertEqual(photoAfter.values as? [NSNumber], photoMotion.values as? [NSNumber])
        XCTAssertEqual(photoAfter.beginTime, photoMotion.beginTime)
        XCTAssertEqual(photoAfter.duration, photoMotion.duration)
        let pixelsAfter = try XCTUnwrap(pixels.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(pixelsAfter.beginTime, pixelFade.beginTime)
        XCTAssertEqual(pixelsAfter.duration, pixelFade.duration)
        XCTAssertEqual(pixelsAfter.fromValue as? NSNumber, pixelFade.fromValue as? NSNumber)
    }

    func testRepeatedCachedImageDoesNotRestartPixelFade() throws {
        let view = canvas()
        zoomToFull(view)
        let photo = try layer("SpaceCanvas.photo.101", in: XCTUnwrap(view.layer))
        let pixels = try layer("SpaceCanvas.pixels", in: photo)
        let still = try image()
        view.installPreviews([101: still], at: 0)
        // A known in-flight fade makes the test independent of Reduce Motion.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + 0.25
        fade.duration = 2
        pixels.add(fade, forKey: "opacity")
        let camera = view.camera

        for _ in 0..<3 { view.installPreviews([101: still], at: 0) }

        let after = try XCTUnwrap(pixels.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(after.beginTime, fade.beginTime)
        XCTAssertEqual(after.duration, fade.duration)
        XCTAssertEqual(after.fromValue as? NSNumber, fade.fromValue as? NSNumber)
        XCTAssertEqual(after.toValue as? NSNumber, fade.toValue as? NSNumber)
        XCTAssertNotNil(pixels.contents)
        XCTAssertEqual(view.camera, camera)
    }

    func testZoomingBackOutReleasesPixelsAndRejectsLateArrival() throws {
        let view = canvas()
        zoomToFull(view)
        let photo = try layer("SpaceCanvas.photo.101", in: XCTUnwrap(view.layer))
        let pixels = try layer("SpaceCanvas.pixels", in: photo)
        let still = try image()
        view.installPreviews([101: still], at: 0)
        XCTAssertNotNil(pixels.contents)

        for _ in 0..<12 { view.zoom(out: true, reduceMotion: true) }
        XCTAssertEqual(view.camera.scale, view.layout.fitScale)
        XCTAssertNil(pixels.contents)
        XCTAssertEqual(photo.opacity, 0)
        XCTAssertEqual(pixels.opacity, 0)

        view.installPreviews([101: still], at: 0)
        XCTAssertNil(pixels.contents, "An old near-selection result must not refill the distant map")
    }

    func testSelectionChangeRejectsPreviousDesktopArrival() throws {
        let view = canvas()
        zoomToFull(view)
        let root = try XCTUnwrap(view.layer)
        let oldPixels = try layer("SpaceCanvas.pixels", in: layer("SpaceCanvas.photo.101", in: root))
        let newPixels = try layer("SpaceCanvas.pixels", in: layer("SpaceCanvas.photo.102", in: root))
        let still = try image()
        view.installPreviews([101: still], at: 0)

        view.select(1, animated: false)
        view.installPreviews([101: still], at: 0)
        XCTAssertNil(oldPixels.contents)
        XCTAssertNil(newPixels.contents)

        view.installPreviews([102: still], at: 1)
        XCTAssertNotNil(newPixels.contents)
        XCTAssertNil(oldPixels.contents)
    }

    func testWindowSpanningDisplaysKeepsIdentityAndCropsEachSide() throws {
        let window = WindowEntry(wid: 700, app: "Editor", pid: -1, title: "Across displays",
            frame: WindowFrame(x: -200, y: 100, w: 600, h: 400), spaceIds: [41, 42],
            isOnScreen: true, latticesSession: nil)
        let left = try XCTUnwrap(SpaceFilmstripLayout.cards(
            spaces: [SpaceInfo(id: 41, index: 1, display: 1, isCurrent: true)], windows: [window],
            bounds: CGRect(x: -1000, y: 0, width: 1000, height: 1000)).first?.windows.first)
        let right = try XCTUnwrap(SpaceFilmstripLayout.cards(
            spaces: [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true)], windows: [window],
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)).first?.windows.first)

        for part in [left, right] {
            XCTAssertEqual(part.wid, 700)
            XCTAssertEqual(part.pid, -1)
            XCTAssertEqual(part.title, "Across displays")
            XCTAssertEqual(part.contentsRect.minY, 0, accuracy: 0.0001)
            XCTAssertEqual(part.contentsRect.height, 1, accuracy: 0.0001)
        }
        XCTAssertEqual(left.rect.minX, 0.8, accuracy: 0.0001)
        XCTAssertEqual(left.rect.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(left.contentsRect.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(left.contentsRect.width, 1 / 3, accuracy: 0.0001)
        XCTAssertEqual(right.rect.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(right.rect.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(right.contentsRect.minX, 1 / 3, accuracy: 0.0001)
        XCTAssertEqual(right.contentsRect.width, 2 / 3, accuracy: 0.0001)

        let view = canvas(first: right)
        let photo = try layer("SpaceCanvas.photo.700", in: XCTUnwrap(view.layer))
        XCTAssertEqual(try layer("SpaceCanvas.pixels", in: photo).contentsRect, right.contentsRect)
    }

    func testClippingAboveAndLeftUsesUnclippedWindowForSourceCrop() throws {
        let window = WindowEntry(wid: 701, app: "Editor", pid: -1, title: "Corner",
            frame: WindowFrame(x: -1200, y: -700, w: 600, h: 500), spaceIds: [41],
            isOnScreen: true, latticesSession: nil)
        let clipped = try XCTUnwrap(SpaceFilmstripLayout.cards(
            spaces: [SpaceInfo(id: 41, index: 1, display: 1, isCurrent: true)], windows: [window],
            bounds: CGRect(x: -1000, y: -500, width: 1000, height: 1000)).first?.windows.first)
        XCTAssertEqual(clipped.wid, 701)
        XCTAssertEqual(clipped.rect.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(clipped.rect.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(clipped.rect.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(clipped.rect.height, 0.3, accuracy: 0.0001)
        XCTAssertEqual(clipped.contentsRect.minX, 1 / 3, accuracy: 0.0001)
        XCTAssertEqual(clipped.contentsRect.minY, 0.4, accuracy: 0.0001)
        XCTAssertEqual(clipped.contentsRect.width, 2 / 3, accuracy: 0.0001)
        XCTAssertEqual(clipped.contentsRect.height, 0.6, accuracy: 0.0001)
    }

    private func canvas(first: SpaceFilmstripWindow? = nil) -> SpaceCanvasView {
        _ = NSApplication.shared
        return SpaceCanvasView(cards: cards(first: first), selected: 0, current: 0,
            room: CGSize(width: 1440, height: 900), scale: 2,
            handlers: .init(choose: { _ in }, land: { XCTFail("Preview must not land") }, cancel: {}))
    }

    private func cards(first: SpaceFilmstripWindow? = nil) -> [SpaceFilmstripCard] {
        (1...16).map { number in
            SpaceFilmstripCard(id: number, number: number, windows: [
                number == 1 ? first ?? SpaceFilmstripWindow(
                    rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), app: "Editor", wid: 101)
                : SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      app: "Editor", wid: UInt32(number + 100))
            ])
        }
    }

    private func zoomToFull(_ view: SpaceCanvasView) {
        for _ in 0..<12 { view.zoom(out: false, reduceMotion: true) }
        XCTAssertEqual(view.camera.scale, view.layout.fillScale)
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
