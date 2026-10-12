import SwiftUI

// MARK: - Long

/// A small adaptive tile. Lighting is static; motion only follows incoming events.
struct Long: View {
    enum Mood: Equatable { case rest, listen, work, done, oops, away, talk }
    enum Depth: String, CaseIterable {
        case subtle, soft, bold
        var highlight: Double { switch self { case .subtle: 0.08; case .soft: 0.17; case .bold: 0.32 } }
    }
    var mood: Mood = .rest
    var size: CGFloat = 44
    var gaze: CGVector = .zero
    var depth: Depth = .soft
    /// Real playback amplitude, supplied by a speech event producer, never a clock.
    var speechLevel: Double = 0
    @Environment(\.colorScheme) private var scheme
    private var palette: LongPalette { LongPalette(scheme: scheme) }
    @Environment(\.accessibilityReduceMotion) private var still

    static let ink = Color(red: 0x10 / 255, green: 0x15 / 255, blue: 0x18 / 255)
    static let lit = Color(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf2 / 255)
    static let coral = Color(red: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255)

    var body: some View {
        let u = size / 100
        let leaning = mood == .listen && !still
        let nodding = mood == .done && !still
        ZStack {
            LongFeet().fill(palette.body)
            LongFeet().stroke(palette.face.opacity(0.12), lineWidth: max(0.5, u))
            LongBody().fill(palette.body)
                .shadow(color: .black.opacity(palette.shadowOpacity), radius: palette.shadowRadius * u, x: 0, y: palette.shadowOffset * u)
            LongBody().fill(LinearGradient(colors: [palette.isLight ? Color.white.opacity(depth.highlight * 2) : Self.lit.opacity(depth.highlight), .clear, (palette.isLight ? Self.ink.opacity(0.10) : Color.black.opacity(0.18))], startPoint: .topLeading, endPoint: .bottomTrailing))
            LongBody().stroke(LinearGradient(colors: [palette.isLight ? Color.white.opacity(0.8) : Self.lit.opacity(depth.highlight * 1.8), palette.face.opacity(palette.isLight ? 0.22 : 0.04)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.6, 1.4 * u))
            if mood == .away { LongCorner().fill(Self.coral) }
            Group {
                eyes(u)
                LongMouth(shape: mouthShape).fill(palette.face)
                    .animation(still ? nil : .easeOut(duration: 0.1), value: mouthShape)
            }
            .offset(x: mood == .away ? 4 * u : 0)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(leaning ? -7 : nodding ? 4 : 0), anchor: UnitPoint(x: 0.5, y: 0.92))
        .offset(y: leaning ? -1 : nodding ? 3 * u : 0)
        .animation(still ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: leaning)
        .animation(still ? nil : .easeOut(duration: 0.24), value: mood)
        .accessibilityHidden(true)
    }

    /// Closed at rest; a small round "ooh" while listening; low and flat for
    /// oops; while talking its opening follows playback amplitude.
    private var mouthShape: LongMouth.Form {
        switch mood {
        case .listen: .ooh
        case .oops: .oops
        case .talk: still ? .half : speechLevel > 0.6 ? .open : speechLevel > 0.15 ? .half : .closed
        default: .closed
        }
    }

    private func eyes(_ u: CGFloat) -> some View {
        let squint: CGFloat = mood == .oops ? 0.3 : mood == .listen ? 1.2 : mood == .work ? 0.7 : 1
        let looking = mood == .rest || mood == .listen || mood == .away || mood == .talk
        let dx: CGFloat = mood == .work ? 3 : looking ? gaze.dx : 0
        let dy: CGFloat = mood == .listen ? -2.5 + gaze.dy : mood == .oops ? 3 : looking ? gaze.dy : 0
        return ZStack {
            LongEye(cx: 38, cy: 32).fill(palette.face).scaleEffect(x: 1, y: squint, anchor: UnitPoint(x: 0.38, y: 0.32))
            LongEye(cx: 62, cy: 32).fill(palette.face).scaleEffect(x: 1, y: squint, anchor: UnitPoint(x: 0.62, y: 0.32))
        }
        .offset(x: dx * u, y: dy * u)
        .animation(still ? nil : .easeOut(duration: 0.18), value: gaze)
    }

}

// MARK: Long's pieces, on the 100-unit grid

private extension CGRect {
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: minX + x * width / 100, y: minY + y * height / 100)
    }
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: at(x, y), size: CGSize(width: w * width / 100, height: h * height / 100))
    }
}

private struct LongBody: Shape {
    func path(in r: CGRect) -> Path {
        Path(roundedRect: r.box(10, 6, 80, 80), cornerRadius: 20 * r.width / 100, style: .continuous)
    }
}

/// The mouth: a solid tile with the body's corners, a quarter of its width.
/// Closing squashes it to a bar and the corners stay round.
private struct LongMouth: Shape {
    enum Form: Equatable { case closed, half, open, ooh, oops }
    var shape: Form
    func path(in r: CGRect) -> Path {
        let (w, h, dy): (CGFloat, CGFloat, CGFloat) = switch shape {
        case .closed: (22, 6, 0)
        case .half: (22, 13, 0)
        case .open: (22, 20, 0)
        case .ooh: (13, 12, 0)
        case .oops: (16, 5, 4)
        }
        let radius = min(w * 0.25, h / 2) * r.width / 100
        return Path(roundedRect: r.box(50 - w / 2, 64 + dy - h / 2, w, h), cornerRadius: radius, style: .continuous)
    }
}

/// The coral cell in his top-right corner while you're away.
private struct LongCorner: Shape {
    func path(in r: CGRect) -> Path {
        Path(roundedRect: r.box(74.5, 14.5, 7, 7), cornerRadius: 1.75 * r.width / 100, style: .continuous)
    }
}

private struct LongFeet: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for x in [26, 62] as [CGFloat] {
            p.addRoundedRect(in: r.box(x, 80, 12, 12), cornerSize: CGSize(width: 4.5 * r.width / 100, height: 4.5 * r.width / 100))
        }
        return p
    }
}

private struct LongEye: Shape {
    var cx, cy: CGFloat
    func path(in r: CGRect) -> Path {
        Path(roundedRect: r.box(cx - 7, cy - 7, 14, 14), cornerRadius: 3.5 * r.width / 100, style: .continuous)
    }
}
