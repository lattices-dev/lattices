import AppKit
import QuartzCore

private final class SpaceFilmstripLayerHost: NSView {
    override var isFlipped: Bool { true }
}

struct SpaceFilmstripCard: Equatable {
    let id: Int
    let number: Int
    let windows: [SpaceFilmstripWindow]
}

struct SpaceFilmstripWindow: Equatable {
    let rect: CGRect
    let app: String
    /// For the canvas's app icon and caption only; the strip draws neither.
    var pid: Int32 = 0
    var title: String = ""
    /// Identity and source crop for optional close-up imagery. The filmstrip
    /// itself still draws only geometry and never captures a window.
    var wid: UInt32 = 0
    var contentsRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Pure geometry shared by the renderer and regression tests. No screen
/// capture, AX, image decoding, or WindowServer calls occur in this model.
enum SpaceFilmstripLayout {
    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 105
    static let stride: CGFloat = 178
    static let height: CGFloat = 178

    static func trayWidth(screenWidth: CGFloat, count: Int) -> CGFloat {
        min(max(0, screenWidth - 48), 1000, max(240, CGFloat(count) * stride + 32))
    }

    static func offset(selected: Int, viewportWidth: CGFloat) -> CGFloat {
        viewportWidth / 2 - cardWidth / 2 - CGFloat(selected) * stride
    }

    /// Columns and rows of the aperture's zoomed-out map. Square-ish and
    /// regular: 16 desktops read 4 × 4, fewer use fewer columns and rows.
    static func gridShape(count: Int) -> (columns: Int, rows: Int) {
        let count = max(1, count)
        let columns = Int(ceil(Double(count).squareRoot()))
        return (columns, Int(ceil(Double(count) / Double(columns))))
    }

    /// One connected plane: 16:10 cells adjoin with no gutters, centred in
    /// `frame`, in reading order.
    static func gridCells(count: Int, in frame: CGRect, aspect: CGFloat = 1.6) -> [CGRect] {
        guard count > 0 else { return [] }
        let shape = gridShape(count: count)
        let width = min(frame.width / CGFloat(shape.columns), frame.height / CGFloat(shape.rows) * aspect)
        let height = width / aspect
        let origin = CGPoint(x: frame.midX - width * CGFloat(shape.columns) / 2,
                             y: frame.midY - height * CGFloat(shape.rows) / 2)
        return (0..<count).map { i in
            CGRect(x: origin.x + CGFloat(i % shape.columns) * width,
                   y: origin.y + CGFloat(i / shape.columns) * height, width: width, height: height)
        }
    }

    static func cards(spaces: [SpaceInfo], windows: [WindowEntry], bounds: CGRect) -> [SpaceFilmstripCard] {
        guard !spaces.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return spaces.map { SpaceFilmstripCard(id: $0.id, number: $0.index, windows: []) }
        }

        // Sort the inventory once, then retain at most six visible windows
        // per desktop. Never rescan or sort it separately for each desktop.
        let requested = Set(spaces.map(\.id))
        let ownPID = getpid()
        var members: [Int: [SpaceFilmstripWindow]] = [:]
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for window in windows.sorted(by: { $0.zIndex < $1.zIndex }) {
            // Inactive desktops need neither a CG title nor AX verification.
            guard !window.appHidden, !window.collapsed, window.pid != ownPID,
                  window.frame.w >= 120, window.frame.h >= 120 else { continue }
            var preview: SpaceFilmstripWindow?
            for (index, id) in window.spaceIds.enumerated() where requested.contains(id) {
                guard (members[id]?.count ?? 0) < 6,
                      !window.spaceIds[..<index].contains(id) else { continue }
                if preview == nil {
                    let frame = window.frame
                    let source = CGRect(x: (frame.x - bounds.minX) / bounds.width,
                                      y: (frame.y - bounds.minY) / bounds.height,
                                      width: frame.w / bounds.width, height: frame.h / bounds.height)
                    let rect = source.intersection(unit)
                    // Clip before counting: off-display windows cannot crowd
                    // a visible window out of the six preview slots.
                    guard !rect.isNull, rect.width > 0.01, rect.height > 0.01 else { break }
                    let crop = CGRect(x: (rect.minX - source.minX) / source.width,
                                      y: (rect.minY - source.minY) / source.height,
                                      width: rect.width / source.width, height: rect.height / source.height)
                    preview = SpaceFilmstripWindow(rect: rect, app: window.app, pid: window.pid,
                                                   title: window.title, wid: window.wid, contentsRect: crop)
                }
                guard let preview else { continue }
                members[id, default: []].append(preview)
            }
        }
        return spaces.map { space in
            SpaceFilmstripCard(id: space.id, number: space.index,
                windows: Array((members[space.id] ?? []).reversed()))
        }
    }
}

