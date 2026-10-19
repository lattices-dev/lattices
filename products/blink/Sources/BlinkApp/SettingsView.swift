import AppKit
import HudsonUI
import SwiftUI

/// Blink's settings are a view over the agent-first config file. Every mutable
/// control round-trips through `BlinkConfigStore.update`; external edits remain
/// authoritative and repaint this surface through the observed store.
struct SettingsView: View {
    @ObservedObject var store: BlinkConfigStore
    let notesDirectory: URL

    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: SettingsSection = .general
    @ObservedObject private var menuBar = CompanionMenuBarVisibility.shared
    @StateObject private var rail = WindowFrameRail(persistKey: "blink.settings.rail")

    private var isDark: Bool {
        switch store.config.appearance.lowercased() {
        case "light": return false
        case "dark": return true
        default: return colorScheme == .dark
        }
    }

    private var settingsTheme: HudTheme { BlinkBrand.hudTheme(dark: isDark) }

    private var tildePath: String {
        notesDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var restoreSession: Binding<Bool> {
        Binding(
            get: { store.config.behavior.restoreSession },
            set: { value in store.update { $0.behavior.restoreSession = value } }
        )
    }

    private var defaultMode: Binding<String> {
        Binding(
            get: { store.config.behavior.defaultMode },
            set: { value in store.update { $0.behavior.defaultMode = value } }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { store.config.behavior.launchAtLogin },
            set: { value in store.update { $0.behavior.launchAtLogin = value } }
        )
    }

    private var defaultSheet: Binding<String> {
        Binding(
            get: { store.config.panel.sheet },
            set: { value in store.update { $0.panel.sheet = value } }
        )
    }

    private var panelShadow: Binding<Bool> {
        Binding(
            get: { store.config.panel.shadow },
            set: { value in store.update { $0.panel.shadow = value } }
        )
    }

    private var panelSize: Binding<PanelSizePreset> {
        Binding(
            get: {
                PanelSizePreset.matching(
                    width: store.config.panel.defaultWidth,
                    height: store.config.panel.defaultHeight
                )
            },
            set: { preset in
                guard let size = preset.size else { return }
                store.update {
                    $0.panel.defaultWidth = size.width
                    $0.panel.defaultHeight = size.height
                }
            }
        )
    }

    private var appearance: Binding<String> {
        Binding(
            get: {
                let value = store.config.appearance.lowercased()
                return ["auto", "light", "dark"].contains(value) ? value : "auto"
            },
            set: { value in store.update { $0.appearance = value } }
        )
    }

    private var backgroundLevel: Binding<BackgroundLevel> {
        Binding(
            get: {
                guard store.config.drape.enabled else { return .off }
                return store.config.drape.opacity <= 0.7 ? .light : .full
            },
            set: { level in
                store.update {
                    switch level {
                    case .off:
                        $0.drape.enabled = false
                    case .light:
                        $0.drape.enabled = true
                        $0.drape.opacity = 0.4
                    case .full:
                        $0.drape.enabled = true
                        $0.drape.opacity = 1
                    }
                }
            }
        )
    }

    private var suppressSoloDrape: Binding<Bool> {
        Binding(
            get: { store.config.drape.soloSuppressed },
            set: { value in store.update { $0.drape.soloSuppressed = value } }
        )
    }

    private var focusDim: Binding<Double> {
        Binding(
            get: { store.config.focus.dim },
            set: { value in store.update { $0.focus.dim = value } }
        )
    }

    private var motionEnabled: Binding<Bool> {
        Binding(
            get: { store.config.motion.enabled },
            set: { value in store.update { $0.motion.enabled = value } }
        )
    }

    private var entrance: Binding<String> {
        Binding(
            get: { store.config.motion.entrance },
            set: { value in store.update { $0.motion.entrance = value } }
        )
    }

    private var flingEnabled: Binding<Bool> {
        Binding(
            get: { store.config.physics.flingEnabled },
            set: { value in store.update { $0.physics.flingEnabled = value } }
        )
    }

    private var shakeEnabled: Binding<Bool> {
        Binding(
            get: { store.config.physics.shakeEnabled },
            set: { value in store.update { $0.physics.shakeEnabled = value } }
        )
    }

    var body: some View {
        WindowFrame(
            rail: rail,
            chrome: settingsTheme.palette.chrome,
            sheet: settingsTheme.palette.bg,
            edge: settingsTheme.hairline.subtle
        ) {
            brand
        } navigation: { folded in
            sidebar(folded: folded)
        } content: {
            content
        }
        .frame(minWidth: 620, idealWidth: 780, minHeight: 460, idealHeight: 580)
        .background { shortcuts }
        .buttonStyle(BrandButtonStyle())
        .hudTheme(settingsTheme)
    }

    /// The mark and wordmark after the traffic lights, open or folded.
    private var brand: some View {
        HStack(spacing: 7) {
            BlinkMark(ink: settingsTheme.palette.ink)
                .frame(width: 16, height: 16)
            Text("Canvas")
                .font(.system(size: 16, weight: .light, design: .serif))
                .tracking(-0.2)
                .foregroundStyle(settingsTheme.palette.ink)
        }
    }

    private func sidebar(folded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element) { index, section in
                    SettingsNavRow(
                        section: section,
                        shortcut: index + 1,
                        folded: folded,
                        selected: selection == section
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.top, folded ? HudSpacing.md : 0)

            Spacer(minLength: HudSpacing.xxxl)

            if !folded {
                Button(action: openConfig) {
                    Text("config.json")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .buttonStyle(BrandButtonStyle(quiet: true))
                .help("Every setting here lives in config.json")
                .padding(.horizontal, HudSpacing.md)
                .padding(.bottom, HudSpacing.lg)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// ⌘1… jump to a page and ⌘B folds the rail, as in Hudson's side nav.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element) { index, section in
                Button("") { selection = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { rail.toggle() }
                .keyboardShortcut("b", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .tracking(-0.6)
                    .foregroundStyle(settingsTheme.palette.ink)

                Text(selection.subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(settingsTheme.palette.muted)
                    .padding(.top, 6)

                selectedPage
                    .padding(.top, 28)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 56)
            .id(selection)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: Woven.reduceMotion ? 0 : 4)),
                    removal: .identity
                )
            )
        }
        .scrollIndicators(.automatic)
        .animation(BlinkBrand.rise, value: selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .general: generalPage
        case .notes: notesPage
        case .desktop: desktopPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            BrandSection("Files") {
                HudSettingsControlRow(title: "Notes folder", subtitle: tildePath) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([notesDirectory])
                    }
                    .accessibilityHint("Shows the Canvas notes folder in Finder")
                }
                SettingsDivider()
                HudSettingsControlRow(title: "Config file", subtitle: store.displayPath) {
                    Button("Open") { openConfig() }
                        .accessibilityHint("Opens Canvas's JSON configuration file")
                }
            }

