// THESIS: Command-K is Blink's fastest path from intent to a note or action.
// OWN-WORLD: A compact terminal-like graphite/paper panel with one cool signal color.
// STORY: Type freely, scan Notes and Actions, then run the highlighted result with Return.
// FIRST VIEWPORT: Live-state strip, decisive search field, grouped results, terse key legend.
// FORM: A dedicated centered key panel, native to Blink's menubar and floating-panel architecture.

import AppKit
import BlinkCore
import SwiftUI
import HudsonShell
import HudsonUI

/// Owns Blink's Command-K interstitial. AppDelegate supplies AppModel and the
/// catalog provider, keeping this surface independent of private panel-manager
/// and app-controller state.
@MainActor
final class BlinkCommandPaletteController: NSObject, NSWindowDelegate {
    typealias ActivityProvider = @MainActor () -> [BlinkActivity]

    private let model: AppModel
    private let activities: ActivityProvider
    private var panel: BlinkCommandPanel?
    private var hostingController: NSHostingController<BlinkCommandPaletteView>?
    private var isDismissing = false

    init(model: AppModel, activities: @escaping ActivityProvider) {
        self.model = model
        self.activities = activities
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Present on the display that invoked Command-K. Capture the screen before
    /// activating Blink because the palette itself becomes the key window.
    func show(from invocationWindow: NSWindow? = nil) {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let screen = invocationScreen(for: invocationWindow)
        let rootView = BlinkCommandPaletteView(
            model: model,
            activities: activities(),
            dismiss: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = .preferredContentSize

        let contentSize = BlinkCommandPaletteView.contentSize
        let panel = BlinkCommandPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            // Unlike note panels, the interstitial must activate Blink so its
            // search field owns typing even when invoked from a nonactivating
            // note panel over another app.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(BlinkCommandPanel.identifier)
        panel.delegate = self
        panel.contentViewController = host
        panel.setContentSize(contentSize)
        panel.title = "Canvas Commands"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        center(panel, on: screen)
        self.panel = panel
        hostingController = host

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func toggle(from invocationWindow: NSWindow? = nil) {
        if isVisible {
            dismiss()
        } else {
            show(from: invocationWindow)
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel = nil
        hostingController = nil
        isDismissing = false
    }

    private func invocationScreen(for window: NSWindow?) -> NSScreen {
        if let screen = window?.screen ?? NSApp.keyWindow?.screen {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func center(_ window: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}

private final class BlinkCommandPanel: NSPanel {
    static let identifier = "blink.command-palette"
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct BlinkCommandPaletteView: View {
    static let contentSize = NSSize(width: 620, height: 500)

    @ObservedObject var model: AppModel
    let activities: [BlinkActivity]
    let dismiss: () -> Void

    @ObservedObject private var appearance = AppearanceManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @State private var appeared = false
    @State private var hoveredID: String?
    @FocusState private var searchFocused: Bool

    private var palette: BlinkDiscoveryPalette {
        .forScheme(appearance.scheme)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [PaletteResult] {
        noteResults + activityResults
    }

    private var noteResults: [PaletteResult] {
        let ordered = model.notes.sorted { $0.updatedAt > $1.updatedAt }
        if trimmedQuery.isEmpty {
            return ordered.prefix(8).map(PaletteResult.note)
        }
        let tokens = searchTokens
        return ordered
            .filter { note in
                let searchable = ([note.title, note.content] + note.tags)
                    .joined(separator: " ")
                    .lowercased()
                return tokens.allSatisfy { searchable.contains($0) }
            }
            .prefix(14)
            .map(PaletteResult.note)
    }

    private var activityResults: [PaletteResult] {
        activities
            .filter { $0.isExecutable && $0.isAvailable }
            .filter { $0.matches(trimmedQuery) }
            .map(PaletteResult.activity)
    }

    private var searchTokens: [String] {
        trimmedQuery.lowercased().split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    private var resultSections: [PaletteSection] {
        let notes = results.filter { $0.kind == .note }
        let actions = results.filter { $0.kind == .activity }
        return [
            PaletteSection(title: "Notes", results: notes),
            PaletteSection(title: "Actions", results: actions),
        ].filter { !$0.results.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            liveStrip
            HudDivider(color: palette.rule)
            searchField
            HudDivider(color: palette.rule)
            resultBody
            HudDivider(color: palette.rule)
            footer
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(BlinkDiscoveryBackdrop(palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.rule, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 30, x: 0, y: 16)
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.985))
        .opacity(appeared ? 1 : 0)
        .preferredColorScheme(appearance.scheme == .dark ? .dark : .light)
        .onAppear {
            query = ""
            selectedIndex = 0
            installKeyMonitor()
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(HudMotion.chromeResize) { appeared = true }
            }
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            removeKeyMonitor()
            appeared = false
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: results.map(\.id)) { _, ids in
            if ids.isEmpty {
                selectedIndex = 0
            } else {
                selectedIndex = min(selectedIndex, ids.count - 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas commands")
    }

    private var liveStrip: some View {
        HStack(spacing: HudSpacing.md) {
            Circle()
                .fill(palette.live)
                .frame(width: 6, height: 6)
                .shadow(color: palette.live.opacity(0.7), radius: 4)
                .accessibilityHidden(true)

            Text("CANVAS · COMMANDS")
                .font(HudFont.mono(HudTextSize.micro, weight: .semibold))
                .tracking(HudTracking.widest)
                .foregroundStyle(palette.accent)

            Spacer()

            BlinkKeyChip("⌘K", palette: palette)
        }
        .padding(.horizontal, HudSpacing.xxl)
        .frame(height: 30)
        .background(palette.accentSoft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Canvas command palette")
    }

    private var searchField: some View {
        HStack(spacing: HudSpacing.xl) {
            Image(systemName: "magnifyingglass")
                .font(HudFont.ui(HudTextSize.lg, weight: .medium))
                .foregroundStyle(palette.muted)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $query,
                prompt: Text("Find a note or run an action…")
                    .foregroundStyle(palette.dim)
            )
            .textFieldStyle(.plain)
            .font(HudFont.ui(HudTextSize.lg))
            .foregroundStyle(palette.ink)
            .tint(palette.accent)
            .focused($searchFocused)
            .accessibilityLabel("Search notes and commands")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(HudFont.ui(HudTextSize.base))
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, HudSpacing.xxxl)
        .frame(height: 62)
        .background(palette.raised.opacity(0.9))
    }

    @ViewBuilder
    private var resultBody: some View {
        if results.isEmpty {
            emptyState
        } else {
            resultList
        }
    }

    private var resultList: some View {
        let visibleResults = results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(resultSections) { section in
                        Section {
                            ForEach(section.results, id: \.id) { result in
                                if let index = visibleResults.firstIndex(where: { $0.id == result.id }) {
                                    resultRow(result, index: index)
                                        .id(result.id)
                                }
                            }
                        } header: {
                            HStack {
                                HudSectionLabel(section.title, tint: palette.dim)
                                Spacer()
                                Text("\(section.results.count)")
                                    .font(HudFont.mono(HudTextSize.micro, weight: .medium))
                                    .foregroundStyle(palette.dim)
                            }
                            .padding(.horizontal, HudSpacing.xxxl)
                            .padding(.top, HudSpacing.lg)
                            .padding(.bottom, HudSpacing.sm)
                            .background(palette.bg.opacity(0.98))
                        }
                    }
                }
                .padding(.bottom, HudSpacing.md)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedIndex) { _, newIndex in
                guard let id = visibleResults[safe: newIndex]?.id else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: nil)
                } else {
                    withAnimation(HudMotion.quickScroll) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
    }

    private func resultRow(_ result: PaletteResult, index: Int) -> some View {
        let selected = selectedIndex == index
        let hovering = hoveredID == result.id
        return Button {
            selectedIndex = index
            performSelection()
        } label: {
            HStack(spacing: HudSpacing.xl) {
                Image(systemName: result.symbolName)
                    .font(HudFont.ui(HudTextSize.base, weight: .medium))
                    .foregroundStyle(selected ? palette.accent : palette.muted)
                    .frame(width: 24, height: 24)
                    .background(selected ? palette.accentSoft : palette.rule.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: HudRadius.standard))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: HudSpacing.xxs) {
                    HStack(spacing: HudSpacing.sm) {
                        Text(result.title)
                            .font(HudFont.ui(HudTextSize.base, weight: selected ? .semibold : .medium))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)

                        if let context = result.contextLabel {
                            Text(context.uppercased())
                                .font(HudFont.mono(HudTextSize.micro, weight: .medium))
                                .tracking(HudTracking.wide)
                                .foregroundStyle(palette.dim)
                        }
                    }

                    if let subtitle = result.subtitle {
                        Text(subtitle)
                            .font(HudFont.ui(HudTextSize.xs))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: HudSpacing.xl)

                if let shortcut = result.shortcutDisplay {
                    BlinkKeyChip(shortcut, palette: palette)
                } else if selected {
                    Image(systemName: "return")
                        .font(HudFont.ui(HudTextSize.xs, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, HudSpacing.xxxl)
            .frame(height: 48)
            .background(selected ? palette.selection : (hovering ? palette.rule.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredID = isHovering ? result.id : (hoveredID == result.id ? nil : hoveredID)
            if isHovering { selectedIndex = index }
        }
        .accessibilityLabel(result.accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: HudSpacing.lg) {
            Image(systemName: "magnifyingglass")
                .font(HudFont.ui(HudTextSize.xxxl, weight: .light))
                .foregroundStyle(palette.dim)
            Text("No notes or actions match “\(trimmedQuery)”")
                .font(HudFont.ui(HudTextSize.base, weight: .medium))
                .foregroundStyle(palette.muted)
            Text("Try a title, tag, or verb like “focus” or “reveal”.")
                .font(HudFont.ui(HudTextSize.xs))
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: HudSpacing.xxxl) {
            footerHint(keys: "↑↓", label: "navigate")
            footerHint(keys: "↩", label: "open or run")
            footerHint(keys: "Esc", label: "dismiss")
            Spacer()
            Text("\(results.count) READY")
                .font(HudFont.mono(HudTextSize.micro, weight: .medium))
                .tracking(HudTracking.wide)
                .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, HudSpacing.xxl)
        .frame(height: 42)
        .background(palette.chrome.opacity(0.96))
    }

    private func footerHint(keys: String, label: String) -> some View {
        HStack(spacing: HudSpacing.sm) {
            BlinkKeyChip(keys, palette: palette)
            Text(label)
                .font(HudFont.ui(HudTextSize.xs))
                .foregroundStyle(palette.dim)
        }
        .accessibilityElement(children: .combine)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.identifier?.rawValue == BlinkCommandPanel.identifier else {
                return event
            }
            switch event.keyCode {
            case 53: // Escape
                dismiss()
                return nil
            case 125: // Down
                moveSelection(1)
                return nil
            case 126: // Up
                moveSelection(-1)
                return nil
            case 36, 76: // Return / keypad Enter — no alternate Command-Return behavior.
                performSelection()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    private func performSelection() {
        guard let result = results[safe: selectedIndex] else { return }
        dismiss()
        switch result {
        case .note(let note):
            Task { @MainActor in await model.openNote(id: note.id) }
        case .activity(let activity):
            DispatchQueue.main.async { activity.perform() }
        }
    }
}

private enum PaletteResultKind {
    case note
    case activity
}

@MainActor
private enum PaletteResult {
    case note(Note)
    case activity(BlinkActivity)

    var id: String {
        switch self {
        case .note(let note): "note-\(note.id)"
        case .activity(let activity): "activity-\(activity.id.rawValue)"
        }
    }

    var kind: PaletteResultKind {
        switch self {
        case .note: .note
        case .activity: .activity
        }
    }

    var title: String {
        switch self {
        case .note(let note): note.title
        case .activity(let activity): activity.title
        }
    }

    var subtitle: String? {
        switch self {
        case .note(let note):
            let collapsed = note.content
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard collapsed != note.title, !collapsed.isEmpty else {
                return note.tags.isEmpty ? "Markdown note" : note.tags.map { "#\($0)" }.joined(separator: "  ")
            }
            return String(collapsed.prefix(110))
        case .activity(let activity):
            return activity.description
        }
    }

    var symbolName: String {
        switch self {
        case .note: "note.text"
        case .activity(let activity): activity.symbolName
        }
    }

    var contextLabel: String? {
        switch self {
        case .note: nil
        case .activity(let activity): activity.scope.displayTitle
        }
    }

    var shortcutDisplay: String? {
        switch self {
        case .note: nil
        case .activity(let activity): activity.shortcutDisplay
        }
    }

    var accessibilityLabel: String {
        [title, subtitle, shortcutDisplay].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct PaletteSection: Identifiable {
    let title: String
    let results: [PaletteResult]
    var id: String { title }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
