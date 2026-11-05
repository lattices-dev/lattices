import ActionCore
import AppKit
import Foundation
import ScreenCaptureKit

/// Long-lived synthetic agent cursor for drive leases.
///
/// Stays up until the stop file appears. A state JSON steers position and click
/// flashes. Motion follows a bounded arc with a smooth launch and arrival,
/// a short trail while traveling, and a subtle balance sway while parked.
struct AgentCursorState: Codable, Equatable {
    var x: Double?
    var y: Double?
    /// `appkit` (legacy/default) or `quartz`. Quartz input is converted once at the overlay edge.
    var coordinateSpace: String?
    /// auto (default), light, or dark scene treatment.
    var appearance: String?
    var agent: String?
    var label: String?
    /// `idle` | `click` | `type` | `key` | `countdown`
    var phase: String?
    /// Full string for type cues; revealed over time with key sounds.
    var typingText: String?
    /// Single key / chord label for press-key cues.
    var keyLabel: String?
    /// Seconds remaining in a pre-focus warning (3, 2, 1).
    var countdown: Int?
    /// Unique per act so repeated clicks/types re-trigger sound + visuals.
    var cueId: String?
    /// Optional region the cursor is presenting — same coordinate space as `x`/`y`.
    var highlight: AgentCursorHighlight?
    /// Renewable deadline after which this detached overlay releases itself.
    var expiresAt: String?
    var updatedAt: String?
}

struct AgentCursorHighlight: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

private struct TrailSample {
    var point: CGPoint
    var at: TimeInterval
}

@MainActor
final class AgentCursorOverlayController: NSObject {
    private let stateFile: String
    private let stopFile: String
    private let leaseStopFile: String?
    private let writer: ResponseWriter
    private let logger: DebugLogger
    private var overlayWindow: NSWindow?
    private var overlayView: AgentCursorOverlayView?
    private var pollTimer: Timer?
    private var displayTimer: Timer?
    private var lastStateData: Data?
    private var state = AgentCursorState(phase: "idle")

    private var targetPoint: CGPoint?
    private var travelPoint: CGPoint?
    private var moveOrigin: CGPoint?
    private var moveControl: CGPoint?
    private var moveStartedAt: TimeInterval?
    private var moveDuration: TimeInterval = 0.28
    private var isTraveling = false

    private var clickStartedAt: Date?
    private var typingStartedAt: Date?
    private var typingFullText: String = ""
    private var typingRevealCount: Int = 0
    private var nextTypingSoundAt: TimeInterval = 0
    private var lastCueId: String?
    private var lastCountdownValue: Int?
    private let soundPlayer = DemoCueSoundPlayer()
    private let startedAt = Date()
    private var trail: [TrailSample] = []
    private var lastFrameAt: TimeInterval = 0
    private var lastAppearanceSampleAt: TimeInterval = -1
    private var appearanceSampleInFlight = false
    private var appearanceContent: SCShareableContent?
    private var appearanceContentAt: TimeInterval = -10
    private var darkScene = false
    private var appearanceBlend: CGFloat = 0
    /// Last moment the cursor moved or played a cue; the badge hides shortly after.
    private var lastActivityAt: TimeInterval = 0
    /// Start of a "find me" ripple, requested by the supervision HUD or menu bar.
    private var locateStartedAt: TimeInterval?
    private static let locateDuration: TimeInterval = 1.6
    private static let idleExpirySeconds: TimeInterval = 90
    private static let iso8601Format = Date.ISO8601FormatStyle()
    private static let fractionalISO8601Format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Rest pose of a real pointer: from the lower-right, tip toward upper-left.
    /// Steeper than vertical so it never reads as a rocket.
    private let brandLean: CGFloat = -38.0 * .pi / 180.0
    /// Extra motion on top of the rest pose — idle breath, arrival settle, click strike.
    private var leanAngle: CGFloat = 0
    private var leanVelocity: CGFloat = 0
    private var pendingClick = false
    private var settleUntil: TimeInterval = 0

    init(
        stateFile: String,
        stopFile: String,
        leaseStopFile: String?,
        replyFile: String?,
        debugLogPath: String?
    ) {
        self.stateFile = stateFile
        self.stopFile = stopFile
        self.leaseStopFile = leaseStopFile
        self.writer = ResponseWriter(replyFile: replyFile)
        self.logger = DebugLogger(path: debugLogPath)
    }

