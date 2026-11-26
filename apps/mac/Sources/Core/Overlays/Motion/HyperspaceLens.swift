import AppKit
import QuartzCore

/// Lens: the light glass the Hyperspace HUD and its layout tray are made of.
/// Values follow the Lens board (Proposal + Detail). Coral marks selection
/// and Apply only; everything else is ink on white glass.
@MainActor
enum Lens {
    nonisolated static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// The one accent. Coral on white glass; amber on graphite, where the
    /// warmer, lighter hue reads as light on the ink rather than as a warning.
    nonisolated static var coral: NSColor { graphite ? amber : srgb(0xef6a47) }
    nonisolated static let amber = srgb(0xf2a93e)
    static var badgeTop: NSColor { graphite ? srgb(0xf8c26a) : srgb(0xf6875f) }
    static var badgeBottom: NSColor { graphite ? srgb(0xe3921f) : srgb(0xe5562f) }
    /// Text and rings that sit on the accent.
    static var onAccent: NSColor { graphite ? deepInk : .white }
    static let inkTop = srgb(0x2c3238)
    static let inkBottom = srgb(0x0f1317)
    /// Graphite: the HUD as an ink tile (#101518 at 82%) with paper text and
    /// white hairlines. Off by default; `defaults write <domain> hyperspace.tone graphite`.
    nonisolated static var graphite: Bool { UserDefaults.standard.string(forKey: "hyperspace.tone") == "graphite" }
    static var appearance: NSAppearance? { NSAppearance(named: graphite ? .darkAqua : .aqua) }
    /// Ink in either tone: the dark brand ink, whatever the surface.
    static let deepInk = srgb(0x101518)
    static let paper = srgb(0xf2f2f2)
    /// The foreground: ink on white glass, paper on graphite.
    static var ink: NSColor { graphite ? paper : deepInk }
    static var muted: NSColor { graphite ? paper.withAlphaComponent(0.5) : srgb(0x6a7078) }
    static var iconTint: NSColor { graphite ? paper.withAlphaComponent(0.6) : srgb(0x5b6168) }
    /// The cool navy every shadow is mixed from.
    static let rim = srgb(0x14182c)
    /// Hairlines: navy on white glass, white on graphite.
    static var hair: NSColor { graphite ? NSColor.white.withAlphaComponent(0.6) : rim }
    static let shade = srgb(0x10142c)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func symbol(_ names: [String], size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                return image
            }
        }
        return nil
    }

    // MARK: Motion

    /// A transform that scales and lifts a layer around its centre, whatever
    /// anchor AppKit gave the view's layer.
    static func centred(_ layer: CALayer, scale: CGFloat, dy: CGFloat = 0) -> CATransform3D {
        let cx = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let cy = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var t = CATransform3DMakeTranslation(cx, cy + dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    static func spring(_ keyPath: String, from: Any, to: Any, damping: CGFloat = 16,
                       stiffness: CGFloat = 260, delay: CFTimeInterval = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.damping = damping
        spring.stiffness = stiffness
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        if delay > 0 {
            spring.beginTime = CACurrentMediaTime() + delay
            spring.fillMode = .backwards
        }
        return spring
    }

    /// Rise, settle and fade in. `dy` is in layer points, positive up.
    static func entrance(_ layer: CALayer?, dy: CGFloat, scale: CGFloat, delay: CFTimeInterval = 0) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 {
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
        }
        layer.add(fade, forKey: "lens.fade")
        guard !reduceMotion else { return }
        let lift = spring("transform", from: NSValue(caTransform3D: centred(layer, scale: scale, dy: -dy)),
                          to: NSValue(caTransform3D: CATransform3DIdentity), damping: 17, stiffness: 240, delay: delay)
        layer.add(lift, forKey: "lens.lift")
    }

    /// A quick bloom: something just became yours.
    static func pop(_ layer: CALayer?, from scale: CGFloat = 0.4, delay: CFTimeInterval = 0) {
        guard let layer, !reduceMotion else { return }
        let bloom = spring("transform", from: NSValue(caTransform3D: centred(layer, scale: scale)),
                           to: NSValue(caTransform3D: CATransform3DIdentity), damping: 11, stiffness: 320, delay: delay)
        layer.add(bloom, forKey: "lens.pop")
    }

    /// One pass of light across a surface, as if it caught the sun.
    static func glint(_ host: CALayer?, delay: CFTimeInterval = 0.12) {
        guard let host, !reduceMotion else { return }
        let band = CAGradientLayer()
        let w = host.bounds.width
        band.frame = CGRect(x: -w * 0.6, y: 0, width: w * 0.5, height: host.bounds.height)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                       NSColor.white.withAlphaComponent(0.42).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: 1, b: 0, c: -0.35, d: 1, tx: 0, ty: 0))
        band.opacity = 0
        host.addSublayer(band)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -w * 0.35
        move.toValue = w * 1.35
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.15, 0.75, 1]
        let group = CAAnimationGroup()
        group.animations = [move, show]
        group.duration = 0.75
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { band.removeFromSuperlayer() }
        band.add(group, forKey: "lens.glint")
        CATransaction.commit()
    }

    // MARK: Identity colour

    private static var identityCache: [String: NSColor] = [:]

    /// A window's own colour, taken from its app's icon: saturated pixels count
    /// most, so Notes reads yellow and a terminal reads near-black ink.
    static func identity(for app: String, icon: NSImage?) -> NSColor {
        if let cached = identityCache[app] { return cached }
        var color = srgb(0x5b6878)
        if let icon, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 14, pixelsHigh: 14,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: CGRect(x: 0, y: 0, width: 14, height: 14), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            // Vote by hue so a multicolour icon picks its loudest colour
            // instead of averaging to mud; greys only win an icon with no hue.
            var buckets = [(r: CGFloat, g: CGFloat, b: CGFloat, w: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
            var grey: (v: CGFloat, w: CGFloat) = (0, 0)
            for x in 1..<13 { for y in 1..<13 {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), px.alphaComponent > 0.5 else { continue }
                let s = px.saturationComponent, v = px.brightnessComponent
                if s < 0.18 || v < 0.18 { grey.v += v; grey.w += 1; continue }
                let i = min(11, Int(px.hueComponent * 12))
                let w = s * v
                buckets[i].r += px.redComponent * w; buckets[i].g += px.greenComponent * w
                buckets[i].b += px.blueComponent * w; buckets[i].w += w
            } }
            if let best = buckets.max(by: { $0.w < $1.w }), best.w > 1.2 {
                let mean = NSColor(srgbRed: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1)
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                mean.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                color = NSColor(hue: h, saturation: min(0.68, max(0.46, s * 0.92)),
                                brightness: min(0.9, max(0.62, v)), alpha: 1)
            } else if grey.w > 0 {
                color = NSColor(hue: 0.58, saturation: 0.08, brightness: min(0.42, max(0.24, grey.v / grey.w * 0.5)), alpha: 1)
            }
        }
        identityCache[app] = color
        return color
    }

    // MARK: Wallpaper

    private static var wallpapers: [String: CGImage] = [:]
    private static var wallpaperLoads: [String: Task<Void, Never>] = [:]
    private static var wallpaperWaiters: [String: [(CGImage?) -> Void]] = [:]

    static func screenKey(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "\(id)"
    }

    /// The configured still for this display, shared by every miniature.
    static func wallpaper(for screen: NSScreen, receive: @escaping (CGImage?) -> Void) {
        let key = screenKey(screen)
        if let image = wallpapers[key] { receive(image); return }
        wallpaperWaiters[key, default: []].append(receive)
        guard wallpaperLoads[key] == nil else { return }
        wallpaperLoads[key] = SpaceCanvasWallpaper.shared.load(for: screen) { image in
            if let cg = image?.cgImage { wallpapers[key] = cg }
            let waiters = wallpaperWaiters.removeValue(forKey: key) ?? []
            wallpaperLoads[key] = nil
            waiters.forEach { $0(image?.cgImage) }
        }
    }
}

