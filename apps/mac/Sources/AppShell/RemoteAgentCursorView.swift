import AppKit
import QuartzCore

enum RemoteAgentCursorBehavior: String, CaseIterable {
    case followPointer
    case returnToOrigin

    var title: String {
        switch self {
        case .followPointer: return "Follow my pointer"
        case .returnToOrigin: return "Return after clicking"
        }
    }
}

/// A local companion to the real pointer. Its flight never schedules remote input.
/// Core Animation does the drawing and goes idle when the pointer has settled.
final class RemoteAgentCursorView: NSView {
    var behavior: RemoteAgentCursorBehavior = .followPointer {
        didSet { if behavior != oldValue { reset() } }
    }
    private let pointer = CALayer()
    private let ripple = CAShapeLayer()
    private var hasPosition = false
    private var hoverPoint: CGPoint?
    private var home: CGPoint?
    private var landing: Task<Void, Never>?
    private(set) var isLanding = false

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
        pointer.shadowColor = NSColor(srgbRed: 0.40, green: 0.52, blue: 1, alpha: 1).cgColor
        pointer.shadowOpacity = 0.8
        pointer.shadowRadius = 5
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
        landing?.cancel()
        landing = nil
        isLanding = false
        hasPosition = false
        hoverPoint = nil
        home = nil
        pointer.removeAllAnimations()
        ripple.removeAllAnimations()
        isHidden = true
    }

    func follow(_ point: CGPoint, reduceMotion: Bool) {
        hoverPoint = point
        guard !isLanding else { return }
        if behavior == .returnToOrigin, hasPosition { return }
        // Settle beside the real pointer with a gently varying offset. This is
        // spatial drift, not idle jitter: once the mouse rests, the companion rests.
        let drift = (point.x + point.y) * 0.012
        let offset = CGPoint(x: 25 + sin(drift) * 4, y: 23 + cos(drift * 0.8) * 4)
        let destination = CGPoint(x: min(max(7, point.x + offset.x), max(7, bounds.width - 22)),
                                  y: min(max(7, point.y + offset.y), max(7, bounds.height - 27)))
        let start = pointer.presentation()?.position ?? pointer.position
        if !hasPosition { home = destination }
        withoutActions { pointer.position = destination }
        if hasPosition, !reduceMotion {
            let flight = CABasicAnimation(keyPath: "position")
            flight.fromValue = start
            flight.toValue = destination
            flight.duration = 0.34
            flight.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pointer.add(flight, forKey: "flight")
        } else {
            pointer.removeAnimation(forKey: "flight")
        }
        hasPosition = true
        isHidden = false
    }

    /// A visual receipt for a submitted click, not an acknowledgement from the host.
    func land(at point: CGPoint, reduceMotion: Bool) {
        if !hasPosition { follow(point, reduceMotion: reduceMotion) }
        hoverPoint = point
        let start = pointer.presentation()?.position ?? pointer.position
        landing?.cancel()
        pointer.removeAllAnimations()
        ripple.removeAllAnimations()
        isLanding = true
        isHidden = false
        withoutActions { pointer.position = point }

        let distance = hypot(point.x - start.x, point.y - start.y)
        let duration: TimeInterval = reduceMotion ? 0 : min(0.30, 0.15 + distance / 2200)
        if !reduceMotion {
            let flight = CAKeyframeAnimation(keyPath: "position")
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: point, control: CGPoint(x: (start.x + point.x) / 2,
                                                        y: min(start.y, point.y) - min(42, 12 + distance * 0.08)))
            flight.path = path
            flight.duration = duration
            flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pointer.add(flight, forKey: "flight")
        }

        landing = Task { @MainActor [weak self] in
            do {
                if duration > 0 { try await Task.sleep(for: .seconds(duration)) }
                guard let self, !Task.isCancelled else { return }
                self.impact(at: point, reduceMotion: reduceMotion)
                try await Task.sleep(for: .seconds(0.32))
                guard !Task.isCancelled else { return }
                self.isLanding = false
                self.landing = nil
                if self.behavior == .returnToOrigin, let home = self.home {
                    self.returnHome(to: home, reduceMotion: reduceMotion)
                } else if let hover = self.hoverPoint {
                    self.follow(hover, reduceMotion: reduceMotion)
                }
            } catch { /* Leaving the picture or clicking again cancels this landing. */ }
        }
    }

    private func returnHome(to home: CGPoint, reduceMotion: Bool) {
        let start = pointer.presentation()?.position ?? pointer.position
        withoutActions { pointer.position = home }
        guard !reduceMotion else { return }
        let flight = CABasicAnimation(keyPath: "position")
        flight.fromValue = start
        flight.toValue = home
        flight.duration = 0.26
        flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pointer.add(flight, forKey: "flight")
    }

    private func impact(at point: CGPoint, reduceMotion: Bool) {
        withoutActions { ripple.position = point }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
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

        let drop = CAKeyframeAnimation(keyPath: "transform")
        drop.values = [CATransform3DIdentity,
                       CATransform3DMakeScale(1.12, 0.82, 1),
                       CATransform3DMakeScale(0.97, 1.04, 1), CATransform3DIdentity]
        drop.keyTimes = [0, 0.22, 0.62, 1]
        drop.duration = 0.30
        drop.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        pointer.add(drop, forKey: "drop")
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
