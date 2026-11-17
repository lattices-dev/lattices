import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The unified command bar surface — one bar for search, slash-commands and
/// (later) voice, opened in a mode-specific way:
///   • `.command` (Ctrl+Opt+Space) prefills "/" → command mode
///   • `.search`  (Hyper+5)        empty, focused → search
///   • `.voice`   (Phase B)        auto-listen
///
/// Composes `UnifiedCommandBarState` (which reuses OmniSearch + the command
/// engine). The window owns the panel, the ghost preview, the key monitor, and
/// the captured frontmost target. Ghost + commit logic are lifted from
/// `OmniSearchWindow`, which this replaces once the other phases land.
final class UnifiedCommandBarWindow {
    static let shared = UnifiedCommandBarWindow()

    enum Mode { case command, search, voice }

    /// Readable so siblings (e.g. `ScreenMapWindowController`) can avoid
    /// overlapping the bar — mirrors the old `VoiceCommandWindow.shared.panel`.
    private(set) var panel: OverlayPanel?
    private var ghost: NSPanel?
    private var gridHint: NSPanel?
    private var state: UnifiedCommandBarState?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var ghostObserver: AnyCancellable?
    private var queryObserver: AnyCancellable?
    private var voicePhaseObserver: AnyCancellable?
    private var optionKeyDown = false
    private var optionPushToTalkActive = false
    /// Push-to-talk may only arm after ⌥ has been seen UP since the bar opened.
    /// Opening via a hotkey that contains ⌥ (Ctrl+Opt+Space) otherwise triggers
    /// listening on chord release: Space/Ctrl come up a few ms before ⌥, and
    /// that flagsChanged reads as a fresh ⌥ press.
    private var optionSeenReleased = false

    private var capturedTarget: (wid: UInt32, pid: Int32)?
    private var capturedScreen: NSScreen?
    private var lastHighlightedWid: UInt32?
    private var lastHighlightAt: Date = .distantPast

    private let panelWidth: CGFloat = 560

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(mode: Mode = .search) {
        if isVisible { dismiss() } else { show(mode: mode) }
    }