// MARK: - Glass

/// Native refraction with a finely etched face and a polished edge. The face
/// adds roughness, not a pale tint that erases the backdrop and edge lighting.
final class LensGlassView: NSView {
    private let glass = NSGlassEffectView()
    private let face = LensGlassFace()
    private let interior = LensPassView()
    let content = LensPassView()
    private(set) var radius: CGFloat
    private var backdrop: NSView?

    /// `graphite` follows the HUD tone. SwiftUI cards drawn for white glass
    /// (Layers, Grid, Map, previews) pass false so their content stays legible.
    init(frame: NSRect, radius: CGFloat, graphite: Bool = Lens.graphite) {
        self.radius = radius
        super.init(frame: frame)
        appearance = NSAppearance(named: graphite ? .darkAqua : .aqua)
        face.graphite = graphite
        if graphite {
            // Graphite follows fab's island: a plain dark blur under a smoked
            // fill, no Liquid Glass lensing. Crisp edges, a little desktop through.
            let blur = NSVisualEffectView(frame: bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            interior.frame = bounds
            interior.autoresizingMask = [.width, .height]
            face.frame = bounds
            face.autoresizingMask = [.width, .height]
            face.radius = radius
            interior.addSubview(face)
            content.frame = bounds
            content.autoresizingMask = [.width, .height]
            interior.addSubview(content)
            blur.addSubview(interior)
            addSubview(blur)
            backdrop = blur
            return
        }
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.tintColor = nil
        glass.cornerRadius = radius
        // The release builds with the macOS 26 SDK. Enable interactive glass
        // when the running AppKit supplies its macOS 27 property.
        if glass.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
            glass.setValue(true, forKey: "effectIsInteractive")
        }
        interior.frame = bounds
        interior.autoresizingMask = [.width, .height]
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        face.radius = radius
        interior.addSubview(face)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        interior.addSubview(content)
        glass.contentView = interior
        addSubview(glass)
    }

