import AppKit
import SwiftUI

/// The two privacy grants Action needs, in the order the helper walks them.
enum ActionPermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: return "Focus, click, type, read UI"
        case .screenRecording: return "Screenshots and recording"
        }
    }
}

private final class ActionPermissionHelperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A small window docked beside System Settings that walks Accessibility, then
/// Screen Recording. It carries a drag tile for the exact Action copy that is
/// running: several copies can share one bundle id, and dragging this one into
/// the list is the only way to be sure the row macOS keeps is the one that applies.
@MainActor
final class ActionPermissionHelperController {
    static let shared = ActionPermissionHelperController()

    private var panel: NSPanel?
    private let size = NSSize(width: 400, height: 288)

    private init() {}

    func show(model: ActionLauncherViewModel, focus kind: ActionPermissionKind) {
        model.permissionHelperFocus = kind
        model.openSettings(for: kind)

        let panel = panel ?? makePanel()
        panel.contentViewController = NSHostingController(
            rootView: ActionPermissionHelperView(model: model, onClose: { [weak self] in self?.close() })
        )
        panel.setContentSize(size)
        self.panel = panel

        Task { @MainActor [weak self, weak panel] in
            _ = await Self.waitForSystemSettingsFrontmost(timeout: 6)
            guard let self, let panel else { return }
            self.position(panel)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = ActionPermissionHelperPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Action permissions"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        // Stays over System Settings while the operator works in it.
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    private static func waitForSystemSettingsFrontmost(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Beside the Settings window when there is room, else on top of its corner.
    private func position(_ panel: NSPanel) {
        guard let settings = Self.systemSettingsFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) ?? NSScreen.main else {
            panel.center()
            return
        }

        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let top = min(settings.maxY, visible.maxY) - size.height
        var origin = NSPoint(x: settings.maxX + gap, y: top)
        if origin.x + size.width > visible.maxX {
            origin.x = settings.minX - gap - size.width
        }
        if origin.x < visible.minX {
            origin.x = settings.maxX - size.width - 24
            origin.y = settings.minY + 24
        }
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        panel.setFrameOrigin(origin)
    }

    /// The Settings window in AppKit coordinates (bottom-left origin).
    private static func systemSettingsFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }

        let bounds = windows
            .filter { ($0[kCGWindowOwnerName as String] as? String) == "System Settings" }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .filter { $0.width > 200 && $0.height > 200 }
            .max { $0.width * $0.height < $1.width * $1.height }

        return bounds.map { NSRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height) }
    }
}

private struct ActionPermissionHelperView: View {
    @ObservedObject var model: ActionLauncherViewModel
    let onClose: () -> Void

    private var focus: ActionPermissionKind { model.permissionHelperFocus }
    private var allGranted: Bool { ActionPermissionKind.allCases.allSatisfy(model.isGranted) }
    private var focusGranted: Bool { model.isGranted(focus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(allGranted ? "Action is ready" : "Allow Action in \(focus.title)")
                    .font(ActionType.uiSubhead)
                    .foregroundStyle(StageHUDTheme.textPrimary)
                Text(instruction)
                    .font(ActionType.uiCaption)
                    .foregroundStyle(StageHUDTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: 14) {
                ActionAppDragTile(appURL: Bundle.main.bundleURL, isEnabled: !focusGranted) {
                    model.refreshPermissions()
                }
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ActionPermissionKind.allCases) { kind in
                        stepRow(kind)
                    }
                }
            }

            Text(model.runningAppPath)
                .font(ActionType.monoCaption)
                .foregroundStyle(StageHUDTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help("The copy macOS has to allow. Another copy with the same name does not count.")

            HStack(spacing: 8) {
                if !allGranted {
                    Button("Open Settings") { model.openSettings(for: focus) }
                        .buttonStyle(ActionSettingsPillButtonStyle())
                    if focus == .screenRecording {
                        // Screen Recording is read once per process; a running agent
                        // keeps reporting denied until it restarts.
                        Button("Restart agent", action: model.restartAgentAndRefreshPermissions)
                            .buttonStyle(ActionSettingsPillButtonStyle())
                    }
                    Button("Reset", action: model.resetPermissionsAndRequest)
                        .buttonStyle(ActionSettingsPillButtonStyle())
                        .help("Clears every saved Action row, including ones for other copies, and asks again.")
                }
                Spacer(minLength: 0)
                Button(allGranted ? "Done" : "Close", action: onClose)
                    .buttonStyle(ActionSettingsPillButtonStyle(primary: allGranted))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StageHUDTheme.appBackground)
        .task {
            // Accessibility changes are visible right away; poll until both are in.
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: model.accessibilityStatus) { _, _ in advanceIfGranted() }
        .onChange(of: model.screenRecordingStatus) { _, _ in advanceIfGranted() }
    }

