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
}
