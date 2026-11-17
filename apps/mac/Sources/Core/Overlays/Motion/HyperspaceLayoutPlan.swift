import Foundation

/// Desktop geometry uses AX's top-left coordinates. A plan is pure data until
/// MotionPanel resolves every window and applies the whole change.
struct HyperspaceLayoutPlan: Equatable {
    var title: String
    var frames: [UInt32: CGRect]
}

enum HyperspaceLayoutPlanner {
    static let minimumSize = CGSize(width: 280, height: 180)
    /// Space left between windows when a layout lands. Small enough that
    /// neighboring windows read as one arrangement.
    static let gap: CGFloat = 4

    /// Ordered, feasible alternatives for the current selection. The overview
    /// tray shows at most four. `arrangements` keeps every distinct style so a
    /// placed bunch can cycle further.
    static func options(_ ids: [UInt32], in area: CGRect) -> [HyperspaceLayoutPlan] {
        Array(arrangements(ids, in: area).prefix(4))
    }

    /// Every distinct style for these windows, in tap order. A grid leads when
    /// there are more than three windows and follows columns with three.
    /// Then both mains, then rows.
    static func arrangements(_ ids: [UInt32], in area: CGRect) -> [HyperspaceLayoutPlan] {
        guard !ids.isEmpty, Set(ids).count == ids.count,
              area.width.isFinite, area.height.isFinite,
              area.width >= minimumSize.width, area.height >= minimumSize.height else { return [] }
        var candidates: [HyperspaceLayoutPlan?] = [columns(ids, in: area)]
        if ids.count > 2 {
            candidates += [mainAndCompanions(ids, in: area, leading: true),
                           mainAndCompanions(ids, in: area, leading: false)]
        }
        if ids.count > 1 { candidates.append(rows(ids, in: area)) }
        // From four windows the grid leads. With three it follows columns,
        // ahead of the mains, so it shows in the four-chip tray.
        if ids.count > 3 { candidates.insert(grid(ids, in: area), at: 0) }
        else if ids.count == 3 { candidates.insert(grid(ids, in: area), at: 1) }
        var result: [HyperspaceLayoutPlan] = []
        for plan in candidates.compactMap({ $0 }) where !result.contains(where: { $0.frames == plan.frames }) {
            result.append(plan)
        }
        return result
    }

    static func isArrangement(_ title: String) -> Bool {
        title == "Rows" || title == "Main left" || title == "Main right" || title == "Balanced grid"
            || title == "Fill display" || title.contains("column")
    }

