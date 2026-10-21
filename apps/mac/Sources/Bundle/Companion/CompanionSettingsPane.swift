import AppKit
import DeckKit
import HudsonUI
import SwiftUI

/// Settings for the iPad companion: the bridge, trusted devices and the
/// cockpit deck. Core Settings shows these through `BundleModules`.
struct CompanionSettingsPane: View {
    @ObservedObject var prefs: Preferences = .shared
    @ObservedObject var cockpit: CompanionCockpitStore = .shared
    @ObservedObject var permChecker: PermissionChecker = .shared

    @State private var selectedCompanionCockpitPageID = "main"
    @State private var companionTrustRevision = 0

    var body: some View {
        companionContent
    }

    private func settingsCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardDivider: some View {
        HudDivider(color: HudHairline.subtle)
            .padding(.vertical, 3)
    }

    private var shortcutsInsetPanel: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Palette.surface.opacity(0.55))
    }

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

    private func relativeTimestamp(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private var companionTrackpadBinding: Binding<Bool> {
        Binding(
            get: { prefs.companionTrackpadEnabled },
            set: { enabled in
                prefs.companionTrackpadEnabled = enabled
                if enabled && !permChecker.accessibility {
                    permChecker.requestAccessibility()
                }
            }
        )
    }

    private var companionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                companionBridgeOverviewCard
                companionTrustedDevicesCard
                companionCockpitCard
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var companionBridgeOverviewCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Palette.running.opacity(0.14))
                        .overlay(
                            Image(systemName: "lock.shield")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Palette.running)
                        )
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(prefs.companionBridgeEnabled ? "Private local bridge" : "Local bridge off")
                            .font(Typo.mono(12))
                            .foregroundColor(Palette.text)
                        Text(prefs.companionBridgeEnabled
                            ? "Local communication uses a private socket. Remote companions connect through a separately started gateway."
                            : "Enable the private local bridge to allow companion requests through the gateway.")
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    SettingsSwitch(isOn: $prefs.companionBridgeEnabled)
                }

                cardDivider

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 120), spacing: 10, alignment: .leading),
                        GridItem(.flexible(minimum: 120), spacing: 10, alignment: .leading),
                        GridItem(.flexible(minimum: 120), spacing: 10, alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    companionBridgeFact(
                        label: "Status",
                        value: prefs.companionBridgeEnabled ? "enabled" : "off"
                    )
                    companionBridgeFact(
                        label: "Transport",
                        value: "private IPC"
                    )
                    companionBridgeFact(
                        label: "Protocol",
                        value: "v\(LatticesCompanionBridgeServer.protocolVersion)"
                    )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote gateway")
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textDim)
                    Text("lats gateway start --tailnet")
                        .font(Typo.monoBold(12))
                        .foregroundColor(Palette.text)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shortcutsInsetPanel)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Mac bridge fingerprint")
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textDim)
                    Text(LatticesCompanionSecurityCoordinator.shared.bridgeFingerprint)
                        .font(Typo.monoBold(13))
                        .foregroundColor(Palette.text)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shortcutsInsetPanel)

                HStack(spacing: 6) {
                    ForEach(DeckBridgeCapability.defaultCompanionCapabilities, id: \.self) { capability in
                        companionCapabilityBadge(capability)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var companionTrustedDevicesCard: some View {
        let trustedDevices = companionTrustedDevices(revision: companionTrustRevision)

        return settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paired devices")
                            .font(Typo.mono(12))
                            .foregroundColor(Palette.text)
                        Text("Only trusted devices can call protected deck and input routes. Pairing grants are listed per device.")
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            companionTrustRevision += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Palette.textDim)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Palette.surfaceHov)
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.borderLit, lineWidth: 0.5))
                                )
                        }
                        .buttonStyle(.plain)

                        if trustedDevices.isEmpty == false {
                            Button {
                                guard confirmForgetTrustedDevices() else { return }
                                LatticesCompanionSecurityCoordinator.shared.clearTrustedDevices()
                                companionTrustRevision += 1
                            } label: {
                                Text("Forget All")
                                    .font(Typo.monoBold(10))
                                    .foregroundColor(Palette.kill.opacity(0.9))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Palette.kill.opacity(0.10))
                                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.kill.opacity(0.22), lineWidth: 0.5))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if trustedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "ipad.and.iphone")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Palette.textMuted)

                        Text("No paired iPad or iPhone devices yet.")
                            .font(Typo.caption(10.5))
                            .foregroundColor(Palette.textMuted)

                        Text("Open the Lattices companion app on your iPad and select this Mac. You’ll approve the pairing prompt here.")
                            .font(Typo.caption(9.5))
                            .foregroundColor(Palette.textMuted.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(shortcutsInsetPanel)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(trustedDevices) { device in
                            companionDeviceRow(device)
                        }
                    }
                }
            }
        }
    }

    private func companionBridgeFact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Typo.pixel(11))
                .foregroundColor(Palette.textDim)
                .tracking(1)
            Text(value)
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shortcutsInsetPanel)
    }

    private func companionDeviceRow(_ device: DeckTrustedDeviceSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.surfaceHov)
                .overlay(
                    Image(systemName: companionDeviceIcon(for: device.name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.textDim)
                )
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(device.name)
                        .font(Typo.monoBold(11))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)

                    Text(device.fingerprint)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Text("Paired \(relativeTimestamp(device.pairedAt))")
                    Text("Last seen \(relativeTimestamp(device.lastSeenAt))")
                }
                .font(Typo.caption(9.5))
                .foregroundColor(Palette.textMuted.opacity(0.78))

                HStack(spacing: 6) {
                    ForEach(device.capabilities, id: \.self) { capability in
                        companionCapabilityBadge(capability)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                guard confirmRevokeTrustedDevice(device) else { return }
                LatticesCompanionSecurityCoordinator.shared.revokeTrustedDevice(id: device.id)
                companionTrustRevision += 1
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Revoke")
                        .font(Typo.monoBold(9.5))
                }
                .foregroundColor(Palette.kill.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Palette.kill.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.kill.opacity(0.22), lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help("Revoke this paired device")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shortcutsInsetPanel)
    }

    private func companionCapabilityBadge(_ capability: String) -> some View {
        Text(companionCapabilityLabel(capability))
            .font(Typo.monoBold(9))
            .foregroundColor(Palette.running.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Palette.running.opacity(0.10))
                    .overlay(Capsule().strokeBorder(Palette.running.opacity(0.18), lineWidth: 0.5))
            )
    }

    private func companionCapabilityLabel(_ capability: String) -> String {
        switch capability {
        case DeckBridgeCapability.deckRead:
            return "Deck Read"
        case DeckBridgeCapability.deckPerform:
            return "Deck Actions"
        case DeckBridgeCapability.inputTrackpad:
            return "Trackpad"
        default:
            return capability
        }
    }

    private func companionDeviceIcon(for name: String) -> String {
        name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }

    private func confirmForgetTrustedDevices() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all paired companion devices?"
        alert.informativeText = "Your iPad or iPhone will need to pair again before it can control Lattices."
        alert.addButton(withTitle: "Forget Devices")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRevokeTrustedDevice(_ device: DeckTrustedDeviceSummary) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke \(device.name)?"
        alert.informativeText = """
        This removes the paired-device trust record for \(device.name).

        Fingerprint: \(device.fingerprint)

        The device will need to pair again before it can control Lattices.
        """
        alert.addButton(withTitle: "Revoke Device")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }


    private var companionCockpitCard: some View {
        let trustedDeviceCount = companionTrustedDevices(revision: companionTrustRevision).count

        return shortcutSectionCard(
            title: "Companion Cockpit",
            eyebrow: "iPad & iPhone",
            summary: "Define the Mac-authored command deck here, then let the companion app render it. Trackpad proxy runs through the same bridge."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // The deck layout lives on its own page now.
                Button { SettingsWindowController.shared.show(section: "deck") } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Palette.text)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command Deck")
                                .font(Typo.monoBold(11))
                                .foregroundColor(Palette.text)
                            Text("Design the grid, keys, and spans the companion renders.")
                                .font(Typo.caption(10.5))
                                .foregroundColor(Palette.textMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.textDim)
                    }
                    .padding(12)
                    .background(shortcutsInsetPanel)
                }
                .buttonStyle(.plain)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trackpad Proxy")
                            .font(Typo.monoBold(11))
                            .foregroundColor(Palette.text)
                        Text("Enable remote pointer control for the iPad trackpad surface. Accessibility permission is still required on the Mac.")
                            .font(Typo.caption(10.5))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    SettingsSwitch(isOn: companionTrackpadBinding)
                        .disabled(!prefs.companionBridgeEnabled)
                        .opacity(prefs.companionBridgeEnabled ? 1 : 0.45)
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing and trust")
                            .font(Typo.monoBold(11))
                            .foregroundColor(Palette.text)
                        Text("\(trustedDeviceCount) paired \(trustedDeviceCount == 1 ? "device" : "devices"). Revoke devices and review bridge grants in Companion settings.")
                            .font(Typo.caption(10.5))
                            .foregroundColor(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        SettingsWindowController.shared.show(section: "companion")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "ipad.and.iphone")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Manage")
                                .font(Typo.monoBold(10))
                        }
                        .foregroundColor(Palette.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.surfaceHov)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.borderLit, lineWidth: 0.5))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(shortcutsInsetPanel)

                HStack(spacing: 10) {
                    Text("Changes appear in the iPad companion on the next snapshot refresh.")
                        .font(Typo.caption(10.5))
                        .foregroundColor(Palette.textMuted)

                    Spacer()

                    Button("Reset Companion Layout") {
                        cockpit.reset()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.caption(10.5))
                    .foregroundColor(Palette.textDim)
                }
            }
        }
    }

    private func companionTrustedDevices(revision: Int) -> [DeckTrustedDeviceSummary] {
        _ = revision
        return LatticesCompanionSecurityCoordinator.shared.trustedDeviceSummaries()
    }

    private func companionCockpitSlotMenu(
        pageID: String,
        index: Int,
        shortcutID: String,
        categories: [LatticesCompanionShortcutCategory]
    ) -> some View {
        let definition = LatticesCompanionCockpitCatalog.definition(for: shortcutID)
        let label = definition?.title ?? "Empty"
        let subtitle = definition?.subtitle ?? "Choose a shortcut"
        let icon = definition?.iconSystemName ?? "square.dashed"

        return Menu {
            Button("Empty Slot") {
                cockpit.updateSlot(pageID: pageID, index: index, shortcutID: "")
            }

            ForEach(categories) { category in
                let shortcuts = LatticesCompanionCockpitCatalog.shortcuts.filter {
                    $0.category == category && !$0.id.isEmpty
                }
                if !shortcuts.isEmpty {
                    Section(category.title) {
                        ForEach(shortcuts) { shortcut in
                            Button {
                                cockpit.updateSlot(
                                    pageID: pageID,
                                    index: index,
                                    shortcutID: shortcut.id
                                )
                            } label: {
                                Label(shortcut.title, systemImage: shortcut.iconSystemName)
                            }
                        }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text("Slot \(index + 1)")
                        .font(Typo.pixel(10))
                        .foregroundColor(Palette.textDim)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.textMuted)
                }

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.textDim)

                Text(label)
                    .font(Typo.monoBold(11))
                    .foregroundColor(Palette.text)
                    .lineLimit(2)

                Text(subtitle)
                    .font(Typo.caption(9.5))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

}

/// Full-page companion deck builder. Mac-owned edits persist immediately
/// and flow through the next cockpit snapshot to connected companions.
struct CompanionDeckPane: View {
    @ObservedObject var cockpit: CompanionCockpitStore = .shared

    var body: some View {
        CompanionDeckBuilderView(layout: cockpit.layout, onChange: { layout in
            cockpit.layout = layout
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
