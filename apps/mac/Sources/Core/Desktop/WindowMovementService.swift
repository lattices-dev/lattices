import AppKit
import SwiftUI

// MARK: - Menu Model (pure)

/// Pure description of the immediate window-movement context menu shared by
/// Desktop Inventory and Studio. Holds no AppKit state so the cycle/wrap,
/// current-display, and multi-selection rules are unit-testable.
struct WindowMoveMenuModel: Equatable {
    struct Display: Equatable {
        /// API display index (SkyLight topology order), as accepted by
        /// `window.move` / `window.place`.
        let index: Int
        let name: String
        /// True when this is the clicked window's display.
        let isCurrent: Bool
        var desktops: [Desktop] = []
    }

    struct Desktop: Equatable {
        let displayIndex: Int
        let displayName: String
        let spaceId: Int
        let number: Int
        /// Whether the anchor window actually belongs to this Space.
        var isCurrent = false
        /// Whether this Desktop is currently showing on its display.
        var isShowing = false
        /// macOS assigns the window's app to another desktop on this display
        /// (Dock › Assign To) and would pull the window back there.
        var isRefused = false

        var title: String { "\(displayName) · Desktop \(number)" }
    }

    struct Target: Equatable {
        let wid: UInt32
        let pid: Int32
    }

    let displays: [Display]
    let targets: [Target]
    /// Captured from the UI host screen, never from the window being moved.
    var here: Desktop? = nil

    /// Slot presets offered by Move & Place: the canonical named
    /// `PlacementSpec` positions kept to a scannable set (maximize, center,
    /// halves, quarters, thirds). The full catalog stays available through
    /// Tile Window, the CLI, and the API.
    static let placementSlots: [TilePosition] = [
        .maximize, .center,
        .left, .right, .top, .bottom,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird,
    ]

    /// Right-click target rule shared by Inventory and Studio: a click on a
    /// member of an existing multi-selection targets the whole selection; any
    /// other click targets just the clicked window.
    static func resolveTargets(clicked: Target, selection: [Target]) -> [Target] {
        if selection.count > 1, selection.contains(clicked) { return selection }
        return [clicked]
    }

    /// Desktop movement is available on one-display systems too.
    var isAvailable: Bool {
        !targets.isEmpty && (displays.count > 1 || displays.contains { !$0.desktops.isEmpty })
    }

    var targetCount: Int { targets.count }

    var currentDisplay: Display? { displays.first(where: \.isCurrent) }

    /// Deterministic next display: one step through the display topology from
    /// the clicked window's display, wrapping at the end. When the anchor
    /// display cannot be resolved, cycling starts from the first display.
    var nextDisplay: Display? {
        guard isAvailable, displays.count > 1 else { return nil }
        guard let position = displays.firstIndex(where: \.isCurrent) else {
            return displays.first
        }
        return displays[(position + 1) % displays.count]
    }

    private var countPrefix: String {
        targetCount > 1 ? "Move \(targetCount) Windows" : "Move"
    }

    var nextMonitorTitle: String { "\(countPrefix) to Next Monitor" }
    var moveToMonitorTitle: String { "\(countPrefix) to Monitor" }
    var movePlaceTitle: String { "Move & Place" }

    /// Move & Place is single-window only: several windows sent to the same
    /// slot would stack into one overlapping pile.
    var includesPlacement: Bool { isAvailable && displays.count > 1 && targetCount == 1 }

    var bringHereTitle: String {
        let prefix = targetCount > 1 ? "Bring \(targetCount) Windows Here" : "Bring Here"
        return here.map { "\(prefix) — \($0.title)" } ?? prefix
    }

    func isDisabled(_ desktop: Desktop) -> Bool {
        (desktop.isCurrent || desktop.isRefused) && targetCount == 1
    }

    func moveAccessibilityLabel(to desktop: Desktop) -> String {
        targetCount > 1
            ? "Move \(targetCount) windows to \(desktop.title)"
            : "Move window to \(desktop.title)"
    }

