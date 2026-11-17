import AppKit
import QuartzCore

@MainActor
final class PlyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PlyView: NSView {
    let atlas: PlyAtlas
    private(set) var pose: PlyPose = .rest
    private let current = CALayer()
    private let outgoing = CALayer()
    private var tracking: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDrop: (() -> Void)?
    var onContext: ((NSEvent, NSView) -> Void)?
    private var drag: PlyDrag?
    var reduceMotion = false {
        didSet {
            if reduceMotion {
                current.removeAllAnimations()
                outgoing.removeAllAnimations()
            }
        }
    }

    init(atlas: PlyAtlas) {
        self.atlas = atlas
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        wantsLayer = true
        layer?.addSublayer(current)
        layer?.addSublayer(outgoing)
        for item in [current, outgoing] {
            item.contentsGravity = .resizeAspect
            item.magnificationFilter = .linear
            item.minificationFilter = .trilinear
        }
        outgoing.opacity = 0
        current.contents = atlas.frames[0]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ply")
        toolTip = "Click to switch workspace · Drag to move"
        setAccessibilityHelp("Click to switch Lattices workspaces. Drag to move. Right-click for hello, size, expressions, hide, and quit.")
        setAccessibilityValue(pose.title)
    }

    required init?(coder: NSCoder) { fatalError("Use init(atlas:)") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.frame = bounds; outgoing.frame = bounds
        current.contentsScale = window?.backingScaleFactor ?? 2
        outgoing.contentsScale = current.contentsScale
        CATransaction.commit()
    }

    func show(_ next: PlyPose, bounce: Bool = false) {
        if next != pose {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outgoing.removeAllAnimations()
            outgoing.contents = current.contents
            outgoing.opacity = 0
            current.contents = atlas.frames[next.rawValue]
            pose = next
            CATransaction.commit()
            if !reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.14
                outgoing.add(fade, forKey: "whole-frame-fade")
            }
            setAccessibilityValue(next.title)
        }
        if bounce && !reduceMotion {
            let greeting = CAKeyframeAnimation(keyPath: "transform.translation.y")
            greeting.values = [0, 4, 0]; greeting.keyTimes = [0, 0.4, 1]; greeting.duration = 0.36
            current.add(greeting, forKey: "greeting")
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point),
              atlas.alpha(at: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height), pose: pose) > 0.08 else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { if drag == nil { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { if drag == nil { onHover?(false) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        guard let window else { return }
        beginDrag(at: window.convertPoint(toScreen: event.locationInWindow), origin: window.frame.origin)
    }
    func beginDrag(at point: CGPoint, origin: CGPoint) { drag = PlyDrag(pointer: point, origin: origin) }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        continueDrag(to: window.convertPoint(toScreen: event.locationInWindow))
    }
    func continueDrag(to point: CGPoint) {
        guard var gesture = drag else { return }
        let wasMoving = gesture.moved
        let origin = gesture.update(point)
        drag = gesture
        if let origin {
            if !wasMoving { NSCursor.closedHand.set(); onDragStart?() }
            window?.setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) { endDrag() }
    func endDrag() {
        guard let gesture = drag else { return }
        drag = nil
        NSCursor.openHand.set()
        if gesture.moved { onDrop?() } else { onPress?() }
    }
    override func rightMouseDown(with event: NSEvent) { onContext?(event, self) }
}
