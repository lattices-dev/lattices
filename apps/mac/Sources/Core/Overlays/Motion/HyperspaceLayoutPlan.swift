import CoreGraphics
import Foundation

/// Desktop geometry uses AX's top-left coordinates. A plan is pure data until
/// MotionPanel resolves every window and applies the whole change.
struct HyperspaceLayoutPlan: Equatable {
    var title: String
    var frames: [UInt32: CGRect]
    var tileGroup: HyperspaceTileGroup? = nil
    var sketchRegions: [HyperspaceSketchRegion] = []
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

    /// On the live Hyperspace canvas, the center of an occupied tile exchanges
    /// its occupant with the dragged window. An edge can split the tile if both halves fit.
    static func desktopDrop(_ id: UInt32, original: CGRect, start: CGPoint, at point: CGPoint,
                            in area: CGRect, neighbors: [(UInt32, CGRect)]) -> HyperspaceLayoutPlan {
        let drag = DesktopDrop(id: id, original: original, start: start, area: area, neighbors: neighbors)
        return drag.plan(at: point)
    }

    /// Capture the layout once on mouse-down. Every preview and the final mouse-up use this baseline.
    final class DesktopDrop {
        private var heldEdge: (neighbor: UInt32, edge: LandingEdge)?
        private var centerNeighbor: UInt32?
        let id: UInt32
        let original: CGRect
        let start: CGPoint
        let area: CGRect
        let neighbors: [(UInt32, CGRect)]
        let group: HyperspaceTileGroup?

        init(id: UInt32, original: CGRect, start: CGPoint, area: CGRect, neighbors: [(UInt32, CGRect)],
             prior: HyperspaceLayoutPlan? = nil) {
            self.id = id
            self.original = original
            self.start = start
            self.area = area
            // Landing plates paint in ascending ID order, above desktop windows in native z-order.
            let staged = neighbors.filter { prior?.frames[$0.0] != nil }.sorted { $0.0 > $1.0 }
            self.neighbors = staged + neighbors.filter { prior?.frames[$0.0] == nil }
            let live = Dictionary([(id, original)] + neighbors, uniquingKeysWith: { first, _ in first })
            if let saved = prior?.tileGroup, saved.frames[id] != nil,
               saved.frames.allSatisfy({ live[$0.key] == $0.value }) {
                group = saved
            } else {
                let candidates = prior?.frames[id] == nil ? live : live.filter { prior?.frames[$0.key] != nil }
                group = HyperspaceTileGroup(containing: id, frames: candidates, in: area)
            }
        }

        func plan(at point: CGPoint) -> HyperspaceLayoutPlan {
            occupiedLanding(at: point) ?? drop(id, original: original, start: start, at: point, in: area, neighbors: neighbors)
        }

        func occupiedLanding(at point: CGPoint) -> HyperspaceLayoutPlan? {
            if let (neighbor, frame) = neighbors.first(where: { $0.0 != id && $0.1.contains(point) }),
               original.intersection(frame).isEmpty,
               [original, frame].allSatisfy({ $0.width >= minimumSize.width && $0.height >= minimumSize.height
                   && area.insetBy(dx: -3, dy: -3).contains($0) }) {
                let candidate = landingEdge(at: point, in: frame)
                let edge: LandingEdge?
                if let held = heldEdge, held.neighbor == neighbor,
                   held.edge.depth(at: point, in: frame) <= 0.24 * (held.edge.horizontal ? frame.width : frame.height) + 12 {
                    edge = held.edge
                } else if let candidate, centerNeighbor == neighbor,
                          candidate.depth(at: point, in: frame) > 0.24 * (candidate.horizontal ? frame.width : frame.height) - 12 {
                    edge = nil
                } else { edge = candidate }
                centerNeighbor = edge == nil ? neighbor : nil
                heldEdge = edge.map { (neighbor, $0) }
                if let edge {
                    if let reflow = group?.inserting(id, beside: neighbor, edge: edge) { return reflow }
                    if let split = splitTile(id, neighbor: neighbor, frame: frame, edge: edge) { return split }
                }
                return .init(title: "Swap windows", frames: [id: frame, neighbor: original],
                             tileGroup: group?.swapping(id, neighbor))
            }
            heldEdge = nil
            centerNeighbor = nil
            return nil
        }
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
        guard let edge = landingEdge(at: point, in: neighbor.1) else { return nil }
        return splitTile(id, neighbor: neighbor.0, frame: neighbor.1, edge: edge)
    }

