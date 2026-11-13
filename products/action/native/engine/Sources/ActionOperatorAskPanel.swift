import ActionCore
import AppKit
import Darwin
import IOKit
import SwiftUI

/// Clicks never make this panel the operator's keyboard target. A drag of the
/// subject app is the one exception: AppKit swallows drag sessions that start in
/// a window that refuses key, so the panel takes key only for that gesture.
private final class ActionOperatorAskPanel: NSPanel {
    var allowsKeyForDrag = false
    override var canBecomeKey: Bool { allowsKeyForDrag }
    override var canBecomeMain: Bool { false }

    var onDismiss: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

private final class ActionOperatorAskHostingView: NSHostingView<ActionOperatorAskView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One gutter and radii nested from the theme's small radius, so every corner
/// in the panel is concentric with the one around it: button → row/card → panel.
private enum AskMetrics {
    static let width: CGFloat = 380
    /// Panel edge to a card or row.
    static let gutter: CGFloat = 8
    /// Card or row edge to its content.
    static let inset: CGFloat = 12
    /// Row edge to its button; the footer button sits `gutter + buttonInset` in.
    static let buttonInset: CGFloat = 4
    /// The one leading edge text, glyphs and the subject icon share.
    static var lead: CGFloat { gutter + inset }
    static let rowHeight: CGFloat = 44
    static var buttonHeight: CGFloat { rowHeight - 2 * buttonInset }
    static let icon: CGFloat = 52
    static var cardHeight: CGFloat { icon + 2 * inset }
    static var buttonRadius: CGFloat { StageHUDTheme.cornerRadiusSmall }
    static var rowRadius: CGFloat { buttonRadius + buttonInset }
    static var panelRadius: CGFloat { rowRadius + gutter }
    /// After a drop, how long the card says it is checking before it settles.
    static let checkWindow: TimeInterval = 6
}

/// Quick and calm; a plain fade when the operator asks for less motion.
private func askMotion(_ reduce: Bool) -> Animation {
    reduce ? .easeInOut(duration: 0.12) : .snappy(duration: 0.24, extraBounce: 0.04)
}

@MainActor
private final class ActionOperatorAskViewModel: ObservableObject {
    let request: ActionOperatorAskRequest
    @Published var state: ActionOperatorAskState
    /// The row whose list the operator opened last; it stays marked as current.
    @Published var activeItem: String?
    /// From a drop of the subject until a row turns granted or the window passes.
    @Published private(set) var checkingSince: Date?
    private var grantedAtDrop: Set<String> = []
    var onStep: ((ActionOperatorAskStep) -> Void)?
    var onDone: (() -> Void)?
    var onDecline: (() -> Void)?
    var onDrag: (() -> Void)?

    init(request: ActionOperatorAskRequest) {
        self.request = request
        state = ActionOperatorAskState(request: request)
    }

    var linkedSteps: Set<String> { Set(request.items.compactMap(\.step)) }
    var footerSteps: [ActionOperatorAskStep] { request.steps.filter { !linkedSteps.contains($0.id) } }

    func step(_ id: String?) -> ActionOperatorAskStep? {
        id.flatMap { id in request.steps.first { $0.id == id } }
    }

    /// The single accented row control: the current row if it is still
    /// missing, otherwise the first missing row that has a step.
    var primaryItem: String? {
        let missing = state.items.filter { $0.state != .granted && $0.step != nil }
        if let activeItem, missing.contains(where: { $0.id == activeItem }) { return activeItem }
        return missing.first?.id
    }

    /// Done takes the accent when nothing on a row is left to press.
    var doneIsPrimary: Bool { state.allGranted || primaryItem == nil }

    var isChecking: Bool { checkingSince != nil }

    /// The row a drop most likely fed: the current one, else the first missing.
    var checkingItem: String? {
        guard isChecking else { return nil }
        let missing = state.items.filter { $0.state != .granted }
        if let activeItem, missing.contains(where: { $0.id == activeItem }) { return activeItem }
        return missing.first?.id
    }

    private var granted: Set<String> {
        Set(state.items.filter { $0.state == .granted }.map(\.id))
    }

    func subjectDropped(now: Date = Date()) {
        grantedAtDrop = granted
        checkingSince = now
        onDrag?()
    }

