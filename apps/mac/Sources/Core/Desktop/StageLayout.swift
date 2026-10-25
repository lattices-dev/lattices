import CoreGraphics

/// Where a stage's windows sit while one of them is engaged.
///
/// Unit rects, y = 0 at the top. The set keeps a grid. The engaged window
/// grows to a fixed share of the display, centered on its own cell and kept
/// on screen. The others shrink inside their cells so they sit back.
enum StageLayout {
    /// Share of the display width the engaged window takes.
    static let activeWidth: CGFloat = 0.40
    /// Share of the display height the engaged window takes.
    static let activeHeight: CGFloat = 0.86
    /// How much of its home cell a resting window keeps.
    static let restScale: CGFloat = 0.84

    /// Column count for a set. Six windows read as a 3×2 grid.
    static func columns(for count: Int) -> Int {
        switch count {
        case ..<2: return 1
        case 2, 4: return 2
        case 3: return 3
        default: return 3
        }
    }

    /// Home cell for each window, row-major. A short last row is centered.
    static func homes(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = columns(for: count)
        let rows = (count + cols - 1) / cols
        let cellW = 1 / CGFloat(cols)
        let cellH = 1 / CGFloat(rows)
        return (0..<count).map { index in
            let row = index / cols
            let col = index % cols
            let inRow = min(cols, count - row * cols)
            let lead = (CGFloat(cols - inRow) * cellW) / 2
            return CGRect(
                x: lead + CGFloat(col) * cellW,
                y: CGFloat(row) * cellH,
                width: cellW,
                height: cellH
            )
        }
    }

    /// Frame for every window while `active` is the one being used.
    static func frames(count: Int, active: Int) -> [CGRect] {
        let homes = homes(count: count)
        guard homes.indices.contains(active) else { return homes }
        return homes.enumerated().map { index, home in
            index == active ? engaged(around: home) : inset(home, scale: restScale)
        }
    }

    /// The engaged window: `activeWidth` by `activeHeight`, centered on `home`, clamped to the display.
    static func engaged(around home: CGRect) -> CGRect {
        var frame = CGRect(
            x: home.midX - activeWidth / 2,
            y: home.midY - activeHeight / 2,
            width: activeWidth,
            height: activeHeight
        )
        frame.origin.x = min(max(frame.minX, 0), max(0, 1 - frame.width))
        frame.origin.y = min(max(frame.minY, 0), max(0, 1 - frame.height))
        return frame
    }

    static func inset(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let width = rect.width * scale
        let height = rect.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}