    struct LandingEdge {
        let horizontal: Bool
        let sourceFirst: Bool

        func depth(at point: CGPoint, in frame: CGRect) -> CGFloat {
            if horizontal { return sourceFirst ? point.x - frame.minX : frame.maxX - point.x }
            return sourceFirst ? point.y - frame.minY : frame.maxY - point.y
        }
    }

    private static func landingEdge(at point: CGPoint, in rect: CGRect) -> LandingEdge? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let horizontal = min(x, 1 - x) < min(y, 1 - y)
        guard min(x, 1 - x, y, 1 - y) < 0.24 else { return nil }
        return LandingEdge(horizontal: horizontal, sourceFirst: horizontal ? x < 0.5 : y < 0.5)
    }

    private static func splitTile(_ id: UInt32, neighbor: UInt32, frame rect: CGRect,
                                  edge: LandingEdge) -> HyperspaceLayoutPlan? {
        let horizontal = edge.horizontal
        let length = horizontal ? rect.width : rect.height
        let minimum = horizontal ? minimumSize.width : minimumSize.height
        guard (length - gap) / 2 >= minimum else { return nil }
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
        return .init(title: "Share space", frames: [id: (edge.sourceFirst ? first : second).integral,
            neighbor: (edge.sourceFirst ? second : first).integral])
    }

    private static func moved(_ id: UInt32, original: CGRect, start: CGPoint, at point: CGPoint, in area: CGRect) -> HyperspaceLayoutPlan {
        var frame = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return .init(title: "Move window", frames: [id: frame.integral])
    }

    // In divider coordinates x runs across the seam and y along it.
    private static func oriented(_ rect: CGRect, vertical: Bool) -> CGRect {
        vertical ? rect : CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
    }

    struct Divider: Equatable {
        static let grabRadius: CGFloat = 36
        let vertical: Bool
        fileprivate let coordinate: CGFloat
        fileprivate var span: ClosedRange<CGFloat>
        fileprivate var contacts: [ClosedRange<CGFloat>]
        fileprivate var leading: [UInt32: CGRect]
        fileprivate var trailing: [UInt32: CGRect]

        func touches(_ wid: UInt32) -> Bool { leading[wid] != nil || trailing[wid] != nil }

        var affectedFrames: [CGRect] {
            (Array(leading.values) + trailing.values).map { oriented($0, vertical: vertical) }
        }

        func snapTargets(alongside others: [Divider]) -> [CGFloat] {
            let low = leading.values.map(\.minX).min()!, high = trailing.values.map(\.maxX).max()!
            let ratios: [CGFloat] = [1 / 3, 0.5, 2 / 3]
            let adjacent = others.filter {
                $0.vertical == vertical && abs($0.coordinate - coordinate) > 2
                    && min(abs($0.span.lowerBound - span.upperBound), abs(span.lowerBound - $0.span.upperBound)) <= 12
            }
            return (adjacent.map(\.coordinate) + ratios.map { (low + (high - low) * $0).rounded() })
                .filter { $0 >= coordinate + lowerLimit && $0 <= coordinate + upperLimit }
        }

        func snapped(at point: CGPoint, from start: CGPoint, targets: [CGFloat], held: CGFloat?)
            -> (plan: HyperspaceLayoutPlan, snap: CGFloat?) {
            let desired = coordinate + (vertical ? point.x - start.x : point.y - start.y)
            let nearest = targets.min { abs($0 - desired) < abs($1 - desired) }
            let snap = held.flatMap { abs($0 - desired) <= 16 ? $0 : nil }
                ?? nearest.flatMap { abs($0 - desired) <= 8 ? $0 : nil }
            let target = snap ?? desired
            return (plan(at: CGPoint(x: target, y: target)), snap)
        }

        func distance(to point: CGPoint) -> CGFloat {
            abs((vertical ? point.x : point.y) - coordinate)
        }

        var hitFrame: CGRect {
            oriented(CGRect(x: coordinate - Self.grabRadius, y: span.lowerBound, width: Self.grabRadius * 2,
                            height: span.upperBound - span.lowerBound), vertical: vertical)
        }

        /// A joined seam may span a gutter or pass behind a floating window.
        /// Put its one grip entirely inside the longest exposed contact.
        var handleFrame: CGRect {
            let run = contacts.max { a, b in
                let lhs = a.upperBound - a.lowerBound, rhs = b.upperBound - b.lowerBound
                return lhs == rhs ? a.lowerBound > b.lowerBound : lhs < rhs
            }!
            let length = min(48, run.upperBound - run.lowerBound)
            let middle = (run.upperBound + run.lowerBound) / 2
            return oriented(CGRect(x: coordinate - 2, y: middle - length / 2, width: 4, height: length),
                            vertical: vertical)
        }

        func warmth(at point: CGPoint) -> CGFloat {
            max(0, 1 - distance(to: point) / Self.grabRadius)
        }

        /// Put the grip under the approaching hand, keeping both ends inside one exposed run.
        func handleFrame(near point: CGPoint) -> CGRect {
            let along = vertical ? point.y : point.x
            func separation(_ run: ClosedRange<CGFloat>) -> CGFloat {
                max(run.lowerBound - along, along - run.upperBound, 0)
            }
            guard let run = contacts.min(by: { separation($0) < separation($1) }) else { return handleFrame }
            let heat = warmth(at: point)
            let length = min(48 + 32 * heat, run.upperBound - run.lowerBound)
            let width = 4 + 6 * heat
            let start = min(max(along - length / 2, run.lowerBound), run.upperBound - length)
            return oriented(CGRect(x: coordinate - width / 2, y: start, width: width, height: length), vertical: vertical)
        }

        func contains(_ point: CGPoint) -> Bool {
            guard hitFrame.contains(point) else { return false }
            let along = vertical ? point.y : point.x
            if contacts.contains(where: { $0.contains(along) }) { return true }
            // The small gutter at a four-way junction belongs to the continuous
            // seam too. A covered stretch within a window's edge does not.
            return !leading.values.contains { $0.minY <= along && along <= $0.maxY }
                && !trailing.values.contains { $0.minY <= along && along <= $0.maxY }
        }

        fileprivate var minimumExtent: CGFloat { vertical ? minimumSize.width : minimumSize.height }
        fileprivate var lowerLimit: CGFloat { leading.values.map { minimumExtent - $0.width }.max()! }
        fileprivate var upperLimit: CGFloat { trailing.values.map { $0.width - minimumExtent }.min()! }

        func plan(at point: CGPoint, from start: CGPoint? = nil) -> HyperspaceLayoutPlan {
            let origin = start.map { vertical ? $0.x : $0.y } ?? coordinate
            let delta = min(max(((vertical ? point.x : point.y) - origin).rounded(), lowerLimit), upperLimit)
            var frames = leading.mapValues { frame in
                oriented(CGRect(x: frame.minX, y: frame.minY, width: frame.width + delta,
                                height: frame.height), vertical: vertical)
            }
            for (id, frame) in trailing {
                frames[id] = oriented(CGRect(x: frame.minX + delta, y: frame.minY,
                    width: frame.width - delta, height: frame.height), vertical: vertical)
            }
            return .init(title: "Resize together", frames: frames)
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

    /// Front-to-back paint order. A surface without a resize target still covers edges behind it.
    struct DividerSurface: Equatable {
        let target: UInt32?
        let frame: CGRect
    }

    static func dividers(_ windows: [(UInt32, CGRect)]) -> [Divider] {
        dividers(surfaces: windows.map { DividerSurface(target: $0.0, frame: $0.1) }, in: .infinite)
    }

    private static func subtract(_ cover: Range<CGFloat>, from runs: [Range<CGFloat>]) -> [Range<CGFloat>] {
        runs.flatMap { run -> [Range<CGFloat>] in
            guard run.overlaps(cover) else { return [run] }
            var parts: [Range<CGFloat>] = []
            if run.lowerBound < cover.lowerBound { parts.append(run.lowerBound..<cover.lowerBound) }
            if cover.upperBound < run.upperBound { parts.append(cover.upperBound..<run.upperBound) }
            return parts
        }
    }

    static func dividers(surfaces: [DividerSurface], in viewport: CGRect) -> [Divider] {
        let gutter: CGFloat = 12
        var result: [Divider] = []
        for vertical in [true, false] {
            let tiles = surfaces.map { oriented($0.frame, vertical: vertical) }
            let bounds = oriented(viewport, vertical: vertical)
            var seams: [Divider] = []
            for (i, left) in tiles.enumerated() {
                guard let leftID = surfaces[i].target else { continue }
                for (j, right) in tiles.enumerated() {
                    guard let rightID = surfaces[j].target, leftID != rightID else { continue }
                    let spacing = right.minX - left.maxX
                    let low = max(left.minY, right.minY, bounds.minY), high = min(left.maxY, right.maxY, bounds.maxY)
                    let center = left.maxX + spacing / 2
                    guard (0...gutter).contains(spacing), high - low >= 24,
                          center - 2 >= bounds.minX, center + 2 <= bounds.maxX else { continue }
                    var runs = [low..<high]
                    for k in 0..<max(i, j) where k != i && k != j {
                        let cover = tiles[k]
                        let hidesLeft = k < i && cover.maxX > left.maxX - 2 && cover.minX < center + 2
                        let hidesRight = k < j && cover.minX < right.minX + 2 && cover.maxX > center - 2
                        if hidesLeft || hidesRight {
                            runs = subtract(cover.minY..<cover.maxY, from: runs)
                            if runs.isEmpty { break }
                        }
                    }
                    let contacts = runs.filter { $0.upperBound - $0.lowerBound >= 24 }
                        .map { $0.lowerBound...$0.upperBound }
                    guard let first = contacts.first, let last = contacts.last else { continue }
                    var seam = Divider(vertical: vertical, coordinate: center, span: first.lowerBound...last.upperBound,
                                       contacts: contacts, leading: [leftID: left], trailing: [rightID: right])
                    // A new segment may connect two previously separate runs.
                    for index in seams.indices.reversed() {
                        let other = seams[index]
                        guard abs(center - other.coordinate) <= 2,
                              other.span.lowerBound <= seam.span.upperBound + gutter, seam.span.lowerBound <= other.span.upperBound + gutter else { continue }
                        seam.span = min(seam.span.lowerBound, other.span.lowerBound)...max(seam.span.upperBound, other.span.upperBound)
                        seam.contacts.append(contentsOf: other.contacts)
                        seam.leading.merge(other.leading) { existing, _ in existing }
                        seam.trailing.merge(other.trailing) { existing, _ in existing }
                        seams.remove(at: index)
                    }
                    seams.append(seam)
                }
            }
            result += seams.filter { seam in
                func unstacked(_ side: [UInt32: CGRect]) -> Bool {
                    let ordered = side.values.sorted { $0.minY < $1.minY }
                    return zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 1 }
                }
                return seam.lowerLimit < seam.upperLimit && unstacked(seam.leading) && unstacked(seam.trailing)
            }
        }
        return result
    }
}