    /// Marker written beside the state file by whoever wants the cursor to announce itself.
    private var locateFile: String { stateFile + ".locate" }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: stateFile).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A marker left over from a previous overlay must not fire on launch.
        try? FileManager.default.removeItem(atPath: locateFile)

        if !FileManager.default.fileExists(atPath: stateFile) {
            let seed = AgentCursorState(
                x: nil,
                y: nil,
                agent: "Agent",
                // No resting label: the cursor parks clean and badges only while active.
                label: nil,
                phase: "idle",
                expiresAt: Date().addingTimeInterval(Self.idleExpirySeconds).formatted(Self.fractionalISO8601Format),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            try JSONEncoder().encode(seed).write(to: URL(fileURLWithPath: stateFile))
        }

        try writer.write(
            ActionHostResponse(
                status: "agent-cursor-overlay-running",
                outputPath: nil,
                detail: String(ProcessInfo.processInfo.processIdentifier)
            )
        )
        logger.log(
            "agent-cursor: started pid=\(ProcessInfo.processInfo.processIdentifier) state=\(stateFile) leaseStop=\(leaseStopFile ?? "none")"
        )

        reloadState(force: true)
        ensureWindow()
        startPolling()
        startDisplayLoop()
        app.run()
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startDisplayLoop() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderFrame()
            }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        if FileManager.default.fileExists(atPath: stopFile) {
            shutdown(reason: "cursor-stop-file")
            return
        }
        if let leaseStopFile,
           FileManager.default.fileExists(atPath: leaseStopFile) {
            shutdown(reason: "lease-stop-file")
            return
        }
        reloadState(force: false)
        if FileManager.default.fileExists(atPath: locateFile) {
            try? FileManager.default.removeItem(atPath: locateFile)
            beginLocate()
        }
        if stateIsExpired(at: Date()) {
            shutdown(reason: "idle-expiry")
        }
    }

    /// Ripple outward from the wedge and show the badge so a parked cursor is easy to spot.
    private func beginLocate() {
        let now = Date().timeIntervalSince(startedAt)
        locateStartedAt = now
        lastActivityAt = now
        logger.log("agent-cursor: locate requested")
    }

    private func reloadState(force: Bool) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFile)) else {
            return
        }
        if !force, data == lastStateData {
            return
        }
        guard let decoded = try? JSONDecoder().decode(AgentCursorState.self, from: data) else {
            return
        }
        lastStateData = data
        let previous = state
        state = decoded

        let nextTarget = resolvePoint(from: decoded)
        let previousTarget = targetPoint
        targetPoint = nextTarget
        if travelPoint == nil {
            travelPoint = nextTarget
            moveOrigin = nextTarget
            isTraveling = false
        } else if previousTarget == nil
            || hypot(nextTarget.x - (previousTarget?.x ?? nextTarget.x),
                     nextTarget.y - (previousTarget?.y ?? nextTarget.y)) > 1.5 {
            beginMove(to: nextTarget)
        }

        handleCueTransition(from: previous, to: decoded)
    }

    private func handleCueTransition(from previous: AgentCursorState, to decoded: AgentCursorState) {
        let phase = (decoded.phase ?? "idle").lowercased()
        let cueChanged = decoded.cueId != nil && decoded.cueId != lastCueId
        let phaseChanged = (previous.phase ?? "").lowercased() != phase
            || previous.typingText != decoded.typingText
            || previous.keyLabel != decoded.keyLabel
            || cueChanged

        guard phaseChanged || cueChanged else {
            return
        }
        lastActivityAt = Date().timeIntervalSince(startedAt)
        if let cueId = decoded.cueId {
            lastCueId = cueId
        }

        switch phase {
        case "countdown":
            let value = decoded.countdown ?? 0
            if value != lastCountdownValue, value > 0 {
                lastCountdownValue = value
                // Soft tick each second of the pre-focus warning.
                soundPlayer.playClick()
            }
            clickStartedAt = nil
            typingStartedAt = nil
        case "click":
            typingStartedAt = nil
            typingFullText = ""
            typingRevealCount = 0
            lastCountdownValue = nil
            if isTraveling {
                pendingClick = true
            } else {
                fireClickCue()
            }
        case "type":
            let text = decoded.typingText ?? decoded.label ?? ""
            typingFullText = text
            typingRevealCount = 0
            typingStartedAt = Date()
            nextTypingSoundAt = 0
            clickStartedAt = nil
            lastCountdownValue = nil
            if !text.isEmpty {
                // First keytick immediately so type cues never feel silent.
                soundPlayer.playTyping()
                typingRevealCount = min(1, text.count)
                nextTypingSoundAt = 0.07
            }
        case "key":
            clickStartedAt = Date()
            typingStartedAt = Date()
            typingFullText = decoded.keyLabel ?? decoded.label ?? "key"
            typingRevealCount = typingFullText.count
            lastCountdownValue = nil
            soundPlayer.playClick()
        default:
            lastCountdownValue = nil
            break
        }
    }

    private func fireClickCue() {
        clickStartedAt = Date()
        settleUntil = Date().timeIntervalSince(startedAt) + 0.28
        soundPlayer.playClick()
    }

    private func beginMove(to target: CGPoint) {
        let from = travelPoint ?? target
        moveOrigin = from
        targetPoint = target
        let distance = hypot(target.x - from.x, target.y - from.y)
        // Small corrections stay direct. Longer travel traces a gentle bow,
        // with a reproducible side chosen from the dominant direction.
        let dx = target.x - from.x
        let dy = target.y - from.y
        let bend = min(110, max(0, (distance - 35) * 0.18))
        let side: CGFloat = abs(dx) >= abs(dy) ? (dx >= 0 ? 1 : -1) : (dy >= 0 ? -1 : 1)
        var control = CGPoint(x: (from.x + target.x) / 2 - dy / max(1, distance) * bend * side,
                              y: (from.y + target.y) / 2 + dx / max(1, distance) * bend * side)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(from) && $0.frame.contains(target) }) {
            control.x = min(screen.frame.maxX, max(screen.frame.minX, control.x))
            control.y = min(screen.frame.maxY, max(screen.frame.minY, control.y))
        }
        moveControl = control
        moveDuration = min(0.78, max(0.18, 0.20 + Double(distance) / 1700.0))
        moveStartedAt = Date().timeIntervalSince(startedAt)
        isTraveling = distance > 0.8
        if isTraveling {
            trail.removeAll(keepingCapacity: true)
            trail.append(TrailSample(point: from, at: moveStartedAt ?? 0))
        }
    }

    private func resolvePoint(from state: AgentCursorState) -> CGPoint {
        if let x = state.x, let y = state.y, x.isFinite, y.isFinite {
            if state.coordinateSpace?.lowercased() == "quartz" {
                let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
                return CGPoint(x: x, y: mainDisplayHeight - y)
            }
            return CGPoint(x: x, y: y)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(
            x: frame.origin.x + frame.width * 0.72,
            y: frame.origin.y + frame.height * 0.62
        )
    }

    private func ensureWindow() {
        let point = travelPoint ?? resolvePoint(from: state)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            return
        }

        if let existing = overlayWindow, existing.screen == screen {
            return
        }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        let view = AgentCursorOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        panel.orderFrontRegardless()

        overlayWindow?.orderOut(nil)
        overlayWindow = panel
        overlayView = view
    }

    private func renderFrame() {
        ensureWindow()
        guard let screen = overlayWindow?.screen ?? NSScreen.main else {
            return
        }

        let now = Date().timeIntervalSince(startedAt)
        let dt = lastFrameAt > 0 ? min(0.05, now - lastFrameAt) : 1.0 / 60.0
        lastFrameAt = now

        var speed: CGFloat = 0
        if let target = targetPoint, let origin = moveOrigin, let t0 = moveStartedAt, isTraveling {
            let u = (now - t0) / max(0.001, moveDuration)
            if u >= 1 {
                travelPoint = target
                isTraveling = false
                speed = 0
                settleUntil = now + 0.32
                if pendingClick {
                    pendingClick = false
                    fireClickCue()
                }
            } else {
                let control = moveControl ?? origin
                let position = ActionPointerMotion.point(from: origin, control: control, to: target, progress: u)
                let prevU = max(0, (now - dt - t0) / max(0.001, moveDuration))
                let prev = ActionPointerMotion.point(from: origin, control: control, to: target, progress: prevU)
                travelPoint = position
                speed = CGFloat(hypot(position.x - prev.x, position.y - prev.y) / max(dt, 0.001))
                trail.append(TrailSample(point: position, at: now))
            }
        } else if let target = targetPoint {
            travelPoint = target
        }

        // A short trail makes the trajectory legible without obscuring the UI.
        let trailHorizon = now - 0.14
        trail.removeAll { $0.at < trailHorizon }

        guard let global = travelPoint else {
            return
        }

        let travelDamping: CGFloat = isTraveling ? 0.18 : 1.0
        stepBalance(dt: dt, amplitude: travelDamping)

        updateAppearance(at: global, now: now)
        let appearanceTarget: CGFloat = darkScene ? 1 : 0
        appearanceBlend += (appearanceTarget - appearanceBlend) * min(1, CGFloat(dt) * 8)

        // Brand lean is the resting pose; bicycle micro-sway rides on top.
        let lean = brandLean + leanAngle
        let local = CGPoint(
            x: global.x - screen.frame.origin.x,
            y: global.y - screen.frame.origin.y
        )

        let localTrail = trail.map { sample -> CGPoint in
            CGPoint(
                x: sample.point.x - screen.frame.origin.x,
                y: sample.point.y - screen.frame.origin.y
            )
        }

        var clickProgress: CGFloat?
        if let clickStartedAt {
            let elapsed = Date().timeIntervalSince(clickStartedAt)
            if elapsed < 0.34 {
                clickProgress = CGFloat(elapsed / 0.34)
            } else if (state.phase ?? "").lowercased() != "key" {
                self.clickStartedAt = nil
            }
        }

        // Reveal typing text + key ticks over ~55ms per character (capped).
        var typingVisible: String?
        var showCaret = false
        if let typingStartedAt, !typingFullText.isEmpty {
            let elapsed = Date().timeIntervalSince(typingStartedAt)
            let perChar = 0.055
            let targetCount = min(typingFullText.count, max(1, Int(elapsed / perChar) + 1))
            while typingRevealCount < targetCount {
                typingRevealCount += 1
                if Date().timeIntervalSince(startedAt) >= nextTypingSoundAt {
                    soundPlayer.playTyping()
                    nextTypingSoundAt = Date().timeIntervalSince(startedAt) + 0.048
                }
            }
            let end = typingFullText.index(typingFullText.startIndex, offsetBy: typingRevealCount)
            typingVisible = String(typingFullText[..<end])
            showCaret = typingRevealCount < typingFullText.count
                || elapsed < Double(typingFullText.count) * perChar + 0.35
            if elapsed > Double(typingFullText.count) * perChar + 1.2 {
                // Keep final text on badge briefly, then clear local typing anim.
                if elapsed > Double(typingFullText.count) * perChar + 2.4 {
                    self.typingStartedAt = nil
                }
            }
        }

        let phase = (state.phase ?? "idle").lowercased()
        let badgeLabel: String? = {
            if phase == "countdown", let n = state.countdown, n > 0 {
                return "pointer in \(n)…"
            }
            if phase == "type", let typingVisible, !typingVisible.isEmpty {
                return typingVisible
            }
            if phase == "key" {
                return state.keyLabel ?? state.label
            }
            if phase == "click" {
                return state.label ?? "click"
            }
            return nil
        }()

        if isTraveling || speed > 1 {
            lastActivityAt = now
        }

        var locateProgress: CGFloat?
        if let locateStartedAt {
            let elapsed = now - locateStartedAt
            if elapsed < Self.locateDuration {
                locateProgress = CGFloat(elapsed / Self.locateDuration)
                // Keep the badge up for the whole ripple.
                lastActivityAt = now
            } else {
                self.locateStartedAt = nil
            }
        }

        var localHighlight: CGRect?
        if let box = state.highlight, box.width > 4, box.height > 4 {
            localHighlight = CGRect(
                x: box.x - screen.frame.origin.x,
                y: box.y - screen.frame.origin.y,
                width: box.width,
                height: box.height
            )
        }
        overlayView?.model = AgentCursorRenderModel(
            point: local,
            trail: localTrail,
            agent: state.agent ?? "Agent",
            label: badgeLabel,
            badgeVisible: phase != "idle" || now - lastActivityAt < 2.0,
            clickProgress: clickProgress,
            leanAngle: lean,
            speed: speed,
            isTraveling: isTraveling,
            typingVisible: typingVisible,
            showCaret: showCaret,
            isKeyCue: phase == "key",
            countdown: phase == "countdown" ? state.countdown : nil,
            darkSceneBlend: appearanceBlend,
            highlight: localHighlight,
            locateProgress: locateProgress
        )
        overlayView?.needsDisplay = true
    }

    /// Exclude this overlay from sampling so our glow cannot feed back into
    /// the scene decision. Keep the last treatment when capture is unavailable.
    private func updateAppearance(at point: CGPoint, now: TimeInterval) {
        if state.appearance == "light" { darkScene = false; return }
        if state.appearance == "dark" { darkScene = true; return }
        guard now - lastAppearanceSampleAt >= 0.35 else { return }
        lastAppearanceSampleAt = now
        guard #available(macOS 14.0, *), !appearanceSampleInFlight,
              CGPreflightScreenCaptureAccess(), let window = overlayWindow else { return }
        appearanceSampleInFlight = true
        let windowID = CGWindowID(window.windowNumber)
        let quartz = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.appearanceSampleInFlight = false }
            do {
                if self.appearanceContent == nil || now - self.appearanceContentAt > 3 {
                    self.appearanceContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    self.appearanceContentAt = now
                }
                guard let content = self.appearanceContent,
                      let display = content.displays.first(where: { $0.frame.contains(quartz) }),
                      let ownWindow = content.windows.first(where: { $0.windowID == windowID }) else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [ownWindow])
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: quartz.x - display.frame.minX - 20,
                    y: quartz.y - display.frame.minY - 20, width: 40, height: 40)
                    .intersection(CGRect(origin: .zero, size: display.frame.size))
                config.width = 8
                config.height = 8
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // An explicit scene override may have arrived during capture.
                guard self.state.appearance == nil || self.state.appearance == "auto",
                      let current = self.travelPoint, hypot(current.x - point.x, current.y - point.y) < 50 else { return }
                var pixel = [UInt8](repeating: 0, count: 4)
                let sampled = pixel.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return true
                }
                guard sampled else { return }
                let brightness = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
                if brightness < 0.40 { self.darkScene = true }
                else if brightness > 0.62 { self.darkScene = false }
            } catch {
                // Keep the last readable treatment if permission/capture changes.
                self.appearanceContent = nil
            }
        }
    }

    private func stepBalance(dt: TimeInterval, amplitude: CGFloat) {
        let now = Date().timeIntervalSince(startedAt)
        let t = now
        // Idle breath plus a quicker fidget — reads as attention, not a screensaver.
        let noise = sin(t * 1.15) * 0.72 + sin(t * 2.4 + 0.6) * 0.38 + sin(t * 4.1 + 1.1) * 0.16
        var drive = CGFloat(noise) * 1.25 * amplitude
        if now < settleUntil {
            let remaining = settleUntil - now
            drive += sin((0.32 - remaining) * 18) * 0.22 * CGFloat(remaining / 0.32)
        }
        let spring: CGFloat = 16.0
        let damping: CGFloat = 4.8
        let accel = -spring * leanAngle - damping * leanVelocity + drive
        leanVelocity += accel * CGFloat(dt)
        leanAngle += leanVelocity * CGFloat(dt)
        leanAngle = min(0.14, max(-0.14, leanAngle))
    }

    private func stateIsExpired(at now: Date) -> Bool {
        if let expiresAt = state.expiresAt,
           let deadline = Self.parseISO8601Date(expiresAt) {
            return deadline <= now
        }
        if let updatedAt = state.updatedAt,
           let lastUpdate = Self.parseISO8601Date(updatedAt) {
            return now.timeIntervalSince(lastUpdate) >= Self.idleExpirySeconds
        }
        return now.timeIntervalSince(startedAt) >= Self.idleExpirySeconds
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        (try? Date(raw, strategy: fractionalISO8601Format))
            ?? (try? Date(raw, strategy: iso8601Format))
    }

    private func shutdown(reason: String) {
        logger.log("agent-cursor: shutdown pid=\(ProcessInfo.processInfo.processIdentifier) reason=\(reason)")
        pollTimer?.invalidate()
        displayTimer?.invalidate()
        overlayWindow?.orderOut(nil)
        try? FileManager.default.removeItem(atPath: stateFile)
        try? FileManager.default.removeItem(atPath: stopFile)
        NSApplication.shared.terminate(nil)
    }
}

