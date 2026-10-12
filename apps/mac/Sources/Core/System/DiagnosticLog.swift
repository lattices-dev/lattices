import AppKit
import Combine
import HudsonObservability
import HudsonUI
import SwiftUI

// MARK: - Log Store (HudLogStore facade)

final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()

    struct Entry: Identifiable {
        let id: UUID
        let time: Date
        let message: String
        let level: Level

        enum Level: String { case info, success, warning, error }

        var icon: String {
            switch level {
            case .info:    return "›"
            case .success: return "✓"
            case .warning: return "⚠"
            case .error:   return "✗"
            }
        }

        init(hud: HudLogEntry) {
            id = hud.id
            time = hud.timestamp
            message = hud.message
            level = Level(hud: hud)
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let logger = HudLogger(subsystem: "dev.lattices.app", category: "diagnostic")
    private var cancellables = Set<AnyCancellable>()

    private init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            HudLogStore.shared.$entries
                .receive(on: DispatchQueue.main)
                .map { $0.map(Entry.init(hud:)) }
                .sink { [weak self] mapped in
                    self?.entries = mapped
                }
                .store(in: &self.cancellables)
        }
    }

    func log(_ message: String, level: Entry.Level = .info) {
        logger.log(level.hudLevel, message, metadata: level.hudMetadata)
    }

    func info(_ msg: String)    { log(msg, level: .info) }
    func success(_ msg: String) { log(msg, level: .success) }
    func warn(_ msg: String)    { log(msg, level: .warning) }
    func error(_ msg: String)   { log(msg, level: .error) }
    func clear() {
        Task { @MainActor in
            HudLogStore.shared.clear()
        }
    }

    // MARK: - Per-Action Timing

    struct TimedAction {
        let label: String
        let start: Date
    }

    func startTimed(_ label: String) -> TimedAction {
        info("▸ \(label)")
        return TimedAction(label: label, start: Date())
    }

    func finish(_ action: TimedAction) {
        let ms = Date().timeIntervalSince(action.start) * 1000
        success("▸ \(action.label) — \(String(format: "%.0f", ms))ms")
    }

    func fail(_ action: TimedAction, message: String? = nil) {
        let ms = Date().timeIntervalSince(action.start) * 1000
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix = detail.isEmpty ? "" : "\n\(detail)"
        error("▸ \(action.label) failed — \(String(format: "%.0f", ms))ms\(suffix)")
    }
}

private extension DiagnosticLog.Entry.Level {
    init(hud: HudLogEntry) {
        if hud.metadata["outcome"] == "success" {
            self = .success
            return
        }
        switch hud.level {
        case .warning:
            self = .warning
        case .error, .fault:
            self = .error
        default:
            self = .info
        }
    }

    var hudLevel: HudLogLevel {
        switch self {
        case .info: return .info
        case .success: return .notice
        case .warning: return .warning
        case .error: return .error
        }
    }

    var hudMetadata: [String: String] {
        switch self {
        case .success: return ["outcome": "success"]
        default: return [:]
        }
    }
}

// MARK: - Interaction Feedback

final class AppFeedback {
    static let shared = AppFeedback()

    private lazy var tapSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "tap", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()
    private var didWarmTapSound = false

    private init() {}

    @discardableResult
    func beginTimed(_ label: String, state: HUDState? = nil, feedback: String? = nil, playSound: Bool = true) -> DiagnosticLog.TimedAction {
        if playSound {
            playTap()
        }
        if let feedback, let state {
            state.showFeedback(feedback)
        }
        return DiagnosticLog.shared.startTimed(label)
    }

    func finish(_ action: DiagnosticLog.TimedAction, state: HUDState? = nil, feedback: String? = nil) {
        if let feedback, let state {
            state.showFeedback(feedback)
        }
        DiagnosticLog.shared.finish(action)
    }

    func acknowledge(_ label: String, state: HUDState? = nil, feedback: String? = nil, playSound: Bool = true) {
        if playSound {
            playTap()
        }
        if let feedback, let state {
            state.showFeedback(feedback)
        }
        DiagnosticLog.shared.info(label)
    }

    func playTapSound() {
        playTap()
    }

    func warmUp() {
        runOnMain { self.warmUpTapSoundOnMain() }
    }

    func warmUpTapSound() {
        warmUp()
    }

    func commitTactile() {
        runOnMain {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.playPreparedTapOnMain()
        }
    }
    /// Aim-change detent for the Ctrl+Option tile pointer: gentle trackpad
    /// tap plus a quiet synthesized tick.
    func aimTick() {
        runOnMain {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            CursorSoundPlayer.shared.play(.tick)
        }
    }

