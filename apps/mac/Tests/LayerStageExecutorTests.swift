import Foundation
import XCTest
@testable import Lattices

final class LayerStageExecutorTests: XCTestCase {
    private enum DiskFailure: Error { case unwritable }

    private final class Desk {
        var events: [String] = []
        var durable = LayerStage.State()
        var writes = 0
        var failWrites: Set<Int> = []
        var parkResult = LayerStageExecutor.ParkResult()
        var restored = Set<UInt32>()
        var failedUnhides = Set<Int32>()
        var unavailableApps = Set<Int32>()
        var prepared: LayerStage.State?

        var environment: LayerStageExecutor.Environment {
            .init(
                write: { state in
                    self.writes += 1
                    self.events.append("write")
                    if self.failWrites.contains(self.writes) { throw DiskFailure.unwritable }
                    self.durable = state
                    if self.writes == 1 { self.prepared = state }
                },
                unhide: { pid in
                    self.events.append("unhide:\(pid)")
                    if self.unavailableApps.contains(pid) { return .unavailable }
                    return self.failedUnhides.contains(pid) ? .failed("app \(pid)") : .succeeded("app \(pid)")
                },
                waitForUnhide: { _ in self.events.append("wait") },
                park: { _, _ in self.events.append("park"); return self.parkResult },
                restore: { windows in
                    self.events.append("restore")
                    return self.restored.intersection(windows.map(\.wid))
                },
                hide: { pid in self.events.append("hide:\(pid)"); return .succeeded("app \(pid)") }
            )
        }
    }

    private func window(_ wid: UInt32, pid: Int32 = 10) -> LayerStage.ParkedWindow {
        .init(wid: wid, pid: pid, app: "app \(pid)", title: "window \(wid)",
              frame: WindowFrame(x: 100, y: 120, w: 800, h: 600))
    }

    private func run(
        _ desk: Desk,
        state: LayerStage.State = .init(),
        proposed: LayerStage.State? = nil,
        plan: LayerStage.Plan = .init(),
        want: Set<UInt32> = [],
        parking: [LayerStage.ParkedWindow] = []
    ) -> LayerStageExecutor.Result {
        LayerStageExecutor.execute(
            initial: state, proposed: proposed ?? state, plan: plan, want: want,
            parking: parking, origin: CGPoint(x: 1439, y: 899), environment: desk.environment
        )
    }

    func testFailedPreparationPreservesAllStateAndRunsNoEffects() {
        let desk = Desk()
        desk.failWrites = [1]
        var initial = LayerStage.State()
        initial.parked = [window(1)]
        initial.hiddenPids = [10]
        initial.scenes = ["old@1": [1, 2]]
        initial.tucked = ["old": [3]]
        initial.untucked = ["new": [4]]
        var proposed = initial
        proposed.scenes["new@1"] = [5]
        let result = run(desk, state: initial, proposed: proposed,
                         plan: .init(unhide: [10], park: [2], restore: [1], hide: [20]), parking: [window(2)])
        XCTAssertEqual(result.state, initial)
        XCTAssertEqual(desk.events, ["write"])
        XCTAssertTrue(result.outcome.blockedBeforeEffects)
        XCTAssertNotNil(result.outcome.persistenceError)
        XCTAssertTrue(result.outcome.parked.isEmpty)
        XCTAssertTrue(result.outcome.hidden.isEmpty)
    }

    func testProductionExecutorDurablyPreparesThenRunsEffectsInOrder() throws {
        let desk = Desk()
        desk.parkResult.spots = [2: CGPoint(x: 1439, y: 870)]
        desk.restored = [1]
        var initial = LayerStage.State()
        initial.parked = [window(1)]
        initial.hiddenPids = [10]
        let result = run(desk, state: initial,
                         plan: .init(unhide: [10], park: [2], restore: [1], hide: [20], hidden: [3]),
                         want: [1], parking: [window(2)])
        XCTAssertEqual(desk.events, ["write", "unhide:10", "wait", "park", "restore", "hide:20", "write"])
        let prepared = try XCTUnwrap(desk.prepared)
        XCTAssertEqual(prepared.parked.map(\.wid), [1, 2])
        XCTAssertEqual(prepared.parked.last?.pendingPark, true)
        XCTAssertEqual(prepared.hiddenPids, [10, 20])
        XCTAssertEqual(result.state.parked.map(\.wid), [2])
        XCTAssertNil(result.state.parked.first?.pendingPark)
        XCTAssertEqual(result.state.hiddenPids, [20])
        XCTAssertEqual(result.outcome.shown, [1])
        XCTAssertEqual(result.state, desk.durable)
    }

