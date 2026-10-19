import AppKit
import BlinkCore
import SwiftUI

private struct WorkspaceMenuEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let noteCount: Int
}

@MainActor
final class PeerSyncStatus: ObservableObject {
    @Published var unavailableReason: String?

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }
}

/// The menubar popover is Blink's compact workspace: capture/search spans the
/// whole workspace, with recents on the left and a spatial overview on the
/// right.
/// Selecting is deliberately separate from opening so the canvas can act as a
/// quiet browser; Return or the preview card's Open action realizes the panel.
struct CapturePopoverView: View {
    static let contentSize = CGSize(width: 1_056, height: 700)

    @ObservedObject var model: AppModel
    var dismiss: () -> Void
    var openSettings: () -> Void
    var openGuide: () -> Void
    var showCommands: () -> Void
    var toggleBlink: () -> Void
    var showGrid: () -> Void
    var quit: () -> Void
    var beginDictation: () -> Void
    var trustedPeerCount: Int
    @ObservedObject var peerSyncStatus: PeerSyncStatus

    @ObservedObject private var appearance = AppearanceManager.shared
    @ObservedObject private var configStore = BlinkConfigStore.shared

    @State private var query = ""
    @State private var selectedNoteID: String?
    @State private var canvasMode: CanvasMode = .constellation
    @State private var canvasExpanded = false
    @FocusState private var fieldFocused: Bool