    /// `query` seeds the bar's text — lets other surfaces (e.g. the menu-bar
    /// Mini-Home Bar pane) hand off typed input instead of just opening it.
    func show(mode: Mode = .search, query: String? = nil) {
        if let p = panel, p.isVisible {
            if let query, let state { state.query = query }
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Capture app identity and display before presenting takes focus.
        DesktopModel.shared.forcePoll()
        let front = DesktopModel.shared.frontmostWindow()
        if let entry = front {
            capturedTarget = (wid: entry.wid, pid: entry.pid)
            capturedScreen = screenForWindowFrame(entry.frame)
        }

        let arrangement = AppArrangementTarget.make(
            anchor: front, windows: DesktopModel.shared.allWindows(),
            displayName: capturedScreen?.localizedName ?? "Current display",
            displayForWindow: AppArrangementTarget.displayID(for:)
        )
        let st = UnifiedCommandBarState(arrangementTarget: arrangement)
        if mode == .command {
            st.query = "/"
        }
        if let query {
            st.query = query
        }
        state = st

        let view = UnifiedCommandBarView(
            state: st,
            onCommit: { [weak self] in self?.commit() },
            onMic: { [weak self] in self?.onMic() },
            onSettings: { [weak self] in self?.dismiss(); SettingsWindowController.shared.show() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        .preferredColorScheme(.dark)

        let presentationScreen = invocationScreen()
        let panelHeight = min(520, presentationScreen.visibleFrame.height - 200)

        let p = OverlayPanelShell.makePanel(
            config: .init(
                size: NSSize(width: panelWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                background: .clear,          // SwiftUI draws the opaque card + shadow
                level: .floating,
                hasShadow: false,            // the card draws its own shadow
                hidesOnDeactivate: false,
                isMovableByWindowBackground: true,   // drag the bar/panel chrome to reposition
                // Do not use `.canJoinAllSpaces` here: on multi-display
                // setups macOS can mirror all-spaces panels onto each active
                // display. Moving to the active Space keeps a single command
                // box on the screen that invoked it.
                collectionBehavior: [.moveToActiveSpace, .fullScreenAuxiliary],
                activatesOnMouseDown: true
            ),
            rootView: view
        )
        p.becomesKeyOnlyIfNeeded = false   // keep the panel key so the field stays focused (no beep) and Esc works
        positionPanel(p, on: presentationScreen)
        // Restore the last dragged position only when it belongs to the screen
        // that invoked the bar. A stale origin on another monitor is worse than
        // the default top-center placement.
        if let o = savedOrigin(for: p.frame.size, on: presentationScreen) {
            p.setFrameOrigin(o)
        }
        OverlayPanelShell.present(p)
        panel = p

        // Re-assert key on the next runloop tick — present() can fire before the
        // hosting view is mounted, leaving the field unfocused on first open.
        DispatchQueue.main.async { [weak p] in p?.makeKeyAndOrderFront(nil) }

        installKeyMonitor()
        installVoiceMonitor()
        installGhostObservers(st)

        // The dedicated voice hotkey opens straight into listening.
        if mode == .voice {
            DispatchQueue.main.async { st.voice.startListening() }
        }
    }

    func dismiss() {
        savePosition()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        resetOptionVoiceTracking()
        ghostObserver?.cancel(); ghostObserver = nil
        queryObserver?.cancel(); queryObserver = nil
        voicePhaseObserver?.cancel(); voicePhaseObserver = nil
        state?.voice.cancelProcessing()   // stop any in-flight capture/transcription
        ghost?.orderOut(nil); ghost = nil
        gridHint?.orderOut(nil); gridHint = nil
        lastHighlightedWid = nil
        lastHighlightAt = .distantPast
        panel?.orderOut(nil); panel = nil
        state = nil
        capturedTarget = nil
        capturedScreen = nil
    }

    // MARK: - Position persistence

    private let originKey = "unifiedCommandBar.originV1"

    private func savePosition() {
        guard let p = panel else { return }
        let o = p.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: originKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
        return NSPoint(x: a[0], y: a[1])
    }

    private func savedOrigin(for size: CGSize, on screen: NSScreen) -> NSPoint? {
        guard let origin = savedOrigin() else { return nil }
        let frame = CGRect(origin: origin, size: size)
        return screen.visibleFrame.intersects(frame) ? origin : nil
    }

    private func invocationScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? capturedScreen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func positionPanel(_ panel: NSWindow, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 120
        ))
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            let cmd = self.state?.commandMode == true
            switch event.keyCode {
            case 53: // Escape — first stops listening, then dismisses
                if let voice = self.state?.voice {
                    if voice.phase == .listening {
                        self.resetOptionVoiceTracking()
                        voice.stopListening()
                        return nil
                    }
                    if voice.phase == .connecting {
                        self.resetOptionVoiceTracking()
                        voice.cancelProcessing()
                        return nil
                    }
                }
                self.dismiss(); return nil
            case 125: // ↓
                self.state?.moveSelection(1); return nil
            case 126: // ↑
                self.state?.moveSelection(-1); return nil
            case 36, 76: // Return / Enter — ⌘↵ always hands off to the assistant
                if event.modifierFlags.contains(.command) {
                    self.handToAssistant(self.assistantPrompt()); return nil
                }
                self.commit(); return nil
            case 48: // Tab — complete the highlighted command
                if cmd { self.complete(); return nil }
                return event
            default:
                // Type-to-exit: a printable keypress while voice owns the bar
                // (listening, transcribing, or showing a result) cancels voice
                // and drops back to the text field with the keystroke kept —
                // the transcript view is read-only, so without this the only
                // way back to typing was dismissing the whole bar.
                if let st = self.state, st.voiceActive,
                   let chars = event.characters, !chars.isEmpty,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                       .isDisjoint(with: [.command, .option, .control]) {
                    self.resetOptionVoiceTracking()
                    st.voice.cancelListening()
                    st.query += chars
                    return nil
                }
                return event
            }
        }
    }

    /// Push-to-talk: hold ⌥ to record, release to stop. A global flags monitor
    /// catches the release even if focus shifts while the non-activating panel is up.
    private func installVoiceMonitor() {
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isVisible, let voice = state?.voice else { return }
        let optionDown = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.option)

        if optionDown {
            guard !optionKeyDown else { return }
            optionKeyDown = true

            if voice.phase == .listening && !optionPushToTalkActive {
                optionPushToTalkActive = false
                voice.stopListening()
            } else if voice.armed && optionSeenReleased
                        && (voice.phase == .idle || voice.phase == .result)
                        && panel?.isKeyWindow == true {
                // Only START push-to-talk while the bar is key. The global flags
                // monitor exists to catch the RELEASE after focus shifts; without
                // this gate an ⌥ press aimed at another app would begin recording.
                optionPushToTalkActive = true
                voice.startListening()
            }
            return
        }

        optionSeenReleased = true
        guard optionKeyDown else { return }
        optionKeyDown = false
        if optionPushToTalkActive {
            switch voice.phase {
            case .connecting:
                voice.cancelProcessing()
            case .listening:
                voice.stopListening()
            default:
                break
            }
        }
        optionPushToTalkActive = false
    }

