import AppKit

/// `Lattices --hyperspace-preview [--screen N|name]`: the Hyperspace HUD and the
/// overview marks, drawn over invented windows on a stage that fills one
/// display. It reads no real windows and moves none; it exists to iterate on
/// the look. It runs beside a live Lattices, without the daemon or hotkeys.
///
/// Keys: E overview on/off · a window's letter picks it (overview) ·
/// Tab aims the next window · C clears picks · W light/dark wallpaper ·
/// Esc leaves overview, then quits.
@MainActor
final class HyperspacePreview {
    private static var retained: HyperspacePreview?

    static func startFromCommandLineIfNeeded() -> Bool {
        guard CommandLine.arguments.contains("--hyperspace-preview") else { return false }
        NSApp.setActivationPolicy(.regular)
        let preview = HyperspacePreview()
        retained = preview
        preview.start()
        return true
    }

    struct Fake {
        let id: UInt32
        let app: String
        let title: String
        let bundle: String
        var frame: CGRect          // AppKit, screen coordinates
        let dark: Bool
    }

    private let screen: NSScreen
    private let stage: StageWindow
    private let stageView = StageView()
    private let hud = HyperspaceDesktopHUD()
    private var inlineHUD: NSView?
    /// Front to back.
    private var windows: [Fake] = []
    private var hints: [UInt32: String] = [:]
    private var picks: [UInt32] = []
    private var overview = true
    private var aimed: UInt32?
    private var hovered: UInt32?
    private var plan: HyperspaceLayoutPlan?
    private var tool: HyperspaceTool?

    init() {
        let args = CommandLine.arguments
        // --screen takes an index or part of a display's name ("agent").
        let screens = NSScreen.screens
        var pick: String?
        if let i = args.firstIndex(of: "--screen"), i + 1 < args.count { pick = args[i + 1] }
        var chosen: NSScreen? = pick.flatMap { p in screens.first { $0.localizedName.localizedCaseInsensitiveContains(p) } }
        if chosen == nil, let n = pick.flatMap({ Int($0) }), n >= 0, n < screens.count { chosen = screens[n] }
        screen = chosen ?? NSScreen.main ?? screens[0]
        for (i, s) in NSScreen.screens.enumerated() {
            FileHandle.standardError.write("screen \(i): \(s.localizedName) \(NSStringFromRect(s.frame))\(s == screen ? "  ← stage" : "")\n".data(using: .utf8)!)
        }
        stage = StageWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    }

    private func start() {
        windows = Self.fixture(in: screen.visibleFrame)
        let letters = ["h", "j", "k", "l", "a", "d", "u", "i", "o", "n"]
        for (i, w) in windows.enumerated() { hints[w.id] = letters[i % letters.count] }

        stage.contentView = stageView
        stage.isOpaque = true
        stage.acceptsMouseMovedEvents = true
        stage.isReleasedWhenClosed = false
        stage.setFrame(screen.frame, display: false)
        if let i = CommandLine.arguments.firstIndex(of: "--desktop-image"), i + 1 < CommandLine.arguments.count {
            stageView.desktopImage = NSImage(contentsOfFile: CommandLine.arguments[i + 1])
        }
        stageView.windows = { [unowned self] in windows }
        stageView.onKey = { [unowned self] in key($0) }
        stageView.onClick = { [unowned self] in click($0) }
        stageView.onHover = { [unowned self] in hovered = $0; render() }
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let selectionFrame = HyperspaceSelectionFrame(frame: stageView.bounds, usableFrame: visible)
        selectionFrame.autoresizingMask = [.width, .height]
        stageView.addSubview(selectionFrame)
        NSApp.activate(ignoringOtherApps: true)
        stage.makeKeyAndOrderFront(nil)

        hud.onPick = { [unowned self] in toggle($0) }
        hud.onPickGroup = { [unowned self] ids in ids.forEach { toggle($0) } }
        hud.onPresentation = { [unowned self] desktop in overview = !desktop; render() }
        hud.onChooseLayout = { [unowned self] in plan = $0; render() }
        hud.onApply = { [unowned self] in plan = nil; render() }
        hud.onDiscard = { [unowned self] in plan = nil; render() }
        hud.onTool = { [unowned self] t in tool = tool == t ? nil : t; render() }
        hud.onDone = { NSApp.terminate(nil) }
        render()
    }

