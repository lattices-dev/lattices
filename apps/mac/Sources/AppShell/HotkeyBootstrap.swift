import AppKit
import Carbon

enum HotkeyBootstrap {
    static func registerHotkeys() {
        let store = HotkeyStore.shared
        store.register(action: .workspaceAssistant) { AssistantAccess.show() }
        store.register(action: .unifiedWindow) { ScreenMapWindowController.shared.toggle() }
        store.register(action: .screenMap) { ScreenMapWindowController.shared.showPage(.overview) }
        store.register(action: .bezel) { WorkspaceInspectorPresenter.show() }
        store.register(action: .cheatSheet) { SettingsWindowController.shared.show(section: "shortcuts") }
        store.register(action: .desktopInventory) {
            DiagnosticLog.shared.info("Hotkey: desktopInventory triggered")
            ScreenMapWindowController.shared.showPage(.overview)
        }
        store.register(action: .voiceCommand) {
            DiagnosticLog.shared.info("Hotkey: voiceCommand triggered")
            UnifiedCommandBarWindow.shared.toggle(mode: .voice)
        }
        store.register(action: .handsOff) {
            DiagnosticLog.shared.info("Hotkey: handsOff triggered")
            HandsOffSession.shared.toggle()
            if HandsOffSession.shared.state != .idle {
                HUDController.shared.showVoiceBar()
            } else {
                HUDController.shared.hideVoiceBar()
            }
        }
        store.register(action: .hud) { HUDController.shared.toggle() }
        store.register(action: .mouseFinder) { MouseFinder.shared.find() }
        store.register(action: .overlayActors) { ScreenOverlayCanvasController.shared.toggleAgentActorsVisibility() }
        store.register(action: .gridPlacement) {
            TilePointerController.shared.cancelApply()
            GridPlacementWindow.shared.toggle()
        }
        // The single command-surface hotkey: opens the merged bar (browse +
        // search; "/" for slash commands).
        store.register(action: .commandBar) {
            TilePointerController.shared.cancelApply()
            UnifiedCommandBarWindow.shared.toggle(mode: .search)
        }
        store.register(action: .focusMode) { FocusModeController.shared.toggle() }
        store.register(action: .stageMode) { StageModeController.shared.toggle() }
        store.register(action: .activityLog) {
            DiagnosticLog.shared.info("Hotkey: activityLog triggered")
            ScreenMapWindowController.shared.showPage(.activity)
        }

        registerLayerHotkeys(store: store)
        LayerChordMonitor.shared.start()
        DisplayGather.shared.start()
        registerTilingHotkeys(store: store)
    }

    private static func registerLayerHotkeys(store: HotkeyStore) {
        store.register(action: .layerPrev) { stepLayer(.left, action: .layerPrev) }
        store.register(action: .layerNext) { stepLayer(.right, action: .layerNext) }
        store.register(action: .layerUp) { stepLayer(.up, action: .layerUp) }
        store.register(action: .layerDown) { stepLayer(.down, action: .layerDown) }
        store.register(action: .layerTag) { WorkspaceManager.shared.addFrontmostWindowToActiveLayer() }

        for (offset, action) in HotkeyAction.layerActions.enumerated() {
            let slot = offset + 1
            store.register(action: action) { selectSlot(slot, action: action) }
        }

        // ⌘⌥ + numpad 1–9 reach the same slots: 1 2 3 is the pad's top row,
        // as on the bezel. Fixed, beside the rebindable top-row digits.
        let keypadKeyCodes: [UInt32] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (offset, keyCode) in keypadKeyCodes.enumerated() {
            let slot = offset + 1
            HotkeyManager.shared.registerSingle(
                id: 121 + UInt32(offset),
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | optionKey)
            ) { selectSlot(slot) }
        }

