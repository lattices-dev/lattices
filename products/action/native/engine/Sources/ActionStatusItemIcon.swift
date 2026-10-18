import ActionCore
import AppKit

extension ActionBrandMark {
    /// The status item image.
    ///
    /// At rest it is a template, so the menu bar tints it for the current
    /// appearance and inverts it on highlight — the behaviour every other extra
    /// has. While a drive holds the machine it is drawn in coral instead, which
    /// is the same thing coral means everywhere else in the app: something is
    /// live. A template image cannot carry colour, so the live variant gives up
    /// template tinting; that is fine, because a coral mark is legible against
    /// both a light and a dark menu bar.
    @MainActor
    static func statusItemImage(live: Bool) -> NSImage {
        // A 14pt glyph centred in an 18pt image. Menu bar extras are expected to
        // sit a little inside their slot; filling it edge to edge reads as
        // shouting next to the system's own items.
        let side: CGFloat = 18
        let glyph: CGFloat = 14
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inset = (side - glyph) / 2
            let design = designRect(fittingGlyphIn: rect.insetBy(dx: inset, dy: inset))
            context.addPath(markPath(in: design, gap: statusItemGap))
            context.setFillColor(live ? coral : .black)
            context.fillPath()
            return true
        }
        image.isTemplate = !live
        return image
    }

    /// Clearance between the letter and the cursor in the menu bar. In one
    /// colour the gap is all that separates the cursor from the leg, and at
    /// this size the standard ten units come to about a third of a point, so
    /// the two fuse into one blot. Thirty-six units open it to about a point.
    private static let statusItemGap = 36.0
}
