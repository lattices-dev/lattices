import ActionCore
import SwiftUI

/// The tile the mark sits on — the same continuous-corner rounded rect the app
/// icon uses, so the chip in a header and the icon in the Dock are one mark.
struct ActionBrandTileShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ActionBrandMark.tilePath(in: rect))
    }
}

/// The A or its cursor, placed inside a tile the way the app icon places
/// them. Hand it the tile's bounds and it works out its own inset.
struct ActionBrandGlyphShape: Shape {
    enum Part {
        case letter
        case cursor
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        let mark = ActionBrandMark.markRect(inTile: rect, yAxis: .down)
        switch part {
        case .letter:
            return Path(ActionBrandMark.letterPath(in: mark, yAxis: .down))
        case .cursor:
            return Path(ActionBrandMark.cursorPath(in: mark, yAxis: .down))
        }
    }
}

/// Action's brand chip: the app icon, drawn live.
///
/// The same tile and glyph the app icon carries, the letter in the ink and the
/// cursor in coral, so the chip in a header and the icon in the Dock are one
/// mark. The tile and the glyph read theme tokens rather than baked colours,
/// so they follow a theme switch, which the icon on disk cannot, and that is
/// the one place the two are allowed to drift. Under a dark theme they match
/// the dark icon: light ink on a dark tile.
struct ActionBrandTile: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ActionBrandTileShape()
                .fill(StageHUDTheme.hudPaper)
            ActionBrandGlyphShape(part: .letter)
                .fill(StageHUDTheme.hudInk)
            ActionBrandGlyphShape(part: .cursor)
                .fill(StageHUDTheme.hudCoral)
        }
        .frame(width: size, height: size)
        .overlay(
            ActionBrandTileShape()
                .stroke(StageHUDTheme.hudInk.opacity(0.10), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}