    /// Checking ends quietly: on a new grant, on success, or when the window
    /// passes with nothing changed. The verifier decides; this only displays.
    func settleChecking(now: Date) {
        guard let since = checkingSince else { return }
        if !granted.subtracting(grantedAtDrop).isEmpty || state.isShowingSuccess
            || now.timeIntervalSince(since) >= AskMetrics.checkWindow {
            checkingSince = nil
        }
    }
}

private struct ActionOperatorAskView: View {
    @ObservedObject var model: ActionOperatorAskViewModel
    @ObservedObject private var theme = ActionThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AskMetrics.lead)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if let subject = model.request.subject {
                ActionOperatorAskSubjectCard(
                    subject: subject,
                    checking: model.isChecking,
                    enabled: !model.state.isShowingSuccess,
                    onDrop: { model.subjectDropped() }
                )
                .padding(.horizontal, AskMetrics.gutter)
                .padding(.bottom, model.state.items.isEmpty ? AskMetrics.gutter : 4)
            }

            if !model.state.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.state.items, id: \.id) { item in row(item) }
                }
                .padding(.horizontal, AskMetrics.gutter)
                .padding(.bottom, AskMetrics.gutter)
            }

            // "All set" belongs to the footer's success mark, not a second line.
            if let detail = model.state.detail, !detail.isEmpty, !model.state.isShowingSuccess {
                Text(detail)
                    .font(ActionType.uiCaption)
                    .foregroundStyle(StageHUDTheme.hudMuted)
                    .padding(.horizontal, AskMetrics.lead)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Rectangle().fill(StageHUDTheme.hudStroke).frame(height: StageHUDTheme.hairline)

            footer
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: AskMetrics.width, alignment: .leading)
        .background(StageHUDTheme.hudCanvas)
        .animation(askMotion(reduceMotion), value: model.state)
        .animation(askMotion(reduceMotion), value: model.isChecking)
        .animation(askMotion(reduceMotion), value: model.activeItem)
        .preferredColorScheme(.dark)
        .onChange(of: model.state.isShowingSuccess) { _, success in
            if success { AccessibilityNotification.Announcement("All set").post() }
        }
        .id(theme.revision)
    }

    // Who is asking comes first: Action, on behalf of the agent.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text("ACTION")
                    .foregroundStyle(StageHUDTheme.hudPaper)
                if !requester.isEmpty {
                    Text("·").foregroundStyle(StageHUDTheme.hudMuted)
                    Text(requester.uppercased())
                        .foregroundStyle(StageHUDTheme.hudMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(ActionType.label)
            .tracking(ActionType.labelTracking)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(requester.isEmpty ? "Action" : "Action, for \(requester)")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
            .overlay(alignment: .trailing) {
                Button { model.onDecline?() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(ActionOperatorAskCloseStyle())
                .help("Close")
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.request.title)
                    .font(ActionType.uiSubhead)
                    .foregroundStyle(StageHUDTheme.hudPaper)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !model.request.why.isEmpty {
                    Text(model.request.why)
                        .font(ActionType.uiBody)
                        .foregroundStyle(StageHUDTheme.hudMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var requester: String {
        [model.request.requester.agent, model.request.requester.task]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func row(_ item: ActionOperatorAskItem) -> some View {
        let granted = item.state == .granted
        let current = item.id == model.activeItem && !granted
        let checking = item.id == model.checkingItem
        return HStack(spacing: 10) {
            ZStack {
                if checking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .transition(.opacity)
                } else {
                    Image(systemName: glyph(for: item.state))
                        .font(ActionIcon.large)
                        .foregroundStyle(granted ? StageHUDTheme.hudCoral : StageHUDTheme.hudMuted)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: granted)
                        .transition(.opacity)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(item.label)
                .font(ActionType.uiRow)
                .foregroundStyle(granted ? StageHUDTheme.hudMuted : StageHUDTheme.hudPaper)
            Spacer(minLength: 8)
            if !granted, let step = model.step(item.step) {
                Button(step.label) {
                    model.activeItem = item.id
                    model.onStep?(step)
                }
                .buttonStyle(ActionOperatorAskButtonStyle(primary: model.primaryItem == item.id))
                .disabled(model.state.isShowingSuccess)
                .accessibilityLabel("\(step.label) for \(item.label)")
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            }
        }
        .padding(.leading, AskMetrics.inset)
        .padding(.trailing, AskMetrics.buttonInset)
        .frame(height: AskMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: AskMetrics.rowRadius, style: .continuous)
                .fill(current ? StageHUDTheme.hudPanel : .clear)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label): \(checking ? "checking" : granted ? "on" : item.state.rawValue)")
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if model.state.isShowingSuccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(ActionIcon.large)
                        .foregroundStyle(StageHUDTheme.hudCoral)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    Text("All set")
                        .font(ActionType.uiBodyStrong)
                        .foregroundStyle(StageHUDTheme.hudPaper)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("All set")
                .transition(.opacity.combined(with: .offset(y: 4)))
                Spacer(minLength: 0)
            } else {
                ForEach(model.footerSteps, id: \.id) { step in
                    Button(step.label) { model.onStep?(step) }
                        .buttonStyle(ActionOperatorAskLinkStyle())
                        .accessibilityLabel(step.label)
                }
                Spacer(minLength: 8)
                // Under verify, Done replaces Not now once every row is on:
                // both close safely, and one exit reads cleaner than two.
                if !(model.state.offersDone && !model.state.allowsDone) {
                    Button("Not now") { model.onDecline?() }
                        .buttonStyle(ActionOperatorAskLinkStyle())
                        .accessibilityLabel("Not now")
                }
                if model.state.offersDone {
                    Button("Done") { model.onDone?() }
                        .buttonStyle(ActionOperatorAskButtonStyle(primary: model.doneIsPrimary))
                        .accessibilityLabel("Done")
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                }
            }
        }
        .frame(minHeight: AskMetrics.buttonHeight)
        // The Done button's corner is concentric with the panel's.
        .padding(.leading, AskMetrics.lead)
        .padding(.trailing, AskMetrics.gutter + AskMetrics.buttonInset)
        .padding(.vertical, AskMetrics.gutter + AskMetrics.buttonInset)
    }

    private func glyph(for state: ActionOperatorAskItemState) -> String {
        switch state {
        case .missing: "circle"
        case .granted: "checkmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }
}

/// A full-height action. Primary is the panel's one coral control.
private struct ActionOperatorAskButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        ActionOperatorAskButton(configuration: configuration, primary: primary)
    }
}

private struct ActionOperatorAskButton: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AskMetrics.buttonRadius, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .font(ActionType.uiBodyStrong)
            .foregroundStyle(primary ? StageHUDTheme.hudInk : StageHUDTheme.hudPaper)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minWidth: 76, minHeight: AskMetrics.buttonHeight)
            .background {
                // The Stage HUD's hardware finish: a fill, a bevel from a lit
                // top edge to a shaded foot, and a one-point highlight line.
                shape.fill(fill)
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [
                                StageHUDTheme.hudBevelLight.opacity(primary ? 0.9 : 1),
                                .clear,
                                StageHUDTheme.hudBevelShadow.opacity(pressed ? 0.25 : 0.55),
                            ],
                            startPoint: .top, endPoint: .bottom))
                        .blendMode(pressed ? .plusDarker : .normal)
                    }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(StageHUDTheme.hudPaper.opacity(pressed ? 0.06 : (primary ? 0.32 : 0.16)))
                    .frame(height: 1)
                    .padding(.horizontal, AskMetrics.buttonRadius)
            }
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: shadow, radius: pressed ? 1 : 4, y: pressed ? 0 : 2)
            .offset(y: pressed && !reduceMotion ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovering = $0 && isEnabled }
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var shadow: Color {
        primary ? StageHUDTheme.hudCoral.opacity(hovering ? 0.28 : 0.18) : StageHUDTheme.hudShadow.opacity(0.32)
    }

    private var fill: Color {
        if primary {
            if configuration.isPressed { return StageHUDTheme.hudCoral.opacity(0.8) }
            return hovering ? StageHUDTheme.hudCoralHot : StageHUDTheme.hudCoral
        }
        if configuration.isPressed { return StageHUDTheme.hudMetalTrough }
        return hovering ? StageHUDTheme.hudPanelRaised : StageHUDTheme.hudMetalTop
    }

    private var stroke: Color {
        if primary { return StageHUDTheme.hudCoralHot.opacity(0.6) }
        return hovering ? StageHUDTheme.hudPaper.opacity(0.28) : StageHUDTheme.hudStrokeStrong
    }
}