    /// The resolved palette for the current app scheme. Its cool signal-blue
    /// distinguishes Blink from Talkie's coral while preserving the graphite /
    /// paper world. Follows a light/dark flip live because `appearance` is observed.
    private var pal: PopoverPalette { .forScheme(appearance.scheme) }
    private var accent: Color { pal.accent }
    private var accentBright: Color { pal.accentBright }
    private var peerSyncUnavailableReason: String? { peerSyncStatus.unavailableReason }
    private var blinkShortcut: String {
        KeyChord.parse(configStore.config.hotkeys.blink)?.display
            ?? configStore.config.hotkeys.blink
    }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The design is set in IBM Plex Mono weight 200. SF Mono at a light weight
    /// is the closest native match (bundling IBM Plex Mono would be exact).
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Definitions make empty workspaces selectable; note membership keeps an
    /// unknown/removed definition browseable rather than orphaning its notes.
    private var workspaceEntries: [WorkspaceMenuEntry] {
        let configured = configStore.config.workspaces ?? [:]
        let ids = Set(configured.keys).union(
            model.notes.compactMap(\.presentation.workspace)
        )
        return ids.map { id in
            let configuredTitle = configured[id]?.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = configuredTitle.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let count = model.notes.filter { $0.presentation.workspace == id }.count
            return WorkspaceMenuEntry(id: id, title: title, noteCount: count)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var scopedNotes: [Note] {
        model.notes.filter {
            model.workspaceScope.includes(workspace: $0.presentation.workspace)
        }
    }

    private var filtered: [Note] {
        guard !trimmedQuery.isEmpty else { return Array(scopedNotes.prefix(12)) }
        let needle = trimmedQuery.lowercased()
        return Array(
            scopedNotes
                .filter {
                    $0.title.lowercased().contains(needle)
                        || $0.content.lowercased().contains(needle)
                        || $0.tags.contains { $0.lowercased().contains(needle) }
                }
                .prefix(18)
        )
    }

    private var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return filtered.first(where: { $0.id == selectedNoteID })
    }

    private var activeWorkspaceTitle: String {
        switch model.workspaceScope {
        case .all: "All notes"
        case .unfiled: "Unfiled"
        case .workspace(let id): workspaceEntries.first { $0.id == id }?.title ?? id
        }
    }

    private var capturePlaceholder: String {
        switch model.workspaceScope {
        case .all: "Search or capture…"
        default: "Search or capture in \(activeWorkspaceTitle)…"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            hairline
            HStack(spacing: 0) {
                if !canvasExpanded {
                    recentSidebar
                        .frame(width: 262)
                        .background(pal.navigationFill)
                    verticalHairline
                }
                canvasPane
            }
            hairline
            footer
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(popoverBackground)
        .overlay(PopoutCorners())
        .environment(\.popoverPalette, pal)
        .preferredColorScheme(appearance.scheme == .dark ? .dark : .light)
        .background(
            Button("") { createFromQuery() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        )
        .onAppear {
            normalizeWorkspaceScope()
            fieldFocused = true
        }
        .onChange(of: workspaceEntries.map(\.id)) { _, _ in
            normalizeWorkspaceScope()
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selectedNoteID, ids.contains(selectedNoteID) { return }
            selectedNoteID = nil
        }
    }

    private var popoverBackground: some View {
        ZStack {
            pal.bgBase
            RadialGradient(
                colors: [
                    pal.bgGrad1,  // #17191c
                    pal.bgGrad2,  // #0c0e10
                    pal.bgGrad3,  // #050607
                ],
                center: UnitPoint(x: 0.78, y: 0.0),
                startRadius: 0,
                endRadius: 820
            )
            TerminalGrid(step: 40, opacity: 0.02)
        }
    }

    private var captureHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(pal.inkMuted)  // #6b7072

            TextField(capturePlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(mono(15, .light))
                .foregroundStyle(pal.inkBright)  // #e6e8e6
                .tint(accent)
                .focused($fieldFocused)
                .onSubmit { openFirstOrCreate() }

            WorkspaceScopeMenu(
                selection: model.workspaceScope,
                title: activeWorkspaceTitle,
                count: scopedNotes.count,
                allCount: model.notes.count,
                unfiledCount: model.notes.filter { $0.presentation.workspace == nil }.count,
                workspaces: workspaceEntries
            ) { scope in
                query = ""
                selectedNoteID = nil
                model.selectWorkspace(scope)
            }

            toolbarSeparator

            Button(action: startSystemDictation) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(accentBright)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.07))
                    .overlay(Rectangle().stroke(accent.opacity(0.22), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dictate into capture")
            .accessibilityLabel("Dictate into capture")

            NewNoteButton(
                title: trimmedQuery.isEmpty ? "New note" : "Create note",
                help: trimmedQuery.isEmpty
                    ? "Create a new note (⌘↩)"
                    : "Create a note from this capture (⌘↩)",
                action: createFromQuery
            )
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var numberedNotes: [(index: Int, note: Note)] {
        filtered.enumerated().map { (index: $0.offset + 1, note: $0.element) }
    }
    private var todayItems: [(index: Int, note: Note)] {
        numberedNotes.filter { Calendar.current.isDateInToday($0.note.updatedAt) }
    }
    private var earlierItems: [(index: Int, note: Note)] {
        numberedNotes.filter { !Calendar.current.isDateInToday($0.note.updatedAt) }
    }

    private var recentSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(trimmedQuery.isEmpty ? "LOG" : "MATCHES")
                    .font(mono(10)).tracking(1.8).textCase(.uppercase)
                    .foregroundStyle(pal.inkMuted)
                Spacer()
                Text("\(filtered.count) REC")
                    .font(mono(10)).tracking(1)
                    .foregroundStyle(pal.inkGhost)
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 10)

            if scopedNotes.isEmpty {
                emptyState(sidebarEmptyMessage)
            } else if filtered.isEmpty {
                emptyState("No matches — Return creates “\(trimmedQuery)”.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !todayItems.isEmpty {
                            sidebarSection("Today")
                            ForEach(todayItems, id: \.note.id) { sidebarRow($0, earlier: false) }
                        }
                        if !earlierItems.isEmpty {
                            sidebarSection("Earlier")
                            ForEach(earlierItems, id: \.note.id) { sidebarRow($0, earlier: true) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .background(SubtleScroller())
            }
        }
    }

    private func sidebarSection(_ title: String) -> some View {
        Text(title)
            .font(mono(9)).tracking(2).textCase(.uppercase)
            .foregroundStyle(pal.inkGhost)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func sidebarRow(_ item: (index: Int, note: Note), earlier: Bool) -> some View {
        RecentNoteRow(
            index: item.index,
            note: item.note,
            accent: accent,
            selected: item.note.id == selectedNote?.id,
            earlier: earlier,
            onSelect: { selectedNoteID = item.note.id },
            onOpen: { open(item.note) },
            onCopyMarkdown: { copyToPasteboard(item.note.content) },
            onCopyPath: {
                copyToPasteboard(
                    AppDelegate.notesDirectory()
                        .appendingPathComponent("\(item.note.id).md").path
                )
            },
            onDelete: { delete(item.note) }
        )
    }

    private var canvasPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("CANVAS")
                    .font(mono(10))
                    .tracking(1.6)
                    .foregroundStyle(pal.inkMid)

                if model.workspaceScope != .all {
                    Text("/")
                        .font(mono(10))
                        .foregroundStyle(pal.inkGhost)
                    Text(activeWorkspaceTitle.uppercased())
                        .font(mono(9.5, .medium))
                        .tracking(0.8)
                        .foregroundStyle(accentBright)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                CanvasModePicker(selection: $canvasMode, accent: accent)

                toolbarSeparator

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { canvasExpanded.toggle() }
                } label: {
                    Image(systemName: canvasExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(pal.ink)  // #c4c8c6
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(canvasExpanded ? "Show recents" : "Expand canvas")
                .accessibilityLabel(canvasExpanded ? "Show recents" : "Expand canvas")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)

            hairline

            Group {
                if filtered.isEmpty {
                    emptyCanvas
                } else {
                    switch canvasMode {
                    case .grid:
                        NoteCardGrid(
                            notes: filtered,
                            selectedNoteID: selectedNote?.id,
                            accent: noteAccent,
                            onSelect: { selectedNoteID = $0.id },
                            onOpen: open
                        )
                    case .constellation:
                        NoteConstellation(
                            notes: filtered,
                            selectedNoteID: selectedNote?.id,
                            accent: accent,
                            onSelect: { selectedNoteID = $0.id },
                            onOpen: open
                        )
                    case .list:
                        CanvasNoteList(
                            notes: filtered,
                            selectedNoteID: selectedNote?.id,
                            accent: noteAccent,
                            onSelect: { selectedNoteID = $0.id },
                            onOpen: open
                        )
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(pal.strokeBase.opacity(0.1))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(pal.strokeBase.opacity(0.18))
            Text(emptyCanvasTitle)
                .font(.system(size: 12))
                .foregroundStyle(pal.strokeBase.opacity(0.36))
            if trimmedQuery.isEmpty, model.workspaceScope != .all {
                Text("New notes will land in this workspace.")
                    .font(mono(10))
                    .foregroundStyle(pal.strokeBase.opacity(0.26))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasSurface())
    }

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("CANVAS")
                    .font(mono(10, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(pal.ink)
                Text("/")
                    .font(mono(10))
                    .foregroundStyle(pal.inkGhost)
                Text("v\(appVersion)")
                    .font(mono(9.5))
                    .foregroundStyle(pal.inkMuted)
            }

            Spacer()

            Label(
                peerSyncUnavailableReason != nil
                    ? "MOBILE OFF"
                    : trustedPeerCount == 0
                    ? "MOBILE READY"
                    : "MOBILE · \(trustedPeerCount) APPROVED",
                systemImage: peerSyncUnavailableReason != nil
                    ? "wifi.slash"
                    : trustedPeerCount == 0 ? "iphone.badge.plus" : "lock.shield"
            )
            .font(mono(9.5, .medium))
            .tracking(1.2)
            .foregroundStyle(pal.inkMuted)
            .help(
                peerSyncUnavailableReason
                    ?? "Nearby iPhones and iPads ask for approval on this Mac"
            )
            .accessibilityLabel(
                peerSyncUnavailableReason != nil
                    ? "Mobile access unavailable"
                    : trustedPeerCount == 0
                    ? "Mobile access ready"
                    : "\(trustedPeerCount) approved mobile \(trustedPeerCount == 1 ? "device" : "devices")"
            )

            footerSeparator

            FooterActionButton(
                icon: "eye",
                label: "Show/Hide",
                shortcut: blinkShortcut,
                help: "Show or hide all notes (\(blinkShortcut))",
                action: toggleBlink
            )
            FooterActionButton(
                icon: "square.grid.3x3",
                label: "Grid",
                shortcut: nil,
                help: "Show the spatial grid",
                action: showGrid
            )
            FooterActionButton(
                icon: "command",
                label: "Commands",
                shortcut: "⌘K",
                help: "Open commands and notes (⌘K)",
                action: showCommands
            )

            footerSeparator

            FooterUtilitiesMenu(
                openHelp: openGuide,
                openSettings: openSettings
            )

            footerSeparator

            FooterActionButton(
                icon: "power",
                label: "Quit",
                shortcut: "⌘Q",
                help: "Quit Canvas (⌘Q)",
                action: quit
            )
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(pal.footerFill)
    }

    private var footerSeparator: some View {
        Rectangle()
            .fill(pal.strokeBase.opacity(0.11))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 8)
    }

    private var hairline: some View {
        Rectangle().fill(pal.strokeBase.opacity(0.09)).frame(height: 1)
    }

    private var verticalHairline: some View {
        Rectangle().fill(pal.strokeBase.opacity(0.09)).frame(width: 1)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(pal.strokeBase.opacity(0.38))
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var sidebarEmptyMessage: String {
        guard trimmedQuery.isEmpty else {
            return "No matches — Return creates “\(trimmedQuery)”."
        }
        switch model.workspaceScope {
        case .all:
            return "No notes yet — create your first thought."
        case .unfiled:
            return "No unfiled notes — new notes will land here."
        case .workspace:
            return "Blank slate — create the first note in \(activeWorkspaceTitle)."
        }
    }

    private var emptyCanvasTitle: String {
        if !trimmedQuery.isEmpty { return "No notes on this canvas" }
        return switch model.workspaceScope {
        case .all: "Your notes will gather here"
        case .unfiled: "No unfiled notes"
        case .workspace: "\(activeWorkspaceTitle) is a blank slate"
        }
    }

    private func normalizeWorkspaceScope() {
        guard case .workspace(let id) = model.workspaceScope,
              !workspaceEntries.contains(where: { $0.id == id })
        else { return }
        model.selectWorkspace(.all)
    }

    private func openFirstOrCreate() {
        if let selectedNote {
            open(selectedNote)
        } else if let first = filtered.first {
            open(first)
        } else if !trimmedQuery.isEmpty {
            createFromQuery()
        }
    }

    private func createFromQuery() {
        let text = trimmedQuery
        Task { await model.createNote(content: text) }
        dismiss()
    }

    /// Route macOS's standard dictation command to the capture field. The OS
    /// owns permissions, language, audio, and its dictation HUD; Blink only
    /// restores field focus and invokes the responder-chain action.
    private func startSystemDictation() {
        fieldFocused = true
        DispatchQueue.main.async {
            beginDictation()
        }
    }

    private func open(_ note: Note) {
        Task { await model.openNote(id: note.id) }
        dismiss()
    }

    private func delete(_ note: Note) {
        Task { await model.deleteNote(id: note.id) }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func noteAccent(_ note: Note) -> Color {
        let resolved = BlinkConfigStore.shared.config.resolved(for: note.presentation)
        if let raw = resolved.editor.accentColor, let color = Color(blinkHex: raw) {
            return color
        }
        switch resolved.panel.sheet.lowercased() {
        case "card": return Color(red: 0.35, green: 0.82, blue: 0.61)
        case "glass", "dotted": return accent
        default: return Color(red: 0.48, green: 0.52, blue: 0.59)
        }
    }
}

private struct WorkspaceScopeMenu: View {
    @Environment(\.popoverPalette) private var pal
    @State private var hovered = false

    let selection: WorkspaceScope
    let title: String
    let count: Int
    let allCount: Int
    let unfiledCount: Int
    let workspaces: [WorkspaceMenuEntry]
    let onSelect: (WorkspaceScope) -> Void

    var body: some View {
        Menu {
            scopeButton(.all, title: "All notes", count: allCount)
            scopeButton(.unfiled, title: "Unfiled", count: unfiledCount)

            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    scopeButton(
                        .workspace(workspace.id),
                        title: workspace.title,
                        count: workspace.noteCount
                    )
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .light))
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 132, alignment: .leading)
                Text("\(count)")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(pal.inkMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(hovered ? pal.ink : pal.inkMid)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(pal.strokeBase.opacity(hovered ? 0.07 : 0.025))
            .overlay(Rectangle().stroke(pal.strokeBase.opacity(hovered ? 0.15 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.1)) { hovered = isHovered }
        }
        .help("Filter notes and panels by workspace")
        .accessibilityLabel("Workspace \(title), \(count) notes")
    }

    private func scopeButton(_ scope: WorkspaceScope, title: String, count: Int) -> some View {
        Button { onSelect(scope) } label: {
            Label(
                "\(title) · \(count)",
                systemImage: selection == scope ? "checkmark" : "circle"
            )
        }
    }
}

private struct NewNoteButton: View {
    @Environment(\.popoverPalette) private var pal
    @State private var hovered = false

    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pal.accentBright)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(pal.ink)
                Text("⌘↩")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(pal.inkMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(pal.strokeBase.opacity(0.1), lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(pal.strokeBase.opacity(hovered ? 0.07 : 0.025))
            .overlay(Rectangle().stroke(pal.accent.opacity(hovered ? 0.42 : 0.20), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.1)) { hovered = isHovered }
        }
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct FooterActionButton: View {
    @Environment(\.popoverPalette) private var pal
    @State private var hovered = false

    let icon: String
    let label: String
    let shortcut: String?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .light))
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.55)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(pal.inkMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().stroke(pal.strokeBase.opacity(0.1), lineWidth: 1))
                }
            }
            .foregroundStyle(hovered ? pal.ink : pal.inkMid)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(pal.strokeBase.opacity(hovered ? 0.07 : 0.025))
            .overlay(Rectangle().stroke(pal.strokeBase.opacity(hovered ? 0.15 : 0.055), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.1)) { hovered = isHovered }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Help and configuration are durable utility windows, not immediate canvas
/// actions. Keeping them behind one entry makes Commands the clear primary
/// launcher while preserving both destinations.
private struct FooterUtilitiesMenu: View {
    @Environment(\.popoverPalette) private var pal
    @State private var hovered = false

    let openHelp: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Menu {
            Button(action: openHelp) {
                Label("Help & Shortcuts", systemImage: "questionmark.circle")
            }
            Divider()
            Button(action: openSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11.5, weight: .light))
                Text("MORE")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.55)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(hovered ? pal.ink : pal.inkMid)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(pal.strokeBase.opacity(hovered ? 0.07 : 0.025))
            .overlay(
                Rectangle().stroke(
                    pal.strokeBase.opacity(hovered ? 0.15 : 0.055),
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.1)) { hovered = isHovered }
        }
        .help("Help, shortcuts, and settings")
        .accessibilityLabel("More Canvas options")
    }
}

private enum CanvasMode: String, CaseIterable, Identifiable {
    case grid
    case constellation
    case list

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .constellation: "point.3.connected.trianglepath.dotted"
        case .list: "line.3.horizontal"
        }
    }
}