    func update(cornerRadius: CGFloat) {
        radius = cornerRadius
        glass.cornerRadius = cornerRadius
        backdrop?.layer?.cornerRadius = cornerRadius
        face.radius = cornerRadius
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A static, subpixel etch. It has no animation, backdrop capture or input
/// handling; the system glass beneath it still supplies the optical effect.
private final class LensGlassFace: NSView {
    var radius: CGFloat = 14 { didSet { needsDisplay = true } }
    var graphite = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let grain: NSImage = {
        let side = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        var seed: UInt32 = 0x485544
        if let bytes = rep.bitmapData {
            for pixel in 0..<(side * side) {
                seed = seed &* 1664525 &+ 1013904223
                let value = UInt8(truncatingIfNeeded: seed >> 24)
                let offset = pixel * 4
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(rep)
        return image
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        shape.addClip()
        // A restrained directional reflection makes the face read as a solid
        // piece of glass even over a nearly white editor window.
        if graphite {
            // fab's island ground (#0a0a0b), smoked.
            Lens.srgb(0x0a0a0b, 0.66).setFill()
            bounds.fill()
        } else {
            NSGradient(colorsAndLocations:
                (NSColor.white.withAlphaComponent(0.15), 0),
                (NSColor.white.withAlphaComponent(0), 0.38),
                (Lens.srgb(0x192d42, 0.09), 1))?.draw(in: bounds, angle: -90)
        }
        if graphite {
            // One white hairline at 8%, and nothing else on the face.
            let pixel = 1 / (window?.backingScaleFactor ?? 2)
            let edge = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
            context.addPath(CGPath(roundedRect: edge, cornerWidth: max(0, radius - pixel / 2),
                                   cornerHeight: max(0, radius - pixel / 2), transform: nil))
            context.setLineWidth(pixel)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            context.strokePath()
            context.restoreGState()
            return
        }
        context.saveGState()
        context.setAlpha(0.035)
        NSColor(patternImage: Self.grain).setFill()
        bounds.fill()
        context.restoreGState()
        let scale = window?.backingScaleFactor ?? 2
        let pixel = 1 / scale
        let edge = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        let edgePath = CGPath(roundedRect: edge, cornerWidth: max(0, radius - pixel / 2),
                              cornerHeight: max(0, radius - pixel / 2), transform: nil)
        context.addPath(edgePath)
        context.setLineWidth(pixel)
        context.setStrokeColor((graphite ? NSColor.white.withAlphaComponent(0.08) : Lens.srgb(0x182a40, 0.38)).cgColor)
        context.strokePath()
        let lip = bounds.insetBy(dx: pixel * 1.5, dy: pixel * 1.5)
        context.addPath(CGPath(roundedRect: lip, cornerWidth: max(0, radius - pixel * 1.5),
                               cornerHeight: max(0, radius - pixel * 1.5), transform: nil))
        context.setLineWidth(pixel)
        context.replacePathWithStrokedPath()
        context.clip()
        NSGradient(starting: NSColor.white.withAlphaComponent(graphite ? 0.10 : 0.9),
                   ending: NSColor.white.withAlphaComponent(graphite ? 0 : 0.12))?.draw(in: bounds, angle: -90)
        context.restoreGState()
    }
}

/// A container whose empty space does not catch the pointer.
class LensPassView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The soft, cool lift under a piece of glass: one deep, wide shadow and one
/// close one. The glass's own shape is cut out so the shadow never shows
/// through it. Never takes the pointer.
final class LensLiftPanel: NSPanel {
    private let deep = CALayer()
    private let near = CALayer()
    private let cutout = CAShapeLayer()
    private let stage = CALayer()
    static let pad: CGFloat = 96

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        contentView = view
        for layer in [deep, near] {
            layer.shadowColor = Lens.shade.cgColor
            layer.shadowOffset = .zero
            stage.addSublayer(layer)
        }
        deep.shadowOpacity = 0.14
        deep.shadowRadius = 14
        near.shadowOpacity = 0.05
        near.shadowRadius = 2
        cutout.fillRule = .evenOdd
        stage.mask = cutout
        view.layer?.addSublayer(stage)
    }

    /// `glass` is the glass panel's screen frame.
    func follow(_ glass: CGRect, radius: CGFloat, level: NSWindow.Level) {
        self.level = level
        let pad = Self.pad
        setFrame(glass.insetBy(dx: -pad, dy: -pad), display: false)
        let local = CGRect(x: pad, y: pad, width: glass.width, height: glass.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: frame.size)
        deep.frame = stage.bounds
        near.frame = stage.bounds
        // CSS spreads (-22, -12) become insets; offsets fall toward the floor.
        let deepRect = local.insetBy(dx: 22, dy: 22).offsetBy(dx: 0, dy: -38)
        let nearRect = local.insetBy(dx: 12, dy: 10).offsetBy(dx: 0, dy: -14)
        deep.shadowPath = CGPath(roundedRect: deepRect, cornerWidth: max(0, radius - 22), cornerHeight: max(0, radius - 22), transform: nil)
        near.shadowPath = CGPath(roundedRect: nearRect, cornerWidth: max(0, radius - 10), cornerHeight: max(0, radius - 10), transform: nil)
        let path = CGMutablePath()
        path.addRect(stage.bounds)
        path.addRoundedRect(in: local, cornerWidth: radius, cornerHeight: radius)
        cutout.frame = stage.bounds
        cutout.path = path
        CATransaction.commit()
    }
}

/// A borderless, non-activating panel that floats one piece of Lens glass.
class LensFloatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    let lift = LensLiftPanel()

    init(identifier: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = Lens.appearance
    }

    func present(_ frame: CGRect, radius: CGFloat) {
        setFrame(frame, display: false)
        lift.follow(frame, radius: radius, level: level)
        lift.alphaValue = alphaValue
        lift.orderFrontRegardless()
        orderFrontRegardless()
    }

    func fadeIn() {
        alphaValue = 0
        lift.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            lift.animator().alphaValue = 1
        }
    }

    override func orderOut(_ sender: Any?) {
        lift.orderOut(sender)
        super.orderOut(sender)
    }
}

// MARK: - Controls

/// Small polished keys share one lighting model. Their shapes stay still;
/// hover brightens the face, press reverses its light, selection keeps a rim.
@MainActor
enum LensKey {
    enum Finish { case neutral, selection, ink, coral }

