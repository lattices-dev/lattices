import AppKit

/// The app and display captured before the launcher takes focus. This is an
/// exact set of windows, not a query that can widen when the command runs.
struct AppArrangementTarget: Equatable {
    struct Window: Equatable {
        let id: UInt32
        let pid: Int32
    }

    let appName: String
    let bundleID: String?
    let anchorPID: Int32
    let displayID: CGDirectDisplayID
    let displayName: String
    let windows: [Window]

    var windowIDs: [UInt32] { windows.map(\.id) }
    var title: String { "Arrange \(windows.count) \(appName) window\(windows.count == 1 ? "" : "s")" }

    static func make(anchor: WindowEntry?, windows: [WindowEntry],
                     displayName: String,
                     displayForWindow: (WindowEntry) -> CGDirectDisplayID?) -> Self? {
        guard let anchor, DesktopModel.isPlaceableTarget(anchor),
              let displayID = displayForWindow(anchor) else { return nil }
        let bundleID = anchor.bundleId.flatMap { $0.isEmpty ? nil : $0 }
        let matches = windows.filter { entry in
            DesktopModel.isPlaceableTarget(entry)
                && (bundleID.map { entry.bundleId == $0 } ?? (entry.pid == anchor.pid))
                && displayForWindow(entry) == displayID
        }.sorted { lhs, rhs in
            lhs.zIndex == rhs.zIndex ? lhs.wid < rhs.wid : lhs.zIndex < rhs.zIndex
        }
        guard !matches.isEmpty else { return nil }
        return Self(appName: anchor.app, bundleID: bundleID, anchorPID: anchor.pid,
                    displayID: displayID, displayName: displayName,
                    windows: matches.map { Window(id: $0.wid, pid: $0.pid) })
    }

    /// Position words are deliberately excluded: "tile Ghostty left" must keep
    /// the existing placement semantics rather than open a group arrangement.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty, !query.hasPrefix("/") else { return false }
        let appWords = appName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let verbs = ["arrange", "tile", "grid"]
        let fillers: Set<String> = ["window", "windows", "this", "these", "all", "my", "same", "app",
                                    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        var hasSubject = false
        for word in words {
            if verbs.contains(where: { $0.hasPrefix(word) }) || appWords.contains(where: { $0.hasPrefix(word) }) {
                hasSubject = true
            } else if !fillers.contains(word) && Int(word) == nil {
                return false
            }
        }
        return hasSubject
    }

    /// Reject stale IDs, changed ownership, and another display. Newly opened
    /// same-app windows are never added to a selection the user already saw.
    func isValid(in current: [WindowEntry],
                 displayForWindow: (WindowEntry) -> CGDirectDisplayID?) -> Bool {
        guard !windows.isEmpty else { return false }
        return windows.allSatisfy { selected in
            guard let entry = current.first(where: { $0.wid == selected.id }),
                  entry.pid == selected.pid, DesktopModel.isPlaceableTarget(entry),
                  displayForWindow(entry) == displayID else { return false }
            return bundleID.map { entry.bundleId == $0 } ?? (entry.pid == anchorPID)
        }
    }

    static func displayID(for entry: WindowEntry) -> CGDirectDisplayID? {
        let screen = WindowTiler.screenForWindowFrame(entry.frame)
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var result: OmniResult {
        OmniResult(kind: .window, title: title,
                   subtitle: "\(displayName) · Choose a layout",
                   icon: "rectangle.3.group", score: 1_000,
                   arrangementTarget: self) {
            UnifiedCommandBarWindow.shared.openArrangement(self)
        }
    }
}
