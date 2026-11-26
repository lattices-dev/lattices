import CoreGraphics
import Foundation

struct HyperspaceSketchRegion: Equatable {
    let bounds: CGRect
    let ids: [UInt32]
}

extension HyperspaceLayoutPlanner {
    /// Recognize an existing stack of windows when the stroke spans its width
    /// (or a row when the stroke spans its height), including after Apply.
    private static func existingStack(for first: CGPoint, through last: CGPoint, vertical: Bool,
                                      ids: [UInt32], frames: [UInt32: CGRect]) -> HyperspaceSketchRegion? {
        let alongStart = vertical ? \CGRect.minY : \CGRect.minX
        let alongEnd = vertical ? \CGRect.maxY : \CGRect.maxX
        let crossStart = vertical ? \CGRect.minX : \CGRect.minY
        let crossEnd = vertical ? \CGRect.maxX : \CGRect.maxY
        let from = vertical ? first.y : first.x, to = vertical ? last.y : last.x
        let cross = vertical ? (first.x + last.x) / 2 : (first.y + last.y) / 2
        guard let anchor = ids.compactMap({ frames[$0] }).first(where: {
            $0[keyPath: crossStart] - 6 <= cross && $0[keyPath: crossEnd] + 6 >= cross
                && min(from, to) >= $0[keyPath: alongStart] - 12 && max(from, to) <= $0[keyPath: alongEnd] + 12
                && abs(to - from) >= 0.55 * ($0[keyPath: alongEnd] - $0[keyPath: alongStart])
        }) else { return nil }
        let stack = ids.filter {
            guard let f = frames[$0] else { return false }
            return abs(f[keyPath: alongStart] - anchor[keyPath: alongStart]) <= 2
                && abs(f[keyPath: alongEnd] - anchor[keyPath: alongEnd]) <= 2
        }.sorted { frames[$0]![keyPath: crossStart] < frames[$1]![keyPath: crossStart] }
        guard stack.count >= 2, stack.count < ids.count,
              zip(stack, stack.dropFirst()).allSatisfy({
                  (0...12).contains(frames[$1]![keyPath: crossStart] - frames[$0]![keyPath: crossEnd])
              }) else { return nil }
        return .init(bounds: stack.reduce(CGRect.null) { $0.union(frames[$1]!) }, ids: stack)
    }