/// Native layer tree: move one track, keep one focus frame still.
///
/// Retargets are additive: the model jumps to the new goal and an additive
/// animation carries the remaining delta down to zero. Nothing reads the
/// presentation layer, which lags the model until Core Animation commits —
/// a reopen or two selects in one run-loop pass used to start the travel
/// from the previous gesture's resting place, a visible hop. The curve
/// leaves with zero slope, so position and speed both stay continuous
/// through reversals and merged bursts.
/// No frame callbacks, SwiftUI invalidations, or work on the switch queue.
///
/// The aperture zoom keeps the same frame: the reel fades and a connected
/// map of every desktop recedes into the aperture from the selected card's
/// size. Built on first zoom from the cards' cached zones; reversible.
final class SpaceFilmstripView: NSView {
    override var isFlipped: Bool { true }
    private let glass = NSVisualEffectView()
    private let reelHost = SpaceFilmstripLayerHost()
    private let tray = CALayer()
    private let surface = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let channel = CALayer()
    /// A faint lit well behind the aperture: it stays still while the film
    /// passes over it, and it holds the odometer when the film hides.
    private let well = CAGradientLayer()
    private let viewport = CALayer()
    private let track = CALayer()
    private let focusBacklight = CALayer()
    private let focus = CAGradientLayer()
    private let focusMask = CAShapeLayer()
    private let focusKeyline = CALayer()
    private let fade = CAGradientLayer()
    private let rail = CALayer()
    private let marker = CALayer()
    private let counter = CALayer()
    private let lens = CALayer()
    private let content = CALayer()
    private let gridRing = CALayer()
    private var gridCells: [CGRect] = []
    private var models: [SpaceFilmstripCard] = []
    private var configuredSize: CGSize?
    private(set) var configurationCount = 0
    private(set) var isZoomed = false
    private var reels: [CALayer] = []
    private var counterNumber: Int?
    private(set) var isScrubbing = false
    /// The mark's one accent, `#ef6a47`: only the active desktop takes hue.
    static let accent = NSColor(srgbRed: 0.937, green: 0.416, blue: 0.278, alpha: 1)
    private var cards: [CALayer] = []
    private var bookends: [CALayer] = []
    private var railCells: [CALayer] = []
    private(set) var selected: Int?
    private var scale: CGFloat = 2
    private var railStride: CGFloat = 11
    private var railCellSize: CGFloat = 7
    private var legSerial = 0

    static let travelDuration: CFTimeInterval = 0.18
    static let zoomDuration: CFTimeInterval = 0.20
    /// Zero initial slope: stacked additive deltas never add a speed step.
    static let travelTiming = CAMediaTimingFunction(controlPoints: 0.22, 0, 0, 1)