    private var instruction: String {
        if allGranted {
            return "Both permissions are on. You can close this window."
        }
        if focusGranted {
            return "\(focus.title) is on."
        }
        return "Drag the Action icon into the list in System Settings, then switch it on. If Action is already listed, remove it with − first."
    }

    private func stepRow(_ kind: ActionPermissionKind) -> some View {
        let granted = model.isGranted(kind)
        let current = kind == focus && !allGranted
        return Button {
            model.permissionHelperFocus = kind
            model.openSettings(for: kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(ActionIcon.small)
                    .foregroundStyle(granted ? StageHUDTheme.runOk : StageHUDTheme.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                        .font(ActionType.uiBodyStrong)
                        .foregroundStyle(current ? StageHUDTheme.textPrimary : StageHUDTheme.textSecondary)
                    Text(granted ? "Allowed" : kind.detail)
                        .font(ActionType.uiCaption)
                        .foregroundStyle(StageHUDTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? StageHUDTheme.runSelection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Moves to the next missing permission and opens its pane, so the operator
    /// never has to find it in Settings.
    private func advanceIfGranted() {
        guard model.isGranted(focus),
              let next = ActionPermissionKind.allCases.first(where: { !model.isGranted($0) }) else {
            return
        }
        model.permissionHelperFocus = next
        model.openSettings(for: next)
    }
}

/// A drag source for the running Action.app. Dropping it on a privacy list in
/// System Settings adds this exact copy.
struct ActionAppDragTile: NSViewRepresentable {
    let appURL: URL
    let isEnabled: Bool
    var onDragEnded: () -> Void = {}

    func makeNSView(context: Context) -> ActionAppDragTileView {
        ActionAppDragTileView(appURL: appURL, isEnabled: isEnabled, onDragEnded: onDragEnded)
    }

    func updateNSView(_ view: ActionAppDragTileView, context: Context) {
        view.appURL = appURL
        view.isEnabled = isEnabled
        view.onDragEnded = onDragEnded
    }
}

final class ActionAppDragTileView: NSView, NSDraggingSource {
    var appURL: URL { didSet { needsDisplay = true } }
    var isEnabled: Bool { didSet { toolTip = isEnabled ? "Drag into System Settings" : nil; window?.invalidateCursorRects(for: self); needsDisplay = true } }
    var onDragEnded: () -> Void

    private var mouseDownLocation: NSPoint?

    init(appURL: URL, isEnabled: Bool, onDragEnded: @escaping () -> Void) {
        self.appURL = appURL
        self.isEnabled = isEnabled
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        toolTip = isEnabled ? "Drag into System Settings" : nil
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var icon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(StageHUDTheme.cardFill).setFill()
        path.fill()
        if isEnabled {
            var dash: [CGFloat] = [4, 3]
            path.setLineDash(&dash, count: dash.count, phase: 0)
        }
        NSColor(isEnabled ? StageHUDTheme.hudAmber : StageHUDTheme.cardBorder).setStroke()
        path.lineWidth = 1
        path.stroke()

        let side = min(bounds.width, bounds.height) * 0.56
        let iconRect = NSRect(x: (bounds.width - side) / 2, y: 10, width: side, height: side)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let label = NSAttributedString(string: isEnabled ? "Drag me" : "Allowed", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(isEnabled ? StageHUDTheme.hudAmber : StageHUDTheme.runOk),
            .paragraphStyle: style,
        ])
        label.draw(in: NSRect(x: 0, y: bounds.height - 20, width: bounds.width, height: 14))
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = isEnabled ? convert(event.locationInWindow, from: nil) : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        mouseDownLocation = nil

        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let side: CGFloat = 64
        item.setDraggingFrame(NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded()
    }
}