struct AgentCursorRenderModel {
    var point: CGPoint
    var trail: [CGPoint]
    var agent: String
    var label: String?
    /// False once the cursor has been parked idle briefly — badges show while
    /// active and hide at rest so a long computer-use session stays quiet.
    var badgeVisible: Bool
    var clickProgress: CGFloat?
    var leanAngle: CGFloat
    var speed: CGFloat
    var isTraveling: Bool
    var typingVisible: String?
    var showCaret: Bool
    var isKeyCue: Bool
    var countdown: Int?
    var darkSceneBlend: CGFloat = 0
    var highlight: CGRect?
    /// 0…1 while a "find me" ripple plays; nil otherwise.
    var locateProgress: CGFloat?
}

final class AgentCursorOverlayView: NSView {
    // Brand tokens aligned with StageHUDTheme (coral / paper / canvas).
    private static let brandCoral = NSColor(calibratedRed: 0.937, green: 0.416, blue: 0.278, alpha: 1)
    private static let brandCoralHot = NSColor(calibratedRed: 1.0, green: 0.49, blue: 0.32, alpha: 1)
    private static let brandPaper = NSColor(calibratedRed: 0.953, green: 0.922, blue: 0.867, alpha: 1)
    private static let brandCanvas = NSColor(calibratedRed: 0.055, green: 0.071, blue: 0.074, alpha: 0.88)

