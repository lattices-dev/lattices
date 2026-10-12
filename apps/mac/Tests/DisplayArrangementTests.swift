import XCTest
@testable import Lattices

@MainActor
final class DisplayArrangementTests: XCTestCase {
    func testApplyThenTimeoutRestoresOriginalAndKeepCancelsTrial() throws {
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let moved = old.offsetBy(dx: 1000, dy: 0)
        var writes: [[UInt32: CGPoint]] = []
        var timeout: (() -> Void)?
        let trial = DisplayArrangement(readScreens: {
            [.init(number: 1, name: "Fixture", frame: old, main: true, elsewhere: false, displayID: 42)]
        }, configure: { writes.append($0) }, schedule: { seconds, action in
            XCTAssertEqual(seconds, 15); timeout = action; return Timer()
        })
        XCTAssertTrue(writes.isEmpty)
        try trial.apply([42: moved])
        XCTAssertEqual(writes, [[42: moved.origin]])
        XCTAssertTrue(trial.pending)
        XCTAssertThrowsError(try trial.apply([42: old]))
        timeout?()
        XCTAssertEqual(writes.last, [42: old.origin]); XCTAssertFalse(trial.pending)
        try trial.apply([42: moved]); trial.keep(); timeout?()
        XCTAssertEqual(writes.count, 3); XCTAssertFalse(trial.pending)
    }
    func testTopologyChangeAndApplyFailureDoNotStartTrial() {
        let screen = VisitController.Screen(number: 1, name: "Fixture", frame: CGRect(x: 0, y: 0, width: 100, height: 100), main: true, elsewhere: false, displayID: 1)
        var count = 0
        let trial = DisplayArrangement(readScreens: { [screen] }, configure: { _ in count += 1; throw VisitTrust.Failure.bad("fixture") })
        XCTAssertThrowsError(try trial.apply([2: screen.frame])); XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try trial.apply([1: screen.frame])); XCTAssertEqual(count, 1)
        XCTAssertFalse(trial.pending); trial.revert(); XCTAssertEqual(count, 1)
    }
}

@MainActor
final class ClusterMainTrialTests: XCTestCase {
    func testMainTrialShiftsOnceAndRejectsAnotherMainUntilResolved() throws {
        let screens: [VisitController.Screen] = [
            .init(number: 0, name: "Main", frame: CGRect(x: 0, y: 0, width: 100, height: 100), main: true, elsewhere: false, displayID: 1),
            .init(number: 1, name: "DELL", frame: CGRect(x: 100, y: 30, width: 100, height: 100), main: false, elsewhere: false, displayID: 2),
        ]
        var shifts: [CGPoint] = []; var writes: [[UInt32: CGPoint]] = []; var timeout: (() -> Void)?
        let trial = DisplayArrangement(readScreens: { screens }, shiftMachines: { shifts.append(CGPoint(x: $0, y: $1)) },
            configure: { writes.append($0) }, schedule: { seconds, action in XCTAssertEqual(seconds, 15); timeout = action; return Timer() })
        try trial.makeMain(1)
        XCTAssertEqual(writes[0][2], .zero)
        XCTAssertEqual(shifts, [CGPoint(x: -100, y: -30)])
        XCTAssertThrowsError(try trial.makeMain(0))
        timeout?()
        XCTAssertEqual(writes.last?[2], CGPoint(x: 100, y: 30))
        XCTAssertEqual(shifts.last, CGPoint(x: 100, y: 30))
        try trial.makeMain(1); trial.keep(); let count = writes.count; timeout?()
        XCTAssertEqual(writes.count, count)
        XCTAssertFalse(trial.pending)
    }
}
