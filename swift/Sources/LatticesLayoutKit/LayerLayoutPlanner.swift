import CoreGraphics

/// Plans layer layouts from immutable window and display facts. Reading the
/// desktop, classifying apps, and applying the result belong to the caller.
public enum LayerLayoutPlanner {
    public enum Kind: Equatable {
        case auto, columns, masterStack
    }

    public enum Lane: CaseIterable {
        case left, middle, right
    }

    public struct Candidate {
        public let windowID: UInt32
        public let frame: CGRect
        public let spaceIDs: [Int]
        public let isPlaced: Bool
        public let hasTitle: Bool
        public let lane: Lane

        public init(windowID: UInt32, frame: CGRect, spaceIDs: [Int],
                    isPlaced: Bool, hasTitle: Bool, lane: Lane) {
            self.windowID = windowID
            self.frame = frame
            self.spaceIDs = spaceIDs
            self.isPlaced = isPlaced
            self.hasTitle = hasTitle
            self.lane = lane
        }
    }

    public struct Context {
        public let mainBounds: CGRect
        public let otherDisplayBounds: [CGRect]
        public let currentSpaceID: Int
        public let visibleFrame: CGRect
        public let excludedWindowIDs: Set<UInt32>
        public let standardWindowIDs: Set<UInt32>

        public init(mainBounds: CGRect, otherDisplayBounds: [CGRect], currentSpaceID: Int,
                    visibleFrame: CGRect, excludedWindowIDs: Set<UInt32>, standardWindowIDs: Set<UInt32>) {
            self.mainBounds = mainBounds
            self.otherDisplayBounds = otherDisplayBounds
            self.currentSpaceID = currentSpaceID
            self.visibleFrame = visibleFrame
            self.excludedWindowIDs = excludedWindowIDs
            self.standardWindowIDs = standardWindowIDs
        }
    }

    public struct Placement: Equatable {
        /// The position in the original candidate array, before filtering.
        /// This preserves correspondence even when window IDs repeat.
        public let inputIndex: Int
        public let windowID: UInt32
        /// Global top-left coordinates, with each edge rounded to a pixel.
        public let frame: CGRect
    }

    public static let ultrawide: CGFloat = 2.0
    public static let masterRatio: CGFloat = 0.62
    public static let laneWidths: [CGFloat] = [0.3, 0.4, 0.3]

    /// One unit rect per input lane, in input order, with y = 0 at the top.
    public static func frames(_ kind: Kind, lanes windowLanes: [Lane], aspect: CGFloat) -> [CGRect] {
        guard !windowLanes.isEmpty else { return [] }
        let wide = aspect >= ultrawide
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        if windowLanes.count == 1 {
            return [wide ? CGRect(x: 0.25, y: 0, width: 0.5, height: 1) : whole]
        }
        var frames = Array(repeating: whole, count: windowLanes.count)
        let all = Array(windowLanes.indices)
        switch kind {
        case .auto:
            let lanes = Lane.allCases
                .map { lane in all.filter { windowLanes[$0] == lane } }
                .filter { !$0.isEmpty }
            if wide {
                switch lanes.count {
                case 1:
                    columns(lanes[0], count: 4, in: whole, into: &frames)
                case 2:
                    stack(lanes[0], in: CGRect(x: 0, y: 0, width: 0.5, height: 1), into: &frames)
                    stack(lanes[1], in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), into: &frames)
                default:
                    var x: CGFloat = 0
                    for (lane, width) in zip(lanes, laneWidths) {
                        stack(lane, in: CGRect(x: x, y: 0, width: width, height: 1), into: &frames)
                        x += width
                    }
                }
            } else {
                let main = all.first { windowLanes[$0] == .middle } ?? lanes[0][0]
                frames[main] = CGRect(x: 0, y: 0, width: 0.5, height: 1)
                let rest = lanes.joined().filter { $0 != main }
                stack(Array(rest), in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), into: &frames)
            }
        case .columns:
            columns(all, count: wide ? 4 : 3, in: whole, into: &frames)
        case .masterStack:
            frames[0] = CGRect(x: 0, y: 0, width: masterRatio, height: 1)
            stack(Array(all.dropFirst()), in: CGRect(x: masterRatio, y: 0, width: 1 - masterRatio, height: 1), into: &frames)
        }
        return frames
    }

    /// Filters eligibility without reordering, then projects the layout into
    /// the usable display frame. Explicitly placed windows retain their place.
    public static func plan(_ kind: Kind, candidates: [Candidate], context: Context) -> [Placement] {
        let visible = context.visibleFrame
        guard context.currentSpaceID > 0, visible.width > 0, visible.height > 0,
              [visible.minX, visible.minY, visible.width, visible.height].allSatisfy(\.isFinite) else { return [] }
        let eligible = candidates.enumerated().filter { _, candidate in
            guard !candidate.isPlaced, !context.excludedWindowIDs.contains(candidate.windowID), candidate.hasTitle,
                  candidate.spaceIDs.contains(context.currentSpaceID),
                  context.standardWindowIDs.contains(candidate.windowID) else { return false }
            let rect = candidate.frame
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            if context.mainBounds.contains(centre) { return true }
            if context.otherDisplayBounds.contains(where: { $0.contains(centre) }) { return false }
            // LayerStage parks windows by the main display's right edge. They
            // remain candidates even while their centre is off every display.
            return rect.minX >= context.mainBounds.maxX - 40 || context.mainBounds.intersects(rect)
        }
        let boxes = frames(kind, lanes: eligible.map { $0.element.lane }, aspect: visible.width / visible.height)
        return zip(eligible, boxes).map { indexed, box in
            let raw = CGRect(x: visible.origin.x + visible.width * box.minX,
                             y: visible.origin.y + visible.height * box.minY,
                             width: visible.width * box.width,
                             height: visible.height * box.height)
            let x = raw.minX.rounded(), y = raw.minY.rounded()
            return Placement(inputIndex: indexed.offset, windowID: indexed.element.windowID,
                             frame: CGRect(x: x, y: y,
                                           width: raw.maxX.rounded() - x, height: raw.maxY.rounded() - y))
        }
    }

    private static func columns(_ members: [Int], count: Int, in area: CGRect, into frames: inout [CGRect]) {
        let count = max(1, min(count, members.count))
        let width = area.width / CGFloat(count)
        var next = 0
        for column in 0..<count {
            let size = members.count / count + (column < members.count % count ? 1 : 0)
            let rect = CGRect(x: area.minX + CGFloat(column) * width, y: area.minY, width: width, height: area.height)
            stack(Array(members[next..<next + size]), in: rect, into: &frames)
            next += size
        }
    }

    private static func stack(_ members: [Int], in area: CGRect, into frames: inout [CGRect]) {
        guard !members.isEmpty else { return }
        if members.count <= 3 {
            let height = area.height / CGFloat(members.count)
            for (row, member) in members.enumerated() {
                frames[member] = CGRect(x: area.minX, y: area.minY + CGFloat(row) * height, width: area.width, height: height)
            }
            return
        }
        let rows = (members.count + 1) / 2
        let height = area.height / CGFloat(rows)
        let width = area.width / 2
        for (position, member) in members.enumerated() {
            let (row, column) = (position / 2, position % 2)
            let alone = column == 0 && position == members.count - 1
            frames[member] = CGRect(
                x: area.minX + CGFloat(column) * width,
                y: area.minY + CGFloat(row) * height,
                width: alone ? area.width : width,
                height: height
            )
        }
    }
}
