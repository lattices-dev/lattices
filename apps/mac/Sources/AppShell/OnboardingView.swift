import SwiftUI
import AppKit

// MARK: - Onboarding Flow

/// The first-run welcome: show what Lattices does with windows, let the user
/// place one on a practice board, then hand them the one shortcut to keep.
/// Permissions stay optional and are only requested from a button the user
/// presses; a passive check reads their state without prompting.
struct OnboardingView: View {
    @ObservedObject private var permChecker = PermissionChecker.shared
    @ObservedObject private var hotkeys = HotkeyStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    @State private var practice: TilePosition = .center
    @State private var practiceMoves = 0
    @FocusState private var boardFocused: Bool
    var onComplete: (FinishAction) -> Void

    enum Step: Int, CaseIterable {
        case see
        case tryIt
        case ready
    }

    enum FinishAction {
        case home
        case commandBar
    }

    static let coral = Color(red: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255)

    init(step: Step = .see, onComplete: @escaping (FinishAction) -> Void) {
        _step = State(initialValue: step)
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 22)

            Group {
                switch step {
                case .see:   seeStep
                case .tryIt: tryStep
                case .ready: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .transition(.opacity)

            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 22)
        }
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .background(Palette.bg)
        .preferredColorScheme(.dark)
        .onAppear { PermissionChecker.shared.check() }
        // Coming back from System Settings: read the grant once, no polling.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            PermissionChecker.shared.check()
        }
        .onChange(of: step) { _, newStep in
            if newStep == .tryIt { boardFocused = true }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s == step ? Self.coral : (s.rawValue < step.rawValue ? Palette.textMuted : Palette.borderLit))
                        .frame(width: s == step ? 18 : 8, height: 3)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Text(stepName)
                .font(Typo.mono(10))
                .foregroundColor(Palette.textMuted)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var stepName: String {
        switch step {
        case .see:   return "Windows"
        case .tryIt: return "Try it"
        case .ready: return "Ready"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if step == .see {
                Button("Skip") { onComplete(.home) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textMuted)
                    .help("Skip the introduction")
            } else {
                Button { move(by: -1) } label: {
                    HStack(spacing: 6) {
                        Text("Back")
                        Keycap("esc", quiet: true)
                    }
                }
                .buttonStyle(.plain)
                .font(Typo.mono(11))
                .foregroundColor(Palette.textMuted)
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step == .ready {
                Button("Open command bar") { onComplete(.commandBar) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textDim)
            }
            Button {
                if step == .ready { onComplete(.home) } else { move(by: 1) }
            } label: {
                HStack(spacing: 6) {
                    Text(step == .ready ? "Start using Lattices" : "Continue")
                    Text("↩").opacity(0.6)
                }
                .angularButton(step == .ready ? Self.coral : .white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Steps

    private var seeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your windows, on a grid")
                .font(Typo.title(20))
                .foregroundColor(Palette.text)
            Text("Lattices places, finds and switches windows from the keyboard. It runs on this Mac and stays out of the way.")
                .font(Typo.body(12.5))
                .foregroundColor(Palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            DeskDemo(animated: !reduceMotion)
                .frame(height: 190)
                .padding(.top, 4)

            HStack(spacing: 8) {
                featureChip("Place", .tileLeft)
                featureChip("Find", .commandBar)
                featureChip("Layers", .layer1)
            }
        }
    }

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Place a window")
                .font(Typo.title(20))
                .foregroundColor(Palette.text)
            practiceInstructions

            PracticeBoard(position: practice, focused: boardFocused, animated: !reduceMotion)
                .frame(height: 170)
                .focusable()
                .focusEffectDisabled()
                .focused($boardFocused)
                .onKeyPress(phases: .down) { press in
                    guard let target = OnboardingPractice.position(for: press.key) else { return .ignored }
                    place(target)
                    return .handled
                }
                .onTapGesture { boardFocused = true }
                .accessibilityElement()
                .accessibilityLabel("Practice board")
                .accessibilityValue(practice.label)
                .accessibilityHint("Use the arrow keys or C to place the window")
                .accessibilityActions {
                    ForEach(OnboardingPractice.positions, id: \.self) { pos in
                        Button(pos.label) { place(pos) }
                    }
                }
                .onAppear { boardFocused = true }

            tilingStatus
        }
    }

    private var practiceInstructions: some View {
        let lead = practiceMoves == 0 ? "Press the arrow keys, or C to center." : "That's the move."
        return Text("\(lead) \(OnboardingPractice.realWorldHint(bindings: hotkeys.bindings))")
        .font(Typo.body(12.5))
        .foregroundColor(Palette.textDim)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var tilingStatus: some View {
        let granted = permChecker.isGranted(.windowControl)
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark" : Capability.windowControl.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(granted ? Palette.textDim : Self.coral)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(granted ? "Tiling is on" : "Tiling other apps needs Accessibility")
                    .font(Typo.monoBold(11))
                    .foregroundColor(Palette.text)
                Text(granted ? tilingTryLine : "Optional. Turn it on when you're ready; nothing is recorded.")
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
            }
            Spacer(minLength: 0)
            if !granted {
                Button("Turn on…") {
                    PermissionsAssistantWindowController.shared.show(focus: .windowControl)
                }
                .buttonStyle(.plain)
                .font(Typo.monoBold(10))
                .foregroundColor(Self.coral)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().strokeBorder(Self.coral.opacity(0.5), lineWidth: 0.5))
            }
        }
        .padding(10)
        .glassCard()
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One shortcut to keep")
                .font(Typo.title(20))
                .foregroundColor(Palette.text)
            Text("The command bar searches your windows, runs commands and switches layers. Everything else is in it.")
                .font(Typo.body(12.5))
                .foregroundColor(Palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let keys = chordKeys(.commandBar) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Keycap(key, size: 15)
                    }
                } else {
                    Text("No shortcut assigned")
                        .font(Typo.monoBold(12))
                        .foregroundColor(Palette.textDim)
                }
                Text("command bar")
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.textMuted)
                    .padding(.leading, 6)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .glassCard()

            Text("Optional")
                .font(Typo.mono(10))
                .foregroundColor(Palette.textMuted)
                .padding(.top, 4)
            VStack(spacing: 6) {
                ForEach(Capability.available.filter { $0 != .windowControl }) { cap in
                    capabilityRow(cap)
                }
            }
        }
    }

    // MARK: - Shared helpers

    /// One action and its live binding, or "unassigned" when the user cleared it.
    private func featureChip(_ label: String, _ action: HotkeyAction) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typo.mono(10))
                .foregroundColor(Palette.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let keys = chordKeys(action) {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Keycap(key, quiet: true)
                    }
                }
                .fixedSize()
            } else {
                Text("unassigned")
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .glassCard()
        .accessibilityElement(children: .combine)
        .help(action.label)
    }

    private func capabilityRow(_ cap: Capability) -> some View {
        let granted = permChecker.isGranted(cap)
        return HStack(spacing: 10) {
            Image(systemName: cap.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.textDim)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(cap.title)
                    .font(Typo.monoBold(11))
                    .foregroundColor(Palette.text)
                Text(cap.pitch)
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("On")
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textDim)
            } else {
                Button("Set up") {
                    PermissionsAssistantWindowController.shared.show(focus: cap)
                }
                .buttonStyle(.plain)
                .font(Typo.monoBold(10))
                .foregroundColor(Palette.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().strokeBorder(Palette.borderLit, lineWidth: 0.5))
                .accessibilityLabel("Set up \(cap.title)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard()
    }

    private func chordKeys(_ action: HotkeyAction) -> [String]? {
        OnboardingPractice.keycaps(for: hotkeys.bindings[action])
    }

    private var tilingTryLine: String {
        guard let keys = chordKeys(.tileLeft) else { return "Give Tile Left a shortcut in Settings to use it anywhere." }
        return "Try \(keys.joined()) in another app."
    }

    private func place(_ position: TilePosition) {
        if reduceMotion {
            practice = position
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { practice = position }
        }
        practiceMoves += 1
    }

    private func move(by delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        if reduceMotion {
            step = next
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { step = next }
        }
    }
}

