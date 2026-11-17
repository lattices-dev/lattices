import SwiftUI

// MARK: - Overview chrome

/// One set of measures for every Overview control, on the app's own chrome
/// metrics. Strokes are a whole point: the shell can seat the page on a
/// fractional y, and a half-point horizontal hairline then straddles two
/// device rows at partial coverage and vanishes, leaving a pill with sides
/// but no top. A point-wide line keeps at least one full row at any offset.
enum OverviewChrome {
    static let controlHeight: CGFloat = Chrome.controlHeight
    static let radius: CGFloat = Chrome.controlRadius
    static let stroke: CGFloat = 1
    /// Control edge at rest, lit on hover, and the selected edge.
    static let edge = Color.white.opacity(0.07)
    static let edgeLit = Color.white.opacity(0.13)
    static let edgeOn = Color.white.opacity(0.22)
}

/// A control's look in Overview: quiet chips and buttons on one height,
/// radius, stroke and type. Primary is the one ink-filled action in a
/// group (Focus); selected is a chip that's on. Hover lifts the edge and
/// fill, a press darkens it, keyboard focus rings it, disabled dims it.
struct OverviewButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var selected = false
    var height: CGFloat = OverviewChrome.controlHeight
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, selected: selected, height: height, fill: fill)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        let selected: Bool
        let height: CGFloat
        let fill: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let live = enabled && hovered
            configuration.label
                .font(Typo.mono(10))
                .foregroundColor(foreground)
                .lineLimit(1)
                .padding(.horizontal, fill ? 4 : 9)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: OverviewChrome.radius)
                        .fill(background(live))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OverviewChrome.radius)
                        .strokeBorder(edge(live), lineWidth: OverviewChrome.stroke)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OverviewChrome.radius + 2)
                        .strokeBorder(Palette.text.opacity(focused ? 0.5 : 0), lineWidth: OverviewChrome.stroke)
                        .padding(-2)
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.1), value: hovered)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Palette.bg
            case .secondary: return selected || hovered ? Palette.text : Palette.text.opacity(0.72)
            case .quiet: return selected || hovered ? Palette.text : Palette.textDim
            }
        }

        private func background(_ live: Bool) -> Color {
            let pressed = configuration.isPressed
            switch kind {
            case .primary:
                return Palette.text.opacity(pressed ? 0.75 : live ? 1 : 0.9)
            case .secondary:
                if pressed { return Color.white.opacity(0.03) }
                return selected ? Color.white.opacity(0.10) : Color.white.opacity(live ? 0.07 : 0.04)
            case .quiet:
                if pressed { return Color.white.opacity(0.03) }
                return selected ? Color.white.opacity(0.10) : Color.white.opacity(live ? 0.06 : 0)
            }
        }

        private func edge(_ live: Bool) -> Color {
            switch kind {
            case .primary: return .clear
            case .secondary: return selected ? OverviewChrome.edgeOn : live ? OverviewChrome.edgeLit : OverviewChrome.edge
            case .quiet: return selected ? OverviewChrome.edgeOn : live ? OverviewChrome.edgeLit : .clear
            }
        }
    }
}

extension ButtonStyle where Self == OverviewButtonStyle {
    static var overview: OverviewButtonStyle { OverviewButtonStyle() }
    static func overview(_ kind: OverviewButtonStyle.Kind = .secondary, selected: Bool = false,
                         height: CGFloat = OverviewChrome.controlHeight, fill: Bool = false) -> OverviewButtonStyle {
        OverviewButtonStyle(kind: kind, selected: selected, height: height, fill: fill)
    }
}

/// A key the action answers to, beside its label.
struct OverviewKeycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(Typo.mono(8))
            .foregroundColor(Palette.textMuted)
            .padding(.horizontal, 4)
            .frame(minWidth: 15)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(OverviewChrome.edgeLit, lineWidth: OverviewChrome.stroke))
    }
}

/// A menu wearing the secondary control's shape, for Kind, Move and Layer.
struct OverviewMenuChrome: ViewModifier {
    var selected = false
    /// No fill or edge at rest, as in the selection's capsule.
    var quiet = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            // A button-styled menu keeps the label as written; borderless
            // re-lays it out with the chevron first in system ink.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: OverviewChrome.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: OverviewChrome.radius)
                    .fill(Color.white.opacity(selected ? 0.10 : hovered && enabled ? 0.07 : quiet ? 0 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OverviewChrome.radius)
                    .strokeBorder(selected ? OverviewChrome.edgeOn : hovered && enabled ? OverviewChrome.edgeLit : quiet ? .clear : OverviewChrome.edge,
                                  lineWidth: OverviewChrome.stroke)
            )
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

/// A menu's label: its name and a small chevron, in the control type.
struct OverviewMenuLabel: View {
    let title: String
    var selected = false
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(Typo.mono(10))
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .foregroundColor(selected ? Palette.text : Palette.textDim)
    }
}

extension View {
    func overviewMenu(selected: Bool = false, quiet: Bool = false) -> some View {
        modifier(OverviewMenuChrome(selected: selected, quiet: quiet))
    }

    /// Lifted content: a surface a shade above the page, a whole-point edge
    /// lit along its top, and a soft shadow under it.
    func overviewCard(radius: CGFloat = 8) -> some View {
        background(
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(Palette.surface)
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center))
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                        lineWidth: OverviewChrome.stroke
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
    }
}

/// The stage's ground: a faint dot grid, so the maps sit on a surface.
struct OverviewStageGround: View {
    var dotOpacity: Double = 0.07
    var dotSize: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize))
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(Color.white.opacity(dotOpacity)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