    private func resetOptionVoiceTracking() {
        optionKeyDown = false
        optionPushToTalkActive = false
        optionSeenReleased = false
    }

    // MARK: - Commit / drill-in

    private func commit() {
        guard let st = state else { return }
        if st.voiceActive {
            commitVoice(st.voice)
            return
        }
        if st.commandMode {
            // Enter on an empty / unmatched command is a no-op, not a dismiss.
            guard let s = st.search.command.selected else { return }
            switch s.action {
            case .fillCommand(let c):
                st.query = "/" + (c.hint.aliases.first ?? c.name) + " "
            case .setQuery(let q):
                st.query = "/" + q
            case .selectTileTarget(let wid, let label):
                let verb = commandVerb(from: st.search.command.query, fallback: "tile")
                st.search.command.selectTileTarget(wid: wid, label: label)
                st.query = "/" + verb + " "
            case .placeCurrent(let spec):
                guard let t = capturedTarget else { dismiss(); return }
                let screen = capturedScreen ?? NSScreen.main ?? NSScreen.screens.first!
                let app = DesktopModel.shared.windows[t.wid]?.app ?? "Window"
                let arrow = placementArrow(spec)
                flyIn(wid: t.wid, to: spec, on: screen)   // trace the move before it happens
                dismiss()
                WindowTiler.tileWindowById(wid: t.wid, pid: t.pid, to: spec, on: screen)
                showConfirmation(glyph: arrow, title: app, subtitle: s.label, on: screen)
            case .runCommand(let intent, let slots, let subject):
                if let spec = s.previewSpec,
                   let target = previewTarget(for: s, slots: slots, subject: subject) {
                    flyIn(wid: target.wid, to: spec, on: target.screen)
                }
                runIntent(intent, slots: slots, subject: subject, confirmGlyph: s.glyph, confirmTitle: s.label)
            }
        } else if IntentHeuristics.shouldAskAssistant(st.query) {
            handToAssistant(st.query)            // a Lattices question → the assistant
        } else if let match = st.nlMatch {
            runNLCommand(match)                   // typed natural-language command → run it
        } else {
            // The list renders results *grouped*; the selection indexes that same
            // grouped order. Activate the displayed row — NOT `results[selectedIndex]`
            // (raw score order), which would act on a different window than the one
            // highlighted/clicked.
            let ordered = st.search.groupedResults.flatMap { $0.1 }
            guard st.search.selectedIndex >= 0, st.search.selectedIndex < ordered.count else { return }
            let result = ordered[st.search.selectedIndex]
            if result.arrangementTarget != nil {
                dismiss()
                result.action()
            } else {
                result.action()
                dismiss()
            }
        }
    }