private struct CanvasModePicker: View {
    @Environment(\.popoverPalette) private var pal
    @Binding var selection: CanvasMode
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(CanvasMode.allCases) { mode in
                Button { selection = mode } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(
                            selection == mode
                                ? pal.accentBright
                                : pal.ink        // #c4c8c6
                        )
                        .frame(width: 24, height: 24)
                        .background(selection == mode ? accent.opacity(0.1) : .clear)  // sharp
                        .overlay {
                            if selection == mode {
                                Rectangle().stroke(accent.opacity(0.3), lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.rawValue.capitalized)
                .accessibilityLabel("\(mode.rawValue.capitalized) view")
            }
        }
    }
}

private struct RecentNoteRow: View {
    @Environment(\.popoverPalette) private var pal
    let index: Int
    let note: Note
    let accent: Color
    let selected: Bool
    let earlier: Bool
    var onSelect: () -> Void
    var onOpen: () -> Void
    var onCopyMarkdown: () -> Void
    var onCopyPath: () -> Void
    var onDelete: () -> Void

    @State private var hovered = false

    // Tiered ink: the active row is cool, today rows read clear, earlier ones recede.
    private var numberColor: Color {
        if selected { return pal.accentBright }
        return earlier ? pal.inkGhost       // #3d4143
                       : pal.inkFaint       // #54595b
    }
    private var titleColor: Color {
        if selected { return pal.inkStrong } // #fbeee8
        return earlier ? pal.inkMid       // #7f8587
                       : pal.ink       // #d2d5d3
    }
    private var timeColor: Color {
        if selected { return pal.selectedMeta }
        return earlier ? pal.inkFaint       // #54595b
                       : pal.inkMuted          // #6b7072
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10.5, weight: .light, design: .monospaced))
                    .foregroundStyle(numberColor)

                Text(note.title)
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(note.updatedAt.blinkCompactRelative)
                    .font(.system(size: 10.5, weight: .light, design: .monospaced))
                    .foregroundStyle(timeColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                selected ? accent.opacity(0.08) : (hovered ? pal.strokeBase.opacity(0.04) : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(accent).frame(width: 2)  // inset left bar
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .contextMenu {
            Button("Open as Panel", action: onOpen)
            Divider()
            Button("Copy as Markdown", action: onCopyMarkdown)
            Button("Copy Path", action: onCopyPath)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct NoteConstellation: View {
    @Environment(\.popoverPalette) private var pal
    let notes: [Note]
    let selectedNoteID: String?
    let accent: Color
    let onSelect: (Note) -> Void
    let onOpen: (Note) -> Void

    /// Ephemeral overview placements for this popover session only. Intentionally
    /// not written to `blink.slot` or panel frame autosave — the canvas is a
    /// spatial browser, not the durable layout contract.
    @State private var positionOverrides: [String: CGPoint] = [:]
    @State private var activeDrag: OverviewDrag?
    @State private var suppressOpenUntil: Date?

    private struct OverviewDrag {
        let noteID: String
        let origin: CGPoint
        var translation: CGSize = .zero
        var didMove = false
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let basePoints = ConstellationLayout.points(for: notes, in: size)
            let points = resolvedPoints(base: basePoints, size: size)

            ZStack(alignment: .topLeading) {
                CanvasSurface()

                Canvas { context, _ in
                    for edge in ConstellationLayout.edges(for: notes) {
                        guard let start = points[edge.0], let end = points[edge.1] else { continue }
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        context.stroke(
                            path,
                            with: .color(pal.strokeBase.opacity(0.08)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 7])
                        )
                    }
                }
                .allowsHitTesting(false)

                ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
                    if let point = points[note.id] {
                        let isDragging = activeDrag?.noteID == note.id
                        ConstellationNode(
                            index: offset + 1,
                            note: note,
                            accent: accent,
                            selected: note.id == selectedNoteID,
                            isDragging: isDragging,
                            onSelect: { onSelect(note) },
                            onOpen: {
                                guard !shouldSuppressOpen else { return }
                                onOpen(note)
                            },
                            onDragChanged: { translation in
                                beginOrUpdateDrag(
                                    note: note,
                                    base: basePoints[note.id] ?? point,
                                    translation: translation
                                )
                            },
                            onDragEnded: { translation in
                                endDrag(
                                    note: note,
                                    base: basePoints[note.id] ?? point,
                                    translation: translation,
                                    size: size
                                )
                            }
                        )
                        .position(point)
                        .zIndex(isDragging ? 100 : (note.id == selectedNoteID ? 10 : Double(notes.count - offset)))
                    }
                }
            }
            .coordinateSpace(name: "constellationCanvas")
            .clipShape(Rectangle())
            .onChange(of: notes.map(\.id)) { _, ids in
                let keep = Set(ids)
                positionOverrides = positionOverrides.filter { keep.contains($0.key) }
                if let drag = activeDrag, !keep.contains(drag.noteID) {
                    activeDrag = nil
                }
            }
            .onChange(of: size) { _, newSize in
                positionOverrides = positionOverrides.mapValues {
                    ConstellationLayout.clamp($0, in: newSize)
                }
            }
        }
    }

    private var shouldSuppressOpen: Bool {
        if activeDrag?.didMove == true { return true }
        if let until = suppressOpenUntil, Date() < until { return true }
        return false
    }

    private func resolvedPoints(base: [String: CGPoint], size: CGSize) -> [String: CGPoint] {
        var result = base
        for (id, point) in positionOverrides where result[id] != nil {
            result[id] = ConstellationLayout.clamp(point, in: size)
        }
        if let drag = activeDrag, result[drag.noteID] != nil {
            result[drag.noteID] = ConstellationLayout.clamp(
                CGPoint(
                    x: drag.origin.x + drag.translation.width,
                    y: drag.origin.y + drag.translation.height
                ),
                in: size
            )
        }
        return result
    }

    private func beginOrUpdateDrag(note: Note, base: CGPoint, translation: CGSize) {
        var drag: OverviewDrag
        if let existing = activeDrag, existing.noteID == note.id {
            drag = existing
        } else {
            drag = OverviewDrag(noteID: note.id, origin: positionOverrides[note.id] ?? base)
            onSelect(note)
        }
        drag.translation = translation
        if hypot(translation.width, translation.height) >= 4 {
            drag.didMove = true
        }
        activeDrag = drag
    }

    private func endDrag(note: Note, base: CGPoint, translation: CGSize, size: CGSize) {
        let origin: CGPoint
        let didMove: Bool
        if let drag = activeDrag, drag.noteID == note.id {
            origin = drag.origin
            didMove = drag.didMove || hypot(translation.width, translation.height) >= 4
        } else {
            origin = positionOverrides[note.id] ?? base
            didMove = hypot(translation.width, translation.height) >= 4
        }
        if didMove {
            positionOverrides[note.id] = ConstellationLayout.clamp(
                CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                in: size
            )
            suppressOpenUntil = Date().addingTimeInterval(0.35)
        }
        activeDrag = nil
    }
}

