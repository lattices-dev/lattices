import BlinkPeer
import HudsonUI
import SwiftUI

private enum BlinkSettingsRoute: Hashable {
    case connection
    case appearance
    case storage
}

struct BlinkMobileSettingsView: View {
    @ObservedObject var model: BlinkMobileModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BlinkThemeChoice.storageKey) private var themeRaw = BlinkThemeChoice.default.rawValue
    @AppStorage(BlinkAppearance.storageKey) private var appearanceRaw = BlinkAppearance.default.rawValue
    @State private var path: [BlinkSettingsRoute] = []

    private var theme: BlinkThemeChoice {
        BlinkThemeChoice(rawValue: themeRaw) ?? .default
    }

    private var appearance: BlinkAppearance {
        BlinkAppearance(rawValue: appearanceRaw) ?? .default
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 22) {
                    connectionSection
                    appearanceSection
                    storageSection
                    aboutSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(BlinkBackdrop())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BlinkMobileTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: BlinkSettingsRoute.self) { route in
                switch route {
                case .connection:
                    ConnectionView(model: model)
                case .appearance:
                    BlinkAppearanceSettingsView()
                case .storage:
                    BlinkStorageSettingsView(model: model)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var connectionSection: some View {
        HudSettingsSection("Connection", labelTint: BlinkMobileTheme.faintInk) {
            HudSettingsRow(
                icon: connectionIcon,
                iconColor: connectionColor,
                title: "Mac",
                subtitle: connectionSubtitle,
                onTap: { path.append(.connection) }
            ) {
                BlinkSettingsBadge(connectionValue, color: connectionColor)
            }
        }
    }

    private var appearanceSection: some View {
        HudSettingsSection("Appearance", labelTint: BlinkMobileTheme.faintInk) {
            HudSettingsRow(
                icon: "paintpalette",
                iconColor: BlinkMobileTheme.signal,
                title: "Theme",
                subtitle: "\(theme.title) · \(appearance.title)",
                onTap: { path.append(.appearance) }
            )
        }
    }

    private var storageSection: some View {
        HudSettingsSection("On This Device", labelTint: BlinkMobileTheme.faintInk) {
            HudSettingsRow(
                icon: "iphone",
                iconColor: BlinkMobileTheme.secondaryInk,
                title: "Notes",
                subtitle: storageSubtitle,
                onTap: { path.append(.storage) }
            ) {
                BlinkSettingsBadge("\(model.notes.count)", color: BlinkMobileTheme.secondaryInk)
            }
        }
    }

    private var aboutSection: some View {
        HudSettingsSection("About", labelTint: BlinkMobileTheme.faintInk) {
            HudSettingsRow(
                icon: "info.circle",
                iconColor: BlinkMobileTheme.secondaryInk,
                title: "Canvas",
                subtitle: "Read-only companion"
            ) {
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(BlinkMobileTheme.faintInk)
            }
        }
    }

    private var connectionIcon: String {
        switch model.connectionState {
        case .disconnected: "desktopcomputer"
        case .requestingAccess: "ellipsis.circle"
        case .connected: "lock.fill"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .disconnected: BlinkMobileTheme.faintInk
        case .requestingAccess: BlinkMobileTheme.amber
        case .connected: BlinkMobileTheme.signal
        }
    }

    private var connectionValue: String {
        switch model.connectionState {
        case .disconnected: "OFF"
        case .requestingAccess: "WAITING"
        case .connected: "LIVE"
        }
    }

    private var connectionSubtitle: String {
        switch model.connectionState {
        case .disconnected: "Not connected"
        case .requestingAccess(let name): name
        case .connected(let host): host.name
        }
    }

    private var storageSubtitle: String {
        guard let lastSyncedAt = model.lastSyncedAt else { return "No notes saved" }
        return "Updated \(blinkSettingsAge(since: lastSyncedAt).lowercased())"
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(short) (\(build))"
    }
}

private struct BlinkAppearanceSettingsView: View {
    @AppStorage(BlinkThemeChoice.storageKey) private var themeRaw = BlinkThemeChoice.default.rawValue
    @AppStorage(BlinkAppearance.storageKey) private var appearanceRaw = BlinkAppearance.default.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HudSettingsSection("Display", labelTint: BlinkMobileTheme.faintInk) {
                    HudSettingsControlRow(
                        title: "Mode",
                        subtitle: "System, light, or dark",
                        icon: "circle.lefthalf.filled",
                        iconColor: BlinkMobileTheme.signal
                    ) {
                        Picker("Mode", selection: $appearanceRaw) {
                            ForEach(BlinkAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                HudSettingsSection("Theme", labelTint: BlinkMobileTheme.faintInk) {
                    ForEach(Array(BlinkThemeChoice.allCases.enumerated()), id: \.element.id) { index, theme in
                        BlinkThemeRow(
                            theme: theme,
                            isSelected: theme.rawValue == themeRaw,
                            action: { themeRaw = theme.rawValue }
                        )
                        if index < BlinkThemeChoice.allCases.count - 1 {
                            Rectangle()
                                .fill(BlinkMobileTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background(BlinkBackdrop())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BlinkMobileTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct BlinkThemeRow: View {
    let theme: BlinkThemeChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(Array(theme.previewColors.enumerated()), id: \.offset) { _, color in
                        Rectangle()
                            .fill(color)
                            .frame(width: 10, height: 28)
                    }
                }
                .overlay {
                    Rectangle()
                        .stroke(BlinkMobileTheme.hairline, lineWidth: 1)
                }
                .frame(width: 34)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.title)
                        .font(.body)
                        .foregroundStyle(BlinkMobileTheme.ink)
                    Text(theme.detail)
                        .font(.caption)
                        .foregroundStyle(BlinkMobileTheme.secondaryInk)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BlinkMobileTheme.signal : BlinkMobileTheme.faintInk)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .background(isSelected ? BlinkMobileTheme.signal.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title), \(theme.detail)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct BlinkStorageSettingsView: View {
    @ObservedObject var model: BlinkMobileModel
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HudSettingsSection("Local Notes", labelTint: BlinkMobileTheme.faintInk) {
                    HudSettingsRow(
                        icon: "doc.on.doc",
                        iconColor: BlinkMobileTheme.signal,
                        title: "Saved",
                        subtitle: updatedValue
                    ) {
                        BlinkSettingsBadge("\(model.notes.count)", color: BlinkMobileTheme.signal)
                    }
                    Rectangle()
                        .fill(BlinkMobileTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 52)
                    HudSettingsRow(
                        icon: "wifi.slash",
                        iconColor: BlinkMobileTheme.secondaryInk,
                        title: "Without your Mac",
                        subtitle: model.snapshot == nil ? "Unavailable" : "Available"
                    )
                }

                if model.snapshot != nil {
                    HudSettingsSection("Data", labelTint: BlinkMobileTheme.faintInk) {
                        HudSettingsRow(
                            icon: "trash",
                            iconColor: .red,
                            title: "Remove Notes",
                            subtitle: "Mac notes are not changed",
                            onTap: { confirmingRemoval = true }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background(BlinkBackdrop())
        .navigationTitle("On This Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BlinkMobileTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog(
            "Remove notes from this device?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Notes", role: .destructive) {
                Task { await model.clearOfflineNotes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes on your Mac are unchanged. Reconnect to make them available here again.")
        }
    }

    private var updatedValue: String {
        guard let lastSyncedAt = model.lastSyncedAt else { return "Not updated" }
        return "Updated \(blinkSettingsAge(since: lastSyncedAt).lowercased())"
    }
}

private struct BlinkSettingsBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            }
    }
}

private func blinkSettingsAge(since date: Date, now: Date = Date()) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "JUST NOW" }
    if interval < 3_600 { return "\(Int(interval / 60))M AGO" }
    if interval < 86_400 { return "\(Int(interval / 3_600))H AGO" }
    if interval < 30 * 86_400 { return "\(Int(interval / 86_400))D AGO" }
    return date.formatted(date: .abbreviated, time: .omitted).uppercased()
}
