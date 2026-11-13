import AppKit
import QuartzCore

/// One shaped cursor chases the local target dot and settles with its tip on
/// it. It never schedules input. The lag is bounded, so the pointer trails
/// the dot visibly but never reads as a distant second pointer.
final class RemoteAgentCursorView: NSView {
    static let maximumSeparation: CGFloat = 36
    static let catchUp: CFTimeInterval = 0.2

    /// Cursor rectangles scope this to the controlled picture; AppKit restores
    /// the normal pointer over local controls and outside the viewer.
    static let controlCursor: NSCursor = {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor(white: 0.08, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8)).fill()
            NSColor(white: 1, alpha: 0.98).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5, width: 5, height: 5)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 6, y: 6))
    }()
    private let pointer = CALayer()
    private let ripple = CAShapeLayer()
    private var hasPosition = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)

        let coral = NSColor(srgbRed: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255, alpha: 1).cgColor
        ripple.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        ripple.fillColor = coral.copy(alpha: 0.12)
        ripple.strokeColor = coral
        ripple.lineWidth = 1.6
        ripple.opacity = 0
        layer?.addSublayer(ripple)

        // A soft, squat pointer with a rounded nose and rounded shoulders.
        pointer.anchorPoint = .zero
        pointer.bounds = CGRect(x: 0, y: 0, width: 17, height: 19)
        pointer.opacity = 0.9
        pointer.shadowColor = NSColor(srgbRed: 0.40, green: 0.52, blue: 1, alpha: 1).cgColor
        pointer.shadowOpacity = 0.35
        pointer.shadowRadius = 3
        pointer.shadowOffset = .zero
        let arrow = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.5, y: 2.8))
        path.addCurve(to: CGPoint(x: 3.3, y: 0.8), control1: CGPoint(x: 0, y: 0.5), control2: CGPoint(x: 1.4, y: -0.4))
        path.addLine(to: CGPoint(x: 15.4, y: 10))
        path.addCurve(to: CGPoint(x: 14.5, y: 13), control1: CGPoint(x: 17.2, y: 11.4), control2: CGPoint(x: 16.6, y: 12.7))
        path.addLine(to: CGPoint(x: 10.5, y: 13.5))
        path.addQuadCurve(to: CGPoint(x: 9, y: 14.5), control: CGPoint(x: 9.5, y: 13.6))
        path.addLine(to: CGPoint(x: 7.1, y: 17.7))
        path.addCurve(to: CGPoint(x: 3.8, y: 17.2), control1: CGPoint(x: 6, y: 19.6), control2: CGPoint(x: 4.3, y: 19.2))
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = NSColor(white: 0.13, alpha: 1).cgColor
        arrow.strokeColor = NSColor(white: 0.98, alpha: 1).cgColor
        arrow.lineWidth = 1.25
        arrow.lineJoin = .round
        pointer.shadowPath = path
        pointer.addSublayer(arrow)
        layer?.addSublayer(pointer)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { reset() }
    }

    func reset() {
        hasPosition = false
        pointer.removeAllAnimations()
        ripple.removeAllAnimations()
        isHidden = true
    }

    func follow(_ point: CGPoint, reduceMotion: Bool) {
        guard !hasPosition || point != pointer.position || reduceMotion else { return }
        let previous = pointer.presentation()?.position ?? pointer.position
        let dx = previous.x - point.x, dy = previous.y - point.y
        let distance = hypot(dx, dy)
        let fraction = distance > 0 ? min(1, Self.maximumSeparation / distance) : 0
        let start = CGPoint(x: point.x + dx * fraction, y: point.y + dy * fraction)
        pointer.removeAllAnimations()
        withoutActions { pointer.position = point }
        if hasPosition, !reduceMotion, distance > 0 {
            let settle = CABasicAnimation(keyPath: "position")
            settle.fromValue = start
            settle.toValue = point
            settle.duration = Self.catchUp
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            pointer.add(settle, forKey: "settle")
        }
        hasPosition = true
        isHidden = false
    }

    /// A visual receipt for a submitted click, not an acknowledgement from the host.
    func indicateClick(at point: CGPoint, reduceMotion: Bool) {
        guard hasPosition else { return }
        // Click feedback stays at the dot: no approach, pause or retreat.
        ripple.removeAllAnimations()
        withoutActions { ripple.position = point }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.18 : 0.38
        ripple.add(fade, forKey: "fade")
        guard !reduceMotion else { return }
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 0.35
        spread.toValue = 2.1
        spread.duration = 0.38
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(spread, forKey: "spread")

    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
