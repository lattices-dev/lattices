import Foundation
import CoreGraphics

// MARK: - Path Point

/// A single point in the captured mouse path with timestamp
struct GesturePathPoint: Codable {
    let x: CGFloat
    let y: CGFloat
    let timestamp: TimeInterval

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    init(x: CGFloat, y: CGFloat, timestamp: TimeInterval) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }

    init(point: CGPoint, timestamp: TimeInterval) {
        self.x = point.x
        self.y = point.y
        self.timestamp = timestamp
    }
}

// MARK: - Direction Segment

/// A detected direction segment in the path
struct DirectionSegment {
    let direction: MouseGestureDirection
    let startIndex: Int
    let endIndex: Int
    let length: CGFloat

    var label: String {
        direction.rawValue
    }
}

// MARK: - Shape Label

/// Recognized shape label from the gesture
enum GestureShapeLabel: String, Codable, CaseIterable {
    // Single segment
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"

    // Two-segment shapes
    case lShapeDownRight = "l-shape-down-right"
    case lShapeDownLeft = "l-shape-down-left"
    case lShapeUpRight = "l-shape-up-right"
    case lShapeUpLeft = "l-shape-up-left"
    case reverseLShapeRightDown = "reverse-l-right-down"
    case reverseLShapeLeftDown = "reverse-l-left-down"
    case vShape = "v-shape"
    case reverseV = "reverse-v"
    case zShape = "z-shape"
    case reverseZ = "reverse-z"
    case sShape = "s-shape"

    // Three-segment shapes
    case uShape = "u-shape"
    case uShapeFlipped = "u-shape-flipped"
    case nShape = "n-shape"
    case mShape = "m-shape"

    // Freeform shapes
    case circle = "circle"

    var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .lShapeDownRight: return "L (↓ then →)"
        case .lShapeDownLeft: return "L (↓ then ←)"
        case .lShapeUpRight: return "L (↑ then →)"
        case .lShapeUpLeft: return "L (↑ then ←)"
        case .reverseLShapeRightDown: return "Reverse L (→ then ↓)"
        case .reverseLShapeLeftDown: return "Reverse L (← then ↓)"
        case .vShape: return "V (↓ then ↑)"
        case .reverseV: return "Reverse V (↑ then ↓)"
        case .zShape: return "Z (→ then ↓ then →)"
        case .reverseZ: return "Reverse Z (← then ↓ then ←)"
        case .sShape: return "S (→ then ↑ then →)"
        case .uShape: return "U (↓ then → then ↑)"
        case .uShapeFlipped: return "U Flipped (↑ then → then ↓)"
        case .nShape: return "N (↓ then ← then ↑)"
        case .mShape: return "M (↑ then ← then ↓)"
        case .circle: return "Circle"
        }
    }

    var segmentCount: Int {
        switch self {
        case .up, .down, .left, .right:
            return 1
        case .lShapeDownRight, .lShapeDownLeft, .lShapeUpRight, .lShapeUpLeft,
             .reverseLShapeRightDown, .reverseLShapeLeftDown, .vShape, .reverseV:
            return 2
        case .zShape, .reverseZ, .sShape:
            return 3
        case .uShape, .uShapeFlipped, .nShape, .mShape:
            return 3
        case .circle:
            return 4
        }
    }

    static func from(segments: [DirectionSegment]) -> GestureShapeLabel? {
        guard !segments.isEmpty else { return nil }

        let directions = segments.map { $0.direction }

        // Single direction
        if segments.count == 1 {
            switch directions[0] {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }

        // Two directions - L-shapes, V-shapes, etc.
        if segments.count == 2 {
            let first = directions[0]
            let second = directions[1]

            // L shapes
            if first == .down && second == .right {
                return .lShapeDownRight
            }
            if first == .down && second == .left {
                return .lShapeDownLeft
            }
            if first == .up && second == .right {
                return .lShapeUpRight
            }
            if first == .up && second == .left {
                return .lShapeUpLeft
            }

            // Reverse L shapes (horizontal first)
            if first == .right && second == .down {
                return .reverseLShapeRightDown
            }
            if first == .left && second == .down {
                return .reverseLShapeLeftDown
            }

            // V shapes (opposite vertical directions)
            if first == .down && second == .up {
                return .vShape
            }
            if first == .up && second == .down {
                return .reverseV
            }
        }

        // Three directions - Z-shapes, U-shapes, etc.
        if segments.count == 3 {
            let first = directions[0]
            let second = directions[1]
            let third = directions[2]

            // Z shapes (horizontal, vertical, horizontal)
            if first == .right && second == .down && third == .right {
                return .zShape
            }
            if first == .left && second == .down && third == .left {
                return .reverseZ
            }
            if first == .right && second == .up && third == .right {
                return .sShape
            }

            // U shapes (down, right, up or similar)
            if first == .down && second == .right && third == .up {
                return .uShape
            }
            if first == .up && second == .right && third == .down {
                return .uShapeFlipped
            }
            if first == .down && second == .left && third == .up {
                return .nShape
            }
            if first == .up && second == .left && third == .down {
                return .mShape
            }
        }

        return nil
    }
}

