import AppKit

/// What a gesture does, named for the Ink HUD: "Next desktop", or
/// "Screenshot area" with "⇧⌘4" beside it.
struct MouseGestureInkTitle: Equatable {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    private static let knownShortcuts: [String: String] = [
        "⇧⌘3": "Screenshot",
        "⇧⌘4": "Screenshot area",
        "⇧⌘5": "Screenshot tools",
    ]

    static func of(_ action: MouseShortcutActionDefinition, flags: CGEventFlags = []) -> Self {
        if let offset = MouseGestureSpaceMove.offset(for: action.type, flags: flags) {
            return .init(offset > 0 ? "Move window to next desktop" : "Move window to previous desktop")
        }
        switch action.type {
        case .spaceNext:
            return .init("Next desktop")
        case .spacePrevious:
            return .init("Previous desktop")
        case .screenMapToggle:
            return .init("Screen map")
        case .dictationStart:
            return .init("Dictate")
        case .appActivate:
            let app = action.app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(app.isEmpty ? "Open app" : app)
        case .shortcutSend:
            guard let shortcut = action.shortcut else { return .init("Send shortcut") }
            let keys = glyphs(shortcut)
            if let name = knownShortcuts[keys] { return .init(name, detail: keys) }
            return .init(keys)
        }
    }

