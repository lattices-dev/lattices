import CoreGraphics

/// A crop of a display at its normal point size. All coordinates use a
/// top-left origin; backing-pixel density belongs to the renderer.
public struct ActionMonitorViewport: Equatable, Sendable {
    public private(set) var displaySize: CGSize
    public private(set) var viewportSize: CGSize
    public private(set) var origin: CGPoint

    public var scale: CGFloat { 1 }

    /// Places a borrowed window inside the monitor, allowing for the complete
    /// cascade offset when sizing it. Small displays reduce the inset and offset.
    public static func borrowedWindowFrame(size: CGSize, index: Int, displayBounds: CGRect) -> CGRect? {
        guard !displayBounds.isInfinite, !displayBounds.isNull, !displayBounds.isEmpty,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
              displayBounds.size.width.isFinite, displayBounds.size.height.isFinite,
              displayBounds.size.width > 0, displayBounds.size.height > 0,
              displayBounds.maxX.isFinite, displayBounds.maxY.isFinite else { return nil }
        let step = CGFloat(max(0, index) % 8) * 36
        func axis(_ extent: CGFloat, requested: CGFloat) -> (offset: CGFloat, size: CGFloat) {
            let inset = min(80, extent / 4)
            let room = extent - 2 * inset
            let cascade = min(step, room / 2)
            return (inset + cascade, min(requested, room - cascade))
        }
        let horizontal = axis(displayBounds.width, requested: size.width)
        let vertical = axis(displayBounds.height, requested: size.height)
        return CGRect(x: displayBounds.minX + horizontal.offset,
                      y: displayBounds.minY + vertical.offset,
                      width: horizontal.size, height: vertical.size)
    }

    public init(displaySize: CGSize, viewportSize: CGSize, origin: CGPoint = .zero) {
        self.displaySize = Self.validSize(displaySize)
        self.viewportSize = Self.validSize(viewportSize)
        self.origin = CGPoint(x: origin.x.isFinite ? origin.x : 0,
                              y: origin.y.isFinite ? origin.y : 0)
        clampOrigin()
    }

    /// The display-local rectangle currently visible, excluding any blank
    /// portion of a viewport that is larger than the display.
    public var visibleRect: CGRect {
        CGRect(origin: origin, size: CGSize(
            width: min(viewportSize.width, displaySize.width - origin.x),
            height: min(viewportSize.height, displaySize.height - origin.y)))
    }

    /// Positive deltas move the crop right and down. Invalid input is ignored.
    public mutating func pan(delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        origin.x += delta.x
        origin.y += delta.y
        clampOrigin()
    }

    /// Adjacent pages overlap by 10 percent, keeping context without scaling.
    public mutating func page(direction: Int) {
        guard direction != 0 else { return }
        pan(delta: CGPoint(x: viewportSize.width * 0.9 * (direction > 0 ? 1 : -1), y: 0))
    }

    public mutating func resize(viewportSize: CGSize) {
        update(displaySize: displaySize, viewportSize: viewportSize)
    }

    /// Retains the crop's origin when possible, then clamps to the new bounds.
    public mutating func update(displaySize: CGSize, viewportSize: CGSize) {
        self.displaySize = Self.validSize(displaySize)
        self.viewportSize = Self.validSize(viewportSize)
        clampOrigin()
    }

    /// Converts a point inside the visible content without scaling it.
    /// Outside points, blank margins, and nonfinite input have no display target.
    public func displayPoint(forViewPoint point: CGPoint) -> CGPoint? {
        let visible = visibleRect.size
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < visible.width, point.y < visible.height else { return nil }
        return CGPoint(x: origin.x + point.x, y: origin.y + point.y)
    }

    private mutating func clampOrigin() {
        origin.x = min(max(origin.x, 0), max(0, displaySize.width - viewportSize.width))
        origin.y = min(max(origin.y, 0), max(0, displaySize.height - viewportSize.height))
    }

    private static func validSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
               height: size.height.isFinite ? max(0, size.height) : 0)
    }
}
