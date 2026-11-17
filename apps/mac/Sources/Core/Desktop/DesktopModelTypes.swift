import Foundation

struct WindowEntry: Codable, Identifiable, Equatable {
    let wid: UInt32
    let app: String
    let pid: Int32
    let title: String
    var frame: WindowFrame
    let spaceIds: [Int]
    let isOnScreen: Bool
    let latticesSession: String?
    var cgLayer: Int? = nil // Raw WindowServer layer, not a Lattices workspace layer
    var axVerified: Bool = true
    var zIndex: Int = 0 // 0 = frontmost, from CGWindowList order
    var bundleId: String? = nil
    /// The app is hidden. Its windows keep their Space and, via `collapsed`,
    /// their frame.
    var appHidden: Bool = false
    /// CGWindowList gave a collapsed frame (1×1 for a hidden app on macOS
    /// 27); `frame` is the true one, from the WindowServer, AX or a past poll.
    var collapsed: Bool = false
    /// The title as AX gives it, when AX has seen the window. CG elides long
    /// titles in the middle; this one is whole.
    var fullTitle: String? = nil
    /// AX has listed it, this poll or an earlier one. AX can't see other
    /// desktops, so `axVerified` alone doesn't say a window is real.
    var axListed: Bool = false

    var id: UInt32 { wid }

    var hasTitle: Bool { !title.isEmpty || !(fullTitle ?? "").isEmpty }

    /// `title` or `fullTitle` contains `needle`, ignoring case.
    func titleContains(_ needle: String) -> Bool {
        title.localizedCaseInsensitiveContains(needle)
            || (fullTitle?.localizedCaseInsensitiveContains(needle) ?? false)
    }
}

struct WindowFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

// MARK: - Desktop Inventory Snapshot

struct DesktopInventorySnapshot {
    let displays: [DisplayInfo]
    let timestamp: Date

    struct DisplayInfo: Identifiable {
        let id: String           // display UUID or index
        let name: String         // e.g. "Built-in Retina", "LG UltraFine"
        let resolution: (w: Int, h: Int)
        let visibleFrame: (w: Int, h: Int)
        let isMain: Bool
        let spaceCount: Int
        let currentSpaceIndex: Int
        let spaces: [SpaceGroup]
    }

    struct SpaceGroup: Identifiable {
        let id: Int              // CGS space ID
        let index: Int           // 1-based index within display
        let isCurrent: Bool
        let apps: [AppGroup]
    }

    struct AppGroup: Identifiable {
        let id: String           // unique key (spaceId-appName)
        let appName: String
        let windows: [InventoryWindowInfo]
    }

    struct InventoryWindowInfo: Identifiable {
        let id: UInt32           // CGWindowID
        let pid: Int32           // owner PID for AX operations
        let title: String
        let frame: WindowFrame
        let tilePosition: TilePosition?
        let isLattices: Bool
        let latticesSession: String?
        let spaceIndex: Int?     // 1-based space index within display
        let isOnScreen: Bool     // on current space
        var inventoryPath: InventoryPath?
        var appName: String?     // owner app name for filtering
    }

    /// Flat list of all windows across all displays/spaces/apps
    var allWindows: [InventoryWindowInfo] {
        displays.flatMap { $0.spaces.flatMap { $0.apps.flatMap { $0.windows } } }
    }
}