    /// ⌃⌥⇧⌘ order, as macOS menus write it.
    static func glyphs(_ stroke: MouseShortcutKeyStroke) -> String {
        let order: [(MouseShortcutModifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let mods = order.filter { stroke.modifiers.contains($0.0) }.map(\.1).joined()
        let key = stroke.key?.uppercased() ?? stroke.keyCode.map { "#\($0)" } ?? ""
        return mods + key
    }
}

/// The rules one button can fire, read once when it goes down.
struct MouseGestureInkMenu: Equatable {
    var drags: [MouseGestureDirection: MouseGestureInkTitle] = [:]
    var shapes: [GestureShapeLabel: MouseGestureInkTitle] = [:]
    var threshold: CGFloat = 68

    /// The first enabled rule for a trigger wins, as it does in `match(for:)`.
    static func build(rules: [MouseShortcutRule], button: MouseShortcutButton, device: MouseInputDeviceInfo?, threshold: CGFloat, flags: CGEventFlags = []) -> Self {
        var menu = Self(threshold: threshold)
        for rule in rules where rule.enabled && rule.trigger.button == button && rule.device.matches(device) {
            let title = MouseGestureInkTitle.of(rule.effectiveActions.first ?? rule.action, flags: flags)
            switch rule.trigger.kind {
            case .drag:
                if let direction = rule.trigger.direction, menu.drags[direction] == nil {
                    menu.drags[direction] = title
                }
            case .shape:
                if let shape = rule.trigger.shape, menu.shapes[shape] == nil {
                    menu.shapes[shape] = title
                }
            case .click:
                break
            }
        }
        return menu
    }
}

/// The shape the HUD names while it is drawn. `confirmed` once the
/// recognizer would fire it on release; before that, a guess from the
/// strokes so far.
struct MouseGestureInkCandidate: Equatable {
    let shape: GestureShapeLabel
    let confirmed: Bool
}

/// Names a mapped shape from its first strokes, so the HUD can show it before
/// the recognizer is sure. Works in CG coordinates (y down).
enum MouseGestureInkPredictor {
    /// The strokes of each multi-stroke shape, as `GestureShapeLabel.from`
    /// reads them.
    static let strokes: [GestureShapeLabel: [MouseGestureDirection]] = [
        .lShapeDownRight: [.down, .right], .lShapeDownLeft: [.down, .left],
        .lShapeUpRight: [.up, .right], .lShapeUpLeft: [.up, .left],
        .reverseLShapeRightDown: [.right, .down], .reverseLShapeLeftDown: [.left, .down],
        .vShape: [.down, .up], .reverseV: [.up, .down],
        .zShape: [.right, .down, .right], .reverseZ: [.left, .down, .left], .sShape: [.right, .up, .right],
        .uShape: [.down, .right, .up], .uShapeFlipped: [.up, .right, .down],
        .nShape: [.down, .left, .up], .mShape: [.up, .left, .down],
    ]

    static func predict(points: [CGPoint], menu: MouseGestureInkMenu) -> GestureShapeLabel? {
        if menu.shapes[.circle] != nil, isTurningSmoothly(points) { return .circle }
        let runs = strokeRuns(points)
        guard let first = runs.first else { return nil }
        // One straight stroke is a drag until it turns.
        if runs.count == 1 && (menu.drags[first] != nil || menu.shapes[first.shapeLabel] != nil) { return nil }
        let matches = menu.shapes.keys.filter { shape in
            guard let sequence = strokes[shape], sequence.count >= runs.count else { return false }
            return Array(sequence.prefix(runs.count)) == runs
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The path as a chain of axis strokes, each at least `step` long.
    static func strokeRuns(_ points: [CGPoint], step: CGFloat = 18) -> [MouseGestureDirection] {
        guard var anchor = points.first else { return [] }
        var runs: [MouseGestureDirection] = []
        for point in points.dropFirst() {
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            guard hypot(dx, dy) >= step else { continue }
            anchor = point
            // Diagonal steps say nothing about which stroke this is.
            let direction: MouseGestureDirection
            if abs(dx) > abs(dy) * 1.3 { direction = dx >= 0 ? .right : .left }
            else if abs(dy) > abs(dx) * 1.3 { direction = dy >= 0 ? .down : .up }
            else { continue }
            if runs.last != direction { runs.append(direction) }
        }
        return runs
    }

    /// Over half a turn with no sharp corner: a loop on its way round.
    static func isTurningSmoothly(_ points: [CGPoint], step: CGFloat = 14) -> Bool {
        guard var anchor = points.first else { return false }
        var headings: [CGFloat] = []
        for point in points.dropFirst() where hypot(point.x - anchor.x, point.y - anchor.y) >= step {
            headings.append(atan2(point.y - anchor.y, point.x - anchor.x))
            anchor = point
        }
        guard headings.count >= 6 else { return false }
        var total: CGFloat = 0
        for (a, b) in zip(headings, headings.dropFirst()) {
            var turn = b - a
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            if abs(turn) > .pi / 3 { return false }
            if total != 0, turn * total < 0, abs(turn) > .pi / 12 { return false }
            total += turn
        }
        return abs(total) >= .pi * 0.95
    }
}

private extension MouseGestureDirection {
    var shapeLabel: GestureShapeLabel {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}

/// The Ink HUD: one ink, coral only for what is about to fire. Draws in the
/// overlay view's coordinates (y up).
enum MouseGestureInkRenderer {
    static let ink = NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf2 / 255, alpha: 1)
    static let coral = NSColor(srgbRed: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255, alpha: 1)
    static let ground = NSColor(srgbRed: 0x0d / 255, green: 0x10 / 255, blue: 0x13 / 255, alpha: 1)

    static let commitDrawDuration: TimeInterval = 0.36
    static let labelGap: CGFloat = 30

    // MARK: Live

    static func drawTracking(
        in ctx: CGContext,
        bounds: CGRect,
        origin: CGPoint,
        path: [CGPoint],
        menu: MouseGestureInkMenu,
        armed: MouseGestureDirection?,
        candidate: MouseGestureInkCandidate?
    ) {
        let end = path.last ?? origin
        // A shape with a rule beats a drag on release, so it owns the HUD.
        let shapeTitle = candidate.flatMap { menu.shapes[$0.shape] }
        let armed = shapeTitle == nil ? armed.flatMap { menu.drags[$0] == nil ? nil : $0 } : nil
        if !menu.drags.isEmpty {
            ctx.saveGState()
            if shapeTitle != nil { ctx.setAlpha(0.3) }
            drawCompass(in: ctx, bounds: bounds, origin: origin, end: end, menu: menu, armed: armed)
            ctx.restoreGState()
        }
        drawStart(origin, in: ctx)
        drawTrail(smoothed(path), in: ctx)
        if path.count > 1 {
            drawHead(end, in: ctx)
        }
        if let shapeTitle, let candidate, path.count > 2 {
            let box = boundingBox(path)
            let shown = candidate.confirmed ? shapeTitle : MouseGestureInkTitle(shapeTitle.title)
            pill(shown, alpha: candidate.confirmed ? 1 : 0.6, anchor: CGPoint(x: box.midX, y: box.minY - 16), align: .top, bounds: bounds, in: ctx)
        }
    }

    // MARK: Release

    static func drawCommitted(
        in ctx: CGContext,
        bounds: CGRect,
        origin: CGPoint,
        path: [CGPoint],
        menu: MouseGestureInkMenu?,
        direction: MouseGestureDirection,
        label: String,
        success: Bool,
        shape: GestureShapeLabel?,
        segments: [DirectionSegment],
        progress: CGFloat
    ) {
        let end = path.last ?? origin
        let path = smoothed(path)
        guard success else {
            dottedTrail(path, in: ctx)
            let title = label == "No Shortcut Assigned" ? "No gesture" : label
            pill(MouseGestureInkTitle(title), alpha: 0.6, anchor: CGPoint(x: end.x + 14, y: end.y - 14), align: .topLeading, bounds: bounds, in: ctx)
            return
        }

        let settled = easeInOut(progress)
        if let shape {
            let title = menu?.shapes[shape] ?? MouseGestureInkTitle(label)
            let ideal = idealShape(shape, path: path, segments: segments)
            drawRedraw(from: path, to: ideal, t: settled, in: ctx)
            let box = boundingBox(ideal.isEmpty ? path : ideal)
            pill(title, alpha: min(1, settled * 1.6), anchor: CGPoint(x: box.midX, y: box.minY - 16), align: .top, bounds: bounds, in: ctx)
            return
        }

        let threshold = menu?.threshold ?? 68
        let title = menu?.drags[direction] ?? MouseGestureInkTitle(label)
        drawRedraw(from: path, to: idealDrag(from: path.first ?? origin, to: end, direction: direction), t: settled, in: ctx)
        pill(title, alpha: 1, anchor: labelAnchor(origin, direction, threshold), align: labelAlign(direction), bounds: bounds, in: ctx)
    }

    /// The hand stroke steps back and a pen redraws it, start to end, a
    /// little tidier: cleaned up partway, so a circle keeps some of the hand.
    private static func drawRedraw(from path: [CGPoint], to ideal: [CGPoint], t: CGFloat, in ctx: CGContext) {
        let fading = max(0, 1 - t * 1.4)
        if fading > 0.01 {
            ribbon(path, widths: liveWidths(path), color: ink.withAlphaComponent(0.96 * fading), in: ctx)
        }

        let clean = morph(path, into: softened(ideal), t: settleAmount)
        let widths = penWidths(clean)
        let shown = max(2, Int((CGFloat(clean.count) * t).rounded(.up)))
        let line = Array(clean.prefix(shown))
        let lineWidths = Array(widths.prefix(shown))
        ribbon(line, widths: lineWidths.map { $0 + 1.6 }, color: NSColor.black.withAlphaComponent(0.22), in: ctx)
        ribbon(line, widths: lineWidths, color: ink, in: ctx)
        if t < 1, let tip = line.last {
            drawHead(tip, in: ctx)
        }
    }

    /// Everything the HUD can paint for a gesture: the stroke, its lattice,
    /// the compass and the pills beside them. Redraws stay inside it.
    static func extent(origin: CGPoint, path: [CGPoint], menu: MouseGestureInkMenu?) -> CGRect {
        let reach = max(latticeReach + latticeCell, (menu?.threshold ?? 68) + labelGap)
        return boundingBox([origin] + path).insetBy(dx: -(reach + 320), dy: -(reach + 64))
    }

    // MARK: Lattice

    /// The brand grid: a 16 pt cell on a 20 pt pitch, centred on the press.
    static let latticePitch: CGFloat = 20
    static let latticeCell: CGFloat = 16
    /// How far past the stroke the grid shows before it fades out.
    static let latticeReach: CGFloat = 64

    struct LatticeCell: Equatable {
        var column: Int
        var row: Int
        /// 1 on the stroke, 0 at the edge of the reach.
        var near: CGFloat
        var touched: Bool
    }

    /// Cells around the stroke, anchored to the press so they hold still as
    /// it grows. The ones the stroke ran through are touched; the rest fade
    /// with their distance from the nearest touched cell.
    static func latticeCells(origin: CGPoint, path: [CGPoint]) -> [LatticeCell] {
        let points = [origin] + path
        let samples = resample(points, count: max(2, Int(pathLength(points) / 4) + 1))
        func index(_ v: CGFloat, _ o: CGFloat) -> Int { Int(((v - o) / latticePitch).rounded()) }
        var touched: [(Int, Int)] = []
        var seen = Set<Int64>()
        for p in samples {
            let c = index(p.x, origin.x), r = index(p.y, origin.y)
            if seen.insert(Int64(c) << 32 | Int64(UInt32(bitPattern: Int32(r)))).inserted { touched.append((c, r)) }
        }
        let span = Int(ceil(latticeReach / latticePitch))
        let minC = touched.map(\.0).min()! - span, maxC = touched.map(\.0).max()! + span
        let minR = touched.map(\.1).min()! - span, maxR = touched.map(\.1).max()! + span
        let width = maxC - minC + 1
        // Nearest touched cell, in cell units squared; touched cells are 0.
        var nearest = [Int](repeating: .max, count: width * (maxR - minR + 1))
        for (c, r) in touched {
            for dr in -span...span {
                for dc in -span...span {
                    let i = (r + dr - minR) * width + (c + dc - minC)
                    nearest[i] = min(nearest[i], dc * dc + dr * dr)
                }
            }
        }
        var cells: [LatticeCell] = []
        for r in minR...maxR {
            for c in minC...maxC {
                let d2 = nearest[(r - minR) * width + (c - minC)]
                guard d2 != .max else { continue }
                let near = max(0, 1 - sqrt(CGFloat(d2)) * latticePitch / latticeReach)
                guard near > 0 || d2 == 0 else { continue }
                cells.append(LatticeCell(column: c, row: r, near: d2 == 0 ? 1 : near, touched: d2 == 0))
            }
        }
        return cells
    }

    private struct LatticeKey: Equatable {
        var origin: CGPoint
        var cells: [LatticeCell]
        var head: [Int]
        var scale: CGFloat
        /// The destination's, so blits skip colour matching.
        var space: CGColorSpace
    }

    private static var latticeCache: (key: LatticeKey, image: CGImage, rect: CGRect)?

    /// The lattice for a gesture, for a layer under the stroke: it changes
    /// only when the pen enters a new cell, so it is painted once per cell
    /// and the frames between reuse it.
    static func lattice(origin: CGPoint, path: [CGPoint], scale: CGFloat, space: CGColorSpace) -> (image: CGImage, rect: CGRect)? {
        let end = path.last ?? origin
        let head = path.count > 1
            ? [Int(((end.x - origin.x) / latticePitch).rounded()), Int(((end.y - origin.y) / latticePitch).rounded())]
            : []
        let key = LatticeKey(origin: origin, cells: latticeCells(origin: origin, path: path), head: head, scale: scale, space: space)
        if latticeCache?.key != key {
            latticeCache = renderLattice(key)
        }
        return latticeCache.map { ($0.image, $0.rect) }
    }

    /// The lattice steps back while the pen redraws the stroke.
    static func latticeOpacity(committed progress: CGFloat) -> CGFloat {
        1 - easeInOut(progress)
    }

    private static func renderLattice(_ key: LatticeKey) -> (key: LatticeKey, image: CGImage, rect: CGRect)? {
        guard !key.cells.isEmpty else { return nil }
        func rect(_ cell: LatticeCell) -> CGRect {
            CGRect(x: key.origin.x + CGFloat(cell.column) * latticePitch - latticeCell / 2,
                   y: key.origin.y + CGFloat(cell.row) * latticePitch - latticeCell / 2,
                   width: latticeCell, height: latticeCell)
        }
        let area = key.cells.reduce(CGRect.null) { $0.union(rect($1)) }.integral
        guard let image = CGContext(
            data: nil,
            width: Int(area.width * key.scale),
            height: Int(area.height * key.scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: key.space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        image.scaleBy(x: key.scale, y: key.scale)
        image.translateBy(x: -area.minX, y: -area.minY)
        // A few fills, not one per cell: the faint cells fall into steps.
        let steps = 6
        let faint = (0..<steps).map { _ in CGMutablePath() }
        let lit = CGMutablePath(), pen = CGMutablePath()
        for cell in key.cells {
            let target: CGMutablePath
            if key.head == [cell.column, cell.row] {
                target = pen
            } else if cell.touched {
                target = lit
            } else {
                target = faint[min(steps - 1, Int(cell.near * CGFloat(steps)))]
            }
            target.addRoundedRect(in: rect(cell), cornerWidth: 3.5, cornerHeight: 3.5)
        }
        func fill(_ p: CGPath, _ a: CGFloat) {
            guard !p.isEmpty else { return }
            image.addPath(p)
            image.setFillColor(ink.withAlphaComponent(a).cgColor)
            image.fillPath()
        }
        for (step, p) in faint.enumerated() {
            fill(p, 0.09 * pow((CGFloat(step) + 0.5) / CGFloat(steps), 1.5))
        }
        fill(lit, 0.24)
        fill(pen, 0.5)
        return image.makeImage().map { (key, $0, area) }
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    // MARK: Compass

    /// Where each drag leads, as quiet text around the press: faint until
    /// the pen heads that way, firm once it is armed. No ring, no arc.
    private static func drawCompass(
        in ctx: CGContext,
        bounds: CGRect,
        origin: CGPoint,
        end: CGPoint,
        menu: MouseGestureInkMenu,
        armed: MouseGestureDirection?
    ) {
        let dx = end.x - origin.x
        let dy = end.y - origin.y
        let reach = max(abs(dx), abs(dy))
        let heading: MouseGestureDirection? = reach < 10 ? nil
            : abs(dx) >= abs(dy) ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .up : .down)
        let p = min(1, reach / menu.threshold)

        for (direction, title) in menu.drags {
            let alpha: CGFloat
            if let armed {
                alpha = direction == armed ? 0.85 : 0.12
            } else if direction == heading {
                alpha = 0.32 + 0.2 * p
            } else {
                alpha = 0.26
            }
            let shown = direction == armed ? title : MouseGestureInkTitle(title.title)
            hint(shown, alpha: alpha, anchor: labelAnchor(origin, direction, menu.threshold), align: labelAlign(direction), pen: end, bounds: bounds, in: ctx)
        }
    }

    /// Just past the threshold and off to one side of the axis, so the
    /// stroke runs by the label instead of through it.
    static let labelOffset: CGFloat = 20

    private static func labelAnchor(_ origin: CGPoint, _ direction: MouseGestureDirection, _ threshold: CGFloat) -> CGPoint {
        let r = threshold + labelGap
        switch direction {
        case .right: return CGPoint(x: origin.x + r, y: origin.y + labelOffset)
        case .left: return CGPoint(x: origin.x - r, y: origin.y + labelOffset)
        case .up: return CGPoint(x: origin.x + labelOffset, y: origin.y + r)
        case .down: return CGPoint(x: origin.x + labelOffset, y: origin.y - r)
        }
    }

    private static func labelAlign(_ direction: MouseGestureDirection) -> PillAlign {
        switch direction {
        case .left: return .trailing
        case .right, .up, .down: return .leading
        }
    }

    // MARK: Strokes

    static let headWidth: CGFloat = 5.5
    static let tailWidth: CGFloat = 1.2
    static let taperLength: CGFloat = 260
    /// A broad nib held at about 40°: strokes across it run full, strokes
    /// along it run fine.
    static let nibAngle: CGFloat = .pi * 0.22
    static let nibThick: CGFloat = 6.4
    static let nibThin: CGFloat = 1.1
    static let settleAmount: CGFloat = 0.5

    /// 0 along the nib, 1 across it, eased between neighbouring points.
    static func nibFactors(_ points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return points.map { _ in 1 } }
        let raw: [CGFloat] = points.indices.map { i in
            let a = points[max(0, i - 2)]
            let b = points[min(points.count - 1, i + 2)]
            return abs(sin(atan2(b.y - a.y, b.x - a.x) - nibAngle))
        }
        return raw.indices.map { i in
            let window = raw[max(0, i - 3)...min(raw.count - 1, i + 3)]
            return window.reduce(0, +) / CGFloat(window.count)
        }
    }

    /// The live stroke: the nib, drawn out to a hairline behind the pen.
    static func liveWidths(_ points: [CGPoint]) -> [CGFloat] {
        zip(taper(points), nibFactors(points)).map { width, nib in width * (0.45 + 0.55 * nib) }
    }

    /// The finished stroke: the nib, inking in at the start and lifting off at the end.
    static func penWidths(_ points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return points.map { _ in nibThick } }
        var fromStart = [CGFloat](repeating: 0, count: points.count)
        for i in 1..<points.count {
            fromStart[i] = fromStart[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        let total = fromStart[points.count - 1]
        let nibs = nibFactors(points)
        return points.indices.map { i in
            let inking = min(1, 0.3 + fromStart[i] / 22)
            let lifting = min(1, 0.15 + (total - fromStart[i]) / 34)
            return (nibThin + (nibThick - nibThin) * pow(nibs[i], 1.4)) * min(inking, lifting)
        }
    }

    /// Corners rounded the way a pen turns them.
    static func softened(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = points
        for _ in 0..<3 {
            var next = [out[0]]
            for (a, b) in zip(out, out.dropFirst()) {
                next.append(CGPoint(x: 0.85 * a.x + 0.15 * b.x, y: 0.85 * a.y + 0.15 * b.y))
                next.append(CGPoint(x: 0.15 * a.x + 0.85 * b.x, y: 0.15 * a.y + 0.85 * b.y))
            }
            next.append(out[out.count - 1])
            out = next
        }
        return thinned(out, spacing: 2.5)
    }

    /// Drops points closer than `spacing` to the last one kept; both ends stay.
    static func thinned(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        let s2 = spacing * spacing
        for p in points.dropFirst().dropLast() {
            let q = out[out.count - 1]
            if (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) >= s2 { out.append(p) }
        }
        out.append(points[points.count - 1])
        return out
    }

    /// A brush stroke: full at the pen, drawing out to a hairline behind it.
    private static func drawTrail(_ points: [CGPoint], in ctx: CGContext) {
        guard points.count > 1 else { return }
        let widths = liveWidths(points)
        ribbon(points, widths: widths.map { $0 + 3 }, color: NSColor.black.withAlphaComponent(0.24), in: ctx)
        ribbon(points, widths: widths, color: ink.withAlphaComponent(0.96), in: ctx)
    }

    /// Width at each point, by its distance back along the stroke from the head.
    static func taper(_ points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return points.map { _ in headWidth } }
        var widths = [CGFloat](repeating: headWidth, count: points.count)
        var behind: CGFloat = 0
        for i in stride(from: points.count - 2, through: 0, by: -1) {
            behind += hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y)
            let reach = pow(max(0, 1 - behind / taperLength), 0.8)
            widths[i] = tailWidth + (headWidth - tailWidth) * reach
        }
        return widths
    }

    /// A filled outline of the stroke at the given widths, round at both ends.
    private static func ribbon(_ points: [CGPoint], widths: [CGFloat], color: NSColor, in ctx: CGContext) {
        guard points.count > 1, widths.count == points.count else { return }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in points.indices {
            let a = points[max(0, i - 1)]
            let b = points[min(points.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.001, hypot(dx, dy))
            let half = widths[i] / 2
            let normal = CGPoint(x: -dy / length * half, y: dx / length * half)
            left.append(CGPoint(x: points[i].x + normal.x, y: points[i].y + normal.y))
            right.append(CGPoint(x: points[i].x - normal.x, y: points[i].y - normal.y))
        }
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.addLines(between: left + right.reversed())
        ctx.closePath()
        for i in [0, points.count - 1] {
            let r = widths[i] / 2
            ctx.addEllipse(in: CGRect(x: points[i].x - r, y: points[i].y - r, width: r * 2, height: r * 2))
        }
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    private static func drawHead(_ point: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        let glow = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [coral.withAlphaComponent(0.32).cgColor, coral.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )
        if let glow {
            ctx.drawRadialGradient(glow, startCenter: point, startRadius: 0, endCenter: point, endRadius: 16, options: [])
        }
        ctx.restoreGState()
        dot(point, radius: 4, color: coral, in: ctx)
    }

    private static func dottedTrail(_ points: [CGPoint], in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 7])
        ctx.addLines(between: points)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.strokePath()
        ctx.addLines(between: points)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(ink.withAlphaComponent(0.4).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawStart(_ point: CGPoint, in ctx: CGContext) {
        let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.strokeEllipse(in: rect)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
        ctx.strokeEllipse(in: rect)
    }

    private static func dot(_ point: CGPoint, radius: CGFloat, color: NSColor, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - radius - 1.5, y: point.y - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Shapes

    /// The shape as it was meant: a circle fitted to the stroke, or each
    /// segment pulled straight between its ends (a V's arms stay diagonal).
    static func idealShape(_ shape: GestureShapeLabel, path: [CGPoint], segments: [DirectionSegment]) -> [CGPoint] {
        guard path.count > 1 else { return path }
        if shape == .circle {
            let box = boundingBox(path)
            let center = CGPoint(x: box.midX, y: box.midY)
            let radius = (box.width + box.height) / 4
            let start = atan2(path[0].y - center.y, path[0].x - center.x)
            let sweep: CGFloat = signedArea(path) >= 0 ? 1 : -1
            return (0...64).map { i in
                let a = start + sweep * 2 * .pi * CGFloat(i) / 64
                return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            }
        }
        let usable = segments.filter { $0.startIndex >= 0 && $0.endIndex < path.count && $0.startIndex <= $0.endIndex }
        guard let first = usable.first else { return path }
        return [path[first.startIndex]] + usable.map { path[$0.endIndex] }
    }

    /// A drag, straightened onto its axis.
    static func idealDrag(from start: CGPoint, to end: CGPoint, direction: MouseGestureDirection) -> [CGPoint] {
        switch direction {
        case .left, .right: return [start, CGPoint(x: end.x, y: start.y)]
        case .up, .down: return [start, CGPoint(x: start.x, y: end.y)]
        }
    }

    /// Hand jitter out, curves kept: a short moving average, then two Chaikin
    /// passes. Both ends stay where the hand put them.
    static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let window = 3
        var averaged = points
        for i in 1..<(points.count - 1) {
            let reach = min(window, i, points.count - 1 - i)
            let slice = points[(i - reach)...(i + reach)]
            averaged[i] = CGPoint(x: slice.map(\.x).reduce(0, +) / CGFloat(slice.count),
                                  y: slice.map(\.y).reduce(0, +) / CGFloat(slice.count))
        }
        var out = averaged
        for _ in 0..<2 {
            var next = [out[0]]
            for (a, b) in zip(out, out.dropFirst()) {
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            next.append(out[out.count - 1])
            out = next
        }
        return out
    }

    /// `count` points evenly spaced along a polyline.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return points }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Array(repeating: points[0], count: count) }
        var out: [CGPoint] = []
        var index = 0
        var walked: CGFloat = 0
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count - 1)
            while index < lengths.count - 1 && walked + lengths[index] < target {
                walked += lengths[index]
                index += 1
            }
            let t = lengths[index] > 0 ? min(1, (target - walked) / lengths[index]) : 0
            let a = points[index], b = points[index + 1]
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        out[count - 1] = points[points.count - 1]
        return out
    }

    /// Each point of the stroke slides to the same fraction of the way along
    /// the ideal shape.
    static func morph(_ path: [CGPoint], into ideal: [CGPoint], t: CGFloat) -> [CGPoint] {
        guard path.count > 1, ideal.count > 1 else { return path }
        let count = 96
        let from = resample(path, count: count)
        let to = resample(ideal, count: count)
        return zip(from, to).map { a, b in CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var box = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        return box
    }

    private static func signedArea(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst() + [points[0]]).reduce(0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) } / 2
    }

    static func easeInOut(_ t: CGFloat) -> CGFloat {
        let c = min(1, max(0, t))
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }

    // MARK: Pill

    enum PillAlign { case leading, trailing, top, bottom, topLeading }

    /// A label's text, laid out and rendered once, then drawn with alpha.
    private struct PillText {
        var image: CGImage?
        var size: CGSize
    }

    private static var pillTexts: [String: PillText] = [:]

    private static func pillText(_ title: MouseGestureInkTitle, scale: CGFloat, shadowed: Bool = false) -> PillText {
        let key = "\(title.title)\u{1}\(title.detail ?? "")\u{1}\(scale)\u{1}\(shadowed)"
        if let cached = pillTexts[key] { return cached }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowed ? 0.7 : 0)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        let titleText = NSAttributedString(string: title.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: ink,
            .shadow: shadow,
        ])
        let detailText = title.detail.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: ink.withAlphaComponent(0.5),
                .shadow: shadow,
            ])
        }
        let titleSize = titleText.size()
        let detailSize = detailText?.size() ?? .zero
        let gap: CGFloat = detailText == nil ? 0 : 10
        let size = CGSize(width: ceil(titleSize.width + gap + detailSize.width) + 24, height: 30)
        var image: CGImage?
        if let bitmap = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            bitmap.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            titleText.draw(at: CGPoint(x: 12, y: size.height / 2 - titleSize.height / 2))
            detailText?.draw(at: CGPoint(x: 12 + titleSize.width + gap, y: size.height / 2 - detailSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
            image = bitmap.makeImage()
        }
        if pillTexts.count > 64 { pillTexts.removeAll() }
        let text = PillText(image: image, size: size)
        pillTexts[key] = text
        return text
    }

