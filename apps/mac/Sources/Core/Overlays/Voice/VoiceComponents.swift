import AppKit
import Combine
import SwiftUI

// Reusable voice building blocks — the state machine and the small SwiftUI
// pieces that render it. Relocated out of the retired `VoiceCommandWindow.swift`
// (the standalone 3-column voice window) so the unified command bar can compose
// `VoiceCommandState` and reuse `WaveBar` / `ListeningTimer` / `ResultRow`
// without dragging the old window/view chrome along. The deadlock-safe
// DiagnosticLog observer inside `VoiceCommandState` is preserved byte-for-byte.

// MARK: - Transcript Entry

struct ResultItem: Identifiable {
    let id = UUID()
    let wid: UInt32
    let app: String
    let title: String
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let intent: String?
    let slots: [String: String]
    let result: String?
    let resultItems: [ResultItem]
    let logLines: [String]
}

// MARK: - State

final class VoiceCommandState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case transcribing
        case result
    }

    @Published var phase: Phase = .idle
    @Published var armed: Bool = true   // When armed, Space controls the mic
    @Published var partialText: String = ""

    // Current command
    @Published var finalText: String = ""
    @Published var intentName: String?
    @Published var intentSlots: [String: String] = [:]
    @Published var executionResult: String?
    @Published var executionError: String?   // Non-nil when the last intent failed to run
    @Published var resultItems: [ResultItem] = []
    @Published var resultSummary: String = ""

    // Agent advisor response
    @Published var agentResponse: AgentResponse?
    @Published var assistantHandoffPrompt: String?

    // Listening timer
    @Published var listenStartTime: Date = Date()

    // History — all transcripts this session
    @Published var history: [TranscriptEntry] = []

    // Diagnostic log
    @Published var logLines: [String] = []

    private var logSnapshot = 0
    private var logObserver: AnyCancellable?
    private var cancelled = false
    private var requestID = UUID()

    func startListening() {
        guard phase == .idle || phase == .result else { return }
        // Capture runs through AudioLayer; this gate only lets the overlay enter
        // listening once the Vox/HudsonVoice socket is actually reachable.
        cancelled = false
        requestID = UUID()
        phase = .connecting
        executionResult = "Connecting to voice runtime..."
        waitForVoiceRuntime(attempts: 0, requestID: requestID)
    }

    private func waitForVoiceRuntime(attempts: Int, requestID: UUID) {
        guard !cancelled, self.requestID == requestID else { return }
        guard let provider = AudioLayer.shared.provider else {
            let message = "No voice provider available"
            appendLog(message)
            executionResult = message
            resultSummary = message
            syncLogs()
            phase = .result
            return
        }

        guard provider.isAvailable else {
            retryOrFailVoiceRuntime(provider: provider, attempts: attempts, requestID: requestID)
            return
        }

        provider.checkHealth { [weak self] ok in
            guard let self, !self.cancelled, self.requestID == requestID else { return }
            if ok {
                self.beginListening()
            } else {
                self.retryOrFailVoiceRuntime(provider: provider, attempts: attempts, requestID: requestID)
            }
        }
    }

    private func retryOrFailVoiceRuntime(provider: any AudioProvider, attempts: Int, requestID: UUID) {
        guard attempts < 20 else {
            let message = provider.lastErrorMessage ?? "Voice runtime not running - try again after it starts."
            appendLog(message)
            executionResult = message
            resultSummary = message
            syncLogs()
            phase = .result
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForVoiceRuntime(attempts: attempts + 1, requestID: requestID)
        }
    }

    private func beginListening() {
        cancelled = false
        phase = .listening
        listenStartTime = Date()
        partialText = ""
        finalText = ""
        intentName = nil
        intentSlots = [:]
        executionResult = nil
        executionError = nil
        resultItems = []
        resultSummary = ""
        agentResponse = nil
        assistantHandoffPrompt = nil
        // Snapshot log position and observe changes reactively (no polling race)
        logSnapshot = DiagnosticLog.shared.entries.count
        logLines = []
        logObserver = DiagnosticLog.shared.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in
                guard let self else { return }
                let start = min(self.logSnapshot, entries.count)
                let newLines = entries.suffix(from: start).map { $0.message }
                guard !newLines.isEmpty, newLines != self.logLines else { return }
                // Defer the @Published mutation to a fresh run-loop turn. Writing it
                // synchronously here re-enters VoiceCommandState.objectWillChange while
                // DiagnosticLog's publish is still holding its os_unfair_lock, which
                // deadlocks the main thread (the lock is non-recursive).
                DispatchQueue.main.async {
                    guard newLines != self.logLines else { return }
                    self.logLines = newLines
                }
            }
        AudioLayer.shared.startVoiceCommand()
    }

    func stopListening() {
        guard phase == .listening else { return }
        phase = .transcribing
        AudioLayer.shared.stopVoiceCommand()
        observeResult()
    }

    func cancelListening() {
        cancelled = true
        requestID = UUID()
        phase = .idle
        AudioLayer.shared.cancelVoiceCommand()
        appendLog("Cancelled")
    }

    /// Cancel any in-progress processing (polling loops will check this flag).
    func cancelProcessing() {
        cancelled = true
        requestID = UUID()
        if phase == .listening || phase == .transcribing || phase == .connecting {
            AudioLayer.shared.cancelVoiceCommand()
            appendLog("Processing cancelled")
            phase = .idle
        }
    }

    func toggleArmed() {
        if phase == .listening {
            // Stop listening when disarming
            cancelListening()
        }
        armed.toggle()
    }

    func toggleListening() {
        switch phase {
        case .listening:
            stopListening()
        case .idle, .result:
            startListening()
        default:
            break
        }
    }

    func appendLog(_ msg: String) {
        DiagnosticLog.shared.info(msg)
    }

    private func syncLogs() {
        // Logs are now updated reactively via logObserver.
        // This is kept as a manual trigger for the final commit.
        let entries = DiagnosticLog.shared.entries
        let start = min(logSnapshot, entries.count)
        let newLines = entries.suffix(from: start).map { $0.message }
        logLines = newLines
    }

    private func pollForAdvisor() {
        let audio = AudioLayer.shared
        let requestID = requestID
        var checks = 0

        func poll() {
            guard !self.cancelled, self.requestID == requestID else { return }
            if let resp = audio.agentResponse {
                self.agentResponse = resp
                return
            }
            checks += 1
            if checks < 60 { // Up to 12 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
            }
        }

        // Only poll if we don't already have a response
        if agentResponse == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
        }
    }

    func restoreFromHistory(_ entry: TranscriptEntry) {
        finalText = entry.text
        intentName = entry.intent
        intentSlots = entry.slots
        executionResult = entry.result
        resultItems = entry.resultItems
        resultSummary = entry.resultItems.isEmpty ? "" : "\(entry.resultItems.count) result\(entry.resultItems.count == 1 ? "" : "s")"
        logLines = entry.logLines
        agentResponse = nil
        assistantHandoffPrompt = nil
        phase = .result
    }

    private func commitToHistory() {
        guard !finalText.isEmpty else { return }
        let entry = TranscriptEntry(
            timestamp: Date(),
            text: finalText,
            intent: intentName,
            slots: intentSlots,
            result: executionResult,
            resultItems: resultItems,
            logLines: logLines
        )
        history.append(entry)
        // logLines are NOT reset here — they stay visible until the next command starts
    }

    private func observeResult() {
        let audio = AudioLayer.shared
        let requestID = requestID
        var checks = 0
        let maxChecks = 75  // 15 seconds at 0.2s intervals

        func syncState() {
            // Sync transcript immediately
            if let transcript = audio.lastTranscript, !transcript.isEmpty {
                self.finalText = transcript
            }

            // Sync intent/slots as they become available
            if let intent = audio.matchedIntent {
                self.intentName = intent
                self.intentSlots = audio.matchedSlots
            }

            // Sync agent advisor response
            if let resp = audio.agentResponse {
                self.agentResponse = resp
            }

            self.assistantHandoffPrompt = audio.assistantHandoffPrompt

            // Mirror any execution failure so the UI can flag it
            self.executionError = audio.executionError
        }

        func poll() {
            // Bail if cancelled (e.g. user dismissed or started a new command)
            guard !self.cancelled, self.requestID == requestID else { return }

            checks += 1
            syncState()

            let result = audio.executionResult

            // Terminal errors — log them, go to result (not a separate error phase)
            if let result, Self.isRetryableFailure(result) {
                appendLog(result)
                self.executionResult = result
                self.resultSummary = Self.failureSummary(result)
                syncLogs()
                self.phase = .result
                return
            }

            // Still working
            let stillWorking = audio.isTranscribing || result == nil
                || result == "Transcribing..."
                || result == "thinking..."
                || result == "searching..."
                || result == "fixing..."

            if stillWorking {
                // Capture has its own bounded deadline, including model startup.
                // The action timeout starts after a transcript has arrived.
                if audio.isTranscribing { checks = 0 }
                if let result { self.executionResult = result }
                self.phase = .transcribing
                if checks < maxChecks {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                } else {
                    let timeout = "Timed out waiting for a voice result — no action outcome was reported. Try again."
                    appendLog(timeout)
                    self.executionResult = timeout
                    self.resultSummary = timeout
                    syncLogs()
                    commitToHistory()
                    self.phase = .result
                }
                return
            }

            // Grace period for transcript
            if self.finalText.isEmpty && checks < 25 {
                self.phase = .transcribing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                return
            }

            // Final result
            self.executionResult = result
            if let data = audio.executionData {
                switch data {
                case .array(let items):
                    self.resultItems = items.compactMap { item in
                        guard let wid = item["wid"]?.intValue,
                              let app = item["app"]?.stringValue,
                              let title = item["title"]?.stringValue else { return nil }
                        return ResultItem(wid: UInt32(wid), app: app, title: title)
                    }
                    self.resultSummary = "\(items.count) result\(items.count == 1 ? "" : "s")"
                case .object(let obj):
                    self.resultItems = []
                    self.resultSummary = self.friendlyObjectSummary(obj, fallback: result)
                default:
                    self.resultItems = []
                    self.resultSummary = self.friendlyScalarSummary(data, fallback: result)
                }
            } else {
                self.resultItems = []
                if let result, result != "ok" {
                    self.resultSummary = result
                } else {
                    self.resultSummary = ""
                }
            }

            syncLogs()  // Final sync before committing
            commitToHistory()
            self.phase = .result

            // Keep polling for agent advisor response (arrives later)
            self.pollForAdvisor()
        }

        // Sync immediately (no delay for transcript), then start polling
        syncState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
    }

    private func friendlyObjectSummary(_ obj: [String: JSON], fallback: String?) -> String {
        if let summary = obj["summary"]?.stringValue, !summary.isEmpty {
            return summary
        }
        if let message = obj["message"]?.stringValue, !message.isEmpty {
            return message
        }
        if obj["ok"]?.boolValue == false {
            if intentName == "focus" {
                return friendlyFocusSummary(obj, fallback: fallback, success: false)
            }
            return obj["reason"]?.stringValue ?? fallbackSummary(fallback, defaultValue: "Voice command did not complete")
        }

        switch intentName ?? "" {
        case "focus":
            return friendlyFocusSummary(obj, fallback: fallback, success: true)
        case "tile_window":
            if let position = obj["position"]?.stringValue {
                return "Moved window to \(position)"
            }
        case "move_to_display":
            if let display = obj["display"]?.intValue {
                return "Moved window to display \(display + 1)"
            }
        case "launch":
            if let launched = obj["launched"]?.stringValue {
                return "Opened \(launched)"
            }
        case "kill":
            if let killed = obj["killed"]?.stringValue ?? obj["session"]?.stringValue {
                return "Closed \(killed)"
            }
        default:
            break
        }

        return fallbackSummary(fallback, defaultValue: obj["ok"]?.boolValue == true ? "Done" : "Result ready")
    }

    private func friendlyFocusSummary(_ obj: [String: JSON], fallback: String?, success: Bool) -> String {
        if let launched = nonEmpty(obj["launched"]?.stringValue) {
            return "Launched \(launched)"
        }

        let app = nonEmpty(obj["app"]?.stringValue ?? obj["focused"]?.stringValue)
        let session = nonEmpty(obj["session"]?.stringValue ?? obj["latticesSession"]?.stringValue)
        let requested = nonEmpty(obj["requested"]?.stringValue)
        let rawTitle = nonEmpty(obj["title"]?.stringValue)
        let title = nonEmpty(rawTitle.map(cleanWindowTitle))
        let fallbackText = nonEmpty(fallback)
        let fallbackTarget = fallbackText == "ok" ? nil : fallbackText
        let target = app ?? session ?? title ?? requested ?? fallbackTarget ?? "target"

        var summary = success ? "Focused \(target)" : "Could not focus \(target)"
        if let title, title.localizedCaseInsensitiveCompare(target) != .orderedSame {
            summary += " - \"\(clipped(title))\""
        }

        var details: [String] = []
        if let session, session.localizedCaseInsensitiveCompare(target) != .orderedSame {
            details.append("session \(session)")
        }
        if let wid = obj["wid"]?.intValue {
            details.append("wid \(wid)")
        }
        if let resolution = nonEmpty(obj["targetResolution"]?.stringValue) {
            details.append("via \(humanFocusResolution(resolution))")
        }
        if !success, let reason = nonEmpty(obj["reason"]?.stringValue) {
            details.append(reason)
        } else if success, obj["raised"]?.boolValue == false {
            details.append("raise not confirmed")
        }

        if !details.isEmpty {
            summary += " (\(details.joined(separator: ", ")))"
        }
        return summary
    }

    private func friendlyScalarSummary(_ data: JSON, fallback: String?) -> String {
        if let text = data.stringValue, !text.isEmpty {
            return text
        }
        if let ok = data.boolValue {
            return ok ? "Done" : "Voice command did not complete"
        }
        return fallbackSummary(fallback, defaultValue: "Result ready")
    }

    private func fallbackSummary(_ fallback: String?, defaultValue: String) -> String {
        let text = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty && text != "ok" {
            return text
        }
        return defaultValue
    }

    private func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cleanWindowTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"\[lattices:[^\]]+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title : cleaned
    }

    private func clipped(_ text: String, limit: Int = 90) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 3))).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func humanFocusResolution(_ resolution: String) -> String {
        switch resolution {
        case "wid": return "window id"
        case "app": return "app match"
        case "search": return "search"
        case "session": return "session"
        case "session-locator": return "session locator"
        case "app-launch": return "app launch"
        default: return resolution.replacingOccurrences(of: "-", with: " ")
        }
    }

    static func isRetryableFailure(_ result: String) -> Bool {
        result == "No speech detected"
            || result == "Transcription failed"
            || result.hasPrefix("Transcription failed:")
            || result.hasPrefix("Voice runtime")
            || result.hasPrefix("Mic in use")
    }

    static func failureSummary(_ result: String) -> String {
        switch result {
        case "No speech detected":
            return "No speech detected - try again."
        case "Transcription failed":
            return "Transcription failed - try again."
        default:
            return result
        }
    }
}

