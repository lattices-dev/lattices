import AppKit
import BlinkCore
import HudsonObservability
import SwiftUI
import WebKit

/// Root panel surface that owns hover tracking across all descendants,
/// including WKWebView. It also reconciles the current pointer after launch so
/// a panel opened underneath the cursor does not wait for a synthetic re-entry.
@MainActor
private final class PanelHoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var pointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(next)
        hoverTrackingArea = next
        DispatchQueue.main.async { [weak self] in self?.syncPointerLocation() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.syncPointerLocation() }
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    private func syncPointerLocation() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setPointerInside(bounds.contains(convert(windowPoint, from: nil)))
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        onHoverChanged?(inside)
    }
}

/// A floating glass panel that IS a note — Blink's atomic unit.
/// Glass material + a transparent CodeMirror/reader webview; chrome is minimal.
/// Geometry persists via frame autosave (full spatial state lands in M3).
@MainActor
final class NotePanel: NSPanel {
    let noteID: String
    let editor: EditorWebView
    /// The sheet template this panel renders (config default or per-note
    /// `blink:` override) — resolved from `notePresentation` at open time and on
    /// every hot reload. ("sheetTemplate", not "sheet" — NSWindow owns `sheet: Bool`.)
    private(set) var sheetTemplate: String
    /// This note's presentation intent (the `blink:` block, plus any legacy
    /// `sheet:` alias merged in by PanelManager). The single input to
    /// `config.resolved(for:)`, so open-time and hot-reload theming agree.
    /// Mutable: the context menu's style picker updates `sheet` in place.
    private var notePresentation: NotePresentation

    /// The sheet templates offered in the panel's right-click "Style" menu
    /// (config.md → `blink.sheet`), in presentation order.
    static let availableSheets = ["glass", "card", "dotted", "bracket", "marginalia"]

    /// Fired for user-initiated mode flips from the native toggle or ⌘⇧P
    /// (JS-side flips arrive via the bridge's modeChanged instead).
    var onUserModeChange: ((String) -> Void)?

    /// The user picked a new sheet from the context menu — PanelManager persists
    /// it to the note's frontmatter (the panel already applied it live).
    var onSheetChanged: ((String) -> Void)?

    /// The panel's on-screen presence changed by its own hand (context-menu
    /// Hide) — lets PanelManager re-evaluate the drape, which depends on how
    /// many notes are visible.
    var onVisibilityChanged: (() -> Void)?

    /// Supplies the latest complete markdown for context-menu copy. PanelManager
    /// owns the truthful in-memory content (including unsaved edits), so the
    /// panel asks rather than reading a potentially stale file from disk.
    var markdownProvider: (() -> String?)?

    let modeState = PanelModeState()
    var currentMode: String { modeState.mode }

    /// Guaranteed-contrast tint between glass and content. Baseline keeps the
    /// panel legible over pale backgrounds without sampling the screen (which
    /// would need Screen Recording permission); edit mode darkens further so
    /// writing gets a focused, higher-contrast surface. Values are themable
    /// via config.json.
    private let tintLayer = NSView()
    private let glassView = NSVisualEffectView()
    /// Plain root content view; the glass material is a sibling behind the
    /// content so flat sheets can hide the glass without hiding the webview.
    private let container = PanelHoverView()
    private var readTint: CGFloat
    private var editTint: CGFloat

    private var modePillView: NSView?
    private var themeMarkView: NSView?
    private var noteIDView: NSView?
    private var versionMetadataView: NSView?
    private var styleMetadataView: NSView?
    private var focusGlyphView: NSView?
    private var closeButtonView: NSView?
    private var isHovered = false
    /// Pointer is over the detached rail. Combined with `isHovered` so crossing
    /// the seam does not count as leaving the note.
    private var railPointerInside = false
    /// Grace after the pointer leaves note+rail so you can reach the strip.
    private var railLinger = false
    private var railHideWork: DispatchWorkItem?

    /// "rail" lifts the ✕ and mode toggle off the page into `chromeRail`;
    /// "inside" keeps the original hover-earned corner chrome. Config-owned, so
    /// it flips on hot reload.
    private var chromeStyle: String
    private var chromeRail: PanelChromeRail?
    /// Keeps the rail up even after hover leaves.
    private var railPinned = false



    /// The note's title drives the rail's label, so a rename has to reach it.
    override var title: String {
        didSet { chromeRail?.setTitle(title) }
    }

