import XCTest
@testable import Lattices

final class SpaceFilmstripTests: XCTestCase {
    func testRecoveredInventoryUpdatesVisibleInkWithoutRestartingTravel() {
        let view = SpaceFilmstripView()
        var cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        view.configure(cards: cards, size: CGSize(width: 1000, height: SpaceFilmstripLayout.height), scale: 2)
        view.select(0, animated: false)
        view.select(1, animated: true)
        view.illuminateFrame(animated: true)
        let travel = view.trackDeltas
        let animationCount = view.animationCount
        let opacities = view.cardOpacities
        let marker = view.markerX
        cards[0] = SpaceFilmstripCard(id: 1, number: 1, windows: [
            SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), app: "Recovered editor")
        ])

        XCTAssertTrue(view.refresh(cards: cards))
        XCTAssertEqual(view.cardModels, cards)
        XCTAssertEqual(view.selected, 1)
        XCTAssertEqual(view.trackDeltas, travel)
        XCTAssertEqual(view.animationCount, animationCount)
        XCTAssertEqual(view.cardOpacities, opacities)
        XCTAssertEqual(view.markerX, marker)
        XCTAssertEqual(view.configurationCount, 1)
        XCTAssertTrue(labels(in: view).contains("Recovered editor"), "Recovery must replace actual rendered ink")
        XCTAssertFalse(view.refresh(cards: cards))

        view.setZoomed(true, reduceMotion: false)
        let zoomAnimations = view.animationCount
        cards[0] = SpaceFilmstripCard(id: 1, number: 1, windows: [])
        XCTAssertTrue(view.refresh(cards: cards), "A genuinely empty desktop must also update")
        XCTAssertTrue(view.isZoomed)
        XCTAssertEqual(view.selected, 1)
        XCTAssertEqual(view.animationCount, zoomAnimations)
        XCTAssertFalse(labels(in: view).contains("Recovered editor"))
        var changedTopology = cards
        changedTopology[0] = SpaceFilmstripCard(id: 42, number: 1, windows: [])
        XCTAssertFalse(view.refresh(cards: changedTopology))
        XCTAssertEqual(view.cardModels, cards)
    }

    private func labels(in view: NSView) -> [String] {
        func visit(_ layer: CALayer) -> [String] {
            let own = (layer as? CATextLayer)?.string as? String
            return (own.map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap(visit)
        }
        return (view.layer.map(visit) ?? []) + view.subviews.flatMap { labels(in: $0) }
    }

    func testWarmReopenReusesLayersButInvalidatesChangedContentAndGeometry() {
        let view = SpaceFilmstripView()
        let size = CGSize(width: 1000, height: SpaceFilmstripLayout.height)
        var models = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: [
            SpaceFilmstripWindow(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6), app: "Editor")
        ]) }
        XCTAssertTrue(view.configure(cards: models, size: size, scale: 2))
        for index in [15, 0, 14, 1] {
            view.select(index, animated: true)
            view.scrub(number: index + 1, total: 16, animated: true)
            view.resetPresentation()
            XCTAssertNil(view.selected)
            XCTAssertFalse(view.isScrubbing)
            XCTAssertEqual(view.animationCount, 0)
            XCTAssertFalse(view.configure(cards: models, size: size, scale: 2))
            view.select(index, animated: false)
            XCTAssertEqual(view.trackX, SpaceFilmstripLayout.offset(selected: index, viewportWidth: 968))
        }
        XCTAssertEqual(view.configurationCount, 1)
        models[0] = SpaceFilmstripCard(id: 1, number: 1, windows: [])
        XCTAssertTrue(view.configure(cards: models, size: size, scale: 2))
        XCTAssertTrue(view.configure(cards: models, size: size, scale: 1))
        XCTAssertTrue(view.configure(cards: models, size: CGSize(width: 640, height: size.height), scale: 1))
        view.clear()
        XCTAssertTrue(view.cardModels.isEmpty, "Idle release must discard window metadata as well as layers")
        XCTAssertTrue(view.cardOpacities.isEmpty)
        XCTAssertTrue(view.configure(cards: models, size: size, scale: 2))
    }

    func testOverlayClockExcludesEachScreenFreezeAndResumesOnlyOnce() {
        let layer = CALayer()
        let first = SpaceOverlayAnimationClock(layer: layer, now: 10)
        XCTAssertEqual(layer.convertTime(10.15, from: nil), 10, accuracy: 0.0001)
        first.resume(now: 10.15)
        XCTAssertEqual(layer.convertTime(10.20, from: nil), 10.05, accuracy: 0.0001)
        first.resume(now: 11)
        XCTAssertEqual(layer.convertTime(11, from: nil), 10.85, accuracy: 0.0001)
        let second = SpaceOverlayAnimationClock(layer: layer, now: 11)
        second.resume(now: 11.2)
        XCTAssertEqual(layer.convertTime(11.25, from: nil), 10.90, accuracy: 0.0001)
        XCTAssertEqual(layer.speed, 1)
    }

    func testEntranceAndScreenFreezePreserveChildAnimationTimeline() {
        let root = CALayer()
        let edge = CALayer()
        root.addSublayer(edge)
        // A retained surface already carries time excluded by earlier switches.
        root.beginTime = 3
        let opening = SpaceOverlayAnimationClock(layer: root, now: 10)
        let light = CABasicAnimation(keyPath: "opacity")
        light.beginTime = edge.convertTime(10, from: nil) + 0.05
        light.duration = 0.13
        edge.add(light, forKey: "light")
        opening.resume(now: 10.06)
        XCTAssertEqual(edge.convertTime(10.06, from: nil), 7, accuracy: 0.0001)

        let switching = SpaceOverlayAnimationClock(layer: root, now: 10.08)
        switching.resume(now: 10.24)
        XCTAssertEqual(edge.convertTime(10.24, from: nil), 7.02, accuracy: 0.0001)
        XCTAssertEqual(light.beginTime - edge.convertTime(10.24, from: nil), 0.03, accuracy: 0.0001,
                       "Ordering and the Dock freeze must not consume the delayed entrance light")
        XCTAssertEqual(edge.convertTime(10.40, from: nil), 7.18, accuracy: 0.0001)
        XCTAssertEqual(root.speed, 1)
    }

    func testWarmConfigurationCostAgainstRebuildingSixteenDesktops() {
        let view = SpaceFilmstripView()
        let models = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        let size = CGSize(width: 1000, height: SpaceFilmstripLayout.height)
        let cold = CACurrentMediaTime()
        for _ in 0..<30 {
            view.clear()
            view.configure(cards: models, size: size, scale: 2)
        }
        let coldMS = (CACurrentMediaTime() - cold) * 1000 / 30
        let warm = CACurrentMediaTime()
        for _ in 0..<30 {
            view.resetPresentation()
            view.configure(cards: models, size: size, scale: 2)
            view.select(15, animated: false)
        }
        let warmMS = (CACurrentMediaTime() - warm) * 1000 / 30
        print("SpaceFilmstrip benchmark: rebuildMS=\(coldMS) reuseMS=\(warmMS)")
        XCTAssertEqual(view.configurationCount, 30, "Warm cycles must not rebuild")
    }

    func testWindowAttachmentKeepsPreviewsAboveGlass() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 1000, height: SpaceFilmstripLayout.height)
        let view = SpaceFilmstripView()
        view.frame = CGRect(origin: .zero, size: size)
        view.configure(cards: (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }, size: size, scale: 2)
        view.select(15, animated: false)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let material = try XCTUnwrap(view.subviews.first { $0 is NSVisualEffectView })
            let host = try XCTUnwrap(view.subviews.first { child in
                child.layer?.sublayers?.contains { $0.name == "SpaceFilmstrip.tray" } == true
            }, "Retained previews need their own view above the AppKit material")
            let layers = try XCTUnwrap(view.layer?.sublayers)
            let glassIndex = try XCTUnwrap(layers.firstIndex { $0 === material.layer })
            let reelIndex = try XCTUnwrap(layers.firstIndex { $0 === host.layer })
            XCTAssertGreaterThan(reelIndex, glassIndex)
            XCTAssertEqual(host.bounds.size, size)
            XCTAssertTrue(host.isFlipped)
            XCTAssertEqual(view.apertureFrame, CGRect(x: 412, y: 19, width: 176, height: 113))
            window.contentView = nil
            window.contentView = view
        }
    }

    func testCompositorFadeCanReverseAndReduceMotionClearsIt() {
        let view = SpaceFilmstripView()
        SpaceSwitchBezel.fade(view, to: 1, duration: 0.14, from: 0.35)
        XCTAssertEqual(view.layer?.opacity, 1)
        let arrival = view.layer?.animation(forKey: "visibility") as? CABasicAnimation
        XCTAssertEqual(arrival?.fromValue as? Float, 0.35)
        XCTAssertEqual(arrival?.toValue as? Float, 1)

        SpaceSwitchBezel.fade(view, to: 0, duration: 0.12)
        XCTAssertEqual(view.layer?.opacity, 0)
        SpaceSwitchBezel.fade(view, to: 1, duration: 0)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertNil(view.layer?.animation(forKey: "visibility"))
    }

    func testEveryDesktopCentersIncludingBothEndsAndLongJumps() {
        for width: CGFloat in [272, 640, 968] {
            for selected in [0, 1, 8, 17, 63] {
                let center = CGFloat(selected) * SpaceFilmstripLayout.stride
                    + SpaceFilmstripLayout.cardWidth / 2
                    + SpaceFilmstripLayout.offset(selected: selected, viewportWidth: width)
                XCTAssertEqual(center, width / 2, accuracy: 0.001)
            }
        }
    }

    func testTrayFitsSmallAndLargeDisplaysAndCentersOnNegativeOrigin() {
        for width: CGFloat in [320, 1024, 3440] {
            for count in [1, 18, 64] {
                let trayWidth = SpaceFilmstripLayout.trayWidth(screenWidth: width, count: count)
                XCTAssertLessThanOrEqual(trayWidth, width - 48)
                XCTAssertLessThanOrEqual(trayWidth, 1000)
                let screen = CGRect(x: -3840, y: -396, width: width, height: 2160)
                let frame = SpaceSwitchBezel.frame(position: .center, direction: -1,
                    size: CGSize(width: trayWidth, height: SpaceFilmstripLayout.height), screen: screen)
                XCTAssertEqual(frame.midX, screen.midX)
                XCTAssertEqual(frame.midY, screen.midY)
            }
        }
    }

    func testApertureGridIsRegularAndOptimisedForSixteen() {
        let shapes = [1: (1, 1), 2: (2, 1), 4: (2, 2), 5: (3, 2), 9: (3, 3), 10: (4, 3), 16: (4, 4)]
        for (count, shape) in shapes {
            let got = SpaceFilmstripLayout.gridShape(count: count)
            XCTAssertEqual(got.columns, shape.0, "columns for \(count)")
            XCTAssertEqual(got.rows, shape.1, "rows for \(count)")
        }
    }

    func testApertureGridCellsAdjoinAndFitTheFrame() {
        let frame = CGRect(x: 7, y: 7, width: 162, height: 99)
        for count in 1...16 {
            let cells = SpaceFilmstripLayout.gridCells(count: count, in: frame)
            XCTAssertEqual(cells.count, count)
            let columns = SpaceFilmstripLayout.gridShape(count: count).columns
            for (i, cell) in cells.enumerated() {
                XCTAssertTrue(frame.insetBy(dx: -0.001, dy: -0.001).contains(cell), "cell \(i) of \(count)")
                XCTAssertEqual(cell.width / cell.height, 1.6, accuracy: 0.001)
                if i % columns > 0 { XCTAssertEqual(cell.minX, cells[i - 1].maxX, accuracy: 0.001) }
                if i >= columns { XCTAssertEqual(cell.minY, cells[i - columns].maxY, accuracy: 0.001) }
            }
        }
        XCTAssertTrue(SpaceFilmstripLayout.gridCells(count: 0, in: frame).isEmpty)
    }

    func testApertureZoomIsReversibleAndSettlesWithoutWork() {
        let view = SpaceFilmstripView()
        let cards = (1...16).map { SpaceFilmstripCard(id: $0, number: $0, windows: []) }
        view.configure(cards: cards, size: CGSize(width: 968, height: SpaceFilmstripLayout.height), scale: 2)
        view.select(7, animated: false)
        view.setZoomed(true, reduceMotion: true)
        XCTAssertTrue(view.isZoomed)
        view.select(10, animated: false)
        view.setZoomed(false, reduceMotion: true)
        XCTAssertFalse(view.isZoomed)
        XCTAssertEqual(view.selected, 10)
        XCTAssertEqual(view.trackX, SpaceFilmstripLayout.offset(selected: 10, viewportWidth: 936), accuracy: 0.001)
        view.clear()
        XCTAssertFalse(view.isZoomed)
        XCTAssertEqual(view.animationCount, 0)
    }

    func testProjectionClipsToRequestedDisplayAndPreservesEmptyDesktops() {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 1, isCurrent: true),
                      SpaceInfo(id: 43, index: 2, display: 1, isCurrent: false)]
        let windows = [window(1, frame: WindowFrame(x: -1100, y: 0, w: 600, h: 500)),
                       window(2, frame: WindowFrame(x: 50, y: 0, w: 600, h: 500))]
        let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: windows,
            bounds: CGRect(x: -1000, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards.map(\.id), [42, 43])
        XCTAssertEqual(cards[0].windows.count, 1)
        XCTAssertEqual(cards[0].windows[0].rect, CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(cards[1].windows.isEmpty)
    }

    func testPreviewsAreBoundedAndExcludeHiddenAndOwnWindows() {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true)]
        var windows = (1...100).map { window(UInt32($0), z: $0) }
        var hidden = window(101, z: 0)
        hidden.appHidden = true
        var collapsed = window(102, z: 0)
        collapsed.collapsed = true
        windows += [hidden, collapsed,
            WindowEntry(wid: 103, app: "Lattices", pid: getpid(), title: "Overlay",
                        frame: windows[0].frame, spaceIds: [42], isOnScreen: true, latticesSession: nil)]
        let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: windows,
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards[0].windows.count, 6)
        XCTAssertEqual(cards[0].windows.map(\.app), ["App 6", "App 5", "App 4", "App 3", "App 2", "App 1"])
    }

    func testInactiveUntitledWindowStillHasAPlanWithoutAXVerification() {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: false)]
        let window = WindowEntry(wid: 1, app: "Editor", pid: -1, title: "",
            frame: WindowFrame(x: 0, y: 0, w: 500, h: 500), spaceIds: [42],
            isOnScreen: false, latticesSession: nil, axVerified: false)
        let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: [window],
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards[0].windows.count, 1)
        XCTAssertEqual(cards[0].windows[0].app, "Editor")
    }

    func testUnsortedInventoryKeepsFrontmostSixAfterDisplayClipping() {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true)]
        let visible = (1...10).reversed().map { window(UInt32($0), z: $0) }
        let offDisplay = (11...20).map {
            window(UInt32($0), z: 0, frame: WindowFrame(x: 2000, y: 0, w: 500, h: 500))
        }
        let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: offDisplay + visible,
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards[0].windows.map(\.app), (1...6).reversed().map { "App \($0)" })
    }

    func testSharedWindowsAppearOncePerDesktopAndTiesKeepInventoryOrder() {
        let spaces = [SpaceInfo(id: 43, index: 2, display: 0, isCurrent: false),
                      SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true),
                      SpaceInfo(id: 44, index: 3, display: 0, isCurrent: false)]
        let shared = WindowEntry(wid: 100, app: "Shared", pid: -1, title: "",
            frame: WindowFrame(x: 0, y: 0, w: 500, h: 500), spaceIds: [42, 43, 42, 999],
            isOnScreen: false, latticesSession: nil)
        let cards = SpaceFilmstripLayout.cards(spaces: spaces,
            windows: [shared] + (1...8).map { window(UInt32($0)) },
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards.map(\.id), [43, 42, 44])
        XCTAssertEqual(cards.map(\.number), [2, 1, 3])
        XCTAssertEqual(cards[0].windows.map(\.app), ["Shared"])
        XCTAssertEqual(cards[1].windows.map(\.app), ["App 5", "App 4", "App 3", "App 2", "App 1", "Shared"])
        XCTAssertTrue(cards[2].windows.isEmpty)
    }

    func testInvalidDisplayBoundsKeepEmptyDesktopCards() {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true)]
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 1000, height: 0)] {
            let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: [window(1)], bounds: bounds)
            XCTAssertEqual(cards.map(\.id), [42])
            XCTAssertTrue(cards[0].windows.isEmpty)
        }
    }

    // MARK: Motion

    private func strip(count: Int = 18) -> SpaceFilmstripView {
        let view = SpaceFilmstripView()
        let cards = (0..<count).map { SpaceFilmstripCard(id: $0, number: $0 + 1, windows: []) }
        view.configure(cards: cards, size: CGSize(width: 1000, height: SpaceFilmstripLayout.height), scale: 2)
        return view
    }

    private func offset(_ index: Int) -> CGFloat {
        SpaceFilmstripLayout.offset(selected: index, viewportWidth: 1000 - 32)
    }

    func testReopenTravelsFromDepartureNotThePreviousGesture() {
        let view = strip()
        view.select(2, animated: false)
        view.select(9, animated: true)
        // Gesture ends; the next opens elsewhere in the same run-loop pass,
        // before Core Animation commits anything.
        view.configure(cards: (0..<18).map { SpaceFilmstripCard(id: $0, number: $0 + 1, windows: []) },
                       size: CGSize(width: 1000, height: SpaceFilmstripLayout.height), scale: 2)
        XCTAssertEqual(view.animationCount, 0)
        view.select(14, animated: false)
        view.select(15, animated: true)
        XCTAssertEqual(view.trackX, offset(15), accuracy: 0.001)
        XCTAssertEqual(view.trackDeltas.count, 1)
        XCTAssertEqual(view.trackDeltas[0], offset(14) - offset(15), accuracy: 0.001)
    }

    func testReversalAndMergedBurstStayContinuous() {
        let view = strip()
        view.select(5, animated: false)
        // Visible position = model + remaining deltas. With no time elapsed
        // every retarget must leave the strip exactly where it was.
        for target in [6, 7, 6, 5, 12, 4] {
            view.select(target, animated: true)
            XCTAssertEqual(view.trackX + view.trackDeltas.reduce(0, +), offset(5), accuracy: 0.001)
        }
        XCTAssertEqual(view.trackX, offset(4), accuracy: 0.001)
    }

    func testTravelLegsAreAdditiveSelfRemovingAndReleasedOnClear() {
        let view = strip()
        view.select(0, animated: false)
        view.select(1, animated: true)
        XCTAssertGreaterThan(view.animationCount, 0)
        var point: [Float] = [0, 0]
        SpaceFilmstripView.travelTiming.getControlPoint(at: 1, values: &point)
        XCTAssertEqual(point[1], 0, "zero initial slope keeps speed continuous")
        view.clear()
        XCTAssertEqual(view.animationCount, 0)
        XCTAssertNil(view.selected)
    }

    func testReduceMotionSelectsWithoutAnimation() {
        let view = strip()
        view.select(3, animated: false)
        view.select(8, animated: false)
        XCTAssertEqual(view.animationCount, 0)
        XCTAssertEqual(view.trackX, offset(8), accuracy: 0.001)
        XCTAssertEqual(view.cardOpacities[8], 1)
        XCTAssertEqual(view.cardOpacities[7], SpaceFilmstripView.emphasis(distance: 1))
    }

    func testPassingLightIsBoundedAndReleasedWithTheGesture() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        host.wantsLayer = true
        let wash = SpaceSwitchWash()
        XCTAssertEqual(wash.liveBandCount, 0)
        for _ in 0..<20 { wash.pass(direction: 1, in: host) }
        wash.pass(direction: -1, in: host)
        XCTAssertLessThanOrEqual(wash.liveBandCount, 3)
        XCTAssertLessThanOrEqual(host.layer?.sublayers?.count ?? 0, 3)
        wash.release()
        XCTAssertEqual(wash.liveBandCount, 0)
        XCTAssertEqual(host.layer?.sublayers?.count ?? 0, 0)
    }

    func testScrubbingKeepsTrackStillAndReleaseDoesNotTravelThroughCards() {
        let view = strip()
        view.select(1, animated: false)
        let departure = view.trackX
        for number in [3, 4, 9, 10, 18, 17, 6] {
            view.scrub(number: number, total: 18, animated: true)
            XCTAssertEqual(view.trackX, departure)
            XCTAssertEqual(view.selected, 1)
            XCTAssertTrue(view.isScrubbing)
        }
        view.endScrubbing(at: 5, animated: true)
        XCTAssertEqual(view.selected, 5)
        XCTAssertEqual(view.trackX, offset(5), accuracy: 0.001)
        XCTAssertTrue(view.trackDeltas.isEmpty, "Release reveals the destination without replaying intermediate cards")
        XCTAssertFalse(view.isScrubbing)
        view.clear()
        XCTAssertEqual(view.animationCount, 0)
    }

    func testApertureStaysFixedAtTheTrayCentreForEveryCount() {
        // The canvas hand-off and the odometer both read this frame; visual
        // refinements must not move it.
        for count in [1, 4, 18] {
            let view = strip(count: count)
            view.select(count - 1, animated: false)
            XCTAssertEqual(view.apertureFrame, CGRect(x: 16 + (968 - 176) / 2, y: 19, width: 176, height: 113))
        }
    }

    func testArrivalSettleIsOneFiniteLegAndReleasedOnClear() {
        let view = strip()
        view.select(4, animated: false)
        view.illuminateFrame(animated: false)
        XCTAssertEqual(view.animationCount, 0, "Reduce Motion arrives without a settle")
        view.illuminateFrame(animated: true)
        XCTAssertEqual(view.animationCount, 1)
        view.clear()
        XCTAssertEqual(view.animationCount, 0)
    }

    func testCaptureExclusionsRejectSyntheticAppKitWindowNumbers() {
        XCTAssertEqual(SpaceSwitchBezel.captureWindowIDs([-1, 0, 42, Int(UInt32.max), Int(UInt32.max) + 1, Int.max]),
                       [42, UInt32.max])
    }

    private func window(_ id: UInt32, z: Int = 0,
                        frame: WindowFrame = WindowFrame(x: 0, y: 0, w: 500, h: 500)) -> WindowEntry {
        WindowEntry(wid: id, app: "App \(id)", pid: -1, title: "Window", frame: frame,
                    spaceIds: [42], isOnScreen: false, latticesSession: nil, zIndex: z)
    }
}
