import AppKit
import XCTest
@testable import Lattices

final class SpaceCanvasWallpaperTests: XCTestCase {
    func testFillCropsSymmetricallyAndFitLeavesEqualMargins() {
        let image = CGSize(width: 1920, height: 1080)
        let display = CGSize(width: 3440, height: 1440)
        let fill = SpaceCanvasWallpaper.imageRect(image: image, display: display,
                                                  scaling: .scaleProportionallyUpOrDown, clipping: true)
        XCTAssertEqual(fill.width, 3440, accuracy: 0.001)
        XCTAssertEqual(fill.midX, 1720, accuracy: 0.001)
        XCTAssertEqual(fill.midY, 720, accuracy: 0.001)
        XCTAssertLessThan(fill.minY, 0)
        let fit = SpaceCanvasWallpaper.imageRect(image: image, display: display,
                                                 scaling: .scaleProportionallyUpOrDown, clipping: false)
        XCTAssertEqual(fit, CGRect(x: 440, y: 0, width: 2560, height: 1440))
    }

    func testCenterAndStretchHonorDesktopImageOptions() {
        let image = CGSize(width: 640, height: 480)
        let display = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(SpaceCanvasWallpaper.imageRect(image: image, display: display,
            scaling: .scaleNone, clipping: true), CGRect(x: 640, y: 300, width: 640, height: 480))
        XCTAssertEqual(SpaceCanvasWallpaper.imageRect(image: image, display: display,
            scaling: .scaleAxesIndependently, clipping: false), CGRect(origin: .zero, size: display))
        XCTAssertEqual(SpaceCanvasWallpaper.imageRect(image: image, display: display,
            scaling: .scaleProportionallyDown, clipping: false), CGRect(x: 640, y: 300, width: 640, height: 480))
    }

    func testRecognizedGlobalAerialAndDisplayOverride() throws {
        let global = "B004358B-5A27-42E5-B49E-93FC100B2371"
        let display = "A004358B-5A27-42E5-B49E-93FC100B2371"
        let store = try data(["AllSpacesAndDisplays": entry(global),
                              "Displays": ["screen": entry(display)], "Spaces": [:]])
        XCTAssertEqual(SpaceCanvasWallpaper.aerialAssetID(in: store, displayUUID: nil), global)
        XCTAssertEqual(SpaceCanvasWallpaper.aerialAssetID(in: store, displayUUID: "screen"), display)
    }

    func testUnknownDisplayProviderNeverFallsBackToDifferentGlobalWallpaper() throws {
        let store = try data(["AllSpacesAndDisplays": entry("B004358B-5A27-42E5-B49E-93FC100B2371"),
                              "Displays": ["screen": entry("unused", provider: "com.apple.wallpaper.choice.image")]])
        XCTAssertNil(SpaceCanvasWallpaper.aerialAssetID(in: store, displayUUID: "screen"))
    }

    func testPerSpaceAndMalformedSettingsUsePublicAPIFallback() throws {
        let entry = try entry("B004358B-5A27-42E5-B49E-93FC100B2371")
        XCTAssertNil(SpaceCanvasWallpaper.aerialAssetID(in: try data([
            "AllSpacesAndDisplays": entry, "Spaces": ["unknown-space": entry]]), displayUUID: nil))
        XCTAssertNil(SpaceCanvasWallpaper.aerialAssetID(in: try data([
            "AllSpacesAndDisplays": self.entry("../../other")]), displayUUID: nil))
        XCTAssertNil(SpaceCanvasWallpaper.aerialAssetID(in: Data("not a plist".utf8), displayUUID: nil))
    }

    private func entry(_ asset: String, provider: String = "com.apple.wallpaper.choice.aerials") throws -> [String: Any] {
        ["Desktop": ["Content": ["Choices": [["Provider": provider,
            "Configuration": try data(["assetID": asset])]]]]]
    }

    private func data(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
