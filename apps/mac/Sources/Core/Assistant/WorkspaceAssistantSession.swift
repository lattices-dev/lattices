import AppKit
import Combine
import Foundation
import HudsonAI
import HudsonUI

/// A prompt the user queued mid-turn. Carries a stable id so the composer's chips
/// diff cleanly and remove/edit resolve by identity (not a shifting index).
struct QueuedPrompt: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var attachments: [WorkspaceAssistantAttachment] = []
}

struct WorkspaceAssistantAttachment: Identifiable, Equatable {
    let id: UUID
    var name: String
    var mediaType: String
    var content: String
    var systemImage: String

    init(
        id: UUID = UUID(),
        name: String,
        mediaType: String = "text/plain",
        content: String,
        systemImage: String = "doc.text"
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.content = content
        self.systemImage = systemImage
    }
}

struct WorkspaceAssistantMessage: Identifiable, Equatable {
    enum Role {
        case system
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var attachments: [WorkspaceAssistantAttachment]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        attachments: [WorkspaceAssistantAttachment] = [],
        timestamp: Date
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.timestamp = timestamp
    }
}

struct AssistantProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let modelID: String
    let credentialKey: String
    let tokenLabel: String
    let tokenPlaceholder: String
    let helpText: String

    static let supported: [AssistantProvider] = [
        AssistantProvider(
            id: "openai",
            name: "OpenAI",
            modelID: "gpt-5.4",
            credentialKey: "openai_key",
            tokenLabel: "API key",
            tokenPlaceholder: "sk-...",
            helpText: "Connects directly to OpenAI through HudsonAI. The key stays in the macOS Keychain."
        ),
        AssistantProvider(
            id: "anthropic",
            name: "Anthropic",
            modelID: "claude-opus-4-7",
            credentialKey: "anthropic_key",
            tokenLabel: "API key",
            tokenPlaceholder: "sk-ant-...",
            helpText: "Connects directly to Anthropic through HudsonAI. The key stays in the macOS Keychain."
        ),
        AssistantProvider(
            id: "openrouter",
            name: "OpenRouter",
            modelID: "moonshotai/kimi-k2.6",
            credentialKey: "openrouter_key",
            tokenLabel: "API key",
            tokenPlaceholder: "sk-or-...",
            helpText: "Connects directly to OpenRouter through HudsonAI. The key stays in the macOS Keychain."
        ),
    ]

    static func provider(id: String) -> AssistantProvider {
        let migratedID = id == "openai-codex" ? "openai" : id
        return supported.first(where: { $0.id == migratedID }) ?? supported[0]
    }

    func makeAdapter() -> any HudAIProviderAdapter {
        switch id {
        case "anthropic": return HudAIProviders.Anthropic()
        case "openrouter": return HudAIProviders.OpenRouter(appTitle: "Lattices")
        default: return HudAIProviders.OpenAI()
        }
    }
}

final class WorkspaceAssistantSession: ObservableObject {
    static let shared = WorkspaceAssistantSession()
    static func makeEditorSession() -> WorkspaceAssistantSession { WorkspaceAssistantSession(editorOnly: true) }
    private let editorOnly: Bool
    @Published private(set) var editorError: String?
    @Published private(set) var editorSuggestions: [[String: String]] = []

    @Published private(set) var messages: [WorkspaceAssistantMessage] = [
        WorkspaceAssistantMessage(
            role: .system,
            text: "Scout is ready. This chat keeps one persistent Scout session; clear chat to start fresh.",
            timestamp: Date()
        )
    ]
    @Published var draft: String = ""
    @Published var isVisible: Bool = false
    @Published private(set) var isSending: Bool = false
    @Published private(set) var statusText: String = "idle"
    @Published private(set) var isScoutAvailable: Bool?
    @Published private(set) var scoutTargetLabel: String?
    /// Prompts submitted while a turn was streaming. They render as pending chips
    /// and fire FIFO once the current turn finishes (the "queue" primitive).
    @Published private(set) var queuedPrompts: [QueuedPrompt] = []
    @Published var dockHeight: CGFloat = 230 {
        didSet {
            dockHeight = Self.clampDockHeight(dockHeight)
            UserDefaults.standard.set(dockHeight, forKey: Self.dockHeightDefaultsKey)
        }
    }
    @Published var isAuthPanelVisible: Bool = false
    @Published var authProviderID: String = "openai" {
        didSet {
            guard oldValue != authProviderID else { return }
            UserDefaults.standard.set(authProviderID, forKey: Self.selectedProviderDefaultsKey)
            authToken = ""
            isEditingStoredCredential = false
            authNoticeText = nil
            authErrorText = nil
            prepareForDisplay()
        }
    }
    @Published var authToken: String = ""
    @Published var isEditingStoredCredential: Bool = false
    @Published private(set) var authNoticeText: String?
    @Published private(set) var authErrorText: String?
    @Published private(set) var storedCredentialKinds: [String: String] = [:]

    // Chat authorization belongs to Scout. Keep the optional voice provider
    // credential in a voice-specific vault so merely opening chat never touches
    // the retired `dev.lattices.app.ai` keychain item (whose legacy ACL can
    // trigger a macOS password prompt after a dev bundle identity changes).
    private let voiceVault = HudVault(service: "dev.lattices.app.voice")
    private let commandRouter = CommandModelRouter()
    @Published var commandModelPreference: String = UserDefaults.standard.string(forKey: "commandModelPreference") ?? "automatic" {
        didSet {
            UserDefaults.standard.set(commandModelPreference, forKey: "commandModelPreference")
            commandModelStatus = "Selected when the next command needs inference"
        }
    }
    @Published private(set) var commandModelStatus = "Selected when the next command needs inference"

    private let scoutTransport = ScoutAssistantTransport()
    private var scoutBindingRef: String? {
        didSet {
            if let scoutBindingRef, !scoutBindingRef.isEmpty {
                UserDefaults.standard.set(scoutBindingRef, forKey: Self.scoutBindingRefDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.scoutBindingRefDefaultsKey)
            }
        }
    }
    private var streamingMessageID: UUID?
    /// Cancelling this task terminates the active Scout ask/wait process.
    private var streamingTask: Task<Void, Never>?
    /// Monotonic turn id. Every provider callback captures the id it was started
    /// under and bails if it no longer matches, so a stopped or superseded turn
    /// can never write into a newer one (covers the non-cancellable native path).
    private var turnGeneration = 0
    // Display drain — decouples on-screen reveal from network arrival cadence so
    // chunky provider bursts flow in smoothly (and a wait-then-dump final still
    // animates in). `targetText` is everything received so far; `displayedCount`
    // is how many characters have been revealed; a 60Hz timer eases the gap shut.
    private var streamingTargetText: String = ""
    private var streamingDisplayedCount: Int = 0
    private var streamingClosing: Bool = false
    private var streamingDrainTimer: Timer?
    // Ticks to idle before revealing more — used to add a natural reading beat
    // after sentence/clause punctuation so the stream doesn't read robotically.
    private var streamingHoldTicks: Int = 0
    private static let streamingDrainInterval: TimeInterval = 1.0 / 60.0

    private static let selectedProviderDefaultsKey = "HudsonAISelectedProvider"
    private static let scoutBindingRefDefaultsKey = "ScoutWorkspaceAssistantBindingRef"
    private static let preferredHarnessDefaultsKey = "LatticesAssistantPreferredHarness"
    private static let preferredModelDefaultsKey = "LatticesAssistantPreferredModel"
    private static let preferredEffortDefaultsKey = "LatticesAssistantPreferredEffort"

    /// Last successful agent-runtime harness id (for status chrome).
    @Published private(set) var agentRuntimeHarnessLabel: String?
    /// Model the harness reported for the last successful turn.
    @Published private(set) var agentRuntimeModel: String?
    private static let voiceAppendSystemPrompt = """
        You are the Workspace Assistant for Lattices voice surfaces.
        Respond concisely. Follow the response format requested in each prompt exactly.
        """

    /// Product-knowledge brief (how Lattices works, with doc references) injected
    /// into chat/voice prompts so the assistant can explain features — not just the
    /// current settings. Loaded once from `docs/assistant-knowledge.md`; empty if
    /// the file can't be found (the prompt then omits the block).
    static let capabilitiesGuide: String = loadCapabilitiesGuide()

