import XCTest
@testable import LatticesWorkspaceCore

final class LayerOperationCoordinatorTests: XCTestCase {
    private final class Scheduler {
        struct Work {
            let delay: Double
            let action: () -> Void
        }
        var work: [Work] = []
        func schedule(_ delay: Double, _ action: @escaping () -> Void) {
            work.append(Work(delay: delay, action: action))
        }
        func runNext() {
            work.removeFirst().action()
        }
        func drain() {
            while !work.isEmpty { runNext() }
        }
    }

    func testProductionExecutorKeepsEffectsInOrderAndCompletesItsOwnBusyState() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var effects: [String] = []
        let token = operations.begin(isSwitching: true)

        XCTAssertTrue(operations.execute(token, steps: [
            { effects.append("inventory") },
            { effects.append("stage") },
            { effects.append("place") },
            { effects.append("commit") }
        ]))
        operations.complete(token, after: 0.5, refreshing: {
            effects.append("refresh")
            XCTAssertTrue(operations.isSwitching)
        }, finished: {
            XCTAssertFalse(operations.isSwitching)
            effects.append("finished")
        })
        XCTAssertEqual(scheduler.work.map(\.delay), [0.5])
        scheduler.drain()
        XCTAssertEqual(effects, ["inventory", "stage", "place", "commit", "refresh", "finished"])
        XCTAssertFalse(operations.isSwitching)
    }

    func testReentrantInventoryStopsTheOldPlacementAndCommit() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var effects: [String] = []
        let old = operations.begin(isSwitching: true)

        XCTAssertFalse(operations.execute(old, steps: [
            {
                effects.append("old inventory")
                let current = operations.begin()
                operations.execute(current, steps: [{ effects.append("new commit") }])
            },
            { effects.append("old placement") },
            { effects.append("old commit") }
        ]))
        XCTAssertEqual(effects, ["old inventory", "new commit"])
        XCTAssertFalse(operations.isSwitching)
    }

    func testReentrantLaunchCannotPlaceItsWindowOrClearTheNewTilesBusyState() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var effects: [String] = []
        let old = operations.begin(isSwitching: true)
        operations.schedule(old, after: 0.2, steps: [
            {
                effects.append("launch")
                operations.begin(isSwitching: true)
            },
            { effects.append("old tile") }
        ])
        operations.complete(old, after: 0.5, refreshing: { effects.append("old refresh") })

        scheduler.drain()
        XCTAssertEqual(effects, ["launch"])
        XCTAssertTrue(operations.isSwitching)
        XCTAssertFalse(operations.accepts(old))
    }

    func testDelayedWindowLookupReentryStopsItsFollowingMove() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var effects: [String] = []
        let token = operations.begin(isSwitching: true)
        operations.schedule(token, after: 1.5, steps: [
            {
                effects.append("find launched window")
                operations.exit()
            },
            { effects.append("move window") }
        ])
        scheduler.drain()
        XCTAssertEqual(effects, ["find launched window"])
        XCTAssertFalse(operations.focus.isActive)
        XCTAssertFalse(operations.isSwitching)
    }

    func testFocusSupersedesTileAndSettlesBusyWithoutItsRejectedCompletion() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var refreshed = false
        let tile = operations.begin(isSwitching: true)
        operations.complete(tile, after: 0.2, refreshing: { refreshed = true })
        let focus = operations.begin()

        XCTAssertFalse(operations.isSwitching)
        scheduler.drain()
        XCTAssertFalse(refreshed)
        XCTAssertTrue(operations.accepts(focus))
        XCTAssertFalse(operations.isSwitching)
    }

    func testOldCompletionNeverClearsANewerTilesBusyState() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var effects: [String] = []
        let old = operations.begin(isSwitching: true)
        operations.complete(old, after: 0.2, refreshing: { effects.append("old refresh") })
        let current = operations.begin(isSwitching: true)
        operations.complete(current, after: 0.5, refreshing: { effects.append("current refresh") })

        scheduler.runNext()
        XCTAssertTrue(operations.isSwitching)
        XCTAssertEqual(effects, [])
        scheduler.runNext()
        XCTAssertFalse(operations.isSwitching)
        XCTAssertEqual(effects, ["current refresh"])
    }

    func testCompletionRefreshReentryCannotSettleOrFinishTheNewOperation() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        var finished = false
        let token = operations.begin(isSwitching: true)
        operations.complete(token, after: 0.2, refreshing: {
            operations.begin(isSwitching: true)
        }, finished: { finished = true })

        scheduler.drain()
        XCTAssertTrue(operations.isSwitching)
        XCTAssertFalse(finished)
    }

    func testExitPublishesRecoveryIntentBeforeRestoringAndRejectsOldQueuedWork() {
        let scheduler = Scheduler()
        var snapshots: [LayerOperationCoordinator.Snapshot] = []
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule, didChange: { snapshots.append($0) })
        let tile = operations.begin(isSwitching: true)
        var launched = false
        operations.schedule(tile, after: 0.2, steps: [{ launched = true }])
        let exit = operations.exit()
        XCTAssertTrue(operations.execute(exit, steps: [{
            XCTAssertEqual(snapshots.last, operations.snapshot)
            XCTAssertTrue(snapshots.last?.focus.needsRecovery == true)
            operations.recovered(remaining: 0, generation: operations.focus.generation)
        }]))

        scheduler.drain()
        XCTAssertFalse(launched)
        XCTAssertFalse(operations.focus.isActive)
        XCTAssertFalse(operations.focus.needsRecovery)
        XCTAssertFalse(operations.isSwitching)
    }

    func testReentryDuringRestorationStopsTheOldExitFeedbackAndRecoveryCommit() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        let exit = operations.exit()
        let recoveryGeneration = operations.focus.generation
        var effects: [String] = []

        XCTAssertFalse(operations.execute(exit, steps: [
            {
                effects.append("restore")
                operations.begin(isSwitching: true)
                operations.recovered(remaining: 4, generation: recoveryGeneration)
            },
            { effects.append("old exit feedback") }
        ]))
        XCTAssertEqual(effects, ["restore"])
        XCTAssertTrue(operations.focus.isActive)
        XCTAssertEqual(operations.focus.pendingRestorationCount, 0)
        XCTAssertTrue(operations.isSwitching)
    }

    func testSnapshotPublicationReentryKeepsTheNewOwnershipAndFinalMirror() {
        let scheduler = Scheduler()
        var operations: LayerOperationCoordinator!
        var mirrored: LayerOperationCoordinator.Snapshot?
        var reenter = true
        operations = LayerOperationCoordinator(schedule: scheduler.schedule, didChange: { snapshot in
            if reenter {
                reenter = false
                operations.begin(isSwitching: true)
            }
            // Models an outer published setter finishing after its observer.
            mirrored = snapshot
        })

        let superseded = operations.begin()
        var committed = false
        XCTAssertFalse(operations.execute(superseded, steps: [{ committed = true }]))
        XCTAssertFalse(committed)
        XCTAssertEqual(mirrored, operations.snapshot)
        XCTAssertTrue(mirrored?.isSwitching == true)
    }

    func testPreparationFailureOnlyCancelsItsOwnBusyOwner() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        let first = operations.begin(isSwitching: true)
        operations.cancel(first)
        XCTAssertFalse(operations.isSwitching)
        XCTAssertFalse(operations.focus.isActive)
        XCTAssertFalse(operations.accepts(first))

        let second = operations.begin(isSwitching: true)
        operations.cancel(first)
        XCTAssertTrue(operations.isSwitching)
        XCTAssertTrue(operations.accepts(second))
    }

    func testSupersededOperationCannotEnqueueWorkUnderTheCurrentGeneration() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        let old = operations.begin(isSwitching: true)
        operations.execute(old, steps: [{ operations.begin(isSwitching: true) }])
        operations.schedule(old, after: 0.2, steps: [{ XCTFail("Old launch ran") }])
        operations.complete(old, after: 0.5, refreshing: { XCTFail("Old refresh ran") })

        XCTAssertTrue(scheduler.work.isEmpty)
        XCTAssertTrue(operations.isSwitching)
    }

    func testPhysicallyRestoredWindowsKeepRecoveryPendingUntilTheLedgerSaves() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        operations.exit()
        let generation = operations.focus.generation
        operations.recovered(remaining: 0, pendingPersistence: true, generation: generation)

        XCTAssertEqual(operations.focus.pendingRestorationCount, 0)
        XCTAssertTrue(operations.focus.pendingPersistence)
        XCTAssertTrue(operations.focus.needsRecovery)
        XCTAssertTrue(operations.focus.acceptsRecovery(generation))

        let restarted = LayerFocusState(persistedActive: false, hasRememberedLayer: true,
                                        pendingRestorationCount: 0, pendingPersistence: true)
        XCTAssertTrue(restarted.needsRecovery)
        XCTAssertFalse(restarted.isActive)

        operations.recovered(remaining: 0, generation: generation)
        XCTAssertFalse(operations.focus.needsRecovery)
        XCTAssertFalse(operations.focus.pendingPersistence)
    }

    func testLayerReentryClearsPendingPersistenceAndRejectsItsStaleRecovery() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(
            focus: LayerFocusState(pendingPersistence: true), schedule: scheduler.schedule
        )
        let recovery = operations.focus.generation
        operations.begin()
        operations.recovered(remaining: 0, pendingPersistence: true, generation: recovery)
        XCTAssertTrue(operations.focus.isActive)
        XCTAssertFalse(operations.focus.pendingPersistence)
        XCTAssertFalse(operations.focus.needsRecovery)
    }

    func testEntryTokenRetainsWhetherThereWasAnOutgoingLayerBeforePublication() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        let first = operations.begin()
        XCTAssertFalse(first.wasActive)
        XCTAssertTrue(operations.focus.isActive)
        let next = operations.begin()
        XCTAssertTrue(next.wasActive)
        operations.exit()
        XCTAssertFalse(operations.begin().wasActive)
    }

    func testFailedEntryRestoresRecoveryWithoutRevivingEitherCancelledGeneration() {
        let scheduler = Scheduler()
        let operations = LayerOperationCoordinator(schedule: scheduler.schedule)
        let old = operations.begin(isSwitching: true)
        operations.exit()
        let recovery = operations.focus.generation
        operations.recovered(remaining: 2, pendingPersistence: true, generation: recovery)
        let failed = operations.begin(isSwitching: true)
        let entered = operations.focus.generation
        operations.cancel(failed)

        XCTAssertFalse(operations.focus.isActive)
        XCTAssertTrue(operations.focus.needsRecovery)
        XCTAssertEqual(operations.focus.pendingRestorationCount, 2)
        XCTAssertTrue(operations.focus.pendingPersistence)
        XCTAssertGreaterThan(operations.focus.generation, entered)
        XCTAssertFalse(operations.accepts(failed))
        XCTAssertFalse(operations.accepts(old))
        XCTAssertFalse(operations.focus.acceptsRecovery(recovery))
        XCTAssertFalse(operations.isSwitching)
    }
}
