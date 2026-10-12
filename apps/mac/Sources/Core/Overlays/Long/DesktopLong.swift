import AppKit
import SwiftUI

// MARK: - Model

/// What Long is doing. Moods follow the visiting cursor: connecting is work,
/// a visit is away (he goes and stands at the edge you left by), and a visit
/// that ends gets a nod, or a squint if it failed. Nothing polls.
@MainActor
final class DesktopLongModel: ObservableObject {
    @Published var mood: Long.Mood = .rest
    @Published var gaze: CGVector = .zero
    /// While visiting: the host's name, shown on a tag beside him.
    @Published var away: String?
    /// While visiting: the side of the screen the host is on.
    @Published var side: VisitTrust.Side?
    let size: CGFloat = 44
    private var settle: DispatchWorkItem?

    func flash(_ mood: Long.Mood, for seconds: TimeInterval) {
        settle?.cancel()
        self.mood = mood
        let back = DispatchWorkItem { [weak self] in
            guard let self, self.mood == mood else { return }
            self.mood = .rest
        }
        settle = back
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: back)
    }

    func visiting(_ status: VisitController.Status) {
        settle?.cancel()
        away = status.visiting
        side = status.side
        mood = status.ready ? .away : .work
        gaze = switch status.side {
        case .right: CGVector(dx: 4, dy: 0)
        case .left: CGVector(dx: -4, dy: 0)
        case .top: CGVector(dx: 0, dy: -4)
        case .bottom: CGVector(dx: 0, dy: 4)
        case nil: .zero
        }
    }

    func home() {
        away = nil
        side = nil
        gaze = .zero
    }
}

// MARK: - View

struct DesktopLongView: View {
    @ObservedObject var model: DesktopLongModel

    var body: some View {
        let long = VStack(spacing: 0) {
            Long(mood: model.mood, size: model.size, gaze: model.gaze)
            Ellipse().fill(Color.black.opacity(0.22))
                .frame(width: model.size * 0.62, height: max(3, model.size * 0.1)).blur(radius: 2.5)
                .offset(y: -model.size * 0.06)
        }
        Group {
            switch model.side {
            case .right: HStack(spacing: 6) { tag; long }
            case .left: HStack(spacing: 6) { long; tag }
            case .top: VStack(spacing: 4) { long; tag }
            case .bottom: VStack(spacing: 4) { tag; long }
            case nil: long
            }
        }
        .padding(6)
        .fixedSize()
    }