private struct ConstellationNode: View {
    @Environment(\.popoverPalette) private var pal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let note: Note
    let accent: Color
    let selected: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var hovered = false

    // Recency tier drives prominence: A (freshest) → B → C recede into the board.
    // Selection and drag change chrome only — never padding, type size, or extra
    // labels — so external geometry stays put.
    private var tier: Int { index <= 3 ? 0 : (index <= 6 ? 1 : 2) }

    private var bgColor: Color {
        if selected || isDragging { return pal.nodeSelBg }
        switch tier {
        case 0: return pal.nodeBg0
        case 1: return pal.nodeBg1
        default: return pal.nodeBg2
        }
    }
    private var borderColor: Color {
        if selected || isDragging { return accent.opacity(0.55) }
        switch tier {
        case 0: return pal.strokeBase.opacity(hovered ? 0.25 : 0.11)
        case 1: return pal.strokeBase.opacity(hovered ? 0.18 : 0.08)
        default: return pal.strokeBase.opacity(hovered ? 0.12 : 0.05)
        }
    }
    private var titleColor: Color {
        if selected || isDragging { return pal.strokeBase }
        switch tier {
        case 0: return pal.inkBright
        case 1: return pal.inkMid
        default: return pal.inkFaint
        }
    }
    private var numberColor: Color {
        if selected || isDragging { return pal.accentBright }
        switch tier {
        case 0: return pal.inkFaint
        case 1: return pal.inkGhost
        default: return pal.inkGhost
        }
    }