/// The header's close X: a small metal disc that brightens on hover.
private struct ActionOperatorAskCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionOperatorAskClose(configuration: configuration)
    }
}

private struct ActionOperatorAskClose: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? StageHUDTheme.hudPaper : StageHUDTheme.hudMuted)
            .frame(width: 22, height: 22)
            .background(Circle().fill(configuration.isPressed ? StageHUDTheme.hudMetalTrough
                : (hovering ? StageHUDTheme.hudPanelRaised : StageHUDTheme.hudMetalTop)))
            .overlay(Circle().strokeBorder(hovering ? StageHUDTheme.hudPaper.opacity(0.28) : StageHUDTheme.hudStroke, lineWidth: 1))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet text action for the footer; it brightens on hover.
private struct ActionOperatorAskLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionOperatorAskLink(configuration: configuration)
    }
}

private struct ActionOperatorAskLink: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(ActionType.uiBody)
            .foregroundStyle(hovering && isEnabled ? StageHUDTheme.hudPaper : StageHUDTheme.hudMuted)
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
            .frame(minHeight: AskMetrics.buttonHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private enum ActionOperatorAskDragPhase: Equatable {
    case idle, hover, pressed, dragging
}

/// The app the operator is granting, as a real file they can drag into a
/// System Settings list. The whole card is the grab target.
private struct ActionOperatorAskSubjectCard: View {
    let subject: ActionOperatorAskSubject
    let checking: Bool
    let enabled: Bool
    let onDrop: () -> Void
    @State private var phase: ActionOperatorAskDragPhase = .idle
    @State private var icon: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(subject: ActionOperatorAskSubject, checking: Bool, enabled: Bool, onDrop: @escaping () -> Void) {
        self.subject = subject
        self.checking = checking
        self.enabled = enabled
        self.onDrop = onDrop
        _icon = State(initialValue: NSWorkspace.shared.icon(forFile: subject.path))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AskMetrics.rowRadius, style: .continuous)
        HStack(spacing: 14) {
            iconWell
            VStack(alignment: .leading, spacing: 3) {
                Text(subject.name)
                    .font(ActionType.uiBodyStrong)
                    .foregroundStyle(StageHUDTheme.hudPaper)
                    .lineLimit(1)
                Text(caption)
                    .font(ActionType.uiCaption)
                    .foregroundStyle(StageHUDTheme.hudMuted)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            ZStack {
                if checking {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else {
                    Image(systemName: phase == .pressed || phase == .dragging ? "hand.raised.fill" : "hand.draw")
                        .font(ActionIcon.large)
                        .foregroundStyle(phase == .idle ? StageHUDTheme.hudMuted : StageHUDTheme.hudPaper)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity)
                }
            }
            .frame(width: 24, height: 24)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, AskMetrics.inset)
        .frame(height: AskMetrics.cardHeight)
        .background(shape.fill(phase == .hover || phase == .pressed ? StageHUDTheme.hudPanelRaised : StageHUDTheme.hudPanel))
        .overlay(shape.strokeBorder(border, style: StrokeStyle(lineWidth: StageHUDTheme.hairline, dash: [4, 3])))
        .overlay(
            ActionOperatorAskDragSource(
                url: URL(fileURLWithPath: subject.path),
                icon: icon,
                enabled: enabled,
                onPhase: { phase = $0 },
                onDrop: onDrop
            )
        )
        .opacity(enabled ? 1 : 0.6)
        .animation(askMotion(reduceMotion), value: phase)
        .animation(askMotion(reduceMotion), value: checking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.name)
        .accessibilityValue(checking ? "Checking" : "")
        .accessibilityHint("Drag into the System Settings list")
    }

    // The icon lifts on hover, sinks on press and leaves a socket while it is
    // in the operator's hand.
    private var iconWell: some View {
        let lift: CGFloat = reduceMotion ? 1 : (phase == .hover ? 1.04 : phase == .pressed ? 0.95 : 1)
        return ZStack {
            RoundedRectangle(cornerRadius: AskMetrics.buttonRadius + 4, style: .continuous)
                .strokeBorder(StageHUDTheme.hudCoral.opacity(0.7),
                              style: StrokeStyle(lineWidth: StageHUDTheme.hairline, dash: [3, 3]))
                .opacity(phase == .dragging ? 1 : 0)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: AskMetrics.icon, height: AskMetrics.icon)
                .opacity(phase == .dragging ? 0.22 : 1)
                .scaleEffect(lift)
                .shadow(color: StageHUDTheme.hudShadow.opacity(phase == .hover ? 0.55 : 0.3),
                        radius: phase == .hover ? 6 : 3, y: phase == .hover ? 3 : 1)
        }
        .frame(width: AskMetrics.icon, height: AskMetrics.icon)
        .accessibilityHidden(true)
    }

    private var caption: String {
        if phase == .dragging { return "Drop it on the list" }
        if checking { return "Checking…" }
        return "Not listed? Drag it in."
    }

    private var border: Color {
        switch phase {
        case .dragging: StageHUDTheme.hudCoral.opacity(0.7)
        case .hover, .pressed: StageHUDTheme.hudStrokeStrong
        case .idle: checking ? StageHUDTheme.hudStrokeStrong : StageHUDTheme.hudStroke
        }
    }
}

