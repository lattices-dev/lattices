import AppKit
import ActionCore
import AVFoundation
import Foundation
import OSLog
import SwiftUI

@MainActor
final class ActionAppearanceStore: ObservableObject {
    static let shared = ActionAppearanceStore()

    @Published var mode: ActionAppearanceMode {
        didSet {
            mode.persist()
            NSApplication.shared.appearance = mode.appearance
            for window in NSApplication.shared.windows {
                window.appearance = mode.appearance
            }
        }
    }

    private init() {
        self.mode = .load()
    }
}

enum ActionRunKind: String, Codable, CaseIterable, Identifiable {
    case capture
    case drive
    case inspection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture"
        case .drive: return "Drive"
        case .inspection: return "Inspect"
        }
    }

    var icon: String {
        switch self {
        case .capture: return "record.circle"
        case .drive: return "cursorarrow.motionlines"
        case .inspection: return "viewfinder"
        }
    }
}

/// Terminal disposition of a run, collapsed from the many raw state strings the
/// runtime writes (`driving`, `done`, `completed`, `failed`, `cancelled`,
/// `expired`). Runs is an operator ledger, so the row needs one glanceable
/// signal rather than the raw vocabulary.
enum ActionRunOutcome: String, CaseIterable, Identifiable {
    case running
    case unfinished
    case ok
    case failed
    case stopped

    var id: String { rawValue }

    /// A drive that has not been heard from for this long is gone, not working.
    /// The number is not a guess: it matches
    /// `ActionSupervisionRegistry.driveIdleExpirySeconds` and the runtime's
    /// `AGENT_CURSOR_IDLE_EXPIRY_MS`, so the ledger agrees with the supervisor
    /// that already dropped the lease rather than inventing its own opinion.
    static let idleExpirySeconds: TimeInterval = 90