    /// Model goals, for tests and diagnostics. Never the presentation layer.
    var trackX: CGFloat { track.position.x }
    var markerX: CGFloat { marker.position.x }
    var cardOpacities: [Float] { cards.map(\.opacity) }
    var animationCount: Int {
        ([tray, track, marker, viewport, counter, lens, content, gridRing] + cards + reels).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }
    /// Remaining additive travel legs on the track, oldest first.
    var trackDeltas: [CGFloat] {
        (track.animationKeys() ?? []).sorted {
            (Int($0.dropFirst(4)) ?? 0) < (Int($1.dropFirst(4)) ?? 0)
        }.compactMap {
            ((track.animation(forKey: $0) as? CABasicAnimation)?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
        }
    }

    static func emphasis(distance: Int) -> Float {
        distance == 0 ? 1 : distance == 1 ? 0.72 : distance == 2 ? 0.50 : 0.36
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // One bounded material behind the retained reel, never one blur per card.
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        addSubview(glass)
        // AppKit inserts subview backing layers when attaching to a window.
        // A manual root sublayer ends up UNDER the material at that point.
        // Keep the reel in a sibling view so AppKit owns their stacking order.
        reelHost.wantsLayer = true
        reelHost.autoresizingMask = [.width, .height]
        addSubview(reelHost, positioned: .above, relativeTo: glass)
        tray.name = "SpaceFilmstrip.tray"
        reelHost.layer?.addSublayer(tray)
        tray.cornerRadius = 16
        // Mid-screen over a light backdrop: a soft, close shadow that stays
        // inside the panel's 16pt margin rather than a long drop.
        tray.shadowColor = NSColor.black.cgColor
        tray.shadowOpacity = 0.42
        tray.shadowRadius = 12
        tray.shadowOffset = CGSize(width: 0, height: 5)
        // The original graphite frame; white light defines its shallow lip.
        updateGlass()
        surface.startPoint = CGPoint(x: 0.5, y: 0)
        surface.endPoint = CGPoint(x: 0.5, y: 1)
        surface.cornerRadius = 16
        tray.addSublayer(surface)
        channel.backgroundColor = NSColor.black.withAlphaComponent(0.26).cgColor
        channel.cornerRadius = 11
        channel.borderWidth = 0.5
        channel.borderColor = NSColor.black.withAlphaComponent(0.34).cgColor
        tray.addSublayer(channel)
        well.colors = [NSColor.white.withAlphaComponent(0.055).cgColor,
                       NSColor.white.withAlphaComponent(0.02).cgColor]
        well.startPoint = CGPoint(x: 0.5, y: 0)
        well.endPoint = CGPoint(x: 0.5, y: 1)
        well.cornerRadius = 9
        tray.addSublayer(well)
        tray.addSublayer(viewport)
        viewport.masksToBounds = true
        viewport.addSublayer(track)
        viewport.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        // The zoomed-out map sits inside the fixed aperture, under its frame.
        lens.masksToBounds = true
        lens.cornerRadius = 8
        lens.opacity = 0
        lens.addSublayer(content)
        gridRing.borderWidth = 1
        gridRing.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        gridRing.cornerRadius = 2
        gridRing.opacity = 0
        let dot = CALayer()
        dot.backgroundColor = Self.accent.cgColor
        dot.cornerRadius = 1.5
        gridRing.addSublayer(dot)
        lens.addSublayer(gridRing)
        tray.addSublayer(lens)
        focusBacklight.name = "SpaceFilmstrip.backlight"
        focusBacklight.shadowColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1).cgColor
        focusBacklight.shadowRadius = 10
        focusBacklight.shadowOffset = CGSize(width: 0, height: -1)
        tray.addSublayer(focusBacklight)
        tray.addSublayer(focus)
        // A light active treatment: a lit top edge that thins down the
        // sides. The selected card's full opacity carries the rest.
        focus.colors = [NSColor(calibratedWhite: 1, alpha: 0.96).cgColor,
                        NSColor(calibratedWhite: 0.90, alpha: 0.34).cgColor,
                        NSColor(calibratedWhite: 0.94, alpha: 0.50).cgColor]
        focus.locations = [0, 0.65, 1]
        focus.startPoint = CGPoint(x: 0.5, y: 0)
        focus.endPoint = CGPoint(x: 0.5, y: 1)
        focus.mask = focusMask
        focusMask.fillColor = nil
        focusMask.strokeColor = NSColor.black.cgColor
        focusMask.lineWidth = 1
        focusKeyline.cornerRadius = 8
        focusKeyline.borderWidth = 0.5
        focusKeyline.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tray.addSublayer(focusKeyline)
        rim.colors = [NSColor.white.withAlphaComponent(0.38).cgColor,
                      NSColor.white.withAlphaComponent(0.07).cgColor,
                      NSColor.white.withAlphaComponent(0.18).cgColor]
        rim.locations = [0, 0.55, 1]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        rim.mask = rimMask
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 0.75
        tray.addSublayer(rim)
        tray.addSublayer(rail)
        marker.backgroundColor = Self.accent.cgColor
        marker.cornerRadius = 2
        rail.addSublayer(marker)
        counter.masksToBounds = true
        counter.opacity = 0
        tray.addSublayer(counter)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    private func updateGlass() {
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // The near-opaque frame covered 99% of this material, while the
        // WindowServer still filtered the desktop underneath every frame.
        // Keep the optical edge/backlight; make the backing genuinely solid.
        glass.isHidden = true
        focusBacklight.shadowOpacity = solid ? 0 : 0.32
        surface.colors = [NSColor(calibratedRed: 0.106, green: 0.110, blue: 0.116, alpha: 1).cgColor,
                          NSColor(calibratedRed: 0.058, green: 0.060, blue: 0.066, alpha: 1).cgColor]
        surface.locations = [0, 1]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func configure(cards models: [SpaceFilmstripCard], size: CGSize, scale: CGFloat) -> Bool {
        // One retained display, keyed by the complete inventory projection.
        // Reopening identical content does not allocate/rasterize every label.
        if self.models == models, configuredSize == size, self.scale == scale {
            resetPresentation()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateGlass()
            CATransaction.commit()
            return false
        }
        clear()
        configuredSize = size
        configurationCount += 1
        self.scale = scale
        self.models = models
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reelHost.frame = CGRect(origin: .zero, size: size)
        tray.frame = CGRect(x: 16, y: 12, width: size.width - 32, height: size.height - 28)
        tray.shadowPath = CGPath(roundedRect: tray.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        glass.frame = tray.frame
        updateGlass()
        surface.frame = tray.bounds
        channel.frame = tray.bounds.insetBy(dx: 6, dy: 6)
        channel.frame.size.height = 117
        rim.frame = tray.bounds
        rimMask.frame = rim.bounds
        rimMask.path = CGPath(roundedRect: rim.bounds.insetBy(dx: 0.5, dy: 0.5),
                              cornerWidth: 15.5, cornerHeight: 15.5, transform: nil)
        viewport.frame = CGRect(x: 0, y: 6, width: tray.bounds.width, height: 133)
        fade.frame = viewport.bounds
        let stop = min(0.25, 22 / max(1, viewport.bounds.width))
        fade.locations = [0, NSNumber(value: Double(stop)), NSNumber(value: Double(1 - stop)), 1]
        track.anchorPoint = .zero
        track.transform = CATransform3DIdentity
        track.position = .zero
        track.bounds = CGRect(x: 0, y: 0, width: CGFloat(models.count) * SpaceFilmstripLayout.stride, height: 133)
        focus.frame = CGRect(x: (tray.bounds.width - 176) / 2, y: 7, width: 176, height: 113)
        focusMask.frame = focus.bounds
        focusMask.path = CGPath(roundedRect: focus.bounds.insetBy(dx: 0.5, dy: 0.5),
                                cornerWidth: 9, cornerHeight: 9, transform: nil)
        focusBacklight.frame = focus.frame
        focusBacklight.shadowPath = focusMask.path?.copy(strokingWithWidth: 2,
            lineCap: .round, lineJoin: .round, miterLimit: 1)
        focusKeyline.frame = focus.frame.insetBy(dx: 1.5, dy: 1.5)
        well.frame = focus.frame.insetBy(dx: 1, dy: 1)
        lens.frame = focus.frame
        content.frame = lens.bounds
        [surface, channel, well, rim, rimMask, focus, focusMask, focusKeyline].forEach { $0.contentsScale = scale }
        for (i, model) in models.enumerated() {
            let card = makeCard(model)
            card.frame = CGRect(x: CGFloat(i) * SpaceFilmstripLayout.stride, y: 5, width: 168, height: 127)
            track.addSublayer(card)
            cards.append(card)
        }
        // Bookends belong to the track, but never to the desktop selection.
        // They take whole slots of the film's own stride, as many as the
        // half-viewport beside an end card can show (at most two), so the
        // reel's rhythm runs straight into them. Their details disappear
        // with the viewport during number-only holds.
        let reach = (viewport.bounds.width - SpaceFilmstripLayout.cardWidth) / 2
        let slots = min(2, Int(reach / SpaceFilmstripLayout.stride))
        if !models.isEmpty, slots > 0 {
            let span = CGFloat(slots) * SpaceFilmstripLayout.stride
            let empty = models.filter(\.windows.isEmpty).count
            for (x, leading) in [(-span, true), (CGFloat(models.count) * SpaceFilmstripLayout.stride, false)] {
                let bookend = makeBookend(models: models, empty: empty,
                                          width: span - (SpaceFilmstripLayout.stride - SpaceFilmstripLayout.cardWidth),
                                          leading: leading)
                bookend.frame.origin = CGPoint(x: x, y: 5)
                track.addSublayer(bookend)
                bookends.append(bookend)
            }
        }
        railStride = min(11, (tray.bounds.width - 48) / CGFloat(max(1, models.count)))
        railCellSize = min(7, railStride * 0.64)
        let railWidth = CGFloat(max(0, models.count - 1)) * railStride + railCellSize
        rail.frame = CGRect(x: (tray.bounds.width - railWidth) / 2, y: 140, width: railWidth, height: 3)
        for i in models.indices {
            let cell = CALayer()
            cell.frame = CGRect(x: CGFloat(i) * railStride, y: 0, width: railCellSize, height: 3)
            cell.cornerRadius = min(1.5, railCellSize / 2)
            cell.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            rail.insertSublayer(cell, below: marker)
            railCells.append(cell)
        }
        counter.frame = CGRect(x: (tray.bounds.width - 68) / 2, y: 34, width: 68, height: 52)
        marker.transform = CATransform3DIdentity
        marker.frame = CGRect(x: 0, y: 0, width: railCellSize, height: 3)
        CATransaction.commit()
        return true
    }

    /// Inventory can finish after opening. Replace only preview ink; the
    /// retained card roots own emphasis, and the track owns ongoing travel.
    /// A changed desktop order needs a new configuration on the next open.
    @discardableResult
    func refresh(cards updated: [SpaceFilmstripCard]) -> Bool {
        guard updated != models, updated.count == models.count,
              zip(updated, models).allSatisfy({ $0.id == $1.id && $0.number == $1.number }) else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in models.indices where updated[index] != models[index] {
            let ink = makeCard(updated[index])
            cards[index].sublayers?.forEach { $0.removeFromSuperlayer() }
            for child in ink.sublayers ?? [] { cards[index].addSublayer(child) }
        }
        models = updated
        let empty = models.filter(\.windows.isEmpty).count
        for (index, old) in bookends.enumerated() {
            let ink = makeBookend(models: models, empty: empty, width: old.bounds.width, leading: index == 0)
            old.sublayers?.forEach { $0.removeFromSuperlayer() }
            for child in ink.sublayers ?? [] { old.addSublayer(child) }
        }
        if !gridCells.isEmpty { buildGrid() }
        CATransaction.commit()
        return true
    }

    func select(_ index: Int, animated: Bool) {
        guard cards.indices.contains(index), selected != index else { return }
        let animate = animated && selected != nil
        // Zoomed out, the hidden reel jumps; only the map's ring travels.
        let reel = animate && !isZoomed
        let x = SpaceFilmstripLayout.offset(selected: index, viewportWidth: viewport.bounds.width)
        let markerX = CGFloat(index) * railStride + railCellSize / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isZoomed { placeRing(index, animated: animate) }
        retarget(track, keyPath: "position.x", from: track.position.x, to: x, animate: reel)
        track.position.x = x
        retarget(marker, keyPath: "position.x", from: marker.position.x, to: markerX, animate: animate)
        marker.position.x = markerX
        for (i, card) in cards.enumerated() {
            let opacity = Self.emphasis(distance: abs(i - index))
            retarget(card, keyPath: "opacity", from: CGFloat(card.opacity), to: CGFloat(opacity), animate: reel)
            card.opacity = opacity
        }
        selected = index
        CATransaction.commit()
        setAccessibilityLabel("Desktop \(index + 1) of \(cards.count)\(isZoomed ? ", all desktops" : "")")
    }

    /// The canvas hand-off reads the strip's own cards and where its
    /// aperture and map sit, in this view's coordinates.
    var cardModels: [SpaceFilmstripCard] { models }
    var apertureFrame: CGRect {
        // Stay within our layer tree; AppKit flips view backing layers when
        // they attach. The reel host shares this view's flipped coordinates.
        tray.convert(lens.bounds, from: lens).offsetBy(dx: tray.frame.minX, dy: tray.frame.minY)
    }
    var mapFrame: CGRect {
        if gridCells.isEmpty, !models.isEmpty { buildGrid() }
        let map = gridCells.reduce(CGRect.null) { $0.union($1) }
        guard !map.isNull else { return apertureFrame }
        return tray.convert(map, from: lens).offsetBy(dx: tray.frame.minX, dy: tray.frame.minY)
    }

    /// Reversible zoom in the fixed aperture. Out: the reel fades at once
    /// and the map recedes from the selected card's size to the whole
    /// plane. In: the map closes on the selected cell and hands back to the
    /// reel. Finite Core Animation legs only; nothing runs once settled.
    /// Reduce Motion crossfades without the scale.
    func setZoomed(_ zoomed: Bool, reduceMotion: Bool) {
        guard zoomed != isZoomed, let index = selected, !models.isEmpty else { return }
        if gridCells.isEmpty { buildGrid() }
        guard gridCells.indices.contains(index) else { return }
        isZoomed = zoomed
        let travel = reduceMotion ? 0 : Self.zoomDuration
        let crossfade: CFTimeInterval = reduceMotion ? 0.12 : 0.14
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeRing(index, animated: false)
        let near = magnification(for: index)
        let goal = zoomed ? CATransform3DIdentity : near
        if travel > 0 {
            let from = content.animation(forKey: "zoom") != nil
                ? (content.presentation()?.transform ?? content.transform)
                : (zoomed ? near : CATransform3DIdentity)
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: from)
            move.toValue = NSValue(caTransform3D: goal)
            move.duration = travel
            move.timingFunction = Self.travelTiming
            content.add(move, forKey: "zoom")
        }
        content.transform = goal
        let late = max(0, travel - crossfade)
        fade(lens, to: zoomed ? 1 : 0, duration: crossfade, delay: zoomed ? 0 : late)
        fade(viewport, to: zoomed || isScrubbing ? 0 : 1, duration: crossfade, delay: zoomed ? 0 : late)
        fade(gridRing, to: zoomed ? 1 : 0, duration: crossfade, delay: zoomed ? travel * 0.55 : 0)
        CATransaction.commit()
        setAccessibilityLabel("Desktop \(index + 1) of \(cards.count)\(zoomed ? ", all desktops" : "")")
    }

    /// The map's transform that makes cell `index` coincide with the reel's
    /// centred card inside the aperture.
    private func magnification(for index: Int) -> CATransform3D {
        let cell = gridCells[index]
        let target = lens.bounds.insetBy(dx: 4, dy: 4)
        let s = target.width / cell.width
        let mid = CGPoint(x: lens.bounds.midX, y: lens.bounds.midY)
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
            CATransform3DMakeTranslation(target.midX - mid.x - s * (cell.midX - mid.x),
                                         target.midY - mid.y - s * (cell.midY - mid.y), 0))
    }

    private func placeRing(_ index: Int, animated: Bool) {
        guard gridCells.indices.contains(index) else { return }
        let frame = gridCells[index].insetBy(dx: -0.5, dy: -0.5)
        let goal = CGPoint(x: frame.midX, y: frame.midY)
        retarget(gridRing, keyPath: "position.x", from: gridRing.position.x, to: goal.x, animate: animated)
        retarget(gridRing, keyPath: "position.y", from: gridRing.position.y, to: goal.y, animate: animated)
        gridRing.position = goal
    }

    /// One connected plane in two batched paths: cells share their seams,
    /// zones come from the cards' cached rects. Numbers only when legible.
    private func buildGrid() {
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        gridCells = SpaceFilmstripLayout.gridCells(count: models.count, in: lens.bounds.insetBy(dx: 7, dy: 7))
        let plane = CGMutablePath()
        let zones = CGMutablePath()
        for (cell, model) in zip(gridCells, models) {
            plane.addRect(cell)
            let inner = cell.insetBy(dx: min(2, cell.width * 0.06), dy: min(2, cell.height * 0.08))
            for window in model.windows {
                zones.addRoundedRect(in: CGRect(x: inner.minX + window.rect.minX * inner.width,
                                                y: inner.minY + window.rect.minY * inner.height,
                                                width: window.rect.width * inner.width,
                                                height: window.rect.height * inner.height),
                                     cornerWidth: 0.75, cornerHeight: 0.75)
            }
        }
        for (path, fill, stroke) in [(plane, CGFloat(0.03), CGFloat(0.12)), (zones, CGFloat(0.07), CGFloat(0.28))] {
            let ink = CAShapeLayer()
            ink.frame = content.bounds
            ink.path = path
            ink.fillColor = NSColor.white.withAlphaComponent(fill).cgColor
            ink.strokeColor = NSColor.white.withAlphaComponent(stroke).cgColor
            ink.lineWidth = 0.5
            ink.contentsScale = scale
            content.addSublayer(ink)
        }
        if let first = gridCells.first, first.width >= 24 {
            for (cell, model) in zip(gridCells, models) {
                let number = label("\(model.number)", size: 6.5, color: NSColor.white.withAlphaComponent(0.5))
                number.frame = CGRect(x: cell.minX + 2.5, y: cell.minY + 1.5, width: 16, height: 9)
                content.addSublayer(number)
            }
        }
        if let first = gridCells.first {
            gridRing.bounds = CGRect(x: 0, y: 0, width: first.width + 1, height: first.height + 1)
            gridRing.sublayers?.first?.frame = CGRect(x: first.width - 4.5, y: 2, width: 3, height: 3)
        }
    }

    /// One clipped reel per decimal place. Each row is retained for the
    /// gesture; repeats only move two layers and never select a preview card.
    private func configureCounter(total: Int) {
        reels.forEach { $0.removeFromSuperlayer() }
        reels = []
        let digits = max(2, String(total).count)
        counter.frame = CGRect(x: (tray.bounds.width - CGFloat(digits) * 34) / 2, y: 34, width: CGFloat(digits) * 34, height: 52)
        for column in 0..<digits {
            let divisor = Int(pow(10.0, Double(digits - column - 1)))
            let reel = CALayer()
            reel.anchorPoint = .zero
            reel.frame = CGRect(x: CGFloat(column) * 34, y: 0, width: 34,
                                height: CGFloat(total / divisor + 1) * 52)
            for row in 0...(total / divisor) {
                let digit = label("\(row % 10)", size: 42, color: NSColor.white.withAlphaComponent(0.92))
                digit.font = NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .light)
                digit.alignmentMode = .center
                digit.frame = CGRect(x: 0, y: CGFloat(row) * 52, width: 34, height: 52)
                reel.addSublayer(digit)
            }
            counter.addSublayer(reel)
            reels.append(reel)
        }
    }

