import BlinkCore
import BlinkPeer
import SwiftUI
import UIKit

struct BlinkBackdrop: View {
    var body: some View {
        BlinkMobileTheme.canvas
            .ignoresSafeArea()
    }
}

struct BlinkMark: View {
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .stroke(BlinkMobileTheme.signal, lineWidth: max(1, size * 0.06))
            Rectangle()
                .fill(BlinkMobileTheme.signal)
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: -size * 0.12, y: -size * 0.12)
            Rectangle()
                .fill(BlinkMobileTheme.signal)
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: size * 0.12, y: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/*
 THESIS: Blink mobile is the carbon copy of a spatial desk: chronology is the
 structure and ledger discipline is the geometry. OWN-WORLD: warm paper or
 graphite, a continuous indexed rail, sharp rules, square state marks, and
 monospaced machine language. STORY: choose a workspace, verify the copy's age,
 scan the log, search from the thumb rail, and read exact Markdown offline.
 FIRST VIEWPORT: workspace large title, explicit trust rule, indexed entries,
 and a bottom search launcher on compact widths. FORM: approved Index Tape
 direction adapted to native SwiftUI navigation, Dynamic Type, and VoiceOver.
 */

struct ContentView: View {
    @ObservedObject var model: BlinkMobileModel
    @State private var selection: String?
    @State private var selectedLogIndex: Int?
    @State private var query = ""
    @State private var workspace: WorkspaceScope = .all
    @State private var showingSettings = false
    @State private var compactSearchActive = false
    @FocusState private var compactSearchFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var scopedNotes: [BlinkSnapshotNote] {
        model.notes.filter { note in
            switch workspace {
            case .all: true
            case .unfiled: note.presentation.workspace == nil
            case .workspace(let id): note.presentation.workspace == id
            }
        }
    }

