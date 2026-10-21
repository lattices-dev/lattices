// THESIS: Blink Help explains the workspace model; Commands executes and Settings configures.
// OWN-WORLD: A quiet graphite/paper surface, fine spatial grid, cool signal-blue, mono labels.
// STORY: Understand capture → place → recall, then scan every key by where it works.
// FIRST VIEWPORT: A narrow navigator anchors orientation and shortcut reference pages.
// FORM: An established-world extension of Blink's terminal canvas and Hudson's native tokens.

import SwiftUI
import HudsonUI

/// Blink's educational surface. Commands owns executable discovery; this view
/// explains the spatial model and keeps live shortcuts and gestures readable.
@MainActor
struct BlinkGuideView: View {
    enum Page: String, CaseIterable, Identifiable {
        case basics
        case shortcuts

        var id: Self { self }
        var title: String {
            switch self {
            case .basics: "Start Here"
            case .shortcuts: "All Shortcuts"
            }
        }
        var subtitle: String {
            switch self {
            case .basics: "How Canvas fits together"
            case .shortcuts: "Keys grouped by scope"
            }
        }
        var symbolName: String {
            switch self {
            case .basics: "rectangle.3.group"
            case .shortcuts: "command"
            }
        }
    }

    let activities: [BlinkActivity]

    @State private var page: Page = .basics
    @ObservedObject private var appearance = AppearanceManager.shared

    private var palette: BlinkDiscoveryPalette {
        .forScheme(appearance.scheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            navigator
                .frame(width: 190)
            HudDivider(color: palette.rule, axis: .vertical)
            detail
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 610)
        .background(BlinkDiscoveryBackdrop(palette: palette))
        .preferredColorScheme(appearance.scheme == .dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas Help and Shortcuts")
    }

    private var navigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: HudSpacing.xs) {
                HStack(spacing: HudSpacing.md) {
                    Image(systemName: "questionmark")
                        .font(HudFont.mono(HudTextSize.sm, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, height: 24)
                        .background(palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: HudRadius.standard))

                    Text("CANVAS HELP")
                        .font(HudFont.mono(HudTextSize.xs, weight: .semibold))
                        .tracking(HudTracking.wider)
                        .foregroundStyle(palette.ink)
                }

                Text("Learn the workspace, then keep its keys close.")
                    .font(HudFont.ui(HudTextSize.xs))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HudSpacing.xxl)
            .padding(.top, HudSpacing.xxxl)
            .padding(.bottom, HudSpacing.xxl)