// MARK: - Practice mapping

enum OnboardingPractice {
    static let positions: [TilePosition] = [.left, .right, .top, .bottom, .center]

    /// The practice board mirrors the real placement keys without their
    /// modifiers, so global hotkeys never fire while the user experiments.
    /// Keycaps for a live binding: modifiers, then key. `HotkeyStore.bindings`
    /// already merges defaults, so a missing entry means the user cleared it;
    /// never fall back to the default here.
    static func keycaps(for binding: KeyBinding?) -> [String]? {
        guard let binding, let key = binding.displayParts.last else { return nil }
        let symbols = ["Ctrl": "⌃", "Option": "⌥", "Shift": "⇧", "Cmd": "⌘", "Return": "↩"]
        let modifiers = binding.displayParts.dropLast().map { symbols[$0] ?? $0 }.joined()
        return [modifiers, symbols[key] ?? key].filter { !$0.isEmpty }
    }

    /// One real example, Tile Left, with whatever binding it has now. Other
    /// arrows may be remapped separately, so no shared modifier is implied.
    static func realWorldHint(bindings: [HotkeyAction: KeyBinding]) -> String {
        guard let keys = keycaps(for: bindings[.tileLeft]) else {
            return "Tile Left has no shortcut right now; assign one in Settings to place windows from any app."
        }
        return "In any app, \(keys.joined()) sends the window you're in to the left half."
    }

