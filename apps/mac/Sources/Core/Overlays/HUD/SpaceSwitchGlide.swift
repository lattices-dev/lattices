import AppKit
import QuartzCore

/// Gives an instant Space switch a hint of the system slide without playing
/// it: two quiet trails at the pointer, easing the way the content travels
/// and dissolving. Nothing is captured and nothing covers
/// the desktop, so the switch stays a clean cut.
///
/// Main-thread only.
final class SpaceSwitchGlide {
    static let shared = SpaceSwitchGlide()

    private var panel: NSPanel?
    private var streaks: [CAGradientLayer] = []
    /// Bumped on every fire so a stale completion can't order out a newer one.
    private var generation = 0

    private static let panelSize = CGSize(width: 360, height: 120)
    /// Fixed lanes (y offset from the pointer, length, delay) so the pattern
    /// reads as one gesture rather than noise.
    private static let lanes: [(y: CGFloat, length: CGFloat, delay: CFTimeInterval)] = [
        (10, 58, 0.000),
        (-10, 42, 0.016),
    ]

    /// Optional pointer echo; the filmstrip handles navigation feedback.
    /// Reduce Motion suppresses this spatial cue.
    var isEnabled: Bool {
        Preferences.shared.spaceSwitchGlideEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `direction` is the Space direction (+1 = next). `steps` is how many
    /// Spaces the press travelled; bursts merge, so a bigger jump throws
    /// farther.
    func fire(direction: Int, steps: Int) {
        guard isEnabled else { return }
        generation &+= 1
        let mine = generation
        let p = panel ?? makePanel()

        let pointer = NSEvent.mouseLocation
        let size = Self.panelSize
        p.setFrame(CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2,
                          width: size.width, height: size.height), display: false)

        // Content moves opposite the Space direction, like a real swipe.
        let heading = -CGFloat(direction)
        let throwScale = CGFloat(min(max(steps, 1), 3))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, lane) in zip(streaks, Self.lanes) {
            layer.removeAllAnimations()
            layer.bounds = CGRect(x: 0, y: 0, width: lane.length, height: 1.5)
            // Start just behind the pointer so the streaks pass through it.
            layer.position = CGPoint(x: center.x - heading * 22, y: center.y + lane.y)
            // Bright head on the leading side, tail trailing behind it.
            layer.startPoint = CGPoint(x: heading < 0 ? 1 : 0, y: 0.5)
            layer.endPoint = CGPoint(x: heading < 0 ? 0 : 1, y: 0.5)
            layer.opacity = 0
        }
        CATransaction.commit()

        p.alphaValue = 1
        if !p.isVisible { p.orderFrontRegardless() }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panel?.orderOut(nil)
        }
        let now = CACurrentMediaTime()
        for (layer, lane) in zip(streaks, Self.lanes) {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = 0
            move.toValue = heading * (62 + 14 * (throwScale - 1))
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.65, 0]
            flash.keyTimes = [0, 0.18, 1]

            let group = CAAnimationGroup()
            group.animations = [move, flash]
            group.duration = 0.24
            group.beginTime = now + lane.delay
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "streak")
        }
        CATransaction.commit()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        for _ in Self.lanes {
            let layer = CAGradientLayer()
            layer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.55).cgColor,
                NSColor.white.withAlphaComponent(0.95).cgColor,
            ]
            layer.locations = [0, 0.7, 1]
            layer.cornerRadius = 1
            // Soft dark halo keeps the streaks legible on light windows.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
            layer.opacity = 0
            view.layer?.addSublayer(layer)
            streaks.append(layer)
        }
        p.contentView = view
        panel = p
        return p
    }
}