    /// - Parameter lastActivity: the newest timestamp the run wrote — a release,
    ///   or failing that its last heartbeat. `nil` means the run never reported.
    init(state: String, lastActivity: Date?, now: Date = Date()) {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed", "error":
            self = .failed
        case "cancelled", "canceled", "expired", "released":
            self = .stopped
        case "done", "completed", "succeeded", "ok":
            self = .ok
        default:
            // Mid-flight with no terminal record. Live only while the run is
            // still checking in; otherwise it was abandoned mid-drive and
            // saying "Running" about it is a lie the whole ledger pays for.
            guard let lastActivity,
                  now.timeIntervalSince(lastActivity) < Self.idleExpirySeconds else {
                self = .unfinished
                return
            }
            self = .running
        }
    }

    var title: String {
        switch self {
        case .running: return "Running"
        case .unfinished: return "Unfinished"
        case .ok: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    var tint: Color {
        switch self {
        case .running: return StageHUDTheme.runRunning
        case .unfinished: return StageHUDTheme.runStopped
        case .ok: return StageHUDTheme.runOk
        case .failed: return StageHUDTheme.runFailed
        case .stopped: return StageHUDTheme.runStopped
        }
    }

    /// A filled dot means the run reached a state someone recorded. `unfinished`
    /// is the one outcome nobody ever wrote down, so it reads as an open ring —
    /// the difference is carried by form, not by spending another colour.
    var isSettled: Bool {
        self != .unfinished
    }
}

struct ActionSessionSummary: Identifiable {
    let id: String
    let sessionId: String
    let kind: ActionRunKind
    let artifactDirectoryURL: URL
    let videoURL: URL
    let traceURL: URL
    let feedbackURL: URL
    let stageScreenshotURL: URL?
    let resultScreenshotURL: URL?
    let expression: String
    let expectedResult: String
    let actualResult: String
    let startedAt: Date?
    let finishedAt: Date?
    let feedbackCount: Int
    /// Best-effort media duration in seconds (video first, wall-clock fallback).
    let durationSeconds: Double?
    let label: String
    let subtitle: String
    let state: String
    /// Driving agent identity, kept separate from `subtitle` so the Runs row can
    /// rank it below the task instead of inheriting a pre-joined string.
    let agent: String
    /// How the driver reached the agent: the client it named plus the process
    /// the agent saw on the socket. Empty for runs recorded before the agent
    /// kept the ledger.
    let client: String
    let outcome: ActionRunOutcome

    var agentFeedbackMarkdownURL: URL {
        artifactDirectoryURL.appendingPathComponent("agent-feedback.md")
    }

    var agentFeedbackJSONURL: URL {
        artifactDirectoryURL.appendingPathComponent("agent-feedback.json")
    }

    var displayTitle: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let compact = expression.replacingOccurrences(of: " ", with: "")
        return compact.isEmpty ? sessionId : compact
    }

    var isCalculatorTake: Bool {
        kind == .capture && !actualResult.isEmpty
    }

    /// The single date the Runs ledger sorts, groups, and prints. When a run
    /// began is what an operator scans for; anything else has to agree with it.
    var ledgerDate: Date? {
        startedAt ?? finishedAt
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }
        if durationSeconds < 60 {
            return String(format: "%.0fs", durationSeconds.rounded())
        }
        let total = Int(durationSeconds.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct ActionSessionTrace: Decodable {
    let sessionId: String
    let startedAt: String
    let finishedAt: String
    let expression: String
    let expectedResult: String
    let actualResult: String
    let videoPath: String
    let screenshots: [String]
}

private struct PersistedSessionRecord: Decodable {
    let id: String
    let mode: String?
    let state: String?
    let phase: String?
    let createdAt: String?
    let updatedAt: String?
    let targetApp: String?
    let driveLeaseId: String?
    let drive: PersistedDriveRecord?
}

private struct PersistedDriveRecord: Decodable {
    let agent: String?
    let task: String?
    let summary: String?
    let outcome: String?
    let status: String?
    let startedAt: String?
    let releasedAt: String?
    let client: String?
    let clientProcess: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GuidedCaptureLauncherResult: Decodable {
    let sessionId: String
    let artifactDirectory: String
    let videoPath: String
    let tracePath: String
    let expectedResult: String
    let actualResult: String
    let expression: String
}

@MainActor
final class ActionLauncherViewModel: ObservableObject {
    private let logger = Logger(subsystem: ActionAppIdentity.mainBundleIdentifier, category: "Launcher")
    private let agentProcess = ActionAgentProcessController()
    private let agentClient = ActionAgentClient()

    @Published var agentStatus: String = "Offline"
    @Published var accessibilityStatus: String = "Unknown"
    @Published var screenRecordingStatus: String = "Unknown"
    @Published var notes: [String] = []
    /// The status line before anything has happened. Surfaces compare against
    /// it so they can stay silent rather than print it.
    static let idleStatus = "Ready"
    @Published var guidedDemoStatus: String = ActionLauncherViewModel.idleStatus
    @Published var recentSessions: [ActionSessionSummary] = []
    @Published var isRunningGuidedDemo: Bool = false
    @Published var selectedSessionID: String?
    @Published var focusedFeedbackItemID: String?
    @Published var appearanceMode: ActionAppearanceMode
    @Published private(set) var reviewSelectionRequestID = UUID()

    /// Scenarios under Start → Edit → Review (the flow is inherent, not a named “loop”).
    @Published var scenarios: [ActionScenarioDocument] = []
    @Published var selectedScenarioID: String?
    @Published var selectedScenarioStepID: String?
    @Published var scenarioDraftGoal: String = "Calculator, keyboard and click"
    @Published var scenarioStepFeedbackDraft: String = ""
    @Published private(set) var workspaceNavigationRequestID = UUID()
    @Published private(set) var launcherDestination: ActionLauncherDestination = .home
    @Published private(set) var launcherDestinationRequestID = UUID()

    var selectedScenario: ActionScenarioDocument? {
        if let selectedScenarioID,
           let scenario = scenarios.first(where: { $0.id == selectedScenarioID }) {
            return scenario
        }
        return scenarios.first
    }

    var selectedScenarioStep: ActionScenarioStep? {
        guard let scenario = selectedScenario else { return nil }
        if let selectedScenarioStepID,
           let step = scenario.steps.first(where: { $0.id == selectedScenarioStepID }) {
            return step
        }
        return scenario.steps.first
    }

    var needsBundleIdentityPermissionReview: Bool {
        guard UserDefaults.standard.bool(
            forKey: ActionPreferenceMigration.permissionRegrantPendingMarkerKey
        ) else {
            return false
        }

        return [accessibilityStatus, screenRecordingStatus]
            .contains { $0.lowercased() == "denied" }
    }

    private var expectedAgentBundlePath: String? {
        guard Bundle.main.bundleIdentifier == ActionAppIdentity.mainBundleIdentifier else {
            return nil
        }

        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ActionAgent.app", isDirectory: true)
            .resolvingSymlinksInPath()
            .path
    }

    var hasAgentIdentityMismatch: Bool {
        agentStatus == "Agent instance mismatch"
    }

    init() {
        self.appearanceMode = ActionAppearanceStore.shared.mode
        refreshSessions()
        refreshScenarios()
    }

    func refreshPermissions() {
        Task {
            await refreshPermissionsViaAgent()
        }
    }

    func requestPermissions() {
        Task {
            _ = await updatePermissions(using: .accessibilityRequest)
            await requestScreenRecordingPermissionFromHost()
        }
    }

    /// The copy macOS has to grant. Several copies can share one bundle id, so a
    /// grant made to another one looks enabled in System Settings but does not apply.
    var runningAppPath: String {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Clears the grants recorded for Action's bundle ids, then asks again, so the
    /// prompt binds to this copy. This is the way out when Settings shows Action
    /// enabled for a copy signed differently.
    func resetPermissionsAndRequest() {
        Task {
            let bundleIds = [Bundle.main.bundleIdentifier ?? ActionAppIdentity.mainBundleIdentifier,
                             ActionAppIdentity.agentBundleIdentifier]
            for service in ["Accessibility", "ScreenCapture"] {
                for bundleId in bundleIds {
                    await Self.runTCCReset(service: service, bundleId: bundleId)
                }
            }
            _ = await updatePermissions(using: .accessibilityRequest)
            await requestScreenRecordingPermissionFromHost()
        }
    }

    private nonisolated static func runTCCReset(service: String, bundleId: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleId]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    func requestAccessibilityPermission() {
        Task {
            _ = await updatePermissions(using: .accessibilityRequest)
        }
    }

    func requestScreenRecordingPermission() {
        Task {
            await requestScreenRecordingPermissionFromHost()
        }
    }

    func openAccessibilitySettings() {
        Task {
            await openSettingsViaAgent(.openAccessibilitySettings)
        }
    }

    func openScreenRecordingSettings() {
        Task {
            await openSettingsViaAgent(.openScreenRecordingSettings)
        }
    }

    /// Where this checkout lives. Home builds the MCP setup snippet against it
    /// so the line an operator copies is correct for their machine rather than
    /// for the path the docs happen to use.
    var repositoryRoot: URL {
        repositoryRootURL()
    }

    /// Copies the line that registers Action's native runtime MCP with an agent.
    func copyMCPSetupCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ActionMCPSetup.command(root: repositoryRoot), forType: .string)
    }

    /// Signals every live drive to stop and hand the Mac back.
    ///
    /// This is the same path the supervision overlay's stop control takes: it
    /// writes the stop markers the drivers poll. It asks rather than kills, so a
    /// driver mid-act finishes that act and then releases.
    func stopAllDrives() {
        let stopped = ActionSupervisionRegistry.triggerStopAll()
        logger.log("home: requested stop for \(stopped) supervised drive(s)")
    }

    func openScenariosFolder() {
        let scenariosURL = repositoryRoot.appendingPathComponent("scenarios", isDirectory: true)
        NSWorkspace.shared.open(scenariosURL)
    }

    func runGuidedCalculatorDemo() {
        runGuidedCalculatorDemo(forScenarioID: nil)
    }

    /// Draft a Calculator scenario and open Edit.
    func startCalculatorScenario(goal: String? = nil) {
        let scenario = ActionScenarioPresets.makeCalculatorScenario(goal: goal ?? scenarioDraftGoal)
        do {
            try ActionScenarioStore.shared.save(scenario)
            refreshScenarios()
            selectedScenarioID = scenario.id
            selectedScenarioStepID = scenario.steps.first?.id
            setFlowPhase(.edit)
            workspaceNavigationRequestID = UUID()
            guidedDemoStatus = "Scenario drafted — review steps, then run"
        } catch {
            guidedDemoStatus = "Failed to create scenario: \(error.localizedDescription)"
            logger.error("Create scenario failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectScenario(_ scenario: ActionScenarioDocument, preferTake: Bool = false) {
        selectedScenarioID = scenario.id
        selectedScenarioStepID = scenario.steps.first?.id
        if let latest = scenario.latestSessionId {
            selectedSessionID = latest
        }
        // Open on plan by default; prefer take when jumping from a capture.
        if preferTake, scenario.latestSessionId != nil || !scenario.sessionIds.isEmpty {
            setFlowPhase(.review)
        } else if scenario.phase == .review, scenario.latestSessionId == nil {
            setFlowPhase(.edit)
        }
    }

    func deleteScenario(_ scenario: ActionScenarioDocument) {
        try? ActionScenarioStore.shared.delete(id: scenario.id)
        if selectedScenarioID == scenario.id {
            selectedScenarioID = nil
            selectedScenarioStepID = nil
        }
        refreshScenarios()
        guidedDemoStatus = "Scenario deleted"
    }

    func setFlowPhase(_ phase: ActionFlowPhase) {
        guard var scenario = selectedScenario else { return }
        scenario.phase = phase
        persistScenario(scenario)

        if phase == .review, let sessionId = scenario.latestSessionId {
            selectedSessionID = sessionId
            reviewSelectionRequestID = UUID()
        }
    }

    func selectScenarioStep(_ step: ActionScenarioStep) {
        selectedScenarioStepID = step.id
    }

    func toggleSkipScenarioStep(_ stepID: String) {
        guard var scenario = selectedScenario,
              let index = scenario.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let current = scenario.steps[index].status
        scenario.steps[index].status = current == "skipped" ? "pending" : "skipped"
        persistScenario(scenario)
    }

    func addFeedbackToSelectedScenarioStep() {
        let text = scenarioStepFeedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              var scenario = selectedScenario,
              let stepID = selectedScenarioStepID,
              let index = scenario.steps.firstIndex(where: { $0.id == stepID }) else { return }

        let item = ActionScenarioStepFeedback(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            instruction: text
        )
        scenario.steps[index].feedback.append(item)
        if scenario.steps[index].status == "pending" {
            scenario.steps[index].status = "flagged"
        }
        scenarioStepFeedbackDraft = ""
        persistScenario(scenario)
        guidedDemoStatus = "Feedback saved on step \(scenario.steps[index].index)"
    }

    func approveAndRunSelectedScenario() {
        guard let scenario = selectedScenario else {
            runGuidedCalculatorDemo(forScenarioID: nil)
            return
        }
        // Stay on plan while running; success flips to last take.
        guidedDemoStatus = "Running “\(scenario.title)”…"
        runGuidedCalculatorDemo(forScenarioID: scenario.id)
    }

    func refreshScenarios() {
        scenarios = ActionScenarioStore.shared.loadAll()
        if let selectedScenarioID, scenarios.contains(where: { $0.id == selectedScenarioID }) {
            self.selectedScenarioID = selectedScenarioID
        } else {
            self.selectedScenarioID = scenarios.first?.id
        }
        if let scenario = selectedScenario {
            if let selectedScenarioStepID, scenario.steps.contains(where: { $0.id == selectedScenarioStepID }) {
                self.selectedScenarioStepID = selectedScenarioStepID
            } else {
                selectedScenarioStepID = scenario.steps.first?.id
            }
        } else {
            selectedScenarioStepID = nil
        }
    }

    func deleteSelectedScenario() {
        guard let id = selectedScenarioID else { return }
        try? ActionScenarioStore.shared.delete(id: id)
        if selectedScenarioID == id {
            selectedScenarioID = nil
        }
        refreshScenarios()
    }

    private func persistScenario(_ scenario: ActionScenarioDocument) {
        do {
            try ActionScenarioStore.shared.save(scenario)
            if let index = scenarios.firstIndex(where: { $0.id == scenario.id }) {
                scenarios[index] = scenario
            } else {
                scenarios.insert(scenario, at: 0)
            }
            selectedScenarioID = scenario.id
        } catch {
            guidedDemoStatus = "Failed to save scenario: \(error.localizedDescription)"
            logger.error("Save scenario failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runGuidedCalculatorDemo(forScenarioID scenarioID: String?) {
        guard !isRunningGuidedDemo else {
            return
        }

        isRunningGuidedDemo = true
        guidedDemoStatus = "Running guided capture…"

        Task {
            do {
                if let result = try await launchGuidedDemo() {
                    guidedDemoStatus = "Completed \(result.expression) = \(result.actualResult)"
                    refreshSessions()
                    selectedSessionID = result.sessionId

                    if let scenarioID,
                       var scenario = scenarios.first(where: { $0.id == scenarioID })
                        ?? ActionScenarioStore.shared.loadAll().first(where: { $0.id == scenarioID }) {
                        if !scenario.sessionIds.contains(result.sessionId) {
                            scenario.sessionIds.insert(result.sessionId, at: 0)
                        }
                        scenario.latestSessionId = result.sessionId
                        scenario.lastRunStatus = "completed"
                        scenario.phase = .review
                        scenario.title = "Calculator · \(result.expression)"
                        persistScenario(scenario)
                        selectedScenarioID = scenario.id
                        workspaceNavigationRequestID = UUID()
                        reviewSelectionRequestID = UUID()
                    }
                } else {
                    guidedDemoStatus = "Cancelled"
                    if let scenarioID, var scenario = scenarios.first(where: { $0.id == scenarioID }) {
                        scenario.lastRunStatus = "cancelled"
                        persistScenario(scenario)
                    }
                }
            } catch {
                guidedDemoStatus = "Failed: \(error.localizedDescription)"
                logger.error("Guided calculator demo failed: \(error.localizedDescription, privacy: .public)")
                if let scenarioID, var scenario = scenarios.first(where: { $0.id == scenarioID }) {
                    scenario.lastRunStatus = "failed"
                    persistScenario(scenario)
                }
            }
            isRunningGuidedDemo = false
            refreshScenarios()
        }
    }

    func refreshSessions() {
        recentSessions = loadRecentSessions()
        if let selectedSessionID, recentSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            self.selectedSessionID = recentSessions.first?.id
        }
        if recentSessions.isEmpty {
            guidedDemoStatus = isRunningGuidedDemo ? guidedDemoStatus : "No recorded sessions yet"
        }
    }

    func selectSession(_ session: ActionSessionSummary) {
        selectedSessionID = session.id
        focusedFeedbackItemID = nil
    }

    func revealLauncher(to destination: ActionLauncherDestination) {
        launcherDestination = destination
        launcherDestinationRequestID = UUID()
    }

    func revealScenarioInLauncher(_ scenario: ActionScenarioDocument) {
        selectScenario(scenario)
        revealLauncher(to: .scenarios)
    }

    func runScenarioFromLauncher(_ scenario: ActionScenarioDocument) {
        selectScenario(scenario)
        revealLauncher(to: .scenarios)
        approveAndRunSelectedScenario()
    }

    func revealSessionInLauncher(_ session: ActionSessionSummary) {
        selectSession(session)
        if let scenario = scenarios.first(where: {
            $0.latestSessionId == session.sessionId
                || $0.sessionIds.contains(session.sessionId)
                || $0.latestSessionId == session.id
                || $0.sessionIds.contains(session.id)
        }) {
            selectScenario(scenario)
            setFlowPhase(.review)
            revealLauncher(to: .scenarios)
        } else if session.kind == .capture {
            revealLauncher(to: .library)
        } else {
            revealLauncher(to: .runs)
        }
    }

    func replaySession(_ session: ActionSessionSummary) {
        if FileManager.default.fileExists(atPath: session.videoURL.path) {
            NSWorkspace.shared.open(session.videoURL)
            return
        }
        revealSession(session)
    }

    func revealSession(_ session: ActionSessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([session.artifactDirectoryURL])
    }

    func openSessionTrace(_ session: ActionSessionSummary) {
        NSWorkspace.shared.open(session.traceURL)
    }

    func openSessionFeedback(_ session: ActionSessionSummary) {
        guard FileManager.default.fileExists(atPath: session.feedbackURL.path) else {
            return
        }
        NSWorkspace.shared.open(session.feedbackURL)
    }

    func openAgentFeedbackMarkdown(_ session: ActionSessionSummary) throws {
        try writeAgentFeedbackArtifacts(for: session)
        NSWorkspace.shared.open(session.agentFeedbackMarkdownURL)
    }

    func openAgentFeedbackJSON(_ session: ActionSessionSummary) throws {
        try writeAgentFeedbackArtifacts(for: session)
        NSWorkspace.shared.open(session.agentFeedbackJSONURL)
    }

    func copyAgentFeedbackMarkdown(_ session: ActionSessionSummary) throws {
        try writeAgentFeedbackArtifacts(for: session)
        let value = try String(contentsOf: session.agentFeedbackMarkdownURL, encoding: .utf8)
        copyToPasteboard(value)
    }

    func copyAgentFeedbackJSON(_ session: ActionSessionSummary) throws {
        try writeAgentFeedbackArtifacts(for: session)
        let value = try String(contentsOf: session.agentFeedbackJSONURL, encoding: .utf8)
        copyToPasteboard(value)
    }

    func copyAgentFeedbackLink(_ session: ActionSessionSummary, feedbackItemId: String? = nil) throws {
        let token = try ActionSessionLinkStore.shared.register(session: session, feedbackItemId: feedbackItemId)
        copyToPasteboard("action://r/\(token)")
    }

    func handleIncomingDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "action" else {
            return
        }

        let token: String
        if url.host()?.lowercased() == "r" {
            token = url.pathComponents.dropFirst().first ?? ""
        } else {
            token = url.host() ?? ""
        }

        guard !token.isEmpty else {
            return
        }

        do {
            guard let target = try ActionSessionLinkStore.shared.resolve(token: token),
                  let session = try loadSession(at: URL(fileURLWithPath: target.artifactDirectoryPath, isDirectory: true)) else {
                notes.append("deepLinkMissing=\(token)")
                return
            }

            if !recentSessions.contains(where: { $0.id == session.id }) {
                recentSessions.insert(session, at: 0)
            }
            selectedSessionID = session.id
            focusedFeedbackItemID = target.feedbackItemId
            reviewSelectionRequestID = UUID()
        } catch {
            notes.append("deepLinkError=\(error.localizedDescription)")
        }
    }

    func openSessionScreenshot(_ session: ActionSessionSummary) {
        if let resultScreenshotURL = session.resultScreenshotURL {
            NSWorkspace.shared.open(resultScreenshotURL)
        } else if let stageScreenshotURL = session.stageScreenshotURL {
            NSWorkspace.shared.open(stageScreenshotURL)
        }
    }

    /// Permanently removes a session's artifact directory from disk.
    /// Clears the run ledger through the agent, which owns it and knows which
    /// sessions are still driving.
    func clearSessions() async {
        do {
            let response = try await agentClient.send(method: .sessionsClear)
            if !response.ok {
                logger.error("Clear runs failed: \(response.error ?? "unknown", privacy: .public)")
            }
        } catch {
            logger.error("Clear runs failed: \(error.localizedDescription, privacy: .public)")
        }
        // Runs from before the agent kept the ledger sit in the checkout's
        // artifacts folder; nothing writes there any more, so a finished one
        // goes with the rest.
        let legacyRoot = artifactsSessionsDirectoryURL().standardizedFileURL.path
        for session in recentSessions
            where session.artifactDirectoryURL.standardizedFileURL.path.hasPrefix(legacyRoot + "/")
                && session.state != "driving" {
            try? FileManager.default.removeItem(at: session.artifactDirectoryURL)
        }
        selectedSessionID = nil
        focusedFeedbackItemID = nil
        refreshSessions()
    }

    func deleteSession(_ session: ActionSessionSummary) throws {
        try FileManager.default.removeItem(at: session.artifactDirectoryURL)
        if selectedSessionID == session.id {
            selectedSessionID = nil
            focusedFeedbackItemID = nil
        }
        refreshSessions()
        logger.notice("Deleted session \(session.sessionId, privacy: .public)")
    }

    var selectedSession: ActionSessionSummary? {
        if let selectedSessionID,
           let selected = recentSessions.first(where: { $0.id == selectedSessionID }) {
            return selected
        }
        return recentSessions.first
    }

    func startAgent() {
        do {
            try agentProcess.startIfNeeded()
            Task {
                await refreshAgentStatus()
                await refreshPermissionsViaAgent()
            }
        } catch {
            agentStatus = "Failed to start agent"
            notes = ["agentError=\(error.localizedDescription)"]
        }
    }

    func stopAgent() {
        agentProcess.stopIfNeeded()
    }

    func setAppearanceMode(_ mode: ActionAppearanceMode) {
        appearanceMode = mode
        ActionAppearanceStore.shared.mode = mode
    }

    private func repositoryRootURL() -> URL {
        let bundleCandidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: bundleCandidate.appendingPathComponent("package.json").path) {
            return bundleCandidate
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("package.json").path) {
            return cwd
        }

        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func refreshAgentStatus() async {
        do {
            let response = try await agentClient.send(method: .status)
            if response.ok {
                agentStatus = "Connected"
                if let result = response.result {
                    var updatedNotes = notes.filter { !$0.hasPrefix("agent") }
                    updatedNotes.append("agentPid=\(result["pid"] ?? "unknown")")
                    updatedNotes.append("agentMethods=\(result["methods"] ?? "")")
                    notes = updatedNotes
                }
            } else {
                agentStatus = response.error ?? "Agent error"
            }
        } catch {
            agentStatus = "Disconnected"
            logger.error("Agent status failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshPermissionsViaAgent() async {
        _ = await updatePermissions(using: .permissionsSnapshot)
    }

    private func requestScreenRecordingPermissionFromHost() async {
        _ = await actionRequestScreenRecordingAccess()
        _ = await updatePermissions(using: .permissionsSnapshot)
    }

    @discardableResult
    private func updatePermissions(using method: ActionAgentMethod) async -> Bool {
        do {
            let response = try await agentClient.send(method: method)
            if let result = response.result {
                let bundleId = result["bundleId"] ?? "unknown"
                let bundlePath = result["bundlePath"] ?? "unknown"
                var updatedNotes = notes.filter {
                    !$0.hasPrefix("agentBundleId=")
                        && !$0.hasPrefix("agentBundlePath=")
                        && !$0.hasPrefix("agentIdentityError=")
                }
                updatedNotes.append("agentBundleId=\(bundleId)")
                updatedNotes.append("agentBundlePath=\(bundlePath)")

                let receivedBundlePath = URL(fileURLWithPath: bundlePath)
                    .resolvingSymlinksInPath()
                    .path
                if let expectedAgentBundlePath,
                   bundleId != ActionAppIdentity.agentBundleIdentifier
                       || receivedBundlePath != expectedAgentBundlePath {
                    accessibilityStatus = "Unknown"
                    screenRecordingStatus = "Unknown"
                    agentStatus = "Agent instance mismatch"
                    updatedNotes.append(
                        "agentIdentityError=Expected \(ActionAppIdentity.agentBundleIdentifier) at \(expectedAgentBundlePath); received \(bundleId) at \(receivedBundlePath). Quit older Action copies, then reopen Action."
                    )
                    notes = updatedNotes
                    agentProcess.stopIfNeeded()
                    logger.error(
                        "Rejected ActionAgent \(bundleId, privacy: .public) at \(receivedBundlePath, privacy: .public); expected \(ActionAppIdentity.agentBundleIdentifier, privacy: .public) at \(expectedAgentBundlePath, privacy: .public)"
                    )
                    return false
                }

                accessibilityStatus = (result["accessibility"] ?? "unknown").capitalized
                screenRecordingStatus = (result["screenRecording"] ?? "unknown").capitalized
                clearPermissionRegrantMarkerIfComplete()
                notes = updatedNotes
                agentStatus = "Connected"
                return true
            } else {
                agentStatus = response.error ?? "Agent error"
                return false
            }
        } catch {
            agentStatus = "Disconnected"
            logger.error("Agent permissions call failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func clearPermissionRegrantMarkerIfComplete() {
        ActionPreferenceMigration.completePermissionRegrantIfReady(
            accessibilityGranted: accessibilityStatus.lowercased() == "granted",
            screenRecordingGranted: screenRecordingStatus.lowercased() == "granted"
        )
    }

    private func openSettingsViaAgent(_ method: ActionAgentMethod) async {
        guard await updatePermissions(using: .permissionsSnapshot) else {
            return
        }

        do {
            _ = try await agentClient.send(method: method)
            agentStatus = "Connected"
        } catch {
            agentStatus = "Disconnected"
            logger.error("Agent settings call failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sessionsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Action/sessions", isDirectory: true)
    }

    func loadFeedback(for session: ActionSessionSummary) -> ActionSessionFeedbackDocument {
        let feedbackURL = session.feedbackURL
        guard let data = try? Data(contentsOf: feedbackURL),
              let document = try? JSONDecoder().decode(ActionSessionFeedbackDocument.self, from: data) else {
            return .empty(for: session.sessionId)
        }
        return document
    }

    func saveFeedback(_ document: ActionSessionFeedbackDocument, for session: ActionSessionSummary) throws {
        var updatedDocument = document
        updatedDocument.updatedAt = ISO8601DateFormatter().string(from: Date())
        let data = try JSONEncoder.pretty.encode(updatedDocument)
        try data.write(to: session.feedbackURL, options: .atomic)
        try writeAgentFeedbackArtifacts(updatedDocument, for: session)
        refreshSessions()
    }

    private func writeAgentFeedbackArtifacts(for session: ActionSessionSummary) throws {
        try writeAgentFeedbackArtifacts(loadFeedback(for: session), for: session)
    }

    private func writeAgentFeedbackArtifacts(_ document: ActionSessionFeedbackDocument, for session: ActionSessionSummary) throws {
        let export = document.agentExport(for: session)
        let exportData = try JSONEncoder.pretty.encode(export)
        try exportData.write(to: session.agentFeedbackJSONURL, options: .atomic)
        try document.agentMarkdown(for: session).write(to: session.agentFeedbackMarkdownURL, atomically: true, encoding: .utf8)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func artifactsSessionsDirectoryURL() -> URL {
        repositoryRootURL().appendingPathComponent("artifacts/sessions", isDirectory: true)
    }

    private func runInventoryURL() -> URL {
        let directory = sessionsDirectoryURL().deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("runs.json")
    }

    private func loadRecentSessions(limit: Int = 400) -> [ActionSessionSummary] {
        let roots = [sessionsDirectoryURL(), artifactsSessionsDirectoryURL()]
        var seen = Set<String>()
        var loaded: [ActionSessionSummary] = []

        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory, let session = try? loadSession(at: url) else {
                    continue
                }
                if seen.insert(session.id).inserted {
                    loaded.append(session)
                }
            }
        }

        // Sort on the same date the Runs ledger groups and prints. Sorting by
        // finish while displaying start left the time column non-monotonic
        // (12:36, 12:31, 12:34), which reads as a broken list.
        loaded.sort { lhs, rhs in
            let left = lhs.ledgerDate ?? .distantPast
            let right = rhs.ledgerDate ?? .distantPast
            return left > right
        }

        let sessions = Array(loaded.prefix(limit))
        persistRunInventory(sessions)
        return sessions
    }

    private func persistRunInventory(_ sessions: [ActionSessionSummary]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: String]] = sessions.map { session in
            var row: [String: String] = [
                "id": session.id,
                "kind": session.kind.rawValue,
                "title": session.displayTitle,
                "state": session.state,
                "outcome": session.outcome.rawValue,
                "path": session.artifactDirectoryURL.path,
            ]
            if !session.agent.isEmpty {
                row["agent"] = session.agent
            }
            if !session.client.isEmpty {
                row["client"] = session.client
            }
            if !session.subtitle.isEmpty {
                row["subtitle"] = session.subtitle
            }
            if let startedAt = session.startedAt {
                row["startedAt"] = formatter.string(from: startedAt)
            }
            if let finishedAt = session.finishedAt {
                row["updatedAt"] = formatter.string(from: finishedAt)
            }
            return row
        }
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: Date()),
            "count": sessions.count,
            "runs": entries,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: runInventoryURL(), options: .atomic)
    }

    private func loadSession(at sessionURL: URL) throws -> ActionSessionSummary? {
        if let capture = try loadCaptureSession(at: sessionURL) {
            return capture
        }
        return try loadPersistedRuntimeSession(at: sessionURL)
    }

    private func loadCaptureSession(at sessionURL: URL) throws -> ActionSessionSummary? {
        let isoFormatter = ISO8601DateFormatter()
        let traceURL = sessionURL.appendingPathComponent("trace.json")
        let feedbackURL = sessionURL.appendingPathComponent("feedback.json")
        guard let data = try? Data(contentsOf: traceURL),
              let trace = try? JSONDecoder().decode(ActionSessionTrace.self, from: data) else {
            return nil
        }

        let screenshots = trace.screenshots.map(URL.init(fileURLWithPath:))
        let stageScreenshotURL = screenshots.first(where: { $0.lastPathComponent == "stage.png" }) ?? screenshots.first
        let resultScreenshotURL = screenshots.first(where: { $0.lastPathComponent == "result.png" })
        let feedbackCount = ((try? Data(contentsOf: feedbackURL))
            .flatMap { try? JSONDecoder().decode(ActionSessionFeedbackDocument.self, from: $0) })?.items.count ?? 0
        let startedAt = isoFormatter.date(from: trace.startedAt)
        let finishedAt = isoFormatter.date(from: trace.finishedAt)
        let videoURL = URL(fileURLWithPath: trace.videoPath)
        let durationSeconds = Self.resolveDurationSeconds(
            videoURL: videoURL,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        return ActionSessionSummary(
            id: trace.sessionId,
            sessionId: trace.sessionId,
            kind: .capture,
            artifactDirectoryURL: sessionURL,
            videoURL: videoURL,
            traceURL: traceURL,
            feedbackURL: feedbackURL,
            stageScreenshotURL: stageScreenshotURL,
            resultScreenshotURL: resultScreenshotURL,
            expression: trace.expression,
            expectedResult: trace.expectedResult,
            actualResult: trace.actualResult,
            startedAt: startedAt,
            finishedAt: finishedAt,
            feedbackCount: feedbackCount,
            durationSeconds: durationSeconds,
            label: trace.expression,
            subtitle: trace.actualResult.isEmpty ? "Capture" : "= \(trace.actualResult)",
            state: "completed",
            agent: "",
            client: "",
            outcome: .ok
        )
    }

    private func loadPersistedRuntimeSession(at sessionURL: URL) throws -> ActionSessionSummary? {
        let recordURL = sessionURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(PersistedSessionRecord.self, from: data) else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parseDate(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            return fractional.date(from: raw) ?? isoFormatter.date(from: raw)
        }

        let kind: ActionRunKind
        if record.mode == "inspection" || sessionURL.lastPathComponent.hasPrefix("inspection") {
            kind = .inspection
        } else if record.drive != nil || record.driveLeaseId != nil || sessionURL.lastPathComponent.hasPrefix("drive_") {
            kind = .drive
        } else {
            kind = .capture
        }

        let agentName = record.drive?.agent?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? ""
        let label: String
        let subtitle: String
        switch kind {
        case .drive:
            label = record.drive?.task?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? record.drive?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Drive"
            let outcome = (record.drive?.outcome ?? record.drive?.status ?? record.state ?? "completed")
            subtitle = [agentName.nilIfEmpty, outcome].compactMap { $0 }.joined(separator: " · ")
        case .inspection:
            label = record.targetApp.map { "Inspect \($0)" } ?? "Inspection"
            subtitle = record.state ?? record.phase ?? "inspection"
        case .capture:
            label = record.id
            subtitle = record.state ?? "capture"
        }

        let resolvedState = record.drive?.outcome ?? record.drive?.status ?? record.state ?? ""
        let snapshot = sessionURL.appendingPathComponent("snapshot.png")
        let stage = sessionURL.appendingPathComponent("stage.png")
        let result = sessionURL.appendingPathComponent("result.png")
        let startedAt = parseDate(record.drive?.startedAt) ?? parseDate(record.createdAt)
        let finishedAt = parseDate(record.drive?.releasedAt) ?? parseDate(record.updatedAt)
        let videoCandidates = ["capture.mov", "session.mov", "recording.mov"]
            .map { sessionURL.appendingPathComponent($0) }
        let videoURL = videoCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? sessionURL.appendingPathComponent("capture.mov")
        let traceURL = sessionURL.appendingPathComponent(
            FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent("drive-trace.json").path)
                ? "drive-trace.json"
                : "trace.json"
        )
        let durationSeconds = Self.resolveDurationSeconds(
            videoURL: videoURL,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        return ActionSessionSummary(
            id: record.id,
            sessionId: record.id,
            kind: kind,
            artifactDirectoryURL: sessionURL,
            videoURL: videoURL,
            traceURL: traceURL,
            feedbackURL: sessionURL.appendingPathComponent("feedback.json"),
            stageScreenshotURL: FileManager.default.fileExists(atPath: stage.path) ? stage : (
                FileManager.default.fileExists(atPath: snapshot.path) ? snapshot : nil
            ),
            resultScreenshotURL: FileManager.default.fileExists(atPath: result.path) ? result : (
                FileManager.default.fileExists(atPath: snapshot.path) ? snapshot : nil
            ),
            expression: label,
            expectedResult: "",
            actualResult: record.drive?.summary ?? "",
            startedAt: startedAt,
            finishedAt: finishedAt,
            feedbackCount: 0,
            durationSeconds: durationSeconds,
            label: label,
            subtitle: subtitle,
            state: resolvedState,
            agent: agentName,
            client: [record.drive?.client, record.drive?.clientProcess]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: " · "),
            // `finishedAt` is a release for a closed run and the last heartbeat
            // for an open one — either way it is the freshest thing the run said.
            outcome: ActionRunOutcome(state: resolvedState, lastActivity: finishedAt ?? startedAt)
        )
    }

    private static func resolveDurationSeconds(
        videoURL: URL,
        startedAt: Date?,
        finishedAt: Date?
    ) -> Double? {
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        }
        if let startedAt, let finishedAt {
            let wall = finishedAt.timeIntervalSince(startedAt)
            if wall.isFinite, wall > 0 {
                return wall
            }
        }
        return nil
    }

    private func launchGuidedDemo() async throws -> GuidedCaptureLauncherResult? {
        let replyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-guided-demo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: replyURL) }

        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", bundlePath,
            "--args",
            "guided-calculator-demo",
            "--reply-file", replyURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "ActionLauncher",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to launch guided calculator demo"]
            )
        }

        for _ in 0..<300 {
            if let data = try? Data(contentsOf: replyURL), !data.isEmpty {
                if let response = try? JSONDecoder().decode(ActionHostResponse.self, from: data) {
                    if response.status == "cancelled" {
                        return nil
                    }
                    if response.status == "error" {
                        throw NSError(
                            domain: "ActionLauncher",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: response.detail ?? "Guided demo failed"]
                        )
                    }
                }

                return try JSONDecoder().decode(GuidedCaptureLauncherResult.self, from: data)
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        throw NSError(
            domain: "ActionLauncher",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Guided demo did not write a reply file"]
        )
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    func quotedForShell() -> String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