    /// Where the sample window sits on a board of `size`, inset 2pt from its tile.
    static func windowFrame(for position: TilePosition, in size: CGSize) -> CGRect {
        let (x, y, w, h) = position.rect
        return CGRect(x: size.width * x, y: size.height * y, width: size.width * w, height: size.height * h)
            .insetBy(dx: 2, dy: 2)
    }

    static func position(for key: KeyEquivalent) -> TilePosition? {
        switch key {
        case .leftArrow:  return .left
        case .rightArrow: return .right
        case .upArrow:    return .top
        case .downArrow:  return .bottom
        case "c", "C":    return .center
        default:          return nil
        }
    }
}

// MARK: - Pieces

private struct Keycap: View {
    let text: String
    var size: CGFloat = 10
    var quiet = false

    init(_ text: String, size: CGFloat = 10, quiet: Bool = false) {
        self.text = text
        self.size = size
        self.quiet = quiet
    }

    var body: some View {
        Text(text)
            .font(Typo.monoBold(size))
            .foregroundColor(quiet ? Palette.textDim : Palette.text)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(quiet ? 0.04 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Palette.borderLit, lineWidth: 0.5)
                    )
            )
    }
}

/// A drawn window: title bar dots, a label, a few content lines. Shapes, not
/// screenshots.
private struct MiniWindow: View {
    let title: String
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 4, height: 4)
                }
                Text(title)
                    .font(Typo.mono(8))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                    .padding(.leading, 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 13)
            .background(Color.white.opacity(0.04))

            VStack(alignment: .leading, spacing: 4) {
                ForEach([0.7, 0.45, 0.6, 0.3], id: \.self) { w in
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: geo.size.width * w, height: 3)
                    }
                    .frame(height: 3)
                }
            }
            .padding(7)
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.13))
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(accent ?? Palette.borderLit, lineWidth: accent == nil ? 0.5 : 1.25)
        )
    }
}

