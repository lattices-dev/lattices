@testable import ActionCore
import CoreGraphics
import XCTest

final class ActionMonitorViewportTests: XCTestCase {
    func testBorrowedDisplaySizedWindowsStayInsideBoundsAfterCascading() throws {
        let bounds = CGRect(x: -3440, y: 1440, width: 3440, height: 1440)
        for index in [1, 7] {
            let frame = try XCTUnwrap(ActionMonitorViewport.borrowedWindowFrame(
                size: bounds.size, index: index, displayBounds: bounds))
            let step = CGFloat(index) * 36
            XCTAssertEqual(frame.minX, bounds.minX + 80 + step)
            XCTAssertEqual(frame.minY, bounds.minY + 80 + step)
            XCTAssertEqual(frame.maxX, bounds.maxX - 80)
            XCTAssertEqual(frame.maxY, bounds.maxY - 80)
            XCTAssertTrue(bounds.contains(frame), "The entire second or eighth loan must remain visible")
        }
    }

    func testBorrowPlacementPreservesSmallWindowSizeAndWrapsCascade() throws {
        let bounds = CGRect(x: 3440, y: -400, width: 1920, height: 1080)
        let size = CGSize(width: 400, height: 300)
        let first = try XCTUnwrap(ActionMonitorViewport.borrowedWindowFrame(size: size, index: 0, displayBounds: bounds))
        XCTAssertEqual(first, CGRect(x: 3520, y: -320, width: 400, height: 300))
        XCTAssertEqual(ActionMonitorViewport.borrowedWindowFrame(size: size, index: -1, displayBounds: bounds), first)
        XCTAssertEqual(ActionMonitorViewport.borrowedWindowFrame(size: size, index: 8, displayBounds: bounds), first)
        let tinyBounds = CGRect(x: -50, y: -30, width: 100, height: 60)
        let tiny = try XCTUnwrap(ActionMonitorViewport.borrowedWindowFrame(size: size, index: 7, displayBounds: tinyBounds))
        XCTAssertTrue(tinyBounds.contains(tiny))
        XCTAssertGreaterThan(tiny.width, 0)
        XCTAssertGreaterThan(tiny.height, 0)
    }

