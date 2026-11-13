import AppKit
import SwiftUI

/// Home, as a computer-use console.
///
/// The reading order is deliberate and is the whole argument of the screen:
/// *who is driving this Mac right now* → *how an agent gets in* → *what it can
/// ask for* → *what it did*. Recording is one of the things an agent can ask
/// for, not the frame around everything else — Action is a computer-use module
/// that happens to be able to record, and Home has to say that before it says
/// anything about takes.
struct ActionHomeView: View {
    @ObservedObject var model: ActionLauncherViewModel

    let onOpenRuns: () -> Void
    let onOpenSession: (ActionSessionSummary) -> Void
    let onNewScenario: () -> Void

    /// Drives the elapsed clock and picks up a lease the moment one is taken.
    /// A second is the coarsest tick that still lets `00:47` be true.
    private let leaseTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// The ledger is a week-wide tally; re-reading it every second would burn a
    /// file scan to move a number that changes a few times an hour.
    private let countsTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    @State private var lease: ActionHomeLease?
    @State private var beat: String?
    @State private var counts: ActionToolCounts = .empty
    @State private var didCopyCommand = false
    @State private var copyResetTask: Task<Void, Never>?
    /// The run whose row is showing its context. One at a time — the panel is
    /// four rows tall by design, and two open rows would push it past the fold.
    @State private var expandedSessionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            leasePanel
            connectPanel
            actionsPanel
            activityPanel
        }
        .onAppear {
            refreshLease()
            refreshCounts()
        }
        .onReceive(leaseTick) { _ in refreshLease() }
        .onReceive(countsTick) { _ in refreshCounts() }
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: - Who is driving

    @ViewBuilder
    private var leasePanel: some View {
        if let lease {
            drivingPanel(lease)
        }
    }

    private func drivingPanel(_ lease: ActionHomeLease) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    liveDot
                    eyebrow("DRIVING", tint: StageHUDTheme.fieldAccent)
                    Text("lease \(lease.shortID) · \(lease.mode)")
                        .font(ActionType.code)
                        .tracking(0.2)
                        .foregroundStyle(StageHUDTheme.fieldDeepMeta)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(lease.agent)
                        .font(ActionType.panelLead)
                        .foregroundStyle(StageHUDTheme.fieldDeepText)
                    Text(lease.task)
                        .font(ActionType.uiBodyStrong)
                        .foregroundStyle(StageHUDTheme.fieldDeepMeta)
                        .lineLimit(1)
                }

                // The supervisor's own words for what this drive is doing, not a
                // second guess at it. Absent until the driver has said something.
                Text(beat ?? "waiting for the next beat")
                    .font(ActionType.code)
                    .foregroundStyle(StageHUDTheme.fieldDeepMeta)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if lease.pointerControl {
                        deepChip("POINTER CONTROL", filled: true)
                    }
                    if lease.showSupervisionLabel {
                        deepChip("SUPERVISION LABEL", filled: true)
                    }
                    deepChip(model.isRunningGuidedDemo ? "RECORDING" : "RECORDING OFF", filled: model.isRunningGuidedDemo)
                }
                .padding(.top, 3)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 10) {
                Text(lease.formattedElapsed)
                    .font(ActionType.display)
                    .foregroundStyle(StageHUDTheme.fieldDeepText)
                    .monospacedDigit()

                Button {
                    model.stopAllDrives()
                    refreshLease()
                } label: {
                    Text("TAKE BACK")
                        .font(ActionType.label)
                        .tracking(ActionType.labelTracking)
                        .foregroundStyle(StageHUDTheme.fieldAccentText)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StageHUDTheme.fieldAccent)
                        )
                }
                .buttonStyle(.plain)
                .help("Stop every active drive")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(deepPanelBackground)
    }

    private var liveDot: some View {
        Circle()
            .strokeBorder(StageHUDTheme.fieldAccent, lineWidth: 1)
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .fill(StageHUDTheme.fieldAccent)
                    .frame(width: 6, height: 6)
            )
    }

    // MARK: - How an agent gets in

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                eyebrow("CONNECT AN AGENT", tint: StageHUDTheme.fieldInkSecondary)
                Spacer(minLength: 8)
                Text("MCP · STDIO")
                    .font(ActionType.labelRegular)
                    .tracking(ActionType.labelTracking)
                    .foregroundStyle(StageHUDTheme.fieldInkMeta)
                copyButton
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(commandLines.enumerated()), id: \.offset) { index, line in
                    commandLine(line, isFirst: index == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StageHUDTheme.fieldDeep)
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .background(fieldPanelBackground)
    }

    private var commandLines: [String] {
        ActionMCPSetup.commandLines(root: model.repositoryRoot)
    }

    /// The server name is the one token an operator must not mistype, so it is
    /// the one token that gets the accent.
    @ViewBuilder
    private func commandLine(_ line: String, isFirst: Bool) -> some View {
        let font = ActionType.code
        if isFirst, let range = line.range(of: " \(ActionMCPSetup.serverName) ") {
            (
                Text(String(line[line.startIndex..<range.lowerBound]) + " ")
                    .foregroundStyle(StageHUDTheme.fieldDeepText)
                    + Text(ActionMCPSetup.serverName)
                    .foregroundStyle(StageHUDTheme.fieldAccent)
                    + Text(" " + String(line[range.upperBound...]))
                    .foregroundStyle(StageHUDTheme.fieldDeepText)
            )
            .font(font)
            .lineLimit(1)
        } else {
            Text(line)
                .font(font)
                .foregroundStyle(isFirst ? StageHUDTheme.fieldDeepText : StageHUDTheme.fieldDeepMeta)
                .lineLimit(1)
        }
    }

    private var copyButton: some View {
        Button {
            model.copyMCPSetupCommand()
            didCopyCommand = true
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                didCopyCommand = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                    .font(ActionIcon.micro)  // SF Symbol: sized to the label beside it
                Text(didCopyCommand ? "COPIED" : "COPY")
                    .font(ActionType.label)
                    .tracking(ActionType.labelTracking)
            }
            // Ink, not coral. Coral means a drive is live; a clipboard button
            // wearing it borrows the one signal the app cannot afford to spend
            // on chrome. It turns coral for the two seconds it says COPIED,
            // where the colour is a change of state rather than a decoration.
            .foregroundStyle(didCopyCommand ? StageHUDTheme.fieldAccent : StageHUDTheme.fieldInkSecondary)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        didCopyCommand
                            ? StageHUDTheme.fieldAccent
                            : StageHUDTheme.fieldInk.opacity(0.22),
                        lineWidth: StageHUDTheme.hairline
                    )
            )
            .animation(.easeOut(duration: 0.15), value: didCopyCommand)
        }
        .buttonStyle(.plain)
        .help("Copy the MCP setup command")
    }

    // MARK: - What it can ask for

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                eyebrow("ACTIONS", tint: StageHUDTheme.fieldInkSecondary)
                Text(actionsSubtitle)
                    .font(ActionType.uiBody)
                    .foregroundStyle(StageHUDTheme.fieldInkMuted)
                Spacer(minLength: 8)
            }

            HStack(alignment: .top, spacing: 26) {
                ForEach(counts.groups) { group in
                    actionColumn(group)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .background(fieldPanelBackground)
    }

    /// With an empty ledger the counts column would be a wall of zeros reading
    /// as "this does not work", so the label says the counts are the week's
    /// rather than leaving them to be read as all-time.
    private var actionsSubtitle: String {
        counts.hasData ? "this week" : "none this week"
    }

    /// The four columns had four different coloured ticks beside their names —
    /// coral, cyan, tan, ink — and the colours encoded nothing: the group's
    /// name is right there, and no other surface in the app uses those hues to
    /// mean those families. Four hues in one panel, for decoration, on a page
    /// whose one meaningful colour is the coral that means a live drive. The
    /// name over its rule is the header.
    private func actionColumn(_ group: ActionToolGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title.uppercased())
                .font(ActionType.label)
                .tracking(ActionType.labelTracking)
                .foregroundStyle(StageHUDTheme.fieldInkSecondary)
                .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StageHUDTheme.fieldPanelEdge)
                    .frame(height: 1)
            }

            ForEach(group.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name)
                        .font(ActionType.meta)
                        .foregroundStyle(StageHUDTheme.fieldInk)
                    Rectangle()
                        .fill(StageHUDTheme.fieldPanelEdge)
                        .frame(height: 1)
                    Text(counts.hasData ? "\(item.count)" : "—")
                        .font(ActionType.code)
                        .foregroundStyle(StageHUDTheme.fieldInkMeta)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - What it did

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                eyebrow("RECENT ACTIVITY", tint: StageHUDTheme.fieldInkSecondary)
                Text(activityTally)
                    .font(ActionType.labelRegular)
                    .tracking(ActionType.labelTracking)
                    .foregroundStyle(StageHUDTheme.fieldInkSecondary.opacity(0.7))
                Spacer(minLength: 8)
                Button(action: onOpenRuns) {
                    Text("OPEN RUNS →")
                        .font(ActionType.label)
                        .tracking(ActionType.labelTracking)
                        .foregroundStyle(StageHUDTheme.fieldAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StageHUDTheme.fieldPanelEdge)
                    .frame(height: 1)
            }

            if ledgerRows.isEmpty {
                emptyLedger
            } else {
                ForEach(Array(ledgerRows.enumerated()), id: \.element.id) { index, session in
                    ledgerRow(session, isLast: index == ledgerRows.count - 1)
                }
            }
        }
        .background(fieldPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Four, so the whole screen lands inside the default window without
    /// scrolling. Home is a glance surface; the fifth row belongs to Runs.
    private var ledgerRows: [ActionSessionSummary] {
        Array(model.recentSessions.prefix(4))
    }

    private var activityTally: String {
        let sessions = model.recentSessions
        guard !sessions.isEmpty else { return "NO RUNS YET" }
        let drive = sessions.filter { $0.kind == .drive }.count
        let inspect = sessions.filter { $0.kind == .inspection }.count
        let capture = sessions.filter { $0.kind == .capture }.count
        var parts = ["\(sessions.count) RUN\(sessions.count == 1 ? "" : "S")"]
        if drive > 0 { parts.append("\(drive) DRIVE") }
        if inspect > 0 { parts.append("\(inspect) INSPECT") }
        if capture > 0 { parts.append("\(capture) CAPTURE") }
        return parts.joined(separator: " · ")
    }

    private var emptyLedger: some View {
        HStack {
            Text("Nothing yet")
                .font(ActionType.uiBody)
                .foregroundStyle(StageHUDTheme.fieldInkMuted)
            Spacer(minLength: 8)
            Button(action: onNewScenario) {
                Text("NEW SCENARIO")
                    .font(ActionType.label)
                    .tracking(ActionType.labelTracking)
                    .foregroundStyle(StageHUDTheme.fieldAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    /// Clicking a row opens the row, not a window.
    ///
    /// A single click used to navigate straight out of Home — into Scenarios,
    /// or into Finder — which is a lot to happen from one click on a line of
    /// history you were only reading. The click now expands the row into what
    /// it is: when it ran, how long it took, who drove it, where it landed.
    /// Leaving is an explicit button, and a double-click still does what a
    /// double-click does everywhere on macOS.
    private func ledgerRow(_ session: ActionSessionSummary, isLast: Bool) -> some View {
        let expanded = expandedSessionID == session.id
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                outcomeDot(session.outcome)

                Text(session.displayTitle)
                    .font(session.isCalculatorTake ? ActionType.bodyMono : ActionType.uiBodyStrong)
                    .foregroundStyle(StageHUDTheme.fieldInkRow)
                    .lineLimit(1)
                    .frame(width: 300, alignment: .leading)

                Text(session.kind.title.uppercased())
                    .font(ActionType.label)
                    .tracking(ActionType.labelTracking)
                    .foregroundStyle(StageHUDTheme.fieldInkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(StageHUDTheme.fieldCanvas)
                    )
                    .frame(width: 62)

                Text(session.formattedDuration ?? "—")
                    .font(ActionType.meta)
                    .foregroundStyle(StageHUDTheme.fieldInkMeta)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)

                Spacer(minLength: 8)

                Text(relativeTimestamp(session))
                    .font(ActionType.meta)
                    .foregroundStyle(StageHUDTheme.fieldInkMeta)

                // Hidden once the row is open: the same word is a button in
                // the detail strip below, and printing it twice makes the
                // static label look like the thing you are meant to click.
                Text(expanded ? "" : destination(for: session))
                    .font(ActionType.label)
                    .tracking(ActionType.labelTracking)
                    .foregroundStyle(StageHUDTheme.fieldInkSecondary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(expanded ? StageHUDTheme.fieldInk.opacity(0.035) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpenSession(session) }
            // Local state only. Expanding a row to read it is not the same as
            // choosing it, and calling selectSession here left the Scenarios
            // page showing whichever take you had last glanced at on Home.
            .onTapGesture {
                expandedSessionID = expanded ? nil : session.id
            }

            if expanded {
                ledgerRowDetail(session)
            }
        }
        .animation(.easeOut(duration: 0.14), value: expanded)
        .overlay(alignment: .bottom) {
            // The card already draws a bottom edge; a row border under the last
            // row doubles it into a visibly thicker line.
            if !isLast {
                Rectangle()
                    .fill(StageHUDTheme.fieldPanelEdge)
                    .frame(height: 1)
            }
        }
    }

    /// The context the click earns: the facts that are not on the row, and the
    /// two places this run can be opened.
    private func ledgerRowDetail(_ session: ActionSessionSummary) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.sessionId)
                    .font(ActionType.monoCaption)
                    .foregroundStyle(StageHUDTheme.fieldInkMeta)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    detailFact("WHEN", absoluteTimestamp(session))
                    detailFact("BY", session.agent.isEmpty ? "—" : session.agent)
                    if !session.project.isEmpty {
                        detailFact("IN", session.project)
                    }
                    if !session.client.isEmpty {
                        detailFact("VIA", session.client)
                    }
                    detailFact("OUTCOME", session.outcome.title)
                    if session.feedbackCount > 0 {
                        detailFact("NOTES", "\(session.feedbackCount)")
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                fieldChipButton(destination(for: session)) { onOpenSession(session) }
                fieldChipButton("FINDER") { model.revealSession(session) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 13)
        .transition(.opacity)
    }

    private func detailFact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(ActionType.label)
                .tracking(ActionType.labelTracking)
                .foregroundStyle(StageHUDTheme.fieldInkMeta)
            Text(value)
                .font(ActionType.uiCaption)
                .foregroundStyle(StageHUDTheme.fieldInkRow)
                .lineLimit(1)
        }
    }

    /// The COPY button's shape, reused: mono label, hairline border, ink.
    private func fieldChipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ActionType.label)
                .tracking(ActionType.labelTracking)
                .foregroundStyle(StageHUDTheme.fieldInkSecondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(StageHUDTheme.fieldInk.opacity(0.22), lineWidth: StageHUDTheme.hairline)
                )
        }
        .buttonStyle(.plain)
    }

    private func absoluteTimestamp(_ session: ActionSessionSummary) -> String {
        guard let date = session.ledgerDate else {
            return "—"
        }
        return Self.absoluteFormatter.string(from: date)
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return formatter
    }()

    /// Mirrors the Runs ledger: an unfinished run is the one outcome nobody ever
    /// wrote down, so it reads as an open ring rather than spending a colour.
    private func outcomeDot(_ outcome: ActionRunOutcome) -> some View {
        Group {
            if outcome.isSettled {
                Circle().fill(outcome == .running ? StageHUDTheme.fieldAccent : outcome.tint)
            } else {
                Circle().strokeBorder(outcome.tint, lineWidth: 1)
            }
        }
        .frame(width: 6, height: 6)
    }

    /// Where the row goes when clicked, named so the operator knows before they click.
    private func destination(for session: ActionSessionSummary) -> String {
        if session.outcome == .running {
            return "LIVE"
        }
        switch session.kind {
        case .drive: return "TRACE"
        case .inspection: return "SNAPSHOT"
        case .capture: return "REVIEW"
        }
    }

    private func relativeTimestamp(_ session: ActionSessionSummary) -> String {
        guard let date = session.ledgerDate else {
            return "—"
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    // MARK: - Shared

    /// The recessed panel, with a warm rim.
    ///
    /// In dark the deep fill and the canvas are two points apart and the panel
    /// dissolves into the page without it; in light the rim reads as the edge of
    /// an inset block, so it earns its place in both.
    private var deepPanelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(StageHUDTheme.fieldDeep)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(StageHUDTheme.fieldDeepEdge, lineWidth: 1)
            )
    }

    /// The status console: recessed rather than raised.
    private var consolePanelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(StageHUDTheme.fieldConsole)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(StageHUDTheme.fieldPanelEdge, lineWidth: 1)
            )
    }

    private var fieldPanelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(StageHUDTheme.fieldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(StageHUDTheme.fieldPanelEdge, lineWidth: 1)
            )
    }

    private func eyebrow(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(ActionType.label)
            .tracking(ActionType.labelTracking)
            .foregroundStyle(tint)
    }

    private func deepChip(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(ActionType.labelRegular)
            .tracking(ActionType.labelTracking)
            .foregroundStyle(filled ? StageHUDTheme.fieldDeepText : StageHUDTheme.fieldDeepMeta)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Group {
                    if filled {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(StageHUDTheme.fieldDeepChip)
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(StageHUDTheme.fieldDeepEdge, lineWidth: 1)
                    }
                }
            )
    }

    // MARK: - Polling

    /// Both reads touch the filesystem, so they run off the main actor and hand
    /// back only the decoded result. Home is a foreground surface; it must not
    /// stutter because a ledger got long.
    private func refreshLease() {
        Task {
            let leases = await Task.detached(priority: .utility) {
                ActionHomeLeaseReader.activeLeases()
            }.value
            let active = leases.first
            // Scoped to this lease: an unfiltered read prints whatever anyone
            // last wrote, which under a live drive reads as its current step.
            let line: String? = await {
                guard let active else { return nil }
                return await Task.detached(priority: .utility) {
                    ActionSupervisionRegistry.latestNote(forLease: active.id)
                }.value
            }()

            lease = active
            beat = line
        }
    }

    private func refreshCounts() {
        Task {
            counts = await Task.detached(priority: .utility) {
                ActionToolLedger.counts()
            }.value
        }
    }
}