    func scrub(number: Int, total: Int, animated: Bool, selectedIndex: Int? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reels.isEmpty { configureCounter(total: max(total, number)) }
        if !isScrubbing {
            // Finish any single-tap travel; the previews stay in this position
            // for the whole hold and never chase the odometer.
            track.removeAllAnimations()
            cards.forEach { $0.removeAllAnimations() }
            viewport.opacity = 0
            counter.opacity = 1
            isScrubbing = true
        }
        marker.removeAllAnimations()
        marker.position.x = CGFloat(min(max(selectedIndex ?? number - 1, 0), max(0, cards.count - 1))) * railStride + railCellSize / 2
        if number != counterNumber {
            for (column, reel) in reels.enumerated() {
                let divisor = Int(pow(10.0, Double(reels.count - column - 1)))
                let y = -CGFloat(number / divisor) * 52
                retarget(reel, keyPath: "position.y", from: reel.position.y, to: y,
                         animate: animated && counterNumber != nil, duration: 0.12)
                reel.position.y = y
            }
            counterNumber = number
        }
        CATransaction.commit()
        setAccessibilityLabel("\(number) of \(total)")
    }

    func endScrubbing(at index: Int?, animated: Bool) {
        guard isScrubbing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isScrubbing = false
        track.removeAllAnimations()
        marker.removeAllAnimations()
        cards.forEach { $0.removeAllAnimations() }
        if let index { select(index, animated: false) }
        let shown: Float = isZoomed ? 0 : 1
        retarget(viewport, keyPath: "opacity", from: CGFloat(viewport.opacity), to: CGFloat(shown), animate: animated, duration: 0.16)
        viewport.opacity = shown
        retarget(counter, keyPath: "opacity", from: CGFloat(counter.opacity), to: 0, animate: animated, duration: 0.12)
        counter.opacity = 0
        counterNumber = nil
        CATransaction.commit()
    }

