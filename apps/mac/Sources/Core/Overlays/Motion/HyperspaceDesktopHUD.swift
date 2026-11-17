import AppKit
import Combine
import SwiftUI

private final class HUDMenuAction: NSObject {
    private let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }
    func run() { invoke() }
}

/// The Hyperspace HUD: two thin lines of Lens glass at the foot of the
/// display. Windows on top; layouts, view and actions below. Words float in
/// their own small caption, so a proposal never reshapes the HUD. AppKit panels keep
/// desktop pointer work out of SwiftUI; the HUD never owns selection or
/// moves a real window.
final class HyperspaceDesktopHUD: LensFloatPanel {
    struct Window {
        let id: UInt32
        let app: String
        let title: String
        let frame: CGRect
        let icon: NSImage?
        let slot: Int?
    }
    /// One overview cluster: a named rule, or the windows of one app. The survey
    /// already shows each window, so this row selects the group instead.
    struct Group {
        let id: Int
        let name: String
        let rule: String
        let userDefined: Bool
        let wids: [UInt32]
        let icon: NSImage?
    }
    struct State {
        var windows: [Window]
        var groups: [Group] = []
        var area: CGRect
        var desktop: Bool
        var aimedID: UInt32?
        var hasChanges: Bool
        var canUndo: Bool
        var preview: HyperspaceLayoutPlan?
        /// The hand has let go. The overlay is filled in and waiting for Apply or Cancel.
        var held = false
        /// A landing the pointer is approaching, named before the drag commits to it.
        var cue: String?
        var notice: String?
        var busy: Bool
        var tool: HyperspaceTool? = nil
        /// The arrangements the tray offers for the current selection.
        var layouts: [HyperspaceLayoutPlan] = []
        /// A fitted split, offered after the fixed ones only when one fits.
        /// Nothing proposes one yet.
        var suggestion: HyperspaceLayoutPlan? = nil
    }
    var onPick: (UInt32) -> Void = { _ in }
    var onPickGroup: ([UInt32]) -> Void = { _ in }
    var onPresentation: (Bool) -> Void = { _ in }
    var onLayout: () -> Void = {}
    var onChooseLayout: (HyperspaceLayoutPlan) -> Void = { _ in }
    var onTool: (HyperspaceTool) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRestore: () -> Void = {}
    var onDone: () -> Void = {}
    var onApply: () -> Void = {}
    var onDiscard: () -> Void = {}

    static let lineH: CGFloat = 44
    /// The window line is taller: each chip carries a picture of its window.
    static let topH: CGFloat = 54
    static let rowHeight: CGFloat = topH + 1 + lineH
    static let radius: CGFloat = 14
    /// Every key on the instrument shares one height, so both lines sit on
    /// the same 8pt margin as the sides.
    static let keyH: CGFloat = 32
    private let glass = LensGlassView(frame: CGRect(x: 0, y: 0, width: 400, height: rowHeight), radius: radius)
    private let caption = HyperspaceCaption()
    private var lastFingerprint: Int?
    // An adapter for the existing HUD preview, never a second selection model.
    // All selection and placement still belong to MotionPanel.
    private let previewState = HUDState()
    private var previewPanel: NSPanel?
    private var previewHost: NSHostingView<HUDHoverPreviewView>?
    private var previewObservation: AnyCancellable?
    private var lastAimedID: UInt32?
    private var lastDesktop: Bool?
    private var lastSlots: [UInt32: Int] = [:]
    private var lastCommitting = false
    private weak var moreAnchor: NSView?

