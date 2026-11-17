import AppKit
import Combine
import SwiftUI

/// The ⌘K navigator: one palette, four kinds of result.
///
/// An input row (glyph · scope chip · field · mic), a body split between the
/// result list and a preview of the highlighted result, and a footer that
/// teaches the few keys that matter. Mirrors the shell studio's navigator
/// exhibit; palette from `Theme.swift`.
///
/// Slash commands and voice still run through the same bar — they take the
/// scope chip over while they own it, and the body swaps to their content.
struct UnifiedCommandBarView: View {
    @ObservedObject var state: UnifiedCommandBarState
    var onCommit: () -> Void
    var onMic: () -> Void
    /// Settings is reached through its browse row now; the callback stays for
    /// the window's call site.
    var onSettings: () -> Void
    var onDismiss: () -> Void

    @FocusState private var focused: Bool
    /// `nil` is "Everything". ⇥ narrows to one group.
    @State private var scope: ResultGroup?
    @State private var listHeight: CGFloat = 0
    @State private var lastHoverPoint: NSPoint?
    @State private var selectionSync = SelectionSync()
    @State private var selectionWatch: AnyCancellable?

    private enum Metrics {
        static let radius: CGFloat = 12
        static let inputHeight: CGFloat = 46
        static let previewWidth: CGFloat = 218
        static let bodyMaxHeight: CGFloat = 340
        static let rowHeight: CGFloat = 30
        static let rowRadius: CGFloat = 6
        static let thumbHeight: CGFloat = 98
        /// Always drawn, so the pane's height never moves with the selection.
        static let factRows = 3
    }

    /// The palette floats a step above `Palette.surface` (#1a1d22 in the mock).
    private static let surface = Color(red: 0.102, green: 0.114, blue: 0.133)
    /// The one hue on the surface: the highlighted result's glyph, the scope
    /// chip, and the hot cell in the preview.
    private static let accent = Palette.running
    private static let accentText = Color(red: 0.56, green: 0.90, blue: 0.71)

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(scopeShortcuts)
        // Focus must be asserted once the panel is *key* — setting it in onAppear
        // (before key) makes SwiftUI's makeFirstResponder fail silently and never
        // retry, so the field stays unfocused even though the window has focus.
        .onAppear {
            DispatchQueue.main.async { focused = true }
            watchSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            focused = true
        }
        // After voice hands the bar back (type-to-exit, cancel), the text field
        // re-renders — re-assert focus so typing continues without a click.
        .onChange(of: state.voice.phase) { _, phase in
            if phase == .idle { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: allRows.map(\.id)) { _, _ in resultsChanged() }
        .onChange(of: presentGroups) { _, groups in
            if let s = scope, !groups.contains(s) { scope = nil }
        }
        .onChange(of: scope) { _, _ in
            var sync = selectionSync
            ensureVisible(&sync)
            selectionSync = sync
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            inputRow
            if state.detail != .none {
                rule
                expansion
                rule
                footer
            }
        }
        .background(Self.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.borderLit, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Color.white.opacity(0.05).frame(height: 1).padding(.horizontal, Metrics.radius)
        }
        .shadow(color: Color.black.opacity(0.5), radius: 8, y: 4)
        .shadow(color: Color.black.opacity(0.6), radius: 20, y: 12)
        .animation(.easeOut(duration: 0.16), value: state.detail)
    }

