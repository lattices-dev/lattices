import Foundation

/// Layer definitions and the last selected index survive leaving focus mode.
/// This state owns only the live session and recovery of windows it put away.
struct LayerFocusState: Equatable {
    private(set) var isActive: Bool
    private(set) var pendingRestorationCount: Int
    private(set) var generation: UInt64 = 0

    init(isActive: Bool = false, pendingRestorationCount: Int = 0) {
        self.isActive = isActive
        self.pendingRestorationCount = isActive ? 0 : max(0, pendingRestorationCount)
    }

    init(persistedActive: Bool?, hasRememberedLayer: Bool, pendingRestorationCount: Int) {
        self.init(isActive: persistedActive ?? hasRememberedLayer, pendingRestorationCount: pendingRestorationCount)
    }

    var needsRecovery: Bool { !isActive && pendingRestorationCount > 0 }

    /// Every explicit selection invalidates work queued by the preceding layer.
    mutating func enter() {
        generation &+= 1
        isActive = true
        pendingRestorationCount = 0
    }

    /// Persist this before restoring. A crash during restoration must leave the
    /// next launch in recovery, rather than resuming a layer accidentally.
    mutating func exit() {
        generation &+= 1
        isActive = false
        pendingRestorationCount = max(1, pendingRestorationCount)
    }

    func acceptsLayerWork(_ generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    func acceptsRecovery(_ generation: UInt64) -> Bool {
        needsRecovery && self.generation == generation
    }

    mutating func recovered(remaining: Int, generation: UInt64) {
        guard acceptsRecovery(generation) else { return }
        pendingRestorationCount = max(0, remaining)
    }
}
