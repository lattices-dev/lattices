import SwiftUI

/// The Machines canvases sit a step lighter than the rest of the app: the
/// monitors are the subject, so they read as lit panels on a raised well.
enum MachineTone {
    static let well      = Color.white.opacity(0.05)
    static let wellEdge  = Color.white.opacity(0.12)
    static let tileTop   = Color(white: 0.28)
    static let tileBase  = Color(white: 0.21)
    static let tileEdge  = Color.white.opacity(0.30)
    static let backing   = Color(white: 0.12)
    static let label     = Color.white.opacity(0.82)
    static let chip      = Color(white: 0.10).opacity(0.88)
    static let chipEdge  = Color.white.opacity(0.16)
    static let gridMinor = Color.white.opacity(0.11)
    static let gridMajor = Color.white.opacity(0.24)
    /// Something not on screen here: dimmed, never hidden.
    static let away: Double = 0.55
    static let offline: Double = 0.7

    static var tile: LinearGradient { LinearGradient(colors: [tileTop, tileBase], startPoint: .top, endPoint: .bottom) }

    static var monitorBezel: LinearGradient {
        LinearGradient(colors: [Color(white: 0.23), Color(white: 0.145), Color(white: 0.125), Color(white: 0.19)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A narrow monitor casing inside the existing canvas rectangle. The screen
/// is recessed, while the whole rectangle remains available for dragging.
struct MachineMonitorFrame<Screen: View>: View {
    let size: CGSize
    var edge: Color = MachineTone.tileEdge
    var stroke = StrokeStyle(lineWidth: 1)
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let inset = min(3, max(0, min(size.width, size.height) / 8))
        let lip = min(7, max(0, size.height / 5))
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let screenInsets = EdgeInsets(top: inset, leading: inset, bottom: lip, trailing: inset)
        ZStack(alignment: .topLeading) {
            shape.fill(MachineTone.monitorBezel)
            // Keep the original image coordinates for region selection. The
            // casing masks the perimeter instead of rescaling the picture.
            screen()
                .frame(width: size.width, height: size.height)
                .mask(RoundedRectangle(cornerRadius: 3, style: .continuous).padding(screenInsets))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.85), lineWidth: 1)
                    .padding(screenInsets)
                    .allowsHitTesting(false))
        }
        .frame(width: size.width, height: size.height)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.12), .clear, Color.black.opacity(0.6)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .padding(1).allowsHitTesting(false))
        .overlay(shape.strokeBorder(edge, style: stroke).allowsHitTesting(false))
        .overlay(alignment: .bottom) {
            Capsule().fill(Color.white.opacity(0.09))
                .frame(width: min(28, size.width * 0.2), height: 1)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 4, x: 0, y: 3)
        .contentShape(Rectangle())
    }
}
