import XCTest
@testable import Lattices

final class AppWindowShellTests: XCTestCase {
    func testCentersOnTheGivenScreenAboveMiddle() {
        // The U32 sits left of the DELL in global coordinates.
        let u32 = NSRect(x: -3840, y: -324, width: 3840, height: 2135)
        let frame = AppWindowShell.centeredFrame(size: NSSize(width: 1760, height: 760), in: u32)
        XCTAssertEqual(frame.midX, u32.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, u32.midY + u32.height * 0.08, accuracy: 0.5)
        XCTAssertEqual(frame.size, NSSize(width: 1760, height: 760))
    }

    func testClampsToTheScreen() {
        let small = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let frame = AppWindowShell.centeredFrame(size: NSSize(width: 1760, height: 760), in: small)
        XCTAssertEqual(frame.width, 920, accuracy: 0.5)
        XCTAssertEqual(frame.height, 510, accuracy: 0.5)
    }
}
