import SwiftUI

// MARK: - Colors

enum Palette {
    // Base surfaces
    static let bg         = Color(red: 0.08, green: 0.08, blue: 0.09)   // #141416
    static let bgSidebar  = Color(red: 0.08, green: 0.08, blue: 0.09)   // same as bg
    static let surface    = Color(white: 0.10)                           // Raised cards
    static let surfaceHov = Color(white: 0.14)                           // Hovered cards
    static let border     = Color.white.opacity(0.08)
    static let borderLit  = Color.white.opacity(0.14)

    // Text
    static let text       = Color.white.opacity(0.96)
    static let textDim    = Color.white.opacity(0.66)
    static let textMuted  = Color.white.opacity(0.50)

    // Functional accents
    static let running  = Color(red: 0.20, green: 0.78, blue: 0.45)   // Green
    static let detach   = Color(red: 0.96, green: 0.65, blue: 0.14)   // Amber
    static let kill     = Color(red: 0.94, green: 0.30, blue: 0.35)   // Red
    static let launch   = Color.white                                   // Clean white
}

// MARK: - Typography

enum Typo {
    private static let geist     = "GeistMono Nerd Font"
    private static let gohu      = "GohuFontuni14 Nerd Font"

    // UI type is the system face (SF Pro) at light weights; code-ish type is
    // SF Mono. Bold and semibold read heavy on the dark panels, so the
    // strongest weight here is semibold, and only for titles.
    static func title(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func heading(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium)
    }

    static func body(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular)
    }

    /// Reading font for message *content* (assistant/user prose) — SF Mono, the
    /// system monospace: crisp and fine, with native hinting, and still clearly
    /// monospaced/terminal-grade vs. the rounded SF used for UI chrome. (Was
    /// JetBrains Mono, which read heavier and wider for body copy.)
    static func reading(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func caption(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular)
    }

    /// SF Mono. Was JetBrains Mono, which read heavier and wider than the
    /// system type around it.
    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static func monoBold(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func geistMono(_ size: CGFloat = 11) -> Font {
        .custom(geist, size: size)
    }

    static func geistMonoBold(_ size: CGFloat = 11) -> Font {
        Font.custom(geist, size: size).weight(.medium)
    }

    static func pixel(_ size: CGFloat = 14) -> Font {
        .custom(gohu, size: size)
    }
}

// MARK: - Background

struct PanelBackground: View {
    var body: some View {
        Palette.bg
    }
}

// MARK: - Reusable modifiers

struct GlassCard: ViewModifier {
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Palette.surfaceHov : Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isHovered ? Palette.borderLit : Palette.border, lineWidth: 0.5)
                    )
            )
    }
}

struct LiquidGlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base: translucent dark fill
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))

                    // Subtle gradient: brighter at top edge for "glass reflection"
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.06), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )

                    // Border: top-bright, bottom-dark for depth
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)
    }
}

struct AngularButton: ViewModifier {
    let color: Color
    var filled: Bool = true

    func body(content: Content) -> some View {
        content
            .font(Typo.monoBold(10))
            .foregroundColor(filled ? Palette.bg : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(filled ? color : color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(filled ? Color.clear : color.opacity(0.25), lineWidth: 0.5)
            )
    }
}

/// Neutral switch. System `.switch` uses the macOS accent (blue) and fights the palette.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.text.opacity(0.20) : Palette.surface)
                    .overlay(
                        Capsule()
                            .strokeBorder(Palette.borderLit, lineWidth: 0.5)
                    )
                Circle()
                    .fill(isOn ? Palette.text : Palette.textDim)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

/// Quiet segmented control. Selected is lifted white, never system blue.
struct SettingsChoiceBar<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.0
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(Typo.caption(11))
                        .foregroundColor(selected ? Palette.text : Palette.textMuted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? Palette.surfaceHov : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.surface.opacity(0.85))
        )
    }
}

extension View {
    func glassCard(hovered: Bool = false) -> some View {
        modifier(GlassCard(isHovered: hovered))
    }

    func liquidGlass() -> some View {
        modifier(LiquidGlassCard())
    }

    func angularButton(_ color: Color, filled: Bool = true) -> some View {
        modifier(AngularButton(color: color, filled: filled))
    }
}

// MARK: - Chrome metrics

/// Ordinary macOS metrics for the app chrome. The rail, the per-page title bar,
/// and the status bar all size themselves from here so the three agree on the
/// same rhythm instead of each picking its own numbers.
enum Chrome {
    static let titleBarHeight: CGFloat = 46
    static let statusBarHeight: CGFloat = 26
    /// Horizontal inset shared by the title bar and the status bar, so the page
    /// name and the first status slot sit on one vertical line.
    static let inset: CGFloat = 16
    static let controlHeight: CGFloat = 26
    static let controlRadius: CGFloat = 6
    /// Hairline between chrome bands and the content they frame.
    static let hairline: CGFloat = 0.5
}

// MARK: - Boxes