    private var horizontalPadding: CGFloat { tier == 0 ? 12 : 10 }
    private var verticalPadding: CGFloat { tier == 0 ? 8 : 6 }
    private var numberSize: CGFloat { tier == 0 ? 10 : 9.5 }
    private var titleSize: CGFloat { tier == 0 ? 11.5 : 11 }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(.system(size: numberSize, weight: .light, design: .monospaced))
                    .foregroundStyle(numberColor)
                Text(note.title)
                    .font(.system(size: titleSize, weight: .light, design: .monospaced))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(bgColor)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
            .overlay { if selected || isDragging { CornerTicks(color: accent) } }
            .shadow(
                color: isDragging ? accent.opacity(0.26) : .black.opacity(0.18),
                radius: isDragging ? 10 : 4,
                x: 0,
                y: isDragging ? 5 : 2
            )
            .scaleEffect(isDragging && !reduceMotion ? 1.015 : 1)
            .offset(y: hovered && !selected && !isDragging ? -1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDragging)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("constellationCanvas"))
                .onChanged { value in onDragChanged(value.translation) }
                .onEnded { value in onDragEnded(value.translation) }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .help("Drag to arrange · double-click to open \(note.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Drag to reposition on the canvas. Double-click to open.")
    }
}

/// Signal-blue L-brackets just outside a node's four corners — the "locked/active"
/// framing from the design.
private struct CornerTicks: View {
    let color: Color
    var len: CGFloat = 7
    var lineWidth: CGFloat = 1.5
    var out: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: -out, y: -out + len)); p.addLine(to: CGPoint(x: -out, y: -out)); p.addLine(to: CGPoint(x: -out + len, y: -out))
                p.move(to: CGPoint(x: w + out - len, y: -out)); p.addLine(to: CGPoint(x: w + out, y: -out)); p.addLine(to: CGPoint(x: w + out, y: -out + len))
                p.move(to: CGPoint(x: -out, y: h + out - len)); p.addLine(to: CGPoint(x: -out, y: h + out)); p.addLine(to: CGPoint(x: -out + len, y: h + out))
                p.move(to: CGPoint(x: w + out - len, y: h + out)); p.addLine(to: CGPoint(x: w + out, y: h + out)); p.addLine(to: CGPoint(x: w + out, y: h + out - len))
            }
            .stroke(color, lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

private struct NoteCardGrid: View {
    @Environment(\.popoverPalette) private var pal
    let notes: [Note]
    let selectedNoteID: String?
    let accent: (Note) -> Color
    let onSelect: (Note) -> Void
    let onOpen: (Note) -> Void

    /// Compact adaptive cards on a 4pt rhythm; selection is stroke/fill only.
    // Three readable columns beside Recents, four when the canvas is expanded.
    // This uses the available height instead of compressing twelve notes into
    // three rows above a large empty floor.
    private let columns = [GridItem(.adaptive(minimum: 216, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(notes, id: \.id) { note in
                    let selected = note.id == selectedNoteID
                    Button { onSelect(note) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill(accent(note)).frame(width: 8, height: 8)
                                Text(note.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(pal.strokeBase.opacity(selected ? 0.90 : 0.82))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(note.updatedAt.blinkCompactRelative)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(pal.strokeBase.opacity(0.28))
                            }
                            Text(note.blinkExcerpt)
                                .font(.system(size: 11))
                                .foregroundStyle(pal.strokeBase.opacity(0.42))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .topLeading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selected ? pal.accent.opacity(0.055) : pal.strokeBase.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    selected ? pal.accent.opacity(0.50) : pal.strokeBase.opacity(0.07),
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(note) })
                    .help("Double-click to open \(note.title)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(CanvasSurface())
    }
}

private struct CanvasNoteList: View {
    @Environment(\.popoverPalette) private var pal
    let notes: [Note]
    let selectedNoteID: String?
    let accent: (Note) -> Color
    let onSelect: (Note) -> Void
    let onOpen: (Note) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(notes, id: \.id) { note in
                    let selected = note.id == selectedNoteID
                    Button { onSelect(note) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(accent(note)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(pal.strokeBase.opacity(selected ? 0.90 : 0.80))
                                    .lineLimit(1)
                                Text(note.blinkExcerpt)
                                    .font(.system(size: 10))
                                    .foregroundStyle(pal.strokeBase.opacity(0.35))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(note.updatedAt.blinkCompactRelative)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(pal.strokeBase.opacity(0.28))
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11))
                                .foregroundStyle(pal.strokeBase.opacity(selected ? 0.40 : 0.24))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(
                            selected ? pal.accent.opacity(0.05) : pal.strokeBase.opacity(0.02),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    selected ? pal.accent.opacity(0.46) : pal.strokeBase.opacity(0.05),
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(note) })
                    .help("Double-click to open \(note.title)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(CanvasSurface())
    }
}

/// SwiftUI follows the user's global "always show scroll bars" preference,
/// which makes this narrow recents rail visually dominate the notes. The rail
/// remains fully wheel/trackpad-scrollable, but drops that heavy fixed chrome.
private struct SubtleScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> SubtleScrollerProbe {
        SubtleScrollerProbe()
    }

    func updateNSView(_ nsView: SubtleScrollerProbe, context: Context) {
        nsView.configureEnclosingScrollView()
    }
}

private final class SubtleScrollerProbe: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
    }

    func configureEnclosingScrollView() {
        DispatchQueue.main.async { [weak self] in
            var ancestor = self?.superview
            while let view = ancestor, !(view is NSScrollView) {
                ancestor = view.superview
            }
            guard let scrollView = ancestor as? NSScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = false
        }
    }
}

private struct CanvasSurface: View {
    @Environment(\.popoverPalette) private var pal
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(pal.canvasFill)
            DotGrid()
                .clipShape(RoundedRectangle(cornerRadius: 15))
            RoundedRectangle(cornerRadius: 15)
                .stroke(pal.strokeBase.opacity(0.065), lineWidth: 1)
        }
    }
}

