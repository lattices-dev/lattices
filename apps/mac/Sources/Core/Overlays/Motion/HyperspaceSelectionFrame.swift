import AppKit

/// What the island says. The first few visits explain the mode; after that, or
/// once the explainer is dismissed, each visit offers one shortcut hint.
enum HyperspaceIsland {
    private static let visitsKey = "hyperspace.island.visits"
    private static let graduatedKey = "hyperspace.island.graduated"
    static let explainerVisits = 3

    typealias Line = [(String, Role)]
    enum Role { case ink, label, key }

    static let explainer: Line = [("Click windows to pick them, then choose a layout below", .label)]

    /// Only keys the in-place desktop session handles (WindowMotionMode keyDown).
    static let hints: [Line] = [
        [("E", .key), (" labels every window with a key to pick it", .label)],
        [("G", .key), (" grids your picks where they are", .label)],
        [("F", .key), (" grows the picks into open space", .label)],
        [("S", .key), (" swaps the first two picks", .label)],
        [("⌘Z", .key), (" undoes the last arrangement", .label)],
        [("⌘L", .key), (" saves the picks as a layer", .label)],
        [("/", .key), (" opens the command bar", .label)],
        [(":", .key), (" types a command: grid, left, go, layer…", .label)],
        [("← ↑ → ↓", .key), (" aim at a window,  ", .label), ("Space", .key), (" picks it", .label)],
    ]

    /// Counts this visit and returns its line.
    static func nextLine(_ defaults: UserDefaults = .standard) -> Line {
        let visit = defaults.integer(forKey: visitsKey) + 1
        defaults.set(visit, forKey: visitsKey)
        return line(visit: visit, graduated: defaults.bool(forKey: graduatedKey))
    }

    static func line(visit: Int, graduated: Bool) -> Line {
        guard graduated || visit > explainerVisits else { return explainer }
        return hints[(visit - 1) % hints.count]
    }

    /// Dismissing the explainer says "I know this"; later visits show hints.
    static func dismissed(_ line: Line, _ defaults: UserDefaults = .standard) {
        if line.map(\.0) == explainer.map(\.0) { defaults.set(true, forKey: graduatedKey) }
    }
}

/// The desktop is an editing surface while Hyperspace owns its clicks. A small
/// island at the top says so, in fab's island idiom: smoked pill, one line of
/// light type, a dot of accent, and an X to put it away.
final class HyperspaceSelectionFrame: NSView {
    private let island = LensGlassView(frame: .zero, radius: 14, graphite: true)
    private let dot = LensPassView()
    private let text = NSTextField(labelWithString: "")
    private let close = LensControl(frame: CGRect(x: 0, y: 0, width: 20, height: 20), label: "Dismiss")
    private let closeGlyph = NSImageView()
    private let usableFrame: CGRect
    private let line: HyperspaceIsland.Line
    private var dismissed = false
    /// The `:` line rides its own island just above the bottom bar, where a
    /// command line lives; the top island keeps its hint.
    private let commandIsland = LensGlassView(frame: .zero, radius: 14, graphite: true)
    private let commandText = NSTextField(labelWithString: "")
    private let suggestionStack = LensPassView()
    struct Suggestion { let text: String; let detail: String }
    private static let rowH: CGFloat = 24
    static let maxSuggestions = 8
    /// A click on a suggestion row, by index (0 nearest the line).
    var onSuggestion: ((Int) -> Void)?
    private var commandPanel: NSPanel?
    private var restoreLine: DispatchWorkItem?
    /// The island rides its own panel above the layout previews (shield + 7,
    /// with the HUD's hover preview), so a landing plate never washes it out.
    private var panel: NSPanel?

    private static let height: CGFloat = 32
    private static let ink = Lens.srgb(0xededee)
    private static let label = Lens.srgb(0x8b8c91)
    private static let soft = Lens.srgb(0xb4b5b9)