    private static func loadCapabilitiesGuide() -> String {
        let file = "assistant-knowledge.md"
        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let candidates: [String] = [
            // Bundled into the app (shipped builds).
            Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("docs/\(file)") },
            // Beside the .app.
            ((appDir as NSString).appendingPathComponent("../docs/\(file)") as NSString).standardizingPath,
            // Repo root (dev builds: apps/mac/Lattices.app -> repo/docs).
            ((appDir as NSString).appendingPathComponent("../../docs/\(file)") as NSString).standardizingPath,
        ].compactMap { $0 }
        for path in candidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               text.isEmpty == false {
                return text
            }
        }
        return ""
    }

    private static let dockHeightDefaultsKey = "HudsonAIChatDockHeight"

    #if LATTICES_VOICE && canImport(HudsonVoice)
    /// Drains finalized voice transcripts from the Hudson-powered mic into the composer draft.
    private var voiceInputCancellable: AnyCancellable?
    #endif

    private init(editorOnly: Bool = false) {
        self.editorOnly = editorOnly
        if editorOnly {
            // No local-command handlers, voice observers, settings/auth writes
            // or persistent Scout binding for the Editor's isolated conversation.
            messages = []
            return
        }
        scoutBindingRef = UserDefaults.standard.string(forKey: Self.scoutBindingRefDefaultsKey)
        let savedProvider = UserDefaults.standard.string(forKey: Self.selectedProviderDefaultsKey)
        if let savedProvider {
            authProviderID = AssistantProvider.provider(id: savedProvider).id
        }
        let savedDockHeight = UserDefaults.standard.double(forKey: Self.dockHeightDefaultsKey)
        if savedDockHeight > 0 {
            dockHeight = Self.clampDockHeight(savedDockHeight)
        }

        reloadAuthState()

        #if LATTICES_VOICE && canImport(HudsonVoice)
        // Splice finalized voice transcripts into the draft (one-shot, then drain),
        // mirroring OpenScout's HUDDockState lastFinalText subscription.
        voiceInputCancellable = WorkspaceVoiceInput.shared.$lastFinalText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.draft = WorkspaceDictationBuffer.appending(trimmed, to: self.draft)
                Task { @MainActor in
                    WorkspaceVoiceInput.shared.consumeFinalText()
                }
            }
        #endif
    }

    var isProviderInferenceReady: Bool {
        let preference = CommandModelPreference(rawValue: commandModelPreference) ?? .automatic
        if preference == .api { return !needsProviderSetup }
        switch preference {
        case .codex: return CommandModelRouter.executable("codex") != nil
        case .claude: return CommandModelRouter.executable("claude") != nil
        case .grok, .flash: return CommandModelRouter.executable("pi") != nil
        default: return CommandModelRouter.hasRuntime || !storedCredentialKinds.isEmpty
        }
    }

    var providerOptions: [AssistantProvider] {
        AssistantProvider.supported
    }

    var currentProvider: AssistantProvider {
        AssistantProvider.provider(id: authProviderID)
    }

    var needsProviderSetup: Bool {
        !hasSelectedCredential
    }

    /// Chat always has a path: HudsonAI when a key is saved, otherwise Scout.
    var needsChatSetup: Bool { false }

    var scoutStatusSummary: String {
        switch isScoutAvailable {
        case true:
            if let scoutTargetLabel, !scoutTargetLabel.isEmpty {
                return "Scout · \(scoutTargetLabel)"
            }
            return "Scout connected"
        case false:
            return "Scout unavailable"
        case nil:
            return "Checking Scout…"
        }
    }

    var chatTransportSummary: String {
        if let harness = agentRuntimeHarnessLabel, !harness.isEmpty {
            return "Agent runtime · \(harness)"
        }
        if hasSelectedCredential {
            return "\(currentProvider.name) · API"
        }
        return "Scout · project session"
    }

    var preferredAgentHarness: String? {
        get { UserDefaults.standard.string(forKey: Self.preferredHarnessDefaultsKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.preferredHarnessDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredHarnessDefaultsKey)
            }
            objectWillChange.send()
        }
    }

    /// The composer picker's harness / model / effort. The harness is the saved
    /// preference, else whatever answered last, else the runtime's first choice.
    /// Model and effort are saved per pick and only sent to the harness they
    /// were picked for.
    var runtimeSelection: HudRuntimeSelection {
        get {
            let defaults = UserDefaults.standard
            let harness = preferredAgentHarness
                ?? agentRuntimeHarnessLabel
                ?? AgentRuntimeTransport.defaultHarnessPreference[0]
            return HudRuntimeSelection(
                harnessId: harness,
                modelId: defaults.string(forKey: Self.preferredModelDefaultsKey) ?? "",
                effortId: defaults.string(forKey: Self.preferredEffortDefaultsKey) ?? HudRuntimeEffort.autoId
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.modelId, forKey: Self.preferredModelDefaultsKey)
            defaults.set(newValue.effortId, forKey: Self.preferredEffortDefaultsKey)
            preferredAgentHarness = newValue.harnessId
        }
    }

    var hasConversationHistory: Bool {
        messages.contains { $0.role != .system }
    }

    var copyableConversationText: String {
        messages
            .filter { $0.role != .system }
            .compactMap { message -> String? in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(Self.copyLabel(for: message.role)):\n\(text)"
            }
            .joined(separator: "\n\n")
    }

    var selectedCredentialSummary: String {
        hasSelectedCredential ? "key saved" : "not authenticated"
    }

    var hasSelectedCredential: Bool {
        storedCredentialKinds[authProviderID] != nil
    }

    var setupStatusSummary: String {
        chatTransportSummary
    }

    /// Active tool name when the runtime is mid-tool-call, else nil. Drives
    /// the in-message tool chip on the streaming assistant row.
    var activeToolName: String? {
        let prefix = "tool: "
        guard statusText.hasPrefix(prefix) else { return nil }
        let raw = String(statusText.dropFirst(prefix.count))
        return raw.isEmpty ? nil : raw
    }

    func toggleVisibility() {
        isVisible.toggle()
    }

    func toggleAuthPanel() {
        isAuthPanelVisible.toggle()
        if isAuthPanelVisible {
            dockHeight = max(dockHeight, 300)
        }
    }

    func clearConversation() {
        messages = []
        scoutBindingRef = nil
        scoutTargetLabel = nil
        prepareForDisplay()
    }

    func shutdown() {
        invalidateChatRuntime()
    }

    func prepareForDisplay() {
        reloadAuthState()
        if statusText == "setup ai" {
            statusText = "idle"
        }
        refreshScoutAvailability()
        syncStructuredWelcomeMessage()
    }

    func refreshScoutAvailability() {
        let projectPath = scoutProjectPath()
        Task { [weak self] in
            guard let self else { return }
            let available = await self.scoutTransport.checkAvailability(projectPath: projectPath)
            await MainActor.run {
                self.isScoutAvailable = available
                if !available, !self.isSending { self.statusText = "scout offline" }
                if available, self.statusText == "scout offline" { self.statusText = "idle" }
            }
        }
    }

    func refreshCredentialAvailability() {
        reloadAuthState()
    }

    func copyConversationToClipboard() {
        let text = copyableConversationText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DiagnosticLog.shared.success("WorkspaceAssistant: copied conversation to clipboard (\(text.count) chars)")
    }


    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if isSending {
            queuedPrompts.append(QueuedPrompt(text: text))   // queue while a turn is in flight
            return
        }
        send(text)
    }

    /// Editor-only entry point. Tool-free transport is an enforced capability,
    /// not a system-prompt request to an otherwise unrestricted agent.
    func send(_ text: String, editorContext: String, layerId: String) {
        guard editorOnly, !isSending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(WorkspaceAssistantMessage(role: .user, text: trimmed, timestamp: Date()))
        editorError = nil; editorSuggestions = []; isSending = true
        let history = messages.suffix(12).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let prompt = "Layer ID: \(layerId)\nRead-only context:\n\(editorContext)\nConversation:\n\(history)"
        streamingTask = Task { [weak self] in
            do {
                let raw = try await EditorAssistantTransport.complete(prompt)
                var answer = raw
                var suggestions: [[String: String]] = []
                let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                if let object = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any],
                   let text = object["text"] as? String {
                    answer = text
                    suggestions = (object["suggestions"] as? [[String: String]] ?? []).filter {
                        ["gather", "open"].contains($0["kind"] ?? "") && $0["layerId"] == layerId && !($0["label"] ?? "").isEmpty
                    }
                }
                await MainActor.run { [weak self] in
                    self?.messages.append(WorkspaceAssistantMessage(role: .assistant, text: answer, timestamp: Date()))
                    self?.editorSuggestions = suggestions
                    self?.isSending = false
                }
            } catch {
                await MainActor.run { [weak self] in self?.editorError = error.localizedDescription; self?.isSending = false }
            }
        }
    }

    func send(_ text: String) {
        send(text, attachments: [])
    }

    func send(_ text: String, attachments: [WorkspaceAssistantAttachment]) {
        guard !editorOnly else { return } // Fail closed: never route editor text to local commands or unrestricted tools.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isSending {
            queuedPrompts.append(QueuedPrompt(text: trimmed, attachments: attachments))
            return
        }

        messages.append(WorkspaceAssistantMessage(role: .user, text: trimmed, attachments: attachments, timestamp: Date()))

        if let localResponse = handleImmediateLocalCommand(trimmed) {
            appendLocalAssistantResponse(localResponse)
            return
        }

        if let localResponse = handleLocalSettingsCommand(trimmed) {
            appendLocalAssistantResponse(localResponse)
            return
        }

        isSending = true
        statusText = "thinking..."
        settleActiveStreamingMessage(interrupted: false)   // snap any prior reveal to full before a new turn
        turnGeneration &+= 1
        let turnGen = turnGeneration
        let messageID = UUID()
        // Empty body while the turn is in flight — HudAgentTurn already shows LIVE /
        // Composing. Do not leak transport brand names into the message stream.
        messages.append(WorkspaceAssistantMessage(
            id: messageID,
            role: .assistant,
            text: "",
            timestamp: Date()
        ))

        streamingMessageID = messageID
        resetStreamingDrain()

        // Transport preference:
        // 1) local agent-runtime / ACP harness (no Lattices API key)
        // 2) HudsonAI direct when a key is saved
        // 3) Scout project session fallback
        let system = chatInstructions()
        let turnContext = chatTurnContext(attachments: attachments)
        let projectPath = scoutProjectPath()
        let preferredHarness = UserDefaults.standard.string(forKey: Self.preferredHarnessDefaultsKey)
        let selection = runtimeSelection
        let launch = MainActor.assumeIsolated {
            AgentRuntimeLaunch(
                harness: selection.harnessId,
                model: AssistantRuntimeCatalog.shared.launchModel(for: selection),
                effort: AssistantRuntimeCatalog.shared.launchEffort(for: selection)
            )
        }
        let canUseAPI = hasSelectedCredential
        let providerName = currentProvider.name
        streamingTask = Task { [weak self] in
            guard let self else { return }
            let runtime = AgentRuntimeTransport.shared
            if await runtime.isAvailable() {
                let timer = DiagnosticLog.shared.startTimed("Chat inference via agent-runtime")
                await self.sendViaAgentRuntime(
                    userText: trimmed,
                    systemPrompt: system,
                    turnContext: turnContext,
                    cwd: projectPath,
                    preferredHarness: preferredHarness,
                    launch: launch,
                    messageID: messageID,
                    generation: turnGen,
                    inferenceTimer: timer,
                    canUseAPI: canUseAPI,
                    providerName: providerName,
                    attachments: attachments
                )
                return
            }
            if canUseAPI {
                let timer = DiagnosticLog.shared.startTimed(
                    "Chat inference via HudsonAI · \(providerName)"
                )
                await MainActor.run {
                    self.sendViaDirectProvider(
                        userText: trimmed,
                        attachments: attachments,
                        messageID: messageID,
                        generation: turnGen,
                        inferenceTimer: timer
                    )
                }
                return
            }
            let prompt = await MainActor.run {
                self.scoutPrompt(for: trimmed, attachments: attachments)
            }
            let timer = DiagnosticLog.shared.startTimed("Chat inference via Scout")
            await MainActor.run {
                self.sendViaScout(
                    prompt: prompt,
                    projectPath: projectPath,
                    messageID: messageID,
                    generation: turnGen,
                    inferenceTimer: timer
                )
            }
        }
    }

    /// Local harness path (claude / codex / pi / opencode / ACP adapters via agent-runner).
    private func sendViaAgentRuntime(
        userText: String,
        systemPrompt: String,
        turnContext: String,
        cwd: String,
        preferredHarness: String?,
        launch: AgentRuntimeLaunch,
        messageID: UUID,
        generation: Int,
        inferenceTimer: DiagnosticLog.TimedAction,
        canUseAPI: Bool,
        providerName: String,
        attachments: [WorkspaceAssistantAttachment]
    ) async {
        do {
            let reply = try await AgentRuntimeTransport.shared.ask(
                text: userText,
                systemPrompt: systemPrompt,
                turnContext: turnContext,
                cwd: cwd,
                preferredHarness: preferredHarness,
                launch: launch,
                onDelta: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.turnGeneration == generation else { return }
                        self.statusText = "streaming..."
                        self.commitStreamingText(snapshot)
                    }
                },
                onTool: { [weak self] name in
                    Task { @MainActor in
                        guard let self, self.turnGeneration == generation else { return }
                        self.statusText = "tool: \(name)"
                    }
                }
            )
            await MainActor.run { [weak self] in
                guard let self, self.turnGeneration == generation else { return }
                self.streamingTask = nil
                self.isSending = false
                self.statusText = "idle"
                self.agentRuntimeHarnessLabel = reply.harness
                if let model = reply.model { self.agentRuntimeModel = model }
                DiagnosticLog.shared.finish(inferenceTimer)
                DiagnosticLog.shared.info("Assistant · agent-runtime \(reply.harness) completed")
                self.commitStreamingText(reply.text)
                self.finalizeStreaming(finalText: reply.text)
                self.drainQueuedPrompt()
            }
        } catch is CancellationError {
            DiagnosticLog.shared.info("Assistant · agent-runtime cancelled")
            await MainActor.run { [weak self] in
                guard let self, self.turnGeneration == generation else { return }
                self.streamingTask = nil
                if self.isSending {
                    self.isSending = false
                    self.statusText = "idle"
                    self.settleActiveStreamingMessage(interrupted: true)
                }
            }
        } catch {
            let detail = error.localizedDescription
            DiagnosticLog.shared.fail(inferenceTimer, message: detail)
            DiagnosticLog.shared.info("Assistant · agent-runtime failed (\(detail)) — falling back")
            await MainActor.run { [weak self] in
                guard let self, self.turnGeneration == generation else { return }
                self.statusText = canUseAPI
                    ? "agent runtime failed · trying API…"
                    : "agent runtime failed · trying Scout…"
            }
            if canUseAPI {
                let timer = DiagnosticLog.shared.startTimed(
                    "Chat inference via HudsonAI · \(providerName)"
                )
                await MainActor.run {
                    self.streamingTask = nil
                    self.sendViaDirectProvider(
                        userText: userText,
                        attachments: attachments,
                        messageID: messageID,
                        generation: generation,
                        inferenceTimer: timer
                    )
                }
            } else {
                let prompt = await MainActor.run {
                    self.scoutPrompt(for: userText, attachments: attachments)
                }
                let timer = DiagnosticLog.shared.startTimed("Chat inference via Scout")
                await MainActor.run {
                    self.streamingTask = nil
                    self.sendViaScout(
                        prompt: prompt,
                        projectPath: cwd,
                        messageID: messageID,
                        generation: generation,
                        inferenceTimer: timer
                    )
                }
            }
        }
    }

    /// Scout path kept as fallback when no in-app provider key is saved.
    private func sendViaScout(
        prompt: String,
        projectPath: String,
        messageID: UUID,
        generation: Int,
        inferenceTimer: DiagnosticLog.TimedAction
    ) {
        let continuingRef = scoutBindingRef
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.askWithOfflineRetry(
                    prompt: prompt,
                    projectPath: projectPath,
                    bindingRef: continuingRef
                )
                await MainActor.run { [weak self] in
                    guard let self, self.turnGeneration == generation else { return }
                    self.streamingTask = nil
                    self.isSending = false
                    self.statusText = "idle"
                    self.isScoutAvailable = true
                    self.scoutBindingRef = reply.bindingRef
                    self.scoutTargetLabel = reply.targetLabel
                    DiagnosticLog.shared.finish(inferenceTimer)
                    let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        self.failAssistantMessage(id: messageID, detail: "Empty reply.")
                    } else {
                        self.commitStreamingText(text)
                        self.finalizeStreaming(finalText: text)
                    }
                    self.drainQueuedPrompt()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.turnGeneration == generation else { return }
                    self.streamingTask = nil
                    self.isSending = false
                    let detail = error.localizedDescription
                    DiagnosticLog.shared.fail(inferenceTimer, message: detail)
                    self.failAssistantMessage(id: messageID, detail: detail)
                    if Self.shouldRetryScoutWithoutBinding(error) {
                        self.scoutBindingRef = nil
                        self.scoutTargetLabel = nil
                        self.statusText = "idle"
                        self.isScoutAvailable = true
                    } else {
                        self.statusText = "scout offline"
                        self.isScoutAvailable = false
                    }
                    self.drainQueuedPrompt()
                }
            }
        }
    }

    private func askWithOfflineRetry(
        prompt: String,
        projectPath: String,
        bindingRef: String?
    ) async throws -> ScoutAssistantReply {
        do {
            return try await scoutTransport.ask(
                prompt: prompt,
                projectPath: projectPath,
                bindingRef: bindingRef
            )
        } catch {
            // Offline-queued targets *and* dead binding refs share the same recovery:
            // drop the saved ref and re-ask via project routing once.
            guard Self.shouldRetryScoutWithoutBinding(error),
                  let bindingRef,
                  !bindingRef.isEmpty else { throw error }

            let reason = ScoutAssistantTransport.isUnroutableBindingError(error)
                ? "saved Scout ref is no longer routable"
                : "bound session offline"
            await MainActor.run {
                self.scoutBindingRef = nil
                self.scoutTargetLabel = nil
                DiagnosticLog.shared.info(
                    "Assistant · \(reason) — retrying project route \(projectPath)"
                )
            }
            return try await scoutTransport.ask(
                prompt: prompt,
                projectPath: projectPath,
                bindingRef: nil
            )
        }
    }

    private static func shouldRetryScoutWithoutBinding(_ error: Error) -> Bool {
        if ScoutAssistantTransport.isUnroutableBindingError(error) { return true }
        if let scoutError = error as? ScoutAssistantTransportError {
            return scoutError.shouldClearBinding
        }
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("offline session")
            || text.localizedCaseInsensitiveContains("when online")
    }

    /// Direct chat path: HudsonAI provider stream (same credential vault as voice).
    /// Skips Scout broker / offline session parking for ordinary assistant turns.
    private func sendViaDirectProvider(
        userText: String,
        attachments: [WorkspaceAssistantAttachment],
        messageID: UUID,
        generation: Int,
        inferenceTimer: DiagnosticLog.TimedAction
    ) {
        let provider = currentProvider
        let system = chatSystemPrompt(attachments: attachments)
        let history = chatHistoryMessages(excludingAssistantID: messageID)
        let request = HudAIRequest(
            model: provider.modelID,
            messages: history + [.user(userText)],
            system: system
        )
        let client = HudAIClient(
            provider: provider.makeAdapter(),
            model: provider.modelID,
            hudVault: voiceVault,
            defaults: HudAIDefaults(maxOutputTokens: 4_096, timeout: 120),
            routeDefault: .local
        )

        streamingTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                for try await event in client.stream(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(_, let text):
                        accumulated += text
                        let snapshot = accumulated
                        await MainActor.run { [weak self] in
                            guard let self, self.turnGeneration == generation else { return }
                            self.statusText = "streaming..."
                            self.commitStreamingText(snapshot)
                        }
                    case .toolCallStarted(_, let name):
                        await MainActor.run { [weak self] in
                            guard let self, self.turnGeneration == generation else { return }
                            self.statusText = "tool: \(name)"
                        }
                    case .completed(let response):
                        if accumulated.isEmpty {
                            accumulated = response.text
                        }
                    case .failed(let error):
                        throw error
                    case .cancelled:
                        throw CancellationError()
                    case .started, .reasoningDelta, .toolCallInputDelta, .toolCallReady,
                         .toolResultAccepted, .usage:
                        break
                    }
                }

                let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { [weak self] in
                    guard let self, self.turnGeneration == generation else { return }
                    self.streamingTask = nil
                    self.isSending = false
                    self.statusText = "idle"
                    DiagnosticLog.shared.finish(inferenceTimer)
                    if finalText.isEmpty {
                        self.failAssistantMessage(
                            id: messageID,
                            detail: "The model returned an empty reply."
                        )
                    } else {
                        self.commitStreamingText(finalText)
                        self.finalizeStreaming(finalText: finalText)
                    }
                    self.drainQueuedPrompt()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.turnGeneration == generation else { return }
                    self.streamingTask = nil
                    // stop() already settled the UI; only clean up if still marked sending.
                    if self.isSending {
                        self.isSending = false
                        self.statusText = "idle"
                        self.settleActiveStreamingMessage(interrupted: true)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.turnGeneration == generation else { return }
                    self.streamingTask = nil
                    self.isSending = false
                    let detail = error.localizedDescription
                    DiagnosticLog.shared.fail(inferenceTimer, message: detail)
                    self.failAssistantMessage(id: messageID, detail: detail)
                    if Self.isAuthFailure(detail) {
                        self.statusText = "setup ai"
                        self.authErrorText = detail
                        self.isAuthPanelVisible = true
                    } else {
                        self.statusText = "idle"
                    }
                    self.drainQueuedPrompt()
                }
            }
        }
    }

    /// Prior turns for multi-turn chat (excludes the empty streaming placeholder).
    private func chatHistoryMessages(excludingAssistantID: UUID) -> [HudAIMessage] {
        messages.compactMap { message -> HudAIMessage? in
            if message.id == excludingAssistantID { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return .user(text)
            case .assistant:
                // Skip prior error cards — they pollute the model context.
                if text.hasPrefix("**Assistant error**") { return nil }
                return .assistant(text)
            case .system:
                return nil
            }
        }
    }

    /// Full single-shot prompt for transports that take a fresh system prompt per
    /// request (HudsonAI direct): instructions plus the live state.
    private func chatSystemPrompt(attachments: [WorkspaceAssistantAttachment] = []) -> String {
        """
        \(chatInstructions())

        \(chatTurnContext(attachments: attachments))
        """
    }

    /// Stable instructions for a chat session. Holds no live state, so it stays
    /// valid for the whole session; the state rides with each turn instead.
    private func chatInstructions() -> String {
        let knowledge = Self.capabilitiesGuide
        let knowledgeBlock = knowledge.isEmpty ? "" : """

            Lattices product knowledge (how the app works; cite the linked docs when a question goes deeper):
            \(knowledge)
            """
        return """
        You are the Workspace Assistant, the in-app assistant for Lattices.

        Each turn may carry a <lattices_state> block: a JSON snapshot of this user's live Lattices configuration, taken by the app at the moment the message was sent. It is ground truth and supersedes any earlier snapshot. Answer questions about settings, mouse gestures, layers, OCR, terminals and the assistant runtime straight from it. Do not search the working directory, dotfiles or macOS system preferences for Lattices settings; the working directory is just a project the user has open and does not hold Lattices config.

        If the snapshot lacks a detail you need, read it from the running app with `lattices call <method>` (for example `lattices call mouse.shortcuts.get` for the full gesture rules, `lattices call api.schema` to list methods), or read the file named under settingsFiles. Use the product knowledge to explain how Lattices works and point to the right feature or doc. Answer naturally and concretely: say what is configured, in the user's terms (button, gesture, resulting action), and what the choices mean.

        For setting changes, say what should change and the exact next step if you cannot apply it yourself. Never claim a setting or file changed unless you know it did.
        \(knowledgeBlock)
        """
    }

    /// Live state for one turn: the structured settings snapshot plus any attachments.
    private func chatTurnContext(attachments: [WorkspaceAssistantAttachment] = []) -> String {
        let attachmentBlock = attachments.isEmpty ? "" : """


            Attached files:
            \(assistantAttachmentBlock(attachments))
            """
        return """
        <lattices_state>
        \(assistantKnowledgeBrief())
        </lattices_state>\(attachmentBlock)
        """
    }

    private static func isAuthFailure(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("unauthorized")
            || lower.contains("invalid api key")
            || lower.contains("authentication")
            || lower.contains("401")
            || lower.contains("missing api key")
            || lower.contains("no credential")
    }

    func askVoiceAdvisor(transcript: String, matched: String, callback: @escaping (AgentResponse?) -> Void) {
        runVoiceInference(
            prompt: voiceAdvisorPrompt(transcript: transcript, matched: matched),
            label: "voice advisor"
        ) { output in
            guard let output, !output.isEmpty else {
                callback(nil)
                return
            }
            callback(AgentResponse.parse(text: output))
        }
    }

    func answerVoiceQuestion(_ transcript: String, callback: @escaping (AgentResponse?) -> Void) {
        runVoiceInference(
            prompt: voiceQuestionPrompt(transcript: transcript),
            label: "voice question"
        ) { output in
            guard let output, !output.isEmpty else {
                callback(nil)
                return
            }
            callback(AgentResponse(commentary: output, suggestion: nil, raw: output))
        }
    }

    func resolveVoiceIntent(transcript: String, callback: @escaping (ResolvedIntent?) -> Void) {
        runVoiceInference(
            prompt: voiceResolverPrompt(transcript: transcript),
            label: "voice resolver"
        ) { output in
            callback(Self.parseResolvedIntent(from: output))
        }
    }

    /// Second-chance AI pass: an intent the model produced failed validation/execution.
    /// Hand the model the exact failure plus the full catalog vocabulary and ask it to
    /// return a corrected intent constrained to valid values. Best-effort — calls back nil
    /// if the model can't fix it, so the caller can surface the original error.
    func repairVoiceIntent(
        transcript: String,
        failedIntent: String,
        failedSlots: [String: JSON],
        error: String,
        callback: @escaping (ResolvedIntent?) -> Void
    ) {
        runVoiceInference(
            prompt: voiceRepairPrompt(transcript: transcript, failedIntent: failedIntent, failedSlots: failedSlots, error: error),
            label: "voice repair"
        ) { output in
            callback(Self.parseResolvedIntent(from: output))
        }
    }

    /// Parse a resolver/repair model response into a ResolvedIntent. Returns nil for
    /// missing/`unknown` intents so the caller treats it as "couldn't resolve".
    private static func parseResolvedIntent(from output: String?) -> ResolvedIntent? {
        guard let output,
              let jsonStr = Self.extractJSON(from: output),
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intent = json["intent"] as? String,
              intent != "unknown" else {
            return nil
        }

        var slots: [String: JSON] = [:]
        if let rawSlots = json["slots"] as? [String: Any] {
            for (key, value) in rawSlots {
                if let value = value as? String {
                    slots[key] = .string(value)
                } else if let value = value as? Int {
                    slots[key] = .int(value)
                } else if let value = value as? Bool {
                    slots[key] = .bool(value)
                }
            }
        }
        return ResolvedIntent(intent: intent, slots: slots)
    }

    private func runVoiceInference(
        prompt: String,
        label: String,
        callback: @escaping (String?) -> Void
    ) {
        let preference = CommandModelPreference(rawValue: commandModelPreference) ?? .automatic
        let credentials = storedCredentialKinds
        let explicitProvider = currentProvider
        let prompt = Self.voiceAppendSystemPrompt + "\n\n" + prompt
        let providers = preference == .api ? [explicitProvider] : AssistantProvider.supported
        let available = providers.filter { credentials[$0.id] != nil }
        Task {
            do {
                let (text, route) = try await commandRouter.complete(prompt: prompt, preference: preference,
                    apiProviders: available.map(\.id)) { providerID, model, timeout in
                    let provider = AssistantProvider.provider(id: providerID)
                    let client = HudAIClient(provider: provider.makeAdapter(), model: model, hudVault: self.voiceVault,
                        defaults: HudAIDefaults(maxOutputTokens: 1_024, timeout: timeout), routeDefault: .local)
                    return try await client.complete(HudAIRequest(model: model, messages: [.user(prompt)])).text
                }
                DispatchQueue.main.async {
                    self.commandModelStatus = route
                    callback(text)
                }
            } catch {
                DiagnosticLog.shared.warn("Command inference[\(label)] unavailable")
                DispatchQueue.main.async {
                    self.commandModelStatus = error.localizedDescription
                    callback(nil)
                }
            }
        }
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    /// Record the latest accumulated snapshot as the drain target. The reveal
    /// itself happens on the drain timer, not here — so a chunky burst doesn't
    /// snap onto the screen all at once.
    private func commitStreamingText(_ text: String) {
        streamingTargetText = text
        startStreamingDrainIfNeeded()
    }

    private func resetStreamingDrain() {
        streamingDrainTimer?.invalidate()
        streamingDrainTimer = nil
        streamingTargetText = ""
        streamingDisplayedCount = 0
        streamingClosing = false
        streamingHoldTicks = 0
    }

    private func startStreamingDrainIfNeeded() {
        guard streamingDrainTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.streamingDrainInterval, repeats: true) { [weak self] _ in
            self?.tickStreamingDrain()
        }
        // .common so the drain keeps ticking during scroll/tracking runloops.
        RunLoop.main.add(timer, forMode: .common)
        streamingDrainTimer = timer
    }

    /// One reveal step: ease the displayed length toward the target, snapping to
    /// a word boundary so words land whole. Faster while closing so the message
    /// settles promptly once the network is done.
    private func tickStreamingDrain() {
        guard let id = streamingMessageID else {
            streamingDrainTimer?.invalidate()
            streamingDrainTimer = nil
            return
        }

        // Honor a pending reading beat (skip this tick) before revealing more.
        if streamingHoldTicks > 0 {
            streamingHoldTicks -= 1
            return
        }

        let target = streamingTargetText
        let targetCount = target.count

        if streamingDisplayedCount >= targetCount {
            if streamingClosing {
                updateAssistantMessage(id: id, text: target)
                streamingDrainTimer?.invalidate()
                streamingDrainTimer = nil
                streamingMessageID = nil
            }
            return
        }

        let gap = targetCount - streamingDisplayedCount
        let fraction = streamingClosing ? 0.45 : 0.22
        let minStep = streamingClosing ? 6 : 2
        var step = max(minStep, Int((Double(gap) * fraction).rounded()))
        step = min(step, gap)
        let proposed = streamingDisplayedCount + step
        streamingDisplayedCount = snapToWordBoundary(in: target, proposed: proposed)
        updateAssistantMessage(id: id, text: String(target.prefix(streamingDisplayedCount)))

        // After landing on a word boundary, add a reading beat if we just
        // finished a sentence or clause — but never while racing to settle, and
        // never if there's a huge backlog to catch up on.
        if !streamingClosing, gap < 240 {
            streamingHoldTicks = readingBeat(in: target, revealedCount: streamingDisplayedCount)
        }
    }

    /// Pause length (in 60Hz ticks) after the most recently revealed token:
    /// a longer beat after sentence enders, a shorter one after clause marks.
    private func readingBeat(in text: String, revealedCount: Int) -> Int {
        let chars = Array(text)
        // The boundary lands just past a space, so the sentence punctuation is a
        // couple of characters back. Scan the last few non-space chars.
        var idx = revealedCount - 1
        var skippedSpace = false
        while idx >= 0, idx >= revealedCount - 3 {
            let c = chars[idx]
            if c == " " || c == "\n" { skippedSpace = true; idx -= 1; continue }
            guard skippedSpace || idx == revealedCount - 1 else { break }
            switch c {
            case ".", "!", "?":  return 10   // ~165ms — end of sentence
            case ",", ";", ":":  return 5    // ~80ms  — clause break
            default:             return 0
            }
        }
        return 0
    }

    /// Extend `proposed` forward to just past the next space/newline (within a
    /// small window) so the reveal doesn't stop mid-token.
    private func snapToWordBoundary(in text: String, proposed: Int) -> Int {
        let chars = Array(text)
        guard proposed < chars.count else { return chars.count }
        var i = proposed
        let limit = min(chars.count, proposed + 16)
        while i < limit {
            if chars[i] == " " || chars[i] == "\n" { return i + 1 }
            i += 1
        }
        return proposed
    }

    private func cancelPendingStreamingFlush() {
        resetStreamingDrain()
    }

    /// Hand the drain the final text and let it finish revealing. The drain
    /// settles the message exactly and clears `streamingMessageID` once caught up.
    private func finalizeStreaming(finalText: String) {
        streamingTargetText = finalText
        streamingClosing = true
        startStreamingDrainIfNeeded()
    }

    /// Snap the active streaming message to everything received so far and stop the
    /// drain — used before a new turn starts and when a turn is stopped. When
    /// `interrupted`, tag the partial so it reads as deliberately cut off.
    private func settleActiveStreamingMessage(interrupted: Bool) {
        guard let id = streamingMessageID else { return }
        let full = streamingTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        resetStreamingDrain()
        streamingMessageID = nil
        if full.isEmpty {
            removeMessageIfEmpty(id: id)
        } else if interrupted {
            updateAssistantMessage(id: id, text: full + "\n\n— stopped —")
        } else {
            updateAssistantMessage(id: id, text: full)
        }
    }

    /// Fire the next queued prompt once the turn is idle (FIFO drain).
    private func drainQueuedPrompt() {
        guard !isSending, !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        send(next.text, attachments: next.attachments)
    }

    /// Halt the in-flight Scout turn; the generation guard neutralizes any stale
    /// completion that races with process cancellation, then settles
    /// the partial answer. `drainQueue` fires the next queued prompt afterward —
    /// true for a plain stop, false when the caller is about to send a steer.
    private func stop(drainQueue: Bool) {
        turnGeneration &+= 1
        scoutTransport.cancelCurrentTurn()
        AgentRuntimeTransport.shared.interrupt()
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        statusText = "idle"
        settleActiveStreamingMessage(interrupted: true)
        if drainQueue { drainQueuedPrompt() }
    }

    /// Stop button. Halts the in-flight turn without sending anything; any queued
    /// prompts still continue.
    func stop() {
        guard isSending else { return }
        stop(drainQueue: true)
    }

    /// Stop the in-flight turn and, if the composer has text, send it immediately
    /// as a redirect (steer). Empty draft falls back to a plain stop.
    func interruptAndSteer() {
        guard isSending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        stop(drainQueue: text.isEmpty)   // don't drain when we're about to steer
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    /// Remove a still-pending queued prompt (tapping its chip's ✕ before it fires).
    func removeQueuedPrompt(id: UUID) {
        queuedPrompts.removeAll { $0.id == id }
    }

    /// Pull a queued prompt back into the composer to edit it: splice its text into
    /// the draft and drop it from the queue.
    func editQueuedPrompt(id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        let removed = queuedPrompts.remove(at: index)
        draft = WorkspaceDictationBuffer.appending(removed.text, to: draft)
    }

    private func removeMessageIfEmpty(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }
    }

    private func failAssistantMessage(id: UUID, detail: String) {
        let partial = streamingTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = messages.first(where: { $0.id == id })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = partial.isEmpty ? existing : partial
        let failure = Self.formattedInferenceFailure(detail)

        resetStreamingDrain()
        streamingMessageID = nil

        if prefix.isEmpty {
            updateAssistantMessage(id: id, text: failure)
        } else {
            updateAssistantMessage(id: id, text: "\(prefix)\n\n\(failure)")
        }
    }

    private static func formattedInferenceFailure(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "The assistant failed without returning an error message." : trimmed
        return """
        **Assistant error**

        The assistant turn failed before it could finish.

        ```text
        \(body)
        ```
        """
    }

    private func handleInferenceFailure(_ message: String, appendSystemMessage shouldAppendSystemMessage: Bool = true) {
        if let friendly = friendlyAuthFailureMessage(for: message) {
            statusText = "setup ai"
            authErrorText = friendly
            isAuthPanelVisible = true
            syncStructuredWelcomeMessage()
            invalidateChatRuntime()
            return
        }
        statusText = "error"
        if shouldAppendSystemMessage {
            appendSystemMessage(message)
        }
        if Self.looksLikeAuthError(message) {
            isAuthPanelVisible = true
            invalidateChatRuntime()
        }
    }

    func saveSelectedToken() {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            authErrorText = "Enter a token before saving."
            return
        }

        do {
            try voiceVault.setString(currentProvider.credentialKey, token)
            authToken = ""
            isEditingStoredCredential = false
            authNoticeText = "Saved \(currentProvider.tokenLabel.lowercased()) for \(currentProvider.name)."
            authErrorText = nil
            reloadAuthState()
            appendSystemMessage("Saved \(currentProvider.name) credentials.")
            isAuthPanelVisible = false
            prepareForDisplay()
        } catch {
            authErrorText = "Failed to save token: \(error.localizedDescription)"
        }
    }

    func removeSelectedCredential() {
        do {
            try voiceVault.delete(currentProvider.credentialKey)
            authNoticeText = "Removed saved credentials for \(currentProvider.name)."
            authErrorText = nil
            isEditingStoredCredential = true
            reloadAuthState()
            appendSystemMessage("Removed saved \(currentProvider.name) credentials.")
            prepareForDisplay()
        } catch {
            authErrorText = "Failed to remove credentials: \(error.localizedDescription)"
        }
    }

    private func invalidateChatRuntime() {
        scoutTransport.cancelCurrentTurn()
        AgentRuntimeTransport.shared.interrupt()
        streamingTask?.cancel()
        streamingTask = nil
    }

    func beginReplacingSelectedCredential() {
        authToken = ""
        authErrorText = nil
        authNoticeText = nil
        isEditingStoredCredential = true
    }

    func cancelReplacingSelectedCredential() {
        authToken = ""
        authErrorText = nil
        isEditingStoredCredential = false
    }

    private static func copyLabel(for role: WorkspaceAssistantMessage.Role) -> String {
        switch role {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        }
    }

    private func appendSystemMessage(_ text: String) {
        messages.append(WorkspaceAssistantMessage(role: .system, text: text, timestamp: Date()))
    }

    private func appendLocalAssistantResponse(_ text: String) {
        messages.append(WorkspaceAssistantMessage(role: .assistant, text: text, timestamp: Date()))
        statusText = "idle"
    }

    private func syncStructuredWelcomeMessage() {
        guard !hasConversationHistory else { return }
        messages = [
            WorkspaceAssistantMessage(
                role: .system,
                text: structuredWelcomeMessage(),
                timestamp: Date()
            )
        ]
    }

    private func structuredWelcomeMessage() -> String {
        return """
        Welcome to the Workspace Assistant.

        Chat prefers a local agent runtime (Claude Code, Codex, Pi, OpenCode — ACP under the covers when the harness uses it). Falls back to a saved API key or Scout if no local runtime is ready.
        """
    }

    private func handleLocalSettingsCommand(_ text: String) -> String? {
        let lower = text.lowercased()
        let prefs = Preferences.shared

        if let immediate = handleImmediateLocalCommand(text) {
            return immediate
        }

        if lower.contains("help") && lower.contains("settings") {
            return settingsHelpText()
        }

        if lower.contains("settings") && isInformationalSettingsQuery(lower) {
            return settingsSummary()
        }

        if lower.contains("status") || lower.contains("current settings") {
            return settingsSummary()
        }

        if lower.contains("advisor") || lower.contains("voice advisor") {
            return nil
        }

        if lower.contains("scan root") || lower.contains("project root") || lower.contains("project scan") {
            if let root = extractPathValue(from: text) {
                prefs.scanRoot = root
                ProjectScanner.shared.updateRoot(root)
                ProjectScanner.shared.scan()
                return "Set project scan root to \(root) and started a rescan."
            }
            return nil
        }

        if lower.contains("terminal"), isSettingsMutationIntent(lower) {
            if let terminal = parseTerminal(from: lower) {
                guard terminal.isInstalled else {
                    return "\(terminal.rawValue) is not installed, so I left the terminal set to \(prefs.terminal.rawValue)."
                }
                prefs.terminal = terminal
                return "Set terminal to \(terminal.rawValue)."
            }
            return nil
        }

        if isSettingsMutationIntent(lower),
           lower.contains("detach mode") || lower.contains("interaction mode") || lower.contains("learning mode") || lower.contains("auto mode") {
            if lower.contains("auto") {
                prefs.mode = .auto
                return "Set detach mode to Auto."
            }
            if lower.contains("learning") {
                prefs.mode = .learning
                return "Set detach mode to Learning."
            }
            return nil
        }

        if lower.contains("drag") && lower.contains("snap"), isSettingsMutationIntent(lower) {
            if let enabled = parseBooleanMutation(from: lower) {
                prefs.dragSnapEnabled = enabled
                return "\(enabled ? "Enabled" : "Disabled") drag-to-snap."
            }
            return nil
        }

        if lower.contains("mouse") && (lower.contains("gesture") || lower.contains("shortcut")), isSettingsMutationIntent(lower) {
            if isMouseShortcutRuleRequest(lower) {
                return nil
            }
            if let enabled = parseBooleanMutation(from: lower) {
                prefs.mouseGesturesEnabled = enabled
                return "\(enabled ? "Enabled" : "Disabled") mouse gestures."
            }
            return nil
        }

        if lower.contains("companion") && lower.contains("bridge"), isSettingsMutationIntent(lower) {
            if let enabled = parseBooleanMutation(from: lower) {
                prefs.companionBridgeEnabled = enabled
                return "\(enabled ? "Enabled" : "Disabled") the companion bridge."
            }
            return nil
        }

        if lower.contains("companion") && lower.contains("trackpad"), isSettingsMutationIntent(lower) {
            if let enabled = parseBooleanMutation(from: lower) {
                prefs.companionTrackpadEnabled = enabled
                return "\(enabled ? "Enabled" : "Disabled") companion trackpad."
            }
            return nil
        }

        if lower.contains("ocr") || lower.contains("screen text") || lower.contains("text recognition") {
            if lower.contains("accuracy") {
                if lower.contains("fast") {
                    prefs.ocrAccuracy = "fast"
                    return "Set OCR accuracy to Fast."
                }
                if lower.contains("accurate") {
                    prefs.ocrAccuracy = "accurate"
                    return "Set OCR accuracy to Accurate."
                }
                return nil
            }

            if isSettingsMutationIntent(lower), let enabled = parseBooleanMutation(from: lower) {
                ScreenText.shared.setEnabled(enabled)
                return "\(enabled ? "Enabled" : "Disabled") screen text recognition."
            }
            return nil
        }

        return nil
    }

    private func handleImmediateLocalCommand(_ text: String) -> String? {
        let lower = text.lowercased()

        // Window actions are resolved locally so "these" means the windows the
        // user has just plucked in Hyperspace. No provider round-trip is needed.
        let liveTabs = LiveTabGroupStore.shared
        let createTabPhrases = [
            "stack these as tabs", "make these tabs", "group these as tabs",
            "turn these into tabs", "add these up",
        ]
        if createTabPhrases.contains(where: lower.contains) {
            guard liveTabs.candidateWindowIDs.count >= 2 else {
                return "Select at least two windows in Hyperspace first, then say “stack these as tabs.”"
            }
            let requestedName = liveTabGroupName(from: text)
            guard let group = liveTabs.createFromCandidate(name: requestedName) else {
                return "I couldn’t turn that selection into tabs because fewer than two selected windows are still available."
            }
            return "Stacked \(group.members.count) windows as “\(group.name)” in the top-left. Use the grid button to fan them out."
        }

        if lower.contains("add these to tabs") || lower.contains("add these to the tab group") {
            guard liveTabs.activeGroup != nil else { return "Create a live tab group first." }
            let count = liveTabs.addCandidate()
            return count > 0
                ? "Added \(count) window\(count == 1 ? "" : "s") to the active tab group."
                : "Those windows are already in the active tab group, or are no longer available."
        }

        if lower.contains("grid these tabs") || lower.contains("fan out these tabs") || lower.contains("expand these tabs") {
            guard liveTabs.activeGroup != nil else { return "There isn’t an active live tab group yet." }
            liveTabs.expand()
            return "Expanded the active tabs into a grid."
        }

        if lower.contains("collapse these tabs") || lower.contains("stack these tabs") || lower.contains("restack these tabs") {
            guard liveTabs.activeGroup != nil else { return "There isn’t an active live tab group yet." }
            liveTabs.collapse()
            return "Collapsed the active group back into tabs."
        }

        if lower.contains("open assistant settings") || lower.contains("show assistant settings") {
            SettingsWindowController.shared.showAssistant()
            return "Opened Assistant settings."
        }

        if lower.contains("open settings") || lower.contains("show settings") {
            SettingsWindowController.shared.show()
            return "Opened Settings."
        }

        return nil
    }

    private func liveTabGroupName(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in [" called ", " named "] {
            guard let range = lower.range(of: marker) else { continue }
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let start = text.index(text.startIndex, offsetBy: offset)
            let name = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'"))
            if !name.isEmpty { return name }
        }
        return nil
    }

    private func scoutPrompt(for userText: String, attachments: [WorkspaceAssistantAttachment] = []) -> String {
        let knowledge = Self.capabilitiesGuide
        let knowledgeBlock = knowledge.isEmpty ? "" : """

            Lattices product knowledge (how the app works; cite the linked docs when a question goes deeper):
            \(knowledge)
            """
        let attachmentBlock = attachments.isEmpty ? "" : """

        Attached files:
            \(assistantAttachmentBlock(attachments))
        """
        return """
        You are the Workspace Assistant, the in-app assistant for Lattices.

        Use the structured context as ground truth for this user's current configuration, and the product knowledge to explain how Lattices works and point to the right feature or doc. Answer naturally and concretely. For informational questions, explain what is currently configured and what the available choices mean.

        For setting changes, inspect or update the relevant local config with tools when available and safe. If you cannot apply the change, say so plainly and give the exact next step. Never claim a setting or file changed unless it actually changed.
        \(knowledgeBlock)
        \(attachmentBlock)

        Structured context:
        \(assistantKnowledgeBrief())

        User request:
        \(userText)
        """
    }

    private func assistantAttachmentBlock(_ attachments: [WorkspaceAssistantAttachment]) -> String {
        attachments.map { attachment in
            """
            --- \(attachment.name) (\(attachment.mediaType)) ---
            \(attachment.content)
            --- end \(attachment.name) ---
            """
        }
        .joined(separator: "\n\n")
    }

    /// Folder name of the directory new turns run in, for status chrome.
    var workingDirectoryName: String {
        URL(fileURLWithPath: scoutProjectPath()).lastPathComponent
    }

    private func scoutProjectPath() -> String {
        let fileManager = FileManager.default
        let current = fileManager.currentDirectoryPath
        if let root = Self.projectRoot(containing: current) { return root }
        if let running = ProjectScanner.shared.projects.first(where: \.isRunning) {
            return running.path
        }
        if let first = ProjectScanner.shared.projects.first {
            return first.path
        }
        let scanRoot = Preferences.shared.scanRoot
        if !scanRoot.isEmpty, fileManager.fileExists(atPath: scanRoot) {
            return scanRoot
        }
        return fileManager.homeDirectoryForCurrentUser.path
    }

    private static func projectRoot(containing path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<8 {
            let git = candidate.appendingPathComponent(".git").path
            let lattices = candidate.appendingPathComponent(".lattices.json").path
            if fileManager.fileExists(atPath: git) || fileManager.fileExists(atPath: lattices) {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    private func voiceAdvisorPrompt(transcript: String, matched: String) -> String {
        """
        You are the same Workspace Assistant used by Lattices chat, responding through the voice command surface.

        Use the shared structured context below as ground truth. The voice surface needs terse commentary and optional next actions, not a chatty answer.

        Structured context:
        \(assistantKnowledgeBrief())

        Voice transcript:
        "\(transcript)"

        Local match already handled:
        \(matched)

        Available intents (use ONLY these names and slot values):
        \(voiceIntentCatalogText())

        Respond with ONLY a JSON object:
        {"commentary": "short observation or null", "suggestion": {"label": "button text", "intent": "intent_name", "slots": {"key": "value"}} or null}

        Rules:
        - commentary: 1 sentence max. null if the matched command fully covers the request.
        - suggestion: a follow-up action. null if none needed.
        - suggestion.intent MUST be one of the intent names listed above. Never invent an intent.
        - For slots marked with {a|b|c}, the value MUST be exactly one of those tokens.
        - Never suggest what was already executed.
        - Suggestions MUST include all required slots (marked with *).
        - Be terse and useful.
        """
    }

    private func voiceQuestionPrompt(transcript: String) -> String {
        let knowledge = Self.capabilitiesGuide
        let knowledgeBlock = knowledge.isEmpty ? "" : """

            Lattices product knowledge (how the app works):
            \(knowledge)
            """
        return """
        You are the same Workspace Assistant used by Lattices chat, responding through the voice surface.

        This is an informational question, not necessarily a command. Use the shared structured context and product knowledge below, answer naturally, and include concrete current settings when relevant. Keep it short enough for voice, but do not give a clipped yes/no answer.
        \(knowledgeBlock)

        Structured context:
        \(assistantKnowledgeBrief())

        User said:
        "\(transcript)"
        """
    }

    /// Renders the full intent catalog as a vocabulary block for the voice prompts.
    /// Each line lists the intent name, description, and its slots with required
    /// markers (`*`) and the exact set of allowed enum values (`{a|b|c}`). The model
    /// only ever sees valid intent names and valid slot values from here, which keeps
    /// it from inventing things the executor rejects (e.g. position "tl", "grid-2x2").
    private func voiceIntentCatalogText() -> String {
        guard case .array(let intents) = PhraseMatcher.shared.catalog() else { return "" }
        return intents.compactMap { intent -> String? in
            guard let name = intent["intent"]?.stringValue else { return nil }
            let desc = intent["description"]?.stringValue ?? ""
            var line = desc.isEmpty ? "- \(name)" : "- \(name) — \(desc)"
            if case .array(let slots) = intent["slots"], !slots.isEmpty {
                let slotDescs = slots.compactMap { slot -> String? in
                    guard let slotName = slot["name"]?.stringValue else { return nil }
                    var s = slotName
                    if slot["required"]?.boolValue == true { s += "*" }
                    if case .array(let vals) = slot["values"] {
                        let values = vals.compactMap { $0.stringValue }
                        if !values.isEmpty { s += " {\(values.joined(separator: "|"))}" }
                    }
                    return s
                }
                if !slotDescs.isEmpty {
                    line += "\n    slots: \(slotDescs.joined(separator: ", "))"
                }
            }
            return line
        }.joined(separator: "\n")
    }

    private func voiceResolverPrompt(transcript: String) -> String {
        let windowList = DesktopModel.shared.windows.values
            .prefix(20)
            .map { "\($0.app): \($0.title)" }
            .joined(separator: "\n")

        let intentList = voiceIntentCatalogText()

        return """
        You are the same Workspace Assistant used by Lattices chat, resolving a spoken command into one executable Lattices intent.

        Structured context:
        \(assistantKnowledgeBrief())

        Voice transcript, possibly with transcription errors:
        "\(transcript)"

        Available intents:
        \(intentList)

        Current windows:
        \(windowList)

        Return ONLY a JSON object like:
        {"intent":"search","slots":{"query":"dewey"},"reasoning":"user wants to find dewey windows"}

        Rules:
        - Use ONLY intent names and slot values listed above. Never invent a slot value.
        - For slots marked with {a|b|c}, the value MUST be exactly one of those tokens.
        - Use intent "unknown" if the request cannot be mapped confidently.
        - Include all required slots (marked with *).
        - For search, extract the key term.
        - Use app/window names from the current windows list when targeting windows.
        - tile_window moves ONE window to a position. To arrange MULTIPLE windows into a grid (e.g. "tile my four iTerms two by two"), use distribute, not tile_window.
        """
    }

    private func voiceRepairPrompt(transcript: String, failedIntent: String, failedSlots: [String: JSON], error: String) -> String {
        let slotsDesc = failedSlots
            .map { "\($0.key)=\($0.value.stringValue ?? "\($0.value)")" }
            .sorted()
            .joined(separator: ", ")
        let attempt = slotsDesc.isEmpty ? failedIntent : "\(failedIntent)(\(slotsDesc))"

        return """
        You are correcting a Lattices voice command that failed to execute. A previous pass
        produced an intent the executor rejected. Fix it using ONLY the vocabulary below.

        Original voice transcript:
        "\(transcript)"

        Previous attempt that FAILED:
        \(attempt)

        Executor error:
        \(error)

        Available intents (use ONLY these names and slot values):
        \(voiceIntentCatalogText())

        Return ONLY a corrected JSON object like:
        {"intent":"distribute","slots":{"app":"iTerm2"},"reasoning":"four terminals into a grid"}

        Rules:
        - Use ONLY intent names and slot values listed above. Never repeat the rejected value.
        - For slots marked with {a|b|c}, the value MUST be exactly one of those tokens.
        - Include all required slots (marked with *).
        - If the request truly cannot be mapped, return {"intent":"unknown"}.
        """
    }

    private func assistantKnowledgeBrief() -> String {
        assistantContextJSON()
    }

    private func assistantContextJSON() -> String {
        let payload = assistantContextPayload()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"context unavailable"}"#
        }
        return text
    }

    private func assistantContextPayload() -> [String: Any] {
        let prefs = Preferences.shared
        MouseShortcutStore.shared.reloadIfNeeded()

        return [
            "assistant": [
                "name": "Workspace Assistant",
                "chatRuntime": [
                    "transportPreference": ["agent-runtime", "hudson-ai-api", "scout"],
                    "agentRuntimeHarness": agentRuntimeHarnessLabel ?? preferredAgentHarness ?? "auto",
                    "apiProvider": currentProvider.name,
                    "apiModel": currentProvider.modelID,
                    "apiCredential": selectedCredentialSummary,
                ],
                "voiceProvider": [
                    "id": authProviderID,
                    "name": currentProvider.name,
                    "model": currentProvider.modelID,
                    "credential": selectedCredentialSummary,
                    "transport": "HudsonAI direct",
                    "credentialStore": "HudVault / macOS Keychain",
                ],
            ],
            "currentSettings": [
                "terminal": prefs.terminal.rawValue,
                "detachMode": prefs.mode.rawValue,
                "scanRoot": prefs.scanRoot.isEmpty ? NSNull() : prefs.scanRoot,
                "dragToSnap": prefs.dragSnapEnabled,
                "companionBridge": prefs.companionBridgeEnabled,
                "companionTrackpad": prefs.companionTrackpadEnabled,
                "keyboard": [
                    "ctrlOptionHoldMode": prefs.ctrlOptionHoldMode.rawValue,
                    "keyboardRemapsEnabled": prefs.keyboardRemapsEnabled,
                    "spaceSwitchKeysEnabled": prefs.spaceSwitchKeysEnabled,
                    "spaceSwitchBezelPosition": prefs.spaceSwitchBezelPosition.rawValue,
                    "spaceSwitchGlideEnabled": prefs.spaceSwitchGlideEnabled,
                ],
                "pointer": [
                    "tilePointerHUDStyle": prefs.tilePointerHUDStyle.rawValue,
                    "tilePointerSoundEffects": prefs.tilePointerSoundEffectsEnabled,
                    "cursorMarkerShape": prefs.cursorMarkerShape.rawValue,
                    "cursorMarkerAngleDeg": prefs.cursorMarkerAngleDeg,
                    "cursorMarkerSize": prefs.cursorMarkerSize.rawValue,
                ],
                "ocr": [
                    "enabled": prefs.ocrEnabled,
                    "retentionDays": prefs.ocrRetentionDays,
                    "accuracy": prefs.ocrAccuracy,
                    "quickIntervalSeconds": prefs.ocrQuickInterval,
                    "deepIntervalSeconds": prefs.ocrDeepInterval,
                    "quickWindowLimit": prefs.ocrQuickLimit,
                    "deepWindowLimit": prefs.ocrDeepLimit,
                    "deepScanBudget": prefs.ocrDeepBudget,
                ],
                "mouseShortcuts": mouseShortcutContextPayload(),
                "layers": WorkspaceManager.shared.layersContextPayload(),
                "liveTabGroups": LiveTabGroupStore.shared.assistantContextPayload(),
            ],
            "settingsCatalog": [
                [
                    "id": "terminal",
                    "type": "enum",
                    "choices": Terminal.allCases.map(\.rawValue),
                    "installedChoices": Terminal.installed.map(\.rawValue),
                    "description": "Terminal app used when Lattices launches workspaces.",
                ],
                [
                    "id": "detachMode",
                    "type": "enum",
                    "choices": ["learning", "auto"],
                    "description": "Learning mode shows tmux hints; auto mode stays quieter.",
                ],
                [
                    "id": "scanRoot",
                    "type": "path",
                    "description": "Root directory scanned for projects containing .lattices.json.",
                ],
                [
                    "id": "dragToSnap",
                    "type": "boolean",
                    "description": "Enables drag-to-snap window zones.",
                ],
                [
                    "id": "mouseShortcuts",
                    "type": "boolean-plus-json-rules",
                    "description": "Middle-click and drag gesture shortcuts controlled by mouseGestures.enabled plus ~/.lattices/mouse-shortcuts.json.",
                ],
                [
                    "id": "ocr",
                    "type": "object",
                    "description": "Screen text recognition settings, including enablement, cadence, and accuracy.",
                ],
                [
                    "id": "assistantProvider",
                    "type": "enum-plus-api-key",
                    "choices": ["openai", "groq", "openrouter", "minimax"],
                    "description": "Provider-backed inference for chat and voice.",
                ],
            ],
            "settingsFiles": [
                "workspace": "\(NSHomeDirectory())/.lattices/workspace.json",
                "mouseShortcuts": MouseShortcutStore.shared.configURL.path,
                "mouseShortcutsHistory": MouseShortcutStore.shared.historyDirectoryURL.path,
                "snapZones": "\(NSHomeDirectory())/.lattices/snap-zones.json",
                "ocrDatabase": "\(NSHomeDirectory())/.lattices/ocr.db",
                "diagnostics": "\(NSHomeDirectory())/.lattices/lattices.log",
            ],
            "cliCommands": [
                "lattices",
                "lattices init",
                "lattices sync",
                "lattices restart [pane]",
                "lattices tile <position>",
                "lattices group [id]",
                "lattices layer [name|slot]",
                "lattices windows --json",
                "lattices search <query>",
                "lattices app restart",
            ],
            "runtimeSnapshot": [
                "installedTerminals": Terminal.installed.map(\.rawValue),
                "discoveredProjectCount": ProjectScanner.shared.projects.count,
            ],
        ]
    }

    private func mouseShortcutContextPayload() -> [String: Any] {
        let prefs = Preferences.shared
        let store = MouseShortcutStore.shared
        store.reloadIfNeeded()

        return [
            "enabled": prefs.mouseGesturesEnabled,
            "hud": [
                "visual": prefs.mouseGestureHUDVisualEnabled,
                "audio": prefs.mouseGestureHUDAudioEnabled,
                "style": prefs.mouseGestureHUDStyle.rawValue,
            ],
            "configFile": store.configURL.path,
            "historyDirectory": store.historyDirectoryURL.path,
            "recentHistory": store.historySummaryLines,
            "tuning": [
                "dragThresholdPx": Double(store.tuning.dragThreshold),
                "holdTolerancePx": Double(store.tuning.holdTolerance),
                "axisBias": Double(store.tuning.axisBias),
            ],
            "activeMappings": store.enabledRules.map { rule in
                [
                    "id": rule.id,
                    "trigger": rule.trigger.displayLabel,
                    "action": rule.action.label,
                    "summary": rule.summary,
                ]
            },
        ]
    }

    private func settingsSummary() -> String {
        let prefs = Preferences.shared
        return """
        Current settings:
        Terminal: \(prefs.terminal.rawValue)
        Detach mode: \(prefs.mode.rawValue)
        Scan root: \(prefs.scanRoot.isEmpty ? "not set" : prefs.scanRoot)
        Drag-to-snap: \(prefs.dragSnapEnabled ? "on" : "off")
        Mouse gestures: \(prefs.mouseGesturesEnabled ? "on" : "off")
        Companion bridge: \(prefs.companionBridgeEnabled ? "on" : "off")
        Companion trackpad: \(prefs.companionTrackpadEnabled ? "on" : "off")
        OCR: \(prefs.ocrEnabled ? "on" : "off"), \(prefs.ocrAccuracy)
        Chat: Scout local broker
        Voice interpretation: \(currentProvider.name) (\(hasSelectedCredential ? "credential saved" : "credential not configured"))

        \(mouseShortcutSummary())
        """
    }

    private func mouseShortcutSummary() -> String {
        let prefs = Preferences.shared
        let store = MouseShortcutStore.shared
        store.reloadIfNeeded()
        let mappings = store.summaryLines
        let mappingText = mappings.isEmpty
            ? "- No active mouse shortcut mappings."
            : mappings.map { "- \($0)" }.joined(separator: "\n")

        return """
        Mouse shortcuts:
        - Middle-click shortcuts are \(prefs.mouseGesturesEnabled ? "enabled" : "disabled").
        - Config file: \(store.configURL.path)
        - History: \(store.historyDirectoryURL.path)
        - Drag threshold: \(Int(store.tuning.dragThreshold)) px; hold tolerance: \(Int(store.tuning.holdTolerance)) px; axis bias: \(String(format: "%.1f", Double(store.tuning.axisBias))).
        Active mappings:
        \(mappingText)
        """
    }

    private static func extractJSON(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}") else { return nil }
        return String(cleaned[start...end])
    }

    private func settingsHelpText() -> String {
        """
        I can manage Lattices settings from chat. Try:
        - set terminal to Ghostty
        - set scan root to ~/dev
        - turn OCR off
        - set OCR accuracy to fast
        - enable drag snap
        - disable mouse gestures
        - set detach mode to auto
        - open assistant settings
        - open settings
        """
    }

    private func parseTerminal(from lower: String) -> Terminal? {
        let aliases: [(Terminal, [String])] = [
            (.iterm2, ["iterm2", "iterm"]),
            (.warp, ["warp"]),
            (.ghostty, ["ghostty"]),
            (.kitty, ["kitty"]),
            (.alacritty, ["alacritty"]),
            (.terminal, ["terminal.app", "apple terminal", "terminal"]),
        ]

        return aliases.first { _, names in
            names.contains { lower.contains($0) }
        }?.0
    }

    /// Questions and status checks should reach the provider with structured context.
    private func isInformationalSettingsQuery(_ lower: String) -> Bool {
        if lower.contains("?") {
            return true
        }

        let markers = [
            "can you take a look",
            "can you look",
            "could you look",
            "take a look",
            "look at ",
            "what are ",
            "what is ",
            "what's ",
            "which ",
            "how do ",
            "how are ",
            "tell me ",
            "show me ",
            "list ",
            "describe ",
            "explain ",
            "currently ",
            "right now",
            "at the moment",
            "do i have ",
            "are there ",
            "is there ",
            "am i using ",
        ]
        return markers.contains { lower.contains($0) }
    }

    private func isSettingsMutationIntent(_ lower: String) -> Bool {
        !isInformationalSettingsQuery(lower)
            && (
                lower.contains("set ")
                || lower.contains("update ")
                || lower.contains("configure ")
                || lower.contains("switch to ")
                || lower.contains("change ")
                || lower.contains("use ")
                || lower.hasPrefix("enable ")
                || lower.hasPrefix("disable ")
                || lower.contains(" turn on ")
                || lower.contains(" turn off ")
                || lower.contains("turn on ")
                || lower.contains("turn off ")
            )
    }

    private func parseBooleanMutation(from lower: String) -> Bool? {
        guard isSettingsMutationIntent(lower) else { return nil }

        let offTokens = ["turn off", "disable", "switch off"]
        if offTokens.contains(where: lower.contains) {
            return false
        }

        let onTokens = ["turn on", "enable", "switch on"]
        if onTokens.contains(where: lower.contains) {
            return true
        }

        return nil
    }

    private func isMouseShortcutRuleRequest(_ lower: String) -> Bool {
        let ruleMarkers = [
            " back button",
            " forward button",
            " middle button",
            "button.",
            "button ",
            "swipe",
            "slide",
            "drag up",
            "drag down",
            "drag left",
            "drag right",
            "map ",
            "mapping",
            "bind ",
            "assign ",
            "rule",
            "dictation",
            "transcription",
            "enter",
            "shortcut.send",
            "dictation.start",
        ]
        return ruleMarkers.contains { lower.contains($0) }
    }

    private func extractPathValue(from text: String) -> String? {
        let markers = [" to ", " at ", " root "]
        let lower = text.lowercased()

        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            let raw = text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !raw.isEmpty else { continue }
            return (raw as NSString).expandingTildeInPath
        }

        return nil
    }

    private func extractFirstNumber(from text: String) -> Double? {
        let pattern = #"(?<![A-Za-z0-9_])\$?([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    private func friendlyAuthFailureMessage(for message: String) -> String? {
        let lowercased = message.lowercased()
        let authHints = [
            "use /login",
            "set an api key environment variable",
            "authentication",
            "unauthorized",
            "api key",
            "oauth",
            "token",
        ]

        guard authHints.contains(where: lowercased.contains) else { return nil }

        return "This provider still needs an API key. Open Settings with the gear icon, save your \(currentProvider.tokenLabel.lowercased()), and then try again."
    }

    private func reloadAuthState() {
        // The UI only needs presence here. Reading secret data causes Keychain
        // to evaluate the item's app-signature ACL and can show a password
        // prompt when switching between dev and release bundle identities.
        // HudVault.list() requests attributes only, so opening Scout chat never
        // asks Keychain to disclose a voice credential.
        let storedKeys = Set((try? voiceVault.list()) ?? [])
        storedCredentialKinds = Dictionary(uniqueKeysWithValues:
            AssistantProvider.supported.compactMap { provider in
                storedKeys.contains(provider.credentialKey)
                    ? (provider.id, "api_key")
                    : nil
            }
        )
    }

    private static func looksLikeAuthError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("api key")
            || lowercased.contains("oauth")
            || lowercased.contains("token")
            || lowercased.contains("authentication")
            || lowercased.contains("unauthorized")
            || lowercased.contains("bad request")
    }

    private static func clampDockHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, 170), 520)
    }

}