    static func paint(_ layer: CAGradientLayer, finish: Finish = .neutral,
                      selected: Bool = false, hovered: Bool, pressed: Bool) {
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.cornerCurve = .continuous
        let top: NSColor
        let bottom: NSColor
        let edge: NSColor
        switch finish {
        case .ink where Lens.graphite:
            top = NSColor.white.withAlphaComponent(hovered ? 0.14 : 0.08)
            bottom = NSColor.white.withAlphaComponent(hovered ? 0.09 : 0.04)
            edge = NSColor.white.withAlphaComponent(0.18)
        case .ink:
            top = Lens.srgb(hovered ? 0x465461 : 0x35424e)
            bottom = Lens.srgb(0x17212b)
            edge = Lens.srgb(0x07111b, 0.7)
        case .coral where Lens.graphite:
            top = Lens.srgb(hovered ? 0xffcf7e : 0xf9c066)
            bottom = Lens.srgb(0xe8961f)
            edge = Lens.srgb(0x7a4a0c, 0.7)
        case .coral:
            top = Lens.srgb(hovered ? 0xffa482 : 0xfa9874)
            bottom = Lens.srgb(0xec6946)
            edge = Lens.srgb(0x9c351b, 0.6)
        case .selection where Lens.graphite:
            top = Lens.coral.withAlphaComponent(hovered ? 0.20 : 0.14)
            bottom = Lens.coral.withAlphaComponent(hovered ? 0.14 : 0.08)
            edge = Lens.coral.withAlphaComponent(0.75)
        case .selection:
            top = Lens.srgb(0xfffcf8)
            bottom = Lens.srgb(hovered ? 0xffe0d2 : 0xf4dace)
            edge = Lens.coral.withAlphaComponent(0.75)
        case .neutral where Lens.graphite:
            top = NSColor.white.withAlphaComponent(selected ? 0.16 : (hovered ? 0.11 : 0.04))
            bottom = NSColor.white.withAlphaComponent(selected ? 0.11 : (hovered ? 0.07 : 0.015))
            edge = NSColor.white.withAlphaComponent(selected ? 0.16 : (hovered ? 0.12 : 0.06))
        case .neutral:
            top = NSColor.white.withAlphaComponent(selected ? 0.98 : (hovered ? 0.82 : 0.40))
            bottom = NSColor.white.withAlphaComponent(selected ? 0.74 : (hovered ? 0.48 : 0.12))
            edge = Lens.rim.withAlphaComponent(selected ? 0.25 : (hovered ? 0.23 : 0.14))
        }
        layer.colors = pressed ? [bottom.cgColor, top.blended(withFraction: 0.12, of: Lens.ink)!.cgColor]
                               : [top.cgColor, bottom.cgColor]
        layer.borderWidth = 0.5
        layer.borderColor = edge.cgColor
        layer.shadowColor = Lens.rim.cgColor
        layer.shadowOffset = CGSize(width: 0, height: pressed ? 0 : -1)
        layer.shadowRadius = pressed ? 0 : 1.5
        layer.shadowOpacity = pressed ? 0 : (selected || finish != .neutral ? 0.20 : 0.09)
        let lip: CAShapeLayer
        if let existing = layer.sublayers?.first(where: { $0.name == "lens.key-lip" }) as? CAShapeLayer {
            lip = existing
        } else {
            lip = CAShapeLayer()
            lip.name = "lens.key-lip"
            lip.fillColor = nil
            lip.lineWidth = 0.5
            layer.addSublayer(lip)
        }
        lip.frame = layer.bounds
        let inset: CGFloat = 0.75
        lip.path = CGPath(roundedRect: layer.bounds.insetBy(dx: inset, dy: inset),
                          cornerWidth: max(0, layer.cornerRadius - inset),
                          cornerHeight: max(0, layer.cornerRadius - inset), transform: nil)
        let lipAlpha: CGFloat = pressed ? 0.08 : (finish == .ink ? 0.18 : (Lens.graphite && finish != .coral ? 0.06 : 0.52))
        lip.strokeColor = NSColor.white.withAlphaComponent(lipAlpha).cgColor
    }
}

/// A pressable piece of the HUD. It is a real NSButton (title, press and
/// accessibility come from AppKit) that draws nothing itself: children are
/// the decoration. It dips slightly under the finger and springs back.
class LensControl: NSButton {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Restyle for hover/press. Runs inside an animated transaction.
    var restyle: ((LensControl) -> Void)?
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    // NSButton is flipped; every face here is laid out bottom-up like the glass.
    override var isFlipped: Bool { false }
    private(set) var hovered = false
    private(set) var pressed = false
    private var tracking: NSTrackingArea?

