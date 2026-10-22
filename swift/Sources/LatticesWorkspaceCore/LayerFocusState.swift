/// Layer definitions and the last selected index survive leaving focus mode.
/// This value owns only the live session and recovery of windows it put away.
public struct LayerFocusState: Equatable {
    public private(set) var isActive: Bool
    public private(set) var pendingRestorationCount: Int
    public private(set) var pendingPersistence: Bool
    public private(set) var generation: UInt64 = 0

    public init(isActive: Bool = false, pendingRestorationCount: Int = 0, pendingPersistence: Bool = false) {
        self.isActive = isActive
        self.pendingRestorationCount = isActive ? 0 : max(0, pendingRestorationCount)
        self.pendingPersistence = !isActive && pendingPersistence
    }

    public init(persistedActive: Bool?, hasRememberedLayer: Bool, pendingRestorationCount: Int, pendingPersistence: Bool = false) {
        self.init(isActive: persistedActive ?? hasRememberedLayer,
                  pendingRestorationCount: pendingRestorationCount, pendingPersistence: pendingPersistence)
    }

    public var needsRecovery: Bool { !isActive && (pendingRestorationCount > 0 || pendingPersistence) }

    /// Every explicit selection invalidates work queued by the preceding layer.
    public mutating func enter() {
        generation &+= 1
        isActive = true
        pendingRestorationCount = 0
        pendingPersistence = false
    }

    /// Persist this before restoring. A crash during restoration must leave the
    /// next launch in recovery, rather than resuming a layer accidentally.
    public mutating func exit() {
        generation &+= 1
        isActive = false
        pendingRestorationCount = max(1, pendingRestorationCount)
    }

    public func acceptsLayerWork(_ generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    public func acceptsRecovery(_ generation: UInt64) -> Bool {
        needsRecovery && self.generation == generation
    }

    public mutating func recovered(remaining: Int, pendingPersistence: Bool = false, generation: UInt64) {
        guard acceptsRecovery(generation) else { return }
        pendingRestorationCount = max(0, remaining)
        self.pendingPersistence = pendingPersistence
    }

    /// A failed preparation restores the prior mode, never its generation.
    /// Work from either the cancelled entry or its predecessor stays stale.
    mutating func cancelEntry(restoring previous: LayerFocusState) {
        generation &+= 1
        isActive = previous.isActive
        pendingRestorationCount = previous.pendingRestorationCount
        pendingPersistence = previous.pendingPersistence
    }
}
