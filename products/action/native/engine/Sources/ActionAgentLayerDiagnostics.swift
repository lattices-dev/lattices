import CoreGraphics
import Foundation

/// Read-only LOG-phase evidence. Never changes modes, arrangement, focus, or windows.
/// CG can report an intermediate topology immediately after a lifecycle call; retain
/// every stage rather than treating the final sample as proof that reflow has settled.
enum ActionAgentLayerDiagnostics {
    static func snapshot(stage: String, layerDisplayID: CGDirectDisplayID, requestedSize: CGSize, result: String? = nil) -> String {
        var count: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = CGGetOnlineDisplayList(count, &ids, &count)
        let displays: [[String: Any]] = ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            var entry: [String: Any] = [
                "id": id,
                "bounds": rect(CGDisplayBounds(id)),
                "main": CGDisplayIsMain(id) != 0,
                "active": CGDisplayIsActive(id) != 0,
                "online": CGDisplayIsOnline(id) != 0,
                "builtIn": CGDisplayIsBuiltin(id) != 0,
                "inMirrorSet": CGDisplayIsInMirrorSet(id) != 0,
                "mirrorsDisplayID": CGDisplayMirrorsDisplay(id),
                "rotation": CGDisplayRotation(id),
                "vendorID": CGDisplayVendorNumber(id),
                "productID": CGDisplayModelNumber(id),
            ]
            if let mode {
                entry["mode"] = [
                    "id": mode.ioDisplayModeID,
                    "width": mode.width,
                    "height": mode.height,
                    "pixelWidth": mode.pixelWidth,
                    "pixelHeight": mode.pixelHeight,
                    "refreshRate": mode.refreshRate,
                ] as [String: Any]
            } else {
                entry["mode"] = NSNull()
            }
            return entry
        }
        // No AX traversal and no titles/content: window IDs join samples without
        // capturing user document names. Include offscreen windows to expose reflow.
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let windows: [[String: Any]] = (info ?? []).compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return [
                "id": id,
                "pid": window[kCGWindowOwnerPID as String] ?? NSNull(),
                "owner": window[kCGWindowOwnerName as String] ?? NSNull(),
                "onScreen": window[kCGWindowIsOnscreen as String] ?? NSNull(),
                "bounds": rect(bounds),
            ]
        }
        var payload: [String: Any] = [
            "event": "agent-layer.display-diagnostic",
            "schemaVersion": 1,
            "stage": stage,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "layerDisplayID": layerDisplayID,
            "requestedSize": ["width": requestedSize.width, "height": requestedSize.height],
            "displayCountResult": countResult.rawValue,
            "displayListResult": listResult.rawValue,
            "displays": displays,
            "windowsAvailable": info != nil,
            "windows": windows,
        ]
        if let result { payload["result"] = result }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"event\":\"agent-layer.display-diagnostic\",\"error\":\"serialization failed\"}"
        }
        return json
    }

    private static func rect(_ value: CGRect) -> [String: CGFloat] {
        ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
    }
}
