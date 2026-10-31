import CoreGraphics
import Foundation

/// How a hand moves a pointer: a quick launch, a slight bow and a soft arrival.
///
/// Shared by real pointer gestures and the cursors drawn over them, so what is seen and
/// what the app receives follow the same path.
public enum ActionPointerMotion {
    /// Smootherstep: zero velocity and acceleration at both ends, so nothing jerks.
    public static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// The control point that bows a hop to the left of travel by a fraction of its length.
    public static func bowControl(from start: CGPoint, to end: CGPoint, fraction: CGFloat, limit: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0 else { return mid }
        let bow = min(distance * fraction, limit) / distance
        return CGPoint(x: mid.x - (end.y - start.y) * bow, y: mid.y + (end.x - start.x) * bow)
    }

    /// The point `progress` of the way along the eased quadratic from `start` to `end`.
    public static func point(from start: CGPoint, control: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let t = CGFloat(ease(progress))
        let v = 1 - t
        return CGPoint(x: v * v * start.x + 2 * v * t * control.x + t * t * end.x,
                       y: v * v * start.y + 2 * v * t * control.y + t * t * end.y)
    }

    /// How long a drag holds after the press before it travels. The press is what brings a
    /// background app forward, and a window only follows the pointer once that app has
    /// taken the press as the start of a move.
    public static let dragPickupMs = 90

    /// How long a drag rests on its target before the release, so the window lands where
    /// the pointer stops instead of being read as a fling.
    public static let dragSettleMs = 50

    /// A drag paced like a hand: short hops snap, long ones still land in under half a second.
    public static func dragDurationMs(from start: CGPoint, to end: CGPoint) -> Int {
        let distance = Double(hypot(end.x - start.x, end.y - start.y))
        return Int(min(420, max(140, 110 + distance / 2.4)))
    }

    /// How long a drag travels: what the caller asked for, else paced from the distance.
    public static func dragTravelMs(from start: CGPoint, to end: CGPoint, requested: Int? = nil) -> Int {
        max(40, requested ?? dragDurationMs(from: start, to: end))
    }

    /// The bow a drag travels along, in the same points as `start` and `end`.
    public static func dragControl(from start: CGPoint, to end: CGPoint) -> CGPoint {
        bowControl(from: start, to: end, fraction: 0.06, limit: 14)
    }
}