private struct DotGrid: View {
    @Environment(\.popoverPalette) private var pal
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 28
            var x: CGFloat = 14
            while x < size.width {
                var y: CGFloat = 14
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(pal.strokeBase.opacity(0.055))
                    )
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// The faint 1px line grid that underlays the whole popout.
private struct TerminalGrid: View {
    @Environment(\.popoverPalette) private var pal
    var step: CGFloat = 40
    var opacity: Double = 0.02

    var body: some View {
        Canvas { context, size in
            let color = pal.strokeBase.opacity(opacity)
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(color), lineWidth: 1)
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(color), lineWidth: 1)
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// The four L-brackets framing the popout, per the design's terminal chrome.
private struct PopoutCorners: View {
    @Environment(\.popoverPalette) private var pal
    var len: CGFloat = 13
    var body: some View {
        let color = pal.popoutCorner  // #5a6063
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: 0, y: len)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: len, y: 0))
                p.move(to: CGPoint(x: w - len, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: len))
                p.move(to: CGPoint(x: 0, y: h - len)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: len, y: h))
                p.move(to: CGPoint(x: w - len, y: h)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - len))
            }
            .stroke(color, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private enum ConstellationLayout {
    /// Inset so node centers stay fully inside the canvas surface.
    private static let edgeInset = CGSize(width: 72, height: 22)

    private static let candidates: [CGPoint] = [
        CGPoint(x: 0.16, y: 0.20), CGPoint(x: 0.57, y: 0.13),
        CGPoint(x: 0.83, y: 0.32), CGPoint(x: 0.42, y: 0.43),
        CGPoint(x: 0.19, y: 0.62), CGPoint(x: 0.52, y: 0.78),
        CGPoint(x: 0.78, y: 0.65), CGPoint(x: 0.12, y: 0.39),
        CGPoint(x: 0.86, y: 0.13), CGPoint(x: 0.34, y: 0.18),
        CGPoint(x: 0.67, y: 0.42), CGPoint(x: 0.30, y: 0.82),
        CGPoint(x: 0.70, y: 0.84), CGPoint(x: 0.90, y: 0.52),
        CGPoint(x: 0.10, y: 0.81), CGPoint(x: 0.49, y: 0.61),
        CGPoint(x: 0.25, y: 0.45), CGPoint(x: 0.72, y: 0.22),
    ]

    static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let minX = min(edgeInset.width, size.width / 2)
        let maxX = max(minX, size.width - edgeInset.width)
        let minY = min(edgeInset.height, size.height / 2)
        let maxY = max(minY, size.height - edgeInset.height)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    static func points(for notes: [Note], in size: CGSize) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        var occupied = Set<Int>()

        for note in notes.sorted(by: { $0.id < $1.id }) {
            let index: Int
            if let slot = note.presentation.slot, (1...9).contains(slot) {
                let row = (slot - 1) / 3
                let column = (slot - 1) % 3
                let slotPoint = CGPoint(
                    x: 0.18 + CGFloat(column) * 0.32,
                    y: 0.18 + CGFloat(row) * 0.30
                )
                index = nearestCandidate(to: slotPoint, excluding: occupied)
            } else {
                let seed = stableHash(note.id)
                let start = Int(seed % UInt64(candidates.count))
                index = (0..<candidates.count)
                    .map { (start + $0) % candidates.count }
                    .first { !occupied.contains($0) } ?? start
            }
            occupied.insert(index)
            let normalized = candidates[index]
            result[note.id] = clamp(
                CGPoint(x: normalized.x * size.width, y: normalized.y * size.height),
                in: size
            )
        }
        return result
    }

    static func edges(for notes: [Note]) -> [(String, String)] {
        let lookup = Dictionary(
            notes.flatMap { note in
                [(note.id.lowercased(), note.id), (note.title.lowercased(), note.id)]
            },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var result: [(String, String)] = []
        let pattern = #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for note in notes {
            let range = NSRange(note.content.startIndex..<note.content.endIndex, in: note.content)
            for match in regex.matches(in: note.content, range: range) {
                guard let targetRange = Range(match.range(at: 1), in: note.content) else { continue }
                let reference = note.content[targetRange].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let target = lookup[reference], target != note.id else { continue }
                let key = [note.id, target].sorted().joined(separator: "→")
                if seen.insert(key).inserted { result.append((note.id, target)) }
            }
        }
        return result
    }

    static func label(for point: CGPoint, in size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "x0 · y0" }
        return "x\(Int(point.x / size.width * 100)) · y\(Int(point.y / size.height * 100))"
    }

    private static func nearestCandidate(to point: CGPoint, excluding occupied: Set<Int>) -> Int {
        candidates.indices
            .filter { !occupied.contains($0) }
            .min {
                squaredDistance(candidates[$0], point) < squaredDistance(candidates[$1], point)
            } ?? 0
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private extension Note {
    var blinkExcerpt: String {
        var lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.first.map({ Note.extractTitle(from: $0) == title }) == true {
            lines.removeFirst()
        }
        let value = lines.joined(separator: " ")
            .replacingOccurrences(of: #"[#>*_`]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "No additional text yet." : value
    }
}

private extension Date {
    var blinkCompactRelative: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }
        if seconds < 2_592_000 { return "\(Int(seconds / 604_800))w" }
        return "\(Int(seconds / 2_592_000))mo"
    }

    var blinkLongRelative: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hours ago" }
        if seconds < 172_800 { return "yesterday" }
        return "\(Int(seconds / 86_400)) days ago"
    }
}

