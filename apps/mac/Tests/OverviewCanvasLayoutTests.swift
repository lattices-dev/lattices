import XCTest
@testable import Lattices

final class OverviewCanvasLayoutTests: XCTestCase {
    func testSixteenDesktopsFormConnectedFourByFour() {
        let layout = OverviewCanvasLayout(counts: [16], aspects: [1.6])
        XCTAssertEqual(layout.cells.count, 16)
        XCTAssertEqual(layout.size, CGSize(width: 1600, height: 1000))
        for (index, cell) in layout.cells.enumerated() {
            if index % 4 > 0 { XCTAssertEqual(cell.frame.minX, layout.cells[index - 1].frame.maxX) }
            if index >= 4 { XCTAssertEqual(cell.frame.minY, layout.cells[index - 4].frame.maxY) }
        }
    }

    func testEachMonitorKeepsItsOwnGridAndIdentity() {
        let layout = OverviewCanvasLayout(counts: [1, 16, 0, 2], aspects: [2, 1.6, 1.6, 1])
        XCTAssertEqual(layout.cells.count, 19)
        XCTAssertEqual(Set(layout.cells.map(\.id)).count, 19)
        XCTAssertEqual(layout.cells[1].monitor, 1)
        XCTAssertEqual(layout.cells[17].monitor, 3)
        XCTAssertGreaterThan(layout.cells[1].frame.minX, layout.cells[0].frame.maxX)
        XCTAssertGreaterThan(layout.cells[17].frame.minX, layout.cells[16].frame.maxX)
        for cell in layout.cells { XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(cell.frame)) }
    }

    func testClipsGlobalWindowFramesOnNegativeOriginMonitor() throws {
        let display = CGRect(x: -2000, y: -500, width: 2000, height: 1000)
        let cell = CGRect(x: 400, y: 250, width: 400, height: 200)
        let rect = try XCTUnwrap(OverviewCanvasLayout.window(
            CGRect(x: -2200, y: -500, width: 1200, height: 500), display: display, cell: cell))
        XCTAssertEqual(rect, CGRect(x: 400, y: 250, width: 200, height: 100))
        XCTAssertNil(OverviewCanvasLayout.window(CGRect(x: 20, y: 20, width: 10, height: 10), display: display, cell: cell))
        XCTAssertNil(OverviewCanvasLayout.window(display, display: .zero, cell: cell))
    }

    func testOneThroughSixteenFitWithoutDroppingDesktops() {
        for count in 1...16 {
            let layout = OverviewCanvasLayout(counts: [count], aspects: [1.6])
            let room = CGSize(width: 600, height: 300)
            let scale = layout.fit(in: room)
            XCTAssertEqual(layout.cells.count, count)
            XCTAssertLessThanOrEqual(layout.size.width * scale, room.width)
            XCTAssertLessThanOrEqual(layout.size.height * scale, room.height)
        }
        XCTAssertTrue(OverviewCanvasLayout(counts: [], aspects: []).cells.isEmpty)
    }
}