    /// Every sample of a stroke is interpreted against the layout at mouse-down.
    static func sketch(_ points: [CGPoint], ids: [UInt32], frames: [UInt32: CGRect],
                       in area: CGRect, prior: HyperspaceLayoutPlan?) -> HyperspaceLayoutPlan? {
        guard ids.count >= 2, ids.allSatisfy({ frames[$0] != nil }),
              let first = points.first, let last = points.last else { return nil }
        let dx = abs(last.x - first.x), dy = abs(last.y - first.y)
        let vertical = dy > dx
        let length = max(dx, dy)
        let travel = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
            $0 + abs(vertical ? $1.1.y - $1.0.y : $1.1.x - $1.0.x)
        }
        guard travel <= length * 1.35 else { return nil }
        let across = points.map { vertical ? $0.x : $0.y }
        guard let low = across.min(), let high = across.max(),
              length >= 48, high - low <= max(12, length * 0.18) else { return nil }
        let cut = ((high + low) / 2).rounded()
        let midpoint = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        let root = HyperspaceSketchRegion(bounds: area, ids: ids)
        let saved = prior?.sketchRegions ?? []
        let regions = Set(saved.flatMap(\.ids)) == Set(ids) ? saved : []
        let local = regions.filter {
            $0.ids.count < ids.count && $0.bounds.insetBy(dx: -6, dy: -6).contains(midpoint)
            && $0.bounds.insetBy(dx: -18, dy: -18).contains(first)
            && $0.bounds.insetBy(dx: -18, dy: -18).contains(last)
        }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            ?? existingStack(for: first, through: last, vertical: vertical, ids: ids, frames: frames)
        let region = local ?? root
        let bounds = region.bounds
        guard bounds.contains(midpoint), region.ids.count >= 2,
              length >= min(160, (vertical ? bounds.height : bounds.width) * 0.4) else { return nil }
        let axis = vertical ? CGRectEdge.minXEdge : .minYEdge
        let depth = cut - (vertical ? bounds.minX : bounds.minY) - gap / 2
        guard depth > 0, depth + gap < (vertical ? bounds.width : bounds.height) else { return nil }
        let (a, rest) = bounds.divided(atDistance: depth, from: axis)
        let b = rest.divided(atDistance: gap, from: axis).remainder
        let sorted = region.ids.sorted {
            let lhs = frames[$0]!, rhs = frames[$1]!
            let l = vertical ? lhs.midX : lhs.midY, r = vertical ? rhs.midX : rhs.midY
            return l == r ? $0 < $1 : l < r
        }
        let count = sorted.prefix { vertical ? frames[$0]!.midX < cut : frames[$0]!.midY < cut }.count
        let partition = min(sorted.count - 1, max(1, count))
        func order(_ slice: ArraySlice<UInt32>) -> [UInt32] {
            slice.sorted {
                let lhs = frames[$0]!, rhs = frames[$1]!
                let l = vertical ? lhs.midY : lhs.midX, r = vertical ? rhs.midY : rhs.midX
                return l == r ? $0 < $1 : l < r
            }
        }
        let left = order(sorted.prefix(partition)), right = order(sorted.dropFirst(partition))
        let layout = vertical ? rows : columns
        guard let leading = layout(left, a), let trailing = layout(right, b) else { return nil }
        var next = prior?.frames ?? [:]
        next.merge(leading.frames) { _, new in new }
        next.merge(trailing.frames) { _, new in new }
        let affected = Set(region.ids)
        var retained = [root] + regions.filter { $0.ids.count < ids.count && !Set($0.ids).isSubset(of: affected) }
        if let local { retained.append(local) }
        return .init(title: vertical ? "Vertical split" : "Horizontal split", frames: next,
                     sketchRegions: retained + [.init(bounds: a, ids: left), .init(bounds: b, ids: right)])
    }

    /// Keep a pin at its exact staged or desktop frame. For presets that would
    /// cross it, tile the remaining windows in the unoccupied rectangles.
    static func respectingPins(_ plan: HyperspaceLayoutPlan, pins: [UInt32: CGRect],
                               in area: CGRect) -> HyperspaceLayoutPlan? {
        guard !pins.isEmpty else { return plan }
        let movable = plan.frames.filter { pins[$0.key] == nil }
        var result = plan
        result.frames.merge(pins) { _, pinned in pinned }
        if movable.values.allSatisfy({ frame in pins.values.allSatisfy { frame.intersection($0).isEmpty } }) {
            if result.frames != plan.frames {
                let displaced = pins.contains { id, frame in plan.frames[id].map { $0 != frame } ?? false }
                guard !displaced || isArrangement(plan.title) else { return nil }
                result.tileGroup = nil
                result.sketchRegions = []
            }
            return result
        }
        guard isArrangement(plan.title) else { return nil }
        var regions = [area]
        for (_, pin) in pins.sorted(by: { $0.key < $1.key }) {
            regions = regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(pin.insetBy(dx: -gap, dy: -gap))
                guard !cut.isEmpty else { return [region] }
                // Leave full-height side regions for a column of companions.
                let (left, rest) = region.divided(atDistance: cut.minX - region.minX, from: .minXEdge)
                let (center, right) = rest.divided(atDistance: cut.width, from: .minXEdge)
                let above = center.divided(atDistance: cut.minY - center.minY, from: .minYEdge).slice
                let below = center.divided(atDistance: center.maxY - cut.maxY, from: .maxYEdge).slice
                return [left, right, above, below].filter { $0.width >= minimumSize.width && $0.height >= minimumSize.height }
            }
        }
        let ordered = movable.sorted {
            if $0.value.minY != $1.value.minY { return $0.value.minY < $1.value.minY }
            if $0.value.minX != $1.value.minX { return $0.value.minX < $1.value.minX }
            return $0.key < $1.key
        }.map(\.key)
        var remaining = ordered[...]
        var placed = pins
        for region in regions.sorted(by: { $0.width * $0.height > $1.width * $1.height }) where !remaining.isEmpty {
            for count in stride(from: remaining.count, through: 1, by: -1) {
                let options = arrangements(Array(remaining.prefix(count)), in: region)
                guard let next = options.first(where: { $0.title == plan.title }) ?? options.first else { continue }
                placed.merge(next.frames) { _, new in new }
                remaining = remaining.dropFirst(count)
                break
            }
        }
        guard remaining.isEmpty else { return nil }
        return .init(title: plan.title, frames: placed)
    }
}