private extension Color {
    init?(blinkHex raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
        )
    }
}

// MARK: - Appearance palette

/// The popover's full color set for one appearance. `strokeBase` collapses the
/// terminal chrome — every hairline, border, dot, grid line, and hover fill is
/// that color at some opacity, and it doubles as ink-on-surface text — so light
/// mode is mostly "flip white → near-black." The opaque mono inks and the paper
/// backgrounds carry explicit light values. The translucent navigation rail
/// and matte footer are separate semantic surfaces in both schemes.
private struct PopoverPalette {
    let accent: Color
    let accentBright: Color

    /// White in dark, near-black in light: base for all opacity-based chrome
    /// and for ink-on-surface text.
    var strokeBase: Color

    // Tiered mono ink, brightest → faintest.
    var inkStrong: Color   // selected titles
    var inkBright: Color   // input text, freshest node title
    var ink: Color         // icons, keycaps, today rows
    var inkMid: Color      // earlier titles, footer, mid-tier nodes
    var inkMuted: Color    // magnifier, section labels, key badges
    var inkFaint: Color    // row numbers, status line
    var inkGhost: Color    // counts, receded numbers, the "/" divider
    var selectedMeta: Color // a selected row's timestamp

    // Opaque surfaces.
    var bgBase: Color
    var bgGrad1: Color
    var bgGrad2: Color
    var bgGrad3: Color
    var navigationFill: Color
    var footerFill: Color
    var canvasFill: Color
    var nodeSelBg: Color
    var nodeBg0: Color
    var nodeBg1: Color
    var nodeBg2: Color
    var popoutCorner: Color

