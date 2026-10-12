import XCTest
@testable import Lattices

final class LayerFocusStateTests: XCTestCase {
    func testLegacySelectionMigratesWithoutStrandingItsHiddenWindows() {
        let legacy = LayerFocusState(persistedActive: nil, hasRememberedLayer: true, pendingRestorationCount: 0)
        XCTAssertTrue(legacy.isActive)
        let fresh = LayerFocusState(persistedActive: nil, hasRememberedLayer: false, pendingRestorationCount: 0)
        XCTAssertFalse(fresh.isActive)
    }

    func testExitCancelsEveryQueuedLayerMutationBeforeRestorationCompletes() {
        var state = LayerFocusState()
        state.enter()
        let queuedLaunch = state.generation
        XCTAssertTrue(state.acceptsLayerWork(queuedLaunch))

        state.exit()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.acceptsLayerWork(queuedLaunch))
        XCTAssertTrue(state.needsRecovery, "A crash before restoration must retain recovery intent")

        let recovery = state.generation
        state.recovered(remaining: 3, generation: recovery)
        XCTAssertEqual(state.pendingRestorationCount, 3)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.acceptsRecovery(recovery))

        state.recovered(remaining: 0, generation: recovery)
        XCTAssertFalse(state.needsRecovery)
        XCTAssertFalse(state.isActive, "Restoring a desktop must never reenter a layer")
    }

    func testRestartKeepsExitAndPartialRecoveryDespiteRememberedSelection() {
        let restored = LayerFocusState(persistedActive: false, hasRememberedLayer: true, pendingRestorationCount: 2)
        XCTAssertFalse(restored.isActive)
        XCTAssertTrue(restored.needsRecovery)
        XCTAssertEqual(restored.pendingRestorationCount, 2)
    }

    func testExplicitReentryInvalidatesDeferredRecoveryAndEarlierLayerWork() {
        var state = LayerFocusState(isActive: true)
        let oldLayer = state.generation
        state.exit()
        let recovery = state.generation
        state.enter()

        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.acceptsRecovery(recovery))
        XCTAssertFalse(state.acceptsLayerWork(oldLayer))
        XCTAssertTrue(state.acceptsLayerWork(state.generation))
        state.recovered(remaining: 7, generation: recovery)
        XCTAssertEqual(state.pendingRestorationCount, 0)
        XCTAssertTrue(state.isActive)
    }

    func testRepeatedExitSupersedesAnEarlierRecoveryResult() {
        var state = LayerFocusState(isActive: true)
        state.exit()
        let first = state.generation
        state.exit()
        let second = state.generation
        state.recovered(remaining: 0, generation: first)
        XCTAssertTrue(state.needsRecovery)
        state.recovered(remaining: 0, generation: second)
        XCTAssertFalse(state.needsRecovery)
    }
}