    /// The anchor display is unpickable only for a single-window menu. A
    /// multi-selection can span monitors, so its members may legitimately
    /// gather onto the clicked window's display; it stays checked as the
    /// anchor but remains selectable.
    func isDisabled(_ display: Display) -> Bool {
        display.isCurrent && targetCount == 1
    }

    func moveAccessibilityLabel(to display: Display) -> String {
        targetCount > 1
            ? "Move \(targetCount) windows to \(display.name)"
            : "Move window to \(display.name)"
    }

    func placeAccessibilityLabel(slot: TilePosition, on display: Display) -> String {
        "Move window to \(display.name) and place \(slot.label)"
    }
}

// MARK: - Movement Service

/// Shared immediate-movement engine for the UI surfaces. Inventory and Studio
/// both build a `WindowMoveMenuModel` here and execute through the same
/// canonical `ActionRuntime` paths as `window.move` / `window.place`, so the
/// app, CLI, and API cannot drift.
enum WindowMovementService {
    struct Outcome {
        let ok: Bool
        let message: String
        /// Windows whose move actually executed and verified (`status == "ok"`).
        /// Blocked/failed/unverified targets are excluded so callers reconcile
        /// only windows that truly changed.
        let movedWids: [UInt32]
    }

    /// Live displays in physical left-to-right order, while preserving the
    /// stable SkyLight/API identity required by ActionRuntime. Main thread only.
    /// `anchorScreen` marks the clicked window's display.
    static func displays(anchorScreen: NSScreen?) -> [WindowMoveMenuModel.Display] {
        let topology = DisplayTopology.live()
        let anchorID = anchorScreen.map(ScreenOverlayCanvasController.screenID(for:))
        return topology.spatialOrder.map { display in
            return WindowMoveMenuModel.Display(
                index: display.apiIndex,
                name: display.name,
                isCurrent: display.id == anchorID
            )
        }
    }

    /// Menu model anchored on a window's global top-left frame (Inventory).
    static func menuModel(
        windowFrame: WindowFrame,
        targets: [WindowMoveMenuModel.Target],
        anchorWid: UInt32? = nil,
        hostScreen: NSScreen? = nil
    ) -> WindowMoveMenuModel {
        let spaces = WindowTiler.getDisplaySpaces()
        let memberships = anchorWid.map { WindowTiler.getSpacesForWindow($0) } ?? []
        let binding = targets.count == 1 ? targets.first.flatMap { SpaceAssignments.binding(forPid: $0.pid) } : nil
        let hostId = hostScreen.map(ScreenOverlayCanvasController.screenID(for:))
        let hostIndex = DisplayTopology.live().displays.first { $0.id == hostId }?.apiIndex
        var displayModels = displays(anchorScreen: WindowTiler.screenForWindowFrame(windowFrame))
        for index in displayModels.indices {
            let display = displayModels[index]
            let owned = spaces.first { $0.displayIndex == display.index }
            displayModels[index].desktops = (owned?.spaces ?? []).map { space in
                WindowMoveMenuModel.Desktop(
                    displayIndex: display.index, displayName: display.name,
                    spaceId: space.id, number: space.index,
                    isCurrent: memberships.contains(space.id),
                    isShowing: owned?.currentSpaceId == space.id,
                    isRefused: SpaceAssignments.conflict(binding, destinationSpaceId: space.id, displays: spaces) != nil
                )
            }
        }
        return WindowMoveMenuModel(
            displays: displayModels, targets: targets,
            here: displayModels.first { $0.index == hostIndex }?.desktops.first(where: \.isShowing)
        )
    }

    /// Used by Overview and both context-menu surfaces. A success requires
    /// the runtime's verification, never an AX call merely returning success.
    static func failureMessage(for receipt: JSON) -> String? {
        if receipt["status"]?.stringValue == "ok", receipt["verified"]?.boolValue == true { return nil }
        if receipt["status"]?.stringValue == "blocked" {
            return receipt["message"]?.stringValue ?? receipt["blockedReason"]?.stringValue ?? "Grant Accessibility to move windows"
        }
        return receipt["failureReason"]?.stringValue
            ?? receipt["message"]?.stringValue
            ?? "Move not verified; the window did not reach the requested display and Desktop"
    }