private struct DisplayFrame<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            let inner = CGSize(width: geo.size.width - 12, height: geo.size.height - 12)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(red: 0.085, green: 0.105, blue: 0.15))
                // Faint grid: the lattice the windows land on.
                Path { p in
                    for i in 1..<4 {
                        let x = 6 + inner.width * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 6)); p.addLine(to: CGPoint(x: x, y: 6 + inner.height))
                    }
                    for i in 1..<2 {
                        let y = 6 + inner.height * CGFloat(i) / 2
                        p.move(to: CGPoint(x: 6, y: y)); p.addLine(to: CGPoint(x: 6 + inner.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                content(inner)
                    .offset(x: 6, y: 6)
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(highlighted ? OnboardingView.coral.opacity(0.55) : Palette.border, lineWidth: highlighted ? 1 : 0.5)
            }
        }
    }
}

/// Three windows drift between a pile and a tiled layout.
private struct DeskDemo: View {
    let animated: Bool
    @State private var tiled = true

    private struct Item {
        let title: String
        let loose: CGRect
        let placed: CGRect
    }

    private let items: [Item] = [
        Item(title: "tideline — editor",
             loose: CGRect(x: 0.18, y: 0.14, width: 0.5, height: 0.62),
             placed: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        Item(title: "server",
             loose: CGRect(x: 0.38, y: 0.3, width: 0.44, height: 0.55),
             placed: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        Item(title: "docs",
             loose: CGRect(x: 0.08, y: 0.4, width: 0.42, height: 0.5),
             placed: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
    ]

    var body: some View {
        DisplayFrame { size in
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let r = tiled ? item.placed : item.loose
                    MiniWindow(title: item.title, accent: index == 0 && tiled ? OnboardingView.coral : nil)
                        .frame(width: size.width * r.width - 4, height: size.height * r.height - 4)
                        .offset(x: size.width * r.minX + 2, y: size.height * r.minY + 2)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Three windows snapping into a tiled layout")
        .task(id: animated) {
            guard animated else { tiled = true; return }
            tiled = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { tiled = true }
                try? await Task.sleep(for: .milliseconds(2600))
                withAnimation(.easeInOut(duration: 0.45)) { tiled = false }
            }
        }
    }
}

/// One window the user moves with the arrow keys. A soft ghost of the window
/// next to it shows where the rest of the desk would go.
private struct PracticeBoard: View {
    let position: TilePosition
    let focused: Bool
    let animated: Bool

    var body: some View {
        DisplayFrame(highlighted: focused) { size in
            let frame = OnboardingPractice.windowFrame(for: position, in: size)
            let tile = frame.insetBy(dx: -2, dy: -2)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(OnboardingView.coral.opacity(0.08))
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY)
                MiniWindow(title: "tideline — editor", accent: OnboardingView.coral)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .overlay(alignment: .bottomTrailing) {
            Text(focused ? position.label : "Click to focus")
                .font(Typo.mono(9))
                .foregroundColor(Palette.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(10)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Window Controller

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private static let completedKey = "onboarding.completed"

    var isVisible: Bool { window?.isVisible ?? false }

    var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.completedKey)
    }

    /// Show the onboarding window if not yet completed.
    /// Returns true if onboarding was shown.
    @discardableResult
    func showIfNeeded() -> Bool {
        guard !hasCompleted else { return false }
        show()
        return true
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView { action in
            self.complete(then: action)
        }

        let w = AppWindowShell.makeWindow(
            config: .init(
                title: "Welcome to Lattices",
                initialSize: NSSize(width: 560, height: 520),
                minSize: NSSize(width: 540, height: 500)
            ),
            rootView: view
        )
        AppWindowShell.positionCentered(w)
        AppWindowShell.present(w)
        self.window = w
    }

    private func complete(then action: OnboardingView.FinishAction) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.orderOut(nil)
        window = nil
        switch action {
        case .home:
            ScreenMapWindowController.shared.showPage(.home)
        case .commandBar:
            UnifiedCommandBarWindow.shared.show()
        }
        AppDelegate.updateActivationPolicy()
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.completedKey)
    }
}
