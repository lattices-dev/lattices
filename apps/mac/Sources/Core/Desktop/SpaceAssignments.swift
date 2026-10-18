import AppKit

/// The Dock's "Assign To" setting: an app held to one desktop, or shown on
/// all of them. macOS returns an assigned app's windows to its desktop, so a
/// move to any other desktop on that display is undone moments after it lands.
enum SpaceAssignments {
    enum Binding: Equatable {
        case desktop(spaceId: Int)
        case allDesktops
        /// Assigned to a desktop that no longer exists; macOS ignores it.
        case missing(uuid: String)
    }

    struct Assignment: Equatable {
        let bundleId: String
        let binding: Binding
    }

    private static let domain = "com.apple.spaces" as CFString
    private static let key = "app-bindings" as CFString

    /// `app-bindings` maps lowercased bundle ids to a desktop UUID or "AllSpaces".
    static func parse(_ bindings: [String: Any], spaceIdsByUUID: [String: Int]) -> [Assignment] {
        bindings.compactMap { bundleId, value -> Assignment? in
            guard let value = value as? String else { return nil }
            if value == "AllSpaces" { return Assignment(bundleId: bundleId, binding: .allDesktops) }
            if let spaceId = spaceIdsByUUID[value] {
                return Assignment(bundleId: bundleId, binding: .desktop(spaceId: spaceId))
            }
            return Assignment(bundleId: bundleId, binding: .missing(uuid: value))
        }
        .sorted { $0.bundleId < $1.bundleId }
    }

    static func current() -> [Assignment] {
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        return parse(raw, spaceIdsByUUID: WindowTiler.spaceIdsByUUID())
    }

    static func binding(forBundleId bundleId: String?, in assignments: [Assignment]) -> Binding? {
        guard let bundleId = bundleId?.lowercased() else { return nil }
        return assignments.first(where: { $0.bundleId == bundleId })?.binding
    }

    static func binding(forPid pid: pid_t, in assignments: [Assignment] = current()) -> Binding? {
        binding(forBundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, in: assignments)
    }

    /// The assigned desktop a move to `spaceId` would fight, or nil when
    /// macOS lets the window stay there. An assignment only holds on its own
    /// display; another display keeps the window where it is put.
    static func conflict(_ binding: Binding?, destinationSpaceId spaceId: Int, displays: [DisplaySpaces]) -> Int? {
        guard case .desktop(let assigned)? = binding, assigned != spaceId,
              let display = displays.first(where: { $0.spaces.contains(where: { $0.id == assigned }) }),
              display.spaces.contains(where: { $0.id == spaceId }) else { return nil }
        return assigned
    }

    static func json(_ assignment: Assignment, displays: [DisplaySpaces]) -> JSON {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.lowercased() == assignment.bundleId }
        var object: [String: JSON] = [
            "bundleId": .string(assignment.bundleId),
            "app": running?.localizedName.map { JSON.string($0) } ?? .null,
            "running": .bool(running != nil),
        ]
        switch assignment.binding {
        case .allDesktops:
            object["assignedTo"] = .string("all")
        case .missing:
            object["assignedTo"] = .string("missing")
        case .desktop(let spaceId):
            object["assignedTo"] = .string("desktop")
            object["spaceId"] = .int(spaceId)
            if let display = displays.first(where: { $0.spaces.contains(where: { $0.id == spaceId }) }),
               let space = display.spaces.first(where: { $0.id == spaceId }) {
                object["display"] = .int(display.displayIndex)
                object["desktop"] = .int(space.index)
            }
        }
        return .object(object)
    }

    /// "Desktop 3 on DELL S3422DWG", for messages.
    static func describe(spaceId: Int, displays: [DisplaySpaces]) -> String {
        guard let display = displays.first(where: { $0.spaces.contains(where: { $0.id == spaceId }) }),
              let space = display.spaces.first(where: { $0.id == spaceId }) else { return "desktop \(spaceId)" }
        let name: String? = {
            let lookup = { DisplayGeometryMapper.screen(for: display, in: NSScreen.screens)?.localizedName }
            return Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
        }()
        return "Desktop \(space.index)" + (name.map { " on \($0)" } ?? "")
    }
}