    static func rows(_ ids: [UInt32], in area: CGRect) -> HyperspaceLayoutPlan? {
        guard !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        let height = (area.height - gap * CGFloat(ids.count - 1)) / CGFloat(ids.count)
        guard height >= minimumSize.height, area.width >= minimumSize.width else { return nil }
        return .init(title: "Rows", frames: Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: area.minX, y: area.minY + CGFloat(index) * (height + gap),
                        width: area.width, height: height).integral)
        }))
    }

    static func mainAndCompanions(_ ids: [UInt32], in area: CGRect, leading: Bool) -> HyperspaceLayoutPlan? {
        guard ids.count >= 3, Set(ids).count == ids.count else { return nil }
        let mainWidth = (area.width - gap) * 0.6
        let sideWidth = area.width - gap - mainWidth
        let sideHeight = (area.height - gap * CGFloat(ids.count - 2)) / CGFloat(ids.count - 1)
        guard sideWidth >= minimumSize.width, mainWidth >= minimumSize.width,
              sideHeight >= minimumSize.height else { return nil }
        var frames: [UInt32: CGRect] = [ids[0]: CGRect(x: leading ? area.minX : area.maxX - mainWidth,
            y: area.minY, width: mainWidth, height: area.height).integral]
        for (index, id) in ids.dropFirst().enumerated() {
            frames[id] = CGRect(x: leading ? area.minX + mainWidth + gap : area.minX,
                y: area.minY + CGFloat(index) * (sideHeight + gap), width: sideWidth, height: sideHeight).integral
        }
        return .init(title: leading ? "Main left" : "Main right", frames: frames)
    }

    /// Window shape a grid cell aims for. Most windows read best a bit wider
    /// than tall, so an ultrawide gets more columns and a portrait display more rows.
    static let preferredCellAspect: CGFloat = 1.45

    /// A real grid: at least two rows and two columns, so it never repeats
    /// Rows or Columns. The shape whose cells come closest to
    /// `preferredCellAspect` wins, and empty cells count against it. When the
    /// windows don't fill every cell, the top row holds fewer, wider windows,
    /// so the first pick gets the most room.
    static func grid(_ ids: [UInt32], in area: CGRect) -> HyperspaceLayoutPlan? {
        guard ids.count >= 3, Set(ids).count == ids.count else { return nil }
        var best: (score: CGFloat, rows: Int, cols: Int)?
        for rowCount in 2...ids.count {
            let cols = Int(ceil(Double(ids.count) / Double(rowCount)))
            guard cols >= 2, (rowCount - 1) * cols < ids.count else { continue }
            let width = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let height = (area.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
            guard width >= minimumSize.width, height >= minimumSize.height else { continue }
            let empties = CGFloat(rowCount * cols - ids.count)
            let score = abs(log(width / height / preferredCellAspect)) + 0.3 * empties
            if best == nil || score < best!.score { best = (score, rowCount, cols) }
        }
        guard let shape = best else { return nil }
        let height = (area.height - gap * CGFloat(shape.rows - 1)) / CGFloat(shape.rows)
        let short = ids.count - (shape.rows - 1) * shape.cols
        var frames: [UInt32: CGRect] = [:]
        var next = 0
        for row in 0..<shape.rows {
            let count = row == 0 ? short : shape.cols
            let width = (area.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for column in 0..<count {
                frames[ids[next]] = CGRect(x: area.minX + CGFloat(column) * (width + gap),
                    y: area.minY + CGFloat(row) * (height + gap), width: width, height: height).integral
                next += 1
            }
        }
        return .init(title: "Balanced grid", frames: frames)
    }

    static func columns(_ ids: [UInt32], in area: CGRect) -> HyperspaceLayoutPlan? {
        guard !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        let width = (area.width - gap * CGFloat(ids.count - 1)) / CGFloat(ids.count)
        guard width >= minimumSize.width, area.height >= minimumSize.height else { return nil }
        let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: area.minX + CGFloat(index) * (width + gap), y: area.minY,
                        width: width, height: area.height).integral)
        })
        return HyperspaceLayoutPlan(title: ids.count == 1 ? "Fill display" : "\(ids.count) equal columns", frames: frames)
    }

    static func drop(_ id: UInt32, original: CGRect, start: CGPoint, at point: CGPoint,
                     in area: CGRect, neighbors: [(UInt32, CGRect)], occupied obstacles: [CGRect] = []) -> HyperspaceLayoutPlan {
        // Only the dragged window moves, plus the one neighbor a shared edge
        // bisects. A selection uses `dropGroup` and does not adopt outsiders.
        // The same map as overview: a quartile center or a screen corner is that
        // quarter, an outer edge is a half, and the band inside the edge is a third.
        // A partly filled quarter yields its open half instead. The open middle
        // follows the hand. `approach` draws the nearest spot before the pointer
        // crosses into it.
        if let shared = sharedEdge(id, at: point, neighbors: neighbors) { return shared }
        let occupied = neighbors.map(\.1) + obstacles
        if let slot = openSlot(id, at: point, in: area, occupied: occupied) { return slot }
        let (fx, fy) = unitPoint(point, in: area)
        if let plan = zoned(id, fx: fx, fy: fy, in: area) { return plan }
        return moved(id, original: original, start: start, at: point, in: area)
    }

    /// The landing just outside the spot `drop` would commit. Nil in the open
    /// middle, and nil once the pointer is already inside a spot.
    static func approach(_ id: UInt32, at point: CGPoint, in area: CGRect, occupied: [CGRect] = []) -> HyperspaceLayoutPlan? {
        if openSlot(id, at: point, in: area, occupied: occupied) != nil { return nil }
        if let nearby = nearestOpenSlot(id, at: point, in: area, occupied: occupied) { return nearby }
        let (fx, fy) = unitPoint(point, in: area)
        guard zoned(id, fx: fx, fy: fy, in: area) == nil else { return nil }
        let hearts: [(CGFloat, CGFloat)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        var nearest: (CGFloat, HyperspaceLayoutPlan)?
        for (qx, qy) in hearts {
            let distance = hypot(fx - qx, fy - qy)
            guard distance <= 0.22, let plan = quarter(id, left: qx < 0.5, top: qy < 0.5, in: area) else { continue }
            if nearest == nil || distance < nearest!.0 { nearest = (distance, plan) }
        }
        if let nearest { return nearest.1 }
        let midX = fx > 0.30 && fx < 0.70
        let midY = fy > 0.30 && fy < 0.70
        if midY && fx < 0.28 { return horizontalHalf(id, left: true, in: area) }
        if midY && fx > 0.72 { return horizontalHalf(id, left: false, in: area) }
        if midX && fy < 0.28 { return verticalHalf(id, top: true, in: area) }
        if midX && fy > 0.72 { return verticalHalf(id, top: false, in: area) }
        return nil
    }

    /// `approach` for a selection. Two or more windows share the spot the way a
    /// committed drop would, so the guide and the landing are the same frames.
    static func approachGroup(_ ids: [UInt32], anchor: UInt32, at point: CGPoint, in area: CGRect,
                              occupied: [CGRect] = []) -> HyperspaceLayoutPlan? {
        guard let solo = approach(anchor, at: point, in: area, occupied: occupied), let region = solo.frames[anchor] else { return nil }
        guard ids.count >= 2, ids.contains(anchor) else { return solo }
        guard let packed = pack(ids, into: region) else { return nil }
        return .init(title: solo.title, frames: packed)
    }

    /// A 4×4 grid, each quarter split in half both ways. When the quarter under
    /// the pointer is partly filled, the largest open piece of that quarter is
    /// the landing. A fully open quarter stays on the preset map.
    private struct GridBlock {
        var c0: Int
        var r0: Int
        var dc: Int
        var dr: Int
    }

    private static func openSlot(_ id: UInt32, at point: CGPoint, in area: CGRect, occupied: [CGRect]) -> HyperspaceLayoutPlan? {
        guard let block = openPiece(at: point, in: area, occupied: occupied) else { return nil }
        let frame = slotRect(block, in: area)
        guard frame.width >= minimumSize.width, frame.height >= minimumSize.height else { return nil }
        return .init(title: slotTitle(block), frames: [id: frame])
    }

    private static func nearestOpenSlot(_ id: UInt32, at point: CGPoint, in area: CGRect, occupied: [CGRect]) -> HyperspaceLayoutPlan? {
        let reach = max(area.width, area.height) * 0.08
        var best: (CGFloat, HyperspaceLayoutPlan)?
        var seen = Set<String>()
        for row in 0..<4 {
            for column in 0..<4 {
                let raw = rawCell(column, row, in: area)
                let sample = CGPoint(x: raw.midX, y: raw.midY)
                guard let plan = openSlot(id, at: sample, in: area, occupied: occupied),
                      let frame = plan.frames[id] else { continue }
                let key = "\(plan.title) \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))"
                guard seen.insert(key).inserted else { continue }
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                let distance = hypot(dx, dy)
                guard distance > 0, distance <= reach else { continue }
                if best == nil || distance < best!.0 { best = (distance, plan) }
            }
        }
        return best?.1
    }

    /// Work up from the cell under the pointer. Stop when the next larger
    /// piece of its quarter is filled. Nil when that quarter is clear.
    private static func openPiece(at point: CGPoint, in area: CGRect, occupied: [CGRect]) -> GridBlock? {
        guard !occupied.isEmpty, area.width > 1, area.height > 1,
              let (column, row) = cellIndex(point, in: area) else { return nil }
        let cell = GridBlock(c0: column, r0: row, dc: 1, dr: 1)
        guard blockIsOpen(cell, in: area, occupied: occupied) else { return nil }
        let quarter = GridBlock(c0: (column / 2) * 2, r0: (row / 2) * 2, dc: 2, dr: 2)
        guard !blockIsOpen(quarter, in: area, occupied: occupied) else { return nil }
        return openHalf(of: quarter, around: cell, in: area, occupied: occupied) ?? cell
    }

    private static func openHalf(of quarter: GridBlock, around cell: GridBlock, in area: CGRect, occupied: [CGRect]) -> GridBlock? {
        let strips = [
            GridBlock(c0: cell.c0, r0: quarter.r0, dc: 1, dr: 2),
            GridBlock(c0: quarter.c0, r0: cell.r0, dc: 2, dr: 1),
        ]
        var best: (Int, GridBlock)?
        for strip in strips {
            guard blockIsOpen(strip, in: area, occupied: occupied) else { continue }
            let other = sibling(of: strip, in: quarter)
            let closed = closedCellCount(other, in: area, occupied: occupied)
            guard closed > 0 else { continue }
            if best == nil || closed > best!.0 { best = (closed, strip) }
        }
        return best?.1
    }

    private static func sibling(of strip: GridBlock, in quarter: GridBlock) -> GridBlock {
        if strip.dc == 1 {
            let column = strip.c0 == quarter.c0 ? quarter.c0 + 1 : quarter.c0
            return GridBlock(c0: column, r0: quarter.r0, dc: 1, dr: 2)
        }
        let row = strip.r0 == quarter.r0 ? quarter.r0 + 1 : quarter.r0
        return GridBlock(c0: quarter.c0, r0: row, dc: 2, dr: 1)
    }

    private static func blockIsOpen(_ block: GridBlock, in area: CGRect, occupied: [CGRect]) -> Bool {
        closedCellCount(block, in: area, occupied: occupied) == 0
    }

    private static func closedCellCount(_ block: GridBlock, in area: CGRect, occupied: [CGRect]) -> Int {
        var closed = 0
        for row in block.r0..<(block.r0 + block.dr) {
            for column in block.c0..<(block.c0 + block.dc) {
                if occupiedFraction(rawCell(column, row, in: area), occupied) >= 0.35 { closed += 1 }
            }
        }
        return closed
    }

    private static func occupiedFraction(_ rect: CGRect, _ windows: [CGRect]) -> CGFloat {
        let space = rect.width * rect.height
        guard space > 1 else { return 1 }
        var covered: CGFloat = 0
        for window in windows {
            let hit = rect.intersection(window)
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
            covered += hit.width * hit.height
        }
        return min(1, covered / space)
    }

    private static func cellIndex(_ point: CGPoint, in area: CGRect) -> (Int, Int)? {
        let (fx, fy) = unitPoint(point, in: area)
        return (min(3, max(0, Int(fx * 4))), min(3, max(0, Int(fy * 4))))
    }

    private static func rawCell(_ column: Int, _ row: Int, in area: CGRect) -> CGRect {
        CGRect(x: area.minX + area.width / 4 * CGFloat(column),
               y: area.minY + area.height / 4 * CGFloat(row),
               width: area.width / 4, height: area.height / 4)
    }

    private static func slotRect(_ block: GridBlock, in area: CGRect) -> CGRect {
        let span = CGFloat(4)
        let colWidth = (area.width - gap * (span - 1)) / span
        let rowHeight = (area.height - gap * (span - 1)) / span
        return CGRect(x: area.minX + CGFloat(block.c0) * (colWidth + gap),
                      y: area.minY + CGFloat(block.r0) * (rowHeight + gap),
                      width: colWidth * CGFloat(block.dc) + gap * CGFloat(max(0, block.dc - 1)),
                      height: rowHeight * CGFloat(block.dr) + gap * CGFloat(max(0, block.dr - 1))).integral
    }

    private static func slotTitle(_ block: GridBlock) -> String {
        let quarter = "\(block.r0 < 2 ? "Top" : "Bottom") \(block.c0 < 2 ? "left" : "right") quarter"
        if block.dc == 1 && block.dr == 2 { return "\(quarter), \(block.c0 % 2 == 0 ? "left" : "right") half" }
        if block.dc == 2 && block.dr == 1 { return "\(quarter), \(block.r0 % 2 == 0 ? "top" : "bottom") half" }
        let row = block.r0 % 2 == 0 ? "top" : "bottom"
        let column = block.c0 % 2 == 0 ? "left" : "right"
        return "\(quarter), \(row) \(column)"
    }

    private static func unitPoint(_ point: CGPoint, in area: CGRect) -> (CGFloat, CGFloat) {
        let fx = min(1, max(0, (point.x - area.minX) / max(area.width, 1)))
        let fy = min(1, max(0, (point.y - area.minY) / max(area.height, 1)))
        return (fx, fy)
    }

    /// The same landing as `drop`, shared by every selected window. A half or a
    /// quarter becomes the region. Two windows bisect it. More than two take
    /// equal slices along the region's longer side. Windows outside the
    /// selection stay where they are and only mark space as taken. A free move
    /// keeps the formation and carries every window by the same amount.
    static func dropGroup(_ ids: [UInt32], originals: [UInt32: CGRect], anchor: UInt32,
                          start: CGPoint, at point: CGPoint, in area: CGRect,
                          neighbors: [(UInt32, CGRect)]) -> HyperspaceLayoutPlan {
        let group = ids.filter { originals[$0] != nil }
        guard group.count >= 2, let original = originals[anchor] else {
            let frame = originals[anchor] ?? .zero
            return drop(anchor, original: frame, start: start, at: point, in: area, neighbors: neighbors)
        }
        let moving = Set(group)
        let obstacles = neighbors.filter { !moving.contains($0.0) }.map(\.1)
        let solo = drop(anchor, original: original, start: start, at: point, in: area,
                        neighbors: [], occupied: obstacles)
        if solo.title == "Move window" {
            return carried(group, originals: originals, start: start, at: point, in: area)
        }
        guard let region = solo.frames[anchor], let packed = pack(group, into: region) else { return solo }
        return .init(title: solo.title, frames: packed)
    }

    /// Equal frames inside `region`, first id at the top or the left.
    /// A taller region stacks. A wider region sits side by side.
    static func pack(_ ids: [UInt32], into region: CGRect) -> [UInt32: CGRect]? {
        guard !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        if ids.count == 1 {
            guard region.width >= minimumSize.width, region.height >= minimumSize.height else { return nil }
            return [ids[0]: region.integral]
        }
        let count = CGFloat(ids.count)
        if region.height >= region.width {
            let height = (region.height - gap * (count - 1)) / count
            guard height >= minimumSize.height, region.width >= minimumSize.width else { return nil }
            return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                (id, CGRect(x: region.minX, y: region.minY + CGFloat(index) * (height + gap),
                            width: region.width, height: height).integral)
            })
        }
        let width = (region.width - gap * (count - 1)) / count
        guard width >= minimumSize.width, region.height >= minimumSize.height else { return nil }
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: region.minX + CGFloat(index) * (width + gap), y: region.minY,
                        width: width, height: region.height).integral)
        })
    }

    private static func carried(_ ids: [UInt32], originals: [UInt32: CGRect], start: CGPoint,
                                at point: CGPoint, in area: CGRect) -> HyperspaceLayoutPlan {
        var dx = point.x - start.x
        var dy = point.y - start.y
        for id in ids {
            guard let frame = originals[id] else { continue }
            let width = min(frame.width, area.width)
            let height = min(frame.height, area.height)
            dx = min(max(dx, area.minX - frame.minX), area.maxX - width - frame.minX)
            dy = min(max(dy, area.minY - frame.minY), area.maxY - height - frame.minY)
        }
        var frames: [UInt32: CGRect] = [:]
        for id in ids {
            guard let frame = originals[id] else { continue }
            var moved = frame.offsetBy(dx: dx, dy: dy)
            moved.size.width = min(moved.width, area.width)
            moved.size.height = min(moved.height, area.height)
            frames[id] = moved.integral
        }
        return .init(title: "Move windows", frames: frames)
    }

    /// Overview landing. The picture the pointer is on decides the spot:
    /// the heart of a quartile is that quarter, the outer edge is a half,
    /// the band inside that edge is a third, and the middle follows the hand.
    /// `fraction` is that picture, in 0…1. Neighbors still share an edge.
    static func spot(_ id: UInt32, original: CGRect, start: CGPoint, at point: CGPoint,
                     in area: CGRect, neighbors: [(UInt32, CGRect)], fraction: CGPoint? = nil) -> HyperspaceLayoutPlan {
        if let shared = sharedEdge(id, at: point, neighbors: neighbors) { return shared }
        let resolved = fraction.map { (min(1, max(0, $0.x)), min(1, max(0, $0.y))) } ?? unitPoint(point, in: area)
        if let plan = zoned(id, fx: resolved.0, fy: resolved.1, in: area) { return plan }
        return moved(id, original: original, start: start, at: point, in: area)
    }

    /// Quartile centers and screen corners land as quarters. Edge middles land
    /// as halves. The inner edge, across the middle, lands as a third.
    private static func zoned(_ id: UInt32, fx: CGFloat, fy: CGFloat, in area: CGRect) -> HyperspaceLayoutPlan? {
        let midX = fx > 0.30 && fx < 0.70
        let midY = fy > 0.30 && fy < 0.70
        if fx < 0.18 && midY { return horizontalHalf(id, left: true, in: area) }
        if fx > 0.82 && midY { return horizontalHalf(id, left: false, in: area) }
        if fy < 0.18 && midX { return verticalHalf(id, top: true, in: area) }
        if fy > 0.82 && midX { return verticalHalf(id, top: false, in: area) }

        let qx: CGFloat = fx < 0.5 ? 0.25 : 0.75
        let qy: CGFloat = fy < 0.5 ? 0.25 : 0.75
        let heart = abs(fx - qx) <= 0.14 && abs(fy - qy) <= 0.14
        let corner = (fx < 0.18 || fx > 0.82) && (fy < 0.18 || fy > 0.82)
        if heart || corner {
            return quarter(id, left: fx < 0.5, top: fy < 0.5, in: area)
        }

        if fx < 0.34 && midY { return third(id, horizontal: true, leading: true, in: area) }
        if fx > 0.66 && midY { return third(id, horizontal: true, leading: false, in: area) }
        if fy < 0.34 && midX { return third(id, horizontal: false, leading: true, in: area) }
        if fy > 0.66 && midX { return third(id, horizontal: false, leading: false, in: area) }
        return nil
    }

    private static func quarter(_ id: UInt32, left: Bool, top: Bool, in area: CGRect) -> HyperspaceLayoutPlan? {
        let width = (area.width - gap) / 2, height = (area.height - gap) / 2
        guard width >= minimumSize.width, height >= minimumSize.height else { return nil }
        return .init(title: "\(top ? "Top" : "Bottom") \(left ? "left" : "right") quarter", frames: [id:
            CGRect(x: left ? area.minX : area.midX + gap / 2,
                   y: top ? area.minY : area.midY + gap / 2, width: width, height: height).integral])
    }

    private static func horizontalHalf(_ id: UInt32, left: Bool, in area: CGRect) -> HyperspaceLayoutPlan? {
        let width = (area.width - gap) / 2
        guard width >= minimumSize.width, area.height >= minimumSize.height else { return nil }
        return .init(title: left ? "Left half" : "Right half", frames: [id:
            CGRect(x: left ? area.minX : area.midX + gap / 2, y: area.minY,
                   width: width, height: area.height).integral])
    }

    private static func verticalHalf(_ id: UInt32, top: Bool, in area: CGRect) -> HyperspaceLayoutPlan? {
        let height = (area.height - gap) / 2
        guard height >= minimumSize.height, area.width >= minimumSize.width else { return nil }
        return .init(title: top ? "Top half" : "Bottom half", frames: [id:
            CGRect(x: area.minX, y: top ? area.minY : area.midY + gap / 2,
                   width: area.width, height: height).integral])
    }

    private static func third(_ id: UInt32, horizontal: Bool, leading: Bool, in area: CGRect) -> HyperspaceLayoutPlan? {
        if horizontal {
            let width = (area.width - gap * 2) / 3
            guard width >= minimumSize.width, area.height >= minimumSize.height else { return nil }
            return .init(title: leading ? "Left third" : "Right third", frames: [id:
                CGRect(x: leading ? area.minX : area.maxX - width, y: area.minY,
                       width: width, height: area.height).integral])
        }
        let height = (area.height - gap * 2) / 3
        guard height >= minimumSize.height, area.width >= minimumSize.width else { return nil }
        return .init(title: leading ? "Top third" : "Bottom third", frames: [id:
            CGRect(x: area.minX, y: leading ? area.minY : area.maxY - height,
                   width: area.width, height: height).integral])
    }

    private static func sharedEdge(_ id: UInt32, at point: CGPoint, neighbors: [(UInt32, CGRect)]) -> HyperspaceLayoutPlan? {
        guard let neighbor = neighbors.first(where: { $0.0 != id && $0.1.contains(point) }) else { return nil }
        let rect = neighbor.1
        guard rect.width > 1, rect.height > 1 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let horizontal = min(x, 1 - x) < min(y, 1 - y)
        let nearEdge = min(x, 1 - x, y, 1 - y) < 0.24
        let length = horizontal ? rect.width : rect.height
        let minimum = horizontal ? minimumSize.width : minimumSize.height
        guard nearEdge, (length - gap) / 2 >= minimum else { return nil }
        var first = rect
        var second = rect
        if horizontal {
            first.size.width = (rect.width - gap) / 2
            second.origin.x = first.maxX + gap
            second.size.width = first.width
        } else {
            first.size.height = (rect.height - gap) / 2
            second.origin.y = first.maxY + gap
            second.size.height = first.height
        }
        let sourceFirst = horizontal ? x < 0.5 : y < 0.5
        return .init(title: "Share space", frames: [id: (sourceFirst ? first : second).integral,
            neighbor.0: (sourceFirst ? second : first).integral])
    }

    private static func moved(_ id: UInt32, original: CGRect, start: CGPoint, at point: CGPoint, in area: CGRect) -> HyperspaceLayoutPlan {
        var frame = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return .init(title: "Move window", frames: [id: frame.integral])
    }

    struct Divider {
        let first: UInt32
        let second: UInt32
        let a: CGRect
        let b: CGRect
        let vertical: Bool
        var hitFrame: CGRect {
            vertical
                ? CGRect(x: (a.maxX + b.minX) / 2 - 7, y: a.minY, width: 14, height: a.height)
                : CGRect(x: a.minX, y: (a.maxY + b.minY) / 2 - 7, width: a.width, height: 14)
        }
        func plan(at point: CGPoint) -> HyperspaceLayoutPlan {
            var firstFrame = a
            var secondFrame = b
            if vertical {
                let x = min(max(point.x, a.minX + minimumSize.width + gap / 2), b.maxX - minimumSize.width - gap / 2)
                firstFrame.size.width = x - gap / 2 - a.minX
                secondFrame.origin.x = x + gap / 2
                secondFrame.size.width = b.maxX - secondFrame.minX
            } else {
                let y = min(max(point.y, a.minY + minimumSize.height + gap / 2), b.maxY - minimumSize.height - gap / 2)
                firstFrame.size.height = y - gap / 2 - a.minY
                secondFrame.origin.y = y + gap / 2
                secondFrame.size.height = b.maxY - secondFrame.minY
            }
            return .init(title: "Resize together", frames: [first: firstFrame.integral, second: secondFrame.integral])
        }
    }

    /// The same arrangement with a new window order. Named proposals rebuild.
    /// A free move or a shared edge has no pattern to rebuild, so the caller
    /// keeps those frames and exchanges the two slots itself.
    static func reflow(_ plan: HyperspaceLayoutPlan, ids: [UInt32], in area: CGRect) -> HyperspaceLayoutPlan? {
        guard !ids.isEmpty, Set(ids) == Set(plan.frames.keys) else { return nil }
        let next: HyperspaceLayoutPlan?
        if plan.title == "Rows" {
            next = rows(ids, in: area)
        } else if plan.title == "Main left" {
            next = mainAndCompanions(ids, in: area, leading: true)
        } else if plan.title == "Main right" {
            next = mainAndCompanions(ids, in: area, leading: false)
        } else if plan.title == "Balanced grid" {
            next = grid(ids, in: area)
        } else if plan.title.contains("column") || plan.title == "Fill display" {
            next = columns(ids, in: area)
        } else {
            next = nil
        }
        guard let next, Set(next.frames.keys) == Set(ids) else { return nil }
        return next
    }

    /// The other slot under `point`, in the same coordinate space as `slots`.
    /// The pointer may sit in the gap beside a slot. The dragged window's own
    /// slot is never a landing.
    static func landingSlot(_ id: UInt32, at point: CGPoint, slots: [UInt32: CGRect]) -> UInt32? {
        guard slots.count > 1 else { return nil }
        var best: (UInt32, CGFloat)?
        for (other, rect) in slots where other != id && rect.width > 0 && rect.height > 0 {
            let padX = max(rect.width * 0.015, 0)
            let padY = max(rect.height * 0.015, 0)
            let hit = rect.insetBy(dx: -padX, dy: -padY)
            let dx = max(hit.minX - point.x, 0, point.x - hit.maxX)
            let dy = max(hit.minY - point.y, 0, point.y - hit.maxY)
            let outside = hypot(dx, dy)
            let limit = max(rect.width, rect.height) * 0.08
            guard outside == 0 || outside < limit else { continue }
            let center = hypot(point.x - rect.midX, point.y - rect.midY)
            let score = outside == 0 ? center : outside + 10_000
            if best == nil || score < best!.1 { best = (other, score) }
        }
        return best?.0
    }

    static func dividers(_ windows: [(UInt32, CGRect)]) -> [Divider] {
        var result: [Divider] = []
        for first in windows {
            for second in windows where first.0 != second.0 {
                let a = first.1, b = second.1
                if abs(a.maxX + gap - b.minX) <= 3,
                   abs(a.minY - b.minY) <= 3, abs(a.maxY - b.maxY) <= 3,
                   a.width + b.width >= minimumSize.width * 2 {
                    result.append(.init(first: first.0, second: second.0, a: a, b: b, vertical: true))
                } else if abs(a.maxY + gap - b.minY) <= 3,
                          abs(a.minX - b.minX) <= 3, abs(a.maxX - b.maxX) <= 3,
                          a.height + b.height >= minimumSize.height * 2 {
                    result.append(.init(first: first.0, second: second.0, a: a, b: b, vertical: false))
                }
            }
        }
        return result
    }
}