            VStack(spacing: HudSpacing.xs) {
                ForEach(Page.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(spacing: HudSpacing.lg) {
                            Image(systemName: item.symbolName)
                                .font(HudFont.ui(HudTextSize.sm, weight: .medium))
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: HudSpacing.xxs) {
                                Text(item.title)
                                    .font(HudFont.ui(HudTextSize.sm, weight: page == item ? .semibold : .regular))
                                Text(item.subtitle)
                                    .font(HudFont.ui(HudTextSize.xxs))
                                    .foregroundStyle(page == item ? palette.ink.opacity(0.72) : palette.dim)
                            }

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(page == item ? palette.ink : palette.muted)
                        .padding(.horizontal, HudSpacing.lg)
                        .frame(height: 48)
                        .background(page == item ? palette.selection : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: HudRadius.standard))
                    .accessibilityValue(page == item ? "Selected" : "")
                }
            }
            .padding(.horizontal, HudSpacing.md)

            Spacer()

            HStack(spacing: HudSpacing.sm) {
                Circle()
                    .fill(palette.live)
                    .frame(width: 6, height: 6)
                Text("SHORTCUTS FOLLOW CONFIG")
                    .font(HudFont.mono(HudTextSize.micro, weight: .medium))
                    .tracking(HudTracking.wide)
                    .foregroundStyle(palette.dim)
            }
            .padding(HudSpacing.xxl)
            .accessibilityLabel("Shortcuts update with Canvas configuration")
        }
        .background(palette.chrome.opacity(0.96))
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .basics:
            basicsPage
        case .shortcuts:
            shortcutsPage
        }
    }

    private var basicsPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HudSpacing.huge) {
                pageHeader(
                    title: "How Canvas Works",
                    subtitle: "The note is the window, and the desktop is the workspace."
                )

                conceptSection(title: "THE CORE LOOP", rows: coreLoop)
                conceptSection(title: "CHOOSE THE RIGHT SURFACE", rows: utilitySurfaces)
            }
            .padding(.horizontal, HudSpacing.huge)
            .padding(.vertical, HudSpacing.xxxl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var coreLoop: [GuideConcept] {
        [
            GuideConcept(
                id: "capture",
                symbolName: "plus.rectangle.on.rectangle",
                title: "Capture",
                detail: "Create or find a note from the menubar popover, Commands, or the global new-note shortcut."
            ),
            GuideConcept(
                id: "place",
                symbolName: "macwindow.on.rectangle",
                title: "Place",
                detail: "A note opens as its one floating panel. Move, resize, shade, or focus it directly on the desktop."
            ),
            GuideConcept(
                id: "recall",
                symbolName: "arrow.uturn.forward",
                title: "Recall",
                detail: "Reopening a note focuses the same panel, and Canvas restores its position on this Mac."
            ),
        ]
    }

    private var utilitySurfaces: [GuideConcept] {
        [
            GuideConcept(
                id: "commands",
                symbolName: "command",
                title: "Commands — do",
                detail: "Find a note or run one available action. The launcher closes after your choice.",
                shortcut: shortcut(for: .commandPalette)
            ),
            GuideConcept(
                id: "help",
                symbolName: "questionmark.circle",
                title: "Help & Shortcuts — learn",
                detail: "Keep the workspace model, gestures, and current keyboard map open as a reference.",
                shortcut: shortcut(for: .openGuide)
            ),
            GuideConcept(
                id: "settings",
                symbolName: "gearshape",
                title: "Settings — configure",
                detail: "Change Canvas's behavior and appearance. Controls stay open while you tune them.",
                shortcut: shortcut(for: .openSettings)
            ),
        ]
    }

    private func shortcut(for id: BlinkActivityID) -> String? {
        activities.first(where: { $0.id == id })?.shortcutDisplay
    }

    private func conceptSection(title: String, rows: [GuideConcept]) -> some View {
        VStack(alignment: .leading, spacing: HudSpacing.md) {
            HudSectionLabel(title, tint: palette.dim)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    conceptRow(row)
                    if row.id != rows.last?.id {
                        HudDivider(color: palette.rule.opacity(0.72))
                            .padding(.leading, 48)
                    }
                }
            }
            .background(palette.raised)
            .clipShape(RoundedRectangle(cornerRadius: HudRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: HudRadius.card)
                    .stroke(palette.rule, lineWidth: 1)
            )
        }
    }

    private func conceptRow(_ concept: GuideConcept) -> some View {
        HStack(alignment: .top, spacing: HudSpacing.xl) {
            Image(systemName: concept.symbolName)
                .font(HudFont.ui(HudTextSize.base, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 24, height: 24)
                .background(palette.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: HudRadius.standard))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HudSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: HudSpacing.md) {
                    Text(concept.title)
                        .font(HudFont.ui(HudTextSize.base, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                    if let shortcut = concept.shortcut {
                        BlinkKeyChip(shortcut, palette: palette)
                    }
                }

                Text(concept.detail)
                    .font(HudFont.ui(HudTextSize.sm))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HudSpacing.xl)
        .accessibilityElement(children: .combine)
    }

    private var shortcutsPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HudSpacing.huge) {
                pageHeader(
                    title: "All Shortcuts",
                    subtitle: "Keys are grouped by where Canvas listens for them."
                )

                ForEach(BlinkActivityScope.allCases) { scope in
                    let rows = shortcutRows(for: scope)
                    if !rows.isEmpty {
                        shortcutSection(scope: scope, rows: rows)
                    }
                }
            }
            .padding(.horizontal, HudSpacing.huge)
            .padding(.vertical, HudSpacing.xxxl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func shortcutSection(scope: BlinkActivityScope, rows: [GuideShortcut]) -> some View {
        VStack(alignment: .leading, spacing: HudSpacing.md) {
            HStack {
                HudSectionLabel(scope.displayTitle, tint: palette.dim)
                Spacer()
                Text("\(rows.count)")
                    .font(HudFont.mono(HudTextSize.micro, weight: .medium))
                    .foregroundStyle(palette.dim)
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: HudSpacing.xl) {
                        VStack(alignment: .leading, spacing: HudSpacing.xxs) {
                            Text(row.title)
                                .font(HudFont.ui(HudTextSize.sm, weight: .medium))
                                .foregroundStyle(palette.ink)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(HudFont.ui(HudTextSize.xs))
                                    .foregroundStyle(palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: HudSpacing.xl)
                        BlinkKeyChip(row.keys, palette: palette)
                    }
                    .padding(.horizontal, HudSpacing.xl)
                    .padding(.vertical, HudSpacing.lg)
                    .accessibilityElement(children: .combine)

                    if row.id != rows.last?.id {
                        HudDivider(color: palette.rule.opacity(0.72))
                    }
                }
            }
            .background(palette.raised)
            .clipShape(RoundedRectangle(cornerRadius: HudRadius.card))
            .overlay(RoundedRectangle(cornerRadius: HudRadius.card).stroke(palette.rule, lineWidth: 1))
        }
    }

    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: HudSpacing.sm) {
            Text(title)
                .font(HudFont.ui(HudTextSize.xxl, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(subtitle)
                .font(HudFont.ui(HudTextSize.base))
                .foregroundStyle(palette.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func shortcutRows(for scope: BlinkActivityScope) -> [GuideShortcut] {
        var rows = activities
            .filter { $0.scope == scope }
            .compactMap { activity -> GuideShortcut? in
                guard let shortcut = activity.shortcutDisplay else { return nil }
                return GuideShortcut(
                    id: "activity-\(String(describing: activity.id))",
                    scope: activity.scope,
                    keys: shortcut,
                    title: activity.title,
                    detail: activity.description
                )
            }

        for supplement in GuideShortcut.supplements where supplement.scope == scope {
            let normalized = supplement.title.lowercased()
            let alreadyCovered = rows.contains {
                $0.title.lowercased() == normalized
                    || (!supplement.deduplicationHint.isEmpty
                        && $0.title.lowercased().contains(supplement.deduplicationHint))
            }
            if !alreadyCovered {
                rows.append(supplement)
            }
        }
        return rows
    }
}

private struct GuideConcept: Identifiable {
    let id: String
    let symbolName: String
    let title: String
    let detail: String
    var shortcut: String?

    init(
        id: String,
        symbolName: String,
        title: String,
        detail: String,
        shortcut: String? = nil
    ) {
        self.id = id
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
    }
}

private struct GuideShortcut: Identifiable {
    let id: String
    let scope: BlinkActivityScope
    let keys: String
    let title: String
    let detail: String?
    let deduplicationHint: String

    init(
        id: String,
        scope: BlinkActivityScope = .application,
        keys: String,
        title: String,
        detail: String? = nil,
        deduplicationHint: String = ""
    ) {
        self.id = id
        self.scope = scope
        self.keys = keys
        self.title = title
        self.detail = detail
        self.deduplicationHint = deduplicationHint
    }

    static let supplements: [GuideShortcut] = [
        .init(
            id: "panel-mode",
            scope: .panel,
            keys: "⌘⇧P",
            title: "Switch read / edit",
            detail: "Flip the current note between reading and writing.",
            deduplicationHint: "read"
        ),
        .init(
            id: "panel-focus",
            scope: .panel,
            keys: "⌘.",
            title: "Focus current note",
            detail: "Recede the surrounding desk and keep this note present.",
            deduplicationHint: "focus"
        ),
        .init(
            id: "panel-close",
            scope: .panel,
            keys: "⌘W",
            title: "Close current note",
            detail: "Pending edits are saved before its panel closes.",
            deduplicationHint: "close"
        ),
        .init(
            id: "panel-escape",
            scope: .panel,
            keys: "Esc",
            title: "Step back",
            detail: "Escape moves from edit → read → leave focus, one step at a time.",
            deduplicationHint: "step"
        ),
        .init(
            id: "popover-return",
            scope: .popover,
            keys: "↩",
            title: "Open the result",
            detail: "Open the selected or first match; create only when nothing matches.",
            deduplicationHint: "open"
        ),
        .init(
            id: "popover-command-return",
            scope: .popover,
            keys: "⌘↩",
            title: "Create from the search field",
            detail: "Always create a new note using the current capture text.",
            deduplicationHint: "create"
        ),
        .init(
            id: "grid-cells",
            scope: .grid,
            keys: "Q W E  /  A S D  /  Z X C",
            title: "Place in the 3 × 3 grid",
            detail: "Each letter maps to the matching screen cell.",
            deduplicationHint: "place"
        ),
        .init(
            id: "grid-dismiss",
            scope: .grid,
            keys: "Esc",
            title: "Leave the grid",
            deduplicationHint: "leave"
        ),
        .init(
            id: "editor-save",
            scope: .editor,
            keys: "⌘S",
            title: "Save now",
            detail: "Flush the current edit immediately; Canvas also saves as you type."
        ),
    ]
}

/// Shared discovery-surface colors. Hudson owns spacing, type, motion, and
/// component geometry; Blink supplies the app-specific graphite/blue world.
struct BlinkDiscoveryPalette {
    let bg: Color
    let chrome: Color
    let raised: Color
    let ink: Color
    let muted: Color
    let dim: Color
    let rule: Color
    let accent: Color
    let live: Color
    let selection: Color

    var accentSoft: Color { accent.opacity(0.13) }

    static func forScheme(_ scheme: AppScheme) -> Self {
        if scheme == .dark {
            return .init(
                bg: Color(red: 0.035, green: 0.039, blue: 0.043),
                chrome: Color(red: 0.025, green: 0.027, blue: 0.030),
                raised: Color(red: 0.057, green: 0.061, blue: 0.066),
                ink: Color(red: 0.918, green: 0.922, blue: 0.910),
                muted: Color(red: 0.650, green: 0.665, blue: 0.665),
                dim: Color(red: 0.455, green: 0.475, blue: 0.480),
                rule: Color.white.opacity(0.10),
                accent: Color(red: 0.365, green: 0.620, blue: 0.980),
                live: Color(red: 0.353, green: 0.820, blue: 0.608),
                selection: Color(red: 0.365, green: 0.620, blue: 0.980).opacity(0.14)
            )
        }
        return .init(
            bg: Color(red: 0.949, green: 0.941, blue: 0.925),
            chrome: Color(red: 0.925, green: 0.914, blue: 0.894),
            raised: Color(red: 0.985, green: 0.980, blue: 0.968),
            ink: Color(red: 0.125, green: 0.110, blue: 0.095),
            muted: Color(red: 0.360, green: 0.335, blue: 0.310),
            dim: Color(red: 0.485, green: 0.455, blue: 0.420),
            rule: Color.black.opacity(0.12),
            accent: Color(red: 0.176, green: 0.365, blue: 0.690),
            live: Color(red: 0.106, green: 0.580, blue: 0.404),
            selection: Color(red: 0.176, green: 0.365, blue: 0.690).opacity(0.11)
        )
    }
}

struct BlinkDiscoveryBackdrop: View {
    let palette: BlinkDiscoveryPalette

    var body: some View {
        ZStack {
            palette.bg
            Canvas { context, size in
                let step: CGFloat = 36
                var path = Path()
                stride(from: CGFloat.zero, through: size.width, by: step).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: CGFloat.zero, through: size.height, by: step).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(palette.rule.opacity(0.18)), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
        }
    }
}

struct BlinkKeyChip: View {
    let text: String
    let palette: BlinkDiscoveryPalette

    init(_ text: String, palette: BlinkDiscoveryPalette) {
        self.text = text
        self.palette = palette
    }

    var body: some View {
        Text(text)
            .font(HudFont.mono(HudTextSize.xxs, weight: .semibold))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .padding(.horizontal, HudSpacing.sm)
            .padding(.vertical, HudSpacing.xs)
            .background(palette.rule.opacity(0.38))
            .clipShape(RoundedRectangle(cornerRadius: HudRadius.tight))
            .overlay(
                RoundedRectangle(cornerRadius: HudRadius.tight)
                    .stroke(palette.rule, lineWidth: 1)
            )
            .accessibilityLabel("Shortcut \(text)")
    }
}
