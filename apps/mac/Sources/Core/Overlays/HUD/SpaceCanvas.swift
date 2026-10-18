import AppKit
import QuartzCore

/// Detail is distance-based: begin revealing one 1.2× zoom from full size.
/// A small lead gives the asynchronous still capture time to arrive.
enum SpaceCanvasDetail {
    static let prepareRatio: CGFloat = 0.65
    static func opacity(scale: CGFloat, fillScale: CGFloat) -> Float {
        guard fillScale > 0 else { return 0 }
        let start: CGFloat = 1 / 1.2
        let t = min(1, max(0, (scale / fillScale - start) / (0.98 - start)))
        return Float(t * t * (3 - 2 * t))
    }
}

/// The camera over the canvas: which world point sits at the stage's
/// centre, and how many points one desktop width spans.
struct SpaceCanvasCamera: Equatable {
    var center: CGPoint
    var scale: CGFloat

    /// Advance by a zoom ratio along the same fixed-point path as a glide.
    /// A held key supplies distance each display frame, not a future endpoint.
    func advanced(toward goal: Self, logarithmicDelta: Double) -> Self {
        let distance = log(goal.scale / scale)
        guard abs(distance) > 0.000001 else { return goal }
        guard distance * logarithmicDelta > 0 else { return self }
        if abs(logarithmicDelta) >= abs(distance) { return goal }
        let nextScale = scale * exp(logarithmicDelta)
        let fixed = CGPoint(x: (center.x * scale - goal.center.x * goal.scale) / (scale - goal.scale),
                            y: (center.y * scale - goal.center.y * goal.scale) / (scale - goal.scale))
        return Self(center: CGPoint(x: fixed.x - (fixed.x - center.x) * scale / nextScale,
                                    y: fixed.y - (fixed.y - center.y) * scale / nextScale), scale: nextScale)
    }

    /// The path a camera travels between two views. Matrix interpolation
    /// changes scale linearly, so a zoom-in rushes its start and a zoom-out
    /// its end, and the content swings off the point it zooms about. Here
    /// scale moves at a constant ratio and the one world point both views
    /// show at the same screen position stays put, so equal time reads as
    /// equal zoom. A pure pan, with no fixed point, moves in a straight line.
    static func path(from a: SpaceCanvasCamera, to b: SpaceCanvasCamera, steps: Int) -> [SpaceCanvasCamera] {
        let steps = max(1, steps)
        let ratio = b.scale / a.scale
        guard a.scale > 0, b.scale > 0, abs(log(ratio)) > 0.002 else {
            return (0...steps).map { i in
                let u = CGFloat(i) / CGFloat(steps)
                return SpaceCanvasCamera(center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * u,
                                                         y: a.center.y + (b.center.y - a.center.y) * u),
                                         scale: a.scale + (b.scale - a.scale) * u)
            }
        }
        // The world point that maps to the same screen point in both views.
        let fixed = CGPoint(x: (a.center.x * a.scale - b.center.x * b.scale) / (a.scale - b.scale),
                            y: (a.center.y * a.scale - b.center.y * b.scale) / (a.scale - b.scale))
        return (0...steps).map { i in
            if i == 0 { return a }
            if i == steps { return b }
            let s = a.scale * pow(ratio, CGFloat(i) / CGFloat(steps))
            let k = a.scale / s
            return SpaceCanvasCamera(center: CGPoint(x: fixed.x - (fixed.x - a.center.x) * k,
                                                     y: fixed.y - (fixed.y - a.center.y) * k), scale: s)
        }
    }
}

/// Pure geometry for the desktop canvas. One desktop is one world unit
/// wide and as tall as the physical display's own proportion, so a filled
/// desktop is exactly the screen. Desktops adjoin in the aperture's reading
/// order, so the plane is the miniature map at a larger size. No capture,
/// AX or WindowServer reads.
struct SpaceCanvasLayout {
    let count: Int
    let columns: Int
    let rows: Int
    let room: CGSize
    /// Width over height of one desktop: the display's, never a constant.
    let aspect: CGFloat

    init(count: Int, room: CGSize) {
        let shape = SpaceFilmstripLayout.gridShape(count: count)
        self.count = max(1, count)
        self.columns = shape.columns
        self.rows = shape.rows
        self.room = room
        self.aspect = room.width > 0 && room.height > 0 ? room.width / room.height : 1.6
    }

    var world: CGSize { CGSize(width: CGFloat(columns), height: CGFloat(rows) / aspect) }

    /// The canvas area under the header, clear of the screen's edges. Its
    /// centre is the room's centre, so a filled desktop is centred exactly.
    var stage: CGRect {
        CGRect(x: 40, y: 64, width: max(1, room.width - 80), height: max(1, room.height - 128))
    }

    func cell(_ index: Int) -> CGRect {
        CGRect(x: CGFloat(index % columns), y: CGFloat(index / columns) / aspect,
               width: 1, height: 1 / aspect)
    }

    var fitScale: CGFloat { min(stage.width / world.width, stage.height / world.height) }
    /// One desktop spans the whole display: the furthest zoom, still a preview.
    var fillScale: CGFloat { room.width }
    var maxScale: CGFloat { max(fitScale, fillScale) }
    /// About two and a half desktops across: the raster size of the plane.
    var openingScale: CGFloat { min(maxScale, max(fitScale, stage.width / min(CGFloat(columns), 2.6))) }

    /// Within this of the fill scale, the camera locks to one desktop.
    func locks(_ scale: CGFloat) -> Bool { maxScale > fitScale && scale >= maxScale * 0.995 }

    /// Always enter with every desktop visible, regardless of selection.
    func opening(on index: Int) -> SpaceCanvasCamera {
        SpaceCanvasCamera(center: CGPoint(x: world.width / 2, y: world.height / 2), scale: fitScale)
    }

    /// Scale within fit…max; an edge may come in by a short margin, never
    /// half the view. An axis smaller than the stage stays centred.
    func clamped(_ camera: SpaceCanvasCamera) -> SpaceCanvasCamera {
        let s = min(max(camera.scale, fitScale), maxScale)
        let margin: CGFloat = 0.12
        func axis(_ v: CGFloat, half: CGFloat, extent: CGFloat) -> CGFloat {
            extent + 2 * margin > 2 * half ? min(max(v, half - margin), extent - half + margin) : extent / 2
        }
        return SpaceCanvasCamera(
            center: CGPoint(x: axis(camera.center.x, half: stage.width / 2 / s, extent: world.width),
                            y: axis(camera.center.y, half: stage.height / 2 / s, extent: world.height)),
            scale: s)
    }

    func view(_ rect: CGRect, camera: SpaceCanvasCamera) -> CGRect {
        CGRect(x: (rect.minX - camera.center.x) * camera.scale + stage.midX,
               y: (rect.minY - camera.center.y) * camera.scale + stage.midY,
               width: rect.width * camera.scale, height: rect.height * camera.scale)
    }

    func world(_ point: CGPoint, camera: SpaceCanvasCamera) -> CGPoint {
        CGPoint(x: (point.x - stage.midX) / camera.scale + camera.center.x,
                y: (point.y - stage.midY) / camera.scale + camera.center.y)
    }

    /// The camera that lays the whole map exactly over `frame`. Unclamped.
    func camera(fitting frame: CGRect) -> SpaceCanvasCamera {
        let s = frame.width / world.width
        return SpaceCanvasCamera(center: CGPoint(x: (stage.midX - frame.minX) / s, y: (stage.midY - frame.minY) / s), scale: s)
    }

