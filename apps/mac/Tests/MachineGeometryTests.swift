import XCTest
@testable import Lattices

final class MachineGeometryTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    func testTwoMachinesShareEdgeAndNormalizeOwnSpan() {
        let machines = [("a", CGRect(x: 2000, y: 0, width: 1000, height: 600)),
                        ("b", CGRect(x: 2000, y: 600, width: 1000, height: 600))]
        let first = MachineGeometry.owner(at: CGPoint(x: 1999, y: 300), side: .right, display: display, machines: machines)
        XCTAssertEqual(first?.0, "a"); XCTAssertEqual(first?.1.fraction(CGPoint(x: 1999, y: 300)), 0.5)
        XCTAssertEqual(MachineGeometry.owner(at: CGPoint(x: 1999, y: 600), side: .right, display: display, machines: machines)?.0, "b")
        XCTAssertNil(MachineGeometry.owner(at: CGPoint(x: 1999, y: 1200), side: .right, display: display, machines: machines))
    }
    func testGapOverlapAndCornerAreNotContact() {
        for r in [CGRect(x: 2010, y: 0, width: 100, height: 100),
                  CGRect(x: 1900, y: 0, width: 200, height: 100),
                  CGRect(x: 2000, y: 1200, width: 100, height: 100)] {
            XCTAssertTrue(MachineGeometry.contacts(display: display, machine: r).isEmpty)
        }
    }
    func testMigrationUsesOutermostDisplayAndNegativeCoordinates() {
        let left = CGRect(x: -1400, y: -200, width: 1400, height: 900)
        let r = MachineGeometry.migrate(side: .left, displays: [display, left], size: CGSize(width: 800, height: 600))
        XCTAssertEqual(r, CGRect(x: -2200, y: -50, width: 800, height: 600))
        for side in VisitTrust.Side.allCases {
            let r = MachineGeometry.migrate(side: side, displays: [display])
            XCTAssertEqual(MachineGeometry.contacts(display: display, machine: r).first?.side, side)
        }
    }
    func testSnapAndNoSnapBeyondTolerance() {
        let r = CGRect(x: 2012, y: 300, width: 800, height: 500)
        XCTAssertEqual(MachineGeometry.snap(r, to: [display], tolerance: 20).minX, 2000)
        XCTAssertEqual(MachineGeometry.snap(r, to: [display], tolerance: 5), r)
    }
    func testMonitorDescriptionIncludesVirtualOutput() {
        let result = MachineArrangementStore.parseMonitors([
            ["name": "HDMI-A-1", "frame": ["x": 0.0, "y": 0.0, "w": 3440.0, "h": 1440.0]],
            ["name": "LATS-1", "frame": ["x": 3440.0, "y": 0.0, "w": 1920.0, "h": 1080.0]]])
        XCTAssertEqual(result.map(\.name), ["HDMI-A-1", "LATS-1"])
        XCTAssertEqual(result.last?.frame.width, 1920)
    }
    func testAddHostPreservesOtherEntriesAndRejectsCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hosts.json")
        try MachineArrangementStore.addHost(name: "a", address: "a", file: file)
        try MachineArrangementStore.addHost(name: "b", address: "b", file: file)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual((root["hosts"] as? [String: Any])?.count, 2)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try MachineArrangementStore.addHost(name: "c", address: "c", file: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
}