private struct ActionOperatorAskDragSource: NSViewRepresentable {
    let url: URL
    let icon: NSImage
    let enabled: Bool
    let onPhase: (ActionOperatorAskDragPhase) -> Void
    let onDrop: () -> Void

    func makeNSView(context: Context) -> ActionOperatorAskDragView {
        ActionOperatorAskDragView(url: url, icon: icon, onPhase: onPhase, onDrop: onDrop)
    }

    func updateNSView(_ view: ActionOperatorAskDragView, context: Context) {
        view.onPhase = onPhase
        view.onDrop = onDrop
        view.isEnabled = enabled
    }
}

/// System Settings accepts an app only as an NSURL file drag (the same
/// payload Finder writes), so this is AppKit rather than SwiftUI `.onDrag`.
/// It draws nothing; the card beneath draws every phase it reports.
private final class ActionOperatorAskDragView: NSView, NSDraggingSource {
    let url: URL
    private let icon: NSImage
    var onPhase: (ActionOperatorAskDragPhase) -> Void
    var onDrop: () -> Void
    var isEnabled = true {
        didSet { if !isEnabled { hovering = false; pressed = false } }
    }
    private var start: NSPoint?
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { report() } }
    private var pressed = false { didSet { report() } }
    private var dragging = false { didSet { report() } }
    private var reported: ActionOperatorAskDragPhase = .idle

    init(url: URL, icon: NSImage, onPhase: @escaping (ActionOperatorAskDragPhase) -> Void, onDrop: @escaping () -> Void) {
        self.url = url
        self.icon = icon
        self.onPhase = onPhase
        self.onDrop = onDrop
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled && frame.contains(point) ? self : nil
    }

    /// Where the card draws the icon: leading inset, vertically centred.
    private var iconRect: NSRect {
        NSRect(x: AskMetrics.inset, y: (bounds.height - AskMetrics.icon) / 2,
               width: AskMetrics.icon, height: AskMetrics.icon)
    }

    private func report() {
        let phase: ActionOperatorAskDragPhase = dragging ? .dragging : pressed ? .pressed : hovering ? .hover : .idle
        guard phase != reported else { return }
        reported = phase
        onPhase(phase)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // activeAlways: the panel is non-activating and usually not key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: pressed ? .closedHand : .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !pressed && !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        start = convert(event.locationInWindow, from: nil)
        pressed = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        self.start = nil
        if let panel = window as? ActionOperatorAskPanel {
            panel.allowsKeyForDrag = true
            panel.makeKey()
        }
        let (image, frame) = liftedDragImage()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(frame, contents: image)
        pressed = false
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        pressed = false
        if hovering { NSCursor.openHand.set() }
    }

    /// The icon slightly larger and on a soft shadow, so it reads as lifted.
    private func liftedDragImage() -> (NSImage, NSRect) {
        let pad: CGFloat = 12
        let side = AskMetrics.icon * 1.06
        let size = NSSize(width: side + pad * 2, height: side + pad * 2)
        let shadowColor = NSColor(StageHUDTheme.hudShadow).withAlphaComponent(0.45)
        let icon = icon
        let image = NSImage(size: size, flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = 9
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            icon.draw(in: NSRect(x: pad, y: pad, width: side, height: side))
            return true
        }
        let rect = iconRect
        let frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                           width: size.width, height: size.height)
        return (image, frame)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Released over the panel itself: nothing could have been added.
        let backOnPanel = window?.frame.contains(screenPoint) ?? false
        if let panel = window as? ActionOperatorAskPanel {
            panel.allowsKeyForDrag = false
            panel.resignKey()
        }
        dragging = false
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        if !backOnPanel { onDrop() }
    }
}

