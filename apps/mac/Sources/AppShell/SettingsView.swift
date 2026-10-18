import DeckKit
import AVFoundation
import SwiftUI
import HudsonUI
#if LATTICES_VOICE && canImport(HudsonVoice)
import HudsonVoice
#endif

/// Settings content with internal General / Shortcuts tabs.
/// Can also render the Docs page when `page == .docs`.
struct SettingsContentView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case permissions
        case shortcuts
        case keyboard
        case mouse
        case eventViewer
        case hyperspace
        case voice
        case ai
        case search
        case companion
        case deck

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "About"
            case .permissions: return "Permissions"
            case .shortcuts: return "Shortcuts"
            case .keyboard: return "Keyboard"
            case .mouse: return "Mouse"
            case .eventViewer: return "Event Viewer"
            case .hyperspace: return "Hyperspace"
            case .voice: return "Voice"
            case .ai: return "AI"
            case .search: return "Search & OCR"
            case .companion: return "Companion"
            case .deck: return "Command Deck"
            }
        }

        var icon: String {
            switch self {
            case .general: return "info.circle"
            case .permissions: return "checkmark.shield"
            case .shortcuts: return "command"
            case .keyboard: return "keyboard"
            case .mouse: return "computermouse"
            case .eventViewer: return "waveform.path.ecg"
            case .hyperspace: return "square.grid.3x3.fill"
            case .voice: return "waveform.badge.mic"
            case .ai: return "sparkles"
            case .search: return "text.viewfinder"
            case .companion: return "ipad.and.iphone"
            case .deck: return "square.grid.2x2"
            }
        }

        var eyebrow: String {
            switch self {
            case .general: return "About"
            case .permissions: return "Access"
            case .shortcuts: return "Controls"
            case .keyboard: return "Keys"
            case .mouse: return "Input"
            case .eventViewer: return "Inspect"
            case .hyperspace: return "Survey"
            case .voice: return "Capture"
            case .ai: return "Agents"
            case .search: return "Indexing"
            case .companion: return "LATS iOS Bridge"
            case .deck: return "Companion"
            }
        }

        var summary: String {
            switch self {
            case .general:
                return "Version, updates, terminal defaults, project discovery, and detach behavior."
            case .permissions:
                return "macOS grants for window control, OCR, gestures, and voice."
            case .shortcuts:
                return "A full map of global hotkeys for workspace movement and tmux flow."
            case .keyboard:
                return "Caps Lock to Hyper, tap-for-Escape, and key-state recovery."
            case .mouse:
                return "Cursor marker defaults, middle-click gestures, HUD confirmation, and mappings."
            case .eventViewer:
                return "Live input events — what this machine’s mouse actually emits."
            case .hyperspace:
                return "Per-display window surveys, lighting, zoom, and layout for Hyperspace."
            case .voice:
                return "Lattices hosts the embedded voice runtime, microphone access, command shortcuts, and the provider-backed voice model."
            case .ai:
                return "Provider auth, chat readiness, and assistant runtime state."
            case .search:
                return "OCR cadence, quality, and recent capture visibility."
            case .companion:
                return "Local-network pairing, trusted iPad devices, and bridge security."
            case .deck:
                return "Design the companion command deck — the grid, keys, and spans the iPad renders."
            }
        }

        var group: String {
            switch self {
            case .general, .permissions, .shortcuts:
                return "General"
            case .keyboard, .mouse, .eventViewer, .hyperspace, .voice:
                return "Control"
            case .ai, .search:
                return "Intelligence"
            case .companion, .deck:
                return "Devices"
            }
        }

        /// Sections whose feature is compiled into this build.
        var isAvailable: Bool {
            switch self {
            case .companion, .deck: return LatticesTier.isBundle
            default: return true
            }
        }

        static var groupedCases: [(String, [SettingsSection])] {
            ["General", "Control", "Intelligence", "Devices"].compactMap { group in
                let sections = allCases.filter { $0.group == group && $0.isAvailable }
                return sections.isEmpty ? nil : (group, sections)
            }
        }
    }

    var page: AppPage = .settings
    @ObservedObject var prefs: Preferences
    @ObservedObject var scanner: ProjectScanner
    @ObservedObject var hotkeyStore: HotkeyStore = .shared
    @ObservedObject var workspaceManager: WorkspaceManager = .shared
    @ObservedObject var appUpdater: AppUpdater = .shared
    @ObservedObject var mouseShortcutStore: MouseShortcutStore = .shared
    @ObservedObject var keyboardRemapStore: KeyboardRemapStore = .shared
    @ObservedObject var permChecker: PermissionChecker = .shared
    @ObservedObject var mouseGestureController: MouseGestureController = .shared
    @ObservedObject var keyboardRemapController: KeyboardRemapController = .shared
    @ObservedObject var spaceSwitchInterceptor: SpaceSwitchInterceptor = .shared
    @ObservedObject var assistantSession: WorkspaceAssistantSession = .shared
    var onBack: (() -> Void)? = nil

    @State private var selectedTab: SettingsSection = .general
    @State private var keyboardRecoveryStatus: String?
    @State private var shortcutScope: ShortcutScope = .assigned

    private enum ShortcutScope: String, CaseIterable {
        case assigned
        case all
        var label: String {
            switch self {
            case .assigned: return "Assigned"
            case .all: return "All"
            }
        }
    }
    @FocusState private var assistantAuthFieldFocused: Bool

    // Hyperspace survey dials — same UserDefaults keys (and defaults) the in-survey
    // rig writes, so the two stay in lockstep. See ExposeView in WindowMotionMode.
    @AppStorage("hyperspace.ambient")    private var hsAmbient: Double = 0.5
    @AppStorage("hyperspace.keyLight")   private var hsKeyLight: Double = 0.4
    @AppStorage("hyperspace.keyAngle")   private var hsKeyAngle: Int = 0
    @AppStorage("hyperspace.spotlight")  private var hsSpotlight: Double = 0.3
    @AppStorage("hyperspace.temp")       private var hsTemp: Double = 0.5
    @AppStorage("hyperspace.sizeAuto")   private var hsSizeAuto: Bool = true
    @AppStorage("hyperspace.tileScale")  private var hsTileScale: Double = 1.0
    @AppStorage("hyperspace.layoutTall") private var hsLayoutTall: Bool = false
    @AppStorage("hyperspace.handKeys")   private var hsHandKeys: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Back bar
            backBar

            if page == .docs {
                docsContent
            } else {
                settingsBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(PanelBackground())
        .onAppear {
            permChecker.check()
            if page == .companionSettings, SettingsSection.companion.isAvailable {
                selectedTab = .companion
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticesShowGeneralSettings)) { _ in
            selectedTab = .general
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticesShowAssistantSettings)) { _ in
            selectedTab = .ai
        }
        .onReceive(NotificationCenter.default.publisher(for: .latticesShowSettingsSection)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw), section.isAvailable {
                selectedTab = section
            }
        }
    }

    // MARK: - Back Bar

    private var snapModifierBinding: Binding<SnapModifierKey> {
        Binding(
            get: { workspaceManager.snapZonesConfig.modifier ?? .command },
            set: { workspaceManager.updateSnapModifier($0) }
        )
    }

    private var backBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onBack {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: HudTextSize.xs, weight: .semibold))
                            .foregroundColor(Palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }

                Text(page == .docs ? "Docs" : "Settings")
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HudDivider(color: Palette.border)
        }
    }

    // MARK: - Settings Body

    private var settingsBody: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 196, alignment: .top)
                .background(Palette.bg)

            HudDivider(color: Palette.border, axis: .vertical)
                .frame(maxHeight: .infinity)

            selectedSectionContent
                .background(Palette.bg)
        }
        .background(Palette.bg)
    }

    private var settingsSidebar: some View {
        // Scrollable so the section list never imposes a tall minimum height. The
        // unified window is user-resizable; without this, the non-scrolling list
        // (~480pt) overflows short windows and pushes the shell's status bar off
        // the bottom — every section pane already scrolls, so the rail must too.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(SettingsSection.groupedCases, id: \.0) { group, sections in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group)
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)

                        ForEach(sections) { section in
                            settingsTab(section)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bg.opacity(0.55))
    }

    private func settingsTab(_ section: SettingsSection) -> some View {
        SettingsSidebarRow(
            icon: section.icon,
            title: section.title,
            isActive: selectedTab == section
        ) {
            selectedTab = section
        }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedTab {
        case .general:
            generalContent
        case .permissions:
            permissionsContent
        case .shortcuts:
            shortcutsContent
        case .keyboard:
            keyboardContent
        case .mouse:
            mouseGesturesContent
        case .eventViewer:
            eventViewerContent
        case .hyperspace:
            hyperspaceContent
        case .voice:
            voiceContent
        case .ai:
            aiContent
        case .search:
            searchOcrContent
        case .companion, .deck:
            BundleModules.settingsPane(section: selectedTab.rawValue) ?? AnyView(EmptyView())
        }
    }

    // MARK: - Sticky section header

    private func stickyHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(Typo.pixel(14))
                    .foregroundColor(Palette.textDim)
                    .tracking(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Palette.bg)

            Rectangle()
                .fill(Palette.border)
                .frame(height: 0.5)
        }
    }

    // MARK: - General

    private var appUpdateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("App")
                            .font(Typo.heading(13))
                            .foregroundColor(Palette.text)
                        Text(LatticesRuntime.buildChannelLabel)
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                    }

                    HStack(spacing: 8) {
                        Text(appUpdater.currentDisplayVersion)
                            .font(Typo.body(12))
                            .foregroundColor(Palette.textDim)
                        if let update = appUpdater.availableUpdate {
                            Text("v\(update.version) ready")
                                .font(Typo.caption(11))
                                .foregroundColor(Palette.detach)
                        } else if appUpdater.isChecking {
                            Text("Checking…")
                                .font(Typo.caption(11))
                                .foregroundColor(Palette.textMuted)
                        } else if let error = appUpdater.lastError {
                            Text(error)
                                .font(Typo.caption(11))
                                .foregroundColor(Palette.detach)
                                .lineLimit(1)
                        } else if let checked = appUpdater.lastChecked {
                            Text("Checked \(checked, style: .relative)")
                                .font(Typo.caption(11))
                                .foregroundColor(Palette.textMuted)
                        }
                    }
                }

                Spacer(minLength: 12)

                Toggle("Auto", isOn: $appUpdater.autoCheckEnabled)
                    .font(Typo.caption(11))
                    .toggleStyle(.checkbox)
                    .foregroundColor(Palette.textDim)

                Button {
                    if appUpdater.availableUpdate == nil {
                        Task { await appUpdater.check() }
                    } else {
                        appUpdater.promptForUpdate()
                    }
                } label: {
                    Text(appUpdater.isUpdating
                         ? "Preparing…"
                         : (appUpdater.availableUpdate == nil
                            ? (appUpdater.isChecking ? "Checking…" : "Check")
                            : "Update"))
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                }
                .buttonStyle(.plain)
                .disabled(appUpdater.isUpdating || appUpdater.isChecking)
            }
        }
    }

    private var interactionBehaviorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Detach")
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)
                Spacer(minLength: 12)
                SettingsChoiceBar(
                    selection: $prefs.mode,
                    options: [
                        (.learning, "Learning"),
                        (.auto, "Auto"),
                    ]
                )
            }

            Text(prefs.mode == .learning
                 ? "Shows keybinding hints when you detach from a tmux session."
                 : "Detaches quietly after Lattices hands off the workspace.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
        }
    }

    private var terminalSettingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Terminal")
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)
                Spacer(minLength: 12)
                SettingsChoiceBar(
                    selection: $prefs.terminal,
                    options: Terminal.installed.map { ($0, $0.rawValue) }
                )
            }

            Text("Used when Lattices attaches to tmux sessions.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
        }
    }

    private var projectDiscoveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("Projects")
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)

                TextField("~/dev", text: $prefs.scanRoot)
                    .textFieldStyle(.plain)
                    .font(Typo.body(12))
                    .foregroundColor(Palette.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .outlinedBox(HudSurface.control)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if !prefs.scanRoot.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: prefs.scanRoot)
                    }
                    if panel.runModal() == .OK, let url = panel.url {
                        prefs.scanRoot = url.path
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Choose scan root")

                Button {
                    scanner.updateRoot(prefs.scanRoot)
                    scanner.scan()
                } label: {
                    Text("Rescan")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                }
                .buttonStyle(.plain)
            }

            Text("Scans this folder for .lattices.json configs.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
        }
    }

    private var inputControlsCard: some View {
        shortcutSectionCard(
            title: "Input Controls",
            eyebrow: "Gestures",
            summary: "Mouse gestures and drag snapping live alongside the shortcuts they trigger."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                settingsPrefRow(
                    "Drag-to-snap",
                    caption: "Hold a modifier while dragging a window to reveal snap targets."
                ) {
                    SettingsSwitch(isOn: $prefs.dragSnapEnabled)
                }

                settingsPrefRow("Snap modifier") {
                    SettingsChoiceBar(
                        selection: snapModifierBinding,
                        options: SnapModifierKey.allCases.map { ($0, $0.shortLabel) }
                    )
                }

                settingsPrefRow(
                    "Ctrl+Option hold",
                    caption: LatticesTier.isBundle
                        ? "What holding Control+Option shows. Tile HUD is the gray picker; Spatial Lens places the window under the pointer."
                        : "What holding Control+Option shows. Tile HUD is the gray picker."
                ) {
                    SettingsChoiceBar(
                        selection: $prefs.ctrlOptionHoldMode,
                        options: CtrlOptionHoldMode.available.map { ($0, $0.label) }
                    )
                }
                settingsPrefRow(
                    "Tile HUD style",
                    caption: "Loop is the radial ring. Matrix is the Lattices 3×3. While held, numpad 1–9 or arrow keys tile directly."
                ) {
                    SettingsChoiceBar(
                        selection: $prefs.tilePointerHUDStyle,
                        options: TilePointerHUDStyle.allCases.map { ($0, $0.label) }
                    )
                }
                settingsPrefRow(
                    "Move & land feedback",
                    caption: "Experiment: a tick as your aim crosses cells, a tactile tap when the window lands."
                ) {
                    SettingsSwitch(isOn: $prefs.tilePointerSoundEffectsEnabled)
                }

                settingsPrefRow(
                    "Middle-click gestures",
                    caption: "Switch Spaces, open the Screen Map, or trigger dictation."
                ) {
                    SettingsSwitch(isOn: $prefs.mouseGesturesEnabled)
                }

                settingsPrefRow("Visual confirmation") {
                    SettingsSwitch(isOn: $prefs.mouseGestureHUDVisualEnabled)
                }

                settingsPrefRow("Audio confirmation") {
                    SettingsSwitch(isOn: $prefs.mouseGestureHUDAudioEnabled)
                }

                settingsPrefRow("HUD style") {
                    SettingsChoiceBar(
                        selection: $prefs.mouseGestureHUDStyle,
                        options: MouseGestureHUDStyle.allCases.map { ($0, $0.label) }
                    )
                }

                breakerStatusRow(
                    state: mouseGestureController.breakerState,
                    label: "Mouse gestures"
                ) {
                    mouseGestureController.reArmAfterBreakerTrip()
                }
            }
        }
    }

    private var keyboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Caps Lock as Hyper")
                                    .font(Typo.heading(13))
                                    .foregroundColor(Palette.text)
                                Text("Hold Caps Lock for Hyper. Tap Caps Lock for Escape.")
                                    .font(Typo.caption(11))
                                    .foregroundColor(Palette.textMuted)
                            }

                            Spacer()

                            SettingsSwitch(isOn: $prefs.keyboardRemapsEnabled)
                        }

                        HStack(spacing: 10) {
                            statusToken(
                                prefs.keyboardRemapsEnabled ? "Enabled" : "Off",
                                color: prefs.keyboardRemapsEnabled ? Palette.running : Palette.textDim
                            )
                            statusToken(
                                keyboardRemapController.capsLockTransportActive ? "Transport active" : "Transport idle",
                                color: keyboardRemapController.capsLockTransportActive ? Palette.running : Palette.textDim
                            )
                            if !permChecker.accessibility {
                                statusToken("Accessibility needed", color: Palette.detach)
                            }
                            Spacer(minLength: 0)
                        }

                        cardDivider

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active remap")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)

                            if keyboardRemapStore.summaryLines.isEmpty {
                                Text("No active keyboard remaps")
                                    .font(Typo.caption(9.5))
                                    .foregroundColor(Palette.textMuted.opacity(0.7))
                            } else {
                                ForEach(keyboardRemapStore.summaryLines.prefix(3), id: \.self) { line in
                                    Text(line)
                                        .font(Typo.caption(9.5))
                                        .foregroundColor(Palette.textMuted.opacity(0.82))
                                }
                            }
                        }

                        breakerStatusRow(
                            state: keyboardRemapController.breakerState,
                            label: "Keyboard remaps"
                        ) {
                            keyboardRemapController.reArmAfterBreakerTrip()
                        }

                        if let keyboardRecoveryStatus {
                            Text(keyboardRecoveryStatus)
                                .font(Typo.caption(9.5))
                                .foregroundColor(Palette.textMuted.opacity(0.8))
                        }

                        HStack(spacing: 8) {
                            Button {
                                let didClear = keyboardRemapController.clearStuckCapsLockState()
                                keyboardRecoveryStatus = didClear
                                    ? "Caps Lock state cleared."
                                    : "Could not clear Caps Lock state; check Accessibility/Input Monitoring."
                            } label: {
                                settingsActionLabel("Clear Stuck State", icon: "escape", emphasized: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                keyboardRemapStore.restoreDefaults()
                                keyboardRecoveryStatus = "Keyboard remaps restored to defaults."
                            } label: {
                                settingsActionLabel("Restore Defaults", icon: "arrow.counterclockwise")
                            }
                            .buttonStyle(.plain)

                            Button {
                                keyboardRemapStore.openConfiguration()
                            } label: {
                                settingsActionLabel("Open Config", icon: "doc.text")
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }

                        if !permChecker.accessibility {
                            cardDivider

                            permissionSettingsRow(
                                "Accessibility",
                                granted: permChecker.accessibility,
                                detail: "Required for Caps Lock as Hyper and tap-for-Escape handling."
                            ) {
                                permChecker.requestAccessibility()
                            }
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Instant Space Switching")
                                    .font(Typo.heading(13))
                                    .foregroundColor(Palette.text)
                                Text("Ctrl+←/→ jumps straight to the next Space — no slide animation — with a small Lattices confirmation. Hold Shift for a landscape of every Space on that display.")
                                    .font(Typo.caption(11))
                                    .foregroundColor(Palette.textMuted)
                            }

                            Spacer()

                            SettingsSwitch(isOn: $prefs.spaceSwitchKeysEnabled)
                        }

                        HStack(spacing: 10) {
                            statusToken(
                                prefs.spaceSwitchKeysEnabled ? "Enabled" : "Off",
                                color: prefs.spaceSwitchKeysEnabled ? Palette.running : Palette.textDim
                            )
                            if !permChecker.accessibility {
                                statusToken("Accessibility needed", color: Palette.detach)
                            }
                            Spacer(minLength: 0)
                        }

                        breakerStatusRow(
                            state: spaceSwitchInterceptor.breakerState,
                            label: "Space switching"
                        ) {
                            spaceSwitchInterceptor.reArmAfterBreakerTrip()
                        }

                        cardDivider

                        settingsPrefRow(
                            "Slide echo",
                            caption: "A quick swoosh at the pointer as you switch. Turn off for just the desktop filmstrip. Reduce Motion suppresses the swoosh."
                        ) {
                            SettingsSwitch(isOn: $prefs.spaceSwitchGlideEnabled)
                        }

                        if !permChecker.accessibility {
                            cardDivider

                            permissionSettingsRow(
                                "Accessibility",
                                granted: permChecker.accessibility,
                                detail: "Required to intercept Ctrl+←/→ before Mission Control."
                            ) {
                                permChecker.requestAccessibility()
                            }
                        }
                    }
                }

                if LatticesTier.isBundle {
                    settingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Spatial Lens")
                                        .font(Typo.heading(13))
                                        .foregroundColor(Palette.text)
                                    Text("Preview and place the window under your pointer without opening a separate mode.")
                                        .font(Typo.caption(11))
                                        .foregroundColor(Palette.textMuted)
                                }

                                Spacer()
                                SettingsSwitch(isOn: Binding(
                                    get: { prefs.ctrlOptionHoldMode == .spatialLens },
                                    set: { prefs.ctrlOptionHoldMode = $0 ? .spatialLens : .tileHUD }
                                ))
                            }

                            HStack(spacing: 10) {
                                statusToken(
                                    prefs.spatialLensEnabled ? "Enabled" : "Off",
                                    color: prefs.spatialLensEnabled ? Palette.running : Palette.textDim
                                )
                                statusToken("Control + Option", color: Palette.launch)
                                if !permChecker.accessibility {
                                    statusToken("Accessibility needed", color: Palette.detach)
                                }
                                Spacer(minLength: 0)
                            }

                            cardDivider

                            VStack(alignment: .leading, spacing: 7) {
                                Text("Hold physical Control + Option over a window to reveal eight targets around the pointer.")
                                Text("Choose a side or corner, then release either modifier to place. Release in the center to cancel.")
                                Text("Sides cycle ½ → ⅓ → ⅔ on this display. Move well beyond a side target for a deliberate adjacent-display flick.")
                                Text("Takes over the Ctrl+Option hold from the Tile HUD.")
                            }
                            .font(Typo.caption(9.5))
                            .foregroundColor(Palette.textMuted.opacity(0.82))
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var mouseGestureHUDSettingsControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsPrefRow("Visual confirmation") {
                SettingsSwitch(isOn: $prefs.mouseGestureHUDVisualEnabled)
            }
            settingsPrefRow("Audio confirmation") {
                SettingsSwitch(isOn: $prefs.mouseGestureHUDAudioEnabled)
            }
            settingsPrefRow("HUD style") {
                SettingsChoiceBar(
                    selection: $prefs.mouseGestureHUDStyle,
                    options: MouseGestureHUDStyle.allCases.map { ($0, $0.label) }
                )
            }
        }
    }

    private var cursorMarkerSettingsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent cursor marker")
                    .font(Typo.monoBold(10.5))
                    .foregroundColor(Palette.text)
                Text("Default resting marker for computer-use cursor actions. Individual actions can still override these values.")
                    .font(Typo.caption(9.5))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsPrefRow("Shape") {
                SettingsChoiceBar(
                    selection: $prefs.cursorMarkerShape,
                    options: CursorMarkerShape.settingsOptions.map { ($0, $0.label) }
                )
            }

            settingsPrefRow("Rotation") {
                SettingsChoiceBar(
                    selection: $prefs.cursorMarkerAngleDeg,
                    options: [(-8, "−8°"), (-16, "−16°")]
                )
            }

            settingsPrefRow("Size") {
                SettingsChoiceBar(
                    selection: $prefs.cursorMarkerSize,
                    options: CursorMarkerSize.settingsOptions.map { ($0, $0.label) }
                )
            }
        }
    }

    private var mouseGesturesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Middle-click gestures")
                                .font(Typo.monoBold(11))
                                .foregroundColor(Palette.text)
                            Spacer()
                            SettingsSwitch(isOn: $prefs.mouseGesturesEnabled)
                        }

                        cardDivider

                        cursorMarkerSettingsControls

                        cardDivider

                        mouseGestureHUDSettingsControls

                        cardDivider

                        mouseShortcutMappingMatrix(title: "Active mappings", limit: 8)

                        Text("Hold Shift before a desktop gesture to move the window under the pointer to the next or previous desktop. You follow the window to its new desktop.")
                            .font(Typo.caption(11))
                            .foregroundColor(Palette.textDim)

                        breakerStatusRow(
                            state: mouseGestureController.breakerState,
                            label: "Mouse gestures"
                        ) {
                            mouseGestureController.reArmAfterBreakerTrip()
                        }

                        mouseMappingsFooter
                    }
                }
            }
            .padding(16)
        }
    }

    private func mouseShortcutMappingMatrix(title: String, limit: Int) -> some View {
        let allRules = mouseShortcutStore.enabledRules
        let rules = Array(allRules.prefix(limit))
        let hiddenCount = max(allRules.count - rules.count, 0)
        let grouped = Dictionary(grouping: rules, by: \.trigger.button)
        let sortedButtons = grouped.keys.sorted { mouseShortcutButtonSortOrder($0) < mouseShortcutButtonSortOrder($1) }

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.text)

            if rules.isEmpty {
                mouseShortcutEmptyMappingRow
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sortedButtons, id: \.self) { button in
                        if let buttonRules = grouped[button] {
                            mouseShortcutMappingButtonGroup(button: button, rules: buttonRules)
                        }
                    }
                }

                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more in config")
                        .font(Typo.mono(8))
                        .foregroundColor(Palette.textMuted.opacity(0.72))
                }
            }
        }
    }

    private func mouseShortcutMappingButtonGroup(button: MouseShortcutButton, rules: [MouseShortcutRule]) -> some View {
        let sortedRules = rules.sorted { lhs, rhs in
            mouseShortcutTriggerSortOrder(lhs.trigger) < mouseShortcutTriggerSortOrder(rhs.trigger)
        }

        return VStack(alignment: .leading, spacing: 5) {
            Text(button.displayLabel)
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.textMuted.opacity(0.82))

            VStack(spacing: 0) {
                ForEach(Array(sortedRules.enumerated()), id: \.element.id) { index, rule in
                    mouseShortcutMappingTableRow(rule)

                    if index < sortedRules.count - 1 {
                        Rectangle()
                            .fill(Palette.border.opacity(0.45))
                            .frame(height: 0.5)
                            .padding(.leading, 10)
                    }
                }
            }
            .outlinedBox(Palette.surface.opacity(0.48))
        }
    }

    private var mouseShortcutEmptyMappingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "slash.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.textMuted.opacity(0.75))
            Text("No active mappings")
                .font(Typo.caption(9))
                .foregroundColor(Palette.textMuted.opacity(0.68))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .outlinedBox(Palette.surface.opacity(0.48))
    }

    private func mouseShortcutMappingTableRow(_ rule: MouseShortcutRule) -> some View {
        HStack(spacing: 8) {
            Text(mouseShortcutGestureLabel(for: rule.trigger))
                .font(Typo.mono(9))
                .foregroundColor(Palette.text)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)

            Image(systemName: mouseShortcutTriggerIcon(for: rule.trigger))
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Palette.textMuted.opacity(0.62))
                .frame(width: 12)

            Text(mouseShortcutActionSummary(for: rule))
                .font(Typo.caption(9))
                .foregroundColor(Palette.textMuted.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 0)

            if rule.effectiveActions.count > 1 {
                Text("\(rule.effectiveActions.count)x")
                    .font(Typo.monoBold(8))
                    .foregroundColor(Palette.textMuted.opacity(0.72))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.surfaceHov.opacity(0.55)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var eventViewerContent: some View {
        MouseInputEventViewerView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { MouseInputEventViewer.shared.setEmbeddedCaptureActive(true) }
            .onDisappear { MouseInputEventViewer.shared.setEmbeddedCaptureActive(false) }
    }

    private var mouseMappingsFooter: some View {
        HStack(spacing: 14) {
            Button("Event Viewer") {
                selectedTab = .eventViewer
            }
            .buttonStyle(.plain)
            .font(Typo.caption(11))
            .foregroundColor(Palette.textDim)

            if mouseShortcutStore.hasHistory {
                Button("Undo last change") {
                    mouseShortcutStore.restoreLatestHistory()
                }
                .buttonStyle(.plain)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textDim)
            }

            Button("Reset mappings") {
                mouseShortcutStore.restoreDefaults()
            }
            .buttonStyle(.plain)
            .font(Typo.caption(11))
            .foregroundColor(Palette.textMuted)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func mouseShortcutManagementPanel(detail: String, showHistorySummary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                mouseShortcutControlButton(icon: "slider.horizontal.3", label: "Configure") {
                    mouseShortcutStore.openConfiguration()
                }

                mouseShortcutControlButton(icon: "scope", label: "Event Viewer") {
                    MouseInputEventViewer.shared.show()
                }

                mouseShortcutControlButton(icon: "clock.arrow.circlepath", label: "History") {
                    mouseShortcutStore.openHistory()
                }

                mouseShortcutControlButton(
                    icon: "arrow.uturn.backward",
                    label: "Undo Last",
                    isEnabled: mouseShortcutStore.hasHistory
                ) {
                    mouseShortcutStore.restoreLatestHistory()
                }

                mouseShortcutControlButton(icon: "arrow.counterclockwise", label: "Defaults") {
                    mouseShortcutStore.restoreDefaults()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Palette.textMuted.opacity(0.66))
                Text(detail)
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showHistorySummary, !mouseShortcutStore.historySummaryLines.isEmpty {
                HStack(spacing: 6) {
                    Text("Recent")
                        .font(Typo.monoBold(8))
                        .foregroundColor(Palette.textMuted.opacity(0.68))

                    ForEach(Array(mouseShortcutStore.historySummaryLines.prefix(3)), id: \.self) { snapshot in
                        Text(snapshot)
                            .font(Typo.mono(8))
                            .foregroundColor(Palette.textMuted.opacity(0.7))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.surface.opacity(0.55)))
                    }
                }
            }
        }
    }

    private func mouseShortcutControlButton(
        icon: String,
        label: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(Typo.monoBold(9))
                    .lineLimit(1)
            }
            .foregroundColor(isEnabled ? Palette.text : Palette.textMuted.opacity(0.52))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonBox()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func mouseShortcutActionSummary(for rule: MouseShortcutRule) -> String {
        rule.effectiveActions.map(\.label).joined(separator: " + ")
    }

    private func mouseShortcutGestureLabel(for trigger: MouseShortcutTrigger) -> String {
        switch trigger.kind {
        case .click:
            return "click"
        case .drag:
            if let direction = trigger.direction {
                return "drag \(direction.displayLabel.lowercased())"
            }
            return "drag"
        case .shape:
            if let shape = trigger.shape {
                return shape.displayName.lowercased()
            }
            return "shape"
        }
    }

    private func mouseShortcutButtonSortOrder(_ button: MouseShortcutButton) -> Int {
        switch button {
        case .middle: return 0
        case .button4: return 1
        case .button5: return 2
        case .right: return 3
        case .number: return 4
        }
    }

    private func mouseShortcutTriggerSortOrder(_ trigger: MouseShortcutTrigger) -> Int {
        let kindOrder: Int
        switch trigger.kind {
        case .drag: kindOrder = 0
        case .shape: kindOrder = 1
        case .click: kindOrder = 2
        }

        let directionOrder: Int
        switch trigger.direction {
        case .left: directionOrder = 0
        case .right: directionOrder = 1
        case .up: directionOrder = 2
        case .down: directionOrder = 3
        case nil: directionOrder = 4
        }

        return kindOrder * 10 + directionOrder
    }

    private func mouseShortcutTriggerIcon(for trigger: MouseShortcutTrigger) -> String {
        switch trigger.kind {
        case .click:
            return "cursorarrow.click"
        case .shape:
            return "scribble.variable"
        case .drag:
            switch trigger.direction {
            case .left: return "arrow.left"
            case .right: return "arrow.right"
            case .up: return "arrow.up"
            case .down: return "arrow.down"
            case nil: return "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
    }

    private var generalContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appUpdateCard
                generalRule
                terminalSettingsCard
                generalRule
                interactionBehaviorCard
                generalRule
                projectDiscoveryCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalRule: some View {
        HudDivider(color: Palette.border)
            .padding(.vertical, 16)
    }

    private var permissionsContent: some View {
        let missing = Capability.available.filter { !$0.isGranted }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsPrefRow(
                    "Status",
                    caption: "Needed for tiling, OCR, gestures, remaps, and voice."
                ) {
                    HStack(spacing: 12) {
                        Text(missing.isEmpty ? "All on" : "\(missing.count) off")
                            .font(Typo.caption(11))
                            .foregroundColor(missing.isEmpty ? Palette.textDim : Palette.detach)

                        Button(missing.isEmpty ? "Assistant" : "Set Up") {
                            PermissionsAssistantWindowController.shared.show(focus: missing.first)
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)

                        Button("Recheck") {
                            permChecker.check()
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                    }
                }

                generalRule

                permissionSettingsRow(
                    "Accessibility",
                    granted: permChecker.accessibility,
                    detail: "Mouse gestures, remaps, window movement, and focus."
                ) {
                    permChecker.requestAccessibility()
                }
                generalRule
                permissionSettingsRow(
                    "Screen Recording",
                    granted: permChecker.screenRecording,
                    detail: "Window titles, OCR, and Space-aware discovery."
                ) {
                    permChecker.requestScreenRecording()
                }
                generalRule
                permissionSettingsRow(
                    "Microphone",
                    granted: permChecker.microphoneGranted,
                    detail: "Local dictation and voice commands."
                ) {
                    permChecker.requestMicrophone()
                }
                generalRule
                permissionReviewRow(
                    "Automation",
                    detail: "System Events shortcuts, including gesture-triggered dictation."
                ) {
                    permChecker.openAutomationSettings()
                }
                generalRule
                permissionReviewRow(
                    "Input Monitoring",
                    detail: "Review if global input capture or synthetic shortcuts fail."
                ) {
                    permChecker.openInputMonitoringSettings()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { permChecker.check() }
    }

    private var appContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: LatticesRuntime.isDevBuild ? "hammer.fill" : "checkmark.seal.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(LatticesRuntime.isDevBuild ? Palette.detach : Palette.running)
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("Lattices app")
                                        .font(Typo.mono(12))
                                        .foregroundColor(Palette.text)
                                    buildChannelBadge
                                    Spacer()
                                }

                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(appUpdater.currentDisplayVersion)
                                        .font(Typo.heading(20))
                                        .foregroundColor(Palette.text)
                                    Text(LatticesRuntime.buildStatusLabel)
                                        .font(Typo.monoBold(10))
                                        .foregroundColor(LatticesRuntime.isDevBuild ? Palette.detach : Palette.running)
                                }

                                if let revision = LatticesRuntime.buildRevision {
                                    Text("Build \(revision)")
                                        .font(Typo.caption(9))
                                        .foregroundColor(Palette.textMuted.opacity(0.8))
                                }
                            }
                        }

                        Text("Lattices can check for new signed releases and prepare the update here. You’ll confirm before the app quits and relaunches.")
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)

                        if let update = appUpdater.availableUpdate {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Palette.detach)
                                    Text("New version v\(update.version) is ready")
                                        .font(Typo.monoBold(10))
                                        .foregroundColor(Palette.detach)
                                }

                                if !update.releaseNotes.isEmpty {
                                    Text(String(update.releaseNotes.prefix(180)) + (update.releaseNotes.count > 180 ? "..." : ""))
                                        .font(Typo.caption(9))
                                        .foregroundColor(Palette.textMuted)
                                        .lineLimit(3)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Palette.surfaceHov.opacity(0.65))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.detach.opacity(0.35), lineWidth: 0.5))
                            )
                        } else if appUpdater.isChecking {
                            Text("Checking for updates...")
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted)
                        } else if let error = appUpdater.lastError {
                            Text(error)
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.detach.opacity(0.9))
                        } else if let checked = appUpdater.lastChecked {
                            Text("Last checked \(checked, style: .relative)")
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted.opacity(0.8))
                        }

                        if let status = appUpdater.statusMessage {
                            Text(status)
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.running.opacity(0.85))
                        }

                        if let reason = appUpdater.unavailableReason {
                            Text(reason)
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.detach.opacity(0.9))
                        }

                        HStack(spacing: 10) {
                            Button {
                                appUpdater.promptForUpdate()
                            } label: {
                                Text(appUpdater.isUpdating ? "Preparing..." : (appUpdater.availableUpdate == nil ? "Check for Updates" : "Update to v\(appUpdater.availableUpdate?.version ?? "")"))
                                    .font(Typo.monoBold(10))
                                    .foregroundColor(Palette.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .buttonBox()
                            }
                            .buttonStyle(.plain)
                            .disabled(appUpdater.isUpdating)

                            Button {
                                Task { await appUpdater.check() }
                            } label: {
                                Text(appUpdater.isChecking ? "Checking..." : "Check Now")
                                    .font(Typo.caption(9))
                                    .foregroundColor(Palette.textMuted.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                            .disabled(appUpdater.isChecking)

                            Toggle("Auto", isOn: $appUpdater.autoCheckEnabled)
                                .font(Typo.caption(9))
                                .toggleStyle(.checkbox)
                                .foregroundColor(Palette.textMuted.opacity(0.9))

                            if appUpdater.availableUpdate != nil {
                                Button {
                                    appUpdater.viewCurrentRelease()
                                } label: {
                                    Text("Release Notes")
                                        .font(Typo.caption(9))
                                        .foregroundColor(Palette.textMuted.opacity(0.9))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    appUpdater.skipCurrentUpdate()
                                } label: {
                                    Text("Skip")
                                        .font(Typo.caption(9))
                                        .foregroundColor(Palette.textMuted.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            Text("CLI: `lattices app update`")
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted.opacity(0.8))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var behaviorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sessions")
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.text)

                        HStack {
                            Text("Detach mode")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                            SettingsChoiceBar(
                                selection: $prefs.mode,
                                options: [
                                    (.learning, "Learning"),
                                    (.auto, "Auto"),
                                ]
                            )
                        }

                        Text(prefs.mode == .learning
                            ? "Shows keybinding hints on detach"
                            : "Detaches sessions silently")
                            .font(Typo.caption(9))
                            .foregroundColor(Palette.textMuted.opacity(0.7))
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Window drag snap")
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.text)

                        HStack {
                            Text("Drag-to-snap")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                            SettingsSwitch(isOn: $prefs.dragSnapEnabled)
                        }

                        HStack {
                            Text("Snap modifier")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                            SettingsChoiceBar(
                                selection: snapModifierBinding,
                                options: SnapModifierKey.allCases.map { ($0, $0.shortLabel) }
                            )
                        }

                        Text("Dragging stays normal until you hold \(snapModifierBinding.wrappedValue.label). While that key is down, Lattices reveals snap targets and a live preview for the window you’re moving.")
                            .font(Typo.caption(9))
                            .foregroundColor(Palette.textMuted.opacity(0.7))

                        cardDivider

                        Text("Advanced landing-zone rules still live in ~/.lattices/snap-zones.json. Modifier changes here take effect on the next drag.")
                            .font(Typo.caption(9))
                            .foregroundColor(Palette.textMuted.opacity(0.7))
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mouse gestures")
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.text)

                        HStack {
                            Text("Middle-click gestures")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                            SettingsSwitch(isOn: $prefs.mouseGesturesEnabled)
                        }

                        Text("Rules live in ~/.lattices/mouse-shortcuts.json. Defaults include middle-click drag left/right for Spaces, down for Screen Map, and up for the Voice Command hotkey.")
                            .font(Typo.caption(9))
                            .foregroundColor(Palette.textMuted.opacity(0.7))

                        cardDivider

                        mouseGestureHUDSettingsControls

                        cardDivider

                        mouseShortcutMappingMatrix(title: "Active drag mappings", limit: 4)

                        breakerStatusRow(
                            state: mouseGestureController.breakerState,
                            label: "Mouse gestures"
                        ) {
                            mouseGestureController.reArmAfterBreakerTrip()
                        }

                        mouseMappingsFooter
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keyboard remaps")
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.text)

                        HStack {
                            Text("Caps Lock as Hyper")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                            SettingsSwitch(isOn: $prefs.keyboardRemapsEnabled)
                        }

                        Text("Rules live in ~/.lattices/keyboard-remaps.json. The default maps hold Caps Lock to Hyper and tap Caps Lock to Escape. While enabled, Lattices temporarily maps physical Caps Lock through a private F18 transport so the lock state does not latch.")
                            .font(Typo.caption(9))
                            .foregroundColor(Palette.textMuted.opacity(0.7))

                        cardDivider

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active remaps")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)

                            ForEach(keyboardRemapStore.summaryLines.prefix(4), id: \.self) { line in
                                Text(line)
                                    .font(Typo.caption(9))
                                    .foregroundColor(Palette.textMuted.opacity(0.78))
                            }

                            if keyboardRemapStore.summaryLines.isEmpty {
                                Text("No active remaps")
                                    .font(Typo.caption(9))
                                    .foregroundColor(Palette.textMuted.opacity(0.6))
                            }
                        }

                        breakerStatusRow(
                            state: keyboardRemapController.breakerState,
                            label: "Keyboard remaps"
                        ) {
                            keyboardRemapController.reArmAfterBreakerTrip()
                        }

                        HStack(spacing: 8) {
                            Button {
                                keyboardRemapStore.openConfiguration()
                            } label: {
                                Text("Configure...")
                                    .font(Typo.monoBold(10))
                                    .foregroundColor(Palette.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .buttonBox()
                            }
                            .buttonStyle(.plain)

                            Button {
                                keyboardRemapStore.restoreDefaults()
                            } label: {
                                Text("Restore Defaults")
                                    .font(Typo.monoBold(10))
                                    .foregroundColor(Palette.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .buttonBox()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hyperspace

    private var hyperspaceContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                // ── Displays ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ocrSectionLabel("Displays")

                        Text("Hyperspace opens a separate survey on each display with windows. Nothing moves until you select and gather on that display.")
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8, alignment: .top)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                                HyperspaceDisplayTile(index: index, screen: screen)
                            }
                        }
                    }
                }

                // ── Lighting ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ocrSectionLabel("Lighting")
                        Text("The survey is lit like a room. These mirror the dials inside Hyperspace and apply the next time it opens.")
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        hsSlider("moon.stars", "Ambient", $hsAmbient) { hsPercent($0) }
                        hsKeyLightRow
                        hsSlider("flashlight.on.fill", "Spotlight", $hsSpotlight) { hsPercent($0) }
                        hsSlider("thermometer.medium", "Temperature", $hsTemp) {
                            $0 < 0.45 ? "Cool" : $0 > 0.55 ? "Warm" : "Neutral"
                        }
                    }
                }

                // ── Size & layout ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ocrSectionLabel("Size & Layout")

                        // Auto-fit: the panel sizes tiles from the window count, sat a
                        // little inside the fill so the lattice has room to breathe.
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Palette.textMuted)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Auto-fit to window count")
                                    .font(Typo.mono(11))
                                    .foregroundColor(Palette.text)
                                Text("Sizes tiles to fill the display, with room to breathe")
                                    .font(Typo.caption(9.5))
                                    .foregroundColor(Palette.textMuted)
                            }
                            Spacer()
                            SettingsSwitch(isOn: $hsSizeAuto)
                        }

                        // Manual zoom — active when auto is off. Lower = more room.
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Palette.textMuted)
                                .frame(width: 18)
                            Text("Zoom")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                                .frame(width: 96, alignment: .leading)
                            Slider(value: $hsTileScale, in: 0.55...1.7)
                                .controlSize(.small)
                                .tint(Palette.running)
                            Text(hsSizeAuto ? "auto" : String(format: "%.2f×", hsTileScale))
                                .font(Typo.monoBold(10))
                                .foregroundColor(Palette.text)
                                .frame(width: 50, alignment: .trailing)
                        }
                        .opacity(hsSizeAuto ? 0.4 : 1)
                        .disabled(hsSizeAuto)

                        cardDivider

                        // Lattice growth: scan wide vs. grow into the vertical.
                        hsSegmentRow("rectangle.grid.2x2", "Lattice") {
                            SettingsChoiceBar(
                                selection: $hsLayoutTall,
                                options: [(false, "Scan"), (true, "Tall")]
                            )
                        }

                        // Hint keys: full keyboard vs. hand-split assignment.
                        hsSegmentRow("keyboard", "Hint keys") {
                            SettingsChoiceBar(
                                selection: $hsHandKeys,
                                options: [(false, "Standard"), (true, "Hand split")]
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // A labeled lighting slider (0…1) with a right-aligned readout.
    private func hsSlider(_ icon: String, _ title: String, _ value: Binding<Double>,
                          readout: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.textMuted)
                .frame(width: 18)
            Text(title)
                .font(Typo.mono(11))
                .foregroundColor(Palette.textDim)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
                .tint(Palette.running)
            Text(readout(value.wrappedValue))
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.text)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // Key light: intensity slider plus a three-way origin picker (◤ ▲ ◥).
    private var hsKeyLightRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.textMuted)
                .frame(width: 18)
            Text("Key light")
                .font(Typo.mono(11))
                .foregroundColor(Palette.textDim)
                .frame(width: 96, alignment: .leading)
            Slider(value: $hsKeyLight, in: 0...1)
                .controlSize(.small)
                .tint(Palette.running)
            SettingsChoiceBar(
                selection: $hsKeyAngle,
                options: [(0, "◤"), (1, "▲"), (2, "◥")]
            )
        }
    }

    // A labeled row hosting a trailing control (segmented picker, etc.).
    private func hsSegmentRow<Trailing: View>(_ icon: String, _ title: String,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.textMuted)
                .frame(width: 18)
            Text(title)
                .font(Typo.mono(11))
                .foregroundColor(Palette.textDim)
                .frame(width: 96, alignment: .leading)
            trailing()
            Spacer(minLength: 0)
        }
    }

    private func hsPercent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - Voice

    private var voiceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                voiceMicrophoneAccessCard
                generalRule
                voiceRuntimeBlock
                generalRule
                voiceModelCard
                generalRule
                voiceShortcutsCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            assistantSession.prepareForDisplay()
        }
    }

    private var voiceRuntimeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            settingsPrefRow("Runtime") {
                #if LATTICES_VOICE && canImport(HudsonVoice)
                Text(LatticesVoiceRuntime.isRunning ? "Running" : "Not running")
                    .font(Typo.caption(11))
                    .foregroundColor(LatticesVoiceRuntime.isRunning ? Palette.textDim : Palette.kill)
                #else
                Text("Not in this build")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                #endif
            }

            #if LATTICES_VOICE && canImport(HudsonVoice)
            Text(LatticesLocalEndpoints.voiceRuntimeWebSocketURL)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
            if !LatticesVoiceRuntime.isRunning {
                Text("Restart Lattices if dictation fails.")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
            }
            #else
            Text("Build with HUDSONKIT_WITH_VOICE=1 to host the voice runtime.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
            #endif
        }
    }

    private var voiceModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsPrefRow("Provider") {
                SettingsChoiceBar(
                    selection: $assistantSession.authProviderID,
                    options: assistantSession.providerOptions.map { ($0.id, $0.name) }
                )
            }

            Text(assistantSession.currentProvider.helpText)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            assistantCredentialControls
            assistantAuthMessage
        }
    }

    private var voiceShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(Typo.heading(13))
                .foregroundColor(Palette.text)
            ShortcutMapRow(action: .voiceCommand, store: hotkeyStore)
            ShortcutMapRow(action: .handsOff, store: hotkeyStore)
            ShortcutMapRow(action: .workspaceAssistant, store: hotkeyStore)
        }
    }

    private var voiceMicrophoneAccessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsPrefRow("Microphone", caption: voiceMicrophoneDetail) {
                voiceMicrophoneTrailing
            }

            HStack(spacing: 14) {
                if voiceMicrophoneNeedsAttention {
                    Button(voiceMicrophonePrimaryLabel) {
                        voiceMicrophonePrimaryAction()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
                }

                Button("Recheck") {
                    permChecker.check()
                }
                .buttonStyle(.plain)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var voiceMicrophoneTrailing: some View {
        Text(voiceMicrophoneStatusLabel.capitalized)
            .font(Typo.caption(11))
            .foregroundColor(voiceMicrophoneNeedsAttention ? Palette.detach : Palette.textDim)
    }

    private var voiceMicrophonePrimaryLabel: String {
        switch permChecker.microphone {
        case .notDetermined: return "Request access"
        case .denied, .restricted: return "Open System Settings"
        default: return "Permissions"
        }
    }

    private func voiceMicrophonePrimaryAction() {
        switch permChecker.microphone {
        case .notDetermined:
            permChecker.requestMicrophone()
        case .denied, .restricted:
            permChecker.openMicrophoneSettings()
        default:
            PermissionsAssistantWindowController.shared.show(focus: .voiceCapture)
        }
    }

    private var voiceMicrophoneStatusLabel: String {
        switch permChecker.microphone {
        case .authorized:
            return "ready"
        case .notDetermined:
            return "not requested"
        case .denied:
            return "blocked"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private var voiceMicrophoneDetail: String {
        switch permChecker.microphone {
        case .authorized:
            return "Lattices can listen when you start dictation or a voice command."
        case .notDetermined:
            return "Ask macOS once before using local dictation or voice commands."
        case .denied:
            return "Open Privacy & Security > Microphone and enable Lattices, then recheck."
        case .restricted:
            return "This Mac or an administrator is blocking microphone access."
        @unknown default:
            return "Lattices could not read the current microphone permission state."
        }
    }

    private var voiceMicrophoneNeedsAttention: Bool {
        switch permChecker.microphone {
        case .authorized:
            return false
        default:
            return true
        }
    }

    // MARK: - AI

    private var aiContent: some View {
        ScrollView {
            assistantProviderCard
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            assistantSession.prepareForDisplay()
        }
    }

    private var assistantProviderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsPrefRow("Assistant", caption: assistantSession.setupStatusSummary) {
                Text(chatTransportStatusLabel.capitalized)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
            }

            Text("Local runtime first (Claude Code, Codex, Pi, OpenCode). Then the saved API key, then Scout.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)

            settingsPrefRow("Harness") {
                SettingsChoiceBar(
                    selection: Binding(
                        get: { assistantSession.preferredAgentHarness ?? "auto" },
                        set: { assistantSession.preferredAgentHarness = $0 == "auto" ? nil : $0 }
                    ),
                    options: ["auto", "claude-code", "codex", "pi", "opencode"].map { ($0, $0) }
                )
            }

            settingsPrefRow("API fallback") {
                Text(assistantSession.currentProvider.name)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
            }

            assistantCredentialControls
            assistantAuthMessage
        }
    }

    @ViewBuilder
    private var assistantCredentialControls: some View {
        assistantApiKeyControls
    }

    private var assistantApiKeyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsPrefRow("API key") {
                HStack(spacing: 12) {
                    Text(assistantSession.hasSelectedCredential ? "Saved" : "Needed")
                        .font(Typo.caption(11))
                        .foregroundColor(assistantSession.hasSelectedCredential ? Palette.textDim : Palette.detach)

                    if assistantSession.hasSelectedCredential && !assistantSession.isEditingStoredCredential {
                        Button("Replace") {
                            assistantSession.beginReplacingSelectedCredential()
                            assistantAuthFieldFocused = true
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)

                        Button("Clear") {
                            assistantSession.removeSelectedCredential()
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                    }
                }
            }

            if !assistantSession.hasSelectedCredential || assistantSession.isEditingStoredCredential {
                HStack(spacing: 10) {
                    SecureField(assistantTokenPlaceholder, text: $assistantSession.authToken)
                        .textFieldStyle(.plain)
                        .font(Typo.body(12))
                        .foregroundColor(Palette.text)
                        .focused($assistantAuthFieldFocused)
                        .onSubmit {
                            assistantSession.saveSelectedToken()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .outlinedBox(HudSurface.control)

                    Button("Save") {
                        assistantSession.saveSelectedToken()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
                    .disabled(assistantSession.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if assistantSession.hasSelectedCredential {
                        Button("Cancel") {
                            assistantSession.cancelReplacingSelectedCredential()
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var assistantAuthMessage: some View {
        if let error = assistantSession.authErrorText {
            Text(error)
                .font(Typo.caption(9.5))
                .foregroundColor(Palette.kill.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        } else if let notice = assistantSession.authNoticeText {
            Text(notice)
                .font(Typo.caption(9.5))
                .foregroundColor(Palette.running.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatTransportStatusLabel: String {
        if let harness = assistantSession.agentRuntimeHarnessLabel {
            return harness
        }
        if assistantSession.hasSelectedCredential { return "API" }
        switch assistantSession.isScoutAvailable {
        case true: return "Scout"
        case false: return "Offline"
        case nil: return "Runtime"
        }
    }

    private var assistantTokenPlaceholder: String {
        let placeholder = assistantSession.currentProvider.tokenPlaceholder
        return placeholder.isEmpty ? "Paste \(assistantSession.currentProvider.tokenLabel.lowercased())" : placeholder
    }

    private var buildChannelBadge: some View {
        Text(LatticesRuntime.buildChannelLabel)
            .font(Typo.monoBold(9))
            .foregroundColor(Palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Palette.surfaceHov.opacity(0.6))
            )
    }

    private func statusToken(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(Typo.monoBold(9.5))
                .foregroundColor(Palette.textDim)
        }
    }

    // MARK: - Search & OCR

    private func ocrNumField(_ value: Binding<Double>, width: CGFloat = 50) -> some View {
        TextField("", value: value, formatter: NumberFormatter())
            .textFieldStyle(.plain)
            .font(Typo.monoBold(11))
            .foregroundColor(Palette.text)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .outlinedBox(Color.white.opacity(0.06))
    }

    private func ocrIntField(_ value: Binding<Int>, width: CGFloat = 36) -> some View {
        TextField("", value: value, formatter: NumberFormatter())
            .textFieldStyle(.plain)
            .font(Typo.monoBold(11))
            .foregroundColor(Palette.text)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .outlinedBox(Color.white.opacity(0.06))
    }

    private func ocrSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typo.monoBold(10))
            .foregroundColor(Palette.textDim)
            .tracking(0.5)
    }

    private var searchOcrContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                // ── Screen Text Recognition Card ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        // Header row: label + toggle
                        HStack {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(prefs.ocrEnabled ? Palette.running.opacity(0.15) : Palette.surface)
                                    .overlay(
                                        Image(systemName: "text.viewfinder")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(prefs.ocrEnabled ? Palette.running : Palette.textMuted)
                                    )
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Screen text recognition")
                                        .font(Typo.mono(12))
                                        .foregroundColor(Palette.text)
                                    Text("Vision OCR on visible windows")
                                        .font(Typo.caption(10))
                                        .foregroundColor(Palette.textMuted)
                                }
                            }
                            Spacer()
                            SettingsSwitch(isOn: Binding(
                                get: { prefs.ocrEnabled },
                                set: { ScreenText.shared.setEnabled($0) }
                            ))
                        }

                        // Accuracy
                        HStack(spacing: 8) {
                            Text("Accuracy")
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.textDim)
                            SettingsChoiceBar(
                                selection: $prefs.ocrAccuracy,
                                options: [("accurate", "Accurate"), ("fast", "Fast")]
                            )
                            Spacer()
                        }
                        .padding(.leading, 32)

                        if !permChecker.screenRecording {
                            cardDivider

                            PermissionAppDragCard(
                                title: "OCR needs the current Lattices app in Screen Recording",
                                permissionName: "Screen Recording",
                                detail: "If an older Lattices entry is already listed, remove it and drag this app into the list from scratch.",
                                onOpenSettings: {
                                    PermissionDragAssistantWindowController.shared.show(focus: .screenSearch, openSettings: true)
                                }
                            )
                        }
                    }
                }

                // ── Scan Schedule Card ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ocrSectionLabel("Schedule")

                        // Quick scan sentence
                        HStack(spacing: 0) {
                            Text("Quick scan top ")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            ocrIntField($prefs.ocrQuickLimit, width: 32)
                            Text(" windows every ")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            ocrNumField($prefs.ocrQuickInterval, width: 42)
                            Text("s")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                        }

                        cardDivider

                        // Deep scan sentence
                        HStack(spacing: 0) {
                            Text("Deep scan up to ")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            ocrIntField($prefs.ocrDeepLimit, width: 32)
                            Text(" windows every ")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            ocrNumField($prefs.ocrDeepInterval, width: 52)
                            Text("s")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                        }

                        HStack(spacing: 0) {
                            Text("OCR budget: ")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            ocrIntField($prefs.ocrDeepBudget, width: 32)
                            Text(" windows per scan")
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.textDim)
                            Spacer()
                        }

                        // Human-readable deep interval
                        let h = Int(prefs.ocrDeepInterval / 3600)
                        let m = Int(prefs.ocrDeepInterval.truncatingRemainder(dividingBy: 3600) / 60)
                        if h > 0 || m > 0 {
                            Text("≈ \(h > 0 ? "\(h)h" : "")\(m > 0 ? " \(m)m" : "")")
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted.opacity(0.6))
                                .padding(.leading, 2)
                        }
                    }
                }

                // ── Status Card ──
                settingsCard {
                    HStack(spacing: 8) {
                        let ocrResults = ScreenText.shared.results
                        let isScanning = ScreenText.shared.isScanning

                        Circle()
                            .fill(isScanning ? Palette.detach : (prefs.ocrEnabled ? Palette.running : Palette.textMuted))
                            .frame(width: 6, height: 6)

                        Text(isScanning ? "Scanning..." : (prefs.ocrEnabled ? "\(ocrResults.count) windows cached" : "Disabled"))
                            .font(Typo.mono(10))
                            .foregroundColor(Palette.textMuted)

                        Spacer()

                        Button {
                            ScreenText.shared.scan()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Scan Now")
                                    .font(Typo.monoBold(10))
                            }
                            .foregroundColor(prefs.ocrEnabled ? Palette.text : Palette.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .buttonBox(emphasized: prefs.ocrEnabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!prefs.ocrEnabled)
                    }
                }

                // ── Recent Captures ──
                recentCapturesSection
            }
            .padding(16)
        }
    }

    // MARK: - Recent Captures Browser

    private var recentCapturesSection: some View {
        let ocrResults = ScreenText.shared.results
        let grouped = Dictionary(grouping: ocrResults.values, by: \.app)
            .sorted { $0.value.count > $1.value.count }

        return Group {
            if !grouped.isEmpty {
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ocrSectionLabel("Recent Captures")

                        ForEach(grouped, id: \.key) { app, windows in
                            ocrAppGroup(app: app, windows: windows.sorted { $0.timestamp > $1.timestamp })
                        }
                    }
                }
            }
        }
    }

    private func ocrAppGroup(app: String, windows: [OcrWindowResult]) -> some View {
        let isCollapsed = collapsedOcrApps.contains(app)

        return VStack(alignment: .leading, spacing: 0) {
            // App header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed {
                        collapsedOcrApps.remove(app)
                    } else {
                        collapsedOcrApps.insert(app)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Palette.textMuted)
                        .frame(width: 10)

                    Text(app)
                        .font(Typo.monoBold(11))
                        .foregroundColor(Palette.text)

                    Text("(\(windows.count))")
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)

                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(windows, id: \.wid) { win in
                        ocrWindowRow(win)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private func ocrWindowRow(_ win: OcrWindowResult) -> some View {
        let isExpanded = expandedOcrWindow == win.wid
        let preview = String(win.fullText.prefix(80)).replacingOccurrences(of: "\n", with: " ")

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedOcrWindow = isExpanded ? nil : win.wid
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Palette.textMuted)
                        .frame(width: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(win.title.isEmpty ? "Untitled" : win.title)
                                .font(Typo.mono(10))
                                .foregroundColor(Palette.text)
                                .lineLimit(1)

                            Spacer()

                            Text(ocrRelativeTime(win.timestamp))
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted)
                        }

                        if !isExpanded && !preview.isEmpty {
                            Text(preview)
                                .font(Typo.caption(9))
                                .foregroundColor(Palette.textMuted.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ocrExpandedDetail(win)
                    .padding(.leading, 14)
                    .padding(.vertical, 4)
            }
        }
    }

    private func ocrExpandedDetail(_ win: OcrWindowResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Metadata row
            HStack(spacing: 10) {
                let avgConfidence = win.texts.isEmpty ? 0 : win.texts.map(\.confidence).reduce(0, +) / Float(win.texts.count)
                Text("\(win.texts.count) blocks")
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted)
                Text("confidence: \(String(format: "%.0f%%", avgConfidence * 100))")
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted)
                Spacer()
            }

            // Full text in scrollable monospaced area
            ScrollView {
                Text(win.fullText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Palette.textDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 150)
            .outlinedBox(Color.black.opacity(0.2))
        }
    }

    private func ocrRelativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: - Settings Card

    private func settingsCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsPrefRow<Control: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: caption == nil ? .center : .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.body(12))
                    .foregroundColor(Palette.text)
                if let caption {
                    Text(caption)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
    }

    private var cardDivider: some View {
        HudDivider(color: Palette.border)
            .padding(.vertical, 3)
    }

    private func settingsActionLabel(_ title: String, icon: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(Typo.monoBold(10))
        }
        .foregroundColor(emphasized ? Palette.text : Palette.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .buttonBox(emphasized: emphasized)
    }

    private func permissionSettingsRow(
        _ title: String,
        granted: Bool,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if granted {
                permChecker.check()
            } else {
                action()
            }
        } label: {
            permissionRowContent(
                title,
                status: granted ? "granted" : "not set",
                statusColor: granted ? Palette.running : Palette.detach,
                icon: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                iconColor: granted ? Palette.running : Palette.detach,
                detail: detail,
                showsExternalLink: !granted
            )
        }
        .buttonStyle(.plain)
        .help(granted ? "Refresh permission status" : "Open macOS permission flow")
    }

    private func permissionReviewRow(
        _ title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            permissionRowContent(
                title,
                status: "review",
                statusColor: Palette.textDim,
                icon: "gearshape.2.fill",
                iconColor: Palette.textDim,
                detail: detail,
                showsExternalLink: true
            )
        }
        .buttonStyle(.plain)
        .help("Open macOS Privacy & Security settings")
    }

    private func permissionRowContent(
        _ title: String,
        status: String,
        statusColor: Color,
        icon: String,
        iconColor: Color,
        detail: String,
        showsExternalLink: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 12, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.text)
                    Text(status)
                        .font(Typo.mono(9))
                        .foregroundColor(statusColor)
                    Spacer()
                    if showsExternalLink {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.textMuted)
                    }
                }

                Text(detail)
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func breakerStatusRow(
        state: EventTapBreaker.State,
        label: String,
        onReArm: @escaping () -> Void
    ) -> some View {
        switch state {
        case .armed:
            EmptyView()
        case .paused(let cooldownSec):
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("\(label) paused — \(cooldownSec)s cooldown")
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted)
                Spacer()
            }
        case .disabled:
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("\(label) disabled — tap callback exceeded OS budget repeatedly")
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textMuted)
                Spacer()
                Button {
                    onReArm()
                } label: {
                    Text("Re-enable")
                        .font(Typo.monoBold(10))
                        .foregroundColor(Palette.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .buttonBox()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsContent: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let contentWidth = max(geo.size.width - 56, 320)
                let tilingColumns = contentWidth > 860
                    ? [
                        GridItem(.flexible(minimum: 280, maximum: 360), spacing: 16, alignment: .top),
                        GridItem(.flexible(minimum: 320, maximum: 640), spacing: 16, alignment: .top)
                    ]
                    : [GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 16, alignment: .top)]

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 22) {
                            inputControlsCard

                            shortcutMapHeader

                            shortcutMapSection(
                                "App",
                                actions: HotkeyAction.allCases.filter { $0.group == .app }
                            )

                            shortcutMapSection(
                                "Layers",
                                actions: HotkeyAction.layerActions + [.layerPrev, .layerNext, .layerUp, .layerDown, .layerTag]
                            )

                            settingsPrefRow(
                                "Confirm a layer switch",
                                caption: "After letting go of ⌘⌥ on another layer: how long Return has before you stay where you are."
                            ) {
                                SettingsChoiceBar(
                                    selection: $prefs.layerSwitchConfirmSeconds,
                                    options: [(0, "Switch at once"), (3, "3s"), (5, "5s"), (10, "10s"), (-1, "Until I choose")]
                                )
                            }

                            shortcutSectionCard(
                                title: "Tiling",
                                eyebrow: "Desktop Layout",
                                summary: "The grid is the placement map. Click a cell to rebind. While Ctrl+Option is held, numpad or number-row 1–9 tile the matrix; arrows aim an edge or corner and apply on release."
                            ) {
                                LazyVGrid(columns: tilingColumns, alignment: .leading, spacing: 20) {
                                    shortcutsTilingVisualizer
                                    shortcutMapSection(
                                        "Bindings",
                                        actions: [
                                            .tileLeft, .tileRight, .tileTop, .tileBottom,
                                            .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
                                            .tileLeftThird, .tileCenterThird, .tileRightThird,
                                            .tileCenter, .tileMaximize, .tileOpenCell,
                                            .tileDistribute, .tileTypeGrid, .tileOrganize,
                                            .motionMode,
                                        ],
                                        showTitle: false
                                    )
                                }
                            }

                            shortcutsTmuxCard
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                    }
                }
            }

            Spacer(minLength: 0)

            separator

            HStack {
                HStack(spacing: 8) {
                    footerActionButton(icon: "book", label: "Docs") {
                        ScreenMapWindowController.shared.showPage(.docs)
                    }

                    footerActionButton(icon: "list.bullet.rectangle", label: "Activity Log") {
                        ScreenMapWindowController.shared.showPage(.activity)
                    }
                }

                Spacer()

                Button {
                    hotkeyStore.resetAll()
                } label: {
                    Text("Reset all to defaults")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Shortcuts: Overview

    // MARK: - Shortcuts: map

    private var shortcutMapHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shortcuts")
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)
                Text("Click a shortcut to rebind it.")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
            }
            Spacer(minLength: 12)
            SettingsChoiceBar(
                selection: $shortcutScope,
                options: ShortcutScope.allCases.map { ($0, $0.label) }
            )
        }
    }

    private func visibleShortcutActions(_ actions: [HotkeyAction]) -> [HotkeyAction] {
        switch shortcutScope {
        case .all:
            return actions
        case .assigned:
            return actions.filter { hotkeyStore.bindings[$0] != nil }
        }
    }

    private func shortcutMapSection(
        _ title: String,
        actions: [HotkeyAction],
        showTitle: Bool = true
    ) -> some View {
        let visible = visibleShortcutActions(actions)
        let hidden = max(actions.count - visible.count, 0)
        return VStack(alignment: .leading, spacing: 6) {
            if showTitle {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(Typo.heading(13))
                        .foregroundColor(Palette.text)
                    Spacer(minLength: 8)
                    if shortcutScope == .assigned && hidden > 0 {
                        Button {
                            shortcutScope = .all
                        } label: {
                            Text("\(hidden) unassigned")
                                .font(Typo.caption(11))
                                .foregroundColor(Palette.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if visible.isEmpty {
                Text(shortcutScope == .assigned ? "None assigned" : "None")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 180), spacing: 28, alignment: .leading),
                        GridItem(.flexible(minimum: 180), spacing: 28, alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(visible, id: \.rawValue) { action in
                        ShortcutMapRow(action: action, store: hotkeyStore)
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts: Tiling

    private var shortcutsTilingVisualizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            shortcutSubsectionLabel("Screen Regions")

            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        tileCell(action: .tileTopLeft, label: "TL")
                        tileCell(action: .tileTop, label: "Top")
                        tileCell(action: .tileTopRight, label: "TR")
                    }
                    HStack(spacing: 2) {
                        tileCell(action: .tileLeft, label: "Left")
                        tileCell(action: .tileMaximize, label: "Max")
                        tileCell(action: .tileRight, label: "Right")
                    }
                    HStack(spacing: 2) {
                        tileCell(action: .tileBottomLeft, label: "BL")
                        tileCell(action: .tileBottom, label: "Bottom")
                        tileCell(action: .tileBottomRight, label: "BR")
                    }
                }
                .padding(8)
                .background(shortcutsInsetPanel)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thirds")
                        .font(Typo.caption(10.5))
                        .foregroundColor(Palette.textMuted)

                    HStack(spacing: 2) {
                        tileCell(action: .tileLeftThird, label: "\u{2153}L")
                        tileCell(action: .tileCenterThird, label: "\u{2153}C")
                        tileCell(action: .tileRightThird, label: "\u{2153}R")
                    }
                }
                .padding(8)
                .background(shortcutsInsetPanel)

                VStack(alignment: .leading, spacing: 6) {
                    Text("HUD keyboard")
                        .font(Typo.caption(10.5))
                        .foregroundColor(Palette.textMuted)

                    Text("While Ctrl+Option is held")
                        .font(Typo.caption(9.5))
                        .foregroundColor(Palette.textDim)

                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            hudKeyboardCell("7")
                            hudKeyboardCell("8")
                            hudKeyboardCell("9")
                        }
                        HStack(spacing: 2) {
                            hudKeyboardCell("4")
                            hudKeyboardCell("5")
                            hudKeyboardCell("6")
                        }
                        HStack(spacing: 2) {
                            hudKeyboardCell("1")
                            hudKeyboardCell("2")
                            hudKeyboardCell("3")
                        }
                    }

                    Text("Numpad or number row. Arrows: one edge, two for a corner — release Ctrl+Option to apply.")
                        .font(Typo.caption(9.5))
                        .foregroundColor(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(shortcutsInsetPanel)

                Text("Global shortcuts below fire instantly. HUD keys only apply while Ctrl+Option is held.")
                    .font(Typo.caption(10.5))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shortcuts: tmux

    private var shortcutsTmuxCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("tmux panes")
                .font(Typo.heading(13))
                .foregroundColor(Palette.text)
            Text("Reference only — not edited here.")
                .font(Typo.caption(11))
                .foregroundColor(Palette.textMuted)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 180), spacing: 28, alignment: .leading),
                    GridItem(.flexible(minimum: 180), spacing: 28, alignment: .leading),
                ],
                alignment: .leading,
                spacing: 0
            ) {
                shortcutRow("Detach", keys: ["⌃B", "D"])
                shortcutRow("Kill pane", keys: ["⌃B", "X"])
                shortcutRow("Pane left", keys: ["⌃B", "←"])
                shortcutRow("Pane right", keys: ["⌃B", "→"])
                shortcutRow("Zoom", keys: ["⌃B", "Z"])
                shortcutRow("Scroll", keys: ["⌃B", "["])
            }
        }
    }

    // MARK: - Shortcut section UI

    private func shortcutSectionCard<Content: View>(
        title: String,
        eyebrow: String,
        summary: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typo.heading(13))
                    .foregroundColor(Palette.text)

                Text(summary)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
    }

    private func shortcutFactCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.textDim)

            Text(title)
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)

            Text(detail)
                .font(Typo.caption(10))
                .foregroundColor(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func shortcutSubsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Typo.caption(11))
            .foregroundColor(Palette.textMuted)
    }

    private var shortcutsInsetPanel: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Palette.surface.opacity(0.55))
    }

    private func hudKeyboardCell(_ label: String) -> some View {
        Text(label)
            .font(Typo.geistMonoBold(9))
            .foregroundColor(Palette.text)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .outlinedBox()
    }

    private func tileCellBadge(_ binding: KeyBinding?) -> String {
        guard let binding else { return "Unset" }
        let parts = binding.displayParts
        guard let key = parts.last else { return "Unset" }
        if parts.contains("Shift") {
            return "⇧\(key)"
        }
        return key
    }

    private func relativeTimestamp(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Tile cell (spatial grid item)

    private func tileCell(action: HotkeyAction, label: String) -> some View {
        let binding = hotkeyStore.bindings[action]
        let badgeText = tileCellBadge(binding)

        return Button {
            // Open inline key recorder for this action
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(Typo.caption(9))
                    .foregroundColor(Palette.textDim)
                Text(badgeText)
                    .font(Typo.geistMonoBold(9))
                    .foregroundColor(Palette.text)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .outlinedBox()
        }
        .buttonStyle(.plain)
        .popover(isPresented: tileCellPopoverBinding(for: action)) {
            KeyRecorderView(action: action, store: hotkeyStore)
                .padding(12)
                .frame(width: 300)
        }
    }

    @State private var expandedOcrWindow: UInt32?
    @State private var collapsedOcrApps: Set<String> = []

    @State private var activeTilePopover: HotkeyAction?

    private func tileCellPopoverBinding(for action: HotkeyAction) -> Binding<Bool> {
        Binding(
            get: { activeTilePopover == action },
            set: { if !$0 { activeTilePopover = nil } }
        )
    }

    // MARK: - Compact key recorder

    private func compactKeyRecorder(action: HotkeyAction) -> some View {
        KeyRecorderView(action: action, store: hotkeyStore)
    }

    // MARK: - Shortcut row (read-only, for tmux)

    private func shortcutRow(_ label: String, keys: [String]) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typo.body(12))
                .foregroundColor(Palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(Typo.geistMonoBold(10))
                        .foregroundColor(Palette.text)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.surfaceHov)
                        )
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Docs

    private var docsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section(header: stickyHeader("What is lattices?")) {
                    Text("A developer workspace launcher. It creates pre-configured terminal layouts for your projects \u{2014} go from \u{201C}I want to work on X\u{201D} to a full environment in one click.")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                        .lineSpacing(3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }

                Section(header: stickyHeader("Glossary")) {
                    VStack(alignment: .leading, spacing: 12) {
                        glossaryItem("Session",
                            "A persistent workspace that lives in the background. Survives terminal crashes, disconnects, even closing your laptop.")
                        glossaryItem("Pane",
                            "A single terminal view inside a session. A typical setup has two panes \u{2014} Claude Code on the left, dev server on the right.")
                        glossaryItem("Attach",
                            "Connect your terminal window to an existing session. The session was already running \u{2014} you\u{2019}re just viewing it.")
                        glossaryItem("Detach",
                            "Disconnect your terminal but keep the session alive. Your dev server keeps running, Claude keeps thinking.")
                        glossaryItem("tmux",
                            "Terminal multiplexer \u{2014} the engine behind lattices. It manages sessions, panes, and layouts. lattices configures it so you don\u{2019}t have to.")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                Section(header: stickyHeader("How it works")) {
                    VStack(alignment: .leading, spacing: 8) {
                        flowStep("1", "Create a .lattices.json in your project root")
                        flowStep("2", "lattices reads the config and builds a tmux session")
                        flowStep("3", "Each pane gets its command (claude, dev server, etc.)")
                        flowStep("4", "Session persists in the background until you kill it")
                        flowStep("5", "Attach and detach from any terminal, any time")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                Section(header: stickyHeader("Voice commands")) {
                    VStack(alignment: .leading, spacing: 8) {
                        flowStep("⌥", "Hold Option key to speak, release to stop")
                        flowStep("⇥", "Tab to arm/disarm the mic")
                        flowStep("⎋", "Escape to dismiss")

                        Text("Built-in commands: find, show, open, tile, kill, scan")
                            .font(Typo.caption(10.5))
                            .foregroundColor(Palette.textMuted)
                            .padding(.top, 4)

                        Text("When local matching fails, the optional voice provider can advise with follow-up suggestions. Chat uses Scout; voice capture and any voice-only provider credential live in Settings → Voice.")
                            .font(Typo.caption(10.5))
                            .foregroundColor(Palette.textMuted)
                            .lineSpacing(2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                Section(header: stickyHeader("Reference")) {
                    HStack(spacing: 8) {
                        docsLinkButton(icon: "doc.text", label: "Config format", file: "config.md")
                        docsLinkButton(icon: "book", label: "Full concepts", file: "concepts.md")
                        footerActionButton(icon: "list.bullet.rectangle", label: "Activity Log") {
                            ScreenMapWindowController.shared.showPage(.activity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Docs helpers

    private func glossaryItem(_ term: String, _ definition: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(term)
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)
            Text(definition)
                .font(Typo.caption(10.5))
                .foregroundColor(Palette.textMuted)
                .lineSpacing(2)
        }
    }

    private func flowStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.running)
                .frame(width: 14)
            Text(text)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textDim)
        }
    }

    private func docsLinkButton(icon: String, label: String, file: String) -> some View {
        Button {
            let path = resolveDocsFile(file)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            footerActionLabel(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    private func footerActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            footerActionLabel(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    private func footerActionLabel(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(Typo.caption(11))
        }
        .foregroundColor(Palette.textMuted)
    }

    private func resolveDocsFile(_ file: String) -> String {
        let bundle = Bundle.main.bundlePath
        let appDir = (bundle as NSString).deletingLastPathComponent
        let docsPath = ((appDir as NSString).appendingPathComponent("../docs/\(file)") as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: docsPath) { return docsPath }
        // Fallback: look relative to the repo root (dev builds)
        let repoGuess = ((appDir as NSString).appendingPathComponent("../../docs/\(file)") as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: repoGuess) ? repoGuess : docsPath
    }

    // MARK: - Shared helpers

    private var separator: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 0.5)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textDim)
                .frame(width: 100, alignment: .trailing)
                .padding(.top, 2)

            content()
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

/// Keeps the 1.5-second desktop inventory publisher local to the Hyperspace
/// display tiles instead of invalidating the entire Settings hierarchy.
private struct HyperspaceDisplayTile: View {
    let index: Int
    let screen: NSScreen

    @ObservedObject private var desktopModel = DesktopModel.shared

    private var windowCount: Int {
        desktopModel.allWindows().filter { entry in
            entry.pid != ProcessInfo.processInfo.processIdentifier &&
            entry.isOnScreen &&
            !entry.title.isEmpty &&
            ObjectIdentifier(WindowTiler.screenForWindowFrame(entry.frame)) == ObjectIdentifier(screen)
        }.count
    }

    var body: some View {
        let windows = windowCount
        let name = index == 0 ? "Main display" : "Display \(index + 1)"
        let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: index == 0 ? "display" : "rectangle.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(windows > 0 ? Palette.running : Palette.textMuted)
                    .frame(width: 16)

                Text(name)
                    .font(Typo.monoBold(10.5))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text(size)
                    .font(Typo.caption(9.5))
                    .foregroundColor(Palette.textMuted)
                Spacer(minLength: 0)
                Text("\(windows)")
                    .font(Typo.monoBold(11))
                    .foregroundColor(windows > 0 ? Palette.running : Palette.textMuted)
                Text(windows == 1 ? "window" : "windows")
                    .font(Typo.caption(9.5))
                    .foregroundColor(Palette.textMuted)
            }
        }
        .padding(10)
        .outlinedBox(Color.black.opacity(0.22))
    }
}

private struct SettingsSidebarRow: View {
    let icon: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var titleTint: Color {
        if isActive { return Palette.text }
        if isHovering { return Palette.text }
        return Palette.textDim
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? Palette.textDim : Palette.textMuted)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(isActive ? Typo.body(12) : Typo.body(12))
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundColor(titleTint)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Palette.surfaceHov.opacity(0.7) : (isHovering ? Palette.surface.opacity(0.45) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