    init() {
        super.init(identifier: "hyperspace.desktop-hud")
        title = "Hyperspace"
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 8)
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        previewObservation = previewState.$hoveredPreviewItem
            .dropFirst()
            .sink { [weak self] item in
                if item == nil { self?.previewPanel?.orderOut(nil) }
            }
    }

    override func orderOut(_ sender: Any?) {
        previewState.previewInteractionActive = false
        previewState.hoveredPreviewItem = nil
        previewPanel?.orderOut(sender)
        caption.orderOut(sender)
        super.orderOut(sender)
    }

    func update(_ state: State, on screen: NSScreen) {
        var hash = Hasher()
        hash.combine(NSStringFromRect(screen.visibleFrame))
        hash.combine(state.desktop)
        hash.combine(state.aimedID)
        hash.combine(state.hasChanges)
        hash.combine(state.canUndo)
        hash.combine(state.notice)
        hash.combine(state.busy)
        hash.combine(state.tool)
        hash.combine(state.preview?.title)
        hash.combine(state.held)
        hash.combine(state.cue)
        hash.combine(state.layouts.map(\.title))
        hash.combine(state.suggestion?.title)
        for group in state.groups {
            hash.combine(group.id); hash.combine(group.name); hash.combine(group.wids)
        }
        for window in state.windows {
            hash.combine(window.id); hash.combine(window.title); hash.combine(window.slot)
            hash.combine(NSStringFromRect(window.frame))
        }
        for (id, frame) in (state.preview?.frames ?? [:]).sorted(by: { $0.key < $1.key }) {
            hash.combine(id); hash.combine(NSStringFromRect(frame))
        }
        let fingerprint = hash.finalize()
        guard lastFingerprint != fingerprint || !isVisible else { return }
        lastFingerprint = fingerprint
        let wasVisible = isVisible

        let row = buildRow(state, on: screen)
        let visible = screen.visibleFrame
        let frame = CGRect(x: round(visible.midX - row / 2), y: visible.minY + 14, width: row, height: Self.rowHeight)
        present(frame, radius: Self.radius)
        if !wasVisible {
            fadeIn()
            Lens.entrance(glass.layer, dy: 6, scale: 0.97)
        }

        // Words float above the HUD; layouts live on its lower line.
        var top = frame.maxY
        let offersLayouts = state.preview.map { plan in
            state.layouts.contains { $0.title == plan.title } || state.suggestion?.title == plan.title
        } ?? false
        if let text = captionText(state, trayShown: offersLayouts) {
            top = caption.show(text, emphasis: state.notice == nil, centredOn: frame.midX, above: top, on: screen, level: level)
        } else {
            caption.hide()
        }
        previewTop = top

        if lastDesktop != state.desktop {
            previewState.previewInteractionActive = false
            previewState.hoveredPreviewItem = nil
            lastDesktop = state.desktop
        }
        if lastAimedID != state.aimedID {
            lastAimedID = state.aimedID
            if let window = state.windows.first(where: { $0.id == state.aimedID }), !state.busy {
                showPreview(window, on: screen)
            } else {
                previewState.hoveredPreviewItem = nil
            }
        }
        lastSlots = Dictionary(uniqueKeysWithValues: state.windows.compactMap { w in w.slot.map { (w.id, $0) } })
        lastCommitting = state.preview != nil
    }

    private var previewTop: CGFloat = 0

    // MARK: Row

    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 10
    private static let spacing: CGFloat = 4
    /// Window chips breathe more than keys, so the icons read as a row.
    private static let chipSpacing: CGFloat = 8

    /// Where the instrument sits on a screen, so overview marks can treat it
    /// as a window in front and keep keys out from under it.
    static func footprint(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = instrumentWidth(on: screen)
        return CGRect(x: round(visible.midX - width / 2), y: visible.minY + 14, width: width, height: rowHeight)
    }

    /// The instrument's one width. It depends on the screen only, never on
    /// the mode or the selection, so Desktop and Overview toggle in place.
    static func instrumentWidth(on screen: NSScreen) -> CGFloat {
        let visible = screen.visibleFrame.width
        return floor(min(visible - 48, max(760, min(900, visible * 0.56))))
    }

    /// Lays out both lines at the fixed width: windows on top; layouts,
    /// view and actions below, split by one hairline.
    private func buildRow(_ state: State, on screen: NSScreen) -> CGFloat {
        let content = glass.content
        content.subviews.forEach { $0.removeFromSuperview() }
        let line = Self.lineH
        let topY = line + 1
        let keyH = Self.keyH
        let keyY = (line - keyH) / 2
        let committing = state.preview != nil
        let width = Self.instrumentWidth(on: screen)

        // Hairline between the lines.
        let rule = LensPassView(frame: CGRect(x: 0, y: line, width: width, height: 0.5))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Lens.hair.withAlphaComponent(0.1).cgColor
        content.addSubview(rule)

        // Top line: every window (or cluster), edge to edge.
        let chipItems = state.desktop ? windowChips(state, on: screen) : groupChips(state)
        let chipsW = chipItems.reduce(0) { $0 + $1.frame.width } + Self.chipSpacing * CGFloat(max(0, chipItems.count - 1))
        if !chipItems.isEmpty {
            mountChips(chipItems, width: chipsW, room: width - 2 * Self.inset, x: Self.inset, y: topY,
                       focusID: state.aimedID, in: content)
        }

        // Bottom line, right side: fixed slots laid out from the right edge.
        // The action slot always reserves room for Cancel, so nothing to its
        // left moves when a proposal appears.
        let aspect = state.area.height > 0 ? state.area.width / state.area.height : 1.6
        let mapH: CGFloat = 22
        let mapW = round(min(44, max(30, mapH * aspect)))
        let wellW = mapW + 6
        let cell: CGFloat = 30
        let segW: CGFloat = 1 + cell * 2 + 1
        let toolsW: CGFloat = keyH * CGFloat(HyperspaceTool.allCases.count)
        let cancel = ghostButton("Cancel", key: "esc", enabled: !state.busy) { [weak self] in self?.onDiscard() }
        let cta = primaryButton(state)
        let actionW = cancel.frame.width + Self.spacing + cta.frame.width
        let rightW = wellW + Self.gap + 1 + Self.gap + segW + Self.gap + toolsW + keyH + Self.gap + actionW + Self.inset

        var x = width - rightW
        let map = mapWell(state, on: screen, frame: CGRect(x: x, y: (line - keyH) / 2, width: wellW, height: keyH))
        content.addSubview(map)
        x += wellW + Self.gap
        content.addSubview(separator(x: x, y: 0))
        x += 1 + Self.gap

        let seg = presentationSegment(state, cell: cell, frame: CGRect(x: x, y: keyY, width: segW, height: keyH))
        content.addSubview(seg)
        x += segW + Self.gap

        for tool in HyperspaceTool.allCases {
            let on = state.tool == tool
            let symbol = ["square.stack.3d.up", "square.grid.2x2", "map"][HyperspaceTool.allCases.firstIndex(of: tool) ?? 0]
            let button = iconButton(tool.rawValue, symbols: [symbol], on: on, frame: CGRect(x: x, y: keyY, width: keyH, height: keyH),
                                    tip: on ? "Hide \(tool.rawValue)" : "Show \(tool.rawValue)", enabled: !state.busy) { [weak self] in
                self?.onTool(tool)
            }
            button.setAccessibilityValue(on ? "On" : "Off")
            content.addSubview(button)
            x += keyH
        }
        let more = iconButton("More", symbols: ["ellipsis"], on: false, frame: CGRect(x: x, y: keyY, width: keyH, height: keyH),
                              tip: "Undo and keyboard shortcuts", enabled: !state.busy) { [weak self] in self?.showMoreMenu(state) }
        content.addSubview(more)
        moreAnchor = more

        if committing {
            cancel.frame.origin = CGPoint(x: width - Self.inset - actionW, y: keyY)
            content.addSubview(cancel)
        }
        cta.frame.origin = CGPoint(x: width - Self.inset - cta.frame.width, y: keyY)
        content.addSubview(cta)

        // Bottom line, left side: layouts from the shared left edge, as many
        // as fit before the map.
        let layoutRoom = width - rightW - Self.gap - Self.inset
        var layoutViews: [NSView] = []
        var used: CGFloat = 0
        for view in layoutItems(state, on: screen) {
            if view is NSTextField { view.frame.size.width = max(0, layoutRoom) }
            let next = used + (layoutViews.isEmpty ? 0 : Self.spacing) + view.frame.width
            if next > layoutRoom { break }
            layoutViews.append(view)
            used = next
        }
        if layoutViews.count > 1, let last = layoutViews.last, !(last is LensControl) { layoutViews.removeLast() }
        x = Self.inset
        for view in layoutViews {
            view.frame.origin = CGPoint(x: x, y: (line - view.frame.height) / 2)
            content.addSubview(view)
            x += view.frame.width + Self.spacing
        }
        let selectedTitle = state.preview?.title
        let titles = layoutViews.compactMap { ($0 as? LensControl)?.title }
        if titles != lastLayoutTitles, isVisible {
            for (index, view) in layoutViews.enumerated() {
                Lens.entrance(view.layer, dy: 3, scale: 0.97, delay: 0.02 + Double(index) * 0.02)
            }
        } else if selectedTitle != lastLayoutSelected, let selectedTitle,
                  let view = layoutViews.first(where: { ($0 as? LensControl)?.title == Self.layoutName(selectedTitle) }) {
            Lens.pop(view.layer, from: 1.03)
        }
        lastLayoutTitles = titles
        lastLayoutSelected = selectedTitle
        return width
    }

    // MARK: Layouts

    private var lastLayoutTitles: [String] = []
    private var lastLayoutSelected: String?

    /// Show arrangements once they can be used. Before that, explain the next
    /// action rather than filling the instrument with disabled controls.
    private func layoutItems(_ state: State, on screen: NSScreen) -> [NSView] {
        var views: [NSView] = []
        let selected = state.preview?.title
        let live = !state.layouts.isEmpty
        let plans = state.layouts
        guard live else {
            let count = state.windows.filter { $0.slot != nil }.count
            let text = count == 0 ? "Select two or more windows to arrange them" : "1 selected · select another window to arrange"
            return [lensLabel(text, size: 12, weight: .medium, color: Lens.ink.withAlphaComponent(0.85),
                              frame: CGRect(x: 0, y: 0, width: 300, height: 16), align: .left)]
        }
        for plan in plans {
            views.append(layoutItem(plan, suggested: false, selected: live && plan.title == selected,
                                    live: live, state: state))
        }
        if live, let suggestion = state.suggestion {
            let rule = LensPassView(frame: CGRect(x: 0, y: 0, width: 8.5, height: 16))
            rule.wantsLayer = true
            let hair = CALayer()
            hair.frame = CGRect(x: 4, y: 0, width: 0.5, height: 16)
            hair.backgroundColor = Lens.hair.withAlphaComponent(0.14).cgColor
            rule.layer?.addSublayer(hair)
            views.append(rule)
            views.append(layoutItem(suggestion, suggested: true, selected: suggestion.title == selected,
                                    live: true, state: state))
        }
        return views
    }

    static func layoutName(_ title: String) -> String {
        if title == "Balanced grid" { return "Grid" }
        if title == "Fill display" { return "Fill" }
        if title.contains("column") { return "Columns" }
        return title
    }

    private func layoutItem(_ plan: HyperspaceLayoutPlan, suggested: Bool, selected: Bool,
                            live: Bool, state: State) -> LensControl {
        let name = suggested ? plan.title : Self.layoutName(plan.title)
        let font = Lens.font(12, .medium)
        let nameW = min(120, ceil((name as NSString).size(withAttributes: [.font: font]).width))
        let miniW: CGFloat = 26, miniH: CGFloat = 16
        let h = Self.keyH
        let w = 8 + miniW + 8 + nameW + 10
        let control = LensControl(frame: CGRect(x: 0, y: 0, width: w, height: h), label: name)
        let face = LensPassView(frame: control.bounds)
        face.wantsLayer = true
        let fill = CAGradientLayer()
        fill.frame = face.bounds
        fill.cornerRadius = 6
        fill.cornerCurve = .continuous
        face.layer?.addSublayer(fill)
        control.addSubview(face)
        control.restyle = { c in
            LensKey.paint(fill, finish: selected ? .selection : .neutral,
                          selected: selected, hovered: c.hovered, pressed: c.pressed)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); control.restyle?(control); CATransaction.commit()

        let mini = LensScreenView(frame: CGRect(x: 8, y: (h - miniH) / 2, width: miniW, height: miniH))
        mini.area = state.area
        mini.glow = false
        mini.blockRadius = 1
        let byID = Dictionary(state.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        mini.plain = true
        mini.plainFill = .clear
        mini.plainRadius = 2.5
        mini.plainEdge = Lens.ink.withAlphaComponent(selected ? 0.60 : (live ? 0.48 : 0.22))
        mini.blockStroke = Lens.graphite ? Lens.deepInk : NSColor.white.withAlphaComponent(0.85)
        // One ink; on the chosen layout every pick wears the accent.
        mini.blocks = plan.frames.map { id, frame in
            let first = live && selected && byID[id]?.slot != nil
            let color = first ? Lens.coral.withAlphaComponent(0.85)
                              : Lens.ink.withAlphaComponent(selected ? 0.50 : (live ? 0.38 : 0.14))
            return .init(frame: frame, number: nil, color: color)
        }
        control.addSubview(mini)

        let labelX = 8 + miniW + 8
        control.addSubview(lensLabel(name, size: 12, weight: selected ? .semibold : .medium,
                                     color: Lens.ink.withAlphaComponent(selected ? 1 : (live ? 0.9 : 0.65)),
                                     frame: CGRect(x: labelX, y: (h - 15) / 2, width: nameW, height: 15)))
        control.setAccessibilityValue(selected ? "Selected" : "Not selected")
        if live {
            control.toolTip = suggested ? "\(name) · suggested for these windows" : "Preview \(name) · G cycles"
            control.isEnabled = !state.busy
            control.onClick = { [weak self] in self?.onChooseLayout(plan) }
        } else {
            control.toolTip = "Select two or more windows to arrange them"
            control.isEnabled = false
        }
        return control
    }

    private func separator(x: CGFloat, y: CGFloat) -> NSView {
        let view = LensPassView(frame: CGRect(x: x, y: y + (Self.lineH - 16) / 2, width: 0.5, height: 16))
        view.wantsLayer = true
        view.layer?.backgroundColor = Lens.hair.withAlphaComponent(0.14).cgColor
        return view
    }

    // MARK: Chips

    private static let chipH: CGFloat = topH - 16
    private static let thumbH: CGFloat = 28
    private static let glyph: CGFloat = 18

    private static func thumbW(_ area: CGRect) -> CGFloat {
        let aspect = area.height > 0 ? area.width / area.height : 1.6
        return round(min(50, max(40, thumbH * aspect)))
    }

    /// Every chip is the same width: glyph, then the map. Nothing to read,
    /// so nothing to measure.
    private static func chipWidth(_ area: CGRect) -> CGFloat { 7 + glyph + 7 + thumbW(area) + 5 }

    /// A chip: the app glyph, then the display in miniature with this window
    /// (or cluster) drawn where it sits. The title lives in the tooltip and the
    /// hover preview. Selection fills the key and colours the block.
    private func chip(label: String, icon: NSImage?, slot: Int?,
                      frames: [CGRect], picked: [Bool], area: CGRect,
                      selected: Bool, aimed: Bool, enabled: Bool) -> LensControl {
        let w = Self.chipWidth(area)
        let h = Self.chipH
        let control = LensControl(frame: CGRect(x: 0, y: 0, width: w, height: h), label: label)
        let face = LensPassView(frame: control.bounds)
        face.wantsLayer = true
        let fill = CAGradientLayer()
        fill.frame = face.bounds
        fill.cornerRadius = 7
        fill.cornerCurve = .continuous
        face.layer?.addSublayer(fill)
        control.addSubview(face)
        control.restyle = { c in
            LensKey.paint(fill, selected: selected, hovered: c.hovered || aimed, pressed: c.pressed)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); control.restyle?(control); CATransaction.commit()

        let g = Self.glyph
        let image = LensImageView(frame: CGRect(x: 7, y: (h - g) / 2, width: g, height: g))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layerUsesCoreImageFilters = true
        if let grey = CIFilter(name: "CIColorControls") {
            grey.setValue(selected ? 0.9 : 0.5, forKey: kCIInputSaturationKey)
            image.contentFilters = [grey]
        }
        image.alphaValue = selected ? 1 : 0.86
        control.addSubview(image)

        let tw = Self.thumbW(area), th = Self.thumbH
        let thumbRect = CGRect(x: 7 + g + 7, y: (h - th) / 2, width: tw, height: th)
        let thumb = LensScreenView(frame: thumbRect)
        thumb.area = area
        thumb.glow = false
        thumb.plain = true
        thumb.plainFill = Lens.ink.withAlphaComponent(selected ? 0.07 : 0.05)
        thumb.plainRadius = 3.5
        thumb.blockStroke = Lens.graphite ? Lens.deepInk : NSColor.white.withAlphaComponent(0.9)
        thumb.plainEdge = Lens.ink.withAlphaComponent(selected ? 0.32 : 0.2)
        thumb.blockRadius = 1.5
        let on = slot != nil ? Lens.coral.withAlphaComponent(0.9) : Lens.ink.withAlphaComponent(0.55)
        let off = Lens.ink.withAlphaComponent(selected ? 0.3 : 0.24)
        thumb.blocks = frames.enumerated().map { i, frame in
            .init(frame: frame, number: nil, color: (i < picked.count && picked[i]) ? on : off)
        }
        control.addSubview(thumb)

        // The slot number rides the map's corner, wherever the window sits.
        if let slot {
            let size: CGFloat = 13
            let badge = LensPassView(frame: CGRect(x: thumbRect.maxX - size + 3, y: thumbRect.minY - 3, width: size, height: size))
            badge.wantsLayer = true
            badge.layer?.cornerRadius = size / 2
            // Every pick wears the accent; the numeral carries the order.
            badge.layer?.backgroundColor = Lens.coral.cgColor
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = (Lens.graphite ? Lens.deepInk : .white).cgColor
            let numeral = lensLabel("\(slot)", size: 8.5, weight: .bold, color: Lens.onAccent,
                                    frame: CGRect(x: 0, y: 1.5, width: size, height: 10), align: .center)
            numeral.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
            badge.addSubview(numeral)
            control.addSubview(badge)
        }
        control.isEnabled = enabled
        return control
    }

    private func windowChips(_ state: State, on screen: NSScreen) -> [LensControl] {
        state.windows.map { window in
            let name = window.title.isEmpty ? window.app : window.title
            let control = chip(label: "\(window.app), \(name)", icon: window.icon, slot: window.slot,
                               frames: [window.frame], picked: [window.slot != nil], area: state.area,
                               selected: window.slot != nil, aimed: window.id == state.aimedID, enabled: !state.busy)
            control.toolTip = "\(window.app) — \(window.title)"
            control.setAccessibilityValue(window.slot.map { "Selected, window \($0)" } ?? "Not selected")
            control.identifier = NSUserInterfaceItemIdentifier("hud.window.\(window.id)")
            control.onClick = { [weak self] in
                self?.previewState.previewInteractionActive = false
                self?.previewState.hoveredPreviewItem = nil
                self?.onPick(window.id)
            }
            control.onHover = { [weak self] hovering in
                if hovering, !state.busy { self?.showPreview(window, on: screen) }
                else { self?.dismissPreviewAfterHover(window.id) }
            }
            if window.slot != nil, lastSlots[window.id] == nil, isVisible {
                Lens.pop(control.subviews.last?.layer, from: 0.3)
            }
            return control
        }
    }

    /// Overview already shows every window. This row selects a whole cluster:
    /// a named rule, or every window of one app.
    private func groupChips(_ state: State) -> [LensControl] {
        let groups = state.groups.isEmpty ? appGroups(from: state.windows) : state.groups
        let picked = Set(state.windows.compactMap { $0.slot == nil ? nil : $0.id })
        let apps = Dictionary(state.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return groups.map { group in
            let selectedCount = group.wids.filter { picked.contains($0) }.count
            let all = selectedCount == group.wids.count && !group.wids.isEmpty
            let partial = selectedCount > 0 && !all
            let icon = group.icon ?? Lens.symbol(["square.stack.3d.up"], size: 14)
            let count = group.wids.count
            let members = group.wids.filter { apps[$0] != nil }
            let control = chip(label: group.name, icon: icon, slot: nil,
                               frames: members.compactMap { apps[$0]?.frame },
                               picked: members.map { picked.contains($0) }, area: state.area,
                               selected: all, aimed: false, enabled: !state.busy)
            control.toolTip = group.userDefined
                ? "\(group.name) — \(group.rule). \(selectedCount) of \(count) selected"
                : "\(group.name), \(count) windows. \(selectedCount) selected"
            control.setAccessibilityValue(all ? "All selected" : (partial ? "Partly selected" : "Not selected"))
            control.onClick = { [weak self] in self?.onPickGroup(group.wids) }
            return control
        }
    }

    /// Chips sit on the glass. They scroll only when they no longer fit.
    private func mountChips(_ chips: [LensControl], width: CGFloat, room: CGFloat, x: CGFloat, y: CGFloat, focusID: UInt32?, in content: NSView) {
        let strip = LensPassView(frame: CGRect(x: 0, y: 0, width: width, height: Self.topH))
        var cursor: CGFloat = 0
        var focus: NSView?
        for chip in chips {
            chip.frame.origin = CGPoint(x: cursor, y: (Self.topH - Self.chipH) / 2)
            strip.addSubview(chip)
            if let focusID, chip.identifier?.rawValue == "hud.window.\(focusID)" { focus = chip }
            cursor += chip.frame.width + Self.chipSpacing
        }
        if width <= room + 1 {
            strip.frame.origin = CGPoint(x: x, y: y)
            content.addSubview(strip)
            return
        }
        let scroll = NSScrollView(frame: CGRect(x: x, y: y, width: room, height: Self.topH))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = strip
        // Fade the clipped ends instead of cutting chips with a hard edge.
        scroll.wantsLayer = true
        let fade = CAGradientLayer()
        fade.frame = scroll.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.withAlphaComponent(0.15).cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.15).cgColor]
        fade.locations = [0, NSNumber(value: Double(10 / room)), NSNumber(value: Double(1 - 10 / room)), 1]
        scroll.layer?.mask = fade
        content.addSubview(scroll)
        if let focus { strip.scrollToVisible(focus.frame.insetBy(dx: -16, dy: 0)) }
    }

    /// Used when the survey has not published clusters yet. One chip per app.
    private func appGroups(from windows: [Window]) -> [Group] {
        let names = Array(Set(windows.map(\.app))).sorted()
        return names.enumerated().map { index, name in
            let members = windows.filter { $0.app == name }
            return Group(id: index, name: name, rule: "app", userDefined: false,
                         wids: members.map(\.id), icon: members.first?.icon)
        }
    }

    // MARK: Map, switch, tools

    /// The display in miniature: the real wallpaper, every window where it is
    /// (or where the proposal puts it), the chosen ones in coral. A click asks
    /// for layouts.
    private func mapWell(_ state: State, on screen: NSScreen, frame: CGRect) -> NSView {
        let picked = state.windows.contains { $0.slot != nil }
        let control = LensControl(frame: frame, label: "Layouts")
        let map = LensScreenView(frame: control.bounds.insetBy(dx: 3, dy: 3))
        map.area = state.area
        map.guides = false
        map.plain = true
        map.plainFill = .clear
        map.plainRadius = 2.5
        map.plainEdge = Lens.ink.withAlphaComponent(0.2)
        map.blockRadius = 0.5
        map.blockStroke = Lens.graphite ? Lens.deepInk : NSColor.white.withAlphaComponent(0.9)
        let ordered = state.windows.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
        map.blocks = ordered.map { window in
            let color = Lens.graphite
                ? (window.slot != nil ? Lens.srgb(0xf4b65a) : Lens.srgb(0x2a3035))
                : (window.slot != nil ? Lens.srgb(0xf4ab95) : Lens.srgb(0xdfe2e5))
            return LensScreenView.Block(frame: state.preview?.frames[window.id] ?? window.frame, number: nil, color: color)
        }
        control.addSubview(map)
        control.toolTip = picked ? "Layouts · G" : nil
        control.isEnabled = picked && !state.busy
        control.alphaValue = 1
        control.onClick = { [weak self] in self?.onLayout() }
        return control
    }

    private func presentationSegment(_ state: State, cell: CGFloat, frame: CGRect) -> NSView {
        let well = LensPassView(frame: frame)
        well.wantsLayer = true
        well.layer?.cornerRadius = 7
        well.layer?.cornerCurve = .continuous
        well.layer?.backgroundColor = Lens.ink.withAlphaComponent(0.05).cgColor
        let items: [(String, [String], Bool, String)] = [
            ("Desktop", ["macwindow.on.rectangle", "macwindow"], true, "Arrange on the desktop · E"),
            ("Overview", ["square.grid.3x2", "rectangle.grid.2x2"], false, "See every window · E"),
        ]
        for (index, item) in items.enumerated() {
            let on = state.desktop == item.2
            let button = iconButton(item.0, symbols: item.1, on: on,
                                    frame: CGRect(x: 1 + CGFloat(index) * cell, y: 1, width: cell, height: frame.height - 2),
                                    tip: item.3, enabled: !state.busy) { [weak self] in self?.onPresentation(item.2) }
            button.setAccessibilityValue(on ? "Selected" : "Not selected")
            well.addSubview(button)
        }
        return well
    }

    /// A round icon button. On: a white pebble with a soft drop.
    private func iconButton(_ label: String, symbols: [String], on: Bool, frame: CGRect, tip: String,
                            enabled: Bool, action: @escaping () -> Void) -> LensControl {
        let control = LensControl(frame: frame, label: label)
        let face = LensPassView(frame: control.bounds)
        face.wantsLayer = true
        let pebble = CAGradientLayer()
        pebble.frame = face.bounds.insetBy(dx: 1.5, dy: 1.5)
        pebble.cornerRadius = frame.height <= 20 ? 5 : 6
        pebble.cornerCurve = .continuous
        pebble.shadowColor = Lens.rim.cgColor
        pebble.shadowOffset = CGSize(width: 0, height: -0.5)
        pebble.shadowRadius = 0.5
        pebble.borderColor = Lens.hair.withAlphaComponent(0.08).cgColor
        face.layer?.addSublayer(pebble)
        control.addSubview(face)
        let image = LensImageView(frame: control.bounds)
        image.image = Lens.symbol(symbols, size: 13, weight: .medium)
        image.imageScaling = .scaleNone
        control.addSubview(image)
        func paint(_ c: LensControl) {
            LensKey.paint(pebble, selected: on, hovered: c.hovered, pressed: c.pressed)
            image.contentTintColor = Lens.ink.withAlphaComponent(on || c.hovered ? 1 : 0.82)
        }
        control.restyle = paint
        CATransaction.begin(); CATransaction.setDisableActions(true); paint(control); CATransaction.commit()
        control.toolTip = tip
        control.isEnabled = enabled
        control.onClick = action
        return control
    }

    // MARK: Actions

    private func keycap(_ text: String, x: CGFloat, in control: NSView) -> CGFloat {
        let font = Lens.font(11, .semibold)
        let w = max(24, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 14)
        let cap = LensPassView(frame: CGRect(x: x, y: (control.bounds.height - 24) / 2, width: w, height: 24))
        cap.wantsLayer = true
        let fill = CAGradientLayer()
        fill.frame = cap.bounds
        fill.cornerRadius = 7
        fill.colors = Lens.graphite ? [NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.white.withAlphaComponent(0.06).cgColor]
                                     : [NSColor.white.cgColor, Lens.srgb(0xf1f2f4).cgColor]
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        fill.borderWidth = 0.5
        fill.borderColor = Lens.hair.withAlphaComponent(0.16).cgColor
        fill.shadowColor = Lens.rim.cgColor
        fill.shadowOpacity = 0.12
        fill.shadowRadius = 0
        fill.shadowOffset = CGSize(width: 0, height: -1)
        cap.layer?.addSublayer(fill)
        cap.addSubview(lensLabel(text, size: 11, weight: .semibold, color: Lens.graphite ? Lens.paper.withAlphaComponent(0.7) : Lens.srgb(0x4a5157),
                                 frame: CGRect(x: 0, y: 4, width: w, height: 15), align: .center))
        control.addSubview(cap)
        return w
    }

    private func ghostButton(_ title: String, key: String, enabled: Bool, action: @escaping () -> Void) -> LensControl {
        let font = Lens.font(12.5, .regular)
        let textW = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let w = 12 + textW + 12
        let control = LensControl(frame: CGRect(x: 0, y: 0, width: w, height: Self.keyH), label: title)
        let face = LensPassView(frame: control.bounds)
        face.wantsLayer = true
        let fill = CAGradientLayer()
        fill.frame = face.bounds
        fill.cornerRadius = 6
        fill.cornerCurve = .continuous
        face.layer?.addSublayer(fill)
        control.addSubview(face)
        let label = lensLabel(title, size: 12.5, weight: .medium, color: Lens.ink.withAlphaComponent(0.85),
                              frame: CGRect(x: 12, y: (Self.keyH - 16) / 2, width: textW, height: 16))
        control.addSubview(label)
        control.restyle = { c in
            LensKey.paint(fill, hovered: c.hovered, pressed: c.pressed)
            label.textColor = Lens.ink.withAlphaComponent(c.hovered ? 1 : 0.85)
        }
        control.refresh()
        control.toolTip = "Discard this layout · \(key)"
        control.isEnabled = enabled
        control.onClick = action
        return control
    }

    /// The exit stays visible even with no proposal: the real desktop still
    /// looks usable while this mode owns its clicks.
    private func primaryButton(_ state: State) -> LensControl {
        let committing = state.preview != nil
        let ready = committing && !state.busy
        let title = state.busy ? "Placing…" : (committing ? "Apply" : "Done ↵")
        let font = Lens.font(12.5, .medium)
        let textW = ceil(max((title as NSString).size(withAttributes: [.font: font]).width,
                             ("Placing…" as NSString).size(withAttributes: [.font: font]).width))
        let w = max(64, 14 + textW + 14)
        let control = LensControl(frame: CGRect(x: 0, y: 0, width: w, height: Self.keyH), label: title)
        let face = LensPassView(frame: control.bounds)
        face.wantsLayer = true
        face.layer?.masksToBounds = false
        let body = CAGradientLayer()
        body.frame = face.bounds
        body.cornerRadius = 6
        body.cornerCurve = .continuous
        body.borderWidth = ready ? 0.5 : 0
        body.borderColor = Lens.hair.withAlphaComponent(0.14).cgColor
        body.shadowColor = Lens.rim.cgColor
        body.shadowOffset = CGSize(width: 0, height: -1)
        body.shadowRadius = 1.5
        body.shadowOpacity = ready ? 0.12 : 0
        face.layer?.addSublayer(body)
        control.addSubview(face)
        let label = lensLabel(title, size: 12.5, weight: .medium, color: Lens.ink.withAlphaComponent(ready ? 0.86 : 0.6),
                              frame: CGRect(x: 6, y: (Self.keyH - 16) / 2, width: w - 12, height: 16), align: .center)
        control.addSubview(label)
        control.restyle = { c in
            LensKey.paint(body, finish: ready ? .coral : .ink, hovered: c.hovered, pressed: c.pressed)
            label.textColor = ready ? Lens.deepInk : .white
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); control.restyle?(control); CATransaction.commit()
        control.toolTip = committing ? "Place these windows · Return" : "Keep applied changes and return to apps · Return"
        control.isEnabled = !state.busy
        control.alphaValue = 1
        control.onClick = { [weak self] in
            if committing { self?.onApply() } else { self?.onDone() }
        }
        return control
    }

    // MARK: Words

    /// The screen frame owns the mode reminder. Float a caption here only
    /// while an operation has something additional to explain.
    private func captionText(_ state: State, trayShown: Bool) -> String? {
        operationCaptionText(state, trayShown: trayShown)
    }

    private func operationCaptionText(_ state: State, trayShown: Bool) -> String? {
        if let notice = state.notice { return notice }
        guard let preview = state.preview else { return nil }
        let approaching = !state.held && state.cue != nil
            && (preview.title == "Move window" || preview.title == "Move windows")
        let name = approaching ? state.cue! : previewTitle(preview.title)
        if state.busy { return "Placing \(name)…" }
        // Overview's own layout stage already names the chosen card.
        return trayShown || !state.desktop ? nil : name
    }

    private func previewTitle(_ title: String) -> String {
        if title.contains("column") { return "Columns" }
        if title == "Balanced grid" { return "Grid" }
        if title == "Move window" || title == "Move windows" { return "Moved" }
        return title
    }

    private func showMoreMenu(_ state: State) {
        let menu = NSMenu()
        // The system menu over the graphite bar reads as pale glass with pale text.
        menu.appearance = NSAppearance(named: .aqua)
        func item(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let control = NSMenuItem(title: title, action: #selector(invokeMenuItem(_:)), keyEquivalent: "")
            control.target = self
            control.representedObject = HUDMenuAction(action)
            control.isEnabled = enabled
            menu.addItem(control)
        }
        menu.autoenablesItems = false
        item("Undo arrangement  ⌘Z", enabled: state.canUndo && !state.busy) { [weak self] in self?.onUndo() }
        item(state.hasChanges ? "Restore original positions and close" : "Close Hyperspace", enabled: !state.busy) { [weak self] in self?.onRestore() }
        menu.addItem(.separator())
        item("Tab: browse   Space: select   E: switch view", enabled: false) {}
        item("G: layouts   Enter: apply / done", enabled: false) {}
        item("Escape: drop the suggestion, then close; applied changes stay", enabled: false) {}
        if let anchor = moreAnchor {
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: anchor.bounds.maxY + 8), in: anchor)
        }
    }

    @objc private func invokeMenuItem(_ sender: NSMenuItem) { (sender.representedObject as? HUDMenuAction)?.run() }

    // MARK: Hover preview

    /// Use the HUD's actual hover-preview view: shared cache, loading state,
    /// previous-image retention and transitions, with selection as its action.
    private func showPreview(_ window: Window, on screen: NSScreen) {
        guard isVisible, let entry = DesktopModel.shared.windows[window.id] else { return }
        previewState.hoveredPreviewItem = .window(entry)
        let view = HUDHoverPreviewView(state: previewState,
                                      appearance: .hyperspace,
                                      actionTitle: window.slot == nil ? "Select" : "Deselect",
                                      onActivate: { [weak self] entry in
            self?.onPick(entry.wid)
            self?.previewState.hoveredPreviewItem = nil
        })
        if let previewHost {
            previewHost.rootView = view
        } else {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .aqua)
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            previewPanel = panel
            previewHost = host
        }
        // The card stands over the chip it belongs to, kept inside the HUD's edges.
        let width = min(360, screen.visibleFrame.width - 32)
        var centre = frame.midX
        if let chip = Self.find("hud.window.\(window.id)", in: glass.content), let host = chip.window {
            centre = host.convertToScreen(chip.convert(chip.bounds, to: nil)).midX
        }
        let x = min(max(centre - width / 2, frame.minX), frame.maxX - width)
        previewPanel?.setFrame(CGRect(x: round(x),
                                     y: min(max(previewTop, frame.maxY) + 8, screen.visibleFrame.maxY - 270),
                                     width: width, height: 270), display: true)
        previewPanel?.orderFrontRegardless()
    }

    private static func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for sub in view.subviews { if let hit = find(id, in: sub) { return hit } }
        return nil
    }

    private func dismissPreviewAfterHover(_ wid: UInt32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !self.previewState.previewInteractionActive,
                  case .window(let entry) = self.previewState.hoveredPreviewItem,
                  entry.wid == wid else { return }
            self.previewState.hoveredPreviewItem = nil
        }
    }
}

