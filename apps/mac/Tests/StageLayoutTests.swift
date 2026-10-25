import CoreGraphics
import XCTest
@testable import Lattices

final class StageLayoutTests: XCTestCase {
    func testSixWindowsReadAsThreeByTwo() {
        let homes = StageLayout.homes(count: 6)
        XCTAssertEqual(homes.count, 6)
        assertClose(homes[0], CGRect(x: 0, y: 0, width: 1.0 / 3, height: 0.5))
        assertClose(homes[1], CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 0.5))
        assertClose(homes[3], CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5))
        assertClose(homes[5], CGRect(x: 2.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5))
    }

    func testShortLastRowIsCentered() {
        let homes = StageLayout.homes(count: 5)
        XCTAssertEqual(homes[3].minX, homes[4].minX - homes[4].width, accuracy: 0.001)
        XCTAssertGreaterThan(homes[3].minX, 0)
        XCTAssertLessThan(homes[4].maxX, 1)
    }

    func testEngagedWindowTakesFortyPercentAndStaysOnScreen() {
        let frames = StageLayout.frames(count: 6, active: 0)
        XCTAssertEqual(frames[0].width, StageLayout.activeWidth, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, StageLayout.activeHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frames[0].minX, 0)
        XCTAssertGreaterThanOrEqual(frames[0].minY, 0)
        XCTAssertLessThanOrEqual(frames[0].maxX, 1.001)
        XCTAssertLessThanOrEqual(frames[0].maxY, 1.001)
    }

    func testCenterWindowGrowsFromItsOwnCell() {
        let frames = StageLayout.frames(count: 6, active: 1)
        XCTAssertEqual(frames[1].midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(frames[1].width, 0.40, accuracy: 0.001)
        XCTAssertLessThan(frames[0].width, 1.0 / 3)
        XCTAssertLessThan(frames[2].width, 1.0 / 3)
    }

    func testOneWindowStillTakesTheStage() {
        let frames = StageLayout.frames(count: 1, active: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].width, StageLayout.activeWidth, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, StageLayout.activeHeight, accuracy: 0.001)
        XCTAssertEqual(frames[0].midX, 0.5, accuracy: 0.001)
    }

    func testNoWindowsHaveNoCells() {
        XCTAssertEqual(StageLayout.homes(count: 0).count, 0)
        XCTAssertEqual(StageLayout.frames(count: 0, active: 0).count, 0)
    }

    func testRestingWindowsShrinkInsideTheirCells() {
        let homes = StageLayout.homes(count: 6)
        let frames = StageLayout.frames(count: 6, active: 4)
        XCTAssertEqual(frames[4].width, StageLayout.activeWidth, accuracy: 0.001)
        for index in [0, 1, 2, 3, 5] {
            XCTAssertLessThan(frames[index].width, homes[index].width)
            XCTAssertLessThan(frames[index].height, homes[index].height)
            XCTAssertGreaterThan(frames[index].midX, homes[index].minX)
            XCTAssertLessThan(frames[index].midX, homes[index].maxX)
        }
    }

    private func assertClose(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.001) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy)
    }
}