// MARK: - Recognition Result

struct ShapeRecognitionResult {
    let shape: GestureShapeLabel?
    let segments: [DirectionSegment]
    let confidence: CGFloat
    let pathLength: CGFloat

    var displayLabel: String {
        if let shape {
            return shape.displayName
        }
        if let first = segments.first {
            return "Unknown (\(first.label))"
        }
        return "Unknown"
    }

    var shapeToken: String? {
        shape?.rawValue
    }
}

// MARK: - Shape Recognizer

final class ShapeRecognizer {
    // Configuration
    private let minSegmentLength: CGFloat
    private let angularThreshold: CGFloat  // radians, default ~45 degrees
    private let minTotalPathLength: CGFloat
    private let cornerSmoothRadius: Int     // points to consider around corners

    init(
        minSegmentLength: CGFloat = 40,
        angularThreshold: CGFloat = .pi / 4,  // 45 degrees
        minTotalPathLength: CGFloat = 80,
        cornerSmoothRadius: Int = 3
    ) {
        self.minSegmentLength = minSegmentLength
        self.angularThreshold = angularThreshold
        self.minTotalPathLength = minTotalPathLength
        self.cornerSmoothRadius = cornerSmoothRadius
    }

    // MARK: - Main Entry Point

    func recognize(points: [GesturePathPoint]) -> ShapeRecognitionResult {
        guard points.count >= 3 else {
            return ShapeRecognitionResult(shape: nil, segments: [], confidence: 0, pathLength: 0)
        }

        // Calculate total path length
        let totalLength = calculatePathLength(points)
        guard totalLength >= minTotalPathLength else {
            return ShapeRecognitionResult(shape: nil, segments: [], confidence: 0, pathLength: totalLength)
        }

        if let circleConfidence = calculateCircleConfidence(points: points, totalLength: totalLength) {
            return ShapeRecognitionResult(
                shape: .circle,
                segments: [],
                confidence: circleConfidence,
                pathLength: totalLength
            )
        }

        if let legs = downwardChevron(points) {
            return ShapeRecognitionResult(shape: .vShape, segments: legs,
                confidence: calculateConfidence(segments: legs, corners: 1, totalLength: totalLength),
                pathLength: totalLength)
        }

        // Direction runs work better for mouse gestures than strict corner
        // detection because real paths rarely contain one crisp corner sample.
        let runSegments = buildDirectionRunSegments(points: points)
        let corners = detectCorners(points: points)
        let segments = runSegments.isEmpty ? buildSegments(points: points, corners: corners) : runSegments

        // Classify shape
        let shape = GestureShapeLabel.from(segments: segments)

        // Calculate confidence based on segment clarity
        let confidence = calculateConfidence(segments: segments, corners: corners.count, totalLength: totalLength)

        return ShapeRecognitionResult(
            shape: shape,
            segments: segments,
            confidence: confidence,
            pathLength: totalLength
        )
    }

    // MARK: - Corner Detection

    /// At 45 degrees both legs can quantize to the same horizontal direction.
    /// Fit the two arms at the lowest point before reducing samples to axis runs.
    private func downwardChevron(_ points: [GesturePathPoint]) -> [DirectionSegment]? {
        guard let tip = points.indices.max(by: { points[$0].y < points[$1].y }),
              tip > 0, tip < points.count - 1 else { return nil }
        let last = points.count - 1
        let apex = points[tip]
        let across = points[last].x > points[0].x ? CGFloat(1) : -1
        var legs: [DirectionSegment] = []
        for (start, end, direction) in [(0, tip, MouseGestureDirection.down), (tip, last, .up)] {
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            let depth = apex.y - (direction == .down ? a.y : b.y)
            guard length >= minSegmentLength, dx * across >= length * 0.20,
                  depth >= max(minSegmentLength / 2, length * 0.35) else { return nil }
            // Reject flat-bottomed U shapes, loops and retraced strokes.
            let traveled = segmentLength(points: points, from: start, to: end)
            guard traveled <= length * 1.20,
                  points[start...end].allSatisfy({ point in
                      let distance = abs(dx * (point.y - a.y) - dy * (point.x - a.x)) / length
                      return distance <= max(6, length * 0.13)
                  }) else { return nil }
            legs.append(.init(direction: direction, startIndex: start, endIndex: end, length: traveled))
        }
        return legs
    }