// MARK: - Caption

/// A small glass pill for the few words the HUD needs: a notice, a landing,
/// a placement in flight.
final class HyperspaceCaption: LensFloatPanel {
    private let glass = LensGlassView(frame: CGRect(x: 0, y: 0, width: 120, height: 22), radius: 11)
    private var lastText: String?

    init() {
        super.init(identifier: "hyperspace.caption")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        ignoresMouseEvents = true
    }

    /// Returns the caption's top edge.
    @discardableResult
    func show(_ text: String, emphasis: Bool, centredOn midX: CGFloat, above top: CGFloat,
              on screen: NSScreen, level: NSWindow.Level) -> CGFloat {
        self.level = level
        let wasVisible = isVisible
        let font = Lens.font(11, .medium)
        let textW = min(screen.visibleFrame.width - 80, ceil((text as NSString).size(withAttributes: [.font: font]).width))
        let width = textW + 22
        glass.content.subviews.forEach { $0.removeFromSuperview() }
        glass.content.addSubview(lensLabel(text, size: 11, weight: .medium, color: emphasis ? Lens.ink : Lens.muted,
                                           frame: CGRect(x: 11, y: 4, width: textW, height: 14), align: .center))
        let frame = CGRect(x: round(midX - width / 2), y: top + 6, width: width, height: 22)
        present(frame, radius: 11)
        if !wasVisible {
            fadeIn()
            Lens.entrance(glass.layer, dy: 4, scale: 0.97)
        } else if lastText != text {
            Lens.pop(glass.layer, from: 0.96)
        }
        lastText = text
        return frame.maxY
    }