    static func moveTargets(
        _ targets: [WindowMoveMenuModel.Target],
        to desktop: WindowMoveMenuModel.Desktop,
        completion: @escaping (Outcome) -> Void
    ) {
        run(completion: completion) {
            var moved: [UInt32] = []
            var failures: [String] = []
            for target in targets {
                do {
                    let receipt = try ActionRuntime.shared.executeWindowMove(
                        params: .object([
                            "wid": .int(Int(target.wid)),
                            "display": .int(desktop.displayIndex),
                            "spaceId": .int(desktop.spaceId),
                        ]), source: "app.context-menu"
                    )
                    if let failure = failureMessage(for: receipt) { failures.append(failure) }
                    else { moved.append(target.wid) }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if let failure = failures.first {
                let prefix = moved.isEmpty ? "" : "Moved \(moved.count)/\(targets.count) windows. "
                return Outcome(ok: false, message: prefix + failure, movedWids: moved)
            }
            return moveOutcome(okWids: moved, total: targets.count, blocked: false, displayName: desktop.title)
        }
    }

    /// Move each target to `display`, preserving each window's own normalized
    /// frame — canonical `window.move` display-only semantics, one receipt per
    /// window. Runs off the main thread; `completion` is delivered on main.
    static func moveTargets(
        _ targets: [WindowMoveMenuModel.Target],
        to display: WindowMoveMenuModel.Display,
        completion: @escaping (Outcome) -> Void
    ) {
        run(completion: completion) {
            var okWids: [UInt32] = []
            var blocked = false
            for target in targets {
                let params = JSON.object([
                    "wid": .int(Int(target.wid)),
                    "display": .int(display.index),
                ])
                do {
                    let receipt = try ActionRuntime.shared.executeWindowMove(params: params, source: "app.context-menu")
                    switch receipt["status"]?.stringValue {
                    case "ok" where receipt["verified"]?.boolValue == true: okWids.append(target.wid)
                    case "blocked": blocked = true
                    default: break
                    }
                } catch {
                    DiagnosticLog.shared.error("[Move] wid \(target.wid) → display \(display.index): \(error)")
                }
            }
            return moveOutcome(okWids: okWids, total: targets.count, blocked: blocked, displayName: display.name)
        }
    }

    /// Move one window to `display` and place it into a canonical slot —
    /// `window.place` semantics through the same runtime as the API.
    static func placeTarget(
        _ target: WindowMoveMenuModel.Target,
        on display: WindowMoveMenuModel.Display,
        slot: TilePosition,
        completion: @escaping (Outcome) -> Void
    ) {
        placeTarget(
            target,
            on: display,
            placement: .tile(slot),
            placementLabel: slot.label,
            source: "app.context-menu",
            completion: completion
        )
    }

    /// Place one window using any canonical PlacementSpec. Spatial Lens uses
    /// this for its two-thirds cycle while context menus continue to pass named
    /// tile slots through the convenience overload above.
    static func placeTarget(
        _ target: WindowMoveMenuModel.Target,
        on display: WindowMoveMenuModel.Display,
        placement: PlacementSpec,
        placementLabel: String,
        source: String,
        completion: @escaping (Outcome) -> Void
    ) {
        run(completion: completion) {
            let params = JSON.object([
                "wid": .int(Int(target.wid)),
                "display": .int(display.index),
                "placement": placement.jsonValue,
            ])
            do {
                let receipt = try ActionRuntime.shared.executeWindowPlace(params: params, source: source)
                switch receipt["status"]?.stringValue {
                case "ok":
                    return Outcome(ok: true, message: "Placed \(placementLabel) on \(display.name)", movedWids: [target.wid])
                case "blocked":
                    return Outcome(ok: false, message: "Grant Accessibility to move windows", movedWids: [])
                default:
                    return Outcome(ok: false, message: "Placement not verified on \(display.name)", movedWids: [])
                }
            } catch {
                DiagnosticLog.shared.error("[Place] wid \(target.wid) → display \(display.index) \(placement.wireValue): \(error)")
                return Outcome(ok: false, message: "Placement failed: \(shortError(error))", movedWids: [])
            }
        }
    }

    /// Truthful receipt: full success, blocked-on-permissions, partial, and
    /// executed-but-unverified are reported as what they are, and only the
    /// wids that verifiably moved are carried for reconciliation.
    static func moveOutcome(okWids: [UInt32], total: Int, blocked: Bool, displayName: String) -> Outcome {
        let okCount = okWids.count
        if okCount == total {
            let message = total > 1
                ? "Moved \(total) windows to \(displayName)"
                : "Moved to \(displayName)"
            return Outcome(ok: true, message: message, movedWids: okWids)
        }
        if blocked, okCount == 0 {
            return Outcome(ok: false, message: "Grant Accessibility to move windows", movedWids: [])
        }
        if okCount > 0 {
            return Outcome(ok: false, message: "Moved \(okCount)/\(total) windows to \(displayName)", movedWids: okWids)
        }
        return Outcome(ok: false, message: "Move not verified — window may not have reached \(displayName)", movedWids: [])
    }

    private static func run(
        completion: @escaping (Outcome) -> Void,
        work: @escaping () -> Outcome
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = work()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func shortError(_ error: Error) -> String {
        error.localizedDescription
    }
}

// MARK: - SwiftUI menu section

/// The shared movement section rendered inside a SwiftUI `contextMenu`.
/// Includes absolute Desktop destinations on every attached display. Callers
/// gate their dividers on `model.isAvailable` so no orphan separators remain.
struct WindowMovementMenuSection: View {
    let model: WindowMoveMenuModel
    let onMove: (WindowMoveMenuModel.Display) -> Void
    var onMoveDesktop: ((WindowMoveMenuModel.Desktop) -> Void)? = nil
    var onPlace: ((WindowMoveMenuModel.Display, TilePosition) -> Void)? = nil

    var body: some View {
        if model.isAvailable {
            if let onMoveDesktop {
                if let here = model.here, !model.isDisabled(here) {
                    Button(model.bringHereTitle) { onMoveDesktop(here) }
                        .accessibilityLabel(model.bringHereTitle)
                }
                Menu("Move to Desktop") {
                    ForEach(model.displays, id: \.index) { display in
                        Section(display.name) {
                            ForEach(display.desktops, id: \.spaceId) { desktop in
                                Button {
                                    onMoveDesktop(desktop)
                                } label: {
                                    if desktop.isCurrent { Label(desktop.title, systemImage: "checkmark") }
                                    else { Text(desktop.title) }
                                }
                                .disabled(model.isDisabled(desktop))
                                .accessibilityLabel(model.moveAccessibilityLabel(to: desktop))
                            }
                        }
                    }
                }
            }
            if let next = model.nextDisplay {
                Button {
                    onMove(next)
                } label: {
                    Label(model.nextMonitorTitle, systemImage: "arrow.right.square")
                }
                .accessibilityLabel(model.moveAccessibilityLabel(to: next))
            }

            if model.displays.count > 1 {
                Menu(model.moveToMonitorTitle) {
                    ForEach(model.displays, id: \.index) { display in
                        Button {
                            onMove(display)
                        } label: {
                            if display.isCurrent {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                        .disabled(model.isDisabled(display))
                        .accessibilityLabel(model.moveAccessibilityLabel(to: display))
                    }
                }

            }
            if model.includesPlacement, let onPlace, let target = model.targets.first {
                Menu(model.movePlaceTitle) {
                    ForEach(model.displays, id: \.index) { display in
                        Menu(display.isCurrent ? "\(display.name) (Current)" : display.name) {
                            ForEach(WindowMoveMenuModel.placementSlots) { slot in
                                Button {
                                    onPlace(display, slot)
                                } label: {
                                    Label(slot.label, systemImage: slot.icon)
                                }
                                .accessibilityLabel(model.placeAccessibilityLabel(slot: slot, on: display))
                            }
                        }
                    }
                }
                .accessibilityLabel("Move window \(target.wid) to a monitor and slot")
            }
        }
    }
}

// MARK: - AppKit menu section

/// Closure box carried on `NSMenuItem.representedObject`.
final class WindowMovementMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

final class WindowMovementMenuTarget: NSObject {
    static let shared = WindowMovementMenuTarget()

    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? WindowMovementMenuAction)?.run()
    }
}

/// AppKit twin of `WindowMovementMenuSection` for `NSMenu`-based surfaces
/// (the Studio canvas). Same model, same ordering, same titles.
enum WindowMovementMenuBuilder {
    static func appendSection(
        to menu: NSMenu,
        model: WindowMoveMenuModel,
        onMove: @escaping (WindowMoveMenuModel.Display) -> Void,
        onMoveDesktop: ((WindowMoveMenuModel.Desktop) -> Void)? = nil,
        onPlace: ((WindowMoveMenuModel.Display, TilePosition) -> Void)? = nil
    ) {
        guard model.isAvailable else { return }

        if let onMoveDesktop {
            if let here = model.here, !model.isDisabled(here) {
                menu.addItem(actionItem(title: model.bringHereTitle, accessibilityLabel: model.bringHereTitle) {
                    onMoveDesktop(here)
                })
            }
            let desktopsItem = NSMenuItem(title: "Move to Desktop", action: nil, keyEquivalent: "")
            let desktopsMenu = NSMenu()
            for display in model.displays {
                if !desktopsMenu.items.isEmpty { desktopsMenu.addItem(.separator()) }
                for desktop in display.desktops {
                    let item: NSMenuItem
                    if model.isDisabled(desktop) {
                        item = NSMenuItem(title: desktop.title, action: nil, keyEquivalent: "")
                    } else {
                        item = actionItem(title: desktop.title, accessibilityLabel: model.moveAccessibilityLabel(to: desktop)) {
                            onMoveDesktop(desktop)
                        }
                    }
                    if desktop.isCurrent { item.state = .on }
                    if desktop.isRefused { item.toolTip = "Assigned to another desktop in macOS" }
                    desktopsMenu.addItem(item)
                }
            }
            desktopsItem.submenu = desktopsMenu
            menu.addItem(desktopsItem)
        }
        if let next = model.nextDisplay {
            menu.addItem(actionItem(
                title: model.nextMonitorTitle,
                accessibilityLabel: model.moveAccessibilityLabel(to: next)
            ) { onMove(next) })
        }

        if model.displays.count > 1 {
            let moveItem = NSMenuItem(title: model.moveToMonitorTitle, action: nil, keyEquivalent: "")
            let moveSubmenu = NSMenu()
            for display in model.displays {
                if model.isDisabled(display) {
                    // No action → auto-disabled; checkmark marks the current display.
                    let item = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
                    item.state = .on
                    item.setAccessibilityLabel("\(display.name), current display")
                    moveSubmenu.addItem(item)
                } else {
                    let item = actionItem(
                        title: display.name,
                        accessibilityLabel: model.moveAccessibilityLabel(to: display)
                    ) { onMove(display) }
                    if display.isCurrent { item.state = .on }
                    moveSubmenu.addItem(item)
                }
            }
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)
        }
        guard model.includesPlacement, let onPlace else { return }
        let placeItem = NSMenuItem(title: model.movePlaceTitle, action: nil, keyEquivalent: "")
        let placeSubmenu = NSMenu()
        for display in model.displays {
            let title = display.isCurrent ? "\(display.name) (Current)" : display.name
            let displayItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let slotSubmenu = NSMenu()
            for slot in WindowMoveMenuModel.placementSlots {
                slotSubmenu.addItem(actionItem(
                    title: slot.label,
                    accessibilityLabel: model.placeAccessibilityLabel(slot: slot, on: display)
                ) { onPlace(display, slot) })
            }
            displayItem.submenu = slotSubmenu
            placeSubmenu.addItem(displayItem)
        }
        placeItem.submenu = placeSubmenu
        menu.addItem(placeItem)
    }

    private static func actionItem(
        title: String,
        accessibilityLabel: String,
        run: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(WindowMovementMenuTarget.perform(_:)),
            keyEquivalent: ""
        )
        item.target = WindowMovementMenuTarget.shared
        item.representedObject = WindowMovementMenuAction(run)
        item.setAccessibilityLabel(accessibilityLabel)
        return item
    }
}
