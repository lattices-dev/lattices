import AppKit
import ActionCore
import OSLog

@available(macOS 15.0, *)
@MainActor
final class RecordingProbeAppRunner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum Target {
        case region(CGRect)
        case appWindow(String)
    }

    private static var retainedRunner: RecordingProbeAppRunner?

    struct Configuration {
        let target: Target
        let outputPath: String
        let stopSignalPath: String?
        let finishedSignalPath: String?
        let frameTimingPath: String?
        let fps: Double
        let scale: Double
        let includeSupervisionOverlay: Bool
    }

    private let logger = Logger(subsystem: ActionAppIdentity.mainBundleIdentifier, category: "RecordingProbe")
    private let configuration: Configuration
    private let writer: ResponseWriter
    private let debugLogger: DebugLogger

    private var window: NSWindow?
    private var statusField: NSTextField?
    private let supervisionRegistrationID = "recording-probe-\(UUID().uuidString)"

    init(configuration: Configuration, writer: ResponseWriter, debugLogger: DebugLogger) {
        self.configuration = configuration
        self.writer = writer
        self.debugLogger = debugLogger
    }

    func run() {
        Self.retainedRunner = self
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerSupervisorStopIfNeeded()
        showWindow()
        startRecording()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActionSupervisionRegistry.unregister(id: supervisionRegistrationID)
        Self.retainedRunner = nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    private func showWindow() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = root
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.orderFrontRegardless()

        self.window = window
        self.statusField = nil
    }

    private func startRecording() {
        let configuration = self.configuration
        let writer = self.writer
        let debugLogger = self.debugLogger

        report("Starting recording probe…")

        Task { [weak self] in
            let recorder = WindowRecorder(writer: writer, logger: debugLogger)

            do {
                switch configuration.target {
                case .region(let rect):
                    try await recorder.recordRegion(
                        rect: rect,
                        outputPath: configuration.outputPath,
                        stopSignalPath: configuration.stopSignalPath,
                        finishedSignalPath: configuration.finishedSignalPath,
                        fps: configuration.fps,
                        scale: configuration.scale,
                        includeSupervisionOverlay: configuration.includeSupervisionOverlay,
                        frameTimingPath: configuration.frameTimingPath
                    )
                case .appWindow(let bundleId):
                    try await recorder.recordAppWindow(
                        bundleId: bundleId,
                        outputPath: configuration.outputPath,
                        stopSignalPath: configuration.stopSignalPath,
                        finishedSignalPath: configuration.finishedSignalPath,
                        frameTimingPath: configuration.frameTimingPath
                    )
                }

                self?.report("Finished: \(configuration.outputPath)")
                NSApplication.shared.terminate(nil)
            } catch {
                let message = error.localizedDescription
                self?.report("Failed: \(message)")
                try? writer.write(ActionHostResponse(status: "error", outputPath: configuration.outputPath, detail: message))
                if let finishedSignalPath = configuration.finishedSignalPath, !finishedSignalPath.isEmpty {
                    let finishedSignalURL = URL(fileURLWithPath: finishedSignalPath)
                    try? FileManager.default.createDirectory(
                        at: finishedSignalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? Data("error:\(message)\n".utf8).write(to: finishedSignalURL)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func report(_ message: String) {
        statusField?.stringValue = message
        logger.notice("\(message, privacy: .public)")
    }

    private func registerSupervisorStopIfNeeded() {
        guard let stopSignalPath = configuration.stopSignalPath, !stopSignalPath.isEmpty else {
            return
        }

        do {
            try ActionSupervisionRegistry.register(
                id: supervisionRegistrationID,
                title: "Stop Recording",
                detail: "Recording supervision",
                controlFile: nil,
                stopFile: stopSignalPath,
                avoidedDisplayID: fullDisplayID(for: configuration.target)
            )
        } catch {
            logger.error("Failed to register supervision stop: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fullDisplayID(for target: Target) -> UInt32? {
        guard case .region(let captureRect) = target else {
            return nil
        }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return nil
        }

        let captureArea = max(captureRect.width, 0) * max(captureRect.height, 0)
        guard captureArea > 0 else {
            return nil
        }

        return displayIDs.first { displayID in
            let displayFrame = CGDisplayBounds(displayID)
            let intersection = captureRect.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isEmpty else {
                return false
            }

            let intersectionArea = intersection.width * intersection.height
            let displayArea = displayFrame.width * displayFrame.height
            guard displayArea > 0 else {
                return false
            }

            return intersectionArea / displayArea >= 0.98
                && intersectionArea / captureArea >= 0.98
        }
    }
}
