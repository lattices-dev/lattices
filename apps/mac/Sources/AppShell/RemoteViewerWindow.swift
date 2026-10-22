import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Windows that show another machine live. One per target, so an app on
/// Archie and a monitor on arts-mini can sit side by side.
@MainActor
final class RemoteViewerWindows: NSObject, NSWindowDelegate {
    static let shared = RemoteViewerWindows()

    private var open: [NSWindow: RemoteViewSession] = [:]
    private var titles: [NSWindow: AnyCancellable] = [:]

    /// Opens (or brings forward) a viewer on `host` showing `target`.
    func show(host: String, address: String, port: UInt16, target: RemoteView.Target) {
        if let (window, _) = open.first(where: { $0.value.host == host && $0.value.target == target }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = RemoteViewSession(host: host, address: address, port: port, target: target)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.04, alpha: 1)
        window.minSize = NSSize(width: 520, height: 340)
        window.isReleasedWhenClosed = false
        window.title = session.title
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: RemoteViewerView(session: session))
        window.delegate = self
        cascade(window)
        open[window] = session
        titles[window] = session.$target.sink { [weak window, weak session] _ in
            DispatchQueue.main.async { if let window, let session { window.title = session.title } }
        }
        session.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        update(window)
    }

    /// Opens a viewer for a `RemoteHostsModel` host.
    func show(_ host: RemoteHostsModel.Host, target: RemoteView.Target) {
        show(host: host.name, address: host.address, port: host.port, target: target)
    }

    private func cascade(_ window: NSWindow) {
        if let last = open.keys.max(by: { $0.windowNumber < $1.windowNumber }) {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
        } else {
            window.center()
        }
    }

    private func update(_ window: NSWindow) {
        guard let session = open[window] else { return }
        session.visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        window.title = session.title
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let session = open.removeValue(forKey: window) else { return }
        titles.removeValue(forKey: window)
        session.visible = false
        session.stop()
    }
}

// MARK: - View

struct RemoteViewerView: View {
    @ObservedObject var session: RemoteViewSession

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                Color.black
                picture
                overlay
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(session.controlling ? Long.coral.opacity(0.55) : Palette.border, lineWidth: 1))
            .padding([.horizontal, .bottom], 8)
        }
        .background(Color(white: 0.04))
        .foregroundStyle(Palette.text)
        .font(Typo.body(11))
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.host).font(Typo.heading(12)).lineLimit(1)
                Text(session.target.label).font(Typo.mono(10)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 8)
            targetPicker
            divider
            controlToggle
            iconButton("rectangle.on.rectangle", help: "Open in Screen Sharing") { session.openScreenSharing() }
            stats
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(width: Chrome.hairline, height: 18)
    }

    private var targetPicker: some View {
        HStack(spacing: 2) {
            Menu {
                if session.displays.isEmpty { Text("No monitors reported") }
                ForEach(session.displays) { display in
                    Button("\(display.name.isEmpty ? "Display \(display.index + 1)" : display.name)  ·  \(Int(display.frame.width))×\(Int(display.frame.height))") {
                        session.target = .display(index: display.index, name: display.name)
                    }
                }
            } label: { segment("display", "Monitor", on: session.target.kind == "Monitor") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Menu {
                if session.windows.isEmpty { Text("No windows") }
                ForEach(groupedWindows, id: \.app) { group in
                    Section(group.app) {
                        ForEach(group.windows) { window in
                            Button(window.title.isEmpty ? group.app : window.title) {
                                session.target = .window(wid: window.id, app: window.app, title: window.title)
                            }
                        }
                    }
                }
            } label: { segment("macwindow", "App", on: session.target.kind == "App") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Button { session.selectingRegion.toggle() } label: {
                segment("crop", "Region", on: session.target.kind == "Region" || session.selectingRegion)
            }
            .buttonStyle(.plain)
            .help("Drag across the picture to view just that part")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
    }

    private var groupedWindows: [(app: String, windows: [RemoteHostsModel.Window])] {
        Dictionary(grouping: session.windows, by: \.app)
            .map { ($0.key, $0.value) }
            .sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
    }

    private func segment(_ icon: String, _ label: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(label).font(Typo.body(11))
        }
        .foregroundStyle(on ? Palette.text : Palette.textDim)
        .padding(.horizontal, 9).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.11) : .clear))
        .contentShape(Rectangle())
    }

    private var controlToggle: some View {
        Button { session.controlling.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: session.controlling ? "cursorarrow.motionlines" : "cursorarrow")
                    .font(.system(size: 10, weight: .medium))
                Text(session.controlling ? "Controlling" : "Control").font(Typo.body(11))
            }
            .foregroundStyle(session.controlling ? Long.coral : (session.canControl ? Palette.textDim : Palette.textMuted.opacity(0.6)))
            .padding(.horizontal, 9).frame(width: 104, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(session.controlling ? Long.coral.opacity(0.14) : Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.canControl)
        .help(session.canControl ? "Send clicks, scrolls and keys to \(session.host)" : "\(session.host) doesn't take input from this Mac")
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textDim)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var stats: some View {
        Text(statsText)
            .font(Typo.mono(10))
            .foregroundStyle(Palette.textMuted)
            .monospacedDigit()
            .frame(width: 92, alignment: .trailing)
    }

    private var statsText: String {
        switch session.status {
        case .live: return session.fps > 0 ? "\(Int(session.fps.rounded())) fps · \(session.latency) ms" : "—"
        case .paused: return "paused"
        case .connecting: return "connecting"
        case .failed: return "offline"
        }
    }

    // MARK: Picture

    private var picture: some View {
        GeometryReader { proxy in
            ZStack {
                RemoteVideoSurface(layer: session.video.layer)
                    .opacity(session.showingVideo ? 1 : 0)
                if !session.showingVideo, let image = session.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                RemoteInputSurface(session: session)
            }
            .onAppear { updateWidth(proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in updateWidth(width) }
        }
    }

    private func updateWidth(_ width: CGFloat) {
        session.requestWidth = RemoteView.requestWidth(viewWidth: width, backingScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    @ViewBuilder private var overlay: some View {
        switch session.status {
        case .connecting:
            placard { ProgressView().controlSize(.small); Text("Connecting to \(session.host)").foregroundStyle(Palette.textDim) }
        case .failed(let reason):
            placard {
                Text(reason).foregroundStyle(Palette.textDim).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    Button("Retry") { session.reconnect() }
                    Button("Screen Sharing") { session.openScreenSharing() }
                }.controlSize(.small)
            }
        case .live where session.image == nil && !session.showingVideo:
            placard { ProgressView().controlSize(.small) }
        default:
            EmptyView()
        }
        VStack {
            if session.selectingRegion {
                hint("Drag to choose a region · Esc cancels")
            }
            Spacer()
            if let notice = session.notice {
                hint(notice)
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func placard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.09).opacity(0.92)))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typo.body(11))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: Chrome.hairline))
    }
}

