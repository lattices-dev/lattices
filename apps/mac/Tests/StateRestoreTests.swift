import XCTest
@testable import Lattices

final class StateRestoreTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double = 0) -> StateMap.Rect { .init(x: x, y: y, w: 800, h: 600) }

    private let dellThen = StateMap.Display(id: "DELL", name: "Dell", frame: .init(x: 3840, y: 0, w: 3440, h: 1440), main: true, desktops: [10, 11, 12], current: 10)

    private func map(_ windows: [StateMap.Window]) -> StateMap {
        StateMap(id: "m", taken: Date(), name: nil, displays: [dellThen], windows: windows, layer: nil)
    }

    private func saved(_ wid: UInt32, _ app: String, title: String = "", session: String? = nil, desktop: Int, x: Double) -> StateMap.Window {
        .init(wid: wid, app: app, bundleId: nil, title: title, session: session, frame: rect(x), desktops: [desktop], hidden: false)
    }

    private func open(_ wid: UInt32, _ app: String, title: String = "", session: String? = nil, desktop: Int, x: Double) -> StateRestore.Live.Window {
        .init(wid: wid, pid: 1, app: app, title: title, session: session, frame: rect(x), desktops: [desktop])
    }

    /// After a reboot: new desktop ids, the Dell moved left, no longer main.
    private func dellNow(desktops: [Int] = [20, 21, 22]) -> StateMap.Display {
        .init(id: "DELL", name: "Dell", frame: .init(x: 0, y: 0, w: 3440, h: 1440), main: false, desktops: desktops, current: desktops[0])
    }

    func testCarriesByPositionAndShiftsWithTheDisplay() {
        let plan = StateRestore.plan(
            map([saved(5, "Ghostty", session: "fab", desktop: 11, x: 3900)]),
            live: .init(displays: [dellNow()], windows: [open(99, "Ghostty", session: "fab", desktop: 20, x: 10)])
        )
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(plan.moves[0].wid, 99)
        XCTAssertEqual(plan.moves[0].carryTo, 21)
        XCTAssertEqual(plan.moves[0].frame.x, 60)
        XCTAssertTrue(plan.notes.contains { $0.contains("main display") })
    }

    func testLeavesWindowsThatAreAlreadyRight() {
        let plan = StateRestore.plan(
            map([saved(5, "Ghostty", desktop: 10, x: 3900)]),
            live: .init(displays: [dellNow()], windows: [open(5, "Ghostty", desktop: 20, x: 60)])
        )
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testFewerDesktopsGoToTheLastOne() {
        let plan = StateRestore.plan(
            map([saved(5, "Safari", desktop: 12, x: 3840)]),
            live: .init(displays: [dellNow(desktops: [20])], windows: [open(5, "Safari", desktop: 20, x: 500)])
        )
        XCTAssertNil(plan.moves.first?.carryTo)
        XCTAssertTrue(plan.notes.contains { $0.contains("had 3 desktops, now 1") })
    }

    func testMissingAndAmbiguousWindows() {
        let plan = StateRestore.plan(
            map([saved(1, "Notes", title: "todo", desktop: 10, x: 3840), saved(2, "Ghostty", title: "a", desktop: 10, x: 3840)]),
            live: .init(displays: [dellNow()], windows: [open(7, "Ghostty", title: "b", desktop: 20, x: 0), open(8, "Ghostty", title: "c", desktop: 20, x: 0)])
        )
        XCTAssertEqual(plan.missing.sorted(), ["Ghostty: a", "Notes: todo"])
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testEachLiveWindowIsUsedOnce() {
        let plan = StateRestore.plan(
            map([saved(1, "Ghostty", title: "x", desktop: 10, x: 3840), saved(2, "Ghostty", title: "x", desktop: 11, x: 3840)]),
            live: .init(displays: [dellNow()], windows: [open(7, "Ghostty", title: "x", desktop: 22, x: 0)])
        )
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(plan.missing.count, 1)
    }
}

extension StateRestoreTests {
    func testAWindowKeepsItsIdEvenIfAClosedOneHadItsTitle() {
        let plan = StateRestore.plan(
            map([saved(191, "Ghostty", title: "talkie", desktop: 10, x: 3840), saved(193, "Ghostty", title: "lattices", desktop: 10, x: 3854)]),
            live: .init(displays: [dellNow()], windows: [open(193, "Ghostty", title: "talkie", desktop: 20, x: 14)])
        )
        XCTAssertEqual(plan.missing, ["Ghostty: talkie"])
        XCTAssertTrue(plan.moves.isEmpty)
    }
}
