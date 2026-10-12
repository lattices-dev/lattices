import CoreGraphics
import XCTest
@testable import Lattices

final class LayerPreviewEscapeTests: XCTestCase {
    func testDesktopNavigationPassesThroughTheFrozenPreview() {
        for key: Int64 in [123, 124, 125, 126] {
            XCTAssertTrue(LayerPreview.passesSystemNavigation(key: key, flags: .maskControl))
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: []))
            XCTAssertFalse(LayerPreview.passesSystemNavigation(key: key, flags: [.maskCommand, .maskAlternate]))
        }
    }

    func testAppSwitcherAndForceQuitRemainAvailable() {
        XCTAssertTrue(LayerPreview.passesSystemNavigation(key: 48, flags: .maskCommand))
        XCTAssertTrue(LayerPreview.passesSystemNavigation(key: 48, flags: [.maskCommand, .maskShift]))
        XCTAssertTrue(LayerPreview.passesSystemNavigation(key: 53, flags: [.maskCommand, .maskAlternate]))
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 48, flags: []))
        XCTAssertFalse(LayerPreview.passesSystemNavigation(key: 53, flags: .maskShift))
    }
}