            BrandSection("Startup") {
                HudSettingsControlRow(
                    title: "Restore panels at launch",
                    subtitle: "Reopen notes where you left them"
                ) {
                    Toggle("Restore panels at launch", isOn: restoreSession)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Restore panels at launch")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Launch at login",
                    subtitle: "Start Canvas when you sign in"
                ) {
                    Toggle("Launch at login", isOn: launchAtLogin)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Launch Canvas at login")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Always show menu bar icon",
                    subtitle: "Otherwise it appears whenever Lattices isn't running"
                ) {
                    Toggle("Always show menu bar icon", isOn: $menuBar.alwaysShow)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                }
            }
        }
    }

    private var notesPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            BrandSection("Defaults") {
                HudSettingsControlRow(
                    title: "Open notes in",
                    subtitle: "New notes can open ready to read or write"
                ) {
                    BrandSegmented(selection: defaultMode, options: [("Read", "read"), ("Edit", "edit")])
                    .frame(width: HudLayout.popoverWidthCompact / 2.6)
                    .accessibilityLabel("Default note mode")
                }
                SettingsDivider()
                HudSettingsPickerRow(
                    title: "Default sheet",
                    subtitle: "The starting look for notes without an override",
                    selection: defaultSheet
                ) {
                    Text("Glass").tag("glass")
                    Text("Card").tag("card")
                    Text("Dotted").tag("dotted")
                    Text("Bracket").tag("bracket")
                    Text("Marginalia").tag("marginalia")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Default panel size",
                    subtitle: panelSize.wrappedValue.description
                ) {
                    Picker("Default panel size", selection: panelSize) {
                        Text("Compact").tag(PanelSizePreset.compact)
                        Text("Standard").tag(PanelSizePreset.standard)
                        Text("Large").tag(PanelSizePreset.large)
                        if panelSize.wrappedValue == .custom {
                            Text("Custom").tag(PanelSizePreset.custom)
                        }
                    }
                    .labelsHidden()
                    .frame(width: HudLayout.popoverWidthCompact / 2)
                    .accessibilityLabel("Default panel size")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Panel shadow",
                    subtitle: "Add depth to glass and card sheets"
                ) {
                    Toggle("Panel shadow", isOn: panelShadow)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Show panel shadows")
                }
            }

            BrandSection("Advanced") {
                HudSettingsControlRow(
                    title: "Typography, styles & workspaces",
                    subtitle: "Fonts, colors, glass and named styles live in config.json"
                ) {
                    Button("Open") { openConfig() }
                        .accessibilityHint("Opens Canvas's JSON configuration file")
                }
            }
        }
    }

    private var desktopPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            BrandSection("Appearance") {
                HudSettingsControlRow(
                    title: "Appearance",
                    subtitle: "Utilities only; notes may differ"
                ) {
                    BrandSegmented(selection: appearance, options: [("Auto", "auto"), ("Light", "light"), ("Dark", "dark")])
                    .frame(width: HudLayout.popoverWidthCompact / 2)
                    .accessibilityLabel("Canvas appearance")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Desktop background",
                    subtitle: "A calm stage behind a set of notes"
                ) {
                    BrandSegmented(selection: backgroundLevel, options: BackgroundLevel.allCases.map { ($0.title, $0) })
                    .frame(width: HudLayout.popoverWidthCompact / 2)
                    .accessibilityLabel("Desktop background strength")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Keep one note clear",
                    subtitle: "Show the background only when notes form a set"
                ) {
                    Toggle("Keep one note clear", isOn: suppressSoloDrape)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .disabled(!store.config.drape.enabled)
                        .accessibilityLabel("Keep the desktop clear behind a single note")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Focus dimming",
                    subtitle: "Quiet the desktop around the focused note",
                    value: "\(Int(store.config.focus.dim * 100))%"
                ) {
                    Slider(value: focusDim, in: 0...0.8, step: 0.05)
                        .tint(settingsTheme.palette.ink)
                        .frame(width: HudLayout.popoverWidthCompact / 2)
                        .accessibilityLabel("Focus dimming")
                        .accessibilityValue("\(Int(store.config.focus.dim * 100)) percent")
                }
            }

            BrandSection("Motion & Gestures") {
                HudSettingsControlRow(
                    title: "Panel motion",
                    subtitle: "Animate notes as they appear and recede"
                ) {
                    Toggle("Panel motion", isOn: motionEnabled)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Animate panels")
                }
                SettingsDivider()
                HudSettingsPickerRow(
                    title: "Entrance effect",
                    subtitle: "Reduce Motion in macOS always takes precedence",
                    selection: entrance
                ) {
                    Text("Shimmer").tag("shimmer")
                    Text("Drop").tag("drop")
                    Text("Draw").tag("draw")
                    Text("None").tag("none")
                }
                .disabled(!store.config.motion.enabled)
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Fling panels",
                    subtitle: "Release a quick drag to glide and bounce"
                ) {
                    Toggle("Fling panels", isOn: flingEnabled)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Fling panels after a quick drag")
                }
                SettingsDivider()
                HudSettingsControlRow(
                    title: "Shake to shade",
                    subtitle: "Shake a panel sideways to fold its content"
                ) {
                    Toggle("Shake to shade", isOn: shakeEnabled)
                        .toggleStyle(BrandToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel("Shake panels to shade them")
                }
            }
        }
    }

    private func openConfig() {
        NSWorkspace.shared.open(store.fileURL)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case notes
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notes: "Notes"
        case .desktop: "Desktop"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Files, startup and session behavior"
        case .notes: "How new notes look and open"
        case .desktop: "Appearance, focus, movement and gestures"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .notes: "note.text"
        case .desktop: "display"
        }
    }
}