    init(frame: CGRect, usableFrame: CGRect, line: HyperspaceIsland.Line = HyperspaceIsland.nextLine()) {
        self.usableFrame = usableFrame
        self.line = line
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("hyperspace.selection-frame")

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = Lens.coral.cgColor
        island.content.addSubview(dot)

        text.attributedStringValue = Self.render(line)
        text.lineBreakMode = .byTruncatingTail
        text.setAccessibilityLabel("Hyperspace: " + line.map(\.0).joined())
        island.content.addSubview(text)

        closeGlyph.image = Lens.symbol(["xmark"], size: 9, weight: .semibold)
        closeGlyph.frame = CGRect(x: 5, y: 5, width: 10, height: 10)
        closeGlyph.imageScaling = .scaleProportionallyUpOrDown
        close.addSubview(closeGlyph)
        close.layer?.cornerRadius = 10
        close.restyle = { [weak self] button in
            self?.closeGlyph.contentTintColor = button.hovered ? Self.ink : Self.label
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(button.hovered ? 0.08 : 0).cgColor
        }
        close.refresh()
        close.onClick = { [weak self] in self?.dismiss() }
        close.identifier = NSUserInterfaceItemIdentifier("hyperspace.island-dismiss")
        close.toolTip = "Dismiss"
        island.content.addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    /// "Hyperspace" in ink, a faint separator, then the line itself.
    private static func render(_ line: HyperspaceIsland.Line) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "Hyperspace", attributes: [
            .font: Lens.font(11, .medium), .foregroundColor: ink,
        ])
        out.append(NSAttributedString(string: "   ", attributes: [.font: Lens.font(11, .regular)]))
        for (words, role) in line {
            let attrs: [NSAttributedString.Key: Any] = switch role {
            case .ink: [.font: Lens.font(11, .regular), .foregroundColor: ink]
            case .label: [.font: Lens.font(11, .regular), .foregroundColor: label]
            case .key: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: soft]
            }
            out.append(NSAttributedString(string: words, attributes: attrs))
        }
        return out
    }

    private var islandRect: CGRect {
        let area = usableFrame.intersection(bounds)
        // NSTextField's cell pads its text a few points each side.
        let textWidth = ceil(text.attributedStringValue.size().width) + 6
        // 14 lead · 6 dot · 9 gap · text · 10 gap · 20 X · 6 trail
        let width = min(max(0, area.width - 40), 14 + 6 + 9 + textWidth + 10 + 20 + 6)
        return CGRect(x: (area.midX - width / 2).rounded(), y: area.maxY - 12 - Self.height,
                      width: width, height: Self.height)
    }

    override func layout() {
        super.layout()
        let rect = islandRect
        let mid = Self.height / 2
        dot.frame = CGRect(x: 14, y: mid - 3, width: 6, height: 6)
        let textHeight = ceil(text.attributedStringValue.size().height)
        text.frame = CGRect(x: 29, y: (mid - textHeight / 2).rounded(), width: rect.width - 29 - 36, height: textHeight)
        close.frame = CGRect(x: rect.width - 26, y: mid - 10, width: 20, height: 20)
        placeIsland()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { tearDown(); return }
        guard !dismissed else { return }
        makePanel()
    }

    private func makePanel() {
        guard panel == nil, window != nil else { return }
        let panel = Self.islandPanel()
        let host = LensPassView()
        panel.contentView = host
        island.autoresizingMask = [.width, .height]
        host.addSubview(island)
        self.panel = panel
        needsLayout = true
        layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
    }

    override func removeFromSuperview() {
        tearDown()
        super.removeFromSuperview()
    }

    override var isHidden: Bool {
        didSet { isHidden || dismissed ? panel?.orderOut(nil) : panel?.orderFrontRegardless() }
    }

    // MARK: - Command line

    /// The `:` line: what's typed, the completion it would take, and the usage
    /// of the verb being typed.
    func showPrompt(_ buffer: String, ghost: String, hint: String,
                    suggestions: [Suggestion] = [], selected: Int? = nil) {
        restoreLine?.cancel()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let out = NSMutableAttributedString(string: ":", attributes: [.font: mono, .foregroundColor: Self.soft])
        out.append(NSAttributedString(string: buffer, attributes: [.font: mono, .foregroundColor: Self.ink]))
        out.append(NSAttributedString(string: "▏", attributes: [.font: mono, .foregroundColor: Lens.coral]))
        out.append(NSAttributedString(string: ghost, attributes: [.font: mono, .foregroundColor: Self.label]))
        if !hint.isEmpty {
            out.append(NSAttributedString(string: "    " + hint, attributes: [.font: Lens.font(11, .regular), .foregroundColor: Self.label]))
        }
        showCommand(out, accessibility: "Command: " + buffer, suggestions: suggestions, selected: selected)
    }

    /// What a command did, held briefly before the line goes away.
    func showResult(_ message: String, error: Bool = false) {
        let out = NSMutableAttributedString(string: error ? "✕  " : "", attributes: [
            .font: Lens.font(11, .medium), .foregroundColor: Self.soft,
        ])
        out.append(NSAttributedString(string: message, attributes: [
            .font: Lens.font(11, .regular), .foregroundColor: error ? Self.ink : Self.soft,
        ]))
        showCommand(out, accessibility: message)
        restoreLine?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPrompt() }
        restoreLine = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    func endPrompt() {
        restoreLine?.cancel()
        commandPanel?.orderOut(nil)
    }

    private func showCommand(_ string: NSAttributedString, accessibility: String,
                             suggestions: [Suggestion] = [], selected: Int? = nil) {
        guard let window else { return }
        if commandPanel == nil {
            let panel = Self.islandPanel()
            let host = LensPassView()
            panel.contentView = host
            commandIsland.autoresizingMask = [.width, .height]
            host.addSubview(commandIsland)
            commandText.lineBreakMode = .byTruncatingTail
            commandIsland.content.addSubview(commandText)
            commandIsland.content.addSubview(suggestionStack)
            commandPanel = panel
        }
        commandText.attributedStringValue = string
        commandText.setAccessibilityLabel(accessibility)
        let area = usableFrame.intersection(bounds)
        let textWidth = ceil(string.size().width) + 6
        // A steady width, so the line doesn't jump while typing.
        let width = min(max(0, area.width - 40), max(640, 16 + textWidth + 16))
        let rows = suggestions.prefix(Self.maxSuggestions)
        let listH = rows.isEmpty ? 0 : CGFloat(rows.count) * Self.rowH + 7
        // Just above the bottom bar (HyperspaceDesktopHUD sits 14pt up, rowHeight tall);
        // suggestions grow upward from the line.
        let local = CGRect(x: (area.midX - width / 2).rounded(),
                           y: area.minY + 14 + HyperspaceDesktopHUD.rowHeight + 8,
                           width: width, height: Self.height + listH)
        let textHeight = ceil(string.size().height)
        commandText.frame = CGRect(x: 16, y: ((Self.height - textHeight) / 2).rounded(),
                                   width: width - 32, height: textHeight)
        layoutSuggestions(Array(rows), selected: selected, width: width)
        commandPanel?.setFrame(window.convertToScreen(convert(local, to: nil)), display: true)
        commandIsland.frame = CGRect(origin: .zero, size: local.size)
        commandPanel?.orderFrontRegardless()
    }

    private func layoutSuggestions(_ rows: [Suggestion], selected: Int?, width: CGFloat) {
        suggestionStack.subviews.forEach { $0.removeFromSuperview() }
        suggestionStack.isHidden = rows.isEmpty
        guard !rows.isEmpty else { return }
        let h = CGFloat(rows.count) * Self.rowH
        suggestionStack.frame = CGRect(x: 0, y: Self.height + 1, width: width, height: h + 6)
        let rule = LensPassView(frame: CGRect(x: 12, y: 0, width: width - 24, height: 0.5))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        suggestionStack.addSubview(rule)
        // Best match sits nearest the line, like a shell's completion menu.
        for (index, row) in rows.enumerated() {
            let y = 3 + CGFloat(index) * Self.rowH
            let on = index == selected
            if on {
                let well = LensPassView(frame: CGRect(x: 6, y: y + 1, width: width - 12, height: Self.rowH - 2))
                well.wantsLayer = true
                well.layer?.cornerRadius = 6
                well.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                suggestionStack.addSubview(well)
                let tick = LensPassView(frame: CGRect(x: 10, y: y + 7, width: 2, height: Self.rowH - 14))
                tick.wantsLayer = true
                tick.layer?.cornerRadius = 1
                tick.layer?.backgroundColor = Lens.coral.cgColor
                suggestionStack.addSubview(tick)
            }
            let out = NSMutableAttributedString(string: row.text, attributes: [
                .font: Lens.font(12, on ? .medium : .regular), .foregroundColor: on ? Self.ink : Self.soft,
            ])
            if !row.detail.isEmpty {
                out.append(NSAttributedString(string: "   " + row.detail, attributes: [
                    .font: Lens.font(11, .regular), .foregroundColor: Self.label,
                ]))
            }
            let row = LensControl(frame: CGRect(x: 6, y: y + 1, width: width - 12, height: Self.rowH - 2),
                                  label: row.text)
            row.layer?.cornerRadius = 6
            row.onHover = { [weak row] inside in
                guard !on else { return }
                row?.layer?.backgroundColor = inside ? NSColor.white.withAlphaComponent(0.05).cgColor : nil
            }
            row.onClick = { [weak self] in self?.onSuggestion?(index) }
            suggestionStack.addSubview(row)
            let label = NSTextField(labelWithAttributedString: out)
            label.lineBreakMode = .byTruncatingTail
            let th = ceil(out.size().height)
            label.frame = CGRect(x: 14, y: ((Self.rowH - 2 - th) / 2).rounded(), width: width - 40, height: th)
            row.addSubview(label)
        }
    }

    private static func islandPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 7)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func dismiss() {
        dismissed = true
        HyperspaceIsland.dismissed(line)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.tearDown() })
    }

    private func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        restoreLine?.cancel()
        commandPanel?.orderOut(nil)
    }

    private func placeIsland() {
        guard let panel, let window else { return }
        let local = islandRect
        panel.setFrame(window.convertToScreen(convert(local, to: nil)), display: true)
        island.frame = CGRect(origin: .zero, size: local.size)
    }

    /// Everything passes through to the desktop; the island lives on its own panel.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