    var model: AgentCursorRenderModel?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else {
            return
        }

        drawTrail(model.trail, head: model.point, speed: model.speed)
        if let highlight = model.highlight {
            drawHighlight(highlight)
        }
        if let countdown = model.countdown, countdown > 0 {
            drawCountdown(at: model.point, value: countdown, lean: model.leanAngle)
        }
        if let clickProgress = model.clickProgress {
            drawClickRing(at: model.point, progress: clickProgress)
        }
        if let locateProgress = model.locateProgress {
            drawLocateRings(at: model.point, progress: locateProgress)
        }
        drawTriangle(at: model.point, lean: model.leanAngle)
        if let typing = model.typingVisible, !typing.isEmpty, !model.isKeyCue {
            drawTypingCaption(near: model.point, text: typing, showCaret: model.showCaret, lean: model.leanAngle)
        }
        if model.isKeyCue, let key = model.label, !key.isEmpty {
            drawKeyCap(near: model.point, key: key, lean: model.leanAngle)
        }
        drawBadge(near: model.point, agent: model.agent, label: model.label, visible: model.badgeVisible, lean: model.leanAngle)
    }

    private func drawCountdown(at point: CGPoint, value: Int, lean: CGFloat) {
        // Amber warning halo — attention is about to take the real pointer.
        let pulse = 0.55 + 0.45 * abs(sin(Date().timeIntervalSince1970 * 4.0))
        let radius = CGFloat(28 + 6 * pulse)
        let halo = NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        NSColor(calibratedRed: 0.894, green: 0.725, blue: 0.412, alpha: 0.14 + 0.10 * pulse).setFill()
        halo.fill()
        NSColor(calibratedRed: 0.894, green: 0.725, blue: 0.412, alpha: 0.55).setStroke()
        halo.lineWidth = 2.0
        halo.stroke()

        let font = NSFont.systemFont(ofSize: 34, weight: .bold)
        let text = "\(value)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.90, blue: 0.62, alpha: 0.96),
            .kern: -0.5,
        ]
        let size = text.size(withAttributes: attrs)
        let origin = CGPoint(
            x: point.x - size.width / 2 + lean * 6,
            y: point.y + 22
        )

        let plate = CGRect(
            x: origin.x - 10,
            y: origin.y - 4,
            width: size.width + 20,
            height: size.height + 8
        )
        let platePath = NSBezierPath(roundedRect: plate, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.05, alpha: 0.72).setFill()
        platePath.fill()
        NSColor(calibratedRed: 0.894, green: 0.725, blue: 0.412, alpha: 0.45).setStroke()
        platePath.lineWidth = 1
        platePath.stroke()

        text.draw(at: origin, withAttributes: attrs)

        let captionFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let caption = "taking pointer" as NSString
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: Self.brandPaper.withAlphaComponent(0.85),
            .kern: 0.6,
        ]
        let capSize = caption.size(withAttributes: captionAttrs)
        caption.draw(
            at: CGPoint(x: plate.midX - capSize.width / 2, y: plate.maxY + 4),
            withAttributes: captionAttrs
        )
    }

    private func drawTypingCaption(near point: CGPoint, text: String, showCaret: Bool, lean: CGFloat) {
        let display = text.count > 42 ? "…" + String(text.suffix(41)) : text
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.brandPaper.withAlphaComponent(0.95),
            .kern: 0.15,
        ]
        let caret = showCaret && Int(Date().timeIntervalSince1970 * 2.2) % 2 == 0 ? "▋" : " "
        let line = display + caret
        let size = (line as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 10
        let padY: CGFloat = 7
        let rect = CGRect(
            x: point.x + 18 + lean * 8,
            y: point.y + 10,
            width: size.width + padX * 2,
            height: size.height + padY * 2
        )
        let bubble = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
        shadow.set()
        Self.brandCanvas.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()
        Self.brandPaper.withAlphaComponent(0.14).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
        (line as NSString).draw(
            at: CGPoint(x: rect.minX + padX, y: rect.minY + padY - 1),
            withAttributes: attrs
        )
    }

    private func drawKeyCap(near point: CGPoint, key: String, lean: CGFloat) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.brandPaper.withAlphaComponent(0.96),
            .kern: 0.4,
        ]
        let size = (key as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 11
        let padY: CGFloat = 7
        let rect = CGRect(
            x: point.x + 18 + lean * 8,
            y: point.y + 10,
            width: max(36, size.width + padX * 2),
            height: size.height + padY * 2
        )
        let cap = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.32)
        shadow.set()
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.12, alpha: 0.92).setFill()
        cap.fill()
        NSGraphicsContext.restoreGraphicsState()
        Self.brandCoral.withAlphaComponent(0.55).setStroke()
        cap.lineWidth = 1.1
        cap.stroke()
        let textX = rect.midX - size.width / 2
        (key as NSString).draw(
            at: CGPoint(x: textX, y: rect.minY + padY - 1),
            withAttributes: attrs
        )
    }

    private func drawHighlight(_ rect: CGRect) {
        let inset = rect.insetBy(dx: -3, dy: -3)
        let frame = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        NSColor(calibratedRed: 0.953, green: 0.922, blue: 0.867, alpha: 0.07).setFill()
        frame.fill()
        NSColor(calibratedRed: 0.953, green: 0.922, blue: 0.867, alpha: 0.42).setStroke()
        frame.lineWidth = 1.4
        frame.stroke()

        let inner = NSBezierPath(roundedRect: inset.insetBy(dx: 1.2, dy: 1.2), xRadius: 9, yRadius: 9)
        NSColor(calibratedRed: 0.937, green: 0.416, blue: 0.278, alpha: 0.28).setStroke()
        inner.lineWidth = 1.0
        inner.stroke()
    }

    private func drawTrail(_ points: [CGPoint], head: CGPoint, speed: CGFloat) {
        guard points.count >= 2 else {
            return
        }

        var samples = points
        if let last = samples.last, hypot(last.x - head.x, last.y - head.y) > 0.5 {
            samples.append(head)
        }

        let speedBoost = min(1.0, max(0.35, Double(speed) / 1800.0))
        let count = samples.count
        for index in 0..<(count - 1) {
            let fade = CGFloat(index + 1) / CGFloat(count)
            let alpha = CGFloat((0.06 + 0.40 * fade * fade) * speedBoost)
            let width = CGFloat(0.9 + 2.5 * fade)

            let segment = NSBezierPath()
            segment.move(to: samples[index])
            segment.line(to: samples[index + 1])
            segment.lineCapStyle = .round
            segment.lineJoinStyle = .round

            segment.lineWidth = width + 1.2
            NSColor(calibratedWhite: 0.04, alpha: alpha * 0.30).setStroke()
            segment.stroke()

            segment.lineWidth = width
            NSColor.white.withAlphaComponent(alpha * 0.72).setStroke()
            segment.stroke()
        }
    }

    /// Three staggered rings expanding from the hotspot. Neutral ink so the
    /// ripple reads on any scene without adding a colour cast.
    private func drawLocateRings(at point: CGPoint, progress: CGFloat) {
        let blend = model?.darkSceneBlend ?? 0
        let graphite = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
        let ink = graphite.blended(withFraction: blend, of: .white) ?? graphite
        let halo = NSColor.white.blended(withFraction: blend, of: .black) ?? .white
        for ring in 0..<3 {
            let offset = CGFloat(ring) * 0.22
            let local = (progress - offset) / (1 - offset)
            guard local > 0, local < 1 else { continue }
            let ease = 1 - pow(1 - local, 2.2)
            let radius = 14 + 96 * ease
            let alpha = 0.55 * pow(1 - local, 1.3)
            let path = NSBezierPath(
                ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            )
            path.lineWidth = 3.4 - 1.6 * local
            halo.withAlphaComponent(alpha * 0.5).setStroke()
            path.stroke()
            path.lineWidth = 1.8 - 0.8 * local
            ink.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }

    private func drawClickRing(at point: CGPoint, progress: CGFloat) {
        let ease = 1 - pow(1 - progress, 2.4)
        let radius = CGFloat(7 + 18 * ease)
        let alpha = CGFloat(0.42 * pow(1 - progress, 1.5))
        let path = NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        path.lineWidth = CGFloat(1.7 - 0.8 * progress)
        NSColor.white.blended(withFraction: 1 - (model?.darkSceneBlend ?? 0), of: Self.brandCoral)?.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawTriangle(at point: CGPoint, lean: CGFloat) {
        let path = NSBezierPath(cgPath: ActionCursorGlyph.path(scale: ActionCursorGlyph.overlayScale))
        path.lineJoinStyle = .round
        var transform = AffineTransform(translationByX: point.x, byY: point.y)
        transform.rotate(byRadians: lean + 18 * .pi / 180)
        path.transform(using: transform)

        let blend = model?.darkSceneBlend ?? 0
        let graphite = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
        let body = Self.brandPaper.blended(withFraction: blend, of: graphite) ?? Self.brandPaper
        let rim = graphite.blended(withFraction: blend, of: .white) ?? graphite
        let accent = Self.brandCoral.blended(withFraction: blend,
            of: NSColor(calibratedRed: 0.48, green: 0.73, blue: 1, alpha: 1)) ?? Self.brandCoral
        // Light scenes get a plain drop shadow: a coral bloom spread over paper
        // reads as a yellow haze. The tinted glow is a dark-scene treatment only.
        let neutralShadow = NSColor(calibratedWhite: 0, alpha: 0.38)
        let glowColor = neutralShadow.blended(withFraction: blend, of: accent.withAlphaComponent(0.8)) ?? neutralShadow
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowBlurRadius = 3 + 4 * blend
        glow.shadowOffset = CGSize(width: 0.5, height: -1)
        glow.shadowColor = glowColor
        glow.set()
        body.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        rim.setStroke()
        path.lineWidth = 1.1
        path.stroke()
        // Fine inset illumination preserves the silhouette at recording scale.
        // Neutral on light scenes for the same reason as the shadow: no cast.
        let insetLight = graphite.withAlphaComponent(0.30)
        let inset = insetLight.blended(withFraction: blend, of: accent.withAlphaComponent(0.55)) ?? insetLight
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        inset.setStroke()
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Agent identity leads; the current action remains a quieter supporting cue.
    private func drawBadge(near point: CGPoint, agent: String, label: String?, visible: Bool, lean: CGFloat) {
        guard visible else { return }
        let primary = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: primary.isEmpty ? "Agent" : primary, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Self.brandPaper,
            .paragraphStyle: paragraph,
        ])
        if !secondary.isEmpty {
            text.append(NSAttributedString(string: "  ·  \(secondary)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
                .paragraphStyle: paragraph,
            ]))
        }
        let inset: CGFloat = 10
        let height: CGFloat = 28
        let width = min(text.size().width + 20, min(360, max(0, bounds.width - inset * 2)))
        var origin = CGPoint(x: point.x + 15, y: point.y - height - 17)
        if origin.x + width > bounds.maxX - inset { origin.x = point.x - width - 18 }
        if origin.y < bounds.minY + inset { origin.y = point.y + 18 }
        origin.x = max(bounds.minX + inset, min(origin.x, bounds.maxX - width - inset))
        origin.y = max(bounds.minY + inset, min(origin.y, bounds.maxY - height - inset))
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let plate = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSColor(calibratedRed: 0.125, green: 0.157, blue: 0.169, alpha: 0.98).setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()

        text.draw(with: CGRect(x: rect.minX + 10, y: rect.midY - text.size().height / 2,
                               width: max(0, width - 20), height: text.size().height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The agent's pointer: a stemless wedge whose origin is the exact action hotspot,
/// pointing down and to the right in a y-up space. Shared by the operator overlay and
/// the agent layer's viewer so the agent has one shape wherever it shows.
enum ActionCursorGlyph {
    /// About the size of the system arrow's body: present, not imposing.
    static let overlayScale: CGFloat = 0.62

    static func path(scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        path.move(to: p(0.3, -2.5))
        path.addCurve(to: p(3, -24.5), control1: p(0.8, -7), control2: p(1.6, -21))
        path.addCurve(to: p(7, -24), control1: p(3.8, -28), control2: p(5.6, -27))
        path.addCurve(to: p(19, -15.2), control1: p(9.4, -18), control2: p(13.5, -15.6))
        path.addCurve(to: p(19.8, -12), control1: p(22.5, -15), control2: p(22.4, -13.6))
        path.addLine(to: p(2.5, -0.8))
        path.addCurve(to: p(0.3, -2.5), control1: p(0.3, 0.7), control2: p(-0.1, -0.1))
        path.closeSubpath()
        return path
    }
}