    /// Dismiss first so the launcher's key/focus teardown cannot close Motion.
    /// The captured set is validated again, never re-resolved as "all terminals".
    func openArrangement(_ target: AppArrangementTarget) {
        dismiss()
        DesktopModel.shared.forcePoll()
        let valid = target.isValid(in: DesktopModel.shared.allWindows(),
                                   displayForWindow: AppArrangementTarget.displayID(for:))
        guard valid, WindowMotionMode.shared.arrangeWindows(windowIDs: target.windowIDs, on: target.displayID) else {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
            }
            showConfirmation(glyph: "exclamationmark.triangle", title: "Windows changed",
                             subtitle: "Reopen the command bar to refresh \(target.appName).", on: screen)
            return
        }
    }

    private func commandVerb(from raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").first.map(String.init) ?? fallback
    }

    private func commitVoice(_ voice: VoiceCommandState) {
        switch voice.phase {
        case .connecting:
            resetOptionVoiceTracking()
            voice.cancelProcessing()
        case .listening:
            resetOptionVoiceTracking()
            voice.stopListening()
        case .result:
            if voiceResultCanRetry(voice) {
                resetOptionVoiceTracking()
                voice.startListening()
            } else {
                dismiss()
            }
        case .idle, .transcribing:
            break
        }
    }

    private func voiceResultCanRetry(_ voice: VoiceCommandState) -> Bool {
        let result = voice.executionResult ?? ""
        return VoiceCommandState.isRetryableFailure(result)
    }

    // MARK: - Natural-language command

    /// Run a command the NL resolver inferred from typed free text. Placement
    /// intents (`tile_window` / `move_to_display`) act on the captured frontmost
    /// window — they otherwise carry no window id; everything else runs with its
    /// own slots.
    private func runNLCommand(_ m: IntentMatch) {
        let windowActing = ["tile_window", "move_to_display"].contains(m.intentName)
        let subject: CommandSubject = windowActing ? .currentWindow : .global
        // Trace a placement move with the ghost before it happens.
        if windowActing, let spec = state?.nlSpec, let t = capturedTarget,
           let screen = capturedScreen ?? NSScreen.main {
            flyIn(wid: t.wid, to: spec, on: screen)
        }
        let confirm = nlConfirm(m)
        runIntent(m.intentName, slots: m.slots, subject: subject,
                  confirmGlyph: confirm.glyph, confirmTitle: confirm.title)
    }

    /// Glyph + title for the post-run confirmation bezel of an NL command.
    private func nlConfirm(_ m: IntentMatch) -> (glyph: String, title: String) {
        if m.intentName == "tile_window",
           let pos = m.slots["position"]?.stringValue,
           let spec = PlacementSpec(string: pos) {
            let app = capturedTarget.flatMap { DesktopModel.shared.windows[$0.wid]?.app } ?? "Window"
            return (placementArrow(spec), app)
        }
        return ("checkmark", m.intentName.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    // MARK: - Confirmation

    /// A brief, self-expiring confirmation bezel announcing what just ran —
    /// decoupled from the bar (which has already dismissed), à la Raycast's HUD,
    /// but in the notch-pill bezel treatment with a stylized direction arrow.
    private func showConfirmation(glyph: String, title: String, subtitle: String?, on screen: NSScreen?) {
        PlacementBezel.shared.show(glyph: glyph, title: title, subtitle: subtitle, on: screen)
    }

    /// A stylized SF Symbol arrow for a placement (the bezel's hero glyph).
    private func placementArrow(_ spec: PlacementSpec) -> String {
        if case .tile(let pos) = spec { return pos.arrowGlyph }
        return "checkmark"
    }

    // MARK: - Assistant handoff

    /// The prompt to escalate: voice transcript if speaking, else the typed text
    /// (slash stripped so a command-mode "/x" reads as plain "x").
    private func assistantPrompt() -> String {
        guard let st = state else { return "" }
        if st.voiceActive {
            return st.voice.assistantHandoffPrompt
                ?? IntentHeuristics.assistantPromptText(st.voice.finalText)
        }
        var q = st.query
        if q.hasPrefix("/") { q.removeFirst() }
        return IntentHeuristics.assistantPromptText(q)
    }

    /// Open the workspace assistant and stream the prompt; the bar steps aside.
    private func handToAssistant(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismiss()
        DispatchQueue.main.async {
            ScreenMapWindowController.shared.showAssistant()
            WorkspaceAssistantSession.shared.send(text)
        }
    }

    /// Reveal the assistant for a voice prompt that `AudioLayer` has already
    /// queued into `WorkspaceAssistantSession`.
    private func showAssistantForQueuedVoiceHandoff() {
        dismiss()
        DispatchQueue.main.async {
            ScreenMapWindowController.shared.showAssistant()
        }
    }

    /// A conversational voice utterance (a question with no workspace action ran)
    /// is handed to the assistant rather than answered headlessly in the bar.
    private func maybeEscalateVoiceQuestion() {
        guard let st = state, st.voice.phase == .result,
              st.voice.intentName == nil else { return }

        if let prompt = st.voice.assistantHandoffPrompt,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showAssistantForQueuedVoiceHandoff()
            return
        }

        guard IntentHeuristics.shouldAskAssistant(st.voice.finalText) else { return }
        handToAssistant(IntentHeuristics.assistantPromptText(st.voice.finalText))
    }

    /// Tab-to-complete: fill the field with the highlighted suggestion fully
    /// typed out (a following ↵ then runs it). The completion text is computed by
    /// the command engine so it stays correct across stages.
    private func complete() {
        guard let st = state, let s = st.search.command.selected else { return }
        st.query = "/" + st.search.command.completion(for: s)
    }

    private func previewTarget(for suggestion: CommandSuggestion, slots: [String: JSON], subject: CommandSubject) -> (wid: UInt32, screen: NSScreen)? {
        let wid = suggestion.previewWid
            ?? slots["wid"]?.uint32Value
            ?? (subject == .currentWindow ? capturedTarget?.wid : nil)
        guard let wid else { return nil }
        let screen = suggestion.previewScreen
            ?? DesktopModel.shared.windows[wid].map { WindowTiler.screenForWindowFrame($0.frame) }
            ?? capturedScreen
            ?? NSScreen.main
        guard let screen else { return nil }
        return (wid, screen)
    }

    private func runIntent(_ intent: String, slots: [String: JSON], subject: CommandSubject,
                           confirmGlyph: String? = nil, confirmTitle: String? = nil) {
        var slots = slots
        if subject == .currentWindow, let t = capturedTarget {
            slots["wid"] = .int(Int(t.wid))
        }
        let screen = capturedScreen
        dismiss()
        do {
            let (name, normalized) = try IntentEngine.shared.normalizeResolved(intentName: intent, slots: slots)
            _ = try IntentEngine.shared.execute(IntentRequest(
                intent: name, slots: normalized, rawText: nil, confidence: 1.0, source: "unified-command-bar"
            ))
            if let confirmTitle {
                showConfirmation(glyph: confirmGlyph ?? "checkmark", title: confirmTitle, subtitle: nil, on: screen)
            }
        } catch {
            DiagnosticLog.shared.error("UnifiedCommandBar command \(intent) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Mic

    /// Tapping the mic toggles listening (start/stop); ⌥-hold is the power gesture.
    private func onMic() {
        guard let voice = state?.voice else { return }
        switch voice.phase {
        case .connecting:
            resetOptionVoiceTracking()
            voice.cancelProcessing()
        case .listening:
            resetOptionVoiceTracking()
            voice.stopListening()
        case .idle, .result:
            resetOptionVoiceTracking()
            voice.startListening()
        case .transcribing:
            break
        }
    }

    // MARK: - Glide (grab → accelerate → snap)

    /// A translucent ghost accelerates from the window's current frame to its
    /// destination and snaps — tracing the move. The real window relocates
    /// instantly underneath (the reliable SkyLight path is untouched); this is
    /// pure motion garnish that survives the bar dismissing.
    private func flyIn(wid: UInt32, to spec: PlacementSpec, on screen: NSScreen) {
        guard let entry = DesktopModel.shared.windows[wid] else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 1080
        let f = entry.frame
        let from = CGRect(x: CGFloat(f.x),
                          y: primaryH - CGFloat(f.y) - CGFloat(f.h),
                          width: CGFloat(f.w), height: CGFloat(f.h))
        let to = ghostFrame(for: spec, on: screen)
        guard from != to else { return }

        let fly = makeGhost()
        fly.setFrame(from, display: true)
        fly.alphaValue = 0.85
        fly.orderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)   // grab → accelerate
            fly.animator().setFrame(to, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.14
                fly.animator().alphaValue = 0                            // snap → fade
            }, completionHandler: { fly.orderOut(nil) })
        })
    }

    // MARK: - Ghost preview (lifted from OmniSearchWindow)

    private func installGhostObservers(_ st: UnifiedCommandBarState) {
        ghostObserver = st.search.command.$selectedIndex
            .combineLatest(st.search.command.$suggestions)
            .sink { [weak self] _ in self?.updateGhost() }
        queryObserver = st.$query
            .sink { [weak self] _ in self?.updateGhost() }

        // When a voice turn settles, escalate conversational questions to the
        // assistant. Deferred to the main runloop so the @Published phase (which
        // publishes in willSet) and the synced transcript/intent have settled.
        voicePhaseObserver = st.voice.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard phase == .result else { return }
                self?.maybeEscalateVoiceQuestion()
            }
    }

    private func updateGhost() {
        guard let st = state else {
            hidePlacementPreview()
            return
        }
        // Command mode previews the highlighted suggestion; plain-text NL commands
        // preview the resolved placement.
        let spec: PlacementSpec?
        let screen: NSScreen?
        let sourceWid: UInt32?
        if st.commandMode {
            let selected = st.search.command.selected
            spec = st.search.command.previewSpec
            screen = st.search.command.previewScreen ?? capturedScreen
            sourceWid = selected?.previewWid ?? st.search.command.tileTarget?.wid ?? (spec == nil ? nil : capturedTarget?.wid)
        } else {
            spec = st.nlSpec
            screen = capturedScreen
            sourceWid = spec == nil ? nil : capturedTarget?.wid
        }

        if let sourceWid {
            highlightPreviewSource(wid: sourceWid)
        }

        guard let spec, let screen else {
            hidePlacementPreview()
            return
        }
        let g = ghost ?? makeGhost()
        g.setFrame(ghostFrame(for: spec, on: screen), display: true)
        g.orderFront(nil)
        updateGridHint(for: spec, on: screen)
        panel?.orderFront(nil)   // bar + ghost share .floating → keep the bar on top
        ghost = g
    }

    private func hidePlacementPreview() {
        ghost?.orderOut(nil); ghost = nil
        gridHint?.orderOut(nil); gridHint = nil
    }

    private func highlightPreviewSource(wid: UInt32) {
        let now = Date()
        guard wid != lastHighlightedWid || now.timeIntervalSince(lastHighlightAt) > 1.2 else { return }
        lastHighlightedWid = wid
        lastHighlightAt = now
        WindowTiler.highlightWindowById(wid: wid)
    }

    private func updateGridHint(for spec: PlacementSpec, on screen: NSScreen) {
        guard case .grid(let grid) = spec else {
            gridHint?.orderOut(nil)
            gridHint = nil
            return
        }

        let hint = gridHint ?? makeGridHint()
        hint.setFrame(screen.visibleFrame, display: true)
        hint.contentView = NSHostingView(
            rootView: GridPlacementScreenHint(grid: grid)
                .preferredColorScheme(.dark)
        )
        hint.orderFront(nil)
        gridHint = hint
    }

    /// Destination frame in Cocoa (bottom-left origin) screen coordinates.
    /// `PlacementSpec.fractions` measures y from the TOP, so flip it.
    private func ghostFrame(for spec: PlacementSpec, on screen: NSScreen) -> CGRect {
        let (fx, fy, fw, fh) = spec.fractions
        let vf = screen.visibleFrame
        return CGRect(
            x: vf.origin.x + vf.width * fx,
            y: vf.maxY - vf.height * (fy + fh),
            width: vf.width * fw,
            height: vf.height * fh
        )
    }

    private func makeGhost() -> NSPanel {
        let g = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        g.isOpaque = false
        g.backgroundColor = .clear
        g.level = .floating
        g.hasShadow = false
        g.ignoresMouseEvents = true
        g.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        g.sharingType = .readOnly

        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 6
        g.contentView = v
        return g
    }

    private func makeGridHint() -> NSPanel {
        let g = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        g.isOpaque = false
        g.backgroundColor = .clear
        g.level = .floating
        g.hasShadow = false
        g.ignoresMouseEvents = true
        g.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        g.sharingType = .readOnly
        return g
    }

    private func screenForWindowFrame(_ f: WindowFrame) -> NSScreen {
        let primaryH = NSScreen.screens.first?.frame.height ?? 1080
        let cx = CGFloat(f.x + f.w / 2)
        let cyTop = CGFloat(f.y + f.h / 2)
        let pt = NSPoint(x: cx, y: primaryH - cyTop)
        return NSScreen.screens.first(where: { $0.frame.contains(pt) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct GridPlacementScreenHint: View {
    let grid: GridPlacement

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let cellW = width / CGFloat(grid.columns)
            let cellH = height / CGFloat(grid.rows)
            let selected = CGRect(
                x: CGFloat(grid.column) * cellW,
                y: CGFloat(grid.row) * cellH,
                width: CGFloat(grid.columnSpan) * cellW,
                height: CGFloat(grid.rowSpan) * cellH
            )
            let badgeX = min(max(12, selected.minX + 12), max(12, width - 150))
            let badgeY = min(max(12, selected.minY + 12), max(12, height - 34))

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.055)

                Path { path in
                    for column in 1..<grid.columns {
                        let x = CGFloat(column) * cellW
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }
                    for row in 1..<grid.rows {
                        let y = CGFloat(row) * cellH
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HUDChrome.cyan.opacity(0.13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(HUDChrome.cyan.opacity(0.85), lineWidth: 2)
                    )
                    .frame(width: selected.width, height: selected.height)
                    .offset(x: selected.minX, y: selected.minY)

                if grid.columns * grid.rows <= 36 {
                    ForEach(0..<(grid.columns * grid.rows), id: \.self) { index in
                        let column = index % grid.columns
                        let row = index / grid.columns
                        Text("\(column + 1),\(row + 1)")
                            .font(Typo.monoBold(11))
                            .foregroundColor(cellIsSelected(column: column, row: row)
                                ? HUDChrome.cyan.opacity(0.95)
                                : Palette.textMuted.opacity(0.72))
                            .frame(width: cellW, height: cellH, alignment: .center)
                            .offset(x: CGFloat(column) * cellW, y: CGFloat(row) * cellH)
                    }
                }

                Text(grid.compactValue)
                    .font(Typo.monoBold(12))
                    .foregroundColor(HUDChrome.onSignal)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(HUDChrome.cyan.opacity(0.92))
                    )
                    .offset(x: badgeX, y: badgeY)
            }
        }
    }

    private func cellIsSelected(column: Int, row: Int) -> Bool {
        column >= grid.column
            && column < grid.column + grid.columnSpan
            && row >= grid.row
            && row < grid.row + grid.rowSpan
    }
}
