import AppKit
import SwiftUI

// MARK: - HUDRightBar (inspector + conversation)

struct HUDRightBar: View {
    @ObservedObject var state: HUDState
    @ObservedObject private var handsOff = HandsOffSession.shared
    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var previewModel = WindowPreviewStore.shared
    @ObservedObject private var xp = HUDExperienceStore.shared
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Top half: inspector
            inspectorPane
                .frame(maxHeight: .infinity)

            HUDHairline(opacity: 0.75)

            // Bottom half: conversation
            conversationPane
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HUDPanelBackground())
        .overlay(alignment: .leading) {
            if xp.showChrome {
                HUDHairline(axis: .vertical, opacity: 0.8)
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: xp.showChrome ? 0 : 14, style: .continuous)
        )
        .hudEdgeGlow()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Inspector (top half)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var inspectorPane: some View {
        if let item = state.pinnedItem {
            detailView(for: item)
        } else {
            inspectorEmpty
        }
    }

    private var inspectorEmpty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "sidebar.right")
                .font(.system(size: 22))
                .foregroundColor(Palette.textMuted.opacity(0.3))
            Text("Select an item")
                .font(Typo.mono(11))
                .foregroundColor(Palette.textMuted)
            Spacer()
        }
    }

    @ViewBuilder
    private func detailView(for item: HUDItem) -> some View {
        switch item {
        case .project(let p): projectDetail(p)
        case .window(let w):  windowDetail(w)
        }
    }

    private func projectDetail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(project.isRunning ? Palette.running : Palette.textMuted.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(project.name)
                    .font(Typo.monoBold(13))
                    .foregroundColor(Palette.text)
                Spacer()
                if project.isRunning {
                    Text("running")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.running)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Palette.running.opacity(0.10)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let previewWindow = projectPreviewWindow(project) {
                previewSection(for: previewWindow, title: "Window Preview")
            }

            HUDHairline(opacity: 0.70)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    metaRow("Path", value: project.path)
                    metaRow("Session", value: project.sessionName)
                    if !project.paneSummary.isEmpty { metaRow("Summary", value: project.paneSummary) }
                    if let dev = project.devCommand { metaRow("Dev", value: dev) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            HStack(spacing: 8) {
                actionButton(project.isRunning ? "Focus" : "Launch",
                             icon: project.isRunning ? "eye" : "play.fill") {
                    SessionManager.launch(project: project)
                    HandsOffSession.shared.playCachedCue(project.isRunning ? "Focused." : "Done.")
                    onDismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func windowDetail(_ window: WindowEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(window.title)
                    .font(Typo.monoBold(12))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Text(window.app)
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            previewSection(for: window, title: "Live Preview")

            HUDHairline(opacity: 0.70)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    metaRow("WID", value: "\(window.wid)")
                    metaRow("Frame", value: "\(Int(window.frame.x)),\(Int(window.frame.y)) \(Int(window.frame.w))×\(Int(window.frame.h))")
                    if let lastUsed = desktop.lastInteractionDate(for: window.wid) {
                        metaRow("Last used", value: relativeTime(lastUsed))
                    }
                    if let session = window.latticesSession { metaRow("Session", value: session) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            HStack(spacing: 8) {
                actionButton("Focus", icon: "eye") {
                    _ = WindowTiler.focusWindow(wid: window.wid, pid: window.pid)
                    HandsOffSession.shared.playCachedCue("Focused.")
                    onDismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func previewSection(for window: WindowEntry, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typo.monoBold(10))
                    .foregroundColor(Palette.textMuted)
                Spacer()
                Text("no focus")
                    .font(Typo.mono(9))
                    .foregroundColor(Palette.textDim)
            }

            WindowPreviewCard(
                image: previewModel.image(for: window.wid),
                isLoading: previewModel.isLoading(window.wid),
                appName: window.app
            )
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipped()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task(id: window.wid) {
            previewModel.load(window: window)
        }
    }

    private func projectPreviewWindow(_ project: Project) -> WindowEntry? {
        guard project.isRunning else { return nil }
        return desktop.windowForSession(project.sessionName)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Conversation (bottom half)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var conversationPane: some View {
        VStack(spacing: 0) {
            // Header with voice state
            conversationHeader

            HUDHairline(opacity: 0.70)

            // Messages
            if handsOff.conversationHistory.isEmpty {
                conversationEmpty
            } else {
                conversationMessages
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 8) {
            // Voice indicator
            voiceIndicator

            Text("Voice")
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text)

            Spacer()

            // State badge
            if state.voiceActive {
                stateBadge
            }

            // V toggle hint
            Text("V")
                .font(Typo.geistMonoBold(9))
                .foregroundColor(state.voiceActive ? Palette.text : Palette.textMuted)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(state.voiceActive ? Palette.running.opacity(0.2) : Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(state.voiceActive ? Palette.running.opacity(0.4) : Palette.border, lineWidth: 0.5)
                        )
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var voiceIndicator: some View {
        Circle()
            .fill(voiceColor)
            .frame(width: 8, height: 8)
            .overlay(
                // Pulse animation when listening
                Circle()
                    .stroke(voiceColor.opacity(0.4), lineWidth: 1.5)
                    .scaleEffect(handsOff.state == .listening ? 1.8 : 1.0)
                    .opacity(handsOff.state == .listening ? 0 : 1)
                    .animation(
                        handsOff.state == .listening
                            ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                            : .default,
                        value: handsOff.state
                    )
            )
    }

    private var voiceColor: Color {
        switch handsOff.state {
        case .idle:       return state.voiceActive ? Palette.running : Palette.textMuted.opacity(0.3)
        case .connecting: return Palette.detach
        case .listening:  return Palette.running
        case .thinking:   return Palette.detach
        }
    }

    private var stateBadge: some View {
        let label: String = {
            switch handsOff.state {
            case .idle:       return "ready"
            case .connecting: return "connecting"
            case .listening:  return "listening"
            case .thinking:   return "thinking"
            }
        }()

        return Text(label)
            .font(Typo.mono(9))
            .foregroundColor(voiceColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(voiceColor.opacity(0.10))
            )
    }

    private var conversationEmpty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 20))
                .foregroundColor(Palette.textMuted.opacity(0.3))
            Text(state.voiceActive ? "Listening..." : "Press V to talk")
                .font(Typo.mono(11))
                .foregroundColor(Palette.textMuted)
            Spacer()
        }
    }

    private var conversationMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(handsOff.conversationHistory.enumerated()), id: \.offset) { index, msg in
                        messageBubble(msg, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: handsOff.conversationHistory.count) { _ in
                // Auto-scroll to bottom
                if let last = handsOff.conversationHistory.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ msg: [String: String], index: Int) -> some View {
        let role = msg["role"] ?? "unknown"
        let content = msg["content"] ?? ""
        let isUser = role == "user"

        return HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(isUser ? "you" : "lattices")
                    .font(Typo.monoBold(8))
                    .foregroundColor(Palette.textMuted)
                    .textCase(.uppercase)

                Text(content)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isUser ? Palette.surfaceHov : Palette.surface)
                    )
                    .textSelection(.enabled)
            }
            .id(index)

            if !isUser { Spacer(minLength: 40) }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Shared helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func metaRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typo.monoBold(9))
                .foregroundColor(Palette.textMuted)
                .textCase(.uppercase)
            Text(value)
                .font(Typo.mono(11))
                .foregroundColor(Palette.text)
                .textSelection(.enabled)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(Typo.monoBold(10))
            }
            .foregroundColor(Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

struct HUDHoverPreviewView: View {
    @ObservedObject var state: HUDState
    @ObservedObject private var previewModel = WindowPreviewStore.shared
    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var xp = HUDExperienceStore.shared
    @State private var renderedWindow: WindowEntry?
    @State private var renderedWindowID: UInt32?
    @State private var renderedImage: NSImage?

    private var previewCornerRadii: RectangleCornerRadii {
        let r: CGFloat = xp.showChrome ? 0 : 14
        return .init(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r)
    }

    private var activeWindow: WindowEntry? {
        guard let item = state.transientPreviewItem else { return nil }
        return previewWindow(for: item)
    }

    private var previewToken: String {
        guard let window = activeWindow else { return "none" }
        return "\(window.wid)-\(previewModel.image(for: window.wid) != nil)"
    }

    var body: some View {
        Group {
            if let window = renderedWindow ?? activeWindow {
                Button {
                    state.pinInspectorCandidate(source: "preview")
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.title)
                                    .font(Typo.monoBold(12))
                                    .foregroundColor(Palette.text)
                                    .lineLimit(1)
                                Text(window.app)
                                    .font(Typo.mono(10))
                                    .foregroundColor(Palette.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("inspect")
                                .font(Typo.mono(9))
                                .foregroundColor(Palette.textDim)
                        }

                        ZStack {
                            WindowPreviewCard(
                                image: renderedImage,
                                isLoading: previewModel.isLoading(window.wid),
                                appName: window.app,
                                style: WindowPreviewCardStyle(
                                    containerCornerRadius: 10,
                                    imageCornerRadius: 8,
                                    imagePadding: 8,
                                    background: HUDChrome.glassFill,
                                    border: HUDChrome.glassStrokeSoft
                                ),
                                holdingPreviousPreview: isHoldingPreviousPreview(for: window)
                            ) {
                                if isHoldingPreviousPreview(for: window) {
                                    loadingOverlay(label: "Loading next preview")
                                }
                            }
                            .id(renderedWindowID ?? window.wid)
                            .transition(.opacity)
                        }
                        .frame(height: 190)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(HUDPanelBackground())
                    .overlay(
                        UnevenRoundedRectangle(cornerRadii: previewCornerRadii, style: .continuous)
                            .strokeBorder(HUDChrome.glassStroke, lineWidth: 0.75)
                    )
                    .clipShape(UnevenRoundedRectangle(cornerRadii: previewCornerRadii, style: .continuous))
                    .hudEdgeGlow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
                .onHover { isHovering in
                    state.previewInteractionActive = isHovering
                    guard !isHovering else { return }
                    let hoveredItemID = state.hoveredPreviewItem?.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        guard hoveredItemID == self.state.hoveredPreviewItem?.id,
                              !self.state.previewInteractionActive else { return }
                        self.state.hoveredPreviewItem = nil
                        self.state.hoverPreviewAnchorScreenY = nil
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            syncRenderedPreview(animated: false)
        }
        .onChange(of: state.transientPreviewItem?.id) { _ in
            syncRenderedPreview(animated: true)
        }
        .onChange(of: previewToken) { _ in
            syncRenderedPreview(animated: true)
        }
    }

    private func previewWindow(for item: HUDItem) -> WindowEntry? {
        switch item {
        case .window(let window):
            return window
        case .project(let project):
            guard project.isRunning else { return nil }
            return desktop.windowForSession(project.sessionName)
        }
    }

    private func loadingOverlay(label: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Palette.text)
                    Text(label)
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(HUDChrome.glassFillStrong)
                        .overlay(
                            Capsule()
                                .strokeBorder(HUDChrome.glassStrokeSoft, lineWidth: 0.5)
                        )
                )
                .padding(14)
            }
        }
    }

    private func isHoldingPreviousPreview(for window: WindowEntry) -> Bool {
        guard let renderedWindowID else { return false }
        return renderedWindowID != window.wid && previewModel.image(for: window.wid) == nil
    }

    private func syncRenderedPreview(animated: Bool) {
        guard let window = activeWindow else { return }

        previewModel.load(window: window)

        guard let image = previewModel.image(for: window.wid) else { return }
        guard renderedWindowID != window.wid || renderedImage == nil || renderedWindow?.title != window.title else { return }

        let apply = {
            renderedWindow = window
            renderedWindowID = window.wid
            renderedImage = image
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.16)) {
                apply()
            }
        } else {
            apply()
        }
    }
}