// MARK: - Input

/// Takes the pointer and keyboard over the picture: region selection while
/// choosing one, forwarded input while controlling, nothing otherwise.
private struct RemoteInputSurface: NSViewRepresentable {
    @ObservedObject var session: RemoteViewSession

    func makeNSView(context: Context) -> RemoteInputView {
        let view = RemoteInputView()
        view.session = session
        return view
    }

    func updateNSView(_ view: RemoteInputView, context: Context) {
        view.session = session
        view.imageSize = session.showingVideo ? session.videoSize : session.image?.size ?? .zero
        view.remoteFrame = session.frame
        view.needsDisplay = true
        if session.controlling || session.selectingRegion { view.window?.makeFirstResponder(view) }
    }
}

/// Hosts the session's `AVSampleBufferDisplayLayer`. Aspect-fit, like
/// `RemoteView.fit`, so input maps onto what is shown.
private struct RemoteVideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> RemoteVideoView {
        let view = RemoteVideoView()
        view.video = layer
        return view
    }

    func updateNSView(_ view: RemoteVideoView, context: Context) {
        view.video = layer
    }
}

final class RemoteVideoView: NSView {
    var video: AVSampleBufferDisplayLayer? {
        didSet {
            guard video !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            if let video { layer?.addSublayer(video) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video?.frame = bounds
        video?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RemoteInputView: NSView {
    weak var session: RemoteViewSession?
    var imageSize: CGSize = .zero
    var remoteFrame: CGRect = .zero

    private var downAt: CGPoint?
    private var dragAt: CGPoint?
    private var scrollCarry = CGVector.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard let session, session.controlling || session.selectingRegion else { return }
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func remote(_ p: CGPoint) -> CGPoint? {
        RemoteView.remotePoint(p, view: bounds.size, image: imageSize, frame: remoteFrame)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downAt = point(event)
        dragAt = downAt
    }

    override func mouseDragged(with event: NSEvent) {
        dragAt = point(event)
        if session?.selectingRegion == true { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragAt = nil; needsDisplay = true }
        guard let session, let start = downAt else { return }
        let end = point(event)
        if session.selectingRegion {
            if let rect = RemoteView.remoteRegion(from: start, to: end, view: bounds.size, image: imageSize, frame: remoteFrame) {
                session.target = .region(rect)
            }
            session.selectingRegion = false
            window?.invalidateCursorRects(for: self)
            return
        }
        guard session.controlling else { return }
        if hypot(end.x - start.x, end.y - start.y) > 6, let a = remote(start), let b = remote(end) {
            session.drag(from: a, to: b)
        } else if let p = remote(end) {
            session.click(p, count: event.clickCount >= 2 ? 2 : 1)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let session, session.controlling, let p = remote(point(event)) else { return }
        session.click(p, button: "right")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, session.controlling, let p = remote(point(event)) else { return super.scrollWheel(with: event) }
        // Trackpads report many small pixel deltas; send whole wheel notches.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollCarry.dx += -event.scrollingDeltaX / unit
        scrollCarry.dy += -event.scrollingDeltaY / unit
        let dx = scrollCarry.dx.rounded(.towardZero), dy = scrollCarry.dy.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        scrollCarry.dx -= dx; scrollCarry.dy -= dy
        session.scroll(at: p, dx: Double(dx), dy: Double(dy))
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        if session.selectingRegion, event.keyCode == 53 {
            session.selectingRegion = false
            needsDisplay = true
            return
        }
        guard session.controlling,
              let key = RemoteView.key(keyCode: event.keyCode, characters: event.characters,
                                       ignoringModifiers: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
            return super.keyDown(with: event)
        }
        session.key(key)
    }

    /// While controlling, ⌘-shortcuts belong to the other machine — except
    /// ⌘W and ⌘` which stay with this window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let session, session.controlling, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let base = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), base == "w" || base == "`" { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session, session.selectingRegion else { return }
        let shown = RemoteView.fit(imageSize, in: bounds.size)
        NSColor.black.withAlphaComponent(0.35).setFill()
        guard let a = downAt, let b = dragAt else {
            shown.fill(using: .sourceOver)
            return
        }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(shown)
        let path = NSBezierPath(rect: shown)
        path.append(NSBezierPath(rect: rect).reversed)
        path.fill()
        let coral = NSColor(srgbRed: 0xef / 255, green: 0x6a / 255, blue: 0x47 / 255, alpha: 1)
        coral.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.5
        outline.stroke()
    }
}
