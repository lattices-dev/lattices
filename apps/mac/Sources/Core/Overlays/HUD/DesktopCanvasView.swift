import AppKit
import QuartzCore

/// A retained scene: gestures move one camera layer; window images are uploaded
/// once, rather than resampled and redrawn on the main thread every frame.
final class DesktopCanvasView: NSView {
    var model: DesktopCanvasModel
    var images: [UInt32: CGImage] { didSet { updateScene() } }
    var onChange: ((DesktopCanvasModel) -> Void)?
    var onWork: ((UInt32?) -> Void)?
    var onExit: (() -> Void)?
    var stationaryApps: [String] = [] { didSet { updateLabels() } }
    var isBusy = false { didSet { updateLabels() } }
    var message = "Drag windows to arrange · Drag empty canvas or use arrow keys to pan" { didSet { updateLabels() } }
    private let camera = CALayer()
    private let desktopCover = CALayer()
    private let grid = CAShapeLayer()
    private let home = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let chromeView = DesktopCanvasChromeView()
    private let heading = NSTextField(labelWithString: "Arrange windows")
    private let subtitle = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let help = NSTextField(labelWithString: "Drag inside the frame: move screen    ·    Drag outside: look around    ·    Arrows: move screen    ·    − / +: zoom    ·    Enter: work here    ·    Esc: undo")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let waiting = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let pendingExit = NSButton(title: "Undo & return  Esc", target: nil, action: nil)
    private var buttons: [NSButton] = []
    private var tiles: [UInt32: CALayer] = [:]
    private var captions: [UInt32: CATextLayer] = [:]
    private var chrome: CGFloat = 1
    /// Centre of the viewport frame: the area that becomes the real screen.
    private var center: CGPoint
    /// Centre of the camera. It trails the frame, so the world holds still
    /// while you move the frame and only scrolls when the frame nears an edge.
    private var look: CGPoint
    private static let overviewScale: CGFloat = 0.42
    private var scale: CGFloat = DesktopCanvasView.overviewScale
    private var animationID = 0
    private var selected: UInt32?
    private var dragStart = CGPoint.zero
    private var dragOrigin = CGPoint.zero
    private var dragged: UInt32?
    private var panning = false
    private var movingViewport = false
    private var stage: CGRect { CGRect(x: 0, y: 74 * chrome, width: bounds.width, height: max(1, bounds.height - 146 * chrome)) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, model: DesktopCanvasModel, images: [UInt32: CGImage]) {
        self.model = model; self.images = images
        center = CGPoint(x: model.viewport.midX, y: model.viewport.midY)
        look = center
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.068, blue: 0.09, alpha: 1).cgColor
        layer?.masksToBounds = true
        camera.anchorPoint = .zero
        layer?.addSublayer(camera)
        for shape in [grid, home, outline] { shape.fillColor = nil }
        grid.strokeColor = NSColor.white.withAlphaComponent(0.07).cgColor
        home.fillColor = NSColor.white.withAlphaComponent(0.04).cgColor
        home.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        outline.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        camera.addSublayer(grid); camera.addSublayer(home)
        desktopCover.zPosition = 900
        desktopCover.contentsGravity = .resize
        desktopCover.opacity = 0
        camera.addSublayer(desktopCover)
        chromeView.wantsLayer = true
        addSubview(chromeView)
        for label in [heading, subtitle, footer, help, zoomLabel] {
            label.textColor = .white
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            chromeView.addSubview(label)
        }
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .lightGray
        help.font = .systemFont(ofSize: 11); help.textColor = .lightGray
        for (title, action) in [("Undo & return  Esc", #selector(exitAction)), ("Work here  ↩", #selector(workAction)), ("Original area", #selector(homeAction)), ("−", #selector(zoomOutAction)), ("+", #selector(zoomInAction))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            if action == #selector(exitAction) {
                button.keyEquivalent = "\u{1b}"; button.keyEquivalentModifierMask = []
                button.toolTip = "Undo this arrangement and restore every window. Global Return: Control + Command + Up."
            } else if action == #selector(workAction) {
                button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = []
                button.toolTip = "Confirm this arrangement and use real apps at normal size."
            }
            buttons.append(button); chromeView.addSubview(button)
        }
        waiting.wantsLayer = true
        waiting.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        waiting.layer?.cornerRadius = 8
        waiting.textColor = .white; waiting.alignment = .center
        waiting.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(waiting)
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false; addSubview(spinner)
        pendingExit.target = self; pendingExit.action = #selector(exitAction)
        pendingExit.bezelStyle = .rounded; addSubview(pendingExit)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Arrange windows. Arrow keys pan. Enter confirms. Escape undoes and restores the original windows.")
        updateScene(); updateLabels(); setCamera(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        chromeView.frame = bounds
        heading.frame = CGRect(x: 24, y: 17, width: 400, height: 26)
        subtitle.frame = CGRect(x: 24, y: 44, width: max(200, bounds.width - 510), height: 18)
        footer.frame = CGRect(x: 24, y: bounds.height - 56, width: bounds.width - 210, height: 20)
        help.frame = CGRect(x: 24, y: bounds.height - 30, width: bounds.width - 210, height: 18)
        zoomLabel.frame = CGRect(x: bounds.width - 112, y: bounds.height - 48, width: 60, height: 22)
        let rects = [CGRect(x: bounds.width - 212, y: 16, width: 192, height: 34), CGRect(x: bounds.width - 354, y: 16, width: 130, height: 34), CGRect(x: bounds.width - 462, y: 16, width: 96, height: 34), CGRect(x: bounds.width - 154, y: bounds.height - 51, width: 32, height: 28), CGRect(x: bounds.width - 48, y: bounds.height - 51, width: 32, height: 28)]
        for (button, rect) in zip(buttons, rects) { button.frame = rect }
        waiting.frame = CGRect(x: max(0, bounds.midX - 310), y: bounds.height - 84, width: min(620, bounds.width), height: 32)
        spinner.frame = CGRect(x: waiting.frame.minX + 10, y: waiting.frame.minY + 8, width: 16, height: 16)
        pendingExit.frame = CGRect(x: bounds.midX - 90, y: waiting.frame.minY - 40, width: 180, height: 32)
    }

    private func updateLabels() {
        let unavailable = stationaryApps.isEmpty ? "" : " · Stays in place: \(stationaryApps.joined(separator: ", "))"
        subtitle.stringValue = "Current desktop · \(model.items.count) windows\(unavailable)"
        footer.stringValue = message
        zoomLabel.stringValue = "\(Int(scale * 100))%"
        for button in buttons { button.isEnabled = !isBusy || button.action == #selector(exitAction) }
        waiting.stringValue = "\(message)  ·  Esc: undo"
        waiting.isHidden = !isBusy
        pendingExit.isHidden = !isBusy
        if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func replaceModel(_ value: DesktopCanvasModel) {
        model = value
        updateScene(); updateLabels()
    }

    private func updateScene(animateFrames: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animateFrames || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.24)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        let ids = Set(model.items.map(\.id))
        for id in Array(tiles.keys) where !ids.contains(id) {
            tiles.removeValue(forKey: id)?.removeFromSuperlayer(); captions.removeValue(forKey: id)
        }
        let path = CGMutablePath()
        for x in stride(from: floor(model.extent.minX / 400) * 400, through: model.extent.maxX, by: 400) {
            path.move(to: CGPoint(x: x, y: model.extent.minY)); path.addLine(to: CGPoint(x: x, y: model.extent.maxY))
        }
        for y in stride(from: floor(model.extent.minY / 400) * 400, through: model.extent.maxY, by: 400) {
            path.move(to: CGPoint(x: model.extent.minX, y: y)); path.addLine(to: CGPoint(x: model.extent.maxX, y: y))
        }
        grid.path = path
        home.path = CGPath(rect: CGRect(origin: .zero, size: model.viewport.size), transform: nil)
        for (index, item) in model.items.reversed().enumerated() {
            let tile: CALayer
            if let existing = tiles[item.id] { tile = existing } else {
                tile = CALayer(); tile.cornerRadius = 6; tile.masksToBounds = true
                tile.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
                tile.contentsGravity = .resize
                let caption = CATextLayer()
                caption.foregroundColor = NSColor.white.cgColor
                caption.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
                caption.fontSize = 20; caption.contentsScale = 2; caption.truncationMode = .end
                tile.addSublayer(caption); captions[item.id] = caption
                camera.addSublayer(tile); tiles[item.id] = tile
            }
            tile.frame = item.frame; tile.zPosition = CGFloat(index + 1)
            // Avoid replacing an unchanged image (and its GPU backing) during a drag.
            if let image = images[item.id], tile.contents as AnyObject? !== image { tile.contents = image }
            tile.borderColor = (selected == item.id ? NSColor.systemCyan : NSColor.white.withAlphaComponent(0.2)).cgColor
            tile.borderWidth = (selected == item.id ? 2 : 1) / max(scale, 0.06)
            captions[item.id]?.string = "  " + item.title
            captions[item.id]?.frame = CGRect(x: 0, y: 0, width: item.frame.width, height: 28)
            captions[item.id]?.opacity = Float(chrome)
        }
        outline.zPosition = 0
        if outline.superlayer == nil { layer?.addSublayer(outline) }
        CATransaction.commit()
    }

    private var transform: CATransform3D {
        CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: stage.midX - look.x * scale, ty: stage.midY - look.y * scale))
    }

    /// Core Animation runs the motion independently of AX and preview work.
    /// A new key/gesture starts at the presentation transform, so interruptions
    /// and key repeats never jump back to the previous animation's endpoint.
    private func setCamera(animated: Bool, completion: @escaping () -> Void = {}) {
        animationID += 1; let generation = animationID
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.24 : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard self?.animationID == generation else { return }
            completion()
        }
        func change(_ target: CALayer, key: String, value: Any) {
            let from = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
            target.removeAnimation(forKey: key)
            target.setValue(value, forKeyPath: key)
            if duration > 0 {
                let motion = CABasicAnimation(keyPath: key)
                motion.fromValue = from; motion.toValue = value; motion.duration = duration
                motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                target.add(motion, forKey: key)
            }
        }
        change(camera, key: "transform", value: NSValue(caTransform3D: transform))
        let viewport = CGRect(x: stage.midX + (model.viewport.minX - look.x) * scale,
                              y: stage.midY + (model.viewport.minY - look.y) * scale,
                              width: model.viewport.width * scale, height: model.viewport.height * scale)
        change(outline, key: "path", value: CGPath(rect: viewport, transform: nil))
        outline.lineWidth = 1
        if let layer = chromeView.layer { change(layer, key: "opacity", value: Float(chrome)) }
        for layer in [grid, home, outline] { change(layer, key: "opacity", value: Float(chrome)) }
        for caption in captions.values { change(caption, key: "opacity", value: Float(chrome)) }
        CATransaction.commit()
        updateLabels()
    }

    func installDesktopCover(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        desktopCover.frame = model.viewport
        desktopCover.contents = image
        desktopCover.opacity = image == nil ? 0 : 1
        CATransaction.commit()
    }
    func revealWindowPreviews() {
        guard desktopCover.opacity != 0 else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16)
        desktopCover.opacity = 0
        CATransaction.commit()
    }

    func prepareEntrance() {
        look = center; scale = 1; chrome = 0; setCamera(animated: false)
    }
    func animateEntrance() {
        scale = Self.overviewScale; chrome = 1; setCamera(animated: true)
    }
    func animateLanding(completion: @escaping () -> Void) {
        if desktopCover.frame != model.viewport { revealWindowPreviews() }
        // Match macOS boundary clamping during the motion, so the last preview
        // frame and the real native frame agree when the cover comes away.
        let viewport = model.viewport
        let screen = CGRect(origin: .zero, size: viewport.size)
        for index in model.items.indices {
            if let physical = DesktopCanvasModel.physicalFrame(model.items[index].frame, viewport: viewport, screen: screen) {
                model.items[index].frame = DesktopCanvasModel.logicalFrame(physical, viewport: viewport, screen: screen)
            }
        }
        updateScene(animateFrames: true)
        look = center; scale = 1; chrome = 0; setCamera(animated: true, completion: completion)
    }
    func animateReturn(to original: DesktopCanvasModel?, completion: @escaping () -> Void) {
        if let original { model = original; updateScene(animateFrames: true) }
        center = CGPoint(x: model.viewport.midX, y: model.viewport.midY)
        look = center; scale = 1; chrome = 0; setCamera(animated: true, completion: completion)
    }
    func cancelAnimation() {
        animationID += 1
        if let presentation = camera.presentation() {
            let t = presentation.transform
            scale = max(0.06, t.m11)
            look = CGPoint(x: (stage.midX - t.m41) / scale, y: (stage.midY - t.m42) / scale)
        }
        camera.removeAllAnimations(); outline.removeAllAnimations()
        // The frame already holds its logical position; an interrupted move
        // jumps the outline there, so Enter always lands on the frame shown.
        setCamera(animated: false)
    }
    private func world(_ point: CGPoint) -> CGPoint {
        let t = camera.presentation()?.affineTransform() ?? camera.affineTransform()
        return point.applying(t.inverted())
    }
    private func commit(animated: Bool = false) {
        model.expand(); onChange?(model); updateScene(); setCamera(animated: animated)
    }
    private func updateViewport(animated: Bool = false) {
        model.viewport.origin = CGPoint(x: center.x - model.viewport.width / 2, y: center.y - model.viewport.height / 2)
        follow()
        commit(animated: animated)
    }
    /// Scroll the camera only as far as needed to keep the frame on stage.
    /// A frame larger than the stage is centred instead.
    private func follow() {
        let area = stage.insetBy(dx: 32, dy: 32)
        func axis(_ look: CGFloat, min frameMin: CGFloat, length: CGFloat, mid: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            let size = length * scale
            if size >= upper - lower { return frameMin + length / 2 }
            let start = mid + (frameMin - look) * scale
            if start < lower { return look - (lower - start) / scale }
            if start + size > upper { return look + (start + size - upper) / scale }
            return look
        }
        look.x = axis(look.x, min: model.viewport.minX, length: model.viewport.width, mid: stage.midX, lower: area.minX, upper: area.maxX)
        look.y = axis(look.y, min: model.viewport.minY, length: model.viewport.height, mid: stage.midY, lower: area.minY, upper: area.maxY)
    }
    func zoom(by factor: CGFloat, animated: Bool = false) {
        guard !isBusy else { return }
        scale = min(1, max(0.06, scale * factor)); chrome = 1
        follow()
        commit(animated: animated)
    }
    override func mouseDown(with event: NSEvent) {
        guard !isBusy else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard stage.contains(point) else { return }
        let location = world(point)
        revealWindowPreviews()
        cancelAnimation()
        let item = model.items.first { $0.frame.contains(location) }
        if event.clickCount == 2 {
            center = item.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? location
            updateViewport(); onWork?(item?.id); return
        }
        // Empty space inside the frame grabs the frame; outside it grabs the world.
        movingViewport = item == nil && model.viewport.contains(location)
        selected = item?.id; dragged = item?.id; panning = item == nil && !movingViewport
        dragStart = point; dragOrigin = item?.frame.origin ?? (movingViewport ? center : look)
        updateScene()
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isBusy else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - dragStart.x) / scale, dy = (point.y - dragStart.y) / scale
        if let index = model.items.firstIndex(where: { $0.id == dragged }) {
            model.items[index].frame.origin = CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy); commit()
        } else if movingViewport {
            center = CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy); updateViewport()
        } else if panning {
            look = CGPoint(x: dragOrigin.x - dx, y: dragOrigin.y - dy); setCamera(animated: false)
        }
    }
    override func mouseUp(with event: NSEvent) { dragged = nil; panning = false; movingViewport = false }
    override func scrollWheel(with event: NSEvent) {
        guard !isBusy else { return }
        if event.modifierFlags.contains([.control, .command]) { zoom(by: exp(event.scrollingDeltaY * 0.012)) }
        else {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
            // Scrolling looks around; it never moves the frame.
            look.x -= event.scrollingDeltaX * factor / scale
            look.y -= event.scrollingDeltaY * factor / scale
            setCamera(animated: !event.hasPreciseScrollingDeltas)
        }
    }
    override func magnify(with event: NSEvent) { zoom(by: exp(event.magnification)) }
    override func keyDown(with event: NSEvent) {
        guard let action = DesktopCanvasModel.keyAction(code: event.keyCode, flags: event.modifierFlags) else { super.keyDown(with: event); return }
        if action == .exit { onExit?(); return }
        guard !isBusy else { return }
        switch action {
        case .exit: break
        case .work: onWork?(selected)
        case .zoomOut: zoom(by: 1 / 1.2, animated: true)
        case .zoomIn: zoom(by: 1.2, animated: true)
        case .left: center.x -= model.viewport.width * 0.5; updateViewport(animated: true)
        case .right: center.x += model.viewport.width * 0.5; updateViewport(animated: true)
        case .down: center.y += model.viewport.height * 0.5; updateViewport(animated: true)
        case .up: center.y -= model.viewport.height * 0.5; updateViewport(animated: true)
        }
    }
    @objc private func zoomOutAction() { zoom(by: 1 / 1.2, animated: true) }
    @objc private func zoomInAction() { zoom(by: 1.2, animated: true) }
    @objc private func exitAction() { onExit?() }
    @objc private func workAction() { if !isBusy { onWork?(selected) } }
    @objc private func homeAction() {
        guard !isBusy else { return }
        center = CGPoint(x: model.viewport.width / 2, y: model.viewport.height / 2)
        look = center
        chrome = 1; scale = Self.overviewScale; updateViewport(animated: true)
    }
}

/// Let clicks in the canvas pass through the transparent instruction layer.
private final class DesktopCanvasChromeView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }
}
