import AppKit

/// The landing plate for Command-drag and Hyperspace. One plate morphs between
/// targets. A set of plates previews a split, and a held plate is the same
/// outline with a deeper fill.
final class WindowHoverPreview {
    static let shared = WindowHoverPreview()
    private let windowLevel: NSWindow.Level

    init(level: NSWindow.Level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))) {
        windowLevel = level
    }

    private var overlayWindow: NSWindow?
    private var plate: CALayer?
    private var blurView: NSVisualEffectView?
    private var visuallyPresent = false
    private var currentTarget: NSRect = .null
    private var generation: UInt64 = 0
    private var autoHideWork: DispatchWorkItem?
    private var stickyUntil: CFTimeInterval = 0
    private var groupPlates: [CALayer] = []
    private var groupLabels: [CATextLayer] = []

    private let plateInset: CGFloat = 3
    private let shadowPad: CGFloat = 28
    private let morphDuration: CFTimeInterval = 0.10
    private let revealDuration: CFTimeInterval = 0.08
    private let dismissDuration: CFTimeInterval = 0.06
    private let cornerRadius: CGFloat = plateCornerRadius

    /// Shared with Hyperspace landing spots so a suggested frame reads as the
    /// same plate Command-drag draws around a window.
    static let plateFill = NSColor(calibratedWhite: 0.28, alpha: 0.46)
    static let plateStroke = NSColor(calibratedWhite: 1.0, alpha: 0.78)
    static let plateBorderWidth: CGFloat = 2
    static let plateFillHeld = NSColor(calibratedWhite: 0.48, alpha: 0.62)
    static let plateStrokeHeld = NSColor(calibratedWhite: 1, alpha: 0.95)
    static let plateBorderWidthHeld: CGFloat = 2.5
    static let plateCornerRadius: CGFloat = 10
    private static let fillColor = plateFill.cgColor
    private static let strokeColor = plateStroke.cgColor
    /// Frosted (Ctrl+Option pointer tiling): blur carries the shape, so the
    /// tint gets more opaque and the border drops to a hairline.
    private static let frostedFillColor = NSColor(calibratedWhite: 0.24, alpha: 0.55).cgColor
    private static let frostedStrokeColor = NSColor(calibratedWhite: 1.0, alpha: 0.30).cgColor
    private static let standardBorderWidth: CGFloat = plateBorderWidth
    private static let frostedBorderWidth: CGFloat = 1
    private static let morphTiming = CAMediaTimingFunction(controlPoints: 0.16, 1.00, 0.30, 1.00)
    enum PlateStyle {
        case standard
        case frosted
    }

    /// Several landing spots at once. Hyperspace uses this for a split, and
    /// passes `held` once the drag has been released. Command-drag keeps the
    /// single morphing plate from `show(frame:)`.
    func show(_ frames: [(CGRect, String)], held: Bool, guides: [(CGRect, String)] = []) {
        autoHideWork?.cancel()
        autoHideWork = nil
        stickyUntil = 0
        generation += 1
        let spots = guides.filter {
            $0.0.insetBy(dx: plateInset, dy: plateInset).width > 8
                && $0.0.insetBy(dx: plateInset, dy: plateInset).height > 8
        }.map { (rect: $0.0, title: $0.1, guide: true) }
        let usable = spots + frames.filter {
            $0.0.insetBy(dx: plateInset, dy: plateInset).width > 8
                && $0.0.insetBy(dx: plateInset, dy: plateInset).height > 8
        }.map { (rect: $0.0, title: $0.1, guide: false) }
        guard !usable.isEmpty else {
            clear()
            return
        }

        let (window, primary) = ensureWindow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primary.opacity = 0
        blurView?.isHidden = true
        if groupPlates.count != usable.count {
            removeGroupPlates()
            groupPlates = usable.map { _ in makeGroupPlate() }
            groupLabels = groupPlates.map { plate in
                let label = makeGroupLabel()
                plate.addSublayer(label)
                return label
            }
            if let host = window.contentView?.layer {
                groupPlates.forEach { host.addSublayer($0) }
            }
        }
        let union = usable.reduce(CGRect.null) { partial, item in
            partial.union(item.rect.insetBy(dx: plateInset, dy: plateInset))
        }
        placeWindow(window, frame: paddedRect(union))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        for index in usable.indices {
            let item = usable[index]
            let target = item.rect.insetBy(dx: plateInset, dy: plateInset)
            let plate = groupPlates[index]
            let label = groupLabels[index]
            plate.frame = layerRect(target, in: window)
            plate.contentsScale = scale
            applyGroupStyle(held && !item.guide, guide: item.guide, to: plate)
            label.string = item.title
            label.contentsScale = scale
            label.foregroundColor = NSColor.white.withAlphaComponent(item.guide ? 0.72 : (held ? 0.96 : 0.82)).cgColor
            label.frame = CGRect(x: 12, y: max(0, plate.bounds.height - 28), width: max(1, plate.bounds.width - 24), height: 16)
            plate.opacity = 1
        }
        CATransaction.commit()
        window.orderFrontRegardless()
        currentTarget = union
        visuallyPresent = true
    }

    func show(frame windowFrame: NSRect, autoHideAfter: TimeInterval? = nil, style: PlateStyle = .standard) {
        removeGroupPlates()
        let target = windowFrame.insetBy(dx: plateInset, dy: plateInset)
        guard target.width > 8, target.height > 8 else { return }

        autoHideWork?.cancel()
        autoHideWork = nil
        stickyUntil = autoHideAfter.map { CACurrentMediaTime() + $0 } ?? 0
        generation += 1
        let (window, plate) = ensureWindow()
        applyStyle(style, to: plate)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if visuallyPresent, similar(currentTarget, target) {
            scheduleAutoHide(autoHideAfter)
            return
        }

        DiagnosticLog.shared.info(
            "HoverPreview: show frame=\(Int(target.width))x\(Int(target.height)) @(\(Int(target.minX)),\(Int(target.minY))) morph=\(visuallyPresent) reduceMotion=\(reduceMotion)"
        )

        if visuallyPresent, !reduceMotion {
            morph(window: window, plate: plate, to: target, generation: generation)
        } else {
            reveal(window: window, plate: plate, at: target, reduceMotion: reduceMotion)
        }
        window.orderFrontRegardless()

        currentTarget = target
        visuallyPresent = true
        scheduleAutoHide(autoHideAfter)
    }

    func hide(immediately: Bool = false) {
        if !immediately, CACurrentMediaTime() < stickyUntil { return }
        autoHideWork?.cancel()
        autoHideWork = nil
        stickyUntil = 0
        guard visuallyPresent || overlayWindow?.isVisible == true else { return }
        generation += 1
        let gen = generation
        currentTarget = .null

        guard let plate, !immediately else {
            snapHide()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(dismissDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == gen else { return }
            self.snapHide()
        }
        plate.opacity = 0
        CATransaction.commit()
    }

    func clear() {
        autoHideWork?.cancel()
        autoHideWork = nil
        stickyUntil = 0
        generation += 1
        removeGroupPlates()
        snapHide()
        overlayWindow?.close()
        overlayWindow = nil
        plate = nil
        blurView = nil
    }

    private func scheduleAutoHide(_ delay: TimeInterval?) {
        guard let delay else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyStyle(_ style: PlateStyle, to plate: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .standard:
            blurView?.isHidden = true
            plate.backgroundColor = Self.fillColor
            plate.borderColor = Self.strokeColor
            plate.borderWidth = Self.standardBorderWidth
        case .frosted:
            blurView?.isHidden = false
            plate.backgroundColor = Self.frostedFillColor
            plate.borderColor = Self.frostedStrokeColor
            plate.borderWidth = Self.frostedBorderWidth
        }
        CATransaction.commit()
    }

    /// Plate and blur backdrop share every frame change so the frosted
    /// glass tracks the tint exactly through reveals and morphs.
    private func setPlateFrame(_ rect: NSRect, on plate: CALayer) {
        plate.frame = rect
        blurView?.frame = rect
    }

    private func snapHide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate?.opacity = 0
        plate?.transform = CATransform3DIdentity
        CATransaction.commit()
        overlayWindow?.orderOut(nil)
        visuallyPresent = false
        currentTarget = .null
    }

    private func ensureWindow() -> (NSWindow, CALayer) {
        if let overlayWindow, let plate { return (overlayWindow, plate) }

        let host = HoverPreviewHostView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.masksToBounds = false

        // Frosted backdrop: blurs whatever sits behind the overlay window.
        let blur = NSVisualEffectView()
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.isHidden = true
        host.addSubview(blur, positioned: .below, relativeTo: nil)

        let plate = CALayer()
        plate.cornerRadius = cornerRadius
        plate.cornerCurve = .continuous
        plate.backgroundColor = Self.fillColor
        plate.borderWidth = Self.standardBorderWidth
        plate.borderColor = Self.strokeColor
        plate.zPosition = 1
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowOpacity = 0.28
        plate.shadowRadius = 16
        plate.shadowOffset = CGSize(width: 0, height: -2)
        plate.opacity = 0
        plate.allowsEdgeAntialiasing = true
        host.layer?.addSublayer(plate)

        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = windowLevel
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.sharingType = .readOnly
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 1

        self.overlayWindow = window
        self.plate = plate
        self.blurView = blur
        return (window, plate)
    }

    private func reveal(window: NSWindow, plate: CALayer, at target: NSRect, reduceMotion: Bool) {
        let padded = paddedRect(target)
        placeWindow(window, frame: padded)
        refreshScale(plate)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setPlateFrame(layerRect(target, in: window), on: plate)
        plate.transform = reduceMotion
            ? CATransform3DIdentity
            : CATransform3DMakeScale(0.96, 0.96, 1)
        plate.opacity = 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0.07 : revealDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        plate.opacity = 1
        plate.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func morph(window: NSWindow, plate: CALayer, to target: NSRect, generation: UInt64) {
        let visual = plate.presentation() ?? plate
        let currentScreen = visual.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        let union = paddedRect(currentScreen.union(target))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeWindow(window, frame: union)
        setPlateFrame(currentScreen.offsetBy(dx: -union.minX, dy: -union.minY), on: plate)
        plate.transform = CATransform3DIdentity
        plate.opacity = 1
        CATransaction.commit()

        let dest = target.offsetBy(dx: -union.minX, dy: -union.minY)
        CATransaction.begin()
        CATransaction.setAnimationDuration(morphDuration)
        CATransaction.setAnimationTimingFunction(Self.morphTiming)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == generation, self.visuallyPresent else { return }
            self.tighten(to: target)
        }
        setPlateFrame(dest, on: plate)
        plate.opacity = 1
        CATransaction.commit()
    }

    private func tighten(to target: NSRect) {
        guard let window = overlayWindow, let plate else { return }
        let padded = paddedRect(target)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeWindow(window, frame: padded)
        setPlateFrame(layerRect(target, in: window), on: plate)
        CATransaction.commit()
    }

    private func placeWindow(_ window: NSWindow, frame: NSRect) {
        window.setFrame(frame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func layerRect(_ screenRect: NSRect, in window: NSWindow) -> NSRect {
        screenRect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private func paddedRect(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: -shadowPad, dy: -shadowPad)
    }

    private func refreshScale(_ plate: CALayer) {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        plate.contentsScale = scale
        overlayWindow?.contentView?.layer?.contentsScale = scale
        blurView?.layer?.contentsScale = scale
    }

    private func makeGroupPlate() -> CALayer {
        let plate = CALayer()
        plate.cornerRadius = cornerRadius
        plate.cornerCurve = .continuous
        plate.zPosition = 2
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowRadius = 16
        plate.shadowOffset = CGSize(width: 0, height: -2)
        plate.allowsEdgeAntialiasing = true
        applyGroupStyle(false, guide: false, to: plate)
        return plate
    }

    private func makeGroupLabel() -> CATextLayer {
        let label = CATextLayer()
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.alignmentMode = .left
        label.truncationMode = .end
        label.contentsScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return label
    }

    private func applyGroupStyle(_ held: Bool, guide: Bool, to plate: CALayer) {
        if guide {
            plate.backgroundColor = Self.plateFill.withAlphaComponent(0.22).cgColor
            plate.borderColor = Self.plateStroke.withAlphaComponent(0.55).cgColor
            plate.borderWidth = 1.5
            plate.shadowOpacity = 0
            return
        }
        plate.backgroundColor = (held ? Self.plateFillHeld : Self.plateFill).cgColor
        plate.borderColor = (held ? Self.plateStrokeHeld : Self.plateStroke).cgColor
        plate.borderWidth = held ? Self.plateBorderWidthHeld : Self.plateBorderWidth
        plate.shadowOpacity = held ? 0.36 : 0.28
    }

    private func removeGroupPlates() {
        groupPlates.forEach { $0.removeFromSuperlayer() }
        groupPlates.removeAll()
        groupLabels.removeAll()
    }

    private func similar(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.midX - b.midX) < 1.5
            && abs(a.midY - b.midY) < 1.5
            && abs(a.width - b.width) < 1.5
            && abs(a.height - b.height) < 1.5
    }
}

private final class HoverPreviewHostView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

