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
    private var presentations: [NSWindow: RemoteViewerPresentation] = [:]
    private var fullScreenExits: [NSWindow: SystemSpaceChangeFeedback.Exit] = [:]

    override init() {
        super.init()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationActivityChanged), name: name, object: nil)
        }
    }

    @objc private func applicationActivityChanged() {
        for window in open.keys { update(window) }
    }

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
        let presentation = RemoteViewerPresentation()
        presentation.window = window
        presentations[window] = presentation
        window.contentView = NSHostingView(rootView: RemoteViewerView(session: session, presentation: presentation))
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
        session.engaged = window.isKeyWindow && NSApp.isActive
        session.visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        window.title = session.title
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidResignKey(_ notification: Notification) {
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
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        presentations[window]?.setFullScreen(true)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let screen = window.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let display = WindowTiler.displaySpaces(forDisplayID: number.uint32Value, in: WindowTiler.getDisplaySpaces()),
           let token = SystemSpaceChangeFeedback.shared.beginFullScreenExit(display) {
            fullScreenExits[window] = token
        }
        presentations[window]?.setFullScreen(false)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let token = fullScreenExits.removeValue(forKey: window) else { return }
        let display = WindowTiler.getDisplaySpaces().first { $0.displayId == token.displayID }
        SystemSpaceChangeFeedback.shared.completeFullScreenExit(token, display: display)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        presentations[window]?.setFullScreen(false)
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        if let token = fullScreenExits.removeValue(forKey: window) {
            SystemSpaceChangeFeedback.shared.cancelFullScreenExit(token)
        }
        presentations[window]?.setFullScreen(true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let session = open.removeValue(forKey: window) else { return }
        if let token = fullScreenExits.removeValue(forKey: window) {
            SystemSpaceChangeFeedback.shared.cancelFullScreenExit(token)
        }
        titles.removeValue(forKey: window)
        presentations.removeValue(forKey: window)?.invalidate()
        session.visible = false
        session.stop()
    }
}

// MARK: - View

struct RemoteViewerView: View {
    @ObservedObject var session: RemoteViewSession
    @ObservedObject var presentation: RemoteViewerPresentation
    @AppStorage("remoteView.agentHands.behavior") private var cursorBehavior = RemoteAgentCursorBehavior.followPointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: Control?
    private enum Control: Hashable { case monitor, app, region, resolution, control, hands, keyboard, screenSharing, fullScreen, close }

