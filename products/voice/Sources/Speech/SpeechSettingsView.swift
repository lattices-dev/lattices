import SwiftUI
import HudsonUI
import HudsonUIAudio

struct SpeechSettingsView: View {
    private let adapters = SpeechProviders.cloudAdapters()
    @ObservedObject private var catalog = SpeechVoiceCatalogStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Spoken output for agents and playback.")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .padding(.bottom, 16)

                CompanionMenuBarPreference().padding(.bottom, 16)
                playbackRow
                speechDivider
                systemRow
                if SpeechPhonon.isCompiledIn {
                    speechDivider
                    SpeechLocalEngineRow(
                        name: "Phonon",
                        caption: "Runs on the Neural Engine. Text stays on this Mac. The first use downloads the model (137 MB).",
                        provider: SpeechProviders.phonon,
                        engine: SpeechPhonon.shared,
                        catalog: catalog
                    )
                }
                speechDivider
                ForEach(Array(adapters.enumerated()), id: \.offset) { index, adapter in
                    if let key = adapter.credentialKey {
                        if index > 0 {
                            speechDivider
                        }
                        SpeechCredentialRow(
                            name: adapter.displayName,
                            credentialKey: key,
                            provider: adapter.providerID.rawValue,
                            catalog: catalog
                        )
                    }
                }
                Text("Keys stay in the macOS Keychain on this Mac. Codex and MCP clients never receive them. Saving a key does not check it with the provider.")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await catalog.refresh(provider: SpeechProviders.system)
            await catalog.refresh(provider: SpeechProviders.openai)
            if SpeechPhonon.isCompiledIn {
                await catalog.refresh(provider: SpeechProviders.phonon)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .speechCredentialsDidChange)) { note in
            let provider = note.userInfo?["provider"] as? String ?? SpeechProviders.elevenlabs
            Task { await catalog.refresh(provider: provider) }
        }
    }

    private var playbackRow: some View {
        speechPrefRow(
            "Playback",
            caption: "Reopen the playback HUD without activating a window."
        ) {
            Button("Show controls") {
                SpeechPlaybackHUD.shared.showFromMenu()
            }
            .buttonStyle(.plain)
            .font(Typo.caption(11))
            .foregroundColor(Palette.textDim)
            .accessibilityLabel("Show speech playback controls")
        }
    }

    private var systemRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            speechPrefRow(
                "System",
                caption: "macOS voices. No API key."
            ) {
                Text("Ready")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.running)
                    .accessibilityValue("Ready")
            }
            SpeechVoicePickerBlock(provider: SpeechProviders.system, canPreview: true, catalog: catalog)
        }
    }

    private var speechDivider: some View {
        HudDivider(color: HudHairline.subtle)
            .padding(.vertical, 16)
    }
}

private struct SpeechLocalEngineRow: View {
    let name: String
    let caption: String
    let provider: String
    let engine: any SpeechLocalSynthesizing
    @ObservedObject var catalog: SpeechVoiceCatalogStore
    @State private var status: SpeechLocalStatus?

    var body: some View {
        let status = status ?? engine.cachedStatus()
        VStack(alignment: .leading, spacing: 8) {
            speechPrefRow(name, caption: caption) {
                Text(status.available ? "Ready" : "Unavailable")
                    .font(Typo.caption(11))
                    .foregroundColor(status.available ? Palette.running : Palette.detach)
                    .accessibilityValue(status.available ? "Ready" : "Unavailable")
            }

            if let detail = status.detail, !status.available {
                Text(detail)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.available {
                SpeechVoicePickerBlock(provider: provider, canPreview: true, catalog: catalog)
            }
        }
        .task { await refresh() }
    }

    @MainActor
    private func refresh() async {
        status = await engine.probe()
        await catalog.refresh(provider: provider)
    }
}

private struct SpeechCredentialRow: View {
    let name: String
    let credentialKey: String
    let provider: String
    @ObservedObject var catalog: SpeechVoiceCatalogStore
    private let vault = HudVault(service: "dev.lattices.app.voice")
    @State private var draft = ""
    @State private var saved = false
    @State private var replacing = false
    @State private var keychainError = false
    @State private var message: String?
    @State private var messageIsError = false

    private var draftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            speechPrefRow(
                name,
                caption: "Cloud synthesis. Spoken text leaves this Mac."
            ) {
                if keychainError {
                    EmptyView()
                } else {
                    Text(saved ? "Saved" : "Needed")
                        .font(Typo.caption(11))
                        .foregroundColor(saved ? Palette.textDim : Palette.detach)
                }
            }
            .accessibilityValue(keychainError ? "Could not read Keychain" : (saved ? "Saved" : "Needed"))

