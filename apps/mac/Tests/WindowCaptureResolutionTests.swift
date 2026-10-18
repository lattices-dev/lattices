import CoreGraphics
import XCTest
@testable import Lattices

final class WindowCaptureResolutionTests: XCTestCase {
    func testWideNonRetinaWindowRetainsNativePixels() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 3440, height: 1440), pointPixelScale: 1,
            maximumPixelSize: 3840), CGSize(width: 3440, height: 1440))
    }

    func testRetinaWindowUsesTwoPixelsPerPoint() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 1728, height: 1117), pointPixelScale: 2,
            maximumPixelSize: 3840), CGSize(width: 3456, height: 2234))
    }

    func testSmallWindowsAreNotUpscaledToTheLimit() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 800, height: 600), pointPixelScale: 1,
            maximumPixelSize: 3840), CGSize(width: 800, height: 600))
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 800, height: 600), pointPixelScale: 2,
            maximumPixelSize: 3840), CGSize(width: 1600, height: 1200))
    }

    func testPixelLimitPreservesLandscapeAndPortraitProportions() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 2560, height: 1440), pointPixelScale: 2,
            maximumPixelSize: 3840), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 1440, height: 2560), pointPixelScale: 2,
            maximumPixelSize: 1440), CGSize(width: 810, height: 1440))
    }

    func testNominalThumbnailKeepsExistingPixelLimit() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 3440, height: 1440), pointPixelScale: 1,
            maximumPixelSize: 480), CGSize(width: 480, height: 201))
    }

    func testInvalidOrFractionalInputsProduceBoundedWholePixels() {
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: .zero, pointPixelScale: 2, maximumPixelSize: 3840),
                       CGSize(width: 1, height: 1))
        XCTAssertEqual(WindowCapture.thumbnailPixelSize(
            pointSize: CGSize(width: 100, height: 50), pointPixelScale: .nan,
            maximumPixelSize: 79.5), CGSize(width: 79, height: 40))
    }
}