    private var filteredNotes: [BlinkSnapshotNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return scopedNotes }
        return scopedNotes.filter { note in
            note.title.lowercased().contains(needle)
                || note.tags.contains { $0.lowercased().contains(needle) }
                || noteContent(note).lowercased().contains(needle)
        }
    }

    private var workspaceIDs: [String] {
        Array(Set(model.notes.compactMap(\.presentation.workspace))).sorted()
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular, !dynamicTypeSize.isAccessibilitySize {
                BlinkPadWorkspaceView(
                    model: model,
                    notes: filteredNotes,
                    scopedNoteCount: scopedNotes.count,
                    workspace: $workspace,
                    workspaceIDs: workspaceIDs,
                    query: $query,
                    selection: $selection,
                    onOpenSettings: { showingSettings = true }
                )
            } else {
                NavigationSplitView {
                    adaptiveSidebar
                } detail: {
                    if let selection,
                       let note = model.notes.first(where: { $0.id == selection }) {
                        NoteDetailView(
                            note: note,
                            index: detailIndex(for: note)
                        )
                    } else {
                        detailPlaceholder
                    }
                }
            }
        }
        .tint(BlinkMobileTheme.signal)
        .toolbarBackground(BlinkMobileTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(BlinkBackdrop())
        .onChange(of: selection) { _, selectedID in
            guard let selectedID else {
                selectedLogIndex = nil
                return
            }
            selectedLogIndex = scopedNotes.firstIndex(where: { $0.id == selectedID }).map { $0 + 1 }
                ?? model.notes.firstIndex(where: { $0.id == selectedID }).map { $0 + 1 }
        }
        .sheet(isPresented: $showingSettings) {
            BlinkMobileSettingsView(model: model)
        }
        .alert(
            "Canvas couldn't finish that",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Try again.")
        }
    }

    private var sidebar: some View {
        Group {
            switch model.cacheState {
            case .loading:
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Loading notes…")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Notes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { model.retryCacheLoad() }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                if model.notes.isEmpty {
                    emptyState
                } else {
                    notesList
                }
            }
        }
        .background(BlinkBackdrop())
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var adaptiveSidebar: some View {
        if horizontalSizeClass == .regular {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 380)
                .searchable(
                    text: $query,
                    placement: .sidebar,
                    prompt: "Search \(workspace.title)"
                )
        } else {
            sidebar
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if canSearch {
                        compactSearchFooter
                    }
                }
        }
    }

    private var canSearch: Bool {
        if case .ready = model.cacheState {
            return !model.notes.isEmpty
        }
        return false
    }

    private func detailIndex(for note: BlinkSnapshotNote) -> Int {
        if let currentScopeIndex = scopedNotes.firstIndex(where: { $0.id == note.id }) {
            return currentScopeIndex + 1
        }
        // iPad intentionally keeps the current reader visible across scope
        // changes. Retain the log identity from the scope that opened it.
        return selectedLogIndex
            ?? model.notes.firstIndex(where: { $0.id == note.id }).map { $0 + 1 }
            ?? 1
    }

    private var notesList: some View {
        List(selection: $selection) {
            if let lastSyncedAt = model.lastSyncedAt {
                Section {
                    SyncSummary(
                        state: model.connectionState,
                        lastSyncedAt: lastSyncedAt,
                        isSyncing: model.isSyncing,
                        issueCount: model.snapshot?.issues.count ?? 0
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if filteredNotes.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "No notes here",
                            systemImage: "note.text",
                            description: Text("Choose another workspace or sync with your Mac.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView.search(text: query)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(filteredNotes, id: \.id) { note in
                        NavigationLink(value: note.id) {
                            NoteRow(
                                note: note,
                                index: (scopedNotes.firstIndex(where: { $0.id == note.id }) ?? 0) + 1,
                                isSelected: selection == note.id
                            )
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                BlinkSectionHeader(
                    title: workspace.title,
                    count: filteredNotes.count,
                    isSearching: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(0)
        .refreshable { await model.refresh() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var compactSearchFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(compactSearchActive ? BlinkMobileTheme.signal : BlinkMobileTheme.hairline)
                .frame(height: compactSearchActive ? 2 : 1)

            if compactSearchActive {
                HStack(spacing: 0) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                        .frame(width: 42, height: 50)
                        .accessibilityHidden(true)

                    TextField(
                        "",
                        text: $query,
                        prompt: Text(dynamicTypeSize.isAccessibilitySize
                            ? "SEARCH NOTES"
                            : "SEARCH · \(workspace.title.uppercased())")
                            .foregroundStyle(BlinkMobileTheme.faintInk)
                    )
                        .font(.subheadline.monospaced())
                        .foregroundStyle(BlinkMobileTheme.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($compactSearchFocused)
                        .accessibilityLabel("Search \(workspace.title)")

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 44, height: 50)
                        }
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                        .accessibilityLabel("Clear search")
                    }

                    Button {
                        query = ""
                        compactSearchFocused = false
                        compactSearchActive = false
                    } label: {
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                        } else {
                            Text("Cancel")
                                .font(.caption.monospaced().weight(.semibold))
                                .textCase(.uppercase)
                        }
                    }
                    .frame(minWidth: 50, minHeight: 50)
                    .foregroundStyle(BlinkMobileTheme.signal)
                    .accessibilityLabel("Cancel search")
                }
                .background(BlinkMobileTheme.raisedSurface)
            } else {
                Button {
                    compactSearchActive = true
                    Task { @MainActor in
                        await Task.yield()
                        compactSearchFocused = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text(dynamicTypeSize.isAccessibilitySize
                            ? "SEARCH"
                            : "SEARCH · \(workspace.title.uppercased())")
                            .lineLimit(1)
                        Spacer()
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("⌘F")
                                .foregroundStyle(BlinkMobileTheme.faintInk)
                        }
                    }
                    .font(.caption.monospaced().weight(.medium))
                    .tracking(0.8)
                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Search \(workspace.title)")
                .background(BlinkMobileTheme.rail)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            VStack(spacing: 16) {
                BlinkMark(size: 44)
                Text(emptyStateTitle)
                    .font(.title2.weight(.semibold))
            }
        } description: {
            Text(emptyStateDescription)
                .foregroundStyle(BlinkMobileTheme.secondaryInk)
        } actions: {
            Button(emptyStateActionTitle) {
                if model.connectionState.host == nil {
                    showingSettings = true
                } else {
                    Task { await model.refresh() }
                }
            }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
    }

    private var emptyStateTitle: String {
        if model.snapshot != nil { return "No notes yet" }
        if model.connectionState.host != nil { return "Notes removed" }
        return "Connect to your Mac"
    }

    private var emptyStateDescription: String {
        if model.snapshot != nil {
            return model.connectionState.host == nil
                ? "No notes were found in the last update."
                : "Create a note on your Mac, then sync."
        }
        if model.connectionState.host != nil {
            return "Sync to restore notes on this device."
        }
        return "Open Settings to choose a nearby Mac."
    }

    private var emptyStateActionTitle: String {
        model.connectionState.host == nil ? "Open Settings" : "Sync Now"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("All Notes") { workspace = .all }
                Button("Unfiled") { workspace = .unfiled }
                if !workspaceIDs.isEmpty { Divider() }
                ForEach(workspaceIDs, id: \.self) { id in
                    Button(id) { workspace = .workspace(id) }
                }
            } label: {
                HStack(spacing: 5) {
                    BlinkMark(size: 24)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                }
            }
            .accessibilityLabel("Workspace: \(workspace.title)")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.connectionState.host != nil {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isSyncing)
                .accessibilityLabel("Sync now")
            }

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    private var detailPlaceholder: some View {
        ContentUnavailableView {
            VStack(spacing: 16) {
                BlinkMark(size: 40)
                Text("Choose a note")
                    .font(.title2.weight(.semibold))
            }
        } description: {
            Text("Select a note to read.")
                .foregroundStyle(BlinkMobileTheme.secondaryInk)
        }
        .background(BlinkBackdrop())
    }
}

private struct BlinkSectionHeader: View {
    let title: String
    let count: Int
    let isSearching: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    headerIdentity
                    Text("\(count) REC")
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                }
            } else {
                HStack(spacing: 8) {
                    headerIdentity
                    Spacer(minLength: 8)
                    Text("\(count) REC")
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                }
            }
        }
        .font(.caption2.monospaced().weight(.medium))
        .tracking(1.15)
        .textCase(nil)
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "note" : "notes")")
    }

    private var headerIdentity: some View {
        HStack(spacing: 8) {
            Text(isSearching ? "MATCHES" : "LOG")
                .foregroundStyle(isSearching ? BlinkMobileTheme.signal : BlinkMobileTheme.faintInk)
            Text("/")
                .foregroundStyle(BlinkMobileTheme.hairline)
            Text(title.uppercased())
                .foregroundStyle(BlinkMobileTheme.faintInk)
                .lineLimit(1)
        }
    }
}