/// A rectangular group of adjoining tiles. Split weights belong to slots so collapsing
/// a branch gives its space to its siblings without disturbing an enclosing split.
struct HyperspaceTileGroup: Equatable {
    private indirect enum Node: Equatable {
        case window(UInt32)
        case split(horizontal: Bool, gutter: CGFloat, children: [Branch])

        func editingLeaves(_ edit: (UInt32) -> Node?) -> Node? {
            switch self {
            case .window(let id):
                return edit(id)
            case let .split(horizontal, gutter, children):
                let edited = children.compactMap { child in
                    child.node.editingLeaves(edit).map { Branch(weight: child.weight, node: $0) }
                }
                if edited.count <= 1 { return edited.first?.node }
                return .split(horizontal: horizontal, gutter: gutter, children: edited)
            }
        }

        func place(in rect: CGRect, into frames: inout [UInt32: CGRect]) -> Bool {
            switch self {
            case .window(let id):
                let minimum = HyperspaceLayoutPlanner.minimumSize
                guard rect.width >= minimum.width, rect.height >= minimum.height else { return false }
                frames[id] = rect
            case let .split(horizontal, gutter, children):
                let start = horizontal ? rect.minX : rect.minY
                let extent = horizontal ? rect.width : rect.height
                let available = extent - gutter * CGFloat(children.count - 1)
                let total = children.reduce(0) { $0 + $1.weight }
                var offset = start
                var weight: CGFloat = 0
                for (index, child) in children.enumerated() {
                    weight += child.weight
                    let end = index == children.count - 1 ? start + extent
                        : (start + available * weight / total + CGFloat(index) * gutter).rounded()
                    var tile = rect
                    if horizontal {
                        tile.origin.x = offset
                        tile.size.width = end - offset
                    } else {
                        tile.origin.y = offset
                        tile.size.height = end - offset
                    }
                    guard child.node.place(in: tile, into: &frames) else { return false }
                    offset = end + gutter
                }
            }
            return true
        }
    }

