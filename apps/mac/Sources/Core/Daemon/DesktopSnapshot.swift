import Foundation

/// One-call situational awareness for agents. Does not recapture windows or OCR.
enum DesktopSnapshot {
    static func build(includeOffscreen: Bool = false) -> JSON {
        let desktop = DesktopModel.shared
        let windows = desktop.allWindows().filter { includeOffscreen || $0.isOnScreen }
        let front = desktop.frontmostWindow()
        let focusedId = desktop.focusedWindow()?.wid
        let displays = Encoders.displays()
        let currentSpaceId = currentSpaceId(for: front, displays: displays)

        var obj: [String: JSON] = [
            "displays": displays,
            "currentSpaceId": currentSpaceId.map { .int($0) } ?? .null,
            "windows": .array(windows.map { Encoders.snapshotWindow($0, focusedWid: focusedId) }),
            "sessions": .array(TmuxModel.shared.sessionSnapshot.map { session in
                .object([
                    "name": .string(session.name),
                    "attached": .bool(session.attached),
                    "windowCount": .int(session.windowCount),
                ])
            }),
            "permissions": PermissionChecker.shared.snapshotJSON(),
        ]

        if let front {
            obj["frontmost"] = Encoders.frontmost(front)
        } else {
            obj["frontmost"] = .null
        }

        if let layer = WorkspaceManager.shared.activeLayer {
            // The layer as `layers.members` reports it: the windows it holds, on any desktop.
            let read = { () -> JSON? in
                let wm = WorkspaceManager.shared
                return wm.overviews(in: desktop.allWindows()).first(where: \.isActive).map { wm.layerMembersJSON($0) }
            }
            let members = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
            obj["activeLayer"] = members ?? .object([
                "id": .string(layer.id),
                "index": .int(WorkspaceManager.shared.activeLayerIndex),
            ])
        } else {
            obj["activeLayer"] = .null
        }

        return .object(obj)
    }

    private static func currentSpaceId(for front: WindowEntry?, displays: JSON) -> Int? {
        guard case .array(let items) = displays else { return nil }
        let displayCurrentIds: [Int] = items.compactMap { item in
            guard case .object(let obj) = item else { return nil }
            return obj["currentSpaceId"]?.intValue
        }
        if let frontIds = front?.spaceIds, !frontIds.isEmpty {
            if let match = frontIds.first(where: { displayCurrentIds.contains($0) }) {
                return match
            }
            return frontIds.first
        }
        return displayCurrentIds.first
    }
}
