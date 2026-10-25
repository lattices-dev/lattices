import AppKit
import SwiftUI

// MARK: - CheatSheetHUD (singleton window controller)

final class CheatSheetHUD {
    static let shared = CheatSheetHUD()

    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        guard panel == nil else { return }

        let view = CheatSheetView()
            .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: view)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.contentView = hosting

        // Center on the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - 260
        let y = screenFrame.midY - 240
        p.setFrameOrigin(NSPoint(x: x, y: y))

        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1.0
        }

        self.panel = p
        installMonitors()
    }

    func dismiss() {
        guard let p = panel else { return }
        removeMonitors()
        TileZoneOverlay.shared.dismiss()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }) { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
        }
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Key handling (global — panel is non-activating so keys go to frontmost app)
        localMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
            } else if event.keyCode == 49 { // Space — toggle voice command
                let audio = AudioLayer.shared
                if audio.isListening {
                    audio.stopVoiceCommand()
                } else {
                    audio.startVoiceCommand()
                }
            }
        }

        // Click outside dismisses
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

}

// MARK: - CheatSheetView

struct CheatSheetView: View {
    @ObservedObject private var hotkeyStore = HotkeyStore.shared
    @ObservedObject private var audioLayer = AudioLayer.shared
    @State private var hoveredAction: HotkeyAction?

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text("KEYBOARD SHORTCUTS")
                    .font(Typo.pixel(14))
                    .foregroundColor(Palette.textDim)
                    .tracking(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Rectangle().fill(Palette.border).frame(height: 0.5)

            // Two-column body
            HStack(alignment: .top, spacing: 20) {
                // Left column: Tiling
                tilingColumn

                Rectangle().fill(Palette.border).frame(width: 0.5)

                // Right column: App + tmux
                VStack(alignment: .leading, spacing: 16) {
                    appColumn
                    Rectangle().fill(Palette.border).frame(height: 0.5)
                    tmuxColumn
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Spacer(minLength: 0)

            // Voice feedback strip
            if audioLayer.isListening || audioLayer.lastTranscript != nil || audioLayer.executionResult != nil {
                Rectangle().fill(Palette.border).frame(height: 0.5)
                voiceFeedback
            }

            Rectangle().fill(Palette.border).frame(height: 0.5)

            // Footer
            HStack(spacing: 20) {
                Spacer()
                HStack(spacing: 6) {
                    keyBadge("Space")
                    Image(systemName: audioLayer.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 11))
                        .foregroundColor(audioLayer.isListening ? Palette.running : Palette.text)
                    Text(audioLayer.isListening ? "Listening..." : "Voice")
                        .font(Typo.geistMono(11))
                        .foregroundColor(audioLayer.isListening ? Palette.running : Palette.text)
                }
                HStack(spacing: 6) {
                    keyBadge("ESC")
                    Text("Dismiss")
                        .font(Typo.geistMono(11))
                        .foregroundColor(Palette.textMuted)
                }
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 520)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Palette.borderLit, lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tiling Column

    private var tilingColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnHeader("Tiling")

            Text("Add Shift to the layer arrows to tile.")
                .font(Typo.caption(10))
                .foregroundColor(Palette.textMuted)

            // 3x3 grid
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    tileCell(action: .tileTopLeft, label: "TL")
                    tileCell(action: .tileTop, label: "Top")
                    tileCell(action: .tileTopRight, label: "TR")
                }
                HStack(spacing: 2) {
                    tileCell(action: .tileLeft, label: "Left")
                    tileCell(action: .tileMaximize, label: "Max")
                    tileCell(action: .tileRight, label: "Right")
                }
                HStack(spacing: 2) {
                    tileCell(action: .tileBottomLeft, label: "BL")
                    tileCell(action: .tileBottom, label: "Bot")
                    tileCell(action: .tileBottomRight, label: "BR")
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )

            // Thirds row
            HStack(spacing: 2) {
                tileCell(action: .tileLeftThird, label: "\u{2153}L")
                tileCell(action: .tileCenterThird, label: "\u{2153}C")
                tileCell(action: .tileRightThird, label: "\u{2153}R")
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )

            // Center + Distribute
            shortcutRow(action: .tileCenter)
            shortcutRow(action: .tileOpenCell)
            shortcutRow(action: .tileDistribute)
            shortcutRow(action: .tileTypeGrid)
            shortcutRow(action: .tileOrganize)

            // Hovered shortcut detail
            if let hovered = hoveredAction, let binding = hotkeyStore.bindings[hovered] {
                HStack(spacing: 3) {
                    ForEach(binding.displayParts, id: \.self) { part in
                        keyBadge(part)
                    }
                    Text("→ \(hovered.label)")
                        .font(Typo.caption(11))
                        .foregroundColor(Palette.textDim)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.1), value: hoveredAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { over in
            if !over {
                hoveredAction = nil
                TileZoneOverlay.shared.dismiss()
            }
        }
        .onDisappear {
            hoveredAction = nil
            TileZoneOverlay.shared.dismiss()
        }
    }

    // MARK: - Voice Feedback

    private var voiceFeedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if audioLayer.isListening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.running)
                        .frame(width: 8, height: 8)
                    Text("Listening...")
                        .font(Typo.geistMono(12))
                        .foregroundColor(Palette.running)
                    Spacer()
                    Text("Press Space to stop")
                        .font(Typo.caption(10))
                        .foregroundColor(Palette.textMuted)
                }
            } else if let transcript = audioLayer.lastTranscript {
                // Show what was heard
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.textMuted)
                    Text(transcript)
                        .font(Typo.geistMono(12))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)
                }

                // Show matched intent + result
                if let intent = audioLayer.matchedIntent {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.textMuted)
                        Text(intent.replacingOccurrences(of: "_", with: " "))
                            .font(Typo.geistMonoBold(11))
                            .foregroundColor(Palette.text)

                        if !audioLayer.matchedSlots.isEmpty {
                            let slotText = audioLayer.matchedSlots
                                .map { "\($0.key): \($0.value)" }
                                .joined(separator: ", ")
                            Text(slotText)
                                .font(Typo.caption(10))
                                .foregroundColor(Palette.textDim)
                        }

                        Spacer()

                        if let result = audioLayer.executionResult {
                            Text(result == "ok" ? "Done" : result)
                                .font(Typo.caption(10))
                                .foregroundColor(result == "ok" ? Palette.running : Palette.kill)
                        }
                    }
                } else if let result = audioLayer.executionResult {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(Palette.textMuted)
                        Text(result)
                            .font(Typo.caption(10))
                            .foregroundColor(Palette.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.15))
        .animation(.easeInOut(duration: 0.15), value: audioLayer.isListening)
        .animation(.easeInOut(duration: 0.15), value: audioLayer.lastTranscript)
    }

    // MARK: - App Column

    private var appColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader("App")

            shortcutRow(action: .commandBar)
            shortcutRow(action: .unifiedWindow)
            shortcutRow(action: .bezel)
            shortcutRow(action: .hud)
            shortcutRow(action: .voiceCommand)
            shortcutRow(action: .cheatSheet)

            columnHeader("Workspace")
            shortcutRow(action: .motionMode)
            shortcutRow(action: .inPlaceMode)
            shortcutRow(action: .chordHints)
            shortcutRow(action: .screenMap)
        }
    }

    // MARK: - tmux Column

    private var tmuxColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            columnHeader("Pane controls")

            tmuxRow("Detach", keys: ["Ctrl+B", "D"])
            tmuxRow("Kill pane", keys: ["Ctrl+B", "X"])
            tmuxRow("Pane left", keys: ["Ctrl+B", "\u{2190}"])
            tmuxRow("Pane right", keys: ["Ctrl+B", "\u{2192}"])
            tmuxRow("Zoom toggle", keys: ["Ctrl+B", "Z"])
            tmuxRow("Scroll mode", keys: ["Ctrl+B", "["])
        }
    }

    // MARK: - Shared components

    private func columnHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typo.pixel(12))
            .foregroundColor(Palette.textDim)
            .tracking(1)
    }

    private func tileCell(action: HotkeyAction, label: String) -> some View {
        let binding = hotkeyStore.bindings[action]
        let badgeText = binding?.symbolicDisplay ?? ""
        let isHovered = hoveredAction == action

        return VStack(spacing: 2) {
            Text(badgeText)
                .font(Typo.geistMonoBold(12))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(isHovered ? Color.blue : Palette.text)
            Text(label)
                .font(Typo.caption(8))
                .foregroundColor(isHovered ? Palette.text : Palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.blue.opacity(0.15) : Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isHovered ? Color.blue.opacity(0.5) : Palette.border, lineWidth: 0.5)
                )
        )
        .onHover { over in
            if over {
                hoveredAction = action
                if let pos = action.tilePosition {
                    TileZoneOverlay.shared.show(position: pos)
                }
            }
        }
    }

    private func shortcutRow(action: HotkeyAction) -> some View {
        let binding = hotkeyStore.bindings[action]
        return HStack(spacing: 8) {
            if let parts = binding?.displayParts {
                HStack(spacing: 3) {
                    ForEach(parts, id: \.self) { part in
                        keyBadge(part)
                    }
                }
            }
            Text(action.label)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textDim)
            Spacer()
        }
    }

    private func tmuxRow(_ label: String, keys: [String]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    keyBadge(key)
                }
            }
            Text(label)
                .font(Typo.caption(11))
                .foregroundColor(Palette.textDim)
            Spacer()
        }
    }

    private func keyBadge(_ key: String) -> some View {
        Text(key)
            .font(Typo.geistMonoBold(10))
            .foregroundColor(Palette.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - HotkeyAction → TilePosition mapping

extension HotkeyAction {
    var tilePosition: TilePosition? {
        switch self {
        case .tileLeft:        return .left
        case .tileRight:       return .right
        case .tileTop:         return .top
        case .tileBottom:      return .bottom
        case .tileTopLeft:     return .topLeft
        case .tileTopRight:    return .topRight
        case .tileBottomLeft:  return .bottomLeft
        case .tileBottomRight: return .bottomRight
        case .tileMaximize:    return .maximize
        case .tileCenter:      return .center
        case .tileLeftThird:   return .leftThird
        case .tileCenterThird: return .centerThird
        case .tileRightThird:  return .rightThird
        default:               return nil
        }
    }
}

// MARK: - TileZoneOverlay

/// Gray destination plate for Ctrl+Option tiling. One overlay morphs between
/// cells instead of tearing down a blue panel per chord.
final class TileZoneOverlay {
    static let shared = TileZoneOverlay()

    func show(position: TilePosition, on screen: NSScreen? = nil, autoHideAfter: TimeInterval? = nil) {
        let targetScreen = screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else { return }
        WindowHoverPreview.shared.show(frame: Self.rect(for: position, on: targetScreen), autoHideAfter: autoHideAfter, style: .frosted)
    }

    func dismiss() {
        WindowHoverPreview.shared.hide()
    }

    static func rect(for position: TilePosition, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let (fx, fy, fw, fh) = position.rect
        return NSRect(
            x: visible.origin.x + visible.width * fx,
            y: visible.origin.y + visible.height * (1 - fy - fh),
            width: visible.width * fw,
            height: visible.height * fh
        )
    }
}