    func testReparkingKeepsOriginalHomeAndDeduplicatesTargets() throws {
        let desk = Desk()
        var initial = LayerStage.State()
        initial.parked = [window(2)]
        var replacement = window(2)
        replacement = .init(wid: replacement.wid, pid: replacement.pid, app: replacement.app,
                            title: replacement.title, frame: .init(x: 1439, y: 870, w: 800, h: 600))
        let result = run(desk, state: initial, plan: .init(park: [2]), parking: [replacement, replacement])
        XCTAssertEqual(result.state.parked.count, 1)
        XCTAssertEqual(result.state.parked.first?.frame, initial.parked.first?.frame)
        XCTAssertEqual(try XCTUnwrap(desk.prepared).parked.first?.pendingPark, true)
    }

    func testUncertainMoveKeepsFreshRecoveryIntentAcrossRestart() throws {
        let desk = Desk()
        let result = run(desk, plan: .init(park: [2]), parking: [window(2)])
        let reloaded = try JSONDecoder().decode(LayerStage.State.self, from: JSONEncoder().encode(desk.durable))
        XCTAssertEqual(result.state, reloaded)
        XCTAssertEqual(reloaded.parked.map(\.wid), [2])
        XCTAssertEqual(reloaded.parked.first?.pendingPark, true)
        let live = [UInt32(2): LayerStage.LiveWindow(pid: 10, frame: CGRect(x: 1400, y: 350, width: 800, height: 600))]
        XCTAssertEqual(LayerStage.stillParked(reloaded.parked, live: live,
                                             main: CGRect(x: 0, y: 0, width: 1440, height: 900), hidden: []).map(\.wid), [2])
    }

    func testPreparedButNeverMovedWindowIsPrunedAtItsHome() throws {
        let desk = Desk()
        _ = run(desk, plan: .init(park: [2]), parking: [window(2)])
        let prepared = try XCTUnwrap(desk.prepared)
        let live = [UInt32(2): LayerStage.LiveWindow(pid: 10, frame: CGRect(x: 100, y: 120, width: 800, height: 600))]
        XCTAssertTrue(LayerStage.stillParked(prepared.parked, live: live,
                                             main: CGRect(x: 0, y: 0, width: 1440, height: 900), hidden: []).isEmpty)
    }

    func testOnlyConfirmedRollbackRemovesRecoveryHome() {
        let desk = Desk()
        desk.parkResult.stayed = [2]
        let result = run(desk, plan: .init(park: [2, 3]), parking: [window(2), window(3)])
        XCTAssertEqual(result.state.parked.map(\.wid), [3])
        XCTAssertEqual(result.outcome.stayed, [2])
    }

    func testFailedReconciliationKeepsDurablePreparedIntent() throws {
        let desk = Desk()
        desk.failWrites = [2]
        desk.parkResult.spots = [2: CGPoint(x: 1439, y: 870)]
        let result = run(desk, plan: .init(park: [2], hide: [20]), parking: [window(2)])
        XCTAssertFalse(result.outcome.blockedBeforeEffects)
        XCTAssertNotNil(result.outcome.persistenceError)
        XCTAssertEqual(result.state, desk.durable)
        XCTAssertEqual(result.state, try XCTUnwrap(desk.prepared))
        XCTAssertEqual(result.state.parked.first?.pendingPark, true)
    }

    func testPartialRecoveryRetainsOnlyFailuresAfterRestart() throws {
        let desk = Desk()
        desk.restored = [1]
        desk.failedUnhides = [20]
        var initial = LayerStage.State()
        initial.parked = [window(1), window(2)]
        initial.hiddenPids = [10, 20]
        initial.scenes = ["old@1": [1]]
        initial.tucked = ["old": [3]]
        let result = LayerStageExecutor.recover(initial, environment: desk.environment)
        let restarted = try JSONDecoder().decode(LayerStage.State.self, from: JSONEncoder().encode(desk.durable))
        XCTAssertEqual(restarted.parked.map(\.wid), [2])
        XCTAssertEqual(restarted.hiddenPids, [20])
        XCTAssertEqual(restarted.tucked, initial.tucked)
        XCTAssertTrue(restarted.scenes.isEmpty)
        XCTAssertEqual(result.outcome.remainingToRestore, 2)
    }

    func testEscapeStillRestoresWhenLedgerCannotBeWritten() {
        let desk = Desk()
        desk.failWrites = [1]
        desk.restored = [1]
        var initial = LayerStage.State()
        initial.parked = [window(1)]
        initial.hiddenPids = [10]
        let result = LayerStageExecutor.recover(initial, environment: desk.environment)
        XCTAssertEqual(desk.events, ["unhide:10", "restore", "write"])
        XCTAssertEqual(result.outcome.unparked, [1])
        XCTAssertEqual(result.outcome.unhiddenApps, ["app 10"])
        XCTAssertNotNil(result.outcome.persistenceError)
        XCTAssertEqual(result.state, initial)
    }

