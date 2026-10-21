import AppKit

/// Blink's shared mark: a framed spatial surface with two diagonally placed notes.
/// The idle menubar image is a template so macOS owns its contrast; the armed
/// image uses Blink's signal blue without changing any geometry.
enum BlinkIcon {
    static let accent = NSColor(
        srgbRed: 93.0 / 255.0,
        green: 158.0 / 255.0,
        blue: 250.0 / 255.0,
        alpha: 1
    )

    static func menuBar(armed: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let color = armed ? accent : NSColor.black
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            drawMark(in: rect, color: color)
            return true
        }
        image.isTemplate = !armed
        image.accessibilityDescription = armed ? "Canvas, capture open" : "Canvas"
        return image
    }

    private static func drawMark(in rect: NSRect, color: NSColor) {
        let side = min(rect.width, rect.height)
        let origin = NSPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let frameRect = NSRect(
            x: origin.x + side * 0.14,
            y: origin.y + side * 0.14,
            width: side * 0.72,
            height: side * 0.72
        )
        let frame = NSBezierPath(
            roundedRect: frameRect,
            xRadius: side * 0.17,
            yRadius: side * 0.17
        )
        frame.lineWidth = side * 0.06
        color.setStroke()
        frame.stroke()

        let blockSide = side * 0.18
        color.setFill()
        NSRect(
            x: origin.x + side * 0.32,
            y: origin.y + side * 0.50,
            width: blockSide,
            height: blockSide
        ).fill()
        NSRect(
            x: origin.x + side * 0.50,
            y: origin.y + side * 0.32,
            width: blockSide,
            height: blockSide
        ).fill()
    }
}