    /// The camera that sets desktop `index` centred inside `frame`, as
    /// large as fits: the strip's thumbnail, or the whole screen. Unclamped.
    func camera(placing index: Int, onto frame: CGRect) -> SpaceCanvasCamera {
        let c = cell(index)
        let s = min(frame.width / c.width, frame.height / c.height)
        return SpaceCanvasCamera(center: CGPoint(x: c.midX + (stage.midX - frame.midX) / s,
                                                 y: c.midY + (stage.midY - frame.midY) / s), scale: s)
    }

    /// The camera at which `index` covers the display edge to edge.
    func filling(_ index: Int) -> SpaceCanvasCamera {
        camera(placing: index, onto: CGRect(origin: .zero, size: room))
    }

    /// The desktop under a world point, clamped to the grid.
    func nearest(to point: CGPoint) -> Int {
        let column = min(max(Int(floor(point.x)), 0), columns - 1)
        let row = min(max(Int(floor(point.y * aspect)), 0), rows - 1)
        return min(row * columns + column, count - 1)
    }

    func index(at point: CGPoint, camera: SpaceCanvasCamera) -> Int? {
        let w = world(point, camera: camera)
        guard w.x >= 0, w.y >= 0 else { return nil }
        let column = Int(w.x), row = Int(w.y * aspect)
        guard column < columns, row < rows else { return nil }
        let index = row * columns + column
        return index < count ? index : nil
    }

    /// Arrow movement on the grid. A short last row clamps to its end.
    func neighbour(of index: Int, dx: Int, dy: Int) -> Int {
        if dy == 0 { return min(max(index + dx, 0), count - 1) }
        let row = index / columns + dy
        guard row >= 0, row < rows else { return index }
        return min(row * columns + index % columns, count - 1)
    }

    /// Bottom-left, in the aperture's proportions.
    var minimap: CGRect {
        let width = min(max(room.width * 0.14, 190), 250)
        let height = width / SpaceFilmstripLayout.cardWidth * SpaceFilmstripLayout.cardHeight
        return CGRect(x: 28, y: room.height - height - 28, width: width, height: height)
    }

    /// The minimap's map, inset as the aperture insets its own.
    func minimapCells(in bounds: CGRect) -> [CGRect] {
        let inset = 7 * bounds.width / SpaceFilmstripLayout.cardWidth
        return SpaceFilmstripLayout.gridCells(count: count, in: bounds.insetBy(dx: inset, dy: inset), aspect: aspect)
    }

    /// The visible world, drawn on the minimap's map.
    func viewport(camera: SpaceCanvasCamera, map: CGRect) -> CGRect {
        let k = map.width / world.width
        let visible = CGRect(x: camera.center.x - stage.width / 2 / camera.scale,
                             y: camera.center.y - stage.height / 2 / camera.scale,
                             width: stage.width / camera.scale, height: stage.height / camera.scale)
        return CGRect(x: map.minX + visible.minX * k, y: map.minY + visible.minY * k,
                      width: visible.width * k, height: visible.height * k).intersection(map)
    }

    func mapPoint(_ point: CGPoint, map: CGRect) -> CGPoint {
        let k = map.width / world.width
        return CGPoint(x: (point.x - map.minX) / k, y: (point.y - map.minY) / k)
    }
}

/// Navigation-only overlay. The event tap routes its keys without stealing
/// and later restoring the foreground app's WindowServer key-focus token.
final class SpaceCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The aperture's second stop: every desktop on one connected plane. The
/// map flies out of the aperture into this plane and the aperture's own
/// copy docks bottom-left as the minimap. The plane is built once per opening;
/// inventory updates replace only its window details. One transform moves
/// the plane. Nothing here moves a real window; only `land` switches,
/// through the navigator.
final class SpaceCanvasView: NSView {
    struct Handlers {
        var choose: (Int) -> Void
        var land: () -> Void
        var cancel: () -> Void
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    let layout: SpaceCanvasLayout
    private var cards: [SpaceFilmstripCard]
    private let handlers: Handlers
    private let scale: CGFloat
    private let base: CGFloat
    private(set) var camera: SpaceCanvasCamera
    private(set) var selected: Int
    private let current: Int

    private let shade = CALayer()
    private let plane = CALayer()
    private let backlight = CALayer()
    private let focusLight = CAGradientLayer()
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let here = CALayer()
    private let header = CALayer()
    private var headerTitle: CATextLayer?
    private let minimap = CALayer()
    private let miniZones = CAShapeLayer()
    private let miniRing = CALayer()
    private let miniViewport = CALayer()
    private var miniMap: CGRect = .zero
    private var miniCells: [CGRect] = []
    private var windowContainers: [CALayer] = []
    private var regions: [CALayer] = []
    private var captions: [CALayer] = []
    private let iconLoader = SpaceCanvasIconLoader()
    private let previewLoader = SpaceCanvasPreviewLoader()
    private var previewLayers: [Int: [UInt32: CALayer]] = [:]
    private var previewImages: [UInt32: CGImage] = [:]
    private var previewIndex: Int?
    private var previewRequest: DispatchWorkItem?
    private var previewRelease: DispatchWorkItem?
    private var previewPreparation: DispatchWorkItem?
    private var previewSignature: [UInt64] = []
    private var previewsEnabled = true
    private var cameraAnimationDeadline: CFTimeInterval = 0

    private enum Drag { case pan(start: CGPoint, camera: SpaceCanvasCamera, moved: Bool), minimap }
    private var drag: Drag?
    private var zoomDrive = SpaceCanvasZoomDrive()
    private var zoomLink: CADisplayLink?
    private var zoomFocusObserver: NSObjectProtocol?
    private var acceptsInput = true

    static let duration: CFTimeInterval = 0.18
    static let entryDuration: CFTimeInterval = 0.3
    static let landDuration: CFTimeInterval = 0.26
    static let exitDuration: CFTimeInterval = 0.2
    static let snapDuration: CFTimeInterval = 0.14
    /// The shade reaches opaque before the switch is posted, so the Dock's
    /// slide happens behind the canvas instead of under a frozen screen.
    static let coverDuration: CFTimeInterval = 0.06
    /// The schematic hands over to the real desktop: fills and shade first,
    /// then the window zones that sit exactly over the real windows.
    static let revealDuration: CFTimeInterval = 0.12
    static let revealZoneDelay: CFTimeInterval = 0.05
    /// Every camera curve here is monotonic and travels the sampled
    /// constant-ratio path, so these shape time, not the zoom's own bias.
    /// Retargets: quick to respond, long settle.
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
    /// Entry: out of the card at once, decelerating into the overview.
    static let entryTiming = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
    /// Landing commits: a short build, then arrival without overshoot.
    static let landTiming = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    /// Escape: leaves at once, since it only undoes the chooser.
    static let exitTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    static let revealTiming = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
    static let fadeIn = CAMediaTimingFunction(controlPoints: 0.22, 0, 0.22, 1)
    static let fadeOut = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.35)
    /// The goal camera, not the presented one: a press that reaches the
    /// minimum only zooms, and the next fresh press sees the minimum.
    var atMinimum: Bool { camera.scale <= layout.fitScale * 1.001 && visibleCamera.scale <= layout.fitScale * 1.001 }
    /// True while the camera holds one desktop at the full display.
    private(set) var locked = false
    private var pointerTracking: NSTrackingArea?