    /// A direction's name as bare, shadowed text: a hint, not a button.
    /// Steps aside for the pen: fades as the pen comes near it.
    private static func hint(_ title: MouseGestureInkTitle, alpha: CGFloat, anchor: CGPoint, align: PillAlign, pen: CGPoint, bounds: CGRect, in ctx: CGContext) {
        guard alpha > 0.01 else { return }
        let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
        let text = pillText(title, scale: scale, shadowed: true)
        guard let image = text.image else { return }
        // The text sits 12 pt inside its image; a hint has no pill to pad.
        let rect = place(text.size, anchor: anchor, align: align, bounds: bounds, scale: scale)
            .offsetBy(dx: align == .leading ? -12 : align == .trailing ? 12 : 0, dy: 0)
        let words = rect.insetBy(dx: 12, dy: 7)
        let gap = hypot(max(words.minX - pen.x, 0, pen.x - words.maxX), max(words.minY - pen.y, 0, pen.y - words.maxY))
        let shown = alpha * max(0.15, min(1, gap / 28))
        ctx.saveGState()
        ctx.setAlpha(shown)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private static func place(_ size: CGSize, anchor: CGPoint, align: PillAlign, bounds: CGRect, scale: CGFloat) -> CGRect {
        var origin: CGPoint
        switch align {
        case .leading: origin = CGPoint(x: anchor.x, y: anchor.y - size.height / 2)
        case .trailing: origin = CGPoint(x: anchor.x - size.width, y: anchor.y - size.height / 2)
        case .top: origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height)
        case .bottom: origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y)
        case .topLeading: origin = CGPoint(x: anchor.x, y: anchor.y - size.height)
        }
        let room = bounds.insetBy(dx: 12, dy: 12)
        origin.x = min(max(origin.x, room.minX), room.maxX - size.width)
        origin.y = min(max(origin.y, room.minY), room.maxY - size.height)
        // On whole pixels, so the text blits without resampling.
        origin = CGPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale)
        return CGRect(origin: origin, size: size)
    }

    private static func pill(_ title: MouseGestureInkTitle, alpha: CGFloat, anchor: CGPoint, align: PillAlign, bounds: CGRect, in ctx: CGContext) {
        guard alpha > 0.01 else { return }
        let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
        let text = pillText(title, scale: scale)
        let rect = place(text.size, anchor: anchor, align: align, bounds: bounds, scale: scale)


        let shape = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setFillColor(ground.withAlphaComponent(0.94 * min(1, alpha * 1.4)).cgColor)
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(ink.withAlphaComponent(0.14 * alpha).cgColor)
        ctx.strokePath()
        if let image = text.image {
            ctx.setAlpha(alpha)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }
}