enum WorkspaceScope: Hashable {
    case all
    case unfiled
    case workspace(String)

    var title: String {
        switch self {
        case .all: "All Notes"
        case .unfiled: "Unfiled"
        case .workspace(let id): id
        }
    }
}

private struct SyncSummary: View {
    let state: BlinkMobileModel.ConnectionState
    let lastSyncedAt: Date
    let isSyncing: Bool
    let issueCount: Int

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(statusColor)
                .frame(height: 2)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Rectangle()
                    .fill(pipColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(statusLine)
                    .font(.caption.monospaced().weight(.medium))
                    .tracking(0.45)
                    .foregroundStyle(isDegraded ? BlinkMobileTheme.amber : BlinkMobileTheme.secondaryInk)
                    .lineLimit(3)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(BlinkMobileTheme.canvas)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusLine.capitalized)
    }

    private var isDegraded: Bool {
        issueCount > 0 || isStale
    }

    private var isStale: Bool {
        Date().timeIntervalSince(lastSyncedAt) > 7 * 24 * 60 * 60
    }

    private var statusColor: Color {
        if isDegraded { return BlinkMobileTheme.amber }
        if isSyncing || state.host != nil { return BlinkMobileTheme.signal.opacity(0.62) }
        return BlinkMobileTheme.hairline
    }

    private var pipColor: Color {
        if isDegraded { return BlinkMobileTheme.amber }
        if isSyncing || state.host != nil { return BlinkMobileTheme.signal }
        return BlinkMobileTheme.faintInk
    }

    private var statusLine: String {
        let age = conciseAge(since: lastSyncedAt)
        if issueCount > 0 {
            return "\(issueCount) SYNC ISSUE\(issueCount == 1 ? "" : "S") · UPDATED \(age)"
        }
        if isSyncing {
            if let host = state.host {
                return "SYNCING · \(host.name.uppercased())"
            }
            return "SYNCING"
        }
        switch state {
        case .disconnected:
            return isStale ? "SYNC DUE · UPDATED \(age)" : "UPDATED \(age)"
        case .requestingAccess(let name):
            return "APPROVAL NEEDED · \(name.uppercased())"
        case .connected(let host):
            return "\(host.name.uppercased()) · UPDATED \(age)"
        }
    }
}