    init(
        noteID: String,
        initialContent: String,
        title: String,
        presentation: NotePresentation = NotePresentation()
    ) {
        self.noteID = noteID
        self.editor = EditorWebView()
        self.notePresentation = presentation

        // Resolve this note's presentation onto the config once, up front — the
        // same reducer hot reload uses, so per-note sheet/tint/radius/theme are
        // consistent everywhere.
        let theme = BlinkConfigStore.shared.config.resolved(for: presentation)
        self.sheetTemplate = theme.panel.sheet
        self.readTint = theme.panel.tintRead
        self.editTint = theme.panel.tintEdit
        self.chromeStyle = theme.panel.chrome

        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: theme.panel.defaultWidth, height: theme.panel.defaultHeight
            ),
            // Truly borderless: no titlebar, no reserved band — the note is a
            // page, not an OS window. `.resizable` keeps native edge-resizing;
            // dragging moves to an invisible strip along the top edge; close
            // lives on the hover ✕ and ⌘W (close(), not performClose — there is
            // no close button to simulate).
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Title never renders (borderless) but names the window for AX/scripts.
        self.title = title
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 260, height: 120)
        // Follow the app-wide light/dark scheme (config.appearance, resolved by
        // AppearanceManager): the glass material, tint, and editor palette all
        // flip with it. A scheme change re-applies via `applyTheme`.
        appearance = NSAppearance(named: AppearanceManager.shared.scheme.nsAppearanceName)
        updateMetadata(theme)

        // Plain container is the contentView; the glass material is a sibling
        // BEHIND the content, not the content root. This lets flat sheets hide
        // the glass (and tint) independently while the webView and hover chrome
        // stay live — hiding the visual-effect view would take its subviews
        // with it, so it must never be an ancestor of the content.
        let glass = glassView
        let container = self.container
        container.wantsLayer = true
        container.layer?.cornerRadius = theme.panel.cornerRadius
        container.layer?.masksToBounds = true

        glass.material = Self.glassMaterial(theme, AppearanceManager.shared.scheme)
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = theme.panel.cornerRadius
        glass.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hasShadow = theme.panel.shadow

        tintLayer.wantsLayer = true
        tintLayer.layer?.backgroundColor = Self.tintColor(AppearanceManager.shared.scheme)
        tintLayer.alphaValue = readTint
        tintLayer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintLayer)
        NSLayoutConstraint.activate([
            tintLayer.topAnchor.constraint(equalTo: container.topAnchor),
            tintLayer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintLayer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintLayer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let webView = editor.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Invisible drag strip along the top edge: the webview consumes clicks
        // everywhere, so this is the panel's move gesture (the old titlebar's
        // one useful job, kept without its reserved band). Sits under the
        // corner chrome in z so ✕/pill clicks win. Height spans the empty top
        // margin above the first line — 24pt matches the reader's content
        // padding, so the grab band fills the band over the text (a bigger,
        // still-thin target) without covering the first line itself.
        let drag = DragHandle()
        drag.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.topAnchor.constraint(equalTo: container.topAnchor),
            drag.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            drag.heightAnchor.constraint(equalToConstant: Self.bandHeight),
        ])

        // Chrome is earned: controls fade in on hover, floating IN the former
        // title area — top corners, over the content, no reserved band.
        // Mode pill (✎/◧) top-right; the focus ring sits alone bottom-right —
        // deliberately not a peer.
        let pill = NSHostingView(
            rootView: ModeToggle(state: modeState) { [weak self] mode in
                self?.selectMode(mode)
            }
        )
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            pill.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            pill.widthAnchor.constraint(equalToConstant: 50),
            pill.heightAnchor.constraint(equalToConstant: 22),
        ])
        modePillView = pill

        // Edit mode exposes the stable slug at bottom-center — identity is one
        // quiet, copyable anchor, separate from the note's treatment metadata.
        let styleHost = NSHostingView(
            rootView: StyleMetadataBadge(state: modeState) { [weak self] in
                self?.showStylePicker()
            }
        )
        styleHost.translatesAutoresizingMaskIntoConstraints = false
        styleHost.alphaValue = 0.75
        container.addSubview(styleHost)
        NSLayoutConstraint.activate([
            styleHost.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            styleHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            styleHost.leadingAnchor.constraint(greaterThanOrEqualTo: container.centerXAnchor, constant: 30),
        ])
        styleMetadataView = styleHost

        let versionHost = NSHostingView(
            rootView: AppVersionLabel(version: Self.appVersion)
        )
        versionHost.translatesAutoresizingMaskIntoConstraints = false
        versionHost.alphaValue = 0.75
        container.addSubview(versionHost)
        NSLayoutConstraint.activate([
            versionHost.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            versionHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            versionHost.trailingAnchor.constraint(lessThanOrEqualTo: container.centerXAnchor, constant: -30),
        ])
        versionMetadataView = versionHost

        // One stable 24pt cell in the TOP-LEFT CHROME: brand at rest, close on
        // hover. The content gutter stays fixed, so chrome never shifts text.
        let markHost = NSHostingView(rootView: ThemeMarkBadge(state: modeState))
        markHost.translatesAutoresizingMaskIntoConstraints = false
        markHost.alphaValue = modeState.hasThemeMark ? 0.94 : 0
        container.addSubview(markHost)
        NSLayoutConstraint.activate([
            markHost.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            markHost.topAnchor.constraint(equalTo: container.topAnchor, constant: 17),
            markHost.widthAnchor.constraint(equalToConstant: 24),
            markHost.heightAnchor.constraint(equalToConstant: 24),
        ])
        themeMarkView = markHost

        let noteIDHost = NSHostingView(
            rootView: NoteIdentifierBadge(noteID: noteID) { [weak self] in
                self?.copyNoteID()
            }
        )
        noteIDHost.translatesAutoresizingMaskIntoConstraints = false
        noteIDHost.alphaValue = 0.55
        container.addSubview(noteIDHost)
        NSLayoutConstraint.activate([
            noteIDHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            noteIDHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            noteIDHost.leadingAnchor.constraint(greaterThanOrEqualTo: versionHost.trailingAnchor, constant: 8),
            noteIDHost.trailingAnchor.constraint(lessThanOrEqualTo: styleHost.leadingAnchor, constant: -8),
        ])
        noteIDView = noteIDHost

        // Close occupies the exact same fixed cell as the resting brand.
        let closeHost = NSHostingView(
            rootView: CloseGlyph { [weak self] in
                self?.close()
            }
        )
        closeHost.translatesAutoresizingMaskIntoConstraints = false
        closeHost.alphaValue = 0
        container.addSubview(closeHost)
        NSLayoutConstraint.activate([
            closeHost.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            closeHost.topAnchor.constraint(equalTo: container.topAnchor, constant: 17),
            closeHost.widthAnchor.constraint(equalToConstant: 24),
            closeHost.heightAnchor.constraint(equalToConstant: 24),
        ])
        closeButtonView = closeHost

        let focusHost = NSHostingView(
            rootView: FocusGlyph(state: modeState) { [weak self] in
                self?.toggleFocus()
            }
        )
        focusHost.translatesAutoresizingMaskIntoConstraints = false
        focusHost.alphaValue = 0
        container.addSubview(focusHost)
        NSLayoutConstraint.activate([
            focusHost.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            focusHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        focusGlyphView = focusHost

        container.onHoverChanged = { [weak self] _ in
            // WKWebView can make an ancestor tracking area report a transient
            // exit while the pointer is still inside the panel. Screen-frame
            // containment is the authoritative state.
            self?.syncHoveredFromPointer()
        }

        contentView = container

        // Restore remembered geometry (or cascade near center on first open).
        let autosaveName = "blink.note.\(noteID)"
        if !setFrameUsingName(autosaveName) {
            center()
        }
        setFrameAutosaveName(autosaveName)

        // After the frame is restored: the rail positions itself off the note's
        // real geometry, so building it earlier would park it at the origin.
        syncChromeRail()

        // Derive the panel's surface from the sheet template: glass-visible for
        // glass/card, fully flat (no glass, no shadow) for the cut-out sheets.
        applySheetAppearance(theme)

        editor.load()
        editor.setContent(initialContent)
        editor.setSheet(sheetTemplate)
        editor.onWillOpenContextMenu = { [weak self] menu in self?.decorateContextMenu(menu) }
        // Focus-on-ready and initial mode are owned by PanelManager (mode-aware).
    }

    /// True for the flat sheets that put ink straight on the wallpaper —
    /// no native glass, no window shadow (a shadow under a transparent
    /// rectangle reads as a ghost box).
    private static func isFlatSheet(_ name: String) -> Bool {
        switch name {
        case "dotted", "bracket", "marginalia": true
        default: false  // glass, card, and any unknown name fall back to glass
        }
    }

    /// The glass material for a scheme. `.hudWindow` is intentionally dark even
    /// under `.aqua`, so in light mode the default swaps to `.popover` — a
    /// light, appearance-adaptive glass. A material the user set explicitly to
    /// something else adapts on its own and is left alone.
    static func glassMaterial(
        _ config: BlinkConfig, _ scheme: AppScheme
    ) -> NSVisualEffectView.Material {
        let material = config.panel.visualEffectMaterial
        if scheme == .light, material == .hudWindow { return .popover }
        return material
    }

    /// The contrast tint painted between glass and content: black deepens the
    /// dark glass so white text reads; white lifts the light glass so dark ink
    /// reads. Same job, mirrored per scheme.
    static func tintColor(_ scheme: AppScheme) -> CGColor {
        (scheme.isDark ? NSColor.black : NSColor.white).cgColor
    }

    /// Reconcile the native surface with `sheetTemplate`.
    ///
    /// - glass/card: the glass material and tint stay ON (card draws its own
    ///   near-opaque paper in the web layer, but the glass behind it is cheap
    ///   and harmless). Corner radius + shadow come from config.
    /// - dotted/bracket/marginalia: hide the glass and tint layers entirely and
    ///   drop the window shadow — the web layer paints everything on a fully
    ///   transparent page.
    private func applySheetAppearance(_ config: BlinkConfig) {
        let scheme = AppearanceManager.shared.scheme
        // Follow the app scheme first, so the glass/tint below render in the
        // right mode even when only the appearance flipped.
        appearance = NSAppearance(named: scheme.nsAppearanceName)
        tintLayer.layer?.backgroundColor = Self.tintColor(scheme)

        let flat = Self.isFlatSheet(sheetTemplate)
        glassView.isHidden = flat
        tintLayer.isHidden = flat
        if flat {
            hasShadow = false
            // No rounded clip over a transparent page — the sheet's own frame
            // (drawn by the web layer) defines the shape.
            container.layer?.cornerRadius = 0
        } else {
            glassView.material = Self.glassMaterial(config, scheme)
            glassView.layer?.cornerRadius = config.panel.cornerRadius
            container.layer?.cornerRadius = config.panel.cornerRadius
            hasShadow = config.panel.shadow
        }
        applySeamCorners()
    }

    /// Nonactivating borderless panels must opt in to becoming key so the
    /// editor can type.
    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        updateChromeVisibility()
    }

    override func resignKey() {
        super.resignKey()
        updateChromeVisibility()
    }


    /// Mode flip (⌘⇧P) and focus (⌘.) — chords come from config so they follow
    /// hot reloads. Handled natively so they work even when the webview never
    /// had key focus. ⌘W closes the panel (LSUIElement apps have no Close menu
    /// item to route it); the close path flushes pending saves as always.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let hotkeys = BlinkConfigStore.shared.config.hotkeys
        if let chord = KeyChord.parse(hotkeys.toggleMode), chord.matches(event) {
            selectMode(currentMode == "edit" ? "read" : "edit")
            return true
        }
        if let chord = KeyChord.parse(hotkeys.focus), chord.matches(event) {
            toggleFocus()
            return true
        }
        if let chord = KeyChord.parse(hotkeys.toggleChrome), chord.matches(event) {
            toggleChromeRail()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
            NotificationCenter.default.post(name: .blinkCommandPaletteRequested, object: self)
            return true
        }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()  // borderless: performClose would beep (no close button)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc quiets things down a step: leave edit for read, then drop focus mode.
    override func cancelOperation(_ sender: Any?) {
        if currentMode == "edit" {
            selectMode("read")
        } else if focusEnabled {
            toggleFocus()
        }
    }

    /// Focus mode: quiet everything around this panel (works in edit or read).
    var focusEnabled: Bool { modeState.focus }

    /// Fired when focus mode flips so the manager can update the overlay.
    var onFocusModeChange: (() -> Void)?

    func toggleFocus() {
        modeState.focus.toggle()
        if modeState.focus { makeKey() }
        updateChromeVisibility()
        onFocusModeChange?()
    }

    // MARK: - Hover-earned chrome

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            syncHoveredFromPointer()
        default:
            break
        }
        super.sendEvent(event)
    }

    private func syncHoveredFromPointer() {
        let mouse = NSEvent.mouseLocation
        let overNote = frame.contains(mouse)
        let overRail = chromeRail?.isShowing == true
            && (chromeRail?.frame.contains(mouse) ?? false)
        setHovered(overNote)
        setRailPointerInside(overRail)
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        refreshChromeHover()
    }

    func setRailPointerInside(_ inside: Bool) {
        guard inside != railPointerInside else { return }
        railPointerInside = inside
        refreshChromeHover()
    }

    /// Show immediately on enter; hide only after a short linger so the pointer
    /// can leave the page and land on the rail without the strip vanishing.
    private func refreshChromeHover() {
        if isHovered || railPointerInside {
            railHideWork?.cancel()
            railHideWork = nil
            railLinger = false
            updateChromeVisibility()
            return
        }
        guard !railLinger else { return }
        railLinger = true
        updateChromeVisibility()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.railHideWork = nil
            self.railLinger = false
            self.updateChromeVisibility()
        }
        railHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }


    // MARK: - Detached chrome rail

    /// Build or tear down the rail to match `chromeStyle`, then re-evaluate what
    /// should be showing. Safe to call repeatedly — hot reload does.
    private func syncChromeRail() {
        let wantsRail = chromeStyle == "rail"
        if wantsRail, chromeRail == nil {
            let theme = BlinkConfigStore.shared.config.resolved(for: notePresentation)
            let scheme = AppearanceManager.shared.scheme
            let rail = PanelChromeRail(
                panel: self,
                state: modeState,
                title: title,
                cornerRadius: theme.panel.cornerRadius,
                material: Self.glassMaterial(theme, scheme),
                tint: currentMode == "edit" ? editTint : readTint,
                accent: theme.chromeAccent(scheme: scheme),
                onClose: { [weak self] in self?.close() },
                onSelectMode: { [weak self] mode in self?.selectMode(mode) },
                onToggleFocus: { [weak self] in self?.toggleFocus() }
            )
            rail.onHoverChanged = { [weak self] inside in
                self?.setRailPointerInside(inside)
            }
            rail.onPlacementChanged = { [weak self] _ in self?.applySeamCorners() }
            chromeRail = rail
        } else if !wantsRail, let rail = chromeRail {
            rail.dismantle()
            chromeRail = nil
            railPinned = false
            railPointerInside = false
            railHideWork?.cancel()
            railHideWork = nil
            railLinger = false
        }
        applySeamCorners()
        updateChromeVisibility()
    }


    /// The page keeps all four rounded corners whether the rail is up or not.
    /// Chrome docks onto that silhouette; it must not mutate the note's shape.
    private func applySeamCorners() {
        let all: CACornerMask = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner,
            .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
        ]
        container.layer?.maskedCorners = all
        glassView.layer?.maskedCorners = all
    }


    /// Earned chrome, not mode chrome: hover (or pin) shows the rail. Edit
    /// mode does not keep it up — a writing note that is not under the hand
    /// should look like a page, not a selected window.
    private var railShouldShow: Bool {
        railPinned || isHovered || railPointerInside || railLinger
    }

    /// Pin/unpin the rail (⌘⇧T by default) so it stays up after hover leaves.
    func toggleChromeRail() {
        guard chromeRail != nil else { return }
        railPinned.toggle()
        updateChromeVisibility()
    }


    /// Push this note's resolved glass + mode tint onto the rail. One path for
    /// open, key flips, mode flips, and hot reload — never a second config
    /// lookup inside the rail.
    private func applyRailSurface() {
        guard chromeRail != nil else { return }
        let theme = BlinkConfigStore.shared.config.resolved(for: notePresentation)
        let scheme = AppearanceManager.shared.scheme
        chromeRail?.applySurface(
            material: Self.glassMaterial(theme, scheme),
            tint: currentMode == "edit" ? editTint : readTint,
            accent: theme.chromeAccent(scheme: scheme)
        )
    }

    private func updateChromeVisibility() {
        // With the rail carrying the ✕ and the toggle, the in-note copies would
        // be duplicate controls sitting on the page — the thing being fixed.
        let railActive = chromeRail != nil
        let showRail = railActive && railShouldShow
        chromeRail?.setVisible(showRail)
        if showRail {
            applyRailSurface()
        }
        applySeamCorners()


        // NSHostingView can fail to animate out of an initial zero alpha; make
        // the mode control deterministic and reserve animation for the
        // same-cell brand/close crossfade.
        modePillView?.alphaValue = !railActive && isHovered ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButtonView?.animator().alphaValue = !railActive && isHovered ? 1 : 0
            // The brand mark keeps its cell to itself once close moves out, so
            // it no longer has to yield on hover.
            themeMarkView?.animator().alphaValue = modeState.hasThemeMark
                ? (railActive ? 0.94 : (isHovered ? 0 : 0.94))
                : 0
            noteIDView?.animator().alphaValue = currentMode == "edit"
                ? (isHovered ? 1 : 0.55)
                : 0
            styleMetadataView?.animator().alphaValue = currentMode == "edit"
                ? (isHovered ? 1 : 0.75)
                : 0
            versionMetadataView?.animator().alphaValue = currentMode == "edit"
                ? (isHovered ? 1 : 0.75)
                : 0
            // Active focus leaves a faint trace so the state stays legible.
            focusGlyphView?.animator().alphaValue = railActive
                ? 0
                : (isHovered ? 1 : (modeState.focus ? 0.35 : 0))
        }
    }

    // MARK: - Mode

    /// Reflect a mode in the toggle without emitting a change (initial mode,
    /// or flips that originated in the webview). On glass sheets it also drives
    /// the focus tint: editing gets a darker, calmer surface; reading stays
    /// airy. Flat sheets have no tint layer, so the flip is a no-op there
    /// (their mode contrast comes from the sheet's own CSS if needed).
    func reflectMode(_ mode: String) {
        modeState.mode = mode
        updateChromeVisibility()
        noteIDView?.isHidden = mode != "edit"
        noteIDView?.alphaValue = mode == "edit" ? (isHovered ? 1 : 0.55) : 0
        styleMetadataView?.isHidden = mode != "edit"
        styleMetadataView?.alphaValue = mode == "edit" ? (isHovered ? 1 : 0.75) : 0
        versionMetadataView?.isHidden = mode != "edit"
        versionMetadataView?.alphaValue = mode == "edit" ? (isHovered ? 1 : 0.75) : 0
        guard !Self.isFlatSheet(sheetTemplate) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            tintLayer.animator().alphaValue = mode == "edit" ? editTint : readTint
        }
    }

    /// Re-apply themable visuals after a config change (hot reload).
    func applyTheme(_ config: BlinkConfig) {
        // Resolve the incoming config through this note's presentation, so per-note
        // sheet/tint/radius/theme survive a global hot reload: a note with its own
        // `blink.sheet` always resolves back to it, a note without one follows the
        // new global sheet.
        let theme = config.resolved(for: notePresentation)
        readTint = theme.panel.tintRead
        editTint = theme.panel.tintEdit
        updateMetadata(theme)

        if theme.panel.chrome != chromeStyle {
            chromeStyle = theme.panel.chrome
            syncChromeRail()
        }
        chromeRail?.applyAppearance(appearance)
        chromeRail?.applyCornerRadius(theme.panel.cornerRadius)
        applyRailSurface()


        if theme.panel.sheet != sheetTemplate {
            sheetTemplate = theme.panel.sheet
            editor.setSheet(sheetTemplate)
        }

        // Re-derive the native surface (glass vs flat, material, radius, shadow)
        // for the current sheet, then set the mode tint only where it applies.
        applySheetAppearance(theme)
        if !Self.isFlatSheet(sheetTemplate) {
            tintLayer.alphaValue = currentMode == "edit" ? editTint : readTint
        }
        editor.setTheme(theme.editorThemeVars(scheme: AppearanceManager.shared.scheme))
    }

    /// Change this note's sheet template live from the context menu: re-derive
    /// both the web sheet and the native surface (glass vs flat, material,
    /// radius). Persistence to frontmatter is the caller's job via
    /// `onSheetChanged`; this only touches presentation, never geometry.
    func applySheet(_ sheet: String) {
        guard sheet != sheetTemplate else { return }
        notePresentation.sheet = sheet
        applyTheme(BlinkConfigStore.shared.config)
    }

    /// Reconcile externally-authored presentation metadata (agent/CLI/file
    /// edits) into the live panel and its metadata rail.
    func applyPresentation(_ presentation: NotePresentation) {
        guard presentation != notePresentation else { return }
        notePresentation = presentation
        applyTheme(BlinkConfigStore.shared.config)
    }

    private func updateMetadata(_ theme: BlinkConfig) {
        modeState.sheet = theme.panel.sheet
        modeState.style = notePresentation.style
        modeState.font = Self.displayFontName(theme.editor.fontFamily)
        modeState.fontSize = theme.editor.fontSize
        modeState.mark = theme.panel.mark
        updateChromeVisibility()
    }

    private static func displayFontName(_ cssFamily: String?) -> String {
        guard let first = cssFamily?.split(separator: ",", maxSplits: 1).first else {
            return "System"
        }
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - Context menu

    /// Rewrite WebKit's right-click menu into a note-aware action surface. Keep
    /// useful selection/edit commands, drop stock Reload, then group identity,
    /// file, presentation, and window actions from least to most consequential.
    private func decorateContextMenu(_ menu: NSMenu) {
        let noisyWebKitGroups: Set<String> = [
            "Spelling and Grammar", "Substitutions", "Transformations", "Font",
            "Speech", "Paragraph Direction", "Selection Direction", "AutoFill",
        ]
        menu.items.removeAll { item in
            if item.identifier?.rawValue == "WKMenuItemIdentifierReload" { return true }
            if noisyWebKitGroups.contains(item.title) { return true }
            // Context menus should not advertise actions that cannot currently
            // act. Selection/link commands remain when WebKit enables them.
            return !item.isEnabled && item.submenu == nil
        }
        normalizeMenuSeparators(menu)
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        menu.addItem(contextItem(
            "Copy Note ID",
            symbol: "number",
            action: #selector(contextCopyNoteID(_:))
        ))
        let copyMarkdown = contextItem(
            "Copy Entire Note as Markdown",
            symbol: "doc.on.doc",
            action: #selector(contextCopyMarkdown(_:))
        )
        copyMarkdown.isEnabled = markdownProvider != nil
        menu.addItem(copyMarkdown)
        menu.addItem(contextItem(
            "Copy File Path",
            symbol: "link",
            action: #selector(contextCopyFilePath(_:))
        ))

        menu.addItem(.separator())
        menu.addItem(contextItem(
            "Open Markdown File",
            symbol: "doc.text",
            action: #selector(contextOpenMarkdownFile(_:))
        ))
        menu.addItem(contextItem(
            "Reveal in Finder",
            symbol: "folder",
            action: #selector(contextRevealInFinder(_:))
        ))

        menu.addItem(.separator())
        let nextMode = currentMode == "edit" ? "Read" : "Edit"
        menu.addItem(contextItem(
            "Switch to \(nextMode) Mode",
            symbol: currentMode == "edit" ? "book" : "pencil",
            action: #selector(contextToggleMode(_:))
        ))
        menu.addItem(contextItem(
            "Focus Mode",
            symbol: "circle.dashed",
            action: #selector(contextToggleFocus(_:)),
            state: focusEnabled ? .on : .off
        ))

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        styleItem.submenu = makeStyleMenu()
        menu.addItem(styleItem)

        menu.addItem(.separator())
        menu.addItem(contextItem(
            "Hide Note",
            symbol: "eye.slash",
            action: #selector(contextHideNote(_:))
        ))
        menu.addItem(contextItem(
            "Close Note",
            symbol: "xmark",
            action: #selector(contextCloseNote(_:))
        ))
    }

    private func makeStyleMenu() -> NSMenu {
        let styleMenu = NSMenu()
        for sheet in Self.availableSheets {
            let item = NSMenuItem(
                title: sheet.capitalized,
                action: #selector(contextSelectSheet(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = sheet
            item.state = (sheet == sheetTemplate) ? .on : .off
            styleMenu.addItem(item)
        }
        return styleMenu
    }

    private func showStylePicker() {
        guard let anchor = styleMetadataView else { return }
        makeStyleMenu().popUp(
            positioning: nil,
            at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY + 4),
            in: anchor
        )
    }

    /// App-level command-palette counterparts to the note context menu. These
    /// deliberately reuse the same truthful providers and file URLs instead of
    /// reimplementing note actions in the palette layer.
    func showCommandStylePicker() { showStylePicker() }
    func copyCommandNoteID() { copyNoteID() }
    func copyCommandMarkdown() {
        guard let markdown = markdownProvider?() else { return }
        copyToPasteboard(markdown)
    }
    func copyCommandFilePath() { copyToPasteboard(noteFileURL.path) }
    func openCommandMarkdownFile() { NSWorkspace.shared.open(noteFileURL) }
    func revealCommandNoteInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([noteFileURL])
    }

    private func normalizeMenuSeparators(_ menu: NSMenu) {
        var hasLeadingItem = false
        var previousWasSeparator = false
        for item in menu.items {
            guard item.isSeparatorItem else {
                hasLeadingItem = true
                previousWasSeparator = false
                continue
            }
            if !hasLeadingItem || previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = true
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }

    private func contextItem(
        _ title: String,
        symbol: String,
        action: Selector,
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.state = state
        return item
    }

    @objc private func contextSelectSheet(_ sender: NSMenuItem) {
        guard let sheet = sender.representedObject as? String else { return }
        applySheet(sheet)
        onSheetChanged?(sheet)
    }

    @objc private func contextCopyNoteID(_ sender: NSMenuItem) {
        copyNoteID()
    }

    @objc private func contextCopyMarkdown(_ sender: NSMenuItem) {
        guard let markdown = markdownProvider?() else { return }
        copyToPasteboard(markdown)
    }

    @objc private func contextCopyFilePath(_ sender: NSMenuItem) {
        copyToPasteboard(noteFileURL.path)
    }

    @objc private func contextOpenMarkdownFile(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(noteFileURL)
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([noteFileURL])
    }

    @objc private func contextToggleMode(_ sender: NSMenuItem) {
        selectMode(currentMode == "edit" ? "read" : "edit")
    }

    @objc private func contextToggleFocus(_ sender: NSMenuItem) {
        toggleFocus()
    }

    /// Soft hide: tuck the panel away but keep it in the session, so clicking
    /// the note in the menubar canvas brings it right back (openPanel focuses
    /// the existing, hidden panel). Distinct from Close, which forgets it.
    @objc private func contextHideNote(_ sender: NSMenuItem) {
        orderOut(nil)
        onVisibilityChanged?()
    }

    @objc private func contextCloseNote(_ sender: NSMenuItem) {
        close()
    }

    // MARK: - Arrival: motion signature

    /// True when the OS asks for reduced motion — treated as `"none"` (spec).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Resolve the effective entrance for this panel. `draw` only makes sense on
    /// flat sheets (there's a frame to stroke); on glass/card it falls back to
    /// `shimmer`. Reduce Motion and a disabled config collapse to `none`.
    private func effectiveEntrance(_ motion: BlinkConfig.Motion) -> String {
        guard motion.enabled, !Self.reduceMotion else { return "none" }
        if motion.entrance == "draw", !Self.isFlatSheet(sheetTemplate) {
            return "shimmer"
        }
        return motion.entrance
    }

    /// Land this panel with its configured entrance. The window animates its own
    /// alpha 0→1 over `durationMs` (and, for `drop`, drifts down from 8pt above
    /// with a spring-like settle); the web layer choreographs the content via
    /// `enter(kind)`. `none` (and Reduce Motion / disabled) is today's instant
    /// show. Safe to call before `orderFront`; the caller orders the panel in.
    ///
    /// `fromOffset` nudges the pre-animation origin (used by the blink's
    /// compass reveal) on top of any per-kind drift.
    func animateEntrance(motion: BlinkConfig.Motion, fromOffset: CGSize = .zero) {
        // A programmatic move supersedes any in-flight glide.
        cancelFling()
        // If an exhale left the frame drifted, snap back to the resting home
        // before we read the target — the reveal must land the panel exactly
        // where it lives, never at a drifted position.
        if let home = blinkHomeFrame {
            setFrame(home, display: false)
            blinkHomeFrame = nil
        }

        let kind = effectiveEntrance(motion)
        editor.enter(kind, durationMs: motion.durationMs)

        guard kind != "none" else {
            // Instant: assigning alpha directly interrupts any in-flight implicit
            // animation, so nothing is left partial.
            alphaValue = 1
            return
        }

        let target = frame
        let dur = max(0.05, motion.durationMs / 1000)
        // `drop` starts 8pt above and scaled-feeling (we approximate the scale
        // with the frame drift + content fade; a window can't cheaply scale its
        // own backing). Any compass offset from the blink adds on top.
        let dropDrift: CGFloat = kind == "drop" ? 8 : 0
        let start = NSRect(
            x: target.origin.x + fromOffset.width,
            y: target.origin.y + dropDrift + fromOffset.height,
            width: target.width, height: target.height
        )

        alphaValue = 0
        if start != target {
            setFrame(start, display: false)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = dur
            // A gentle overshoot easing so `drop` reads as a settle, not a slide.
            context.timingFunction = kind == "drop"
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.25)
                : CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            if start != target {
                animator().setFrame(target, display: true)
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.alphaValue = 1
                self.setFrame(target, display: false)
            }
        }
    }

    /// The resting frame captured at the start of a blink exhale, so a reveal
    /// (or the exhale's own reset) can restore the panel to exactly where it
    /// lived. The drift is purely cosmetic and NEVER touches autosaved geometry.
    private var blinkHomeFrame: NSRect?

    /// Fade out for the blink's synchronized exhale: alpha → 0 and a drift toward
    /// `direction` over `durationMs`. The caller's `finish` closure decides
    /// whether to `orderOut` — a rapid re-toggle can supersede this exhale, in
    /// which case the panel must stay visible for the incoming reveal instead.
    func animateExhale(
        direction: CGSize, durationMs: Double, then finish: @escaping @MainActor () -> Void
    ) {
        cancelFling()  // the blink's choreography supersedes any glide
        let home = frame
        blinkHomeFrame = home
        let dur = max(0.05, durationMs / 1000)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = dur
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(home.offsetBy(dx: direction.width, dy: direction.height), display: true)
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    /// Restore a panel to its resting frame + full alpha after the exhale has
    /// ordered it out, ready for the next reveal. Never touches autosaved frame.
    func resetAfterExhale() {
        if let home = blinkHomeFrame {
            setFrame(home, display: false)
            blinkHomeFrame = nil
        }
        alphaValue = 1
    }

    /// Reusable "slot lock" primitive: animate to `frame` with a 2pt
    /// overshoot-and-settle so a programmatic placement reads as snapping into
    /// its slot rather than gliding. Persists the new frame in the completion.
    /// (GridOverlay draws its own placement today; this is here for it to adopt
    /// later — the spec forbids modifying GridOverlay to use it now.)
    func animateLock(to frame: NSRect) {
        // A programmatic placement supersedes any in-flight glide; the
        // completion persists the target as usual.
        cancelFling()
        // Overshoot slightly past the target along the travel direction, then
        // settle back. Direction derives from where we're coming from.
        let current = self.frame
        let dx = frame.minX - current.minX
        let dy = frame.minY - current.minY
        let len = max(hypot(dx, dy), 0.001)
        let overshoot: CGFloat = 2
        let past = NSRect(
            x: frame.minX + dx / len * overshoot,
            y: frame.minY + dy / len * overshoot,
            width: frame.width, height: frame.height
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.17
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(past, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { settle in
                    settle.duration = 0.11
                    settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.animator().setFrame(frame, display: true)
                } completionHandler: {
                    MainActor.assumeIsolated {
                        self.setFrame(frame, display: false)
                        self.saveFrame(usingName: "blink.note.\(self.noteID)")
                    }
                }
            }
        }
    }

    // MARK: - Focus recede

    /// Whether this panel is currently receded (a non-key panel while focus mode
    /// is active). Recede is a layer TRANSFORM + alpha only — it must never touch
    /// the frame, or geometry persistence would drift.
    private(set) var isReceded = false

    /// Push this panel back a hair: contentView layer scales to 0.985 and dims to
    /// 0.92, giving the focused note visible depth over its peers. Transform-only,
    /// so autosaved geometry is untouched. No-op when motion is disabled or
    /// Reduce Motion is on.
    func recede(enabled: Bool) {
        guard enabled, !Self.reduceMotion else { return }
        guard !isReceded else { return }
        isReceded = true
        applyRecede(scale: 0.985, alpha: 0.92)
    }

    /// Restore a receded panel to its resting transform/alpha (focus off, or this
    /// panel became key). Always safe to call.
    func unrecede() {
        guard isReceded else { return }
        isReceded = false
        applyRecede(scale: 1.0, alpha: 1.0)
    }

    private func applyRecede(scale: CGFloat, alpha: CGFloat) {
        guard let layer = container.layer else { return }
        // Scale about the view's center so the recede reads as depth, not a
        // corner shrink. Anchor + position math keeps the layer put.
        let bounds = container.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            container.animator().alphaValue = alpha
        }
    }

    // MARK: - Panel physics (fling + shade)

    /// Height of the grab band — and of the whole panel while shaded: the
    /// fold collapses the window to exactly its drag strip.
    static let bandHeight: CGFloat = 24

    /// Speed (pt/s) below which a glide is declared at rest: ~0.5pt per frame
    /// at 120Hz — invisible. Not configurable; `flingFriction` is the feel knob.
    private static let flingRestSpeed: Double = 30

    private let physicsLog = HudLogger(category: "blink.panel")


    /// Shake-to-shade is a physics gesture: config-gated, and off under Reduce
    /// Motion like the fling. (Double-click shading stays available regardless —
    /// an instant fold involves no motion.)
    var shakeGesturesEnabled: Bool {
        BlinkConfigStore.shared.config.physics.shakeEnabled && !Self.reduceMotion
    }

    /// Session-only shade state. Deliberately NOT persisted: relaunch always
    /// restores the full panel from the unshaded geometry we keep saving.
    private(set) var isShaded = false
    /// The panel's full size while shaded — the restore target grows back down
    /// from the band, so a shaded drag needs no tracking: the band's current
    /// top edge plus this size IS the unshaded frame.
    private var unshadedSize: CGSize?
    private var preShadeMinSize: NSSize?
    private var preShadeMaxSize: NSSize?

    private var dragInProgress = false
    private var fling: FlingIntegrator?
    private var flingLink: CADisplayLink?
    private var flingLastTime: CFTimeInterval = 0
    /// Set while a fling tick or a geometry-persistence swap applies a frame,
    /// so the setFrame overrides below don't read our own writes as an
    /// interruption and kill the glide (or re-enable autosave mid-swap).
    private var applyingPhysicsFrame = false

    private var autosaveName: String { "blink.note.\(noteID)" }

    /// Frame autosave writes on window moves, which would spam the defaults
    /// during a glide — and, worse, persist the COLLAPSED frame while shaded.
    /// So autosave is suspended whenever physics owns the frame (drag, fling,
    /// or shaded session) and geometry is written exactly once, at rest, by
    /// `persistRestingGeometry`. Never scramble a layout.
    private func refreshAutosaveSuspension() {
        let physicsOwnsFrame = dragInProgress || fling != nil || isShaded
        setFrameAutosaveName(physicsOwnsFrame ? "" : autosaveName)
    }

    /// Persist the resting geometry — always the UNSHADED frame, so a panel
    /// that dies shaded still relaunches full-size. Called once per rest.
    private func persistRestingGeometry() {
        guard isShaded, let fullSize = unshadedSize else {
            saveFrame(usingName: autosaveName)
            return
        }
        // Autosave only knows the live (collapsed) frame, so briefly pose the
        // full panel, save, and fold again — display off, nothing renders.
        applyingPhysicsFrame = true
        let band = frame
        setFrame(unshadedFrame(forBand: band, fullSize: fullSize), display: false)
        saveFrame(usingName: autosaveName)
        setFrame(band, display: false)
        applyingPhysicsFrame = false
    }

    /// The full panel that a shaded band restores to: same size it had, top
    /// edge anchored at the band's top (the panel unfolds downward from it).
    private func unshadedFrame(forBand band: NSRect, fullSize: CGSize) -> NSRect {
        NSRect(x: band.minX, y: band.maxY - fullSize.height, width: fullSize.width, height: fullSize.height)
    }

    // MARK: Shade

    /// Fold the panel into its top band, or unfold it back. Triggered by a
    /// shake mid-drag or a double-click on the band. Instant: the shake is a
    /// violent gesture and the snap is the feedback (classic windowshade).
    func toggleShade() {
        if isShaded { unshade() } else { shade() }
    }

    private func shade() {
        guard !isShaded else { return }
        cancelFling()
        let full = frame
        unshadedSize = full.size
        // Persist the FULL frame before collapsing, then keep autosave off for
        // the whole shaded session so the band's 24pt height never reaches disk.
        saveFrame(usingName: autosaveName)
        isShaded = true
        refreshAutosaveSuspension()
        // Pin the height at the band so native edge-resizing can't fight the fold.
        preShadeMinSize = minSize
        preShadeMaxSize = maxSize
        minSize = NSSize(width: preShadeMinSize?.width ?? 260, height: Self.bandHeight)
        maxSize = NSSize(width: preShadeMaxSize?.width ?? .greatestFiniteMagnitude, height: Self.bandHeight)
        // Fold up under the grab band: the top edge stays put, the bottom rises.
        setFrame(
            NSRect(x: full.minX, y: full.maxY - Self.bandHeight, width: full.width, height: Self.bandHeight),
            display: true
        )
    }

    private func unshade() {
        guard isShaded, let fullSize = unshadedSize else { return }
        let full = unshadedFrame(forBand: frame, fullSize: fullSize)
        isShaded = false
        unshadedSize = nil
        minSize = preShadeMinSize ?? NSSize(width: 260, height: 120)
        maxSize = preShadeMaxSize ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preShadeMinSize = nil
        preShadeMaxSize = nil
        setFrame(full, display: true)
        refreshAutosaveSuspension()
        saveFrame(usingName: autosaveName)
    }

    // MARK: Drag → fling

    func beginManualDrag() {
        cancelFling()
        dragInProgress = true
        chromeRail?.detachFromParent()
        refreshAutosaveSuspension()
    }

    /// Released. A fast enough throw becomes a glide; anything slower is just
    /// a drop — persist the resting frame either way, exactly once.
    func endManualDrag(velocity: CGPoint) {
        let physics = BlinkConfigStore.shared.config.physics
        let speed = hypot(velocity.x, velocity.y)
        guard physics.flingEnabled, !Self.reduceMotion,
              speed >= physics.flingMinVelocity,
              let bounds = flingBounds()
        else {
            settleAfterManualMove()
            return
        }
        physicsLog.info("[BLINK] fling", metadata: ["speed": "\(Int(speed))"])
        fling = FlingIntegrator(
            origin: frame.origin,
            velocity: velocity,
            size: frame.size,
            bounds: bounds,
            friction: physics.flingFriction,
            bounceDamping: physics.bounceDamping,
            restSpeed: Self.flingRestSpeed
        )
        flingLastTime = CACurrentMediaTime()
        // CADisplayLink (macOS 14) fires on the main runloop at the panel's
        // native refresh — no C callback, no thread hop.
        let link = container.displayLink(target: self, selector: #selector(flingTick(_:)))
        link.add(to: .main, forMode: .common)
        flingLink = link
        refreshAutosaveSuspension()
    }

    /// Drop or fling rest: pin the global frame while constrain is still
    /// bypassed so AppKit assigns the destination display, then persist and
    /// reattach the rail. Clearing `dragInProgress` first remaps the drop
    /// onto the origin display.
    private func settleAfterManualMove() {
        let dest = frame
        persistRestingGeometry()
        dragInProgress = false
        applyingPhysicsFrame = true
        refreshAutosaveSuspension()
        setFrame(dest, display: true)
        saveFrame(usingName: autosaveName)
        applyingPhysicsFrame = false
        chromeRail?.syncFrame()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.moveByPhysics(to: dest.origin)
            self.chromeRail?.attachToParent()
        }
    }



    func moveByPhysics(to origin: NSPoint) {
        let want = NSRect(origin: origin, size: frame.size)
        applyingPhysicsFrame = true
        setFrame(want, display: true)
        applyingPhysicsFrame = false
        chromeRail?.syncFrame()
    }



    /// The visible frame of the screen `rect` is MOSTLY on (max intersection
    /// area) — the arena the glide bounces within.
    private func flingBounds(for rect: CGRect? = nil) -> CGRect? {
        let probe = rect ?? frame
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let hit = screen.visibleFrame.intersection(probe)
            guard !hit.isNull, !hit.isEmpty else { continue }
            let area = hit.width * hit.height
            if area > bestArea {
                bestArea = area
                best = screen.visibleFrame
            }
        }
        return best ?? (screen ?? NSScreen.main)?.visibleFrame
    }

    @objc private func flingTick(_ link: CADisplayLink) {
        guard var f = fling else {
            stopFling()
            return
        }
        let now = CACurrentMediaTime()
        // Clamp long frames (stalls, breakpoint hits) so one dt never teleports.
        let dt = min(now - flingLastTime, 1.0 / 20)
        flingLastTime = now
        // Probe the unconstrained next origin so a seam-crossing throw can
        // adopt the destination screen before this tick's bounce.
        let nextOrigin = CGPoint(
            x: f.origin.x + f.velocity.x * CGFloat(dt),
            y: f.origin.y + f.velocity.y * CGFloat(dt)
        )
        if let next = flingBounds(for: CGRect(origin: nextOrigin, size: f.size)),
           next != f.bounds {
            f.bounds = next
        }
        let alive = f.step(dt: dt)
        fling = f
        moveByPhysics(to: f.origin)
        if !alive { stopFling() }
    }


    /// End a glide: unhook the display link, persist the resting frame, and
    /// hand autosave back. Safe to call redundantly — a no-op without a fling.
    private func stopFling() {
        flingLink?.invalidate()
        flingLink = nil
        let wasGliding = fling != nil
        fling = nil
        if wasGliding {
            settleAfterManualMove()
        } else {
            chromeRail?.attachToParent()
            refreshAutosaveSuspension()
        }
    }

    /// Any interruption — a new grab, a shade fold, a programmatic placement,
    /// close — kills the glide and keeps its last position (the interrupter
    /// owns the frame from here, and its own rest will persist again).
    private func cancelFling() {
        guard fling != nil || flingLink != nil else { return }
        stopFling()
    }

    /// Any frame change that didn't come from the fling tick or the persistence
    /// swap itself cancels an in-flight glide — this is what makes programmatic
    /// animation (animateLock, entrances, grid placement) supersede a fling.
    /// This override must use Objective-C dynamic dispatch. AppKit's
    /// `animator()` returns an `_NSAnimProxy` typed as `Self`; a native Swift
    /// call would run this body with the proxy as `self` and interpret its
    /// storage as `NotePanel` ivars instead of letting the proxy forward the
    /// message to the real panel.
    @objc dynamic override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if !applyingPhysicsFrame { cancelFling() }
        super.setFrame(frameRect, display: flag)
    }

    /// AppKit remaps a borderless panel onto the screen it already owns.
    /// A drop that already intersects some display is a real destination —
    /// do not rewrite it onto the origin monitor. Off-screen restores still
    /// go through the default constraint.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let proposed: NSRect
        if dragInProgress || fling != nil || applyingPhysicsFrame {
            proposed = frameRect
        } else {
            let landsOnADisplay = NSScreen.screens.contains { candidate in
                let hit = candidate.frame.intersection(frameRect)
                return !hit.isNull && !hit.isEmpty
            }
            proposed = landsOnADisplay ? frameRect : super.constrainFrameRect(frameRect, to: screen)
        }
        return proposed
    }


    @objc dynamic override func setFrame(_ frameRect: NSRect, display flag: Bool, animate flag2: Bool) {
        if !applyingPhysicsFrame { cancelFling() }
        super.setFrame(frameRect, display: flag, animate: flag2)
    }

    override func close() {
        cancelFling()
        railHideWork?.cancel()
        railHideWork = nil
        railLinger = false
        railPointerInside = false
        // A child window outlives its parent's close unless detached, which
        // would strand a rail floating over nothing.
        chromeRail?.dismantle()
        chromeRail = nil
        super.close()
    }

    /// User-initiated mode change from native chrome (toggle click or ⌘⇧P).
    func selectMode(_ mode: String) {
        guard mode != modeState.mode else { return }
        editor.setMode(mode)
        reflectMode(mode)
        if mode == "edit" {
            makeKey()
            makeFirstResponder(editor.webView)
            editor.focus()
        }
        onUserModeChange?(mode)
    }

    /// Copy the exact agent-facing id, then return keyboard focus to the editor
    /// so identifying a note never interrupts the writing flow.
    private func copyNoteID() {
        copyToPasteboard(noteID)
        guard currentMode == "edit" else { return }
        makeKey()
        makeFirstResponder(editor.webView)
        editor.focus()
    }

    private var noteFileURL: URL {
        BlinkPaths.notes().appendingPathComponent("\(noteID).md", isDirectory: false)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Observable state shared by the panel's SwiftUI chrome.
@MainActor
final class PanelModeState: ObservableObject {
    @Published var mode: String = "edit"
    @Published var focus: Bool = false
    @Published var sheet: String = "glass"
    @Published var style: String?
    @Published var font: String = "System"
    @Published var fontSize: Double = 13
    @Published var mark: String?

    var hasThemeMark: Bool {
        mark != nil
    }
}

/// ✎/◧ mode segments; the active segment is lit. Hover-revealed, top-right —
/// or carried by the detached rail when `panel.chrome` is "rail".
struct ModeToggle: View {
    @ObservedObject var state: PanelModeState
    @ObservedObject private var configStore = BlinkConfigStore.shared
    /// Ink for the glyphs. In-note chrome sits on the panel's darkened glass and
    /// wants white; the detached rail floats over whatever is on the desktop, so
    /// it passes an appearance-adaptive color instead.
    var ink: Color = .white
    var onSelect: (String) -> Void

    private var shortcut: String {
        KeyChord.parse(configStore.config.hotkeys.toggleMode)?.display
            ?? configStore.config.hotkeys.toggleMode
    }

    var body: some View {
        HStack(spacing: 2) {
            segment(icon: "pencil", mode: "edit", help: "Edit (\(shortcut))")
            segment(icon: "book", mode: "read", help: "Read (\(shortcut))")
        }
        .padding(2)
        .background(ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    var accent: Color?

    private var lit: Color { accent ?? ink }

    private func segment(icon: String, mode: String, help: String) -> some View {
        Button {
            onSelect(mode)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(state.mode == mode ? lit : ink.opacity(0.42))
                .frame(width: 22, height: 18)
                .background(
                    state.mode == mode ? lit.opacity(0.20) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The stable, copyable note/window identity at bottom-center in edit mode.
private struct NoteIdentifierBadge: View {
    let noteID: String
    var onCopy: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            onCopy()
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.12)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Text(copied ? "copied" : "id")
                    .foregroundStyle(Color.primary.opacity(0.55))
                Text(noteID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Note ID: \(noteID) — click to copy for an agent")
    }
}

/// A tiny build signature at bottom-left. Theme identity never lives here;
/// `ThemeMarkBadge` owns the top-left chrome cell above.
private struct AppVersionLabel: View {
    let version: String

    var body: some View {
        Text("Canvas v\(version)")
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.34))
            .lineLimit(1)
            .frame(height: 18)
            .help("Canvas \(version)")
    }
}

/// Theme identity in the panel's top-left chrome.
private struct ThemeMarkBadge: View {
    @ObservedObject var state: PanelModeState

    var body: some View {
        Group {
            if let image = ThemeMarkLoader.image(named: state.mark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Theme mark")
            }
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .help("Theme identity")
    }
}

/// Resolve theme marks from Blink's attachment store, never from note markdown.
/// The relative-only + symlink containment rule lives in
/// `BlinkPaths.attachment(named:)` so the app and the `blink` CLI enforce one
/// boundary: a theme typo becomes an absent mark, not an arbitrary file read.
private enum ThemeMarkLoader {
    static func image(named raw: String?) -> NSImage? {
        guard let url = BlinkPaths.attachment(named: raw) else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Read-mostly treatment metadata at bottom-right. It stays quieter than the
/// centered identity; clicking jumps straight into the sheet picker.
private struct StyleMetadataBadge: View {
    @ObservedObject var state: PanelModeState
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    styleLabel
                    Text("·").foregroundStyle(Color.primary.opacity(0.25))
                    Text("\(state.font) \(formattedFontSize)")
                        .lineLimit(1)
                }
                styleLabel
            }
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(hovering ? 0.70 : 0.42))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Color.primary.opacity(hovering ? 0.07 : 0.025), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Style: \(state.sheet) — click to change")
    }

    private var styleLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "paintpalette")
                .font(.system(size: 8))
            if let style = state.style {
                Text("\(style)/\(state.sheet)").lineLimit(1)
            } else {
                Text(state.sheet).lineLimit(1)
            }
        }
    }

    private var formattedFontSize: String {
        state.fontSize.rounded() == state.fontSize
            ? String(Int(state.fontSize))
            : String(format: "%.1f", state.fontSize)
    }
}