    init(frame: NSRect, label: String) {
        super.init(frame: frame)
        title = label
        isBordered = false
        image = nil
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        (cell as? NSButtonCell)?.highlightsBy = []
        focusRingType = .none
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh(); onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh(); onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        refresh()
        if let layer, !Lens.reduceMotion {
            let dip = Lens.spring("transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                  to: NSValue(caTransform3D: Lens.centred(layer, scale: 0.955)), damping: 22, stiffness: 520)
            dip.fillMode = .forwards
            dip.isRemovedOnCompletion = false
            layer.add(dip, forKey: "lens.press")
        }
        // AppKit's tracking loop; the action fires on a release inside.
        super.mouseDown(with: event)
        pressed = false
        refresh()
        if let layer {
            let from = layer.presentation()?.transform ?? Lens.centred(layer, scale: 0.955)
            layer.removeAnimation(forKey: "lens.press")
            if !Lens.reduceMotion {
                layer.add(Lens.spring("transform", from: NSValue(caTransform3D: from),
                                      to: NSValue(caTransform3D: CATransform3DIdentity), damping: 10, stiffness: 380), forKey: "lens.release")
            }
        }
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        restyle?(self)
        CATransaction.commit()
    }
}

/// Paints into a layer-backed view's own sublayer so implicit animations run.
extension NSView {
    func lensLayer() -> CALayer {
        wantsLayer = true
        return layer!
    }
}

/// The numbered coral bead: a gradient, a white ring, a warm drop.
final class LensBadge: NSView {
    init(number: Int, diameter: CGFloat, ring: NSColor = .white) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter + 3, height: diameter + 3))
        wantsLayer = true
        let host = layer!
        host.masksToBounds = false
        let ringLayer = CALayer()
        ringLayer.frame = bounds
        ringLayer.cornerRadius = bounds.width / 2
        ringLayer.backgroundColor = (Lens.graphite ? Lens.deepInk : ring).withAlphaComponent(0.95).cgColor
        ringLayer.shadowColor = Lens.srgb(0x962d0f).cgColor
        ringLayer.shadowOpacity = 0
        ringLayer.shadowRadius = 0
        host.addSublayer(ringLayer)
        let bead = CAGradientLayer()
        bead.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
        bead.cornerRadius = diameter / 2
        bead.colors = [Lens.badgeTop.cgColor, Lens.badgeBottom.cgColor]
        bead.startPoint = CGPoint(x: 0.5, y: 1)
        bead.endPoint = CGPoint(x: 0.5, y: 0)
        host.addSublayer(bead)
        let gloss = CALayer()
        gloss.frame = CGRect(x: bead.frame.minX + diameter * 0.2, y: bead.frame.maxY - 1.5, width: diameter * 0.6, height: 0.75)
        gloss.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        gloss.cornerRadius = 0.4
        host.addSublayer(gloss)
        let text = CATextLayer()
        let size = diameter * 0.6
        text.string = "\(number)"
        text.font = Lens.font(size, .bold)
        text.fontSize = size
        text.alignmentMode = .center
        text.foregroundColor = Lens.onAccent.cgColor
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        text.frame = CGRect(x: bead.frame.minX, y: bead.frame.midY - size * 0.62, width: diameter, height: size * 1.24)
        host.addSublayer(text)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Lattices mark: an ink lattice with a coral centre.
final class LensMarkView: NSView {
    /// The grid's ink strength; the centre stays full coral.
    var inkAlpha: CGFloat = 1
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let unit = bounds.width / 20
        for row in 0..<3 { for col in 0..<3 {
            let rect = CGRect(x: (2 + CGFloat(col) * 5.75) * unit, y: (2 + CGFloat(row) * 5.75) * unit,
                              width: 4.5 * unit, height: 4.5 * unit)
            (row == 1 && col == 1 ? Lens.coral : Lens.ink.withAlphaComponent(inkAlpha)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.2 * unit, yRadius: 1.2 * unit).fill()
        } }
    }
}