extension View {
    /// Anything that holds content (a list, a field, a preview) gets a fill
    /// and the one hairline, at the control radius.
    func outlinedBox(_ fill: Color = Palette.surface, radius: CGFloat = Chrome.controlRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Palette.border, lineWidth: Chrome.hairline)
                )
        )
    }

    /// Buttons are fill only, so a row of actions doesn't read as a row of
    /// boxes. The emphasized one is a step brighter.
    func buttonBox(emphasized: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: Chrome.controlRadius)
                .fill(Color.white.opacity(emphasized ? 0.11 : 0.06))
        )
    }
}

// MARK: - Page actions

/// One control in a page's title bar.
///
/// Pages publish their own set with `.pageActions(...)` and the shell renders
/// them, so every page's actions land in the same place wearing the same shape
/// — the page decides *what* it can do, the chrome decides how that looks.
struct PageActionItem: Identifiable, Equatable {
    let id: String
    let title: String
    var isOn: Bool = false
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.isOn == rhs.isOn
    }
}

struct PageAction: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String?
    /// Rendered as a key cap after the title. Chords stay the second way in.
    let shortcut: String?
    let isPrimary: Bool
    let isEnabled: Bool
    let isOn: Bool?
    let menu: [PageActionItem]?
    let segments: [PageActionItem]?
    let perform: () -> Void

    init(
        id: String,
        title: String,
        icon: String? = nil,
        shortcut: String? = nil,
        isPrimary: Bool = false,
        isEnabled: Bool = true,
        isOn: Bool? = nil,
        menu: [PageActionItem]? = nil,
        segments: [PageActionItem]? = nil,
        perform: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isPrimary = isPrimary
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.menu = menu
        self.segments = segments
        self.perform = perform
    }

    /// Identity plus appearance. Closures can't be compared, and re-running a
    /// title bar because a capture changed would defeat `onPreferenceChange`.
    static func == (lhs: PageAction, rhs: PageAction) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.icon == rhs.icon
            && lhs.shortcut == rhs.shortcut
            && lhs.isPrimary == rhs.isPrimary
            && lhs.isEnabled == rhs.isEnabled
            && lhs.isOn == rhs.isOn
            && lhs.menu == rhs.menu
            && lhs.segments == rhs.segments
    }
}

struct PageActionsKey: PreferenceKey {
    static var defaultValue: [PageAction] { [] }

    static func reduce(value: inout [PageAction], nextValue: () -> [PageAction]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publishes this page's title-bar actions up to the app shell.
    func pageActions(_ actions: [PageAction]) -> some View {
        preference(key: PageActionsKey.self, value: actions)
    }
}

/// Title-bar control: 26pt tall, 6pt radius, hairline border. The primary
/// variant is the only one that carries hue, and it carries the running green.
struct PageActionButton: View {
    let action: PageAction
    var compact = false

    @State private var isHovering = false

    private var foreground: Color {
        if !action.isEnabled { return Palette.textMuted }
        if action.isPrimary || action.isOn == true  { return Palette.running }
        return isHovering ? Palette.text : Palette.textDim
    }

    private var fill: Color {
        if action.isPrimary || action.isOn == true { return Palette.running.opacity(isHovering ? 0.22 : 0.14) }
        return isHovering ? Palette.surfaceHov : Palette.surface
    }

    private var stroke: Color {
        if action.isPrimary || action.isOn == true { return Palette.running.opacity(0.32) }
        return isHovering ? Palette.borderLit : Palette.border
    }

    var body: some View {
        Group {
            if let items = action.segments {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        Button(action: item.perform) {
                            Text(item.title)
                                .font(Typo.body(12))
                                .foregroundColor(item.isOn
                                    ? Color(red: 236 / 255, green: 237 / 255, blue: 239 / 255)
                                    : Color(red: 176 / 255, green: 179 / 255, blue: 184 / 255))
                                .padding(.horizontal, 12)
                                .frame(height: Chrome.controlHeight - 4)
                                .background {
                                    if item.isOn {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(red: 36 / 255, green: 40 / 255, blue: 46 / 255))
                                            .overlay(RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
                                            .shadow(color: .black.opacity(0.20), radius: 1, y: 1)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item.isOn ? [.isSelected] : [])
                        .accessibilityValue(item.isOn ? "Selected" : "Not selected")
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
                .fixedSize()
            } else if let items = action.menu {
                Menu {
                    ForEach(items) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { item.isOn },
                            set: { _ in item.perform() }
                        ))
                    }
                } label: { controlLabel }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button(action: action.perform) { controlLabel }
                    .accessibilityValue(action.isOn.map { $0 ? "On" : "Off" } ?? "")
            }
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(action.title)
        .help(action.title + (action.shortcut.map { " " + $0 } ?? ""))
    }

    private var controlLabel: some View {
            HStack(spacing: 6) {
                if let icon = action.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                if !compact || action.icon == nil {
                    Text(action.title).font(Typo.body(12))
                }
                if let shortcut = action.shortcut, !compact {
                    KeyCap(shortcut)
                }
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .frame(height: Chrome.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Chrome.controlRadius)
                            .strokeBorder(stroke, lineWidth: Chrome.hairline)
                    )
            )
    }
}

/// A key cap. Monospace here is earned — chords are fixed-width data.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(Typo.mono(11))
            .foregroundColor(Palette.textDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Palette.border, lineWidth: Chrome.hairline)
                    )
            )
    }
}
