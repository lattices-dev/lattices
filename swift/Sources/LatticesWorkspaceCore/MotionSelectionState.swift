/// Ordered window selections for a motion session. Display identity and window
/// eligibility come from the caller; this state never reads the desktop.
public struct MotionSelectionState {
    private var selections: [String: [UInt32]] = [:]

    public init() {}

    /// A value snapshot for consumers that render more than one display.
    public var ordersByDisplay: [String: [UInt32]] { selections }

    public func order(on displayID: String) -> [UInt32] {
        selections[displayID] ?? []
    }

    public func members(on displayID: String) -> Set<UInt32> {
        Set(order(on: displayID))
    }

    /// Returns true only when the window became selected. Callers can use this
    /// to prepare a newly selected window without repeating effects on removal.
    @discardableResult
    public mutating func toggle(_ windowID: UInt32, on displayID: String) -> Bool {
        var order = order(on: displayID)
        if order.contains(windowID) {
            order.removeAll { $0 == windowID }
            selections[displayID] = order
            return false
        }
        order.append(windowID)
        selections[displayID] = order
        return true
    }

    /// A fully selected group is removed. Otherwise, missing members are
    /// appended in group order, preserving all earlier selections.
    /// Returns newly selected IDs, in the order their effects should run.
    @discardableResult
    public mutating func toggleGroup(_ windowIDs: [UInt32], on displayID: String) -> [UInt32] {
        guard !windowIDs.isEmpty else { return [] }
        let selected = members(on: displayID)
        if windowIDs.allSatisfy({ selected.contains($0) }) {
            remove(Set(windowIDs), on: displayID)
            return []
        }
        return append(windowIDs, on: displayID)
    }

    /// Adds only missing IDs, in input order. Search results and recalled layers
    /// share this operation, so existing slot numbers remain stable.
    @discardableResult
    public mutating func append(_ windowIDs: [UInt32], on displayID: String) -> [UInt32] {
        var order = order(on: displayID)
        var selected = Set(order)
        var added: [UInt32] = []
        for windowID in windowIDs where selected.insert(windowID).inserted {
            order.append(windowID)
            added.append(windowID)
        }
        selections[displayID] = order
        return added
    }

    /// Removes only the named windows, without changing the display being used
    /// by the caller or reordering the remaining selections.
    public mutating func remove(_ windowIDs: Set<UInt32>, on displayID: String) {
        guard let order = selections[displayID] else { return }
        selections[displayID] = order.filter { !windowIDs.contains($0) }
    }

    public mutating func clear(on displayID: String) {
        selections[displayID] = []
    }

    /// Refreshes and display changes prune stale membership in the authoritative
    /// order, so all views agree immediately about membership and slot numbers.
    public mutating func retainWindows(_ windowIDs: Set<UInt32>, on displayID: String) {
        selections[displayID] = order(on: displayID).filter { windowIDs.contains($0) }
    }

    public mutating func retainDisplays(_ displayIDs: Set<String>) {
        selections = selections.filter { displayIDs.contains($0.key) }
    }
}
