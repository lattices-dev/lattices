import CoreGraphics

/// Shared row-major grid geometry for window arrangement and its previews.
/// All rectangles use a top-left origin; each row fills the available width.
public enum WindowGridPlanner {
    /// Column counts per row, preserving the smart-grid policy used by distribute.
    /// A requested shape is accepted only when its positive counts total `count`.
    public static func shape(for count: Int, requested: [Int]? = nil) -> [Int] {
        guard count > 0 else { return [] }
        if let requested, requested.allSatisfy({ $0 > 0 }), requested.reduce(0, +) == count {
            return requested
        }

        switch count {
        case 1: return [1]
        case 2: return [2]
        case 3: return [3]
        case 4: return [2, 2]
        case 5: return [3, 2]
        case 6: return [3, 3]
        case 7: return [4, 3]
        case 8: return [4, 4]
        case 9: return [3, 3, 3]
        case 10: return [5, 5]
        case 11: return [4, 4, 3]
        case 12: return [4, 4, 4]
        default:
            // Bias toward more columns for landscape screens.
            let columns = Int(ceil(sqrt(Double(count) * 1.5)))
            var rows: [Int] = []
            var remaining = count
            while remaining > 0 {
                rows.append(min(columns, remaining))
                remaining -= columns
            }
            return rows
        }
    }

    /// Unit rectangles in stable row-major order, with no gaps or rounding.
    public static func normalizedSlots(count: Int, shape: [Int]? = nil) -> [CGRect] {
        let rows = self.shape(for: count, requested: shape)
        guard !rows.isEmpty else { return [] }
        let rowHeight = 1 / CGFloat(rows.count)
        var slots: [CGRect] = []
        slots.reserveCapacity(count)
        for (row, columns) in rows.enumerated() {
            let columnWidth = 1 / CGFloat(columns)
            for column in 0..<columns {
                slots.append(CGRect(
                    x: CGFloat(column) * columnWidth,
                    y: CGFloat(row) * rowHeight,
                    width: columnWidth,
                    height: rowHeight
                ))
            }
        }
        return slots
    }

    /// Project a grid into a top-left-origin area and optional fractional sub-region.
    public static func slots(
        count: Int,
        in area: CGRect,
        region: CGRect? = nil,
        shape: [Int]? = nil
    ) -> [CGRect] {
        let target: CGRect
        if let region {
            target = CGRect(
                x: area.minX + area.width * region.minX,
                y: area.minY + area.height * region.minY,
                width: area.width * region.width,
                height: area.height * region.height
            )
        } else {
            target = area
        }
        return normalizedSlots(count: count, shape: shape).map { slot in
            CGRect(
                x: target.minX + target.width * slot.minX,
                y: target.minY + target.height * slot.minY,
                width: target.width * slot.width,
                height: target.height * slot.height
            )
        }
    }
}