private enum BackgroundLevel: String, CaseIterable, Identifiable {
    case off
    case light
    case full

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum PanelSizePreset: String, Hashable {
    case compact
    case standard
    case large
    case custom

    var size: (width: Double, height: Double)? {
        switch self {
        case .compact: (360, 280)
        case .standard: (420, 340)
        case .large: (520, 420)
        case .custom: nil
        }
    }

    var description: String {
        guard let size else { return "Custom size from config.json" }
        return "\(Int(size.width)) × \(Int(size.height)) points"
    }

    static func matching(width: Double, height: Double) -> PanelSizePreset {
        for preset in [PanelSizePreset.compact, .standard, .large] {
            guard let size = preset.size else { continue }
            if abs(width - size.width) < 0.5, abs(height - size.height) < 0.5 {
                return preset
            }
        }
        return .custom
    }
}

/// A full-bleed square row with a flat ink wash when selected; the page you're
/// on is the one coral icon. Folded, it keeps only the icon and names itself in a tooltip.
private struct SettingsNavRow: View {
    let section: SettingsSection
    let shortcut: Int
    let folded: Bool
    let selected: Bool
    let action: () -> Void

    @Environment(\.hudTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: HudSpacing.lg) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? theme.palette.accent : theme.palette.muted)
                    .frame(width: HudIconSize.small, height: HudIconSize.small)

                if !folded {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: HudSpacing.sm)
                    Text("⌘\(shortcut)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.dim)
                        .opacity(hovering || selected ? 1 : 0)
                }
            }
            .foregroundStyle(selected ? theme.palette.ink : theme.palette.muted)
            .padding(.horizontal, folded ? 0 : HudSpacing.xl)
            .frame(maxWidth: .infinity, alignment: folded ? .center : .leading)
            .frame(height: HudLayout.rowHeightCompact)
            .background(
                theme.palette.ink.opacity(selected ? 0.08 : hovering ? 0.04 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(folded ? "\(section.title)  ⌘\(shortcut)" : "")
        .accessibilityLabel("\(section.title) settings")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsDivider: View {
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairline.subtle)
            .frame(height: 1)
            .padding(.horizontal, HudSpacing.md)
            .accessibilityHidden(true)
    }
}
