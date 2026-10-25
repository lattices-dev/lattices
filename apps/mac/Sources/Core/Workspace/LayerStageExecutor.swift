import Foundation

/// Runs the stage's effects against a durable recovery ledger. Native window
/// access stays in LayerStage; this is also the executor used by fixture tests.
enum LayerStageExecutor {
    enum WindowParkResult: Equatable {
        case parked(CGPoint)
        case stayed
        case uncertain
    }

    /// The same verified move/rollback sequence used by the AX adapter.
    static func parkWindow(
        home: CGPoint,
        origin: CGPoint,
        move: (CGPoint) -> Bool,
        position: () -> CGPoint?
    ) -> WindowParkResult {
        guard move(origin) else { return .uncertain }
        if let landed = position(),
           landed.x >= origin.x + 1 - LayerStage.parkedSlack, landed.x <= origin.x,
           landed.y >= origin.y + 1 - LayerStage.parkedDrop, landed.y <= origin.y {
            return .parked(landed)
        }
        if move(home), let restored = position(),
           abs(restored.x - home.x) <= 2, abs(restored.y - home.y) <= 2 {
            return .stayed
        }
        return .uncertain
    }

    struct ParkResult {
        var spots: [UInt32: CGPoint] = [:]
        /// Only windows confirmed back at home may leave the recovery ledger.
        var stayed: Set<UInt32> = []
    }

    enum AppResult {
        case unavailable
        case succeeded(String)
        case failed(String)
    }

    struct Environment {
        var write: (LayerStage.State) throws -> Void
        var unhide: (Int32) -> AppResult
        var waitForUnhide: (Set<Int32>) -> Void
        var park: ([LayerStage.ParkedWindow], CGPoint) -> ParkResult
        var restore: ([LayerStage.ParkedWindow]) -> Set<UInt32>
        var hide: (Int32) -> AppResult
    }

    struct Result {
        var state: LayerStage.State
        var outcome: LayerStage.Outcome
    }

    static func execute(
        initial: LayerStage.State,
        proposed: LayerStage.State,
        plan: LayerStage.Plan,
        want: Set<UInt32>,
        parking: [LayerStage.ParkedWindow],
        origin: CGPoint,
        owners: [UInt32: Int32] = [:],
        environment: Environment,
        finalize: (inout LayerStage.State, LayerStage.Outcome) -> Void = { _, _ in }
    ) -> Result {
        var prepared = proposed
        var known = Set(prepared.parked.map(\.wid))
        for window in parking where known.insert(window.wid).inserted {
            prepared.parked.append(window)
        }
        let parkingIDs = Set(parking.map(\.wid))
        for index in prepared.parked.indices where parkingIDs.contains(prepared.parked[index].wid) {
            prepared.parked[index].pendingPark = true
        }
        for pid in plan.hide where !prepared.hiddenPids.contains(pid) {
            prepared.hiddenPids.append(pid)
        }
        var outcome = LayerStage.Outcome()
        do {
            // All homes and hide intentions must be durable before any effect.
            try environment.write(prepared)
        } catch {
            outcome.blockedBeforeEffects = true
            outcome.persistenceError = error.localizedDescription
            return Result(state: initial, outcome: outcome)
        }

        var next = prepared
        var unhidden = Set<Int32>()
        var notUnhidden = Set<Int32>()
        for pid in plan.unhide {
            switch environment.unhide(pid) {
            case .succeeded(let name):
                outcome.unhiddenApps.append(name)
                unhidden.insert(pid)
                next.hiddenPids.removeAll { $0 == pid }
            case .unavailable:
                notUnhidden.insert(pid)
                next.hiddenPids.removeAll { $0 == pid }
            case .failed(let name):
                notUnhidden.insert(pid)
                outcome.stillHiddenApps.append(name)
            }
        }
        outcome.unhidden = plan.unhidden.filter { owners[$0].map(unhidden.contains) ?? false }
        environment.waitForUnhide(unhidden)

        if !parking.isEmpty {
            let result = environment.park(parking, origin)
            outcome.parked = Set(result.spots.keys)
            outcome.stayed = result.stayed
            next.parked.removeAll { result.stayed.contains($0.wid) }
            for index in next.parked.indices {
                if let spot = result.spots[next.parked[index].wid] {
                    next.parked[index].spot = spot
                    next.parked[index].pendingPark = nil
                }
            }
            // An uncertain AX result keeps its home, even for a fresh window.
        }

        let restored = environment.restore(next.parked.filter { plan.restore.contains($0.wid) })
        next.parked.removeAll { restored.contains($0.wid) }
        outcome.unparked = restored
        outcome.missing = Set(plan.restore).subtracting(restored)
        outcome.shown = want.subtracting(outcome.missing).filter {
            !(owners[$0].map(notUnhidden.contains) ?? false)
        }

        var hidden = Set<Int32>()
        for pid in plan.hide {
            switch environment.hide(pid) {
            case .succeeded(let name): outcome.hiddenApps.append(name); hidden.insert(pid)
            case .unavailable: next.hiddenPids.removeAll { $0 == pid }
            case .failed: break
            }
        }
        outcome.hidden = plan.hidden.filter { owners[$0].map(hidden.contains) ?? false }
        finalize(&next, outcome)
        return reconcile(next, prepared: prepared, outcome: outcome, environment: environment)
    }

    /// Recovery remains available when storage is unwritable. Failed effects
    /// and failed reconciliation retain the prepared journal for a later retry.
    static func recover(_ state: LayerStage.State, environment: Environment) -> Result {
        var next = state
        var outcome = LayerStage.Outcome()
        next.hiddenPids = state.hiddenPids.filter { pid in
            switch environment.unhide(pid) {
            case .succeeded(let name): outcome.unhiddenApps.append(name); return false
            case .unavailable: return false
            case .failed(let name): outcome.stillHiddenApps.append(name); return true
            }
        }
        let restored = environment.restore(state.parked)
        next.parked.removeAll { restored.contains($0.wid) }
        next.scenes.removeAll()
        outcome.unparked = restored
        return reconcile(next, prepared: state, outcome: outcome, environment: environment)
    }

    private static func reconcile(
        _ next: LayerStage.State,
        prepared: LayerStage.State,
        outcome: LayerStage.Outcome,
        environment: Environment
    ) -> Result {
        var result = Result(state: next, outcome: outcome)
        do {
            try environment.write(next)
        } catch {
            // The disk still holds prepared intent. Retain it in memory too;
            // a later recovery can retry, and pruning recognizes restored homes.
            result.state = prepared
            result.outcome.persistenceError = error.localizedDescription
        }
        result.outcome.stillParked = result.state.parked.count
        return result
    }
}

/// Every request, including one with no desktop or no work, supersedes the
/// previous verifier. Revision ownership is independent of whether AX ran.
struct LayerStageRevision {
    private(set) var value: UInt64 = 0

    mutating func begin() { value &+= 1 }
    func accepts(_ revision: UInt64) -> Bool { value == revision }
}