    // MARK: Input

    private func key(_ event: NSEvent) {
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53:
            if plan != nil { plan = nil } else if overview { overview = false } else { NSApp.terminate(nil) }
        case 48:
            let ids = windows.map(\.id)
            let next = aimed.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % ids.count } ?? 0
            aimed = ids[next]
        default:
            switch ch {
            case "e": overview.toggle()
            case "c": picks.removeAll(); plan = nil
            case "w": stageView.lightWallpaper.toggle(); stageView.needsDisplay = true
            default:
                if overview, let id = hints.first(where: { $0.value == ch })?.key { toggle(id) }
            }
        }
        render()
    }

    private func click(_ id: UInt32?) {
        guard let id else { return }
        if overview { toggle(id) } else { raise(id) }
        render()
    }

    private func toggle(_ id: UInt32) {
        if let i = picks.firstIndex(of: id) { picks.remove(at: i) } else { picks.append(id) }
        plan = nil
        render()
    }

    private func raise(_ id: UInt32) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        windows.insert(windows.remove(at: i), at: 0)
        stageView.needsDisplay = true
    }

    // MARK: Render

    private func render() {
        stageView.needsDisplay = true
        WindowSelectionOverlay.shared.sync(overlayEntries())
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flip = { (r: CGRect) in CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
        let visible = screen.visibleFrame.insetBy(dx: 2, dy: 2)
        let area = flip(visible)
        let hudWindows = windows.map { w in
            HyperspaceDesktopHUD.Window(id: w.id, app: w.app, title: w.title, frame: flip(w.frame),
                icon: NSWorkspace.shared.urlForApplication(withBundleIdentifier: w.bundle).map { NSWorkspace.shared.icon(forFile: $0.path) },
                slot: picks.firstIndex(of: w.id).map { $0 + 1 })
        }
        let layouts = picks.count >= 2 ? HyperspaceLayoutPlanner.arrangements(picks, in: area) : []
        hud.update(.init(windows: hudWindows, area: area, desktop: !overview, aimedID: aimed,
                         hasChanges: false, canUndo: false, preview: plan, held: plan != nil,
                         busy: false, tool: tool, layouts: layouts), on: screen)
        // A single-window review can include the real instrument without a
        // screen capture silently omitting its separate floating panel.
        if CommandLine.arguments.contains("--inline-hud") {
            if let content = hud.contentView {
                hud.contentView = nil
                inlineHUD = content
                content.autoresizingMask = []
                stageView.addSubview(content)
            }
            inlineHUD?.frame = hud.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            hud.orderOut(nil)
        }
    }

    /// Mirrors `MotionPanel.overviewMarkEntries`: picked windows get rings,
    /// everything else (in overview) its outline and key, cut where covered.
    private func overlayEntries() -> [WindowSelectionOverlay.Entry] {
        var entries: [WindowSelectionOverlay.Entry] = []
        var placed: [CGPoint] = []
        let hudFrame = HyperspaceDesktopHUD.footprint(on: screen)
        let frames = windows.map(\.frame)
        for (index, w) in windows.enumerated().reversed() {
            let slot = picks.firstIndex(of: w.id).map { $0 + 1 }
            let hover = w.id == hovered || w.id == aimed
            if slot == nil && !overview && !hover { continue }
            var shift: CGFloat = 0
            if slot == nil && overview {
                while placed.contains(where: { abs($0.x - (w.frame.minX + shift)) < 26 && abs($0.y - w.frame.maxY) < 24 }) { shift += 26 }
                placed.append(CGPoint(x: w.frame.minX + shift, y: w.frame.maxY))
            }
            entries.append(.init(wid: w.id, frame: w.frame, slot: slot, isHoverTarget: hover,
                                 hint: overview ? hints[w.id] : nil, hintShift: shift,
                                 occluders: (frames[..<index] + [hudFrame]).filter { $0.intersects(w.frame) }))
        }
        return entries
    }

    // MARK: Fixture

    /// A desk like the one the overview was tuned on: two terminals stacked
    /// left (one buried), a browser across the middle, a chat column right
    /// and a short window over its top.
    private static func fixture(in v: CGRect) -> [Fake] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: v.minX + v.width * x, y: v.maxY - v.height * (y + h), width: v.width * w, height: v.height * h).integral
        }
        return [
            Fake(id: 1, app: "Safari", title: "tideline · release notes", bundle: "com.apple.Safari",
                 frame: r(0.21, 0.2, 0.52, 0.66), dark: false),
            Fake(id: 2, app: "Terminal", title: "tideline — zsh", bundle: "com.apple.Terminal",
                 frame: r(0.0, 0.0, 0.48, 1.0), dark: false),
            Fake(id: 3, app: "Notes", title: "Tideline launch", bundle: "com.apple.Notes",
                 frame: r(0.6, 0.0, 0.4, 0.5), dark: false),
            Fake(id: 4, app: "Xcode", title: "Tideline.xcodeproj", bundle: "com.apple.dt.Xcode",
                 frame: r(0.465, 0.0, 0.33, 1.0), dark: true),
            Fake(id: 5, app: "Terminal", title: "tideline — tests", bundle: "com.apple.Terminal",
                 frame: r(0.0, 0.0, 0.33, 1.0), dark: true),
        ]
    }
}