    func clear() {
        resetPresentation()
        cards.forEach { $0.removeFromSuperlayer() }
        railCells.forEach { $0.removeFromSuperlayer() }
        bookends.forEach { $0.removeFromSuperlayer() }
        bookends.removeAll(keepingCapacity: false)
        cards.removeAll(keepingCapacity: false)
        railCells.removeAll(keepingCapacity: false)
        models.removeAll(keepingCapacity: false)
        configuredSize = nil
    }

    /// End gesture-local motion without throwing away the bounded preview.
    func resetPresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.removeAllAnimations()
        marker.removeAllAnimations()
        tray.removeAllAnimations()
        rim.removeAllAnimations()
        focus.removeAllAnimations()
        cards.forEach { $0.removeAllAnimations() }
        selected = nil
        isScrubbing = false
        counterNumber = nil
        counter.removeAllAnimations()
        viewport.removeAllAnimations()
        reels.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        reels = []
        counter.opacity = 0
        viewport.opacity = 1
        isZoomed = false
        gridCells = []
        content.removeAllAnimations()
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        content.transform = CATransform3DIdentity
        lens.removeAllAnimations()
        lens.opacity = 0
        gridRing.removeAllAnimations()
        gridRing.opacity = 0
        CATransaction.commit()
    }

    /// The edge light resolves a beat after the surface arrives, outer rim
    /// first, then settling inward onto the aperture; all of
    /// it lands at 180ms. The tray itself settles from 98.5% in the same
    /// window, about its own centre, so the aperture never shifts sideways.
    /// Only on a fresh opening; key repeats and interrupted departures
    /// retain the frame.
    func illuminateFrame(animated: Bool) {
        guard animated else { return }
        let now = CACurrentMediaTime()
        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.985
        settle.toValue = 1
        settle.duration = 0.18
        settle.timingFunction = Self.travelTiming
        tray.add(settle, forKey: "arrivalSettle")
        for (edge, delay) in [(rim, 0.0), (focus, 0.05)] as [(CALayer, CFTimeInterval)] {
            let light = CABasicAnimation(keyPath: "opacity")
            light.isAdditive = true
            light.fromValue = -0.65
            light.toValue = 0
            light.beginTime = delay > 0 ? edge.convertTime(now, from: nil) + delay : 0
            light.fillMode = .backwards
            light.duration = max(0.06, 0.18 - delay)
            light.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0, 0.25, 1)
            edge.add(light, forKey: "arrivalLight")
        }
    }

    /// Adds the remaining delta as an additive, self-removing animation.
    /// Each leg gets its own key, so an in-flight leg keeps easing out
    /// underneath the new one and removes itself when done.
    private func retarget(_ layer: CALayer, keyPath: String, from: CGFloat, to: CGFloat, animate: Bool, duration: CFTimeInterval = SpaceFilmstripView.travelDuration) {
        guard animate, abs(from - to) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = from - to
        animation.toValue = 0
        animation.duration = duration
        animation.timingFunction = Self.travelTiming
        legSerial &+= 1
        layer.add(animation, forKey: "leg.\(legSerial)")
    }

    /// A finite opacity leg toward `opacity`, optionally after `delay`.
    /// Additive like the travel legs, so a reversal never pops.
    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let from = CGFloat(layer.opacity)
        layer.opacity = opacity
        guard duration > 0, abs(from - CGFloat(opacity)) > 0.001 else { return }
        let leg = CABasicAnimation(keyPath: "opacity")
        leg.isAdditive = true
        leg.fromValue = from - CGFloat(opacity)
        leg.toValue = 0
        leg.duration = duration
        if delay > 0 {
            leg.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            leg.fillMode = .backwards
        }
        leg.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
        legSerial &+= 1
        layer.add(leg, forKey: "leg.\(legSerial)")
    }

    /// A quiet, non-interactive colophon at each end of the desktop reel: a
    /// ghost frame whose fill and hairline dissolve away from the film, with
    /// its type set flush to the reel-facing edge. Built once per opening;
    /// selection and repeat events do no summary work. Every figure comes
    /// from the cards themselves — `empty` matches the cards' own "Empty".
    private func makeBookend(models: [SpaceFilmstripCard], empty: Int, width: CGFloat, leading: Bool) -> CALayer {
        let count = models.count
        let card = CALayer()
        card.bounds = CGRect(x: 0, y: 0, width: width, height: SpaceFilmstripLayout.cardHeight)
        // Strong at the film, gone by the far edge.
        let toward = leading ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0, y: 0.5)
        let away = leading ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 1, y: 0.5)
        let fill = CAGradientLayer()
        fill.frame = card.bounds
        fill.cornerRadius = 6
        fill.colors = [NSColor.white.withAlphaComponent(0.035).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        fill.startPoint = toward
        fill.endPoint = away
        card.addSublayer(fill)
        let edge = CAGradientLayer()
        edge.frame = card.bounds
        edge.colors = [NSColor.white.withAlphaComponent(0.13).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        edge.locations = [0, 0.8]
        edge.startPoint = toward
        edge.endPoint = away
        let edgeMask = CAShapeLayer()
        edgeMask.frame = edge.bounds
        edgeMask.path = CGPath(roundedRect: edge.bounds.insetBy(dx: 0.375, dy: 0.375),
                               cornerWidth: 6, cornerHeight: 6, transform: nil)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 0.75
        edge.mask = edgeMask
        card.addSublayer(edge)
        [fill, edge, edgeMask].forEach { $0.contentsScale = scale }

        let inset: CGFloat = 18
        let flush: CATextLayerAlignmentMode = leading ? .right : .left
        // The brand closes the reel at the outer edge on both sides. Keep
        // the zoom hint inward, next to the desktops it describes.
        let columnWidth = min(132, width - inset * 2)
        let column = CGRect(x: leading ? inset : width - inset - columnWidth,
                            y: 0, width: columnWidth, height: card.bounds.height)
        if width >= 300 {
            let map = makeCanvasMiniature(models: models)
            map.frame.origin = CGPoint(x: leading ? width - inset - 134 : inset + 10, y: 19)
            card.addSublayer(map)
        }
        // `trail` is space kept free after the text in reading order: to its
        // left on the trailing bookend, to its right on the leading one.
        func place(_ text: CATextLayer, y: CGFloat, height: CGFloat, trail: CGFloat = 0) {
            text.alignmentMode = flush
            text.frame = CGRect(x: column.minX + (leading ? 0 : trail), y: y,
                                width: column.width - trail, height: height)
            card.addSublayer(text)
        }

        // Lockup: LatticesMark's geometry (pad 10%, gap 6%, radius 18% of a
        // cell) in white, the orange stays with the active desktop.
        let wordFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let word = label("Lattices", size: 11, color: NSColor.white.withAlphaComponent(0.62))
        word.font = wordFont
        let wordWidth = ceil(("Lattices" as NSString).size(withAttributes: [.font: wordFont]).width)
        let markSize: CGFloat = 14, markGap: CGFloat = 6
        let markX = leading ? column.maxX - wordWidth - markGap - markSize : column.minX
        let pad = markSize * 0.1, gap = markSize * 0.06, cell = (markSize - 2 * pad - 2 * gap) / 3
        for (i, bright) in [true, false, false, true, false, false, true, true, true].enumerated() {
            let square = CALayer()
            square.frame = CGRect(x: markX + pad + CGFloat(i % 3) * (cell + gap),
                                  y: 16 + pad + CGFloat(i / 3) * (cell + gap), width: cell, height: cell)
            square.cornerRadius = cell * 0.18
            square.backgroundColor = NSColor.white.withAlphaComponent(bright ? 0.62 : 0.14).cgColor
            card.addSublayer(square)
        }
        place(word, y: 15.5, height: 16, trail: leading ? 0 : markSize + markGap)

        // The total, set like the odometer that replaces this view mid-hold.
        let figure = "\(count)", noun = count == 1 ? "desktop" : "desktops"
        let figureFont = NSFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        let figureWidth = ceil((figure as NSString).size(withAttributes: [.font: figureFont]).width)
        let nounWidth = ceil((noun as NSString)
            .size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width)
        let number = label(figure, size: 24, color: NSColor.white.withAlphaComponent(0.80))
        number.font = figureFont
        place(number, y: 43, height: 30, trail: leading ? nounWidth + 6 : 0)
        place(label(noun, size: 10, color: NSColor.white.withAlphaComponent(0.48)), y: 57, height: 14,
              trail: leading ? 0 : figureWidth + 6)

        let detail = empty > 0 ? "This display \u{00B7} \(empty) empty" : "This display"
        place(label(detail, size: 9.5, color: NSColor.white.withAlphaComponent(0.36)), y: 80, height: 14)
        return card
    }

    /// A static spatial reading of the reel, not another live canvas. Two
    /// paths batch every desktop and window; no per-desktop layers, capture,
    /// observers or repeat-time work. Hidden with the viewport in fast mode.
    private func makeCanvasMiniature(models: [SpaceFilmstripCard]) -> CALayer {
        let map = CALayer()
        map.bounds = CGRect(x: 0, y: 0, width: 124, height: 76)
        let columns = max(1, Int(ceil(sqrt(Double(models.count) * 1.6))))
        let rows = max(1, Int(ceil(Double(models.count) / Double(columns))))
        let gap = min(CGFloat(3), 52 / CGFloat(rows * 3))
        let tileWidth = min((124 - CGFloat(columns - 1) * gap) / CGFloat(columns),
                            (52 - CGFloat(rows - 1) * gap) / CGFloat(rows) * 1.6)
        let tileHeight = tileWidth / 1.6
        let origin = CGPoint(x: (124 - CGFloat(columns) * (tileWidth + gap) + gap) / 2,
                             y: (52 - CGFloat(rows) * (tileHeight + gap) + gap) / 2)
        let desktops = CGMutablePath()
        let windows = CGMutablePath()
        for (index, model) in models.enumerated() {
            let frame = CGRect(x: origin.x + CGFloat(index % columns) * (tileWidth + gap),
                               y: origin.y + CGFloat(index / columns) * (tileHeight + gap),
                               width: tileWidth, height: tileHeight)
            desktops.addRoundedRect(in: frame, cornerWidth: 1, cornerHeight: 1)
            let content = frame.insetBy(dx: min(1.5, tileWidth * 0.1), dy: min(1.5, tileHeight * 0.1))
            for window in model.windows {
                windows.addRect(CGRect(x: content.minX + window.rect.minX * content.width,
                                       y: content.minY + window.rect.minY * content.height,
                                       width: window.rect.width * content.width,
                                       height: window.rect.height * content.height))
            }
        }
        for (path, opacity) in [(desktops, CGFloat(0.32)), (windows, CGFloat(0.16))] {
            let ink = CAShapeLayer()
            ink.frame = map.bounds
            ink.path = path
            ink.fillColor = NSColor.white.withAlphaComponent(0.025).cgColor
            ink.strokeColor = NSColor.white.withAlphaComponent(opacity).cgColor
            ink.lineWidth = 0.6
            ink.contentsScale = scale
            map.addSublayer(ink)
        }
        let caption = label("\u{2303}\u{2193} zoom out", size: 9, color: NSColor.white.withAlphaComponent(0.46))
        caption.alignmentMode = .center
        caption.frame = CGRect(x: 0, y: 61, width: 124, height: 14)
        map.addSublayer(caption)
        return map
    }

    private func makeCard(_ model: SpaceFilmstripCard) -> CALayer {
        let card = CALayer()
        let shot = CALayer()
        shot.frame = CGRect(x: 0, y: 0, width: 168, height: 105)
        shot.cornerRadius = 6
        shot.masksToBounds = true
        shot.backgroundColor = NSColor(calibratedRed: 0.118, green: 0.126, blue: 0.138, alpha: 1).cgColor
        shot.borderWidth = 0.75
        shot.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        card.addSublayer(shot)
        for window in model.windows {
            let zone = CALayer()
            zone.frame = CGRect(x: 5 + window.rect.minX * 158, y: 5 + window.rect.minY * 95,
                                width: window.rect.width * 158, height: window.rect.height * 95)
            zone.cornerRadius = 2.5
            zone.masksToBounds = true
            zone.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            zone.borderWidth = 0.6
            zone.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
            shot.addSublayer(zone)
            let bar = CALayer()
            bar.frame = CGRect(x: 0, y: 0, width: zone.bounds.width, height: min(6, zone.bounds.height))
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            zone.addSublayer(bar)
            if zone.bounds.width > 36, zone.bounds.height > 22 {
                let name = label(window.app, size: 7, color: NSColor.white.withAlphaComponent(0.84))
                name.frame = CGRect(x: 5, y: 10, width: zone.bounds.width - 10, height: 12)
                zone.addSublayer(name)
            }
        }
        if model.windows.isEmpty {
            let empty = label("Empty", size: 9.5, color: NSColor.white.withAlphaComponent(0.24))
            empty.alignmentMode = .center
            empty.frame = CGRect(x: 8, y: 45, width: 152, height: 16)
            shot.addSublayer(empty)
        }
        // Figure first, noun quieter: the number is what the eye hunts for.
        let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let figure = "\(model.number)"
        let figureWidth = ceil((figure as NSString).size(withAttributes: [.font: figureFont]).width)
        let number = label(figure, size: 10, color: NSColor.white.withAlphaComponent(0.90))
        number.font = figureFont
        number.frame = CGRect(x: 2, y: 111, width: figureWidth + 1, height: 15)
        card.addSublayer(number)
        let noun = label("Desktop", size: 10, color: NSColor.white.withAlphaComponent(0.46))
        noun.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        noun.frame = CGRect(x: 2 + figureWidth + 6, y: 111, width: 100, height: 15)
        card.addSublayer(noun)
        for i in 0..<min(4, model.windows.count) {
            let dot = CALayer()
            dot.frame = CGRect(x: 162 - CGFloat(i) * 6, y: 116, width: 3, height: 3)
            dot.cornerRadius = 1.5
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.34).cgColor
            card.addSublayer(dot)
        }
        return card
    }

    private func label(_ text: String, size: CGFloat, color: NSColor) -> CATextLayer {
        let label = CATextLayer()
        label.string = text
        label.font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        label.fontSize = size
        label.foregroundColor = color.cgColor
        label.contentsScale = scale
        label.truncationMode = .end
        return label
    }
}