    func testBorrowPlacementRejectsInvalidWindowOrDisplayGeometry() {
        let size = CGSize(width: 400, height: 300)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for invalidSize in [CGSize.zero, CGSize(width: -1, height: 300),
                            CGSize(width: CGFloat.nan, height: 300),
                            CGSize(width: 400, height: CGFloat.infinity)] {
            XCTAssertNil(ActionMonitorViewport.borrowedWindowFrame(size: invalidSize, index: 1, displayBounds: bounds))
        }
        for invalidBounds in [CGRect.zero, CGRect.null, CGRect.infinite,
                              CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                              CGRect(x: 0, y: 0, width: -100, height: 100),
                              CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity)] {
            XCTAssertNil(ActionMonitorViewport.borrowedWindowFrame(size: size, index: 1, displayBounds: invalidBounds))
        }
    }

    func testInitialOriginAndOverscrollClampToDisplayEdges() {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 1440, height: 900), origin: CGPoint(x: -40, y: 800))
        XCTAssertEqual(viewport.origin, CGPoint(x: 0, y: 540))
        viewport.pan(delta: CGPoint(x: 50_000, y: -50_000))
        XCTAssertEqual(viewport.origin, CGPoint(x: 2000, y: 0))
        XCTAssertEqual(viewport.visibleRect, CGRect(x: 2000, y: 0, width: 1440, height: 900))
        viewport.pan(delta: CGPoint(x: -50_000, y: 50_000))
        XCTAssertEqual(viewport.origin, CGPoint(x: 0, y: 540))
        XCTAssertEqual(viewport.scale, 1)
    }

    func testPanningChangesOnlyOriginAndPreservesOneToOnePointDistances() throws {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 1440, height: 900))
        let first = CGPoint(x: 120.5, y: 240.25)
        let second = CGPoint(x: 420.5, y: 640.25)
        XCTAssertEqual(viewport.displayPoint(forViewPoint: first), first)
        viewport.pan(delta: CGPoint(x: 350.25, y: 100.5))
        let mappedFirst = try XCTUnwrap(viewport.displayPoint(forViewPoint: first))
        let mappedSecond = try XCTUnwrap(viewport.displayPoint(forViewPoint: second))
        XCTAssertEqual(mappedFirst, CGPoint(x: 470.75, y: 340.75))
        XCTAssertEqual(mappedSecond.x - mappedFirst.x, second.x - first.x)
        XCTAssertEqual(mappedSecond.y - mappedFirst.y, second.y - first.y)
        XCTAssertEqual(viewport.visibleRect.size, CGSize(width: 1440, height: 900))
        XCTAssertEqual(viewport.scale, 1)
    }

    func testPagingRetainsOverlapAndVerticalPositionAtNormalScale() {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 1000, height: 900), origin: CGPoint(x: 0, y: 120))
        viewport.page(direction: 1)
        XCTAssertEqual(viewport.origin, CGPoint(x: 900, y: 120))
        viewport.page(direction: 9)
        XCTAssertEqual(viewport.origin, CGPoint(x: 1800, y: 120), "Direction is a sign, not a page count")
        viewport.page(direction: 1)
        XCTAssertEqual(viewport.origin, CGPoint(x: 2440, y: 120))
        viewport.page(direction: -1)
        XCTAssertEqual(viewport.origin, CGPoint(x: 1540, y: 120))
        let unchanged = viewport
        viewport.page(direction: 0)
        XCTAssertEqual(viewport, unchanged)
        XCTAssertEqual(viewport.scale, 1)
    }

    func testResizeRetainsStationaryContentUntilAnEdgeRequiresClamping() {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 1000, height: 600), origin: CGPoint(x: 1800, y: 500))
        let point = CGPoint(x: 100, y: 100)
        let originalTarget = viewport.displayPoint(forViewPoint: point)
        viewport.resize(viewportSize: CGSize(width: 1400, height: 800))
        XCTAssertEqual(viewport.origin, CGPoint(x: 1800, y: 500))
        XCTAssertEqual(viewport.displayPoint(forViewPoint: point), originalTarget)
        viewport.resize(viewportSize: CGSize(width: 2200, height: 1100))
        XCTAssertEqual(viewport.origin, CGPoint(x: 1240, y: 340))
        viewport.resize(viewportSize: CGSize(width: 800, height: 500))
        XCTAssertEqual(viewport.origin, CGPoint(x: 1240, y: 340), "Shrinking does not recenter or scale the display")
        viewport.update(displaySize: CGSize(width: 1280, height: 720),
                        viewportSize: CGSize(width: 800, height: 500))
        XCTAssertEqual(viewport.origin, CGPoint(x: 480, y: 220))
        XCTAssertEqual(viewport.visibleRect, CGRect(x: 480, y: 220, width: 800, height: 500))
        XCTAssertEqual(viewport.scale, 1)
    }

    func testSmallerDisplayStaysAtNormalSizeAndBlankAreaHasNoTarget() {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: 640, height: 480),
            viewportSize: CGSize(width: 1440, height: 900), origin: CGPoint(x: 400, y: 300))
        XCTAssertEqual(viewport.origin, .zero)
        XCTAssertEqual(viewport.visibleRect, CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(viewport.displayPoint(forViewPoint: CGPoint(x: 639.5, y: 479.5)),
                       CGPoint(x: 639.5, y: 479.5))
        for point in [CGPoint(x: 640, y: 0), CGPoint(x: 0, y: 480),
                      CGPoint(x: 1000, y: 700), CGPoint(x: -1, y: 100)] {
            XCTAssertNil(viewport.displayPoint(forViewPoint: point))
        }
        viewport.pan(delta: CGPoint(x: 500, y: 500))
        viewport.page(direction: 1)
        XCTAssertEqual(viewport.origin, .zero)
        XCTAssertEqual(viewport.scale, 1)
    }

    func testPointsOutsideViewportCannotReachOtherwiseValidDisplayContent() {
        let viewport = ActionMonitorViewport(displaySize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 1000, height: 600), origin: CGPoint(x: 1000, y: 200))
        for point in [CGPoint(x: 1000, y: 0), CGPoint(x: 0, y: 600),
                      CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1),
                      CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            XCTAssertNil(viewport.displayPoint(forViewPoint: point))
        }
        XCTAssertEqual(viewport.displayPoint(forViewPoint: .zero), CGPoint(x: 1000, y: 200))
    }

    func testInvalidGeometryIsFiniteEmptyAndInvalidPansAreIgnored() {
        var viewport = ActionMonitorViewport(displaySize: CGSize(width: CGFloat.nan, height: -20),
            viewportSize: CGSize(width: CGFloat.infinity, height: -1), origin: CGPoint(x: CGFloat.infinity, y: CGFloat.nan))
        XCTAssertEqual(viewport.displaySize, .zero)
        XCTAssertEqual(viewport.viewportSize, .zero)
        XCTAssertEqual(viewport.visibleRect, .zero)
        XCTAssertNil(viewport.displayPoint(forViewPoint: .zero))

        viewport.update(displaySize: CGSize(width: 3440, height: 1440),
                        viewportSize: CGSize(width: 1000, height: 600))
        viewport.pan(delta: CGPoint(x: 200, y: 100))
        let valid = viewport
        viewport.pan(delta: CGPoint(x: CGFloat.nan, y: 10))
        viewport.pan(delta: CGPoint(x: 10, y: CGFloat.infinity))
        XCTAssertEqual(viewport, valid)
        viewport.pan(delta: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(viewport.origin, CGPoint(x: 2440, y: 840))
        XCTAssertEqual(viewport.scale, 1)
    }
}
