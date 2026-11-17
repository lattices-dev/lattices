import CoreGraphics
import XCTest
import LatticesLayoutKit

final class WindowGridPlannerTests: XCTestCase {
    private typealias Planner = WindowGridPlanner

    func testEmptyAndSingleWindow() {
        XCTAssertTrue(Planner.shape(for: 0).isEmpty)
        XCTAssertTrue(Planner.normalizedSlots(count: 0).isEmpty)
        XCTAssertTrue(Planner.normalizedSlots(count: -1).isEmpty)
        assertFrames(Planner.normalizedSlots(count: 1), [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testExistingSmartGridShapesRemainStable() {
        let shapes = [[1], [2], [3], [2, 2], [3, 2], [3, 3], [4, 3],
                      [4, 4], [3, 3, 3], [5, 5], [4, 4, 3], [4, 4, 4], [5, 5, 3]]
        for (index, shape) in shapes.enumerated() {
            XCTAssertEqual(Planner.shape(for: index + 1), shape)
        }
    }

    func testThreeWindowsAreOrderedFullHeightColumns() {
        assertFrames(Planner.normalizedSlots(count: 3), [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1),
            CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
            CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1),
        ])
    }

    func testFiveWindowsFillBothRowsInRowMajorOrder() {
        assertFrames(Planner.normalizedSlots(count: 5), [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 0.5),
            CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 0.5),
            CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ])
    }

    func testTwelveWindowsFillThreeRowsWithoutGapsOrOverlap() {
        let slots = Planner.normalizedSlots(count: 12)
        XCTAssertEqual(slots.count, 12)
        for (index, slot) in slots.enumerated() {
            assertFrames([slot], [CGRect(x: CGFloat(index % 4) / 4,
                                         y: CGFloat(index / 4) / 3,
                                         width: 0.25, height: 1.0 / 3)])
        }
        XCTAssertEqual(slots.reduce(0) { $0 + $1.width * $1.height }, 1, accuracy: 1e-9)
    }

    func testSlotsProjectIntoAnOffsetDisplayAreaWithoutInsets() {
        assertFrames(Planner.slots(count: 3, in: CGRect(x: -1440, y: -500, width: 1200, height: 900)), [
            CGRect(x: -1440, y: -500, width: 400, height: 900),
            CGRect(x: -1040, y: -500, width: 400, height: 900),
            CGRect(x: -640, y: -500, width: 400, height: 900),
        ])
    }

    func testFractionalRegionAndExplicitShapeUseTopLeftCoordinates() {
        let area = CGRect(x: -1440, y: 30, width: 1200, height: 900)
        let region = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        assertFrames(Planner.slots(count: 3, in: area, region: region, shape: [1, 2]), [
            CGRect(x: -1140, y: 210, width: 600, height: 270),
            CGRect(x: -1140, y: 480, width: 300, height: 270),
            CGRect(x: -840, y: 480, width: 300, height: 270),
        ])
    }

    func testInvalidShapeFallsBackToSmartGrid() {
        let expected = Planner.normalizedSlots(count: 3)
        for shape in [[], [1, 1], [4], [0, 3], [-1, 4]] {
            assertFrames(Planner.normalizedSlots(count: 3, shape: shape), expected)
        }
        XCTAssertTrue(Planner.normalizedSlots(count: 0, shape: [1]).isEmpty)
    }

    private func assertFrames(
        _ actual: [CGRect],
        _ expected: [CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, file: file, line: line)
        }
    }
}