private struct NoteRow: View {
    let note: BlinkSnapshotNote
    let index: Int
    let isSelected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                BlinkMobileTheme.rail
                if isSelected {
                    BlinkMobileTheme.signal
                        .frame(width: 2)
                }

                VStack(alignment: .trailing, spacing: 7) {
                    if note.pinned {
                        Rectangle()
                            .fill(BlinkMobileTheme.ink)
                            .frame(width: 7, height: 7)
                    } else {
                        Text(String(format: "%02d", index))
                            .font(.caption2.monospaced().weight(.semibold))
                    }

                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(indexTapeStamp(for: note.updatedAt))
                            .font(.caption2.monospaced())
                    }
                }
                .foregroundStyle(BlinkMobileTheme.faintInk)
                .padding(.top, 15)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 32 : 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(note.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(BlinkMobileTheme.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                let excerpt = noteExcerpt(note)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(BlinkMobileTheme.secondaryInk)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .lineSpacing(2)
                }

                rowMetadata
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(isSelected ? BlinkMobileTheme.signal.opacity(0.10) : BlinkMobileTheme.surface)
            .overlay(alignment: .bottom) {
                BlinkMobileTheme.hairline.frame(height: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    @ViewBuilder
    private var rowMetadata: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                metadataItems
            }
            .textCase(.lowercase)
            .font(.caption.monospaced())
            .foregroundStyle(BlinkMobileTheme.faintInk)
        } else {
            HStack(spacing: 7) {
                metadataItems
            }
            .textCase(.lowercase)
            .font(.caption.monospaced())
            .foregroundStyle(BlinkMobileTheme.faintInk)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(indexTapeStamp(for: note.updatedAt))
        }
        if let workspace = note.presentation.workspace {
            Text(workspace)
        }
        if let firstTag = note.tags.first {
            Text("#\(firstTag)")
        }
    }

    private var accessibilityLabel: String {
        var parts = [note.pinned ? "Pinned note" : "Note \(index)", note.title]
        let excerpt = noteExcerpt(note)
        if !excerpt.isEmpty { parts.append(excerpt) }
        parts.append(indexTapeStamp(for: note.updatedAt))
        if let workspace = note.presentation.workspace { parts.append(workspace) }
        if let firstTag = note.tags.first { parts.append("tag \(firstTag)") }
        return parts.joined(separator: ", ")
    }
}