    /// Confirmation feedback without the prepared tap sound. Spatial Lens is
    /// continuous and pointer-led, so an audible commit tick is unnecessarily
    /// noisy while a subtle physical acknowledgement remains useful.
    func commitHaptic() {
        runOnMain {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func playTap() {
        DispatchQueue.main.async {
            self.tapSound?.stop()
            self.tapSound?.play()
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func warmUpTapSoundOnMain() {
        guard !didWarmTapSound, let sound = tapSound else { return }
        didWarmTapSound = true
        let volume = sound.volume
        sound.volume = 0
        sound.currentTime = 0
        sound.play()
        sound.stop()
        sound.currentTime = 0
        sound.volume = volume
    }

    private func playPreparedTapOnMain() {
        guard let sound = tapSound else { return }
        sound.currentTime = 0
        sound.play()
    }
}

// MARK: - Synthesized Feedback Sounds

/// Tiny synthesized WAV player for UI ticks/clicks — no bundle resources,
/// tones are generated in code and played at low volume.
final class CursorSoundPlayer {
    static let shared = CursorSoundPlayer()

    private var activeSounds: [NSSound] = []
    private let sampleRate = 44_100

    func play(_ style: CursorSoundStyle) {
        guard style != .none else { return }
        let data = wavData(for: style)
        guard let sound = NSSound(data: data) else { return }
        sound.volume = volume(for: style)
        activeSounds.append(sound)
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak sound] in
            guard let sound else { return }
            self?.activeSounds.removeAll { $0 === sound }
        }
    }

    private func volume(for style: CursorSoundStyle) -> Float {
        switch style {
        case .none:
            return 0
        case .tick:
            return 0.22
        case .click:
            return 0.26
        case .engage:
            return 0.32
        case .chime:
            return 0.30
        }
    }

    private func wavData(for style: CursorSoundStyle) -> Data {
        let tones: [(frequency: Double, start: Double, duration: Double, amplitude: Double)]
        let duration: Double
        switch style {
        case .none:
            tones = []
            duration = 0.01
        case .tick:
            tones = [(920, 0.00, 0.055, 0.28)]
            duration = 0.08
        case .click:
            tones = [(1240, 0.00, 0.032, 0.34), (540, 0.018, 0.055, 0.18)]
            duration = 0.09
        case .engage:
            tones = [(420, 0.00, 0.11, 0.20), (760, 0.055, 0.13, 0.24), (1160, 0.12, 0.06, 0.12)]
            duration = 0.22
        case .chime:
            tones = [(620, 0.00, 0.18, 0.18), (930, 0.03, 0.20, 0.16)]
            duration = 0.25
        }

        let sampleCount = max(1, Int(duration * Double(sampleRate)))
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            var value = 0.0
            for tone in tones {
                guard t >= tone.start, t <= tone.start + tone.duration else { continue }
                let local = (t - tone.start) / tone.duration
                let attack = min(1.0, local / 0.16)
                let decay = pow(max(0.0, 1.0 - local), 1.8)
                let envelope = attack * decay
                value += sin(2 * Double.pi * tone.frequency * t) * tone.amplitude * envelope
                value += sin(2 * Double.pi * tone.frequency * 2.01 * t) * tone.amplitude * envelope * 0.12
            }
            let clipped = max(-1.0, min(1.0, value))
            samples.append(Int16(clipped * Double(Int16.max)))
        }

        return wavData(samples: samples)
    }

    private func wavData(samples: [Int16]) -> Data {
        var data = Data()
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let byteRate = UInt32(sampleRate * MemoryLayout<Int16>.size)
        let blockAlign = UInt16(MemoryLayout<Int16>.size)

        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(byteRate)
        data.appendUInt16LE(blockAlign)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(dataSize)
        for sample in samples {
            data.appendInt16LE(sample)
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt16LE(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - Diagnostic Window

final class DiagnosticWindow {
    static let shared = DiagnosticWindow()

    private var window: NSWindow?
    private var keyMonitor: Any?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if let w = window, w.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        AppDelegate.updateActivationPolicy()
    }

    func show() {
        if let w = window {
            AppWindowShell.present(w)
            return
        }

        let view = DiagnosticWindowRootView(onClose: { [weak self] in
            self?.dismiss()
        })

        let screen = NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = max(600, floor(screenFrame.height * 0.55))

        let w = AppWindowShell.makeWindow(
            config: .init(
                title: "Lattices Activity Log",
                initialSize: NSSize(width: panelWidth, height: panelHeight),
                minSize: NSSize(width: 420, height: 360)
            ),
            rootView: view
        )

        let x = screenFrame.maxX - panelWidth - 12
        let y = screenFrame.minY + floor((screenFrame.height - panelHeight) / 2)
        w.setFrameOrigin(NSPoint(x: x, y: y))

        AppWindowShell.present(w)
        window = w

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let win = self?.window,
                  event.window === win || win.isKeyWindow else { return event }
            self?.dismiss()
            return nil
        }

        let diag = DiagnosticLog.shared
        diag.info("Activity Log opened")
        diag.info("Terminal: \(Preferences.shared.terminal.rawValue) (\(Preferences.shared.terminal.bundleId))")
        diag.info("Installed: \(Terminal.installed.map(\.rawValue).joined(separator: ", "))")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: TmuxQuery.resolvedPath ?? "/opt/homebrew/bin/tmux")
        task.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let sessions = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
        diag.info("tmux sessions: \(sessions)")
    }
}

private struct DiagnosticWindowRootView: View {
    let onClose: () -> Void

    var body: some View {
        HudLoggerPanel(title: "Activity Log", onClose: onClose)
    }
}