    private func detectCorners(points: [GesturePathPoint]) -> [Int] {
        guard points.count > cornerSmoothRadius * 2 else { return [] }

        var corners: [Int] = []
        var lastSignificantDirection: MouseGestureDirection?

        for i in cornerSmoothRadius..<(points.count - cornerSmoothRadius) {
            let before = averageVector(in: points, from: i - cornerSmoothRadius, to: i)
            let after = averageVector(in: points, from: i, to: i + cornerSmoothRadius)

            // Skip if either vector is too short (near-zero movement)
            guard vectorLength(before) > minSegmentLength / 4 else { continue }
            guard vectorLength(after) > minSegmentLength / 4 else { continue }

            let directionBefore = vectorToDirection(before)
            let directionAfter = vectorToDirection(after)

            guard let dirBefore = directionBefore, let dirAfter = directionAfter else { continue }

            // Check if this is a meaningful direction change
            if dirBefore != dirAfter {
                // Verify it's not just noise - the change should be significant
                let angle = angleBetween(before, after)
                if angle >= angularThreshold {
                    // Only add if it's a new direction (not rapid back-and-forth)
                    if lastSignificantDirection != dirAfter {
                        corners.append(i)
                        lastSignificantDirection = dirAfter
                    }
                }
            }
        }

        return corners
    }

