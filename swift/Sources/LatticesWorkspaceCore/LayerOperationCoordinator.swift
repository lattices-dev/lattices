/// Serial layer-operation ownership. The caller supplies its serial executor,
/// persistence/publication, and delayed scheduling; no desktop effects live here.
/// Effects may reenter the coordinator, so currency is checked after each one.
public final class LayerOperationCoordinator {
    public struct Token: Equatable {
        fileprivate let generation: UInt64
        fileprivate let isLayer: Bool
        fileprivate let previousFocus: LayerFocusState
        /// The outgoing layer exists only if focus was active at entry.
        public let wasActive: Bool
    }

    public struct Snapshot: Equatable {
        public let focus: LayerFocusState
        public let isSwitching: Bool
    }

    public typealias Effect = () -> Void
    public typealias Schedule = (_ delay: Double, _ action: @escaping Effect) -> Void

    public private(set) var focus: LayerFocusState
    private var busyGeneration: UInt64?
    private let scheduleEffect: Schedule
    private let didChange: (Snapshot) -> Void
    private var publishing = false

    public init(
        focus: LayerFocusState = LayerFocusState(),
        schedule: @escaping Schedule,
        didChange: @escaping (Snapshot) -> Void = { _ in }
    ) {
        self.focus = focus
        self.scheduleEffect = schedule
        self.didChange = didChange
    }

    public var isSwitching: Bool {
        busyGeneration.map(focus.acceptsLayerWork) ?? false
    }

    public var snapshot: Snapshot { Snapshot(focus: focus, isSwitching: isSwitching) }

    /// A focus/editor operation also supersedes the previous tile's busy state.
    @discardableResult
    public func begin(isSwitching: Bool = false) -> Token {
        let previous = focus
        focus.enter()
        let token = Token(generation: focus.generation, isLayer: true, previousFocus: previous, wasActive: previous.isActive)
        busyGeneration = isSwitching ? token.generation : nil
        publish()
        return token
    }

    @discardableResult
    public func exit() -> Token {
        let previous = focus
        focus.exit()
        let token = Token(generation: focus.generation, isLayer: false, previousFocus: previous, wasActive: previous.isActive)
        busyGeneration = nil
        publish()
        return token
    }

    public func recovered(remaining: Int, pendingPersistence: Bool = false, generation: UInt64) {
        guard focus.acceptsRecovery(generation) else { return }
        focus.recovered(remaining: remaining, pendingPersistence: pendingPersistence, generation: generation)
        publish()
    }

    public func accepts(_ token: Token) -> Bool {
        if token.isLayer { return focus.acceptsLayerWork(token.generation) }
        return !focus.isActive && focus.generation == token.generation
    }

    /// A preparation failure restores the prior mode with a fresh generation.
    public func cancel(_ token: Token) {
        guard accepts(token), token.isLayer else { return }
        focus.cancelEntry(restoring: token.previousFocus)
        busyGeneration = nil
        publish()
    }

    /// The production executor for both immediate phases and delayed work.
    /// A query or launch that reenters cannot let the old operation continue.
    @discardableResult
    public func execute(_ token: Token, steps: [Effect]) -> Bool {
        for step in steps {
            guard accepts(token) else { return false }
            step()
        }
        return accepts(token)
    }

    public func schedule(_ token: Token, after delay: Double, steps: [Effect]) {
        guard accepts(token) else { return }
        scheduleEffect(delay) { [weak self] in
            self?.execute(token, steps: steps)
        }
    }

    /// Completion belongs to its token. Refresh may reenter and start a newer
    /// tile; neither this completion nor an older queued one can clear it.
    public func complete(
        _ token: Token,
        after delay: Double,
        refreshing: @escaping Effect,
        finished: @escaping Effect = {}
    ) {
        guard accepts(token) else { return }
        scheduleEffect(delay) { [weak self] in
            guard let self, self.execute(token, steps: [refreshing]),
                  self.busyGeneration == token.generation else { return }
            self.busyGeneration = nil
            self.publish()
            _ = self.execute(token, steps: [finished])
        }
    }

    /// A subscriber can start another operation while receiving a snapshot.
    /// Deliver its final state after the outer publication finishes so the
    /// caller's read-only mirror cannot end on the superseded snapshot.
    private func publish() {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        while true {
            let delivered = snapshot
            didChange(delivered)
            if snapshot == delivered { return }
        }
    }
}
