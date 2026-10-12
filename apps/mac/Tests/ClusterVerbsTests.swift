import XCTest
@testable import Lattices

final class ClusterVerbsTests: XCTestCase {
    private var screens: [DisplayGather.Screen] {
        (1...3).map { i in .init(index: i, id: "\(i)", name: i == 2 ? "DELL U32" : "Screen \(i)",
            frame: CGRect(x: (i - 1) * 100, y: 0, width: 100, height: 100), visible: .zero, isMain: i == 1) }
    }
    func testBringComposesEachOtherDisplayAndUndo() throws {
        let api = LatticesApi(); let inventory = screens
        ClusterVerbs.register(api, screens: { inventory })
        var calls: [JSON?] = []
        api.register(Endpoint(method: "display.gather", description: "fixture", access: .mutate, params: [], returns: .ok, handler: { calls.append($0); return .object(["moved": .int(1)]) }))
        api.register(Endpoint(method: "display.restore", description: "fixture", access: .mutate, params: [], returns: .ok, handler: { calls.append($0); return .object(["ok": .bool(true)]) }))
        _ = try api.dispatch(method: "bring", params: .object(["display": .string("dell")]))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]?["display"]?.intValue, 1)
        XCTAssertEqual(calls[1]?["display"]?.intValue, 3)
        XCTAssertEqual(calls[0]?["to"]?.intValue, 2)
        calls.removeAll()
        XCTAssertThrowsError(try api.dispatch(method: "bring", params: .object(["display": .string("missing")])))
        XCTAssertTrue(calls.isEmpty)
        _ = try api.dispatch(method: "bring", params: .object(["undo": .bool(true)]))
        XCTAssertEqual(calls.count, 1); XCTAssertNil(calls[0])
    }
    func testMainKeepOnlyAfterSuccessfulTrialAndAliases() throws {
        let api = LatticesApi(); ClusterVerbs.register(api, screens: { [] })
        var methods: [String] = []; var received: JSON?
        for method in ["visit.main", "visit.arrangement.keep", "visit.elsewhere", "mouse.home"] {
            api.register(Endpoint(method: method, description: "fixture", access: .mutate, params: [], returns: .ok, handler: { p in
                methods.append(method); received = p
                if p?["screen"]?.stringValue == "bad" { throw RouterError.notFound("fixture") }
                return .object(["ok": .bool(true)])
            }))
        }
        _ = try api.dispatch(method: "main", params: .object(["display": .string("dell"), "keep": .bool(true)]))
        XCTAssertEqual(methods, ["visit.main", "visit.arrangement.keep"])
        methods.removeAll()
        XCTAssertThrowsError(try api.dispatch(method: "main", params: .object(["display": .string("bad"), "keep": .bool(true)])))
        XCTAssertEqual(methods, ["visit.main"])
        _ = try api.dispatch(method: "here", params: .object(["display": .int(2)]))
        XCTAssertEqual(received?["screen"]?.intValue, 2); XCTAssertEqual(received?["on"]?.boolValue, false)
        _ = try api.dispatch(method: "home", params: nil); XCTAssertEqual(methods.last, "mouse.home")
    }
    func testSharedResolverAndTouchingMidpoint() throws {
        XCTAssertEqual(try DisplayGather.resolve(.string("u32"), "display", among: screens).index, 2)
        XCTAssertEqual(try DisplayGather.resolve(.int(3), "display", among: screens).index, 3)
        XCTAssertThrowsError(try DisplayGather.resolve(.double(.infinity), "display", among: screens))
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        let machine = CGRect(x: 100, y: 30, width: 100, height: 40)
        let entry = try XCTUnwrap(MachineGeometry.entry(displays: [display], machine: machine))
        XCTAssertEqual(entry.side, .right); XCTAssertEqual(entry.point.y, 50)
        let contact = try XCTUnwrap(MachineGeometry.contacts(display: display, machine: machine).first)
        XCTAssertEqual(contact.fraction(entry.point), 0.5)
        XCTAssertNil(MachineGeometry.entry(displays: [display], machine: machine.offsetBy(dx: 10, dy: 0)))
    }
    func testBuildOrderingDoesNotTreatUnknownOrDifferentCommitsAsOlder() {
        XCTAssertTrue(MachineBuild.behind("0.12.9", local: "0.13.3"))
        XCTAssertFalse(MachineBuild.behind("0.13.3", local: "0.13.3"))
        XCTAssertFalse(MachineBuild.behind(nil, local: "0.13.3"))
        XCTAssertFalse(MachineBuild.behind("0.14.0", local: "0.13.3"))
    }
    func testGeneratedCommandsUseCurrentInventory() {
        let rows = BrowseMenu.machinesSection(screens: screens, hosts: [])
        XCTAssertTrue(rows.contains { $0.title == "Bring everything to DELL U32" })
        XCTAssertTrue(rows.contains { $0.title == "Make DELL U32 main" })
        XCTAssertEqual(rows.filter { $0.title.hasPrefix("Bring everything") }.count, 3)
    }
}