    private struct Branch: Equatable {
        let weight: CGFloat
        let node: Node
    }

    private let root: Node
    private let bounds: CGRect
    let frames: [UInt32: CGRect]

    private init(root: Node, bounds: CGRect, frames: [UInt32: CGRect]) {
        self.root = root
        self.bounds = bounds
        self.frames = frames
    }

    init?(containing source: UInt32, frames: [UInt32: CGRect], in area: CGRect) {
        let valid = frames.filter { !$0.value.isEmpty && area.insetBy(dx: -3, dy: -3).contains($0.value) }
        guard let first = valid[source] else { return nil }
        var component = [source: first]
        var pending = [first]
        while let next = pending.popLast() {
            for (id, frame) in valid where component[id] == nil && Self.adjoins(next, frame) {
                component[id] = frame
                pending.append(frame)
            }
        }
        guard component.count > 1 else { return nil }
        let bounds = component.values.reduce(CGRect.null) { $0.union($1) }
        guard let root = Self.partition(Array(component), in: bounds) else { return nil }
        self.init(root: root, bounds: bounds, frames: component)
    }

    private static let maxGutter: CGFloat = 12

    private static func adjoins(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        let dy = max(a.minY, b.minY) - min(a.maxY, b.maxY)
        return ((0...maxGutter).contains(dx) && dy <= -24) || ((0...maxGutter).contains(dy) && dx <= -24)
    }