    @ViewBuilder private var tag: some View {
        if let name = model.away {
            Text(name)
                .font(Typo.monoBold(11))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(model.mood == .away ? Long.coral : Long.ink))
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// The threshold is in screen points; once crossed, returning to the grab
/// point is still a drag and must never open the card.
struct LongDragGesture {
    private(set) var moved = false
    mutating func update(dx: CGFloat, dy: CGFloat) -> Bool {
        moved = moved || hypot(dx, dy) >= 3
        return moved
    }
}

/// A drag moves him (his new home), a click opens his card, ⌥-click brings
/// the cursor home, right-click offers hiding him.
private final class LongHost: NSHostingView<DesktopLongView> {
    var onClick: (() -> Void)?
    var onHide: (() -> Void)?
    var onMoved: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if mods == .control { return rightMouseDown(with: event) }
        if mods == .option { PointerHome.bringHome(); return }
        guard let window else { return }
        // Track the drag here: performDrag returns before the window moves, so
        // every drag also read as a click and opened the card.
        let start = window.frame.origin, grab = NSEvent.mouseLocation
        var gesture = LongDragGesture()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let now = NSEvent.mouseLocation
            let dx = now.x - grab.x, dy = now.y - grab.y
            guard gesture.update(dx: dx, dy: dy) else { continue }
            window.setFrameOrigin(CGPoint(x: start.x + dx, y: start.y + dy))
        }
        if gesture.moved { onMoved?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hide Long", action: #selector(hide), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func hide() { onHide?() }
}

// MARK: - Window

/// Long's own little window: borderless, just under Lattices' overlays, on
/// every Space, never takes focus. Shown unless hidden (`long.shown`); where
/// you drag him is remembered (`long.home`).
@MainActor
final class DesktopLong {
    static let shared = DesktopLong()

    private static let shownKey = "long.shown"
    private static let homeKey = "long.home"
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    let model = DesktopLongModel()
    private var panel: NSPanel?
    private var host: LongHost?
    private var card: LongCard?
    private var observers: [NSObjectProtocol] = []

    static var wanted: Bool { UserDefaults.standard.object(forKey: shownKey) as? Bool ?? true }

    func start() {
        guard observers.isEmpty else { return }
        EventBus.shared.subscribe { [weak self] event in
            guard case .layerSwitched = event else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.card?.refresh()
                if self.model.away == nil { self.model.flash(.done, for: 0.6) }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: VisitController.changed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.visitChanged(note.userInfo) }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(animated: false) }
        })
        if Self.wanted { show() }
    }

    var shown: Bool { panel != nil }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        guard panel == nil else { return }
        let host = LongHost(rootView: DesktopLongView(model: model))
        let p = LongPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = Self.level
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = host
        host.onClick = { [weak self] in self?.toggleCard() }
        host.onHide = { [weak self] in self?.hide() }
        host.onMoved = { [weak self] in self?.dragged() }
        panel = p
        self.host = host
        place(animated: false)
        p.orderFrontRegardless()
    }

    func hide() {
        UserDefaults.standard.set(false, forKey: Self.shownKey)
        card?.close()
        card = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    // MARK: Card

    private func toggleCard() {
        if let card { card.close(); self.card = nil; return }
        guard let panel else { return }
        let card = LongCard(onClose: { [weak self] in self?.card = nil }, onHideLong: { [weak self] in self?.hide() })
        card.show(above: panel.frame)
        self.card = card
    }

    // MARK: Visits

    private func visitChanged(_ info: [AnyHashable: Any]?) {
        let status = VisitController.shared.status()
        card?.refresh()
        if status.visiting != nil {
            model.visiting(status)
            // The tag changes his size; place him once SwiftUI has laid it out.
            DispatchQueue.main.async { self.place(animated: true) }
            return
        }
        // A display marked elsewhere or back may move his home.
        guard model.away != nil || info?["ended"] != nil else { return place(animated: true) }
        model.home()
        DispatchQueue.main.async { self.place(animated: true) }
        if let failed = info?["failed"] as? Bool {
            model.flash(failed ? .oops : .done, for: failed ? 4 : 1.4)
        } else {
            model.mood = .rest
        }
    }

    // MARK: Placement

    /// Home, or at the edge you left by while visiting.
    private func place(animated: Bool) {
        guard let panel, let host else { return }
        let size = host.fittingSize
        let frame = CGRect(origin: awayOrigin(size) ?? homeOrigin(size), size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func homeOrigin(_ size: CGSize) -> CGPoint {
        // Not on a display that's showing another machine.
        let here = NSScreen.screens.filter { !VisitController.isElsewhere($0) }
        let screens = here.map(\.visibleFrame)
        if let saved = UserDefaults.standard.string(forKey: Self.homeKey).map(NSPointFromString),
           screens.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(CGRect(origin: saved, size: size)) }) {
            return saved
        }
        // The menu bar's display, not whichever has focus.
        let visible = here.first(where: { $0.frame.origin == .zero })?.visibleFrame ?? screens.first ?? NSScreen.screens.first?.visibleFrame ?? .zero
        return CGPoint(x: visible.maxX - size.width - 18, y: visible.minY + 14)
    }

    /// Beside the parked cursor, just inside the screen's edge, facing the host.
    private func awayOrigin(_ size: CGSize) -> CGPoint? {
        let status = VisitController.shared.status()
        guard status.visiting != nil, let parked = status.parked, let side = status.side else { return nil }
        // Parked is in global top-left coordinates; AppKit's origin is the primary screen's bottom left.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: parked.x, y: primary - parked.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) })?.frame else { return nil }
        let x: CGFloat, y: CGFloat
        switch side {
        case .right: x = screen.maxX - size.width; y = point.y - size.height / 2
        case .left: x = screen.minX; y = point.y - size.height / 2
        case .top: x = point.x - size.width / 2; y = screen.maxY - size.height
        case .bottom: x = point.x - size.width / 2; y = screen.minY
        }
        return CGPoint(x: min(max(x, screen.minX), screen.maxX - size.width),
                       y: min(max(y, screen.minY), screen.maxY - size.height))
    }

    private func dragged() {
        guard let panel, model.away == nil else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.homeKey)
        if let card { card.show(above: panel.frame) }
    }
}