    func hide() {
        guard isVisible else { return }
        lastText = nil
        orderOut(nil)
    }
}

/// Full-screen veil with holes for the windows you are arranging. Clicks pass
/// through; the selection rings sit above it.
/// Unpicked windows sit under a smoked wash; picked ones show through a
/// window-shaped cutout with a soft bloom, so they read as lit.
final class HyperspaceDimView: NSView {
    struct Hole: Equatable { var rect: NSRect; var radius: CGFloat }
    var holes: [Hole] = [] {
        didSet {
            guard holes != oldValue else { return }
            needsDisplay = true
            let shown = !holes.isEmpty
            if shown != (oldValue.isEmpty == false) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    animator().alphaValue = shown ? 1 : 0
                }
            }
        }
    }
    static let wash: CGFloat = 0.42
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; alphaValue = 0 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard !holes.isEmpty else { return }
        let cutouts = holes.map { NSBezierPath(roundedRect: $0.rect, xRadius: $0.radius, yRadius: $0.radius) }
        let wash = NSBezierPath(rect: bounds)
        cutouts.forEach { wash.append($0) }
        wash.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        wash.addClip()
        NSColor.black.withAlphaComponent(Self.wash).setFill()
        bounds.fill()
        // Bloom: each cutout casts a soft light onto the wash around it.
        let bloom = NSShadow()
        bloom.shadowColor = NSColor.white.withAlphaComponent(0.22)
        bloom.shadowBlurRadius = 28
        bloom.shadowOffset = .zero
        bloom.set()
        NSColor.black.setFill()
        cutouts.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class HyperspacePassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            let local = convert(point, to: subview)
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

final class HyperspaceDividerHandles {
    private var panels: [NSPanel] = []
    func clear() { panels.forEach { $0.orderOut(nil) }; panels.removeAll() }
    func show(_ dividers: [(CGRect, Bool)]) {
        if panels.count != dividers.count {
            clear()
            for _ in dividers {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 7)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                let view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = HyperspaceChrome.inkColor.withAlphaComponent(0.8).cgColor
                view.layer?.cornerRadius = 2
                panel.contentView = view
                panels.append(panel)
            }
        }
        for (panel, divider) in zip(panels, dividers) {
            let hit = divider.0
            let frame = divider.1
                ? CGRect(x: hit.midX - 2, y: hit.midY - 24, width: 4, height: 48)
                : CGRect(x: hit.midX - 24, y: hit.midY - 2, width: 48, height: 4)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }
}