    private var rule: some View {
        Palette.border.frame(height: 1)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.voiceActive ? "mic.fill" : "command")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Palette.textMuted)
                .frame(width: 16)
            scopeChip
            centerInput
            if state.voice.phase == .listening {
                WaveBar()
                ListeningTimer(startTime: state.voice.listenStartTime)
            }
            if !state.query.isEmpty && !state.voiceActive {
                clearButton
            }
            micButton
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.inputHeight)
    }

    /// One chip carries both mode and scope: the search scope while searching,
    /// otherwise whichever mode has taken the bar over.
    private var scopeChip: some View {
        Text(scopeLabel)
            .font(Typo.mono(11))
            .foregroundColor(Self.accentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Self.accent.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Self.accent.opacity(0.32), lineWidth: 1))
            .fixedSize()
    }

    private var scopeLabel: String {
        if state.voiceActive { return state.voice.phase == .listening ? "Listening" : "Voice" }
        if state.commandMode { return "Command" }
        if state.wantsAssistant { return "Ask" }
        return scope?.rawValue ?? "Everything"
    }

    /// Editable field normally; a read-only transcript line while voice is active.
    @ViewBuilder private var centerInput: some View {
        if state.voiceActive {
            Text(voiceTranscript)
                .font(Typo.body(15))
                .foregroundColor(state.voice.finalText.isEmpty && state.voice.partialText.isEmpty
                                 ? Palette.textMuted : Palette.text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Search, or / for commands", text: $state.query)
                .textFieldStyle(.plain)
                .font(Typo.body(15))
                .foregroundColor(Palette.text)
                .focused($focused)
                .onSubmit { onCommit() }
        }
    }

    private var voiceTranscript: String {
        if !state.voice.finalText.isEmpty { return state.voice.finalText }
        if !state.voice.partialText.isEmpty { return state.voice.partialText }
        switch state.voice.phase {
        case .connecting:   return "Connecting…"
        case .listening:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .result:
            if !state.voice.resultSummary.isEmpty { return state.voice.resultSummary }
            if let result = state.voice.executionResult, !result.isEmpty { return result }
            return "Voice result"
        default:            return ""
        }
    }

    private var clearButton: some View {
        Button { state.query = "" } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(Palette.textMuted)
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        let listening = state.voice.phase == .listening
        return Button(action: onMic) {
            Image(systemName: listening ? "stop.circle.fill" : "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(listening ? Self.accent : Palette.textMuted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(listening ? "Stop recording" : "Speak · hold ⌥")
    }

    /// ⇥ / ⇧⇥ cycle the scope chip. Key equivalents resolve before the field
    /// editor sees the Tab, so the field keeps focus. (In slash mode the window's
    /// key monitor consumes ⇥ for completion first.)
    private var scopeShortcuts: some View {
        Group {
            Button("") { cycleScope(1) }.keyboardShortcut(.tab, modifiers: [])
            Button("") { cycleScope(-1) }.keyboardShortcut(.tab, modifiers: .shift)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cycleScope(_ delta: Int) {
        let ring: [ResultGroup?] = [nil] + presentGroups
        let i = ring.firstIndex(of: scope) ?? 0
        scope = ring[(i + delta + ring.count) % ring.count]
    }

    // MARK: - Expansion

    @ViewBuilder private var expansion: some View {
        switch state.detail {
        case .search, .browse, .welcome:
            split(results: resultList, preview: previewPane(resultPreview))
        case .command:
            split(results: commandList, preview: previewPane(commandPreview))
        case .nlCommand:
            split(results: nlRow, preview: previewPane(nlPreview))
        case .voice:
            voiceList
        case .none:
            EmptyView()
        }
    }

    private func split<L: View, P: View>(results: L, preview: P) -> some View {
        HStack(alignment: .top, spacing: 0) {
            results.frame(maxWidth: .infinity, alignment: .topLeading)
            Palette.border.frame(width: 1)
            preview.frame(width: Metrics.previewWidth, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The list hugs its content up to the body cap, then scrolls.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(6)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: listHeight > 0 ? min(listHeight, Metrics.bodyMaxHeight) : nil)
        .frame(maxHeight: Metrics.bodyMaxHeight)
    }

    private struct ListHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    // MARK: - Results (search · browse)

    /// The four kinds the palette shows. `OmniResultKind` is finer-grained (it
    /// drives icons and scoring); this is the reader's vocabulary.
    enum ResultGroup: String, CaseIterable {
        case windows = "Windows"
        case sessions = "Sessions"
        case pages = "Pages"
        case commands = "Commands"

        /// Browse rows that open an app page rather than run something.
        private static let pageTitles: Set<String> = ["Studio", "Activity Log", "Workspace Assistant"]

        static func of(_ item: OmniResult) -> ResultGroup {
            switch item.kind {
            case .window where item.icon.hasPrefix("rectangle."):
                return .commands   // the browse menu's "Tile <app> Left" rows act, they aren't windows
            case .window, .ocrContent, .process:
                return .windows
            case .project, .session, .layer, .group:
                return .sessions
            case .app:
                return .commands
            case .action:
                return pageTitles.contains(item.title) ? .pages : .commands
            }
        }
    }

    /// A result with its flat index in `groupedResults` order — the index the
    /// window's commit() activates — regardless of where the row is drawn.
    private struct Row: Identifiable {
        let idx: Int
        let item: OmniResult
        let group: ResultGroup
        var id: UUID { item.id }
    }

    private struct Section: Identifiable {
        let group: ResultGroup
        let rows: [Row]
        var id: String { group.rawValue }
    }

    private var allRows: [Row] {
        var flat = 0
        return state.search.groupedResults.flatMap { _, items in
            items.map { item in
                defer { flat += 1 }
                return Row(idx: flat, item: item, group: ResultGroup.of(item))
            }
        }
    }

    private var presentGroups: [ResultGroup] {
        let present = Set(allRows.map(\.group))
        return ResultGroup.allCases.filter(present.contains)
    }

    /// Scoped, then regrouped in the four-kind order.
    private var visibleRows: [Row] {
        arrangementRows + sections.flatMap(\.rows)
    }

    /// Keep the captured app's action visible before the larger browse catalog.
    private var arrangementRows: [Row] {
        allRows.filter { $0.item.arrangementTarget != nil && (scope == nil || $0.group == scope) }
    }

    private var sections: [Section] {
        let ordinaryRows = allRows.filter { $0.item.arrangementTarget == nil }
        let rows = scope.map { s in ordinaryRows.filter { $0.group == s } } ?? ordinaryRows
        return ResultGroup.allCases.compactMap { group in
            let inGroup = rows.filter { $0.group == group }
            return inGroup.isEmpty ? nil : Section(group: group, rows: inGroup)
        }
    }

    private var selectedRow: Row? {
        allRows.first { $0.idx == state.search.selectedIndex }
    }

    private var resultList: some View {
        let displays = WindowTiler.getDisplaySpaces()
        return ScrollViewReader { proxy in
            scrolling {
                VStack(alignment: .leading, spacing: 0) {
                    if !arrangementRows.isEmpty {
                        groupLabel("Current app", first: true)
                        ForEach(arrangementRows) { row in
                            resultRow(row, displays: displays).id(row.id)
                        }
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                        groupLabel(section.group.rawValue, first: i == 0 && arrangementRows.isEmpty)
                        ForEach(section.rows) { row in
                            resultRow(row, displays: displays).id(row.id)
                        }
                    }
                }
            }
            .onChange(of: state.search.selectedIndex) { _, _ in
                if let row = selectedRow { proxy.scrollTo(row.id) }
            }
        }
    }

    private func resultRow(_ row: Row, displays: [DisplaySpaces]) -> some View {
        let sel = row.idx == state.search.selectedIndex
        let line = rowLine(row, displays: displays)
        return Button {
            select(row.idx)
            onCommit()
        } label: {
            paletteRow(
                selected: sel,
                glyph: { Image(systemName: row.item.icon).font(.system(size: 12, weight: .medium)) },
                lead: line.lead, tail: line.tail, ctx: line.ctx
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // Only a moving mouse steals the highlight — rows sliding under a
            // resting cursor while arrowing must not.
            guard inside else { return }
            let p = NSEvent.mouseLocation
            guard p != lastHoverPoint else { return }
            lastHoverPoint = p
            select(row.idx)
        }
    }

    /// One row of the list: lead in text weight, tail dimmed, context right.
    /// Fixed height so the list never reflows as the highlight moves.
    private func paletteRow<G: View>(
        selected: Bool, @ViewBuilder glyph: () -> G,
        lead: String, tail: String, ctx: String, trailing: AnyView? = nil
    ) -> some View {
        HStack(spacing: 9) {
            glyph()
                .foregroundColor(selected ? Self.accent : Palette.textMuted)
                .frame(width: 16)
            Text("\(Text(lead).fontWeight(.semibold).foregroundColor(Palette.text))\(Text(tail).foregroundColor(Palette.textDim))")
                .font(Typo.body(12.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let trailing {
                trailing
            } else if !ctx.isEmpty {
                Text(ctx)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.09 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .strokeBorder(selected ? Palette.borderLit : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }

    private func groupLabel(_ text: String, first: Bool) -> some View {
        Text(text.uppercased())
            .font(Typo.heading(11))
            .tracking(0.55)
            .foregroundColor(Palette.textMuted)
            .padding(.horizontal, 8)
            .padding(.top, first ? 2 : 9)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Line {
        var lead: String
        var tail: String
        var ctx: String
    }

    private func rowLine(_ row: Row, displays: [DisplaySpaces]) -> Line {
        let item = row.item
        let tail = item.subtitle.isEmpty || item.subtitle == item.title ? "" : " — \(item.subtitle)"
        var ctx = ""
        switch row.group {
        case .windows:
            if let entry = Self.resolveWindow(for: item),
               let space = Self.spaceOrdinal(for: entry, in: displays) {
                ctx = "Space \(space)"
            }
        case .sessions:
            if item.kind == .project, Self.project(for: item)?.isRunning == true {
                ctx = "running"
            } else if item.kind == .session, Self.tmuxSession(for: item) != nil {
                ctx = "tmux"
            }
        case .pages, .commands:
            break
        }
        return Line(lead: item.title, tail: tail, ctx: ctx)
    }

    // MARK: - Preview

    private struct Preview {
        var scene = ThumbScene()
        var facts: [(String, String)] = []
    }

    /// What the thumbnail draws: the display's visible area with its windows
    /// as dim cells and, when the result resolves to a place, a hot cell.
    /// Rects are unit-square, CG orientation (y down).
    private struct ThumbScene: Equatable {
        var aspect: CGFloat = 16 / 10
        var cells: [CGRect] = []
        var hot: CGRect?
    }

    private func previewPane(_ preview: Preview) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Thumb(scene: preview.scene, accent: Self.accent)
                .frame(height: Metrics.thumbHeight)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<Metrics.factRows, id: \.self) { i in
                    let fact = i < preview.facts.count ? preview.facts[i] : ("", "")
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(fact.0)
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.textMuted)
                            .lineLimit(1)
                            .frame(width: 66, alignment: .leading)
                        Text(fact.1)
                            .font(Typo.mono(11))
                            .foregroundColor(Palette.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: 16)
                }
            }
        }
        .padding(13)
    }

    private var resultPreview: Preview {
        guard let row = selectedRow else { return Preview(scene: Self.scene(on: Self.frontScreen())) }
        let item = row.item
        var p = Preview()

        if let target = item.arrangementTarget {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
            } ?? Self.frontScreen()
            p.scene = Self.scene(on: screen)
            p.facts = [("Selected", "\(target.windows.count) \(target.appName) windows"),
                       ("Display", target.displayName), ("Next", "Choose a layout")]
            return p
        }

        if row.group == .commands, item.kind == .window {
            // "Tile <app> Left" — the browse menu's placement rows on the front window.
            let front = DesktopModel.shared.frontmostWindow()
            let screen = front.map { WindowTiler.screenForWindowFrame($0.frame) } ?? Self.frontScreen()
            let word = item.title.split(separator: " ").last.map(String.init) ?? ""
            let spec = PlacementSpec(string: word.lowercased())
            p.scene = Self.scene(on: screen, spaceIds: front?.spaceIds, hot: spec.map(Self.unit))
            p.facts = [("Target", front?.app ?? "Front window"),
                       ("Placement", word),
                       ("Display", screen.localizedName)]
            return p
        }

        if let entry = Self.resolveWindow(for: item) {
            let screen = WindowTiler.screenForWindowFrame(entry.frame)
            p.scene = Self.scene(on: screen, spaceIds: entry.spaceIds, hot: Self.unit(entry.frame, on: screen))
            let space = Self.spaceOrdinal(for: entry, in: WindowTiler.getDisplaySpaces()).map(String.init) ?? "—"
            p.facts = [("Display", screen.localizedName), ("Space", space)]
            if let session = entry.latticesSession {
                p.facts.append(("Session", session))
            } else if item.kind == .ocrContent {
                p.facts.append(("Match", item.subtitle))
            } else {
                p.facts.append(("Title", entry.title.isEmpty ? "—" : entry.title))
            }
            return p
        }

        p.scene = Self.scene(on: Self.frontScreen())
        switch item.kind {
        case .window, .ocrContent, .process:
            p.facts = [("Display", "—"), ("Space", "—"),
                       (item.kind == .ocrContent ? "Match" : "Title", item.subtitle)]
        case .project:
            if let project = Self.project(for: item) {
                p.facts = [("Path", Self.tilde(project.path)),
                           ("tmux", project.sessionName),
                           ("Panes", String(project.paneCount))]
            } else {
                p.facts = [("Path", item.subtitle)]
            }
        case .session:
            if let session = Self.tmuxSession(for: item) {
                p.facts = [("tmux", session.name),
                           ("Panes", String(session.panes.count)),
                           ("State", session.attached ? "attached" : "detached")]
            } else {
                p.facts = [("cwd", item.subtitle)]
            }
        case .layer:
            let workspace = WorkspaceManager.shared
            let label = Self.suffix(of: item.title, after: ": ")
            if let layers = workspace.config?.layers,
               let index = layers.firstIndex(where: { $0.label == label }) {
                let overview = workspace.overviews(in: DesktopModel.shared.allWindows()).first { $0.index == index }
                let count = overview?.windows.count ?? 0
                let showing = overview?.showingIds.count ?? 0
                p.facts = [("Layer", label),
                           ("Key", LayerOverview.chord(forIndex: index) ?? "None"),
                           ("Windows", count == 0 ? "0" : "\(count) · \(showing) showing")]
            } else {
                p.facts = [("Layer", label)]
            }
        case .group:
            let workspace = WorkspaceManager.shared
            let label = Self.suffix(of: item.title, after: " ")
            if let group = workspace.config?.groups?.first(where: { $0.label == label }) {
                p.facts = [("Group", group.label),
                           ("Tabs", String(group.tabs.count)),
                           ("State", workspace.isGroupRunning(group) ? "running" : "stopped")]
            } else {
                p.facts = [("Group", label)]
            }
        case .app:
            let running = item.subtitle.hasPrefix("Running")
            p.facts = [("App", item.title),
                       ("State", running ? "running" : "not running"),
                       ("Action", running ? "Bring to front" : "Launch")]
        case .action:
            p.facts = [(row.group == .pages ? "Page" : "Command", item.title),
                       ("Detail", item.subtitle)]
        }
        return p
    }

    /// `OmniResult` carries no window identity, so window results are matched
    /// back to the desktop by app + title. Only an unambiguous match previews —
    /// a wrong preview is worse than none.
    private static func resolveWindow(for item: OmniResult) -> WindowEntry? {
        switch item.kind {
        case .window, .ocrContent, .session, .project:
            break
        default:
            return nil
        }
        let windows = DesktopModel.shared.allWindows().filter { $0.frame.w >= 120 && $0.frame.h >= 120 }
        if item.kind == .project, let project = project(for: item) {
            return windows.first { $0.latticesSession == project.sessionName }
        }
        if let tagged = windows.first(where: { $0.latticesSession == item.title }) {
            return tagged
        }
        let sameApp = windows.filter { $0.app == item.title }
        if let exact = sameApp.first(where: { $0.title == item.subtitle || "Window \($0.wid)" == item.subtitle }) {
            return exact
        }
        return sameApp.count == 1 ? sameApp.first : nil
    }

    private static func project(for item: OmniResult) -> Project? {
        ProjectScanner.shared.projects.first {
            item.title == $0.name || item.title.hasSuffix(" " + $0.name)
        }
    }

    private static func tmuxSession(for item: OmniResult) -> TmuxSession? {
        TmuxModel.shared.sessions.first { $0.name == item.title }
    }

    private static func spaceOrdinal(for entry: WindowEntry, in displays: [DisplaySpaces]) -> Int? {
        for display in displays {
            if let space = display.spaces.first(where: { entry.spaceIds.contains($0.id) }) {
                return space.index
            }
        }
        return nil
    }

    private static func suffix(of title: String, after separator: String) -> String {
        guard let range = title.range(of: separator) else { return title }
        return String(title[range.upperBound...])
    }

    private static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func frontScreen() -> NSScreen {
        NSScreen.main ?? NSScreen.screens[0]
    }

    /// The screen's visible area in CG (top-left) coordinates.
    private static func cgVisible(_ screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    private static func unit(_ frame: WindowFrame, on screen: NSScreen) -> CGRect? {
        let area = cgVisible(screen)
        guard area.width > 0, area.height > 0 else { return nil }
        let r = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h).intersection(area)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return CGRect(x: (r.minX - area.minX) / area.width, y: (r.minY - area.minY) / area.height,
                      width: r.width / area.width, height: r.height / area.height)
    }

    private static func unit(_ spec: PlacementSpec) -> CGRect {
        let (fx, fy, fw, fh) = spec.fractions
        return CGRect(x: fx, y: fy, width: fw, height: fh)
    }

    /// Windows on `screen` in the given Space (the display's current one by
    /// default), back to front, as thumbnail cells.
    private static func scene(on screen: NSScreen, spaceIds: [Int]? = nil, hot: CGRect? = nil) -> ThumbScene {
        let area = cgVisible(screen)
        let spaces: Set<Int> = {
            if let ids = spaceIds, !ids.isEmpty { return Set(ids) }
            return Set(WindowTiler.getDisplaySpaces().map(\.currentSpaceId))
        }()
        let cells = DesktopModel.shared.allWindows()
            .filter { entry in
                entry.frame.w >= 120 && entry.frame.h >= 120
                    && (entry.spaceIds.isEmpty || !spaces.isDisjoint(with: entry.spaceIds))
                    && WindowTiler.screenForWindowFrame(entry.frame) == screen
            }
            .prefix(16)
            .compactMap { unit($0.frame, on: screen) }
            .reversed()
        return ThumbScene(aspect: area.height > 0 ? area.width / area.height : 16 / 10,
                          cells: Array(cells), hot: hot)
    }

    private struct Thumb: View {
        let scene: ThumbScene
        let accent: Color

        var body: some View {
            GeometryReader { geo in
                let inset: CGFloat = 7
                let box = CGSize(width: geo.size.width - inset * 2, height: geo.size.height - inset * 2)
                let scale = min(box.width / scene.aspect, box.height)
                let display = CGRect(
                    x: inset + (box.width - scale * scene.aspect) / 2,
                    y: inset + (box.height - scale) / 2,
                    width: scale * scene.aspect, height: scale
                )
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                        .frame(width: display.width, height: display.height)
                        .offset(x: display.minX, y: display.minY)
                    ForEach(Array(scene.cells.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: max(2, cell.width * display.width),
                                   height: max(2, cell.height * display.height))
                            .offset(x: display.minX + cell.minX * display.width,
                                    y: display.minY + cell.minY * display.height)
                    }
                    if let hot = scene.hot {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(accent.opacity(0.19))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(accent.opacity(0.32), lineWidth: 1)
                            )
                            .frame(width: max(2, hot.width * display.width),
                                   height: max(2, hot.height * display.height))
                            .offset(x: display.minX + hot.minX * display.width,
                                    y: display.minY + hot.minY * display.height)
                    }
                }
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.141, green: 0.157, blue: 0.180), Color(red: 0.078, green: 0.086, blue: 0.098)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: scene)
        }
    }

    // MARK: - Selection sync

    /// Keeps the highlight moving through the *drawn* order.
    ///
    /// `OmniSearchState.selectedIndex` is a flat index into `groupedResults`
    /// order, and the window's commit() activates exactly that row — so the
    /// highlighted row must always carry that index. But the palette draws rows
    /// regrouped into four kinds, and possibly scoped, so an arrow step in flat
    /// order can land on a row drawn elsewhere, or on a hidden one. Every
    /// published change is read back and, when it was a ±1 step — or a clamped
    /// step at either end, which `@Published` still fires — redirected to the
    /// drawn neighbour. Programmatic picks (hover, click, scope) queue their
    /// index so they pass through untouched.
    ///
    /// This belongs in `OmniSearchState` (group order + scope owned by the
    /// engine); it lives here until that file can change.
    private struct SelectionSync {
        var lastSeen = 0
        var pending: [Int] = []
        var resultIDs: [UUID] = []
    }

    private func watchSelection() {
        guard selectionWatch == nil else { return }
        // Delivered after the set lands, so a redirect isn't overwritten by the
        // assignment that triggered it.
        selectionWatch = state.search.$selectedIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { syncSelection(to: $0) }
    }

    private func syncSelection(to new: Int) {
        var sync = selectionSync
        defer { selectionSync = sync }

        let ids = allRows.map(\.id)
        if ids != sync.resultIDs {
            // Fresh results — the engine reset the index; nothing to redirect.
            sync.resultIDs = ids
            sync.pending.removeAll()
            sync.lastSeen = new
            ensureVisible(&sync)
            return
        }
        if let i = sync.pending.firstIndex(of: new) {
            sync.pending.removeFirst(i + 1)
            sync.lastSeen = new
            return
        }

        let old = sync.lastSeen
        sync.lastSeen = new
        let drawn = visibleRows
        guard !drawn.isEmpty else { return }

        let step: Int
        switch new - old {
        case 1, -1:
            step = new - old
        case 0 where new == 0:
            step = -1                       // ↑ clamped at the flat start
        case 0 where new == allRows.count - 1:
            step = 1                        // ↓ clamped at the flat end
        default:
            ensureVisible(&sync)            // a direct set — leave it alone
            return
        }
        guard let pos = drawn.firstIndex(where: { $0.idx == old }) else {
            ensureVisible(&sync)
            return
        }
        let target = drawn[max(0, min(drawn.count - 1, pos + step))].idx
        if target != new { pick(target, &sync) }
    }

    private func resultsChanged() {
        var sync = selectionSync
        defer { selectionSync = sync }
        sync.resultIDs = allRows.map(\.id)
        sync.pending.removeAll()
        sync.lastSeen = state.search.selectedIndex
        ensureVisible(&sync)
    }

    private func ensureVisible(_ sync: inout SelectionSync) {
        let drawn = visibleRows
        guard !drawn.contains(where: { $0.idx == state.search.selectedIndex }),
              let first = drawn.first else { return }
        pick(first.idx, &sync)
    }

    private func pick(_ idx: Int, _ sync: inout SelectionSync) {
        sync.pending.append(idx)
        sync.lastSeen = idx
        state.search.selectedIndex = idx
    }

    private func select(_ idx: Int) {
        var sync = selectionSync
        pick(idx, &sync)
        selectionSync = sync
    }

    // MARK: - Slash commands

    private var commandList: some View {
        let cmds = state.search.command.suggestions
        return scrolling {
            VStack(alignment: .leading, spacing: 0) {
                if let ctx = state.search.command.contextLabel {
                    groupLabel(ctx, first: true)
                }
                ForEach(Array(cmds.enumerated()), id: \.element.id) { idx, s in
                    if let sec = s.section, idx == 0 || cmds[idx - 1].section != sec {
                        groupLabel(sec, first: idx == 0 && state.search.command.contextLabel == nil)
                    }
                    commandRow(s, idx: idx)
                }
            }
        }
    }

    private func commandRow(_ s: CommandSuggestion, idx: Int) -> some View {
        let sel = idx == state.search.command.selectedIndex
        return Button {
            state.search.command.selectedIndex = idx
            onCommit()
        } label: {
            paletteRow(
                selected: sel,
                glyph: { suggestionGlyph(s, selected: sel) },
                lead: s.label, tail: "", ctx: s.detail,
                trailing: s.isFill ? AnyView(
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Palette.textMuted)
                ) : nil
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func suggestionGlyph(_ suggestion: CommandSuggestion, selected: Bool) -> some View {
        if let spec = suggestion.previewSpec {
            MiniPlacementGlyph(spec: spec, selected: selected)
                .frame(width: 16, height: 12)
        } else {
            Image(systemName: suggestion.glyph)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var commandPreview: Preview {
        let front = DesktopModel.shared.frontmostWindow()
        guard let s = state.search.command.selected else {
            return Preview(scene: Self.scene(on: Self.frontScreen(), spaceIds: front?.spaceIds))
        }
        let target = s.previewWid.flatMap { DesktopModel.shared.windows[$0] } ?? front
        let screen = s.previewScreen
            ?? target.map { WindowTiler.screenForWindowFrame($0.frame) }
            ?? Self.frontScreen()
        return Preview(
            scene: Self.scene(on: screen, spaceIds: target?.spaceIds, hot: s.previewSpec.map(Self.unit)),
            facts: [("Command", s.label),
                    ("Placement", s.previewSpec?.wireValue ?? "—"),
                    ("Target", target?.app ?? "Front window")]
        )
    }

    // MARK: - NL command (typed natural language → an interpreted, runnable intent)

    /// One row previewing the intent the resolver inferred from the typed text:
    /// you type "tile chrome left" and see exactly what ↵ will run.
    @ViewBuilder private var nlRow: some View {
        if let m = state.nlMatch {
            let s = nlSummary(m)
            Button(action: onCommit) {
                paletteRow(
                    selected: true,
                    glyph: { Image(systemName: s.glyph).font(.system(size: 12, weight: .medium)) },
                    lead: s.label, tail: "", ctx: ""
                )
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    private var nlPreview: Preview {
        let front = DesktopModel.shared.frontmostWindow()
        let screen = front.map { WindowTiler.screenForWindowFrame($0.frame) } ?? Self.frontScreen()
        var p = Preview(scene: Self.scene(on: screen, spaceIds: front?.spaceIds, hot: state.nlSpec.map(Self.unit)))
        if let m = state.nlMatch {
            p.facts = [("Command", nlSummary(m).label),
                       ("Placement", state.nlSpec?.wireValue ?? "—"),
                       ("Target", front?.app ?? "Front window")]
        }
        return p
    }

    /// Humanize an inferred intent + slots into a glyph and a one-line label.
    private func nlSummary(_ m: IntentMatch) -> (glyph: String, label: String) {
        func slot(_ k: String) -> String? {
            if let s = m.slots[k]?.stringValue, !s.isEmpty { return s }
            if let i = m.slots[k]?.intValue { return String(i) }
            return nil
        }
        switch m.intentName {
        case "tile_window":
            if let pos = slot("position"), let spec = PlacementSpec(string: pos) {
                if case .tile(let p) = spec { return (p.arrowGlyph, "Tile · \(p.label)") }
                return ("rectangle.split.2x2", "Tile · \(spec.wireValue)")
            }
            return ("rectangle.center.inset.filled", "Tile window")
        case "move_to_display":
            let d = slot("display").map { "display \((Int($0) ?? 0) + 1)" } ?? "another display"
            return ("display", "Move to \(d)")
        case "focus":
            return ("scope", "Focus \(slot("app") ?? slot("session") ?? "window")")
        case "launch":
            return ("arrow.up.forward.app", "Open \(slot("project") ?? slot("app") ?? "app")")
        case "distribute":
            let what = slot("app").map { "\($0) windows" } ?? "windows"
            return ("rectangle.split.3x3", "Arrange \(what)" + (slot("region").map { " · \($0)" } ?? ""))
        case "scan":
            return ("sparkle.magnifyingglass", "Scan workspace")
        default:
            return ("command", m.intentName.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    // MARK: - Footer

    /// Three keys, not thirty: what ↵ does to the highlighted result, ⇥, and esc.
    private var footer: some View {
        HStack(spacing: 15) {
            ForEach(footerKeys, id: \.0) { key, label in
                hint(key, label)
            }
            Spacer(minLength: 0)
            hint("esc", "Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.025))
    }

    private var footerKeys: [(String, String)] {
        switch state.detail {
        case .command:
            return [("↵", "Run"), ("⇥", "Complete")]
        case .nlCommand:
            return [("↵", "Run"), ("⌘↵", "Ask instead")]
        case .voice:
            switch state.voice.phase {
            case .connecting:   return [("↵", "Cancel")]
            case .listening:    return [("↵", "Finish"), ("⌥", "Release to stop")]
            case .transcribing: return []
            case .result:       return [("↵", voiceRetryable ? "Try again" : "Close")]
            case .idle:         return [("⌥", "Hold to speak")]
            }
        default:
            return [("↵", state.wantsAssistant ? "Ask" : verb(for: selectedRow)), ("⇥", "Narrow scope")]
        }
    }

    private func verb(for row: Row?) -> String {
        guard let row else { return "Open" }
        if row.item.arrangementTarget != nil { return "Arrange" }
        switch row.group {
        case .windows:  return "Focus"
        case .pages:    return "Open"
        case .commands: return "Run"
        case .sessions:
            // The browse menu bakes its verb into the title ("Attach lattices").
            let first = row.item.title.split(separator: " ").first.map(String.init) ?? ""
            if ["Attach", "Kill", "Launch", "Focus"].contains(first) { return first }
            return row.item.kind == .project ? "Start" : "Attach"
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key)
            Text(label)
                .font(Typo.body(11))
                .foregroundColor(Palette.textMuted)
        }
    }

    private var voiceRetryable: Bool {
        let result = state.voice.executionResult ?? ""
        return VoiceCommandState.isRetryableFailure(result)
    }

    // MARK: - Voice expansion

    /// Heard · Intent · Result — the slim voice readout, full width (there is
    /// nothing to preview until a result lands).
    private var voiceList: some View {
        scrolling {
            VStack(alignment: .leading, spacing: 0) {
                if !state.voice.finalText.isEmpty {
                    voiceSection("Heard", first: true) {
                        Text(state.voice.finalText)
                            .font(Typo.body(13))
                            .foregroundColor(Palette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !state.voice.partialText.isEmpty {
                    voiceSection("Hearing…", first: true) {
                        Text(state.voice.partialText)
                            .font(Typo.body(13))
                            .foregroundColor(Palette.textDim)
                    }
                }

                if let intent = state.voice.intentName {
                    voiceSection("Intent") { intentChips(intent) }
                }

                if let failure = state.voice.executionError {
                    voiceSection("Couldn't run") {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.kill)
                            Text(failure)
                                .font(Typo.mono(11))
                                .foregroundColor(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !state.voice.resultItems.isEmpty {
                    let n = state.voice.resultItems.count
                    voiceSection("\(n) match\(n == 1 ? "" : "es")") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(state.voice.resultItems.prefix(20).enumerated()), id: \.1.id) { idx, item in
                                ResultRow(index: idx, item: item, onFocus: focusWindow, onTile: tileWindow)
                            }
                        }
                    }
                } else if !state.voice.resultSummary.isEmpty {
                    voiceSection("Result") { resultLine(state.voice.resultSummary) }
                } else if state.voice.executionResult == "ok" {
                    voiceSection("Result") { resultLine("done") }
                }
            }
        }
    }

    private func voiceSection<Content: View>(_ label: String, first: Bool = false,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            groupLabel(label, first: first)
            content()
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 8)
    }

    /// The resolved intent + its slots as a chip row.
    private func intentChips(_ intent: String) -> some View {
        let slots = state.voice.intentSlots
        return HStack(spacing: 6) {
            chip(intent, signal: true)
            ForEach(slots.keys.sorted(), id: \.self) { key in
                if let val = slots[key] { chip("\(key): \(val)", signal: false) }
            }
        }
    }

    private func chip(_ text: String, signal: Bool) -> some View {
        Text(text)
            .font(Typo.mono(11))
            .foregroundColor(signal ? Self.accentText : Palette.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(signal ? Self.accent.opacity(0.13) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(signal ? Self.accent.opacity(0.32) : Palette.border, lineWidth: 1)
            )
    }

    private func resultLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Self.accent).frame(width: 6, height: 6)
            Text(text)
                .font(Typo.body(12.5))
                .foregroundColor(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func focusWindow(_ wid: UInt32) {
        guard let entry = DesktopModel.shared.windows[wid] else { return }
        WindowTiler.focusWindow(wid: wid, pid: entry.pid)
        WindowTiler.highlightWindowById(wid: wid)
    }

    private func tileWindow(_ wid: UInt32, _ position: String) {
        guard let entry = DesktopModel.shared.windows[wid],
              let placement = PlacementSpec(string: position) else { return }
        WindowTiler.focusWindow(wid: wid, pid: entry.pid)
        WindowTiler.tileWindowById(wid: wid, pid: entry.pid, to: placement)
        WindowTiler.highlightWindowById(wid: wid)
    }
}

private struct MiniPlacementGlyph: View {
    let spec: PlacementSpec
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let (fx, fy, fw, fh) = spec.fractions
            let accent = selected ? Palette.running : Palette.textDim

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.07 : 0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(accent.opacity(selected ? 0.65 : 0.32), lineWidth: 0.6)
                    )

                ForEach(1..<4, id: \.self) { index in
                    Rectangle()
                        .fill(Palette.border.opacity(selected ? 0.8 : 0.55))
                        .frame(width: 0.5)
                        .offset(x: size.width * CGFloat(index) / 4)
                    Rectangle()
                        .fill(Palette.border.opacity(selected ? 0.8 : 0.55))
                        .frame(height: 0.5)
                        .offset(y: size.height * CGFloat(index) / 4)
                }

                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(accent.opacity(selected ? 0.9 : 0.58))
                    .frame(
                        width: max(2, size.width * fw),
                        height: max(2, size.height * fh)
                    )
                    .offset(x: size.width * fx, y: size.height * fy)
            }
        }
    }
}