    private func averageVector(in points: [GesturePathPoint], from start: Int, to end: Int) -> CGPoint {
        guard end > start else { return .zero }
        var sum = CGPoint.zero
        var count = 0

        for i in start..<min(end, points.count) {
            if i > start {
                let prev = points[i - 1]
                let curr = points[i]
                sum.x += curr.x - prev.x
                sum.y += curr.y - prev.y
                count += 1
            }
        }

        return count > 0 ? CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count)) : .zero
    }

    private func vectorLength(_ v: CGPoint) -> CGFloat {
        sqrt(v.x * v.x + v.y * v.y)
    }

    private func vectorToDirection(_ v: CGPoint) -> MouseGestureDirection? {
        let length = vectorLength(v)
        guard length > 5 else { return nil }  // minimum threshold

        // Determine primary direction based on dominant axis
        let absX = abs(v.x)
        let absY = abs(v.y)

        if absX > absY * 1.2 {  // axis bias
            return v.x >= 0 ? .right : .left
        } else if absY > absX * 1.2 {
            return v.y >= 0 ? .down : .up
        }

        // If diagonal, use the dominant component
        if absX >= absY {
            return v.x >= 0 ? .right : .left
        } else {
            return v.y >= 0 ? .down : .up
        }
    }

    private func angleBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dot = a.x * b.x + a.y * b.y
        let lenA = vectorLength(a)
        let lenB = vectorLength(b)
        guard lenA > 0 && lenB > 0 else { return 0 }

        let cosAngle = max(-1, min(1, dot / (lenA * lenB)))
        return acos(cosAngle)
    }

    // MARK: - Segment Building

    private func makeDirectionSegment(
        direction: MouseGestureDirection?,
        start: Int,
        end: Int,
        length: CGFloat
    ) -> DirectionSegment? {
        guard let direction, length > 0 else { return nil }
        return DirectionSegment(
            direction: direction,
            startIndex: start,
            endIndex: end,
            length: length
        )
    }

    private func buildDirectionRunSegments(points: [GesturePathPoint]) -> [DirectionSegment] {
        guard points.count >= 2 else { return [] }

        var rawSegments: [DirectionSegment] = []
        var currentDirection: MouseGestureDirection?
        var currentStart = 0
        var currentEnd = 0
        var currentLength: CGFloat = 0

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            let length = vectorLength(delta)
            guard length >= 2, let direction = vectorToDirection(delta) else { continue }

            if currentDirection == nil {
                currentDirection = direction
                currentStart = index - 1
                currentEnd = index
                currentLength = length
                continue
            }

            if direction == currentDirection {
                currentEnd = index
                currentLength += length
            } else {
                if let segment = makeDirectionSegment(
                    direction: currentDirection,
                    start: currentStart,
                    end: currentEnd,
                    length: currentLength
                ) {
                    rawSegments.append(segment)
                }
                currentDirection = direction
                currentStart = index - 1
                currentEnd = index
                currentLength = length
            }
        }
        if let segment = makeDirectionSegment(
            direction: currentDirection,
            start: currentStart,
            end: currentEnd,
            length: currentLength
        ) {
            rawSegments.append(segment)
        }

        let merged = mergeShortDirectionRuns(rawSegments)
        let filtered = merged.filter { $0.length >= minSegmentLength }
        return mergeAdjacentSegments(filtered)
    }

    private func mergeShortDirectionRuns(_ segments: [DirectionSegment]) -> [DirectionSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [DirectionSegment] = []
        for segment in segments {
            guard segment.length < minSegmentLength / 2 else {
                result.append(segment)
                continue
            }

            if let last = result.last {
                result[result.count - 1] = DirectionSegment(
                    direction: last.direction,
                    startIndex: last.startIndex,
                    endIndex: segment.endIndex,
                    length: last.length + segment.length
                )
            }
        }

        return result
    }

    private func mergeAdjacentSegments(_ segments: [DirectionSegment]) -> [DirectionSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [DirectionSegment] = []
        for segment in segments {
            if let last = result.last, last.direction == segment.direction {
                result[result.count - 1] = DirectionSegment(
                    direction: last.direction,
                    startIndex: last.startIndex,
                    endIndex: segment.endIndex,
                    length: last.length + segment.length
                )
            } else {
                result.append(segment)
            }
        }

        return result
    }

    private func buildSegments(points: [GesturePathPoint], corners: [Int]) -> [DirectionSegment] {
        guard !points.isEmpty else { return [] }

        // If no corners, use entire path as one segment
        if corners.isEmpty {
            let direction = overallDirection(points: points)
            if let dir = direction {
                let length = calculatePathLength(points)
                return [DirectionSegment(direction: dir, startIndex: 0, endIndex: points.count - 1, length: length)]
            }
            return []
        }

        var segments: [DirectionSegment] = []

        // First segment
        let firstCorner = corners[0]
        let firstDir = segmentDirection(points: points, from: 0, to: firstCorner)
        if let dir = firstDir {
            let length = segmentLength(points: points, from: 0, to: firstCorner)
            if length >= minSegmentLength {
                segments.append(DirectionSegment(direction: dir, startIndex: 0, endIndex: firstCorner, length: length))
            }
        }

        // Middle segments (between corners)
        for i in 0..<(corners.count - 1) {
            let startIdx = corners[i]
            let endIdx = corners[i + 1]
            let dir = segmentDirection(points: points, from: startIdx, to: endIdx)
            if let dir = dir {
                let length = segmentLength(points: points, from: startIdx, to: endIdx)
                if length >= minSegmentLength {
                    segments.append(DirectionSegment(direction: dir, startIndex: startIdx, endIndex: endIdx, length: length))
                }
            }
        }

        // Last segment
        let lastCorner = corners[corners.count - 1]
        let lastDir = segmentDirection(points: points, from: lastCorner, to: points.count - 1)
        if let dir = lastDir {
            let length = segmentLength(points: points, from: lastCorner, to: points.count - 1)
            if length >= minSegmentLength {
                segments.append(DirectionSegment(direction: dir, startIndex: lastCorner, endIndex: points.count - 1, length: length))
            }
        }

        return segments
    }

    private func overallDirection(points: [GesturePathPoint]) -> MouseGestureDirection? {
        guard let first = points.first, let last = points.last else { return nil }
        let delta = CGPoint(x: last.x - first.x, y: last.y - first.y)
        return vectorToDirection(delta)
    }

    private func segmentDirection(points: [GesturePathPoint], from startIdx: Int, to endIdx: Int) -> MouseGestureDirection? {
        guard startIdx < endIdx, endIdx < points.count else { return nil }
        let start = points[startIdx]
        let end = points[endIdx]
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        return vectorToDirection(delta)
    }

    private func segmentLength(points: [GesturePathPoint], from startIdx: Int, to endIdx: Int) -> CGFloat {
        guard startIdx < endIdx else { return 0 }
        var length: CGFloat = 0
        for i in (startIdx + 1)...endIdx {
            if i < points.count {
                let dx = points[i].x - points[i - 1].x
                let dy = points[i].y - points[i - 1].y
                length += sqrt(dx * dx + dy * dy)
            }
        }
        return length
    }

    private func calculatePathLength(_ points: [GesturePathPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var length: CGFloat = 0
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            length += sqrt(dx * dx + dy * dy)
        }
        return length
    }

    private func calculateCircleConfidence(points: [GesturePathPoint], totalLength: CGFloat) -> CGFloat? {
        guard points.count >= 12,
              let first = points.first,
              let last = points.last else { return nil }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max() else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        let maxSide = max(width, height)
        let minSide = min(width, height)
        guard minSide >= 35 else { return nil }

        let aspect = minSide / maxSide
        guard aspect >= 0.45 else { return nil }

        let closure = vectorLength(CGPoint(x: last.x - first.x, y: last.y - first.y))
        guard closure <= max(48, maxSide * 0.65) else { return nil }

        let lengthRatio = totalLength / maxSide
        guard lengthRatio >= 2.2, lengthRatio <= 5.6 else { return nil }

        let center = CGPoint(x: minX + width / 2, y: minY + height / 2)
        var totalTurn: CGFloat = 0
        var previousAngle: CGFloat?

        for point in points {
            let vector = CGPoint(x: point.x - center.x, y: point.y - center.y)
            guard vectorLength(vector) >= maxSide * 0.12 else { continue }
            let angle = atan2(vector.y, vector.x)
            if let previousAngle {
                var delta = angle - previousAngle
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                totalTurn += delta
            }
            previousAngle = angle
        }

        let turnCoverage = abs(totalTurn) / (2 * .pi)
        guard turnCoverage >= 0.72 else { return nil }

        let closureScore = 1 - min(1, closure / max(1, maxSide * 0.65))
        let aspectScore = min(1, max(0, (aspect - 0.45) / 0.4))
        let turnScore = min(1, max(0, (turnCoverage - 0.72) / 0.28))
        let lengthScore = min(1, max(0, (lengthRatio - 2.2) / 1.1))
        return max(0.55, min(1, 0.35 * turnScore + 0.25 * closureScore + 0.2 * aspectScore + 0.2 * lengthScore))
    }

    // MARK: - Confidence Calculation

    private func calculateConfidence(segments: [DirectionSegment], corners: Int, totalLength: CGFloat) -> CGFloat {
        guard !segments.isEmpty else { return 0 }

        var confidence: CGFloat = 1.0

        // Penalize for many corners (noisy path)
        if corners > 2 {
            confidence -= CGFloat(corners - 2) * 0.1
        }

        // Penalize if segment lengths are very uneven (might be accidental)
        if segments.count >= 2 {
            let lengths = segments.map { $0.length }
            let avgLength = lengths.reduce(0, +) / CGFloat(lengths.count)
            let variance = lengths.map { abs($0 - avgLength) / avgLength }.reduce(0, +) / CGFloat(lengths.count)
            confidence -= min(0.3, CGFloat(variance) * 0.5)
        }

        // Boost if path is long and smooth
        if totalLength > 200 && corners == 0 {
            confidence = min(1.0, confidence + 0.1)
        }

        return max(0, min(1, confidence))
    }
}

// MARK: - Convenience Extensions

extension ShapeRecognizer {
    /// Recognize from raw CGPoints
    func recognize(points: [CGPoint], timestamps: [TimeInterval]? = nil) -> ShapeRecognitionResult {
        let gesturePoints: [GesturePathPoint]
        if let ts = timestamps {
            gesturePoints = zip(points, ts).map { GesturePathPoint(x: $0.0.x, y: $0.0.y, timestamp: $0.1) }
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            gesturePoints = points.enumerated().map { GesturePathPoint(x: $0.1.x, y: $0.1.y, timestamp: now + Double($0.0) * 0.01) }
        }
        return recognize(points: gesturePoints)
    }

    /// Quick check if path contains a corner
    func hasCorner(at point: CGPoint, in points: [GesturePathPoint]) -> Bool {
        // Simple check - find nearest point index and check context
        guard let nearestIndex = points.firstIndex(where: { abs($0.x - point.x) < 5 && abs($0.y - point.y) < 5 }) else {
            return false
        }
        let corners = detectCorners(points: points)
        return corners.contains(nearestIndex)
    }
}