@MainActor
final class ActionOperatorAskController: NSObject, NSWindowDelegate, NSApplicationDelegate {
    private let model: ActionOperatorAskViewModel
    private let controlURL: URL
    private let eventsURL: URL
    private let writer: ResponseWriter
    private var panel: ActionOperatorAskPanel?
    private var hostingView: ActionOperatorAskHostingView?
    private var scrollView: NSScrollView?
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var didReply = false
    private var exitCode: Int32 = 0
    private var physicalDisplayID: CGDirectDisplayID?

    init(options: CommandOptions) throws {
        let requestURL = URL(fileURLWithPath: try options.required("request"))
        controlURL = URL(fileURLWithPath: try options.required("control-file"))
        eventsURL = URL(fileURLWithPath: try options.required("events-file"))
        writer = ResponseWriter(replyFile: try options.required("reply-file"))
        model = ActionOperatorAskViewModel(request: try ActionOperatorAskRequest.parse(Data(contentsOf: requestURL)))
        super.init()
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        model.onStep = { [weak self] step in self?.perform(step) }
        model.onDone = { [weak self] in self?.resolve { $0.done() } }
        model.onDecline = { [weak self] in self?.decline() }
        model.onDrag = { [weak self] in self?.tick() }

        // An expired or withdrawn request never flashes a panel on screen.
        tick()
        guard !didReply else {
            if exitCode != 0 { Darwin.exit(exitCode) }
            return
        }
        try createPanel()
        installEscapeMonitors()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        app.run()
        if !didReply { decline() }
        if exitCode != 0 { Darwin.exit(exitCode) }
    }