/// The focus ring: a small dashed circle, alone in the bottom-right corner —
/// deliberately not a peer of the mode segments. Fills in while focus is on.
struct FocusGlyph: View {
    @ObservedObject var state: PanelModeState
    @ObservedObject private var configStore = BlinkConfigStore.shared
    var ink: Color = .white
    var accent: Color?
    var onTap: () -> Void

    private var shortcut: String {
        KeyChord.parse(configStore.config.hotkeys.focus)?.display
            ?? configStore.config.hotkeys.focus
    }

    var body: some View {
        Button(action: onTap) {
            Image(systemName: state.focus ? "circle.dashed.inset.filled" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(state.focus ? (accent ?? ink) : ink.opacity(0.50))
        }
        .buttonStyle(.plain)
        .help("Focus — quiet everything else (\(shortcut))")
    }
}

/// Invisible top-edge strip that moves the window — the webview eats clicks
/// everywhere else, so this is the drag surface (the titlebar's ghost, minus
/// the band).
///
/// The drag is tracked manually (not `performDrag`) so the gesture carries
/// data the OS drag never exposes: a release velocity (a fast throw becomes a
/// momentum fling) and a shake signature (folds the panel into the band).
/// The move math is the classic grab-relative offset, so an ordinary drag
/// feels exactly like the native one — the cursor keeps its grip point.
final class DragHandle: NSView {
    private var isDragging = false
    private var isHovering = false
    private var tracking: NSTrackingArea?
    private var grabMouse = NSPoint.zero   // screen point at mouseDown
    private var grabOrigin = NSPoint.zero  // window origin at mouseDown
    private var tracker = DragVelocityTracker()
    private var shake = ShakeDetector()
    /// Held for the whole gesture. The rail detaches from its parent mid-drag
    /// so the note can change displays; `window?.parent` would go nil.
    private weak var dragTarget: NotePanel?