    func testHiddenOnlyRecoveryReportsStorageFailureWithoutInventingWaitingWindows() {
        let desk = Desk()
        desk.failWrites = [1]
        var initial = LayerStage.State()
        initial.hiddenPids = [10]
        let result = LayerStageExecutor.recover(initial, environment: desk.environment)
        XCTAssertEqual(result.outcome.unhiddenApps, ["app 10"])
        XCTAssertEqual(result.outcome.remainingToRestore, 0)
        XCTAssertNotNil(result.outcome.persistenceError)
        XCTAssertEqual(result.state.hiddenPids, [10])
    }

    func testFailedUnhideDoesNotClaimWantedWindowsAreShown() {
        let desk = Desk()
        desk.failedUnhides = [10]
        var state = LayerStage.State()
        state.hiddenPids = [10]
        let result = LayerStageExecutor.execute(
            initial: state, proposed: state, plan: .init(unhide: [10], unhidden: [1]),
            want: [1], parking: [], origin: .zero, owners: [1: 10], environment: desk.environment
        )
        XCTAssertTrue(result.outcome.shown.isEmpty)
        XCTAssertTrue(result.outcome.unhidden.isEmpty)
        XCTAssertTrue(result.outcome.missing.isEmpty)
        XCTAssertEqual(result.outcome.stillHiddenApps, ["app 10"])
        XCTAssertEqual(result.state.hiddenPids, [10])
    }

    func testDisappearedAppDoesNotClaimWantedWindowsAreShown() {
        let desk = Desk()
        desk.unavailableApps = [10]
        var state = LayerStage.State()
        state.hiddenPids = [10]
        let result = LayerStageExecutor.execute(
            initial: state, proposed: state, plan: .init(unhide: [10], unhidden: [1]),
            want: [1], parking: [], origin: .zero, owners: [1: 10], environment: desk.environment
        )
        XCTAssertTrue(result.outcome.shown.isEmpty)
        XCTAssertTrue(result.outcome.unhidden.isEmpty)
        XCTAssertTrue(result.outcome.stillHiddenApps.isEmpty)
        XCTAssertTrue(result.state.hiddenPids.isEmpty)
    }

    func testEveryNewStageRequestRejectsOldVerification() {
        var revision = LayerStageRevision()
        revision.begin()
        let first = revision.value
        for _ in ["no-op", "missing desktop", "show all"] {
            revision.begin()
            XCTAssertFalse(revision.accepts(first))
            XCTAssertTrue(revision.accepts(revision.value))
        }
    }

    func testMoveWithMissingReadbackAndFailedRollbackIsUncertain() {
        var moves: [CGPoint] = []
        let home = CGPoint(x: 100, y: 120)
        let origin = CGPoint(x: 1439, y: 899)
        let result = LayerStageExecutor.parkWindow(home: home, origin: origin, move: {
            moves.append($0)
            return moves.count == 1
        }, position: { nil })
        XCTAssertEqual(result, .uncertain)
        XCTAssertEqual(moves, [origin, home])
    }

    func testConstrainedMoveMustBeConfirmedBackHomeBeforeDiscardingJournal() {
        let home = CGPoint(x: 100, y: 120)
        var reads = [CGPoint(x: 1400, y: 350), home]
        let result = LayerStageExecutor.parkWindow(home: home, origin: CGPoint(x: 1439, y: 899),
                                                  move: { _ in true }, position: { reads.removeFirst() })
        XCTAssertEqual(result, .stayed)
    }

    func testEveryAcceptedParkCanBeRecognizedFromPreparedIntentAfterCrash() {
        let home = CGPoint(x: 100, y: 120)
        let spot = CGPoint(x: 1439, y: 870)
        let result = LayerStageExecutor.parkWindow(home: home, origin: CGPoint(x: 1439, y: 899),
                                                  move: { _ in true }, position: { spot })
        XCTAssertEqual(result, .parked(spot))
        var pending = window(2)
        pending.pendingPark = true
        let live = [UInt32(2): LayerStage.LiveWindow(pid: 10, frame: CGRect(origin: spot, size: CGSize(width: 800, height: 600)))]
        XCTAssertEqual(LayerStage.stillParked([pending], live: live,
                                             main: CGRect(x: 0, y: 0, width: 1440, height: 900), hidden: []), [pending])
    }
}