/// A window in miniature: its cached capture, or its colour and app icon.
final class LensThumbView: NSView {
    let wid: UInt32
    let icon: NSImage?
    let tint: NSColor
    var dim = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(frame: NSRect, wid: UInt32, icon: NSImage?, tint: NSColor) {
        self.wid = wid
        self.icon = icon
        self.tint = tint
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = Lens.rim.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 2.5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(7, bounds.height * 0.21)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if wid != 0, let image = WindowPreviewStore.shared.image(for: wid), image.size.width > 0 {
            NSColor.white.setFill()
            bounds.fill()
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: dim ? 0.72 : 1, respectFlipped: true, hints: nil)
        } else {
            let top = tint.blended(withFraction: 0.18, of: .white) ?? tint
            NSGradient(starting: top, ending: tint)?.draw(in: bounds, angle: 90)
            if let icon {
                let side = min(bounds.height - 8, 22)
                icon.draw(in: CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: dim ? 0.7 : 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

/// A screen in miniature: the real wallpaper with windows laid on it.
/// Geometry is AX top-left, matching HyperspaceLayoutPlan.
final class LensScreenView: NSView {
    struct Block {
        let frame: CGRect
        let number: Int?
        let color: NSColor?
    }
    var area: CGRect = .zero
    var blocks: [Block] = [] { didSet { needsDisplay = true } }
    var guides = false
    var glow = true
    var blockRadius: CGFloat = 2
    var numeralSize: CGFloat = 7
    /// A flat tint and borderless blocks, for small instrument-like maps.
    var plain = false
    var plainFill = Lens.ink.withAlphaComponent(0.05)
    var plainEdge = Lens.ink.withAlphaComponent(0.16)
    var plainRadius: CGFloat?
    /// A hairline around each block, so neighbours stay apart.
    var blockStroke: NSColor?
    private var wallpaper: CGImage?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func load(for screen: NSScreen) {
        Lens.wallpaper(for: screen) { [weak self] image in
            self?.wallpaper = image
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = plain ? (plainRadius ?? min(9, bounds.height * 0.12)) : min(9, bounds.height * 0.12)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if plain {
            plainFill.setFill()
            bounds.fill()
        } else if let wallpaper, let context = NSGraphicsContext.current?.cgContext {
            let w = CGFloat(wallpaper.width), h = CGFloat(wallpaper.height)
            let scale = max(bounds.width / w, bounds.height / h)
            let size = CGSize(width: w * scale, height: h * scale)
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(wallpaper, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                               width: size.width, height: size.height))
            context.restoreGState()
        } else {
            NSGradient(starting: Lens.srgb(0xd9dde6), ending: Lens.srgb(0xb7bfd0))?.draw(in: bounds, angle: -70)
        }
        if guides {
            NSColor.white.withAlphaComponent(0.4).setFill()
            CGRect(x: bounds.midX - 0.25, y: 3, width: 0.5, height: bounds.height - 6).fill()
            CGRect(x: 3, y: bounds.midY - 0.25, width: bounds.width - 6, height: 0.5).fill()
        }
        guard area.width > 0, area.height > 0 else { NSGraphicsContext.restoreGraphicsState(); return }
        let sx = bounds.width / area.width, sy = bounds.height / area.height
        func map(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - area.minX) * sx, y: (rect.minY - area.minY) * sy,
                   width: rect.width * sx, height: rect.height * sy).insetBy(dx: plain ? 1 : 0.6, dy: plain ? 1 : 0.6)
        }
        // Plain windows first, so the chosen ones always sit on top.
        for block in blocks where block.number == nil {
            let rect = map(block.frame)
            let path = NSBezierPath(roundedRect: rect, xRadius: blockRadius, yRadius: blockRadius)
            (block.color ?? NSColor.white.withAlphaComponent(0.82)).setFill()
            path.fill()
            if let stroke = blockStroke {
                stroke.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            } else if !plain {
                NSColor.black.withAlphaComponent(0.16).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        }
        for block in blocks where block.number != nil {
            let rect = map(block.frame)
            let path = NSBezierPath(roundedRect: rect, xRadius: blockRadius, yRadius: blockRadius)
            let fill = block.color ?? Lens.coral
            NSGraphicsContext.saveGraphicsState()
            if glow {
                let shadow = NSShadow()
                shadow.shadowColor = Lens.coral.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = .zero
                shadow.set()
            }
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            let top = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, 1.2)),
                                   xRadius: 0.6, yRadius: 0.6)
            NSColor.white.withAlphaComponent(0.35).setFill()
            top.fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if let number = block.number, rect.height >= numeralSize + 2, rect.width >= numeralSize + 2 {
                let text = NSAttributedString(string: "\(number)", attributes: [
                    .font: Lens.font(numeralSize, .bold), .foregroundColor: NSColor.white,
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        (plain ? plainEdge : NSColor.black.withAlphaComponent(0.26)).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

/// A recessed well: a faint navy tint, darker at the top lip, a white lower
/// lip where light catches the edge.
@MainActor
func lensWell(_ frame: CGRect, radius: CGFloat) -> NSView {
    let well = LensPassView(frame: frame)
    well.wantsLayer = true
    let layer = well.layer!
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    layer.masksToBounds = false
    let fill = CAGradientLayer()
    fill.frame = well.bounds
    fill.cornerRadius = radius
    fill.cornerCurve = .continuous
    fill.colors = [Lens.hair.withAlphaComponent(0.1).cgColor, Lens.hair.withAlphaComponent(0.05).cgColor]
    fill.locations = [0, 0.3]
    fill.startPoint = CGPoint(x: 0.5, y: 1)
    fill.endPoint = CGPoint(x: 0.5, y: 0)
    fill.borderWidth = 0.5
    fill.borderColor = Lens.hair.withAlphaComponent(0.08).cgColor
    layer.addSublayer(fill)
    let lip = CAShapeLayer()
    let lipPath = CGMutablePath()
    lipPath.addRoundedRect(in: well.bounds.offsetBy(dx: 0, dy: -1), cornerWidth: radius, cornerHeight: radius)
    lipPath.addRoundedRect(in: well.bounds, cornerWidth: radius, cornerHeight: radius)
    lip.path = lipPath
    lip.fillRule = .evenOdd
    lip.fillColor = NSColor.white.withAlphaComponent(0.85).cgColor
    layer.addSublayer(lip)
    return well
}

@MainActor
func lensLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
               frame: CGRect, align: NSTextAlignment = .left) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Lens.font(size, weight)
    label.textColor = color
    label.alignment = align
    label.lineBreakMode = .byTruncatingTail
    // NSTextField insets its text 2pt each side; widen the frame so a
    // measured string fits whole and still starts where the caller put it.
    let pad: CGFloat = 3
    switch align {
    case .center: label.frame = frame.insetBy(dx: -pad, dy: 0)
    case .right: label.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width + pad, height: frame.height)
    default: label.frame = CGRect(x: frame.minX - 2, y: frame.minY, width: frame.width + pad + 2, height: frame.height)
    }
    label.isSelectable = false
    label.refusesFirstResponder = true
    return label
}

final class LensImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
