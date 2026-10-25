import Foundation

/// Classifies passive Space notifications from topology, plus explicit exits
/// of Lattices-owned fullscreen windows. All callers run on the main thread.
/// Inputs are snapshots so tests never switch the user's desktop.
final class SystemSpaceChangeFeedback {
    static let shared = SystemSpaceChangeFeedback()

    enum Decision: Equatable { case show, fullScreenReturn, none }
    struct Exit: Equatable {
        let displayID: String
        let spaceID: Int
    }
    private struct PendingExit {
        let token: Exit
        var returnedSpaceID: Int?
    }
    private var previous: [String: DisplaySpaces] = [:]
    private var exits: [String: PendingExit] = [:]

    func seed(_ displays: [DisplaySpaces]) {
        previous = snapshots(displays)
        exits.removeAll()
    }

    @discardableResult
    func beginFullScreenExit(_ display: DisplaySpaces) -> Exit? {
        guard isFullScreen(display.currentSpaceId, in: display) else { return nil }
        let token = Exit(displayID: display.displayId, spaceID: display.currentSpaceId)
        previous[display.displayId] = display
        exits[display.displayId] = PendingExit(token: token)
        return token
    }

    func completeFullScreenExit(_ token: Exit, display: DisplaySpaces?) {
        guard var pending = exits[token.displayID], pending.token == token,
              let display, display.displayId == token.displayID,
              display.currentSpaceId != token.spaceID, isDesktop(display.currentSpaceId, in: display) else { return }
        // Completion may precede the workspace notification. Establish the
        // actual return desktop now, so a later real switch still shows.
        pending.returnedSpaceID = display.currentSpaceId
        exits[token.displayID] = pending
        previous[token.displayID] = display
    }

    func cancelFullScreenExit(_ token: Exit) {
        guard exits[token.displayID]?.token == token else { return }
        exits.removeValue(forKey: token.displayID)
    }

    func observe(_ displays: [DisplaySpaces], activeSpaceID: Int) -> Decision {
        let current = snapshots(displays)
        guard !current.isEmpty else { return .none }
        let active = current.values.first { $0.currentSpaceId == activeSpaceID }
        defer {
            previous = current
            // A marker belongs to one return. A different desktop, removed
            // display, or the matching notification retires it permanently.
            exits = exits.filter { id, pending in
                guard let display = current[id] else { return false }
                if let returned = pending.returnedSpaceID {
                    return display.currentSpaceId == returned && active?.displayId != id
                }
                return display.currentSpaceId == pending.token.spaceID
            }
        }
        guard let active, isDesktop(active.currentSpaceId, in: active) else { return .none }
        if let pending = exits[active.displayId] {
            if let returned = pending.returnedSpaceID {
                if returned == active.currentSpaceId { return .fullScreenReturn }
            } else if previous[active.displayId]?.currentSpaceId == pending.token.spaceID {
                return .fullScreenReturn
            }
        }
        guard let before = previous[active.displayId] else { return .show }
        guard before.currentSpaceId != active.currentSpaceId else { return .none }
        // Closing native fullscreen removes its Space. Swiping away leaves
        // that Space present and remains an ordinary navigation confirmation.
        if isFullScreen(before.currentSpaceId, in: before),
           !active.orderedSpaceIds.contains(before.currentSpaceId) {
            return .fullScreenReturn
        }
        return .show
    }

    private func snapshots(_ displays: [DisplaySpaces]) -> [String: DisplaySpaces] {
        var result: [String: DisplaySpaces] = [:]
        for display in displays where display.currentSpaceId > 0
            && display.orderedSpaceIds.contains(display.currentSpaceId) {
            result[display.displayId] = display
        }
        return result
    }

    private func isDesktop(_ space: Int, in display: DisplaySpaces) -> Bool {
        display.spaces.contains { $0.id == space }
    }

    private func isFullScreen(_ space: Int, in display: DisplaySpaces) -> Bool {
        display.orderedSpaceIds.contains(space) && !isDesktop(space, in: display)
    }
}