    /// Cut at full-width or full-height seams. Each child has to fill its band,
    /// which rejects overlapping windows and L-shaped collections with empty space.
    private static func partition(_ tiles: [(key: UInt32, value: CGRect)], in bounds: CGRect) -> Node? {
        if tiles.count == 1 { return .window(tiles[0].key) }
        for horizontal in [false, true] {
            let start = horizontal ? \CGRect.minX : \CGRect.minY
            let end = horizontal ? \CGRect.maxX : \CGRect.maxY
            let sorted = tiles.sorted { $0.value[keyPath: start] < $1.value[keyPath: start] }
            var bands: [[(key: UInt32, value: CGRect)]] = []
            var limit = -CGFloat.infinity
            for tile in sorted {
                if tile.value[keyPath: start] >= limit { bands.append([]) }
                bands[bands.count - 1].append(tile)
                limit = max(limit, tile.value[keyPath: end])
            }
            guard bands.count > 1 else { continue }
            var children: [Branch] = []
            var previousEnd = bounds[keyPath: start]
            var gutters: [CGFloat] = []
            for band in bands {
                let rect = band.reduce(CGRect.null) { $0.union($1.value) }
                let fillsBand = horizontal
                    ? abs(rect.minY - bounds.minY) <= 1 && abs(rect.maxY - bounds.maxY) <= 1
                    : abs(rect.minX - bounds.minX) <= 1 && abs(rect.maxX - bounds.maxX) <= 1
                let space = rect[keyPath: start] - previousEnd
                guard fillsBand, space <= maxGutter, let node = partition(band, in: rect) else { break }
                if !children.isEmpty { gutters.append(space) }
                children.append(Branch(weight: horizontal ? rect.width : rect.height, node: node))
                previousEnd = rect[keyPath: end]
            }
            if children.count == bands.count {
                let gutter = (gutters.reduce(0, +) / CGFloat(gutters.count)).rounded()
                return .split(horizontal: horizontal, gutter: gutter, children: children)
            }
        }
        return nil
    }

    func inserting(_ source: UInt32, beside target: UInt32, edge: HyperspaceLayoutPlanner.LandingEdge) -> HyperspaceLayoutPlan? {
        guard source != target, frames[source] != nil, frames[target] != nil else { return nil }
        let ids = edge.sourceFirst ? [source, target] : [target, source]
        let pair = Node.split(horizontal: edge.horizontal, gutter: HyperspaceLayoutPlanner.gap,
                              children: ids.map { Branch(weight: 1, node: .window($0)) })
        guard let updated = root.editingLeaves({ id in
            if id == source { return nil }
            return id == target ? pair : .window(id)
        }) else { return nil }
        var next: [UInt32: CGRect] = [:]
        guard updated.place(in: bounds, into: &next) else { return nil }
        let changed = next.filter { $0.key == source || $0.key == target || $0.value != frames[$0.key] }
        return .init(title: "Share space", frames: changed, tileGroup: .init(root: updated, bounds: bounds, frames: next))
    }

    func swapping(_ a: UInt32, _ b: UInt32) -> Self? {
        guard let first = frames[a], let second = frames[b],
              let updated = root.editingLeaves({ .window($0 == a ? b : ($0 == b ? a : $0)) }) else { return nil }
        var next = frames
        next[a] = second
        next[b] = first
        return .init(root: updated, bounds: bounds, frames: next)
    }
}