    /// The in-panel strip paints a hairline grip to advertise itself. The
    /// detached rail is already visibly grabbable, so it opts out.
    var showsGrip = true

    /// The note this handle moves. Inside the panel that is the handle's own
    /// window; on the detached chrome rail it is the rail's parent, so the
    /// gesture moves the note rather than the strip sitting on top of it.
    private var notePanel: NotePanel? {
        dragTarget ?? window as? NotePanel ?? window?.parent as? NotePanel
    }


    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A hairline grip keeps the borderless panel discoverably movable
        // without turning the strip into visible window chrome.
        guard showsGrip else { return }
        let alpha: CGFloat = isDragging ? 0.38 : (isHovering ? 0.24 : 0.08)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        let grip = NSRect(x: bounds.midX - 12, y: bounds.maxY - 5, width: 24, height: 2)
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.openHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging { needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = notePanel else { return }
        // Double-click on the band toggles the shade — the classic windowshade
        // gesture. The click that opened the pair already ran a movement-less
        // drag begin/end, so nothing here is left in flight; the paired
        // mouseUp finds isDragging false and is ignored.
        if event.clickCount == 2 {
            panel.toggleShade()
            return
        }
        dragTarget = panel
        panel.beginManualDrag()
        grabMouse = NSEvent.mouseLocation
        grabOrigin = panel.frame.origin
        tracker.reset()
        shake.reset()
        isDragging = true
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let panel = notePanel else { return }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(
            x: grabOrigin.x + mouse.x - grabMouse.x,
            y: grabOrigin.y + mouse.y - grabMouse.y
        )
        panel.moveByPhysics(to: origin)
        tracker.add(origin, at: event.timestamp)
        // Shake → shade. The fold/grow moves the origin under the cursor, so
        // re-anchor the grab and restart the gesture's sensors or the panel
        // would jump on the next dragged event.
        if panel.shakeGesturesEnabled, shake.add(origin, at: event.timestamp) {
            panel.toggleShade()
            grabOrigin = panel.frame.origin
            grabMouse = mouse
            tracker.reset()
            shake.reset()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let panel = notePanel else { return }
        isDragging = false
        dragTarget = nil
        NSCursor.openHand.set()
        needsDisplay = true
        tracker.add(panel.frame.origin, at: event.timestamp)
        panel.endManualDrag(velocity: tracker.velocity())
    }
}

/// The close glyph: a small ✕ alone in the top-left corner, mirroring the mode
/// pill top-right. Hover-revealed. Replaces the hidden traffic-light close.
struct CloseGlyph: View {
    var ink: Color = .white
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ink.opacity(0.70))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .help("Close (⌘W)")
    }
}
