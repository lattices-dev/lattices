import CoreGraphics
import Foundation

enum MouseHandoffGesture {
    static func qualifies(button: Int64, flags: CGEventFlags, sourcePID: Int64) -> Bool {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return button == 1 && flags.intersection(modifiers) == .maskControl && sourcePID == 0
    }

    static func direction(delta: CGPoint, threshold: CGFloat) -> MouseHandoffDirection? {
        guard abs(delta.x) >= max(68, threshold), abs(delta.x) >= abs(delta.y) * 1.5 else { return nil }
        return delta.x < 0 ? .left : .right
    }

}

struct MouseHandoffCooldown {
    private var nextAllowed: TimeInterval = 0
    mutating func reserve(at time: TimeInterval) -> Bool {
        guard time >= nextAllowed else { return false }
        nextAllowed = time + 5
        return true
    }
}

enum MouseHandoffDirection: String {
    case left, right

    func target(from current: UInt8) -> UInt8 {
        precondition(current < 3)
        return (current + (self == .left ? 2 : 1)) % 3
    }
}