private struct NoteDetailView: View {
    let note: BlinkSnapshotNote
    let index: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(String(format: "%02d", index))
                                .font(.caption2.monospaced().weight(.semibold))
                            Text(indexTapeStamp(for: note.updatedAt))
                                .font(.caption2.monospaced())
                        }
                        .foregroundStyle(BlinkMobileTheme.faintInk)
                        .padding(.top, 29)
                        .padding(.trailing, 8)
                        .frame(width: 48, alignment: .topTrailing)
                        .frame(maxHeight: .infinity, alignment: .topTrailing)
                        .background(BlinkMobileTheme.rail)
                        .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                BlinkMark(size: 17)
                                Text("MARKDOWN / READ ONLY")
                                    .font(.caption2.monospaced().weight(.medium))
                                    .tracking(1.0)
                                    .foregroundStyle(BlinkMobileTheme.faintInk)
                            }

                            if dynamicTypeSize.isAccessibilitySize {
                                Text("ENTRY \(String(format: "%02d", index)) · \(indexTapeStamp(for: note.updatedAt))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(BlinkMobileTheme.faintInk)
                            }

                            Text(note.title)
                                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                                .foregroundStyle(BlinkMobileTheme.ink)

                            HStack(spacing: 8) {
                                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                                if let workspace = note.presentation.workspace {
                                    Text("·")
                                    Text(workspace.uppercased())
                                }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(BlinkMobileTheme.faintInk)
                        }

                        Divider()
                            .overlay(BlinkMobileTheme.hairline)

                        MarkdownDocumentView(markdown: noteContent(note), noteTitle: note.title)

                        if !note.tags.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack { tagViews }
                                VStack(alignment: .leading) { tagViews }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
        .background(BlinkBackdrop())
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var tagViews: some View {
        ForEach(note.tags, id: \.self) { tag in
            Text("#\(tag)")
                .font(.caption.monospaced())
                .foregroundStyle(BlinkMobileTheme.secondaryInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(BlinkMobileTheme.surface)
                .overlay {
                    Rectangle()
                        .stroke(BlinkMobileTheme.hairline, lineWidth: 1)
                }
        }
    }
}

private let indexTapeClockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("HHmm")
    return formatter
}()

private let indexTapeOldDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = "M·yy"
    return formatter
}()

func indexTapeStamp(for date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDate(date, inSameDayAs: now) {
        return indexTapeClockFormatter.string(from: date)
    }

    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
    ).day ?? 0
    if days >= 0, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }
    return indexTapeOldDateFormatter.string(from: date).uppercased()
}

func conciseAge(since date: Date, now: Date = Date()) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "JUST NOW" }
    if interval < 3_600 { return "\(Int(interval / 60))M AGO" }
    if interval < 86_400 { return "\(Int(interval / 3_600))H AGO" }
    if interval < 30 * 86_400 { return "\(Int(interval / 86_400))D AGO" }
    return date.formatted(date: .abbreviated, time: .omitted).uppercased()
}