    private func createPanel() throws {
        guard let screen = operatorScreen else {
            throw ActionHostError.unsupportedOS("The operator panel requires a physical main display")
        }
        let panel = ActionOperatorAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: AskMetrics.width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = model.request.title
        panel.level = actionHUDPanelLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.decline() }
        let host = ActionOperatorAskHostingView(rootView: ActionOperatorAskView(model: model))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = AskMetrics.panelRadius
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(StageHUDTheme.hudStrokeStrong).cgColor
        scroll.documentView = host
        panel.contentView = scroll
        self.panel = panel
        hostingView = host
        scrollView = scroll
        resizePanel(on: screen)
        panel.orderFrontRegardless()
    }

    private var operatorScreen: NSScreen? {
        // `main` follows the key window; `screens.first` owns the menu bar.
        guard let screen = NSScreen.screens.first,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              !ActionAgentLayerDisplay.isAgentLayer(id) else { return nil }
        guard physicalDisplayID == id || isPhysicalDisplay(id) else { return nil }
        physicalDisplayID = id
        return screen
    }

    private func isPhysicalDisplay(_ id: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(id) != 0 { return true }
        // The same hardware registry sources used by Lattices MonitorIdentity.
        // An unrecognised display is not a safe destination for an operator ask.
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        var matches: Set<UInt64> = []
        for name in ["AppleCLCD2", "IOMobileFramebufferShim"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                    let identity = attributes["ProductAttributes"] as? [String: Any],
                    (identity["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
                    (identity["ProductID"] as? NSNumber)?.uint32Value == product else { continue }
                if serial != 0 && (identity["SerialNumber"] as? NSNumber)?.uint32Value != serial { continue }
                var entryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS { matches.insert(entryID) }
            }
        }
        return matches.count == 1
    }

    private func resizePanel(on screen: NSScreen) {
        guard let panel, let hostingView, let scrollView else { return }
        let contentSize = hostingView.fittingSize
        let visible = screen.visibleFrame
        let height = min(contentSize.height, max(1, visible.height - 32))
        hostingView.frame = NSRect(x: 0, y: 0, width: AskMetrics.width, height: contentSize.height)
        var frame = NSRect(x: visible.maxX - AskMetrics.width - 16, y: visible.maxY - height - 16, width: AskMetrics.width, height: height)
        // Beside System Settings when it is open on this display, so the
        // subject's drag into the list is short and the two read as one task.
        if let settings = systemSettingsFrame(on: screen) {
            let top = min(settings.maxY, visible.maxY - 16)
            let y = max(visible.minY + 16, top - height)
            if settings.maxX + 12 + AskMetrics.width <= visible.maxX - 16 {
                frame.origin = NSPoint(x: settings.maxX + 12, y: y)
            } else if settings.minX - 12 - AskMetrics.width >= visible.minX + 16 {
                frame.origin = NSPoint(x: settings.minX - 12 - AskMetrics.width, y: y)
            }
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        scrollView.frame = NSRect(x: 0, y: 0, width: AskMetrics.width, height: height)
    }

    /// System Settings' largest on-screen window, in AppKit coordinates.
    /// Owner and bounds need no Screen Recording grant.
    private func systemSettingsFrame(on screen: NSScreen) -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]], let primary = NSScreen.screens.first else { return nil }
        let frames = windows.compactMap { info -> NSRect? in
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 200, rect.height > 200 else { return nil }
            let frame = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            return screen.frame.intersects(frame) ? frame : nil
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }

    private func tick() {
        guard !didReply else { return }
        resolve { state in
            let now = Date()
            state.expireIfNeeded(now: now)
            state.applyControl(data: try? Data(contentsOf: controlURL), now: now)
            state.finishSatisfaction(now: now)
        }
        model.settleChecking(now: Date())
        guard !didReply, panel != nil else { return }
        guard let screen = operatorScreen else {
            finish(.error(detail: "The operator panel requires a physical main display"))
            return
        }
        resizePanel(on: screen)
    }

    private func resolve(_ update: (inout ActionOperatorAskState) -> Void) {
        guard !didReply else { return }
        var state = model.state
        state.expireIfNeeded(now: Date())
        update(&state)
        if state != model.state { model.state = state }
        if let outcome = state.outcome {
            finish(.answered(outcome: outcome, detail: state.detail ?? outcome.rawValue))
        }
    }

    private func decline() {
        resolve { $0.decline() }
    }

    private func perform(_ step: ActionOperatorAskStep) {
        tick()
        guard !didReply, !model.state.isShowingSuccess else { return }
        do {
            // A failed audit append prevents the local action from running unreported.
            try appendEvent(step: step.id)
            switch step.action {
            case .openSettings(let pane):
                openSettings(pane.url)
            case .reveal(let path):
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case .openApp(let bundleId, let path):
                let url = path.map { URL(fileURLWithPath: $0) }
                    ?? bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                guard let url else {
                    throw ActionHostError.applicationNotRunning(bundleId ?? path ?? "")
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                    let detail = error?.localizedDescription
                    Task { @MainActor in
                        if let detail { self?.finish(.error(detail: detail)) }
                    }
                }
            case .openURL(let url):
                try open(url)
            case .agent:
                break
            }
        } catch {
            finish(.error(detail: error.localizedDescription))
        }
    }

    /// An open System Settings ignores a URL for another Privacy list, so it is
    /// relaunched onto the list the operator asked for.
    private func openSettings(_ url: URL) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        guard !running.isEmpty else {
            if !NSWorkspace.shared.open(url) { finish(.error(detail: "Could not open \(url.absoluteString)")) }
            return
        }
        running.forEach { $0.terminate() }
        Task { @MainActor [weak self] in
            for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !self.didReply else { return }
            if !NSWorkspace.shared.open(url) { self.finish(.error(detail: "Could not open \(url.absoluteString)")) }
        }
    }

    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ActionHostError.unsupportedOS("Could not open \(url.absoluteString)")
        }
    }

    private func appendEvent(step: String) throws {
        struct Event: Encodable { let at: String; let step: String }
        var data = try JSONEncoder().encode(Event(at: ISO8601DateFormatter().string(from: Date()), step: step))
        data.append(0x0a)
        try FileManager.default.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(eventsURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        // O_APPEND + one write keeps the JSON and newline together for the reader.
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func installEscapeMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.decline() }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.decline() }
        }
    }

    private func finish(_ reply: ActionOperatorAskReply) {
        guard !didReply else { return }
        didReply = true
        if reply.status == .error { exitCode = 1 }
        timer?.invalidate()
        timer = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        do {
            try writer.write(reply)
        } catch {
            exitCode = 1
            FileHandle.standardError.write(Data("ActionHost reply failed: \(error.localizedDescription)\n".utf8))
        }
        panel?.orderOut(nil)
        NSApplication.shared.stop(nil)
        // Wake run() when completion came from a timer or a global monitor.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }

    func windowWillClose(_ notification: Notification) { decline() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        decline()
        return .terminateNow
    }
}