    static let dark = PopoverPalette(
        accent: Color(red: 0.365, green: 0.620, blue: 0.980),       // #5d9efa
        accentBright: Color(red: 0.514, green: 0.706, blue: 1.000), // #83b4ff
        strokeBase: .white,
        inkStrong: Color(red: 0.984, green: 0.933, blue: 0.910),   // #fbeee8
        inkBright: Color(red: 0.902, green: 0.910, blue: 0.902),   // #e6e8e6
        ink: Color(red: 0.824, green: 0.835, blue: 0.827),         // #d2d5d3
        inkMid: Color(red: 0.498, green: 0.522, blue: 0.529),      // #7f8587
        inkMuted: Color(red: 0.420, green: 0.440, blue: 0.450),    // #6b7072
        inkFaint: Color(red: 0.329, green: 0.349, blue: 0.357),    // #54595b
        inkGhost: Color(red: 0.239, green: 0.255, blue: 0.263),    // #3d4143
        selectedMeta: Color(red: 0.514, green: 0.706, blue: 1.000), // #83b4ff
        bgBase: Color(red: 0.039, green: 0.043, blue: 0.047),      // #0a0b0c
        bgGrad1: Color(red: 0.090, green: 0.098, blue: 0.110),     // #17191c
        bgGrad2: Color(red: 0.047, green: 0.055, blue: 0.063),     // #0c0e10
        bgGrad3: Color(red: 0.020, green: 0.024, blue: 0.027),     // #050607
        navigationFill: Color(red: 0.028, green: 0.030, blue: 0.033).opacity(0.64),
        footerFill: Color(red: 0.030, green: 0.029, blue: 0.030),  // matte #080708
        canvasFill: Color(red: 0.025, green: 0.031, blue: 0.041).opacity(0.93),
        nodeSelBg: Color(red: 0.071, green: 0.063, blue: 0.067),   // #121011
        nodeBg0: Color(red: 0.055, green: 0.059, blue: 0.067),     // #0e0f11
        nodeBg1: Color(red: 0.039, green: 0.043, blue: 0.047),     // #0a0b0c
        nodeBg2: Color(red: 0.031, green: 0.035, blue: 0.039),     // #08090a
        popoutCorner: Color(red: 0.353, green: 0.376, blue: 0.388)  // #5a6063
    )

    static let light = PopoverPalette(
        accent: Color(red: 0.176, green: 0.365, blue: 0.690),       // #2d5daf
        accentBright: Color(red: 0.196, green: 0.408, blue: 0.741), // #3268bd
        strokeBase: Color(red: 0.086, green: 0.078, blue: 0.070),  // warm near-black
        inkStrong: Color(red: 0.090, green: 0.075, blue: 0.063),   // #17130f
        inkBright: Color(red: 0.130, green: 0.116, blue: 0.102),   // #211d1a
        ink: Color(red: 0.205, green: 0.185, blue: 0.165),         // #342f2a
        inkMid: Color(red: 0.360, green: 0.335, blue: 0.310),      // #5c554f
        inkMuted: Color(red: 0.460, green: 0.435, blue: 0.405),    // #756f67
        inkFaint: Color(red: 0.560, green: 0.535, blue: 0.505),    // #8f8880
        inkGhost: Color(red: 0.680, green: 0.655, blue: 0.622),    // #ada79e
        selectedMeta: Color(red: 0.196, green: 0.408, blue: 0.741), // #3268bd
        bgBase: Color(red: 0.949, green: 0.941, blue: 0.925),      // #f2f0ec paper
        bgGrad1: Color(red: 0.988, green: 0.980, blue: 0.965),     // #fcfaf6
        bgGrad2: Color(red: 0.949, green: 0.941, blue: 0.925),     // #f2f0ec
        bgGrad3: Color(red: 0.910, green: 0.898, blue: 0.874),     // #e8e5df
        navigationFill: Color(red: 0.934, green: 0.928, blue: 0.914).opacity(0.60),
        footerFill: Color(red: 0.890, green: 0.875, blue: 0.847),  // matte warm paper
        canvasFill: Color(red: 1.0, green: 0.996, blue: 0.988).opacity(0.72),
        nodeSelBg: Color(red: 1.0, green: 1.0, blue: 1.0),         // white card
        nodeBg0: Color(red: 0.988, green: 0.984, blue: 0.973),     // #fcfbf8
        nodeBg1: Color(red: 0.957, green: 0.949, blue: 0.933),     // #f4f2ee
        nodeBg2: Color(red: 0.929, green: 0.918, blue: 0.898),     // #ede9e5
        popoutCorner: Color(red: 0.660, green: 0.635, blue: 0.600)  // #a8a29a
    )

    static func forScheme(_ scheme: AppScheme) -> PopoverPalette {
        scheme == .dark ? .dark : .light
    }
}

private struct PopoverPaletteKey: EnvironmentKey {
    static let defaultValue = PopoverPalette.dark
}

private extension EnvironmentValues {
    var popoverPalette: PopoverPalette {
        get { self[PopoverPaletteKey.self] }
        set { self[PopoverPaletteKey.self] = newValue }
    }
}