// MARK: - Stage

private final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class StageView: NSView {
    var windows: () -> [HyperspacePreview.Fake] = { [] }
    var onKey: (NSEvent) -> Void = { _ in }
    var onClick: (UInt32?) -> Void = { _ in }
    var onHover: (UInt32?) -> Void = { _ in }
    var lightWallpaper = false
    var desktopImage: NSImage?
    private var lastHover: UInt32?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey(event) }
    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func hit(_ event: NSEvent) -> UInt32? {
        guard let window else { return nil }
        let p = window.convertPoint(toScreen: event.locationInWindow)
        return windows().first { $0.frame.contains(p) }?.id
    }
    override func mouseDown(with event: NSEvent) { onClick(hit(event)) }
    override func mouseMoved(with event: NSEvent) {
        let id = hit(event)
        if id != lastHover { lastHover = id; onHover(id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = desktopImage {
            // Appearance review over the user's supplied dense desktop, with
            // its old mode indicators excluded from the reference backdrop.
            let source = CGRect(x: 0, y: 100, width: image.size.width, height: max(1, image.size.height - 140))
            image.draw(in: bounds, from: source, operation: .copy, fraction: 1)
            return
        }
        let top = lightWallpaper ? NSColor(white: 0.86, alpha: 1) : NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.24, alpha: 1)
        let bottom = lightWallpaper ? NSColor(white: 0.72, alpha: 1) : NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.11, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 90)
        guard let window else { return }
        for fake in windows().reversed() {
            drawWindow(fake, in: window.convertFromScreen(fake.frame))
        }
    }

    private func drawWindow(_ w: HyperspacePreview.Fake, in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        (w.dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.985, alpha: 1)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let bar = NSRect(x: rect.minX, y: rect.maxY - 38, width: rect.width, height: 38)
        (w.dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        bar.fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: w.dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1),
        ]
        (w.title as NSString).draw(at: NSPoint(x: rect.minX + 84, y: bar.midY - 8), withAttributes: titleAttrs)
        // Lines of text, so keys and outlines are judged against content.
        let ink = w.dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.1)
        ink.setFill()
        var y = bar.minY - 30
        var n = Int(w.id) * 7
        while y > rect.minY + 16 {
            n = (n * 31 + 17) % 97
            let len = rect.width * (0.25 + CGFloat(n % 60) / 100)
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 24, y: y, width: min(len, rect.width - 48), height: 7),
                         xRadius: 3.5, yRadius: 3.5).fill()
            y -= 20
        }
        NSGraphicsContext.restoreGraphicsState()
        (w.dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.14)).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
