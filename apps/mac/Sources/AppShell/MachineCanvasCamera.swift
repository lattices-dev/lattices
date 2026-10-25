import CoreGraphics
import Foundation

/// Pan and zoom for the Machines canvas, after Hudson's `HudCanvasState`.
/// World points are CG global display points; viewport points are the
/// canvas view's own, top-left origin. Pure, so the projection is testable.
struct MachineCanvasCamera: Equatable {
    var pan: CGSize = .zero
    var scale: CGFloat = 0.1
    var viewport: CGSize = .zero
    /// The scale that fits everything; zoom limits and the percentage hang off it.
    var fitScale: CGFloat = 0.1

    var minimumScale: CGFloat { fitScale * 0.5 }
    var maximumScale: CGFloat { max(fitScale * 12, 1) }
    /// Zoom relative to the fitted view, which reads as 100%.
    var percent: Int { Int((scale / max(fitScale, .ulpOfOne) * 100).rounded()) }

    func worldPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / scale, y: (point.y - pan.height) / scale)
    }
    func viewportPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: pan.width + point.x * scale, y: pan.height + point.y * scale)
    }
    func viewportRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: viewportPoint(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func panned(by delta: CGSize) -> Self {
        var next = self
        next.pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        return next
    }

    /// Keeps the world point under `anchor` where it is.
    func zoomed(to proposed: CGFloat, around anchor: CGPoint) -> Self {
        let next = min(max(proposed, minimumScale), maximumScale)
        guard next != scale else { return self }
        let world = worldPoint(anchor)
        var camera = self
        camera.scale = next
        camera.pan = CGSize(width: anchor.x - world.x * next, height: anchor.y - world.y * next)
        return camera
    }

    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> Self { zoomed(to: scale * factor, around: anchor) }
    func zoomed(by factor: CGFloat) -> Self {
        zoomed(by: factor, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    /// Centres `content` in `viewport` and makes that scale the 100% mark.
    static func fitting(_ content: CGRect, in viewport: CGSize, padding: CGFloat = 28) -> Self {
        let room = CGSize(width: max(1, viewport.width - padding * 2), height: max(1, viewport.height - padding * 2))
        guard content.width > 0, content.height > 0, !content.isNull else {
            return Self(viewport: viewport)
        }
        let scale = min(room.width / content.width, room.height / content.height)
        return Self(
            pan: CGSize(width: padding + (room.width - content.width * scale) / 2 - content.minX * scale,
                        height: padding + (room.height - content.height * scale) / 2 - content.minY * scale),
            scale: scale, viewport: viewport, fitScale: scale)
    }

    /// The space is bounded: at least `margin` points of content stay in view.
    func clamped(to content: CGRect, margin: CGFloat = 80) -> Self {
        guard !content.isNull, viewport.width > 0, viewport.height > 0 else { return self }
        let r = viewportRect(content)
        let mx = min(margin, r.width / 2, viewport.width / 2)
        let my = min(margin, r.height / 2, viewport.height / 2)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.maxX < mx { dx = mx - r.maxX } else if r.minX > viewport.width - mx { dx = viewport.width - mx - r.minX }
        if r.maxY < my { dy = my - r.maxY } else if r.minY > viewport.height - my { dy = viewport.height - my - r.minY }
        return dx == 0 && dy == 0 ? self : panned(by: CGSize(width: dx, height: dy))
    }

    /// The canvas band follows the content's shape: wide arrangements get a
    /// short band, tall or crowded ones a taller one, inside the page's room.
    static func bandHeight(content: CGRect, width: CGFloat, available: CGFloat, padding: CGFloat = 28) -> CGFloat {
        let floor: CGFloat = 220
        let ceiling = max(floor, min(560, available * 0.6))
        guard content.width > 0, content.height > 0, !content.isNull else { return floor }
        let natural = (width - padding * 2) * content.height / content.width + padding * 2
        return min(max(natural, floor), ceiling).rounded()
    }

    /// A rectangle dragged across a monitor's tile, in the host's own layout
    /// coordinates (what its capture and input take). Nil when it misses.
    static func hostRegion(_ selection: CGRect, tile: CGRect, monitor: CGRect) -> CGRect? {
        let hit = selection.standardized.intersection(tile)
        guard !hit.isNull, tile.width > 0, tile.height > 0 else { return nil }
        let sx = monitor.width / tile.width, sy = monitor.height / tile.height
        let region = CGRect(x: monitor.minX + (hit.minX - tile.minX) * sx, y: monitor.minY + (hit.minY - tile.minY) * sy,
                            width: hit.width * sx, height: hit.height * sy).integral
        return region.width >= 32 && region.height >= 32 ? region : nil
    }
}