            if keychainError {
                Button("Recheck") { refreshPresence() }
                    .buttonStyle(.plain)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
            } else if saved && !replacing {
                HStack(spacing: 14) {
                    Button("Replace") { replacing = true }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                    Button("Clear") { clear() }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                        .accessibilityHint("Removes the key from Keychain")
                    Spacer(minLength: 0)
                }
            } else {
                HudSecretField(saved ? "Replace API key" : "API key", text: $draft)
                    .accessibilityLabel("\(name) API key")
                HStack(spacing: 14) {
                    Button("Save") { save() }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(draftEmpty ? Palette.textMuted : Palette.textDim)
                        .disabled(draftEmpty)
                        .accessibilityHint("Stores the key in Keychain on this Mac")
                    if replacing {
                        Button("Cancel") {
                            replacing = false
                            draft = ""
                        }
                        .buttonStyle(.plain)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let message {
                Text(message)
                    .font(Typo.caption(11))
                    .foregroundColor(messageIsError ? Palette.kill : Palette.running)
            }

            SpeechVoicePickerBlock(
                provider: provider,
                canPreview: saved && !keychainError,
                catalog: catalog
            )
        }
        .onAppear {
            refreshPresence()
            Task { await catalog.refresh(provider: provider) }
        }
        .onDisappear { draft = "" }
    }

    private func refreshPresence() {
        do {
            saved = SpeechCredentialAvailability.isAvailable(
                credentialKey: credentialKey,
                data: try vault.get(credentialKey)
            )
            keychainError = false
            if message == "Could not read Keychain. Try reopening Settings." {
                message = nil
            }
        } catch {
            keychainError = true
            saved = false
            replacing = false
            messageIsError = true
            message = "Could not read Keychain. Try reopening Settings."
        }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try vault.set(credentialKey, Data(value.utf8))
            saved = true
            replacing = false
            draft = ""
            messageIsError = false
            message = "Saved to Keychain."
            notifyCredentialsChanged()
        } catch {
            messageIsError = true
            message = "Could not save the key to Keychain."
        }
    }

    private func clear() {
        do {
            try vault.delete(credentialKey)
            saved = false
            replacing = false
            draft = ""
            messageIsError = false
            message = "Key removed."
            notifyCredentialsChanged()
        } catch {
            messageIsError = true
            message = "Could not remove the key from Keychain."
        }
    }

    private func notifyCredentialsChanged() {
        NotificationCenter.default.post(
            name: .speechCredentialsDidChange,
            object: nil,
            userInfo: ["provider": provider]
        )
    }
}

private struct SpeechVoicePickerBlock: View {
    let provider: String
    let canPreview: Bool
    @ObservedObject var catalog: SpeechVoiceCatalogStore
    @ObservedObject private var preferences = SpeechVoicePreferences.shared
    @State private var previewError: String?
    @State private var startingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch catalog.state(for: provider) {
            case .none, .loading:
                Text("Loading voices…")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
            case .unavailable(let message):
                Text(message)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.detach)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.kill)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reload voices") {
                        Task { await catalog.refresh(provider: provider) }
                    }
                    .buttonStyle(.plain)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textDim)
                }
            case .empty(let message):
                Text(message)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let voices):
                picker(voices)
                if provider == SpeechProviders.openai {
                    Text("This build lists only the default OpenAI voice.")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if provider == SpeechProviders.elevenlabs, voices.count >= 100 {
                    Text("Showing the first 100 ElevenLabs voices.")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textMuted)
                }
                previewButton(voices: voices)
            }

            if let previewError {
                Text(previewError)
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.kill)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func picker(_ voices: [SpeechVoiceInfo]) -> some View {
        let preferred = preferences.preferredVoice(for: provider)
        let options = merged(voices, preferred: preferred)
        speechPrefRow("Voice", caption: "Used when a speech request does not name a voice.") {
            Picker("Voice", selection: selectionBinding(options: options)) {
                ForEach(options) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(Typo.caption(11))
            .tint(Palette.textDim)
            .accessibilityLabel("\(providerDisplayName) voice")
        }
    }

    private func previewButton(voices: [SpeechVoiceInfo]) -> some View {
        Button(startingPreview ? "Starting…" : "Preview voice") {
            preview(voices: voices)
        }
        .buttonStyle(.plain)
        .font(Typo.caption(11))
        .foregroundColor(canPreview && !startingPreview ? Palette.textDim : Palette.textMuted)
        .disabled(!canPreview || startingPreview || selectedVoiceID(in: voices) == nil)
        .accessibilityLabel("Preview this voice")
        .accessibilityHint("Speaks a short sample through the Voice playback HUD")
    }

    private func preview(voices: [SpeechVoiceInfo]) {
        guard let voice = selectedVoiceID(in: voices) else { return }
        startingPreview = true
        previewError = nil
        do {
            _ = try SpeechRuntime.enqueuePreview(provider: provider, voice: voice)
        } catch {
            previewError = SpeechErrorRedactor.message(from: error)
        }
        startingPreview = false
    }

    private func selectedVoiceID(in voices: [SpeechVoiceInfo]) -> String? {
        let options = merged(voices, preferred: preferences.preferredVoice(for: provider))
        let current = selectionBinding(options: options).wrappedValue
        return current.isEmpty ? nil : current
    }

    private func selectionBinding(options: [SpeechVoiceInfo]) -> Binding<String> {
        Binding(
            get: {
                let preferred = preferences.preferredVoice(for: provider)
                if let preferred, options.contains(where: { $0.id == preferred }) {
                    return preferred
                }
                return options.first(where: \.isDefault)?.id ?? options.first?.id ?? ""
            },
            set: { newValue in
                preferences.setPreferredVoice(newValue, for: provider)
                previewError = nil
            }
        )
    }

    private func merged(_ voices: [SpeechVoiceInfo], preferred: String?) -> [SpeechVoiceInfo] {
        guard let preferred, !preferred.isEmpty,
              !voices.contains(where: { $0.id == preferred })
        else { return voices }
        return [SpeechVoiceInfo(
            id: preferred,
            label: "Saved voice",
            provider: provider,
            available: true,
            isDefault: true
        )] + voices
    }

    private var providerDisplayName: String {
        switch provider {
        case SpeechProviders.system: return "System"
        case SpeechProviders.openai: return "OpenAI"
        case SpeechProviders.elevenlabs: return "ElevenLabs"
        case SpeechProviders.phonon: return "Phonon"
        default: return provider
        }
    }
}

private func speechPrefRow<Control: View>(
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