struct MarkdownDocumentView: View {
    let markdown: String
    let noteTitle: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(markdown, omittingRepeatedTitle: noteTitle)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .foregroundStyle(BlinkMobileTheme.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(BlinkMobileTheme.ink)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker)
                    .font(.body.monospaced())
                    .foregroundStyle(BlinkMobileTheme.signal)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.body.monospaced())
                    .padding()
            }
            .background(BlinkMobileTheme.surface)
            .overlay {
                Rectangle()
                    .stroke(BlinkMobileTheme.hairline, lineWidth: 1)
            }
            .accessibilityLabel("Code block")
            .accessibilityValue(text)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title2, design: .serif, weight: .semibold)
        case 2: .system(.title3, design: .serif, weight: .semibold)
        default: .headline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(marker: String, text: String)
        case code(String)
    }

    var id: Int
    var kind: Kind

    static func parse(_ markdown: String, omittingRepeatedTitle title: String) -> [MarkdownBlock] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func append(_ kind: Kind) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let codeLines = code {
                    append(.code(codeLines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if let item = listItem(in: trimmed) {
                flushParagraph()
                append(.listItem(marker: item.marker, text: item.text))
                continue
            }
            paragraph.append(trimmed)
        }

        flushParagraph()
        if let code { append(.code(code.joined(separator: "\n"))) }

        if let first = blocks.first,
           case .heading(_, let headingTitle) = first.kind,
           headingTitle.caseInsensitiveCompare(title) == .orderedSame {
            blocks.removeFirst()
            for index in blocks.indices { blocks[index].id = index }
        }
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: level)
        guard boundary < line.endIndex, line[boundary].isWhitespace else { return nil }
        return (level, line[boundary...].trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(in line: String) -> (marker: String, text: String)? {
        for marker in ["-", "*", "+"] where line.hasPrefix(marker + " ") {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: digits.count)
        guard boundary < line.endIndex, line[boundary] == "." || line[boundary] == ")" else {
            return nil
        }
        let afterMarker = line.index(after: boundary)
        guard afterMarker < line.endIndex, line[afterMarker].isWhitespace else { return nil }
        return ("\(digits).", line[afterMarker...].trimmingCharacters(in: .whitespaces))
    }
}

struct ConnectionView: View {
    @ObservedObject var model: BlinkMobileModel
    @State private var pendingPeer: BlinkLANPeerCandidate?

    var body: some View {
        List {
            if let host = model.connectionState.host {
                Section("Mac") {
                    Label(host.name, systemImage: "desktopcomputer")
                    LabeledContent("Transport", value: "Local network")
                    LabeledContent("Security", value: "Encrypted")
                }
                .listRowBackground(BlinkMobileTheme.surface)
                Section {
                    Button("Sync Now") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isSyncing)
                    Button("Disconnect", role: .destructive) {
                        model.disconnect()
                    }
                }
                .listRowBackground(BlinkMobileTheme.surface)
            } else {
                nearbySection
                approvalSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(BlinkBackdrop())
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BlinkMobileTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert(
            "Connect to \(pendingPeer?.name ?? "this Mac")?",
            isPresented: Binding(
                get: { pendingPeer != nil },
                set: { if !$0 { pendingPeer = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingPeer = nil }
            Button("Request Access") {
                guard let peer = pendingPeer else { return }
                pendingPeer = nil
                Task {
                    _ = await model.connect(to: peer)
                }
            }
        } message: {
            Text("Your Mac will ask you to allow this device. Access remains until you revoke it on the Mac.")
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        Section {
            switch model.discoveryState {
            case .searching:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for Canvas on your network…")
                        .foregroundStyle(BlinkMobileTheme.secondaryInk)
                }
            case .found:
                ForEach(model.nearbyPeers) { peer in
                    Button {
                        pendingPeer = peer
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(peer.name, systemImage: "desktopcomputer")
                                Text("Nearby")
                                    .font(.caption)
                                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
                            }
                            Spacer()
                            if case .requestingAccess(let name) = model.connectionState,
                               name == peer.name {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BlinkMobileTheme.faintInk)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(model.connectionState != .disconnected)
                }
            case .noPeers:
                Label("No Macs found", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
                Button("Look Again") { model.retryDiscovery() }
            case .failed(let message):
                Label("Discovery unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
                Button("Try Again") { model.retryDiscovery() }
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Nearby Macs")
        } footer: {
            Text("Open Canvas on your Mac. Both devices must be on the same network.")
        }
        .listRowBackground(BlinkMobileTheme.surface)
    }

    @ViewBuilder
    private var approvalSection: some View {
        switch model.connectionState {
        case .requestingAccess(let name):
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Approve on \(name)")
                            .font(.headline)
                        Text("Waiting for approval")
                            .font(.subheadline)
                            .foregroundStyle(BlinkMobileTheme.secondaryInk)
                    }
                }
            } header: {
                Text("Access")
            }
            .listRowBackground(BlinkMobileTheme.surface)
        case .disconnected:
            Section {
                Label("Approval is required on the Mac.", systemImage: "lock.shield")
                    .foregroundStyle(BlinkMobileTheme.secondaryInk)
            } footer: {
                Text("The Mac remembers this device until you revoke access.")
            }
            .listRowBackground(BlinkMobileTheme.surface)
        case .connected:
            EmptyView()
        }
    }
}

func noteContent(_ note: BlinkSnapshotNote) -> String {
    (try? Frontmatter.decode(note.markdown).content) ?? note.markdown
}

func noteExcerpt(_ note: BlinkSnapshotNote) -> String {
    var lines = noteContent(note)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    if let firstContentIndex = lines.firstIndex(where: {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
        let first = lines[firstContentIndex]
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if first.caseInsensitiveCompare(note.title) == .orderedSame {
            lines.remove(at: firstContentIndex)
        }
    }
    return lines.joined(separator: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
