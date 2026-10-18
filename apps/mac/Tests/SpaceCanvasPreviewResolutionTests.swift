import CoreGraphics
import XCTest
@testable import Lattices

final class SpaceCanvasPreviewResolutionTests: XCTestCase {
    func testWideDesktopUsesItsActualDisplayPixels() {
        let limits = SpaceCanvasPreviewLoader.detailPixelLimits(windows: [window(1)],
            displayPixelSize: CGSize(width: 3440, height: 1440))
        XCTAssertEqual(limits[1], 3440)
    }

    func testRetinaHalfWindowsKeepNativeDensity() {
        let windows = [window(1, width: 0.5), window(2, width: 0.5)]
        let limits = SpaceCanvasPreviewLoader.detailPixelLimits(windows: windows,
            displayPixelSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(limits[1], 2160)
        XCTAssertEqual(limits[2], 2160)
    }

    func testClippedWindowRequestsEnoughPixelsForItsFullSource() {
        var clipped = window(1, width: 0.5)
        clipped.contentsRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let limits = SpaceCanvasPreviewLoader.detailPixelLimits(windows: [clipped],
            displayPixelSize: CGSize(width: 3440, height: 1440))
        XCTAssertEqual(limits[1], 3440)
    }

    func testOverlapping4KWindowsShareTheExistingCacheBudget() {
        let limits = SpaceCanvasPreviewLoader.detailPixelLimits(windows: (1...6).map { window(UInt32($0)) },
            displayPixelSize: CGSize(width: 3840, height: 2160))
        let bytes = limits.values.reduce(CGFloat(0)) { $0 + $1 * $1 * (2160.0 / 3840) * 4 }
        XCTAssertLessThan(bytes, CGFloat(SpaceCanvasPreviewLoader.maximumCacheBytes) * 0.92)
        XCTAssertTrue(limits.values.allSatisfy { $0 > 1440 && $0 < 3840 })
    }

    func testInvalidGeometryIsIgnoredAndExtremeResolutionIsBounded() {
        XCTAssertTrue(SpaceCanvasPreviewLoader.detailPixelLimits(windows: [window(1)],
            displayPixelSize: .zero).isEmpty)
        var invalid = window(2)
        invalid.contentsRect = .zero
        let limits = SpaceCanvasPreviewLoader.detailPixelLimits(windows: [window(0), invalid, window(1)],
            displayPixelSize: CGSize(width: 7680, height: 2160))
        XCTAssertEqual(Set(limits.keys), [1])
        XCTAssertEqual(limits[1], 4096)
    }

    private func window(_ id: UInt32, width: CGFloat = 1) -> SpaceFilmstripWindow {
        var window = SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0, width: width, height: 1), app: "Test", pid: 100)
        window.wid = id
        return window
    }
}