// MARK: - Wave Bar Animation

struct WaveBar: View {
    @State private var animating = false
    private let barCount = 4
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.text.opacity(0.7))
                    .frame(width: barWidth, height: animating ? barHeight(for: i) : 3)
                    .animation(
                        .easeInOut(duration: duration(for: i))
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.1),
                        value: animating
                    )
            }
        }
        .frame(height: 12)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }

    private func barHeight(for index: Int) -> CGFloat {
        [10, 6, 12, 8][index % 4]
    }

    private func duration(for index: Int) -> Double {
        [0.4, 0.35, 0.45, 0.3][index % 4]
    }
}

// MARK: - Listening Timer

struct ListeningTimer: View {
    let startTime: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatTime(elapsed))
            .font(Typo.geistMono(10))
            .foregroundColor(Palette.text.opacity(0.7))
            .monospacedDigit()
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startTime)
            }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let secs = Int(t)
        let tenths = Int((t - Double(secs)) * 10)
        return String(format: "%d.%d", secs, tenths)
    }
}

// MARK: - Result Row

struct ResultRow: View {
    let index: Int
    let item: ResultItem
    let onFocus: (UInt32) -> Void
    let onTile: (UInt32, String) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(Typo.geistMono(9))
                .foregroundColor(Palette.textMuted)
                .frame(width: 14, alignment: .leading)
            Text(item.app)
                .font(Typo.geistMonoBold(10))
                .foregroundColor(Palette.textDim)
                .frame(minWidth: 60, alignment: .leading)
            Text(item.title.isEmpty ? "(untitled)" : item.title)
                .font(Typo.geistMono(10))
                .foregroundColor(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    actionButton("Focus", systemImage: "eye") {
                        onFocus(item.wid)
                    }
                    actionButton("Tile Left", systemImage: "rectangle.lefthalf.filled") {
                        onTile(item.wid, "left")
                    }
                    actionButton("Tile Right", systemImage: "rectangle.righthalf.filled") {
                        onTile(item.wid, "right")
                    }
                    actionButton("Maximize", systemImage: "rectangle.fill") {
                        onTile(item.wid, "maximize")
                    }
                    actionButton("Inspect in Map", systemImage: "map") {
                        ScreenMapWindowController.shared.showWindow(wid: item.wid)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Palette.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onFocus(item.wid)
        }
    }

    private func actionButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
                .foregroundColor(Palette.text)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Palette.border, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