        // ⌘⌥0 and ⌘⌥ numpad 0: Classic, every window back as if Lattices
        // weren't running. Again: Classic · one space.
        for (offset, keyCode) in [UInt32(29), 82].enumerated() {
            HotkeyManager.shared.registerSingle(
                id: 130 + UInt32(offset),
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | optionKey)
            ) {
                LayerAim.shared.cancel()
                WorkspaceManager.shared.showClassic()
            }
        }

        // ⌘⌥Z takes back the last layer edit.
        HotkeyManager.shared.registerSingle(
            id: 132,
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: UInt32(cmdKey | optionKey)
        ) {
            LayerAim.shared.cancel()
            WorkspaceManager.shared.undoLayerEditFromHotkey()
        }
    }

    /// Cmd+Opt+N aims at the layer in slot N of the pad; letting go of ⌘⌥
    /// asks to switch to it (`LayerAim`). The middle slot, and any slot without a
    /// layer, drops the aim and shows where you are instead.
    private static func selectSlot(_ slot: Int, action: HotkeyAction? = nil) {
        if LayerPreview.shared.select(slot: slot) { return }
        let workspace = WorkspaceManager.shared
        guard let index = LayerSlots.index(forSlot: slot), workspace.layers.indices.contains(index) else {
            LayerAim.shared.cancel()
            showCurrentLayer()
            return
        }
        LayerAim.shared.aim(at: index, binding: action.flatMap { HotkeyStore.shared.bindings[$0] })
        LayerPreview.shared.arm()
    }

    /// Shows the bezel on the layer you're on, without switching.
    static func showCurrentLayer() {
        let workspace = WorkspaceManager.shared
        let layers = workspace.layers
        guard !layers.isEmpty else { return }
        let current = min(max(workspace.activeLayerIndex, 0), layers.count - 1)
        workspace.showBezel(for: current, in: layers)
        LayerPreview.shared.arm()
    }

    /// Cmd+Opt+arrows aim across the pad the way they point, from the layer
    /// last aimed at; letting go of ⌘⌥ asks to switch (`LayerAim`). They hop the
    /// middle and don't wrap: at the pad's edge, the lit slot bumps the way
    /// you pushed.
    private static func stepLayer(_ direction: LayerSlots.Direction, action: HotkeyAction) {
        // Frozen on a preview (Space mid-flip), its tap browses instead.
        if LayerPreview.shared.step(direction) { return }
        let workspace = WorkspaceManager.shared
        let layers = workspace.layers
        guard !layers.isEmpty else { return }
        let from = LayerAim.shared.origin(in: workspace)
        guard let index = LayerSlots.neighbour(of: from, direction, count: layers.count) else {
            LayerAim.shared.bump(direction)
            return
        }
        LayerAim.shared.aim(at: index, binding: HotkeyStore.shared.bindings[action])
        LayerPreview.shared.arm()
    }

    private static func registerTilingHotkeys(store: HotkeyStore) {
        let tileMap: [(HotkeyAction, TilePosition)] = [
            (.tileLeft, .left), (.tileRight, .right),
            (.tileMaximize, .maximize), (.tileCenter, .center),
            (.tileTopLeft, .topLeft), (.tileTopRight, .topRight),
            (.tileBottomLeft, .bottomLeft), (.tileBottomRight, .bottomRight),
            (.tileTop, .top), (.tileBottom, .bottom),
            (.tileLeftThird, .leftThird), (.tileCenterThird, .centerThird),
            (.tileRightThird, .rightThird),
        ]
        for (action, position) in tileMap {
            store.register(action: action) {
                guard !TilePointerController.shared.shouldSuppressTilingHotkey(action) else { return }
                TilePointerController.shared.cancelApply()
                if WindowMotionMode.shared.tileCurrentTarget(to: position) { return }
                let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? NSScreen.main
                TileZoneOverlay.shared.show(position: position, on: screen, autoHideAfter: 0.28)
                WindowTiler.tileFrontmostViaAX(to: position)
            }
        }
        store.register(action: .tileDistribute) {
            WindowTiler.distributeVisible(reactivateLattices: false)
        }
        store.register(action: .tileTypeGrid) {
            WindowTiler.distributeVisibleByFrontmostType(reactivateLattices: false)
        }
        store.register(action: .tileOrganize) {
            let appName = DesktopModel.shared.frontmostWindow()?.app
                ?? NSWorkspace.shared.frontmostApplication?.localizedName
            CommandModeWindow.shared.show(launchMode: .organize(appName: appName))
        }
        store.register(action: .tileOpenCell) {
            TilePointerController.shared.cancelApply()
            FrontWindowPlacer.fillOpenGridCell()
        }
        store.register(action: .motionMode) {
            TilePointerController.shared.cancelApply()
            WindowMotionMode.shared.toggleHyperspace()
        }
        store.register(action: .inPlaceMode) {
            TilePointerController.shared.cancelApply()
            WindowMotionMode.shared.toggleInPlace()
        }
        store.register(action: .chordHints) {
            TilePointerController.shared.cancelApply()
            InPlaceChordHintOverlay.shared.toggle()
        }
    }
}