    var body: some View {
        ZStack(alignment: .top) {
            framedPicture
                .padding([.horizontal, .bottom], presentation.isFullScreen ? 0 : 12)
                .padding(.top, presentation.isFullScreen ? 0 : 46)

            if presentation.isFullScreen {
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { presentation.setEdgeHovered($0) }
                    .accessibilityHidden(true)
            }
            bar
                .background(Color(white: 0.04).opacity(presentation.isFullScreen ? 0.96 : 1))
                .offset(y: presentation.controlsVisible ? 0 : -40)
                .opacity(presentation.controlsVisible ? 1 : 0)
                .allowsHitTesting(presentation.controlsVisible)
                .accessibilityHidden(!presentation.controlsVisible)
                .onHover { presentation.setControlsHovered($0) }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: presentation.controlsVisible)

            if presentation.isFullScreen && !presentation.controlsVisible {
                HStack {
                    Spacer()
                    closeViewerButton
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.04).opacity(0.85)))
                }
                .padding(10)
            }
        }
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(white: 0.04))
        .foregroundStyle(Palette.text)
        .font(Typo.body(11))
        .onChange(of: focusedControl) { _, value in presentation.setControlsFocused(value != nil) }
        .onChange(of: presentation.isFullScreen) { _, _ in focusedControl = nil }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: presentation.isFullScreen ? 0 : 64)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.host).font(Typo.heading(12)).lineLimit(1)
                Text(session.target.label).font(Typo.mono(10)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                viewerControls.fixedSize()
                ScrollView(.horizontal) { viewerControls.fixedSize() }
                    .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(-1)
            closeViewerButton
                .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var viewerControls: some View {
        HStack(spacing: 10) {
            targetPicker
            resolutionPicker
            divider
            controlToggle
            if session.canSendKeyboard {
                Button {
                    session.keyboardEnabled.toggle()
                    if session.keyboardEnabled { presentation.requestRemoteInput() }
                } label: {
                    Label(session.keyboardEnabled ? "Keyboard on" : "Keyboard off", systemImage: "keyboard")
                        .font(Typo.body(11))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(session.keyboardEnabled ? Long.coral.opacity(0.2) : Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .keyboard)
                .disabled(!session.controlling)
                .help(session.canCaptureKeyboard
                      ? "Keyboard starts with Control. Command becomes Super. Click to toggle, or press Control–Option–Escape to release it."
                      : "Send keys to the focused app on \(session.host). Click to toggle, or press Control–Option–Escape to release it.")
            }
            Menu {
                Text(session.showingVideo ? "Live video" : "Still images")
                if let reason = session.videoFallbackReason {
                    Text("Video interrupted: \(reason)")
                }
                if session.canRetryVideo {
                    Button("Retry live video") { session.retryVideo() }
                }
                Divider()
                Button("VNC in Screen Sharing…") { session.openScreenSharing() }
            } label: {
                Label(session.isRecoveringVideo ? "Reconnecting" : (session.videoFallbackReason != nil ? "Stills" : "Lattices"),
                      systemImage: "rectangle.on.rectangle")
                    .font(Typo.body(11))
            }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Choose Lattices streaming or a VNC connection")
                .focused($focusedControl, equals: .screenSharing)
            stats
            iconButton(presentation.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: presentation.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
                presentation.toggleFullScreen()
            }
            .focused($focusedControl, equals: .fullScreen)
            .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }

    private var closeViewerButton: some View {
        Button { presentation.close() } label: {
            Label("Close viewer", systemImage: "xmark")
                .font(Typo.body(11))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(2)
        .focused($focusedControl, equals: .close)
        .accessibilityLabel("Close viewer")
        .help("Close this viewer · ⌘W")
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
            .focused($focusedControl, equals: .monitor)

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
            .focused($focusedControl, equals: .app)

            Button { session.selectingRegion.toggle() } label: {
                segment("crop", "Region", on: session.target.kind == "Region" || session.selectingRegion)
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .region)
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

    private var resolutionPicker: some View {
        Menu {
            Picker("Resolution", selection: $session.resolution) {
                ForEach(RemoteView.Resolution.allCases) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }
            .pickerStyle(.inline)
            if let size = session.deliveredSize {
                Divider()
                Text("Receiving \(Int(size.width)) × \(Int(size.height))")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($focusedControl, equals: .resolution)
        .accessibilityLabel("Resolution")
        .help("Resolution: \(session.resolution.label)")
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
        HStack(spacing: 0) {
            Button {
                session.controlling.toggle()
                if session.controlling { presentation.requestRemoteInput() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.controlling ? "cursorarrow.motionlines" : "cursorarrow")
                        .font(.system(size: 10, weight: .medium))
                    Text(session.controlling ? "Controlling" : "Control").font(Typo.body(11))
                }
                .padding(.horizontal, 9).frame(width: 104, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .control)
            .help(session.canControl ? "Send clicks, scrolls and keys to \(session.host)" : "\(session.host) doesn't take input from this Mac")

            Rectangle().fill(Palette.border).frame(width: Chrome.hairline, height: 12)
            Menu {
                Picker("Agent hands", selection: $cursorBehavior) {
                    ForEach(RemoteAgentCursorBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($focusedControl, equals: .hands)
            .accessibilityLabel("Agent hands behavior")
            .help("Agent hands: \(cursorBehavior.title)")
        }
        .foregroundStyle(session.controlling ? Long.coral : (session.canControl ? Palette.textDim : Palette.textMuted.opacity(0.6)))
        .background(RoundedRectangle(cornerRadius: 6).fill(session.controlling ? Long.coral.opacity(0.14) : Color.white.opacity(0.05)))
        .disabled(!session.canControl)
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
        .accessibilityLabel(help)
        .help(help)
    }

    private var stats: some View {
        Text(statsText)
            .font(Typo.mono(10))
            .foregroundStyle(Palette.textMuted)
            .monospacedDigit()
            .frame(width: 92, alignment: .trailing)
            .help(session.streamActivity?.state == .idle
                  ? "The remote host reports an unchanged screen. Video resumes as soon as the picture changes."
                  : "Received frames per second and round-trip latency")
    }

    private var statsText: String {
        switch session.status {
        case .live:
            if session.streamActivity?.state == .idle { return "idle · \(Int(session.fps.rounded())) fps" }
            return session.showingVideo || session.fps > 0 ? "\(Int(session.fps.rounded())) fps · \(session.latency) ms" : "—"
        case .paused: return "paused"
        case .connecting: return "connecting"
        case .failed: return "offline"
        }
    }

    // MARK: Picture

    private var isMonitor: Bool {
        if case .display = session.target { return true }
        return false
    }

    private var screenAspect: CGFloat? {
        let size: CGSize?
        if session.frame.width > 0 && session.frame.height > 0 {
            size = session.frame.size
        } else if let delivered = session.deliveredSize {
            size = delivered
        } else if case .display(let index, _) = session.target {
            size = session.displays.first(where: { $0.index == index })?.frame.size
        } else {
            size = nil
        }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// The picture and its input surface share the same inset. Decorative
    /// hardware never participates in remote pointer or region coordinates.
    private var framedPicture: some View {
        GeometryReader { proxy in
            let fullScreen = presentation.isFullScreen
            let edge: CGFloat = fullScreen ? 0 : (isMonitor ? 9 : 6)
            let lip: CGFloat = fullScreen ? 0 : (isMonitor ? 21 : 0)
            let available = CGSize(width: max(1, proxy.size.width - edge * 2),
                                   height: max(1, proxy.size.height - edge * 2 - lip))
            let aspect = fullScreen ? nil : screenAspect
            let width = aspect.map { min(available.width, available.height * $0) } ?? available.width
            let height = aspect.map { width / $0 } ?? available.height
            let radius: CGFloat = fullScreen ? 0 : (isMonitor ? 14 : 10)

            ZStack {
                Color.black
                picture
                overlay
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: fullScreen ? 0 : 5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.9), lineWidth: fullScreen ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .padding(edge)
            .padding(.bottom, lip)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.10), Color(white: 0.14)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(fullScreen ? 0 : 0.35), radius: 10, y: 5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.08), Color.white.opacity(0.18)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: fullScreen ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Long.coral.opacity(0.55), lineWidth: !fullScreen && session.controlling ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if !fullScreen && isMonitor {
                    Capsule().fill(Color.black.opacity(0.45))
                        .frame(width: 30, height: 2)
                        .overlay(alignment: .bottom) { Color.white.opacity(0.08).frame(height: 0.5) }
                        .padding(.bottom, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var picture: some View {
        GeometryReader { proxy in
            ZStack {
                RemoteVideoSurface(layer: session.video.layer, cornerRadius: presentation.isFullScreen ? 0 : 5,
                                   viewportChanged: session.updateViewport)
                    .opacity(session.showingVideo ? 1 : 0)
                if !session.showingVideo, let image = session.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                RemoteInputSurface(session: session, presentation: presentation, cursorBehavior: cursorBehavior)
            }
        }
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
            } else if session.keyboardCaptured && (!presentation.isFullScreen || presentation.controlsVisible) {
                hint("Keyboard captured · ⌘ → Super · ⌃⌥Esc to release")
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
    @ObservedObject var presentation: RemoteViewerPresentation
    var cursorBehavior: RemoteAgentCursorBehavior

    func makeNSView(context: Context) -> RemoteInputView {
        let view = RemoteInputView()
        view.session = session
        view.presentation = presentation
        presentation.localInteractionBegan = { [weak view] in view?.suspendKeyboardCapture() }
        presentation.remoteInteractionRequested = { [weak view] in view?.requestRemoteFocus() }
        presentation.remoteInputIsFirstResponder = { [weak view] in
            guard let view, view.session?.controlling == true,
                  view.session?.keyboardEnabled == true, view.session?.canSendKeyboard == true else { return false }
            return view.window?.firstResponder === view
        }
        return view
    }

    func updateNSView(_ view: RemoteInputView, context: Context) {
        view.session = session
        view.imageSize = session.showingVideo ? session.videoSize : session.image?.size ?? .zero
        view.remoteFrame = session.frame
        view.cursorBehavior = cursorBehavior
        view.updateInteraction()
        view.needsDisplay = true
        view.requestRemoteFocusIfNeeded()
    }

    static func dismantleNSView(_ view: RemoteInputView, coordinator: ()) {
        view.endInteraction()
    }
}

/// Hosts the session's `AVSampleBufferDisplayLayer`. Aspect-fit, like
/// `RemoteView.fit`, so input maps onto what is shown.
private struct RemoteVideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var cornerRadius: CGFloat
    var viewportChanged: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> RemoteVideoView {
        let view = RemoteVideoView()
        view.video = layer
        view.layer?.cornerRadius = cornerRadius
        view.viewportChanged = viewportChanged
        return view
    }

    func updateNSView(_ view: RemoteVideoView, context: Context) {
        view.video = layer
        view.layer?.cornerRadius = cornerRadius
        view.viewportChanged = viewportChanged
    }
}

final class RemoteVideoView: NSView {
    var viewportChanged: ((CGFloat, CGFloat) -> Void)?
    private var reportedViewport: CGSize = .zero
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video?.frame = bounds
        video?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        reportViewport()
    }

    private func reportViewport() {
        guard let window, bounds.width > 0 else { return }
        let viewport = CGSize(width: bounds.width, height: window.backingScaleFactor)
        guard viewport != reportedViewport else { return }
        reportedViewport = viewport
        // Layout can run during a SwiftUI update. Publish on the next main turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedViewport == viewport else { return }
            self.viewportChanged?(viewport.width, viewport.height)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RemoteInputView: NSView {
    weak var session: RemoteViewSession?
    weak var presentation: RemoteViewerPresentation?
    var imageSize: CGSize = .zero
    var remoteFrame: CGRect = .zero
    var cursorBehavior: RemoteAgentCursorBehavior = .followPointer {
        didSet { agentCursor.behavior = cursorBehavior }
    }

    private var downAt: CGPoint?
    private var dragAt: CGPoint?
    private var scrollCarry = CGVector.zero
    private let agentCursor = RemoteAgentCursorView()
    private var pointerTracking: NSTrackingArea?
    private var cursorTarget: RemoteView.Target?
    private var cursorEnabled = false
    private var pressedButtons = Set<String>()
    private var wantedRemoteFocus = false
    private var pendingRemoteFocus = false
    private var remoteFocusScheduled = false
    private var inputResumeScheduled = false
    private lazy var keyboardCapture: RemoteKeyboardCapture = {
        let capture = RemoteKeyboardCapture()
        capture.active = { [weak self] in
            self?.ownsRemoteKeyboard == true && self?.session?.keyboardCaptured == true
        }
        capture.key = { [weak self] code, down in self?.session?.physicalKey(code, down: down) }
        capture.release = { [weak self] in self?.releaseKeyboard() }
        capture.toggleFullScreen = { [weak self] in self?.presentation?.toggleFullScreen() }
        capture.closeWindow = { [weak self] in self?.presentation?.close() }
        return capture
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(agentCursor)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(pointerContextChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(pointerContextChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let acquired = super.becomeFirstResponder()
        if acquired {
            // NSWindow has not installed this responder until this method returns.
            DispatchQueue.main.async { [weak self] in self?.updateInteraction() }
        }
        return acquired
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardCapture.suspend() }
        return resigned
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let session, session.controlling || session.selectingRegion else { return }
        addCursorRect(RemoteView.fit(imageSize, in: bounds.size), cursor: session.selectingRegion ? .crosshair : .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateInteraction()
    }

    override func layout() {
        super.layout()
        updateInteraction()
    }

    private var showsAgentCursor: Bool {
        session?.controlling == true && session?.selectingRegion == false && session?.status == .live
            && window?.isKeyWindow == true && NSApp.isActive
    }

    private var remoteKeyboardEnabled: Bool {
        session?.controlling == true && session?.keyboardEnabled == true && session?.canSendKeyboard == true
    }

    private var ownsRemoteKeyboard: Bool {
        remoteKeyboardEnabled && showsAgentCursor && window?.firstResponder === self
            && presentation?.localControlsActive != true
    }

    private var wantsRemoteFocus: Bool {
        remoteKeyboardEnabled || session?.selectingRegion == true
    }

    func updateInteraction() {
        let shown = RemoteView.fit(imageSize, in: bounds.size)
        let enabled = showsAgentCursor
        if !enabled || cursorTarget != session?.target || agentCursor.frame != shown {
            agentCursor.reset()
        }
        agentCursor.frame = shown
        cursorTarget = session?.target
        if enabled != cursorEnabled {
            cursorEnabled = enabled
            if enabled, let window { followAgentCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        }
        window?.invalidateCursorRects(for: self)
        if ownsRemoteKeyboard, session?.canCaptureKeyboard == true { scheduleInputResume() }
        else { keyboardCapture.suspend() }
    }

    /// updateNSView/layout can reach here while SwiftUI is updating. Recheck
    /// ownership on the next main turn before publishing capture state.
    private func scheduleInputResume() {
        guard !inputResumeScheduled else { return }
        inputResumeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputResumeScheduled = false
            guard self.ownsRemoteKeyboard, let session = self.session else {
                self.keyboardCapture.suspend()
                return
            }
            session.resumeInput()
            guard session.keyboardCaptured else {
                self.keyboardCapture.suspend()
                return
            }
            if !self.keyboardCapture.start() {
                session.keyboardEnabled = false
                session.notice = "Keyboard capture needs Accessibility access for Lattices."
            }
        }
    }

    private func releaseKeyboard() {
        keyboardCapture.suspend()
        session?.keyboardEnabled = false
    }

    func suspendKeyboardCapture() { keyboardCapture.suspend() }

    /// An explicit toolbar action or menu dismissal requests one deferred
    /// handoff; later video/stat updates do not create another request.
    func requestRemoteFocus() {
        guard wantsRemoteFocus else { return }
        pendingRemoteFocus = true
        scheduleRemoteFocusIfNeeded()
    }

    func requestRemoteFocusIfNeeded() {
        let wanted = wantsRemoteFocus
        if wanted && !wantedRemoteFocus { pendingRemoteFocus = true }
        wantedRemoteFocus = wanted
        if !wanted { pendingRemoteFocus = false }
        scheduleRemoteFocusIfNeeded()
    }

    private func scheduleRemoteFocusIfNeeded() {
        guard pendingRemoteFocus, !remoteFocusScheduled,
              presentation?.localControlsActive != true,
              window?.isKeyWindow == true, NSApp.isActive else { return }
        remoteFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remoteFocusScheduled = false
            guard self.pendingRemoteFocus,
                  self.wantsRemoteFocus,
                  self.presentation?.localControlsActive != true,
                  let window = self.window, window.isKeyWindow, NSApp.isActive else { return }
            self.pendingRemoteFocus = false
            if window.firstResponder !== self {
                let acquired = window.makeFirstResponder(self)
                DiagnosticLog.shared.info("RemoteKeyboard: requested picture focus acquired=\(acquired)")
            }
            // A menu can suspend the tap without replacing first responder.
            // Resume explicitly even when the remote picture is unchanged.
            self.updateInteraction()
        }
    }

    func resetAgentCursor() { agentCursor.reset() }

    func endInteraction() {
        keyboardCapture.stop()
        session?.releaseInput()
        pressedButtons.removeAll()
        downAt = nil; dragAt = nil
        agentCursor.reset()
    }

    @objc private func pointerContextChanged(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow, changedWindow !== window { return }
        if notification.name == NSWindow.didBecomeKeyNotification
            || notification.name == NSApplication.didBecomeActiveNotification {
            // Window/application delegates update engaged/visible first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow == true, NSApp.isActive else { return }
                self.updateInteraction()
                self.requestRemoteFocusIfNeeded()
            }
        } else if notification.name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification {
            resetAgentCursor()
        } else {
            endInteraction()
        }
    }

    private func followAgentCursor(at point: CGPoint) {
        guard showsAgentCursor, agentCursor.frame.contains(point), remote(point) != nil else {
            agentCursor.reset()
            return
        }
        agentCursor.follow(convert(point, to: agentCursor), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func landAgentCursor(at point: CGPoint) {
        guard showsAgentCursor else { return }
        agentCursor.land(at: convert(point, to: agentCursor), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    override func mouseEntered(with event: NSEvent) { movePointer(event) }
    override func mouseMoved(with event: NSEvent) { movePointer(event) }
    override func mouseExited(with event: NSEvent) { agentCursor.reset() }

    private func movePointer(_ event: NSEvent) {
        let p = point(event)
        followAgentCursor(at: p)
        guard showsAgentCursor, let mapped = remote(p) ?? (pressedButtons.isEmpty ? nil : clampedRemote(p)) else { return }
        session?.hover(mapped)
    }

    private func clampedRemote(_ point: CGPoint) -> CGPoint? {
        let shown = RemoteView.fit(imageSize, in: bounds.size)
        guard shown.width > 1, shown.height > 1 else { return nil }
        return remote(CGPoint(x: min(max(point.x, shown.minX), shown.maxX - 0.01),
                              y: min(max(point.y, shown.minY), shown.maxY - 0.01)))
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func remote(_ p: CGPoint) -> CGPoint? {
        RemoteView.remotePoint(p, view: bounds.size, image: imageSize, frame: remoteFrame)
    }

    override func mouseDown(with event: NSEvent) {
        presentation?.requestRemoteInput()
        window?.makeFirstResponder(self)
        downAt = point(event)
        dragAt = downAt
        followAgentCursor(at: point(event))
        beginButton("left", event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragAt = point(event)
        movePointer(event)
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
        if session.livePointer {
            endButton("left", event)
            return
        }
        if hypot(end.x - start.x, end.y - start.y) > 6, let a = remote(start), let b = remote(end) {
            session.drag(from: a, to: b)
        } else if let p = remote(end) {
            session.click(p, count: event.clickCount >= 2 ? 2 : 1)
            landAgentCursor(at: end)
        }
    }

    private func beginButton(_ button: String, _ event: NSEvent) {
        guard showsAgentCursor, session?.livePointer == true, let p = remote(point(event)) else { return }
        pressedButtons.insert(button)
        session?.pointerButton(button, down: true, at: p)
    }

    private func endButton(_ button: String, _ event: NSEvent) {
        guard pressedButtons.remove(button) != nil, let p = clampedRemote(point(event)) else { return }
        session?.pointerButton(button, down: false, at: p)
        landAgentCursor(at: point(event))
    }

    override func rightMouseDown(with event: NSEvent) { beginButton("right", event) }
    override func rightMouseDragged(with event: NSEvent) { movePointer(event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { beginButton("middle", event) } }
    override func otherMouseDragged(with event: NSEvent) { movePointer(event) }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { endButton("middle", event) } }

    override func rightMouseUp(with event: NSEvent) {
        if session?.livePointer == true { endButton("right", event); return }
        guard let session, session.controlling, let p = remote(point(event)) else { return }
        session.click(p, button: "right")
        landAgentCursor(at: point(event))
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
        guard presentation?.localControlsActive != true else { return super.keyDown(with: event) }
        if session.selectingRegion, event.keyCode == 53 {
            session.selectingRegion = false
            needsDisplay = true
            return
        }
        guard ownsRemoteKeyboard else { return super.keyDown(with: event) }
        if RemoteKeyboard.isRelease(keyCode: event.keyCode,
                                    flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) {
            releaseKeyboard()
            return
        }
        if session.keyboardCaptured { return }
        guard let key = RemoteView.key(keyCode: event.keyCode, characters: event.characters,
                                       ignoringModifiers: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
            return super.keyDown(with: event)
        }
        session.key(key)
    }

    /// While controlling, ⌘-shortcuts belong to the other machine — except
    /// ⌘W and ⌘` which stay with this window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if RemoteKeyboard.isClose(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) {
            if !event.isARepeat { presentation?.close() }
            return true
        }
        if RemoteKeyboard.isFullScreen(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) {
            if !event.isARepeat { presentation?.toggleFullScreen() }
            return true
        }
        guard presentation?.localControlsActive != true else { return super.performKeyEquivalent(with: event) }
        guard ownsRemoteKeyboard else { return super.performKeyEquivalent(with: event) }
        let base = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), base == "`" { return super.performKeyEquivalent(with: event) }
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