    init(cards: [SpaceFilmstripCard], selected: Int, current: Int, room: CGSize, scale: CGFloat, handlers: Handlers) {
        self.cards = cards
        self.layout = SpaceCanvasLayout(count: cards.count, room: room)
        self.selected = min(max(selected, 0), max(0, cards.count - 1))
        self.current = current
        self.handlers = handlers
        self.scale = scale
        self.base = layout.openingScale
        self.camera = layout.opening(on: self.selected)
        super.init(frame: CGRect(origin: .zero, size: room))
        wantsLayer = true
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        zoomLink?.invalidate()
        previewRequest?.cancel()
        previewRelease?.cancel()
        previewPreparation?.cancel()
        if let zoomFocusObserver { NotificationCenter.default.removeObserver(zoomFocusObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopKeyboardZoom()
        if window == nil {
            previewPreparation?.cancel()
            clearPreviews()
            previewLoader.stop()
        } else { preparePreviews(after: Self.entryDuration) }
        if let zoomFocusObserver { NotificationCenter.default.removeObserver(zoomFocusObserver) }
        zoomFocusObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in self?.stopKeyboardZoom() }
        }
    }

    /// Fresh inventory may arrive after the chooser opens. Keep the camera,
    /// selection and all their in-flight animations; only replace changed
    /// window details. A different desktop topology needs a new canvas.
    @discardableResult
    func refresh(cards fresh: [SpaceFilmstripCard]) -> Bool {
        guard fresh.count == cards.count,
              zip(fresh, cards).allSatisfy({ $0.id == $1.id && $0.number == $1.number }),
              fresh != cards else { return false }
        let changed = fresh.indices.filter { fresh[$0].windows != cards[$0].windows }
        cards = fresh
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in changed {
            updateWindows(at: index)
            if sharpened.remove(index) != nil { sharpen(index) }
        }
        headerTitle?.string = headerText
        miniZones.path = minimapZonePath()
        CATransaction.commit()
        preparePreviews()
        // A title/frame refresh reuses its photo layers, including their active
        // fade. Only changed identities need a new subscription. New photos
        // follow the remaining camera travel rather than jumping to its goal.
        if previewIndex == selected, previewSignature != previewKey(cards[selected].windows) {
            let remaining = plane.animation(forKey: "transform") == nil ? 0
                : max(0, cameraAnimationDeadline - CACurrentMediaTime())
            let path = remaining > 0
                ? SpaceCanvasCamera.path(from: visibleCamera, to: camera, steps: Self.pathSteps) : nil
            updateDetail(camera, duration: remaining, path: path)
        }
        return true
    }

    // MARK: Opening and closing

    /// A departing canvas is an animation surface, no longer a chooser.
    /// Leave the presentation camera intact for the exit animation to sample.
    func endInteraction() {
        acceptsInput = false
        drag = nil
        zoomDrive.reset()
        invalidateZoomLink()
    }

    /// Grows out of the strip: `card` is the strip's selected thumbnail in
    /// this view, and the plane starts with that desktop exactly over it.
    /// Without a strip the plane settles from just past the current desktop.
    /// Either way the camera ends on the whole map, in one move.
    func open(from card: CGRect?, reduceMotion: Bool, revealed: (() -> Void)? = nil) {
        guard let root = layer else { return }
        let start: SpaceCanvasCamera
        if let card, card.width > 0, card.height > 0 {
            start = layout.camera(placing: selected, onto: card)
        } else {
            let anchor = layout.cell(cards.indices.contains(current) ? current : selected)
            let k: CGFloat = 0.12
            start = SpaceCanvasCamera(center: CGPoint(x: camera.center.x + (anchor.midX - camera.center.x) * k,
                                                      y: camera.center.y + (anchor.midY - camera.center.y) * k),
                                      scale: camera.scale * 1.08)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !reduceMotion {
            plane.transform = transform(for: start)
            place(ring: start)
            placeHere(start)
            [root, header, minimap].forEach { $0.opacity = 0 }
        }
        CATransaction.commit()
        // Nothing has been presented yet: the path starts at `start`.
        apply(camera, duration: reduceMotion ? 0 : Self.entryDuration, force: true, timing: Self.entryTiming,
              from: reduceMotion ? camera : start)
        animate(root, "opacity", to: Float(1), duration: reduceMotion ? 0 : 0.12, timing: Self.fadeIn, arrival: revealed)
        animate(header, "opacity", to: Float(1), duration: reduceMotion ? 0 : 0.2, timing: Self.fadeIn)
        animate(minimap, "opacity", to: Float(1), duration: reduceMotion ? 0 : 0.2, timing: Self.fadeIn)
    }

    /// Escape: back into the desktop that is showing, dissolving on the way,
    /// so nothing is left standing in for it.
    func dissolve(reduceMotion: Bool, dismissed: (() -> Void)? = nil) {
        endInteraction()
        stopPreviewRequests()
        let travel = reduceMotion ? 0 : Self.exitDuration
        let home = cards.indices.contains(current) ? current : selected
        apply(layout.filling(home), duration: travel, clamp: false, force: true, timing: Self.exitTiming)
        if let root = layer {
            animate(root, "opacity", to: Float(0), duration: travel, timing: Self.fadeOut, arrival: dismissed)
        } else if let dismissed { DispatchQueue.main.async(execute: dismissed) }
        hideChrome(duration: reduceMotion ? 0 : 0.1)
    }

    /// Landing: the chosen desktop comes forward to exactly fill the display
    /// and stays opaque. `arrived` runs once the camera is there; the owner
    /// removes the canvas only when the switch has also finished.
    func land(reduceMotion: Bool, covered: @escaping () -> Void = {}, arrived: @escaping () -> Void) {
        endInteraction()
        stopPreviewRequests()
        let goal = layout.filling(selected)
        hideChrome(duration: reduceMotion ? 0 : 0.12)
        sharpen(selected)
        // Both surfaces must finish: Reduce Transparency starts with an
        // opaque shade, while an early Enter can still find the root fading in.
        // Each arrival runs once, on main, and only when finished, so a
        // replaced animation never counts and cannot authorise a switch
        // under a cover that is no longer on screen.
        let cover = reduceMotion ? 0 : Self.coverDuration
        var remaining = layer == nil ? 1 : 2
        let opaque = {
            remaining -= 1
            if remaining == 0 { covered() }
        }
        if let root = layer {
            animate(root, "opacity", to: Float(1), duration: cover, timing: Self.revealTiming, arrival: opaque)
        }
        animate(shade, "backgroundColor", to: NSColor(calibratedWhite: 0.04, alpha: 1).cgColor,
                duration: cover, timing: Self.revealTiming, arrival: opaque)
        let settled = goal == camera && plane.animation(forKey: "transform") == nil
        if reduceMotion || settled {
            apply(goal, duration: 0, clamp: false)
            DispatchQueue.main.async(execute: arrived)
        } else {
            apply(goal, duration: Self.landDuration, clamp: false, force: true,
                  timing: Self.landTiming, arrival: arrived)
        }
    }

    /// The switch has landed under the opaque canvas: hand over to the real
    /// desktop. Completion follows the rendered fade, including its zone
    /// delay and any paused layer clock. The duration is descriptive only.
    @discardableResult
    func reveal(reduceMotion: Bool, dismissed: (() -> Void)? = nil) -> CFTimeInterval {
        let duration = reduceMotion ? 0 : Self.revealDuration
        let delay = reduceMotion ? 0 : Self.revealZoneDelay
        let clear = NSColor.clear.cgColor
        var remaining = 1 + windowContainers.count
        let arrived = {
            remaining -= 1
            if remaining == 0 { dismissed?() }
        }
        animate(shade, "backgroundColor", to: clear, duration: duration, timing: Self.revealTiming, arrival: arrived)
        for region in regions {
            animate(region, "backgroundColor", to: clear, duration: duration, timing: Self.revealTiming)
            animate(region, "borderColor", to: clear, duration: duration, timing: Self.revealTiming)
        }
        for caption in captions { animate(caption, "opacity", to: Float(0), duration: duration, timing: Self.revealTiming) }
        for container in windowContainers {
            animate(container, "opacity", to: Float(0), duration: duration,
                    timing: Self.revealTiming, delay: delay, arrival: arrived)
        }
        return duration + delay
    }

    private func hideChrome(duration: CFTimeInterval) {
        for layer in [header, minimap, here, ring, backlight, focusLight] {
            animate(layer, "opacity", to: Float(0), duration: duration, timing: Self.fadeOut)
        }
        locked = true
    }

    // MARK: Selection and camera

    func select(_ index: Int, animated: Bool, followCamera: Bool = true) {
        guard cards.indices.contains(index), index != selected else { return }
        selected = index
        preparePreviews()
        let cell = layout.view(layout.cell(index), camera: camera)
        if locked || (followCamera && !layout.stage.insetBy(dx: -2, dy: -2).contains(cell)) {
            // Follow the ring only when it leaves the view; a locked camera
            // moves to the next desktop's own full-display endpoint.
            let c = layout.cell(index)
            apply(SpaceCanvasCamera(center: CGPoint(x: c.midX, y: c.midY), scale: camera.scale), duration: animated ? 0.16 : 0)
        } else {
            place(ring: camera, duration: animated ? 0.12 : 0)
            updateDetail(camera, duration: animated ? 0.12 : 0)
        }
        placeMinimapRing()
        updateAccessibility()
    }

    /// Camera-only zoom: even at a limit the canvas keeps ownership of input,
    /// and even a full-display desktop is still a preview.
    @discardableResult
    func zoom(out: Bool, about point: CGPoint? = nil, reduceMotion: Bool = false) -> Bool {
        guard acceptsInput else { return false }
        stopKeyboardZoom()
        return stepZoom(out: out, about: point, reduceMotion: reduceMotion)
    }

    private func stepZoom(out: Bool, about point: CGPoint? = nil, reduceMotion: Bool) -> Bool {
        let scale = camera.scale * (out ? 1 / 1.4 : 1.4)
        let duration = reduceMotion ? 0 : 0.14
        if let point {
            zoom(to: scale, about: point, duration: duration)
        } else {
            // Keyboard zoom follows the highlighted desktop. Zooming out
            // preserves the current camera until the full grid fits again.
            let cell = layout.cell(selected)
            let center = out ? camera.center : CGPoint(x: cell.midX, y: cell.midY)
            apply(SpaceCanvasCamera(center: center, scale: scale), duration: duration)
        }
        return true
    }

    /// Bare and intercepted Ctrl keys share this lifetime. OS repeat events
    /// do not set the pace. A tap keeps its notch; a hold continues from it.
    func zoomKey(_ key: Int64, pressed: Bool, opening: Bool = false,
                 reduceMotion: Bool = false, time: TimeInterval = CACurrentMediaTime()) {
        guard acceptsInput else { return }
        guard [125, 126, 27, 24].contains(key) else { return }
        if pressed {
            let wasDriving = zoomDrive.driving || zoomDrive.velocity != 0
            guard zoomDrive.press(key, at: time, delay: opening ? Self.entryDuration : 0.14) else { return }
            if !opening && !wasDriving {
                _ = stepZoom(out: key == 125 || key == 27, reduceMotion: reduceMotion)
            }
            if window != nil && zoomLink == nil {
                let link = displayLink(target: self, selector: #selector(zoomFrame(_:)))
                zoomLink = link
                link.add(to: .main, forMode: .common)
            }
            zoomLink?.isPaused = zoomDrive.atBoundary
            DiagnosticLog.shared.info("SpaceZoom: hold began key=\(key) opening=\(opening)")
        } else {
            zoomDrive.release(key)
            if !zoomDrive.active { invalidateZoomLink() }
            else { zoomLink?.isPaused = zoomDrive.atBoundary }
        }
    }

    @objc private func zoomFrame(_ link: CADisplayLink) {
        advanceKeyboardZoom(to: CACurrentMediaTime())
    }

    /// One retained plane and its existing decorations move per frame. No
    /// inventory/capture work, no animation queue, and no premature lock.
    func advanceKeyboardZoom(to time: TimeInterval) {
        let delta = zoomDrive.advance(to: time)
        if delta != 0 {
            let from = plane.animation(forKey: "transform") == nil ? camera : visibleCamera
            let goal = delta > 0 ? layout.filling(selected) : layout.opening(on: selected)
            let next = from.advanced(toward: goal, logarithmicDelta: delta)
            apply(next, duration: 0)
            let reached = next == goal || (delta > 0 && locked)
            // A reversal can coast briefly into the old limit. Never latch
            // the new direction there: it must be free to move away.
            if reached && (zoomDrive.direction == 0 || zoomDrive.direction == (delta > 0 ? 1 : -1)) {
                zoomDrive.stopAtBoundary()
                zoomLink?.isPaused = true
                DiagnosticLog.shared.info("SpaceZoom: hold reached \(delta > 0 ? "full" : "map")")
            }
        }
        if !zoomDrive.active { invalidateZoomLink() }
    }

    private func invalidateZoomLink() {
        zoomLink?.invalidate()
        zoomLink = nil
    }

    private func stopKeyboardZoom() {
        let wasDriving = zoomDrive.driving || zoomDrive.velocity != 0
        let shown = wasDriving ? visibleCamera : nil
        zoomDrive.reset()
        invalidateZoomLink()
        if let shown { apply(shown, duration: 0, force: true) }
    }

    /// Continuous zoom anchors on what is visible, so a gesture that starts
    /// mid-glide keeps the point under the pointer where the eye sees it.
    private func zoom(to scale: CGFloat, about point: CGPoint, duration: CFTimeInterval) {
        let from = visibleCamera
        let anchor = layout.world(point, camera: from)
        let s = min(max(scale, layout.fitScale), layout.maxScale)
        let center = CGPoint(x: anchor.x - (point.x - layout.stage.midX) / s,
                             y: anchor.y - (point.y - layout.stage.midY) / s)
        apply(SpaceCanvasCamera(center: center, scale: s), duration: duration)
    }

    /// The single way the camera moves. A goal at the fill scale locks onto
    /// the nearest desktop's exact full-display camera; an unchanged goal does
    /// no work at all, so holding a limit never replaces live animations.
    /// Everything that follows the camera travels the same sampled path, from
    /// what is on screen (or `from`, before anything has been shown).
    private func apply(_ goal: SpaceCanvasCamera, duration: CFTimeInterval, clamp: Bool = true,
                       force: Bool = false, timing: CAMediaTimingFunction = SpaceCanvasView.timing,
                       from: SpaceCanvasCamera? = nil, arrival: (() -> Void)? = nil) {
        var next = clamp ? layout.clamped(goal) : goal
        var duration = duration
        let lock = clamp && layout.locks(next.scale)
        if lock {
            let index = layout.nearest(to: next.center)
            next = layout.filling(index)
            if index != selected {
                selected = index
                preparePreviews()
                placeMinimapRing()
                updateAccessibility()
                handlers.choose(index)
            }
            // A continuous gesture glides into the lock instead of jumping.
            if duration == 0, next != camera, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                duration = Self.snapDuration
            }
        }
        guard force || next != camera else { return }
        let start = from ?? visibleCamera
        camera = next
        let path = duration > 0 && start != next
            ? SpaceCanvasCamera.path(from: start, to: next, steps: Self.pathSteps) : nil
        cameraAnimationDeadline = CACurrentMediaTime() + duration
        animate(plane, "transform", to: NSValue(caTransform3D: transform(for: camera)), duration: duration,
                timing: timing, path: path?.map { NSValue(caTransform3D: transform(for: $0)) }, arrival: arrival)
        updateDetail(camera, duration: duration, timing: timing, path: path)
        place(ring: camera, duration: duration, timing: timing, path: path)
        placeHere(camera, duration: duration, timing: timing, path: path)
        let viewport = layout.viewport(camera: camera, map: miniMap)
        if !viewport.isNull {
            let frames = path?.map { layout.viewport(camera: $0, map: miniMap) }
            let usable = frames.map { $0.allSatisfy { !$0.isNull } } ?? false
            animate(miniViewport, "position", to: NSValue(point: CGPoint(x: viewport.midX, y: viewport.midY)), duration: duration, timing: timing,
                    path: usable ? frames?.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) } : nil)
            animate(miniViewport, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: viewport.size)), duration: duration, timing: timing,
                    path: usable ? frames?.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) } : nil)
        }
        if lock { sharpen(selected) }
        if clamp, lock != locked {
            // A full-display desktop needs no ring around the screen's edge.
            locked = lock
            for light in [ring, backlight, focusLight] {
                animate(light, "opacity", to: Float(lock ? 0 : 1), duration: duration == 0 ? 0 : 0.12)
            }
        }
    }

    /// Samples per camera move: dense enough that the straight segments
    /// between them are below a pixel of error at the screen's edge.
    static let pathSteps = 24

    private func preparePreviews(after delay: CFTimeInterval = 0.06) {
        guard previewsEnabled, window != nil else { return }
        previewPreparation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewsEnabled, self.window != nil else { return }
            self.previewPreparation = nil
            self.previewLoader.prepare(cards: self.cards, selected: self.selected, current: self.current)
        }
        previewPreparation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func previewKey(_ windows: [SpaceFilmstripWindow]) -> [UInt64] {
        windows.map { UInt64(UInt32(bitPattern: $0.pid)) << 32 | UInt64($0.wid) }
    }

    /// Frame work is limited to opacity on at most six retained layers.
    /// Capture starts on a later run-loop turn, once per near selection.
    private func updateDetail(_ camera: SpaceCanvasCamera, duration: CFTimeInterval,
                              timing: CAMediaTimingFunction = SpaceCanvasView.timing,
                              path: [SpaceCanvasCamera]? = nil) {
        let near = camera.scale >= layout.fillScale * SpaceCanvasDetail.prepareRatio
        if near, previewsEnabled, cards.indices.contains(selected) {
            let returning = previewRelease != nil
            previewRelease?.cancel()
            previewRelease = nil
            let windows = cards[selected].windows
            let signature = previewKey(windows)
            let changed = previewIndex != selected || previewSignature != signature
            if changed || returning {
                if changed {
                    clearPreviews()
                    previewIndex = selected
                    previewSignature = signature
                }
                let index = selected
                let request = DispatchWorkItem { [weak self] in
                    guard let self, self.previewsEnabled, self.window != nil,
                          self.previewIndex == index, self.previewSignature == signature else { return }
                    self.previewRequest = nil
                    self.previewLoader.load(windows: windows,
                        displayPixelSize: CGSize(width: self.layout.room.width * self.scale,
                                                 height: self.layout.room.height * self.scale)) { [weak self] images in
                        guard let self, self.previewsEnabled, self.previewIndex == index,
                              self.previewSignature == signature else { return }
                        self.installPreviews(images, at: index)
                    }
                }
                previewRequest = request
                DispatchQueue.main.async(execute: request)
            }
        }
        if let index = previewIndex {
            let opacity = SpaceCanvasDetail.opacity(scale: camera.scale, fillScale: layout.fillScale)
            let values = path?.map { SpaceCanvasDetail.opacity(scale: $0.scale, fillScale: layout.fillScale) }
            for photo in previewLayers[index]?.values ?? Dictionary<UInt32, CALayer>().values {
                animate(photo, "opacity", to: opacity, duration: duration, timing: timing, path: values)
            }
        }
        if !near, previewIndex != nil, previewRelease == nil {
            previewRequest?.cancel()
            previewRequest = nil
            previewLoader.cancel()
            // Let an outgoing camera animation fade the images before releasing
            // their backing. A reversal cancels this cleanup.
            if duration == 0 { clearPreviews() }
            else {
                let release = DispatchWorkItem { [weak self] in
                    guard let self, self.camera.scale < self.layout.fillScale * SpaceCanvasDetail.prepareRatio else { return }
                    self.clearPreviews()
                }
                previewRelease = release
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: release)
            }
        }
    }

    /// Only photos change on async arrival; the camera and its animations stay intact.
    func installPreviews(_ images: [UInt32: CGImage], at index: Int) {
        guard previewsEnabled, previewIndex == index else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, image) in images {
            guard let photo = previewLayers[index]?[id], let pixels = photo.sublayers?.first,
                  previewImages[id] !== image else { continue }
            previewImages[id] = image
            pixels.contents = image
            animate(pixels, "opacity", to: Float(1),
                    duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1)
        }
        CATransaction.commit()
    }

    private func stopPreviewRequests() {
        previewsEnabled = false
        previewPreparation?.cancel()
        previewPreparation = nil
        previewRequest?.cancel()
        previewRequest = nil
        previewLoader.stop()
    }

    private func clearPreviews() {
        previewRequest?.cancel()
        previewRequest = nil
        previewRelease?.cancel()
        previewRelease = nil
        previewLoader.cancel()
        if let index = previewIndex {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for photo in previewLayers[index]?.values ?? Dictionary<UInt32, CALayer>().values {
                photo.removeAllAnimations()
                photo.opacity = 0
                photo.sublayers?.first?.removeAllAnimations()
                photo.sublayers?.first?.contents = nil
                photo.sublayers?.first?.opacity = 0
            }
            CATransaction.commit()
        }
        previewImages.removeAll()
        previewIndex = nil
        previewSignature = []
    }

    /// The plane is laid out once at `base`; the camera is one transform.
    private func transform(for camera: SpaceCanvasCamera) -> CATransform3D {
        let k = camera.scale / base
        return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(
            layout.stage.midX - camera.center.x * camera.scale,
            layout.stage.midY - camera.center.y * camera.scale, 0))
    }

    private struct RingGeometry {
        let center: CGPoint
        let local: CGRect
        let radius: CGFloat
        let edge: CGPath
    }

    private func ringGeometry(_ camera: SpaceCanvasCamera) -> RingGeometry {
        let frame = layout.view(layout.cell(selected), camera: camera)
        let inset = min(3, frame.width * 0.04)
        let r = frame.insetBy(dx: inset, dy: inset)
        let local = CGRect(origin: .zero, size: r.size)
        // Continuous, so the path keyframes keep one element count.
        let radius = min(7, max(3, (r.width - 60) / 60 * 4 + 3))
        let edge = CGPath(roundedRect: local.insetBy(dx: 0.75, dy: 0.75),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        return RingGeometry(center: CGPoint(x: r.midX, y: r.midY), local: local, radius: radius, edge: edge)
    }

    /// The ring and the coral dot keep their stroke at any zoom, so they sit
    /// over the plane and travel on the same path.
    private func place(ring camera: SpaceCanvasCamera, duration: CFTimeInterval = 0,
                       timing: CAMediaTimingFunction = SpaceCanvasView.timing, path: [SpaceCanvasCamera]? = nil) {
        let g = ringGeometry(camera)
        let steps = path?.map(ringGeometry)
        for light in [backlight, focusLight, ring] {
            animate(light, "position", to: NSValue(point: g.center), duration: duration, timing: timing,
                    path: steps?.map { NSValue(point: $0.center) })
            animate(light, "bounds", to: NSValue(rect: g.local), duration: duration, timing: timing,
                    path: steps?.map { NSValue(rect: $0.local) })
            animate(light, "cornerRadius", to: g.radius, duration: duration, timing: timing,
                    path: steps?.map(\.radius))
        }
        animate(ringMask, "bounds", to: NSValue(rect: g.local), duration: duration, timing: timing,
                path: steps?.map { NSValue(rect: $0.local) })
        animate(ringMask, "path", to: g.edge, duration: duration, timing: timing, path: steps?.map(\.edge))
        let rim: (CGPath) -> CGPath = { $0.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1) }
        animate(backlight, "shadowPath", to: rim(g.edge), duration: duration, timing: timing,
                path: steps?.map { rim($0.edge) })
    }

    private func herePosition(_ camera: SpaceCanvasCamera) -> CGPoint {
        let frame = layout.view(layout.cell(current), camera: camera)
        let size: CGFloat = frame.width > 120 ? 7 : 4
        return CGPoint(x: frame.maxX - size * 1.8, y: frame.minY + size * 1.8)
    }

    private func placeHere(_ camera: SpaceCanvasCamera, duration: CFTimeInterval = 0,
                           timing: CAMediaTimingFunction = SpaceCanvasView.timing, path: [SpaceCanvasCamera]? = nil) {
        guard cards.indices.contains(current) else { here.opacity = 0; return }
        animate(here, "position", to: NSValue(point: herePosition(camera)), duration: duration, timing: timing,
                path: path?.map { NSValue(point: herePosition($0)) })
    }

    private func placeMinimapRing() {
        guard miniCells.indices.contains(selected) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        miniRing.frame = miniCells[selected].insetBy(dx: -1, dy: -1)
        CATransaction.commit()
    }

    /// Text is rasterised for the overview. A desktop the camera locks onto
    /// is re-rasterised once, for the full display, so only what is shown
    /// at that size pays for the larger backing.
    private var sharpened: Set<Int> = []
    private func sharpen(_ index: Int) {
        guard cards.indices.contains(index), !sharpened.contains(index) else { return }
        sharpened.insert(index)
        let needed = scale * max(2, layout.filling(index).scale / base)
        var layers: [CALayer] = [windowContainers[index]]
        if captions.indices.contains(index) { layers.append(captions[index]) }
        while let layer = layers.popLast() {
            if layer is CATextLayer, layer.contentsScale < needed { layer.contentsScale = needed }
            layers.append(contentsOf: layer.sublayers ?? [])
        }
    }

    /// Retargets from the presented value. A value already installed with
    /// nothing in flight is left alone: no replacement animation, no work.
    /// `path`, when given, is the move sampled evenly from start to `value`.
    private func animate(_ layer: CALayer, _ key: String, to value: Any, duration: CFTimeInterval,
                         timing: CAMediaTimingFunction = SpaceCanvasView.timing, path: [Any]? = nil,
                         delay: CFTimeInterval = 0, arrival: (() -> Void)? = nil) {
        let installed = layer.value(forKeyPath: key)
        if let old = installed as? NSObject, let new = value as? NSObject, old.isEqual(new) {
            if duration == 0 { layer.removeAnimation(forKey: key) }
            if layer.animation(forKey: key) == nil {
                if let arrival { DispatchQueue.main.async(execute: arrival) }
                return
            }
        }
        let from = layer.presentation()?.value(forKeyPath: key) ?? installed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard duration > 0, let from else {
            layer.removeAnimation(forKey: key)
            if let arrival { DispatchQueue.main.async(execute: arrival) }
            return
        }
        let move: CAAnimation
        if let path, path.count > 1 {
            let keyframes = CAKeyframeAnimation(keyPath: key)
            keyframes.values = path
            keyframes.timingFunction = timing
            move = keyframes
        } else {
            let basic = CABasicAnimation(keyPath: key)
            basic.fromValue = from
            basic.toValue = value
            basic.timingFunction = timing
            move = basic
        }
        move.duration = duration
        if delay > 0 {
            move.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            move.fillMode = .backwards
        }
        if let arrival { move.delegate = SpaceCanvasArrival(arrival) }
        layer.add(move, forKey: key)
    }

    private func updateAccessibility() {
        let number = cards.indices.contains(selected) ? cards[selected].number : selected + 1
        setAccessibilityLabel("Desktop canvas, desktop \(number) of \(cards.count)")
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        handleKey(Int64(event.keyCode), pressed: true, repeated: event.isARepeat)
    }

    func handleKey(_ key: Int64, pressed: Bool, repeated: Bool) {
        guard acceptsInput else { return }
        if !pressed {
            if [125, 126, 27, 24].contains(key) { zoomKey(key, pressed: false) }
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch key {
        case 123: move(dx: -1, dy: 0)
        case 124: move(dx: 1, dy: 0)
        case 125, 126, 27, 24:
            if !repeated { zoomKey(key, pressed: true, reduceMotion: reduceMotion) }
        case 36, 76: if !repeated { handlers.land() }
        case 53: if !repeated { handlers.cancel() }
        case 29:
            if !repeated {
                stopKeyboardZoom()
                apply(SpaceCanvasCamera(center: camera.center, scale: layout.fitScale), duration: reduceMotion ? 0 : 0.16)
            }
        default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        handleKey(Int64(event.keyCode), pressed: false, repeated: false)
    }

    func moveSelection(offset: Int) { move(dx: offset, dy: 0) }

    private func move(dx: Int, dy: Int) {
        guard acceptsInput else { return }
        let next = layout.neighbour(of: selected, dx: dx, dy: dy)
        if next != selected { handlers.choose(next) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    /// Hit-test what is visible during travel, not the camera's final goal.
    private var visibleCamera: SpaceCanvasCamera {
        guard let transform = plane.presentation()?.transform else { return camera }
        let s = transform.m11 * base
        guard s > 0 else { return camera }
        return SpaceCanvasCamera(center: CGPoint(x: (layout.stage.midX - transform.m41) / s,
                                                  y: (layout.stage.midY - transform.m42) / s), scale: s)
    }

    override func mouseMoved(with event: NSEvent) {
        highlight(at: convert(event.locationInWindow, from: nil))
    }

    func highlight(at point: CGPoint) {
        guard acceptsInput, drag == nil, layout.stage.contains(point), !minimap.frame.contains(point),
              let index = layout.index(at: point, camera: visibleCamera), index != selected else { return }
        // Update locally first so the navigator's selection callback cannot
        // pan the canvas while the pointer is only exploring it.
        select(index, animated: false, followCamera: false)
        handlers.choose(index)
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsInput else { return }
        stopKeyboardZoom()
        let point = convert(event.locationInWindow, from: nil)
        if minimap.frame.contains(point) {
            drag = .minimap
            jump(minimapPoint: point)
            return
        }
        if event.clickCount >= 2, let index = layout.index(at: point, camera: visibleCamera) {
            drag = nil
            if index != selected { handlers.choose(index) }
            handlers.land()
            return
        }
        // Grab what is visible, so a pan never jumps to an in-flight goal.
        drag = .pan(start: point, camera: visibleCamera, moved: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsInput else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .minimap:
            jump(minimapPoint: point)
        case .pan(let start, let origin, let moved):
            let dx = point.x - start.x, dy = point.y - start.y
            guard moved || hypot(dx, dy) > 3 else { return }
            drag = .pan(start: start, camera: origin, moved: true)
            apply(SpaceCanvasCamera(center: CGPoint(x: origin.center.x - dx / origin.scale,
                                                    y: origin.center.y - dy / origin.scale), scale: origin.scale), duration: 0)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard case .pan(_, _, false) = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = layout.index(at: point, camera: visibleCamera), index != selected { handlers.choose(index) }
    }

    private func jump(minimapPoint point: CGPoint) {
        let local = CGPoint(x: point.x - minimap.frame.minX, y: point.y - minimap.frame.minY)
        apply(SpaceCanvasCamera(center: layout.mapPoint(local, map: miniMap), scale: camera.scale), duration: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsInput else { return }
        stopKeyboardZoom()
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let from = visibleCamera
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            zoom(to: from.scale * exp(dy * 0.006), about: point, duration: 0)
        } else if dx != 0 || dy != 0 {
            apply(SpaceCanvasCamera(center: CGPoint(x: from.center.x - dx / from.scale,
                                                    y: from.center.y - dy / from.scale), scale: from.scale), duration: 0)
        }
    }

    override func magnify(with event: NSEvent) {
        guard acceptsInput else { return }
        stopKeyboardZoom()
        zoom(to: visibleCamera.scale * (1 + event.magnification), about: convert(event.locationInWindow, from: nil), duration: 0)
    }

    // MARK: Building

    private func build() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.name = "SpaceCanvas.root"
        shade.name = "SpaceCanvas.shade"
        shade.frame = bounds
        shade.backgroundColor = NSColor(calibratedWhite: 0.04,
            alpha: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.78).cgColor
        root.addSublayer(shade)

        plane.name = "SpaceCanvas.plane"
        plane.anchorPoint = .zero
        plane.position = .zero
        plane.bounds = CGRect(x: 0, y: 0, width: layout.world.width * base, height: layout.world.height * base)
        root.addSublayer(plane)
        buildPlane()

        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // One retained light around the selection. An explicit stroked path
        // keeps the shadow bounded to its rim rather than blurring content.
        backlight.name = "SpaceCanvas.backlight"
        backlight.shadowColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1).cgColor
        backlight.shadowOpacity = solid ? 0 : 0.30
        backlight.shadowRadius = 14
        backlight.shadowOffset = CGSize(width: 0, height: -2)
        root.addSublayer(backlight)
        focusLight.colors = [NSColor.white.withAlphaComponent(solid ? 0 : 0.065).cgColor,
                             NSColor.white.withAlphaComponent(0).cgColor]
        focusLight.startPoint = CGPoint(x: 0.5, y: 0)
        focusLight.endPoint = CGPoint(x: 0.5, y: 0.75)
        root.addSublayer(focusLight)
        ring.colors = [NSColor.white.withAlphaComponent(0.96).cgColor,
                       NSColor.white.withAlphaComponent(0.30).cgColor,
                       NSColor.white.withAlphaComponent(0.62).cgColor]
        ring.locations = [0, 0.62, 1]
        ring.startPoint = CGPoint(x: 0.3, y: 0)
        ring.endPoint = CGPoint(x: 0.7, y: 1)
        ringMask.anchorPoint = .zero
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = 1.25
        ring.mask = ringMask
        root.addSublayer(ring)
        here.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        here.cornerRadius = 3.5
        here.backgroundColor = SpaceFilmstripView.accent.cgColor
        root.addSublayer(here)

        buildHeader()
        root.addSublayer(header)
        buildMinimap()
        root.addSublayer(minimap)
        apply(camera, duration: 0, force: true)
        placeMinimapRing()
        CATransaction.commit()
    }

    private func buildPlane() {
        for (index, card) in cards.enumerated() {
            let cell = layout.cell(index)
            let frame = CGRect(x: cell.minX * base, y: cell.minY * base, width: cell.width * base, height: cell.height * base)
            let region = CALayer()
            region.frame = frame
            region.backgroundColor = NSColor(calibratedWhite: index == current ? 0.13 : 0.09, alpha: 1).cgColor
            // Vector seams: two adjoining half-point borders, drawn at the
            // zoomed size rather than scaled up from a 1x shape raster.
            region.borderWidth = 0.5
            region.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            plane.addSublayer(region)
            regions.append(region)
            let windows = CALayer()
            windows.name = "SpaceCanvas.windows.\(card.id)"
            windows.frame = frame
            plane.addSublayer(windows)
            windowContainers.append(windows)
            updateWindows(at: index)
            let labelScale = base / layout.fitScale
            let caption = text("Desktop \(card.number)", size: 11 * labelScale, color: NSColor.white.withAlphaComponent(0.5), mono: true)
            caption.frame = CGRect(x: frame.minX + 10, y: frame.maxY - 22 * labelScale, width: frame.width - 20, height: 16 * labelScale)
            plane.addSublayer(caption)
            captions.append(caption)
        }
    }

    private func updateWindows(at index: Int) {
        let container = windowContainers[index]
        let previousPhotos = previewLayers[index] ?? [:]
        previewLayers[index] = [:]
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        let frame = container.bounds
        // Windows sit where they are on the display, so a filled desktop
        // hands off to the real one without anything shifting.
        let inner = frame
        let card = cards[index]
        if card.windows.isEmpty {
            let empty = text("Empty", size: 12, color: NSColor.white.withAlphaComponent(0.28), mono: true)
            empty.name = "SpaceCanvas.empty"
            empty.alignmentMode = .center
            empty.frame = CGRect(x: frame.minX, y: frame.midY - 8, width: frame.width, height: 16)
            container.addSublayer(empty)
        }
        for window in card.windows {
            let zone = CGRect(x: inner.minX + window.rect.minX * inner.width, y: inner.minY + window.rect.minY * inner.height,
                              width: window.rect.width * inner.width, height: window.rect.height * inner.height)
            let layer = makeZone(window, frame: zone)
            if window.wid != 0 {
                // Keep the same layer clock and image fade through inventory
                // refreshes. Reparenting within this plane preserves animation.
                let retained = previousPhotos[window.wid]
                let photo = retained ?? CALayer()
                photo.name = "SpaceCanvas.photo.\(window.wid)"
                photo.frame = layer.bounds
                photo.masksToBounds = true
                let pixels = photo.sublayers?.first ?? CALayer()
                pixels.name = "SpaceCanvas.pixels"
                pixels.frame = photo.bounds
                pixels.contentsGravity = .resize
                pixels.contentsRect = window.contentsRect
                if retained == nil {
                    photo.opacity = 0
                    pixels.opacity = 0
                    photo.addSublayer(pixels)
                }
                layer.addSublayer(photo)
                previewLayers[index]?[window.wid] = photo
                if retained == nil, previewIndex == index, let image = previewImages[window.wid] {
                    pixels.contents = image
                    pixels.opacity = 1
                    photo.opacity = SpaceCanvasDetail.opacity(scale: visibleCamera.scale, fillScale: layout.fillScale)
                }
            }
            container.addSublayer(layer)
        }
    }

    /// A window as the inventory knows it: a framed zone with its app's
    /// icon and name when there's room. No pixels from the window itself.
    private func makeZone(_ window: SpaceFilmstripWindow, frame: CGRect) -> CALayer {
        let zone = CALayer()
        zone.name = "SpaceCanvas.window"
        zone.frame = frame
        zone.cornerRadius = min(4, frame.width * 0.03)
        zone.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        zone.borderWidth = 0.75
        zone.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        zone.masksToBounds = true
        guard frame.width >= 54, frame.height >= 26 else { return zone }
        let labelScale = base / layout.fitScale
        let bar = CALayer()
        bar.frame = CGRect(x: 0, y: 0, width: frame.width, height: 20 * labelScale)
        bar.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        zone.addSublayer(bar)
        var x: CGFloat = 7
        if window.pid > 0 {
            // Reserve the slot before the icon arrives: resolving an app icon
            // can block on IconServices, and must never delay a key press or
            // move the label midway through a camera animation.
            let glyph = CALayer()
            glyph.name = "SpaceCanvas.appIcon"
            glyph.contentsGravity = .resizeAspect
            glyph.frame = CGRect(x: x, y: 3, width: 14, height: 14)
            zone.addSublayer(glyph)
            iconLoader.load(pid: window.pid, into: glyph)
            x += 19
        }
        let name = text(window.app, size: 11 * labelScale, color: NSColor.white.withAlphaComponent(0.78), mono: false)
        name.frame = CGRect(x: x, y: 3, width: max(0, frame.width - x - 6), height: 16 * labelScale)
        zone.addSublayer(name)
        if !window.title.isEmpty, window.title != window.app, frame.height >= 52 * labelScale {
            let title = text(window.title, size: 10 * labelScale, color: NSColor.white.withAlphaComponent(0.42), mono: false)
            title.frame = CGRect(x: 8, y: 26 * labelScale, width: max(0, frame.width - 16), height: 16 * labelScale)
            zone.addSublayer(title)
        }
        return zone
    }

    private func buildHeader() {
        header.name = "SpaceCanvas.header"
        header.frame = CGRect(x: 40, y: 22, width: max(0, bounds.width - 80), height: 34)
        let title = text(headerText, size: 13,
                         color: NSColor.white.withAlphaComponent(0.82), mono: false)
        title.name = "SpaceCanvas.title"
        title.frame = CGRect(x: 0, y: 0, width: 260, height: 18)
        header.addSublayer(title)
        headerTitle = title
        let keys = text("← → choose   ↑ ↓ zoom   ↵ go   esc stay   ⌃⌥ scroll zoom", size: 10.5,
                        color: NSColor.white.withAlphaComponent(0.4), mono: true)
        keys.frame = CGRect(x: 0, y: 19, width: min(560, bounds.width - 48), height: 14)
        header.addSublayer(keys)
    }

    private var headerText: String {
        let empty = cards.filter(\.windows.isEmpty).count
        return "\(cards.count) desktops" + (empty > 0 ? " · \(empty) empty" : "")
    }

    /// The aperture's map, kept: same grid, same ink, now with a viewport.
    private func buildMinimap() {
        let frame = layout.minimap
        minimap.name = "SpaceCanvas.minimap"
        minimap.anchorPoint = .zero
        minimap.position = frame.origin
        minimap.bounds = CGRect(origin: .zero, size: frame.size)
        minimap.cornerRadius = 10
        minimap.masksToBounds = true
        minimap.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        minimap.borderWidth = 1
        minimap.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        miniCells = layout.minimapCells(in: minimap.bounds)
        miniMap = miniCells.reduce(CGRect.null) { $0.union($1) }
        let plane = CGMutablePath()
        for cell in miniCells { plane.addRect(cell) }
        miniZones.name = "SpaceCanvas.minimapZones"
        for (ink, path, fill, stroke) in [(CAShapeLayer(), plane as CGPath, CGFloat(0.03), CGFloat(0.14)),
                                         (miniZones, minimapZonePath(), CGFloat(0.08), CGFloat(0.26))] {
            ink.frame = minimap.bounds
            ink.path = path
            ink.fillColor = NSColor.white.withAlphaComponent(fill).cgColor
            ink.strokeColor = NSColor.white.withAlphaComponent(stroke).cgColor
            ink.lineWidth = 0.5
            ink.contentsScale = scale
            minimap.addSublayer(ink)
        }
        if miniCells.indices.contains(current) {
            let dot = CALayer()
            let cell = miniCells[current]
            dot.frame = CGRect(x: cell.maxX - 6, y: cell.minY + 2.5, width: 3.5, height: 3.5)
            dot.cornerRadius = 1.75
            dot.backgroundColor = SpaceFilmstripView.accent.cgColor
            minimap.addSublayer(dot)
        }
        miniViewport.borderWidth = 1
        miniViewport.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        miniViewport.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        miniViewport.cornerRadius = 1.5
        minimap.addSublayer(miniViewport)
        miniRing.borderWidth = 1.25
        miniRing.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        miniRing.cornerRadius = 2
        minimap.addSublayer(miniRing)
    }

    private func minimapZonePath() -> CGPath {
        let zones = CGMutablePath()
        for (cell, card) in zip(miniCells, cards) {
            let inner = cell.insetBy(dx: min(2, cell.width * 0.06), dy: min(2, cell.height * 0.08))
            for window in card.windows {
                zones.addRect(CGRect(x: inner.minX + window.rect.minX * inner.width, y: inner.minY + window.rect.minY * inner.height,
                                     width: window.rect.width * inner.width, height: window.rect.height * inner.height))
            }
        }
        return zones
    }

    private func text(_ string: String, size: CGFloat, color: NSColor, mono: Bool) -> CATextLayer {
        let label = CATextLayer()
        label.string = string
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) : NSFont.systemFont(ofSize: size, weight: .medium)
        label.font = font
        label.fontSize = size
        label.foregroundColor = color.cgColor
        // The plane zooms in up to about twice its built size.
        label.contentsScale = scale * 2
        label.truncationMode = .end
        return label
    }
}

/// Calls back once when an animation reaches its end. A replaced or removed
/// animation never reports: it must not authorise what follows it. The
/// landing's failsafe covers a move that never finishes.
final class SpaceCanvasArrival: NSObject, CAAnimationDelegate {
    private var done: (() -> Void)?
    init(_ done: @escaping () -> Void) { self.done = done }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let done = self.done
        self.done = nil
        if flag { done?() }
    }
}
