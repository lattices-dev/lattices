import AppKit
import ActionCore
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum PermissionState: String, Encodable {
    case granted
    case denied
}

struct PermissionSnapshot: Encodable {
    let accessibility: PermissionState
    let screenRecording: PermissionState
    let notes: [String]?
}

struct ActionHostResponse: Codable {
    let status: String
    let outputPath: String?
    let detail: String?
}

enum ActionHostCommand: String {
    case agent
    case launcher
    case webkitSmoke = "webkit-smoke"
    case guidedCalculatorDemo = "guided-calculator-demo"
    case quitApp = "quit-app"
    case status
    case capabilities
    case isolationContext = "isolation-context"
    case request
    case openAccessibilitySettings = "open-accessibility-settings"
    case openScreenRecordingSettings = "open-screen-recording-settings"
    case currentSurface = "current-surface"
    case supervisionOverlay = "supervision-overlay"
    case supervisorStop = "supervisor-stop"
    case stageOverlay = "stage-overlay"
    case drape
    case agentLayer = "agent-layer"
    case agentDisplay = "agent-display"
    case blinkClick = "blink-click"
    case blinkType = "blink-type"
    case blinkKey = "blink-key"
    case blinkDrag = "blink-drag"
    case blinkScroll = "blink-scroll"
    case raiseWindow = "raise-window"
    case windowOrder = "window-order"
    case demoCursorOverlay = "demo-cursor-overlay"
    case agentCursorOverlay = "agent-cursor-overlay"
    case clickFeedbackOverlay = "click-feedback-overlay"
    case pointerEventLogInit = "pointer-event-log-init"
    case terminalSession = "terminal-session"
    case prepareNotesNote = "prepare-notes-note"
    case getCaptureWindowFrame = "get-capture-window-frame"
    case composeRoundedScreenshot = "compose-rounded-screenshot"
    case launchApp = "launch-app"
    case recordAppWindow = "record-app-window"
    case recordAppWindowLocal = "record-app-window-local"
    case screenshotAppWindow = "screenshot-app-window"
    case activateApp = "activate-app"
    case focusWindow = "focus-window"
    case listAppWindows = "list-app-windows"
    case typeText = "type-text"
    case typeAppText = "type-app-text"
    case pressKey = "press-key"
    case pressAppKey = "press-app-key"
    case clickPoint = "click-point"
    case drag
    case scroll
    case pressAccessibilityElement = "press-accessibility-element"
    case performAccessibilityAction = "perform-accessibility-action"
    case setAccessibilityValue = "set-accessibility-value"
    case setFocusedAccessibilityValue = "set-focused-accessibility-value"
    case setAccessibilityRoleValue = "set-accessibility-role-value"
    case clickCalculatorButton = "click-calculator-button"
    case inspectCalculatorButtons = "inspect-calculator-buttons"
    case inspectCalculatorUI = "inspect-calculator-ui"
    case inspectAppUI = "inspect-app-ui"
    case getCalculatorDisplay = "get-calculator-display"
    case setWindowFrame = "set-window-frame"
    case getWindowFrame = "get-window-frame"
    case getDisplayFrame = "get-display-frame"
    case recordRegion = "record-region"
    case recordRegionLocal = "record-region-local"
    case recordingProbe = "recording-probe"
    case screenshotRegion = "screenshot-region"
    case screenshotScreen = "screenshot-screen"
    case ocrScreenshot = "ocr-screenshot"
    case requestApplicationActivation = "_request-application-activation"
}

enum ActionHostError: LocalizedError {
    case missingOption(String)
    case unsupportedOS(String)
    case windowNotFound(String)
    case unableToEncodeImage
    case missingOutputPath
    case missingStopSignalPath
    case captureFailed(String)
    case appleScriptFailed(String)
    case applicationNotRunning(String)
    case ambiguousApplication(String)
    case tooFewWindows(target: String, expected: Int, actual: Int)
    case applicationActivationTimedOut(expected: String, actual: String?)
    case accessibilityLookupFailed(String)
    case accessibilityActionFailed(String)
    case fileNotFound(String)
    case invalidColor(String)

    var errorDescription: String? {
        switch self {
        case .missingOption(let option):
            return "Missing required option \(option)"
        case .unsupportedOS(let detail):
            return detail
        case .windowNotFound(let bundleId):
            return "Could not find an on-screen window for \(bundleId)"
        case .unableToEncodeImage:
            return "Unable to encode screenshot as PNG"
        case .missingOutputPath:
            return "Capture command did not receive an output path"
        case .missingStopSignalPath:
            return "Capture command did not receive a stop signal path"
        case .captureFailed(let detail):
            return detail
        case .appleScriptFailed(let detail):
            return detail
        case .applicationNotRunning(let target):
            return "No running application matches \(target)"
        case .ambiguousApplication(let detail):
            return detail
        case .tooFewWindows(let target, let expected, let actual):
            return "Expected at least \(expected) window(s) for \(target), found \(actual)"
        case .applicationActivationTimedOut(let expected, let actual):
            let actualBundleId = actual ?? "none"
            return "Timed out activating \(expected); frontmost application is \(actualBundleId)"
        case .accessibilityLookupFailed(let detail):
            return detail
        case .accessibilityActionFailed(let detail):
            return detail
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidColor(let color):
            return "Invalid color \(color)"
        }
    }
}

struct CommandOptions {
    let command: ActionHostCommand?
    let options: [String: String]

    init(arguments: [String]) {
        let commandName = arguments.dropFirst().first(where: { !$0.hasPrefix("-psn_") })
        if let commandName {
            self.command = ActionHostCommand(rawValue: commandName) ?? .status
        } else {
            self.command = nil
        }

        var parsed: [String: String] = [:]
        let rest = Array(arguments.dropFirst(2))
        var index = 0
        while index < rest.count {
            let key = rest[index]
            index += 1
            guard key.hasPrefix("--") else {
                continue
            }
            // A bare flag — followed by another option or the end of the argument list —
            // reads as boolean true, so callers can write `--raise` instead of `--raise true`.
            if index < rest.count, !rest[index].hasPrefix("--") {
                parsed[String(key.dropFirst(2))] = rest[index]
                index += 1
            } else {
                parsed[String(key.dropFirst(2))] = "true"
            }
        }

        self.options = parsed
    }

    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw ActionHostError.missingOption("--\(key)")
        }
        return value
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        guard let value = options[key], let number = Double(value) else {
            return defaultValue
        }
        return number
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        guard let value = options[key], let number = Int(value) else {
            return defaultValue
        }
        return number
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = options[key] else {
            return defaultValue
        }
        switch value.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return defaultValue
        }
    }
}

final class ResponseWriter {
    private let replyFile: String?

    init(replyFile: String?) {
        self.replyFile = replyFile
    }

    func write(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        if let replyFile {
            let url = URL(fileURLWithPath: replyFile)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: callers poll the reply file for existence and then read it whole, so a
            // plain write can hand back a truncated document mid-write. A rename makes the
            // file appear only once it is complete.
            try data.write(to: url, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}

final class DebugLogger {
    private let path: String?

    init(path: String?) {
        self.path = path
    }

    func log(_ message: String) {
        guard let path else {
            return
        }

        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: path)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            FileHandle.standardError.write(Data("ActionHost debug log failed: \(error.localizedDescription)\n".utf8))
        }
    }
}

func accessibilityStatus(prompt: Bool) -> PermissionState {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
}

func screenRecordingStatus() -> PermissionState {
    CGPreflightScreenCaptureAccess() ? .granted : .denied
}

func snapshot(promptAccessibility: Bool) -> PermissionSnapshot {
    let accessibility = accessibilityStatus(prompt: promptAccessibility)
    let screenRecording = screenRecordingStatus()
    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    let bundlePath = Bundle.main.bundlePath

    return PermissionSnapshot(
        accessibility: accessibility,
        screenRecording: screenRecording,
        notes: [
            "bundleId=\(bundleId)",
            "bundlePath=\(bundlePath)"
        ]
    )
}

func openSettingsPane(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }

    NSWorkspace.shared.open(url)
}

/// Resolves a bundle identifier to exactly one running process. Two processes can share a
/// bundle id (a production install and a dev build), and silently picking one targets the
/// wrong instance — callers must disambiguate with --pid or --bundle-path.
func runningApplication(bundleId: String) throws -> NSRunningApplication {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    guard let app = matches.first else {
        throw ActionHostError.applicationNotRunning("bundle identifier \(bundleId)")
    }
    guard matches.count == 1 else {
        let candidates = matches
            .map { "pid=\($0.processIdentifier) path=\($0.bundleURL?.path ?? "unknown")" }
            .joined(separator: "; ")
        throw ActionHostError.ambiguousApplication(
            "\(matches.count) running applications share bundle identifier \(bundleId); target one with --pid or --bundle-path: \(candidates)"
        )
    }

    return app
}

/// Resolves the target application for app-scoped commands from --pid, --bundle-path, or
/// --bundle-id, in that order. Pid and bundle path each name exactly one process; bundle id
/// resolution fails closed when more than one process shares the identifier.
func resolveTargetApplication(from options: CommandOptions) throws -> NSRunningApplication {
    if let pidOption = options.options["pid"] {
        guard let pid = Int32(pidOption) else {
            throw ActionHostError.missingOption("--pid (must be a process id)")
        }
        return try ActionNativeAutomation.runningApplication(pid: pid)
    }

    if let bundlePath = options.options["bundle-path"], !bundlePath.isEmpty {
        return try ActionNativeAutomation.runningApplication(bundlePath: bundlePath)
    }

    return try runningApplication(bundleId: try options.required("bundle-id"))
}

func targetLabel(for app: NSRunningApplication) -> String {
    app.bundleIdentifier ?? app.bundleURL?.path ?? "pid \(app.processIdentifier)"
}

func activationPolicyLabel(_ policy: NSApplication.ActivationPolicy) -> String {
    switch policy {
    case .regular:
        return "regular"
    case .accessory:
        return "accessory"
    case .prohibited:
        return "prohibited"
    @unknown default:
        return "unknown"
    }
}

func activateApplication(app: NSRunningApplication) throws {
    let label = targetLabel(for: app)
    guard let executableURL = Bundle.main.executableURL else {
        throw ActionHostError.applicationActivationTimedOut(
            expected: label,
            actual: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
        ActionHostCommand.requestApplicationActivation.rawValue,
        "--pid",
        String(app.processIdentifier),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw ActionHostError.applicationActivationTimedOut(
            expected: label,
            actual: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }
}

/// Waits for the app to exist *and* finish launching. A process that exists but is still
/// starting up has no accessibility interface yet, so activating it would fail spuriously.
func waitForRunningApplication(bundleId: String, timeoutMilliseconds: Double) async throws {
    let deadline = Date().addingTimeInterval(max(100, timeoutMilliseconds) / 1_000)
    while true {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        if let app, app.isFinishedLaunching {
            return
        }
        if Date() >= deadline {
            throw ActionHostError.applicationNotRunning(bundleId)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
func activateApplicationAndWait(
    bundleId: String,
    timeoutMilliseconds: Double,
    logger: DebugLogger
) async throws {
    try await activateApplicationAndWait(
        app: try runningApplication(bundleId: bundleId),
        timeoutMilliseconds: timeoutMilliseconds,
        logger: logger
    )
}

@MainActor
func activateApplicationAndWait(
    app: NSRunningApplication,
    timeoutMilliseconds: Double,
    logger: DebugLogger
) async throws {
    let label = targetLabel(for: app)

    // Only regular apps ever become NSWorkspace.frontmostApplication. Accessory /
    // LSUIElement apps (menubar apps, floating panels) would time that wait out every
    // time, so they get their windows raised in place instead.
    guard app.activationPolicy == .regular else {
        let raised = ActionNativeAutomation.raiseAllWindows(pid: app.processIdentifier)
        logger.log(
            "activate-app: requested=\(label) policy=\(activationPolicyLabel(app.activationPolicy)) raised-windows=\(raised) (no frontmost wait for non-regular apps)"
        )
        return
    }

    let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    logger.log("activate-app: requested=\(label) frontmost-before=\(frontmostBefore)")

    let boundedTimeout = max(100, timeoutMilliseconds)
    let deadline = Date().addingTimeInterval(boundedTimeout / 1_000)
    var attempts = 0

    // A freshly launched app can accept the activation request before it is ready to come
    // forward, so a single request is not enough: keep re-requesting until the window server
    // agrees that the app is frontmost, or until the deadline makes it a real failure.
    while true {
        attempts += 1
        let requestError: Error?
        do {
            try activateApplication(app: app)
            requestError = nil
        } catch {
            requestError = error
        }

        let settleDeadline = min(deadline, Date().addingTimeInterval(0.5))
        var frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        while frontmostAfter != app.processIdentifier, Date() < settleDeadline {
            try await Task.sleep(for: .milliseconds(50))
            frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        if frontmostAfter == app.processIdentifier {
            logger.log("activate-app: confirmed requested=\(label) attempts=\(attempts)")
            return
        }

        if Date() >= deadline {
            let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let requestDetail = requestError.map { " last-error=\($0.localizedDescription)" } ?? ""
            logger.log(
                "activate-app: timed-out requested=\(label) frontmost=\(frontmostBundleId) attempts=\(attempts) timeout-ms=\(Int(boundedTimeout))\(requestDetail)"
            )
            throw ActionHostError.applicationActivationTimedOut(expected: label, actual: frontmostBundleId)
        }

        try await Task.sleep(for: .milliseconds(100))
    }
}

func runAppleScript(_ source: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if process.terminationStatus == 0 {
        return output
    }

    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown AppleScript error"
    throw ActionHostError.appleScriptFailed(error)
}

func prepareNotesNote() throws -> String {
    let script = """
    tell application "Notes"
      activate
      set targetFolder to default folder of default account
      set newNote to make new note at targetFolder with properties {body:"<div><br></div>"}
      show newNote
      delay 0.35
      return name of newNote
    end tell
    """

    let noteName = try runAppleScript(script)
    try focusNotesEditor()
    return noteName
}

let keyCodes: [String: UInt16] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
    "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
    "escape": 0x35, "esc": 0x35,
    "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
    "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "forwarddelete": 0x75,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
]

let keySymbols: [String: String] = [
    "cmd": "⌘", "command": "⌘",
    "shift": "⇧",
    "opt": "⌥", "option": "⌥", "alt": "⌥",
    "ctrl": "⌃", "control": "⌃",
    "fn": "fn",
    "return": "↵", "enter": "↵",
    "tab": "⇥",
    "space": "␣",
    "delete": "⌫", "backspace": "⌫",
    "escape": "⎋", "esc": "⎋",
    "up": "↑", "down": "↓", "left": "←", "right": "→",
    "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟", "forwarddelete": "⌦",
]

func keyOverlayLabel(_ key: String) -> String {
    keySymbols[key.lowercased()] ?? key.uppercased()
}

func modifierFlags(for modifiers: [String]) -> CGEventFlags {
    modifiers.reduce(into: CGEventFlags()) { result, modifier in
        switch modifier.lowercased() {
        case "cmd", "command":
            result.insert(.maskCommand)
        case "shift":
            result.insert(.maskShift)
        case "opt", "option", "alt":
            result.insert(.maskAlternate)
        case "ctrl", "control":
            result.insert(.maskControl)
        default:
            break
        }
    }
}

func postKeyPress(_ key: String, modifiers: [String] = []) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create event source")
    }

    let normalized = key.lowercased()
    guard let keyCode = keyCodes[normalized] else {
        try postText(key, delayMs: nil)
        return
    }

    let flags = modifierFlags(for: modifiers)
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create keyboard events")
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(50000)
    keyUp.post(tap: .cghidEventTap)
}

func postKeyPressToApp(bundleId: String, key: String, modifiers: [String] = []) throws {
    try postKeyPressToApp(app: try runningApplication(bundleId: bundleId), key: key, modifiers: modifiers)
}

func postKeyPressToApp(
    app: NSRunningApplication,
    key: String,
    modifiers: [String] = [],
    holdMicroseconds: useconds_t = 50_000
) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create event source")
    }

    let normalized = key.lowercased()
    guard let keyCode = keyCodes[normalized] else {
        throw ActionHostError.accessibilityActionFailed("Unsupported direct app key: \(key)")
    }

    let flags = modifierFlags(for: modifiers)
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create app keyboard events")
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.postToPid(app.processIdentifier)
    usleep(holdMicroseconds)
    keyUp.postToPid(app.processIdentifier)
}

/// How long a plain click holds the mouse button down. Long enough for any app to see a
/// press and a release as one click, short enough that nothing reads it as a press-and-hold.
let defaultClickHoldMilliseconds = 30

/// Clicks at a screen point, holding the button down for `holdMs` before releasing.
/// The default is a plain click; larger values produce a press-and-hold, which is how
/// watch-face editing, context menus, and other long-press affordances are triggered.
///
/// The button events themselves are posted by `ActionPointerChannel`, the shared boundary that
/// also records the event and drives any opt-in click feedback, so the click a viewer sees and
/// the click the artifact describes are the same event.
@discardableResult
func clickPoint(
    _ point: CGPoint,
    holdMs: Int = defaultClickHoldMilliseconds,
    pointerEventLogPath: String? = nil
) throws -> ActionPointerGesture {
    try ActionPointerChannel.primaryClick(
        at: point,
        holdMs: holdMs,
        source: "click-point",
        log: ActionPointerEventLog.active(explicitPath: pointerEventLogPath)
    )
}

func postText(_ text: String, delayMs: Int?) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create event source")
    }

    for scalar in text.utf16 {
        var unicode = [scalar]
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw ActionHostError.accessibilityActionFailed("Unable to create keyboard events")
        }

        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        keyDown.post(tap: .cghidEventTap)
        if let delayMs, delayMs > 0 {
            usleep(useconds_t(delayMs * 500))
        }
        keyUp.post(tap: .cghidEventTap)
        if let delayMs, delayMs > 0 {
            usleep(useconds_t(delayMs * 500))
        }
    }
}

func postTextToApp(bundleId: String, text: String, delayMs: Int?) throws {
    try postTextToApp(app: try runningApplication(bundleId: bundleId), text: text, delayMs: delayMs)
}

func postTextToApp(app: NSRunningApplication, text: String, delayMs: Int?) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ActionHostError.accessibilityActionFailed("Unable to create event source")
    }

    for scalar in text.utf16 {
        var unicode = [scalar]
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw ActionHostError.accessibilityActionFailed("Unable to create app text events")
        }

        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        keyDown.postToPid(app.processIdentifier)
        if let delayMs, delayMs > 0 {
            usleep(useconds_t(delayMs * 500))
        }
        keyUp.postToPid(app.processIdentifier)
        if let delayMs, delayMs > 0 {
            usleep(useconds_t(delayMs * 500))
        }
    }
}

func axValue(_ element: AXUIElement, attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        return nil
    }

    return value
}

func axChildren(of element: AXUIElement) -> [AXUIElement] {
    if let direct = axValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
        return direct
    }

    return []
}

func firstWindowElement(for bundleId: String) throws -> AXUIElement {
    let app = try runningApplication(bundleId: bundleId)
    let application = AXUIElementCreateApplication(app.processIdentifier)

    if let focusedWindow = axValue(application, attribute: kAXFocusedWindowAttribute),
       CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
        return unsafeDowncast(focusedWindow, to: AXUIElement.self)
    }

    if let mainWindow = axValue(application, attribute: kAXMainWindowAttribute),
       CFGetTypeID(mainWindow) == AXUIElementGetTypeID() {
        return unsafeDowncast(mainWindow, to: AXUIElement.self)
    }

    if let windows = axValue(application, attribute: kAXWindowsAttribute) as? [AXUIElement],
       !windows.isEmpty {
        return windows.max { lhs, rhs in
            windowArea(lhs) < windowArea(rhs)
        } ?? windows[0]
    }

    throw ActionHostError.accessibilityLookupFailed("No accessibility window found for \(bundleId)")
}

func windowArea(_ element: AXUIElement) -> CGFloat {
    guard let position = point(from: axValue(element, attribute: kAXPositionAttribute)),
          let size = size(from: axValue(element, attribute: kAXSizeAttribute)) else {
        return 0
    }
    _ = position
    return max(0, size.width) * max(0, size.height)
}

func pointValue(_ point: CGPoint) -> AXValue {
    var point = point
    return AXValueCreate(.cgPoint, &point)!
}

func sizeValue(_ size: CGSize) -> AXValue {
    var size = size
    return AXValueCreate(.cgSize, &size)!
}

func point(from value: AnyObject?) -> CGPoint? {
    guard let value else {
        return nil
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let ax = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(ax) == .cgPoint else {
        return nil
    }
    var point = CGPoint.zero
    guard AXValueGetValue(ax, .cgPoint, &point) else {
        return nil
    }
    return point
}

func size(from value: AnyObject?) -> CGSize? {
    guard let value else {
        return nil
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let ax = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(ax) == .cgSize else {
        return nil
    }
    var size = CGSize.zero
    guard AXValueGetValue(ax, .cgSize, &size) else {
        return nil
    }
    return size
}

func setWindowFrame(bundleId: String, rect: CGRect) throws {
    let window = try firstWindowElement(for: bundleId)

    let positionResult = AXUIElementSetAttributeValue(
        window,
        kAXPositionAttribute as CFString,
        pointValue(rect.origin)
    )
    guard positionResult == .success else {
        throw ActionHostError.accessibilityActionFailed("Failed to set window position for \(bundleId): \(positionResult.rawValue)")
    }

    let sizeResult = AXUIElementSetAttributeValue(
        window,
        kAXSizeAttribute as CFString,
        sizeValue(rect.size)
    )
    // Some native apps expose a fixed or constrained window size. Positioning is
    // still useful for viewport capture, so size failure is best-effort only.
    _ = sizeResult
}

struct WindowFrameResponse: Encodable {
    let status: String
    let bundleId: String
    let frame: OverlayBounds
}

struct CurrentSurfaceResponse: Encodable {
    let status: String
    let bundleId: String
    let appName: String
    let frame: OverlayBounds?
}

struct WindowOrderEntry: Encodable {
    let pid: Int
    let bundleId: String?
    let owner: String
    let title: String
    let layer: Int
    let bounds: OverlayBounds
}

struct WindowOrderResponse: Encodable {
    let status: String
    let windows: [WindowOrderEntry]
}

func windowOrder(bounds: CGRect?) -> WindowOrderResponse {
    let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []

    var windows: [WindowOrderEntry] = []
    windows.reserveCapacity(windowList.count)
    for windowInfo in windowList {
        guard let frame = rect(from: windowInfo), frame.width >= 32, frame.height >= 32 else {
            continue
        }
        if let bounds, !frame.intersects(bounds) {
            continue
        }
        let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let app = ownerPID > 0 ? NSRunningApplication(processIdentifier: ownerPID) : nil
        let owner = (windowInfo[kCGWindowOwnerName as String] as? String)
            ?? app?.localizedName
            ?? ""
        windows.append(
            WindowOrderEntry(
                pid: Int(ownerPID),
                bundleId: app?.bundleIdentifier,
                owner: owner,
                title: windowInfo[kCGWindowName as String] as? String ?? "",
                layer: windowInfo[kCGWindowLayer as String] as? Int ?? 0,
                bounds: overlayBounds(from: frame)
            )
        )
    }
    return WindowOrderResponse(status: "window-order", windows: windows)
}

func overlayBounds(from rect: CGRect) -> OverlayBounds {
    OverlayBounds(
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.size.width,
        height: rect.size.height
    )
}

func activeDisplayBounds(containing point: CGPoint) throws -> CGRect {
    var displayCount: UInt32 = 0
    let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
    guard countResult == .success, displayCount > 0 else {
        throw ActionHostError.captureFailed("No display is available")
    }

    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    let listResult = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
    guard listResult == .success else {
        throw ActionHostError.captureFailed("Failed to enumerate displays")
    }

    let activeIDs = displayIDs.prefix(Int(displayCount))
    let displayID = activeIDs.first(where: { CGDisplayBounds($0).contains(point) })
        ?? activeIDs.first(where: { $0 == CGMainDisplayID() })
        ?? activeIDs.first
    guard let displayID else {
        throw ActionHostError.captureFailed("No display is available")
    }
    return CGDisplayBounds(displayID)
}

func rect(from windowInfo: [String: Any]) -> CGRect? {
    guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
        return nil
    }

    var rect = CGRect.zero
    guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else {
        return nil
    }

    return rect
}

func currentSurface() throws -> CurrentSurfaceResponse {
    let selfBundleId = Bundle.main.bundleIdentifier
    let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

    for windowInfo in windowList {
        let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else {
            continue
        }

        let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t ?? 0
        guard ownerPID > 0,
              let app = NSRunningApplication(processIdentifier: ownerPID),
              let bundleId = app.bundleIdentifier,
              bundleId != selfBundleId else {
            continue
        }

        let appName = app.localizedName ?? bundleId
        let frame = (try? getWindowFrame(bundleId: bundleId))
            ?? rect(from: windowInfo)

        return CurrentSurfaceResponse(
            status: "current-surface",
            bundleId: bundleId,
            appName: appName,
            frame: frame.map(overlayBounds(from:))
        )
    }

    throw ActionHostError.windowNotFound("current-surface")
}

func getWindowFrame(bundleId: String) throws -> CGRect {
    let window = try firstWindowElement(for: bundleId)
    let position = point(from: axValue(window, attribute: kAXPositionAttribute))
    let size = size(from: axValue(window, attribute: kAXSizeAttribute))
    guard let position, let size else {
        throw ActionHostError.accessibilityLookupFailed("Failed to read window frame for \(bundleId)")
    }
    return CGRect(origin: position, size: size)
}

struct AppWindowSnapshot: Encodable {
    let id: Int?
    let title: String?
    let role: String?
    let subrole: String?
    let layer: Int?
    let frame: OverlayBounds?
    let isOnScreen: Bool?
    let source: String
    let raised: Bool
}

struct AppWindowsResponse: Encodable {
    let status: String
    let pid: Int
    let bundleId: String?
    let bundlePath: String?
    let activationPolicy: String
    let windowCount: Int
    let raisedCount: Int
    let windows: [AppWindowSnapshot]
}

private struct AXListedWindow {
    let title: String?
    let role: String?
    let subrole: String?
    let frame: CGRect?
    let raised: Bool
}

/// Lists every window-server and accessibility window one process owns, with no layer or
/// size filtering: floating note panels, detached chrome, and status items all count as
/// windows. `raise` orders each accessibility window front (AXMain + AXRaise) without
/// activating the app, so an accessory / LSUIElement target comes forward for screenshots
/// and clicks without ever needing to become the frontmost application.
func listAppWindows(
    app: NSRunningApplication,
    raise: Bool,
    minWindows: Int,
    logger: DebugLogger
) throws -> AppWindowsResponse {
    let pid = app.processIdentifier
    let application = AXUIElementCreateApplication(pid)
    let axWindows = (axValue(application, attribute: kAXWindowsAttribute) as? [AXUIElement]) ?? []

    var axListed: [AXListedWindow] = []
    for window in axWindows {
        var raised = false
        if raise {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        let position = point(from: axValue(window, attribute: kAXPositionAttribute))
        let size = size(from: axValue(window, attribute: kAXSizeAttribute))
        var frame: CGRect?
        if let position, let size {
            frame = CGRect(origin: position, size: size)
        }
        axListed.append(
            AXListedWindow(
                title: axValue(window, attribute: kAXTitleAttribute) as? String,
                role: axValue(window, attribute: kAXRoleAttribute) as? String,
                subrole: axValue(window, attribute: kAXSubroleAttribute) as? String,
                frame: frame,
                raised: raised
            )
        )
    }

    // The window server list is authoritative for existence, ids, and layers; the AX list
    // carries titles, roles, and the raise handle. Entries are matched by frame and merged
    // so a window missing from either side is still reported rather than dropped.
    let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var snapshots: [AppWindowSnapshot] = []
    var matchedAXIndices = Set<Int>()

    for info in windowList {
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else {
            continue
        }

        let windowFrame = rect(from: info)
        let axIndex = axListed.indices.first { index in
            guard !matchedAXIndices.contains(index),
                  let axFrame = axListed[index].frame,
                  let windowFrame else {
                return false
            }
            return abs(axFrame.origin.x - windowFrame.origin.x) <= 2
                && abs(axFrame.origin.y - windowFrame.origin.y) <= 2
                && abs(axFrame.width - windowFrame.width) <= 2
                && abs(axFrame.height - windowFrame.height) <= 2
        }

        var title = info[kCGWindowName as String] as? String
        var role: String?
        var subrole: String?
        var raised = false
        var source = "cg"
        if let axIndex {
            matchedAXIndices.insert(axIndex)
            let ax = axListed[axIndex]
            if let axTitle = ax.title, !axTitle.isEmpty {
                title = axTitle
            }
            role = ax.role
            subrole = ax.subrole
            raised = ax.raised
            source = "cg+ax"
        }

        snapshots.append(
            AppWindowSnapshot(
                id: info[kCGWindowNumber as String] as? Int,
                title: title,
                role: role,
                subrole: subrole,
                layer: info[kCGWindowLayer as String] as? Int,
                frame: windowFrame.map(overlayBounds(from:)),
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                source: source,
                raised: raised
            )
        )
    }

    for (index, ax) in axListed.enumerated() where !matchedAXIndices.contains(index) {
        snapshots.append(
            AppWindowSnapshot(
                id: nil,
                title: ax.title,
                role: ax.role,
                subrole: ax.subrole,
                layer: nil,
                frame: ax.frame.map(overlayBounds(from:)),
                isOnScreen: nil,
                source: "ax",
                raised: ax.raised
            )
        )
    }

    let label = targetLabel(for: app)
    logger.log(
        "list-app-windows: target=\(label) pid=\(pid) windows=\(snapshots.count) ax=\(axListed.count) raise=\(raise)"
    )

    guard snapshots.count >= minWindows else {
        throw ActionHostError.tooFewWindows(target: label, expected: minWindows, actual: snapshots.count)
    }

    return AppWindowsResponse(
        status: "app-windows",
        pid: Int(pid),
        bundleId: app.bundleIdentifier,
        bundlePath: app.bundleURL?.path,
        activationPolicy: activationPolicyLabel(app.activationPolicy),
        windowCount: snapshots.count,
        raisedCount: snapshots.filter(\.raised).count,
        windows: snapshots
    )
}

func findButton(in root: AXUIElement, label: String) -> AXUIElement? {
    var queue = [root]

    while let current = queue.first {
        queue.removeFirst()

        let role = axValue(current, attribute: kAXRoleAttribute) as? String
        let title = axValue(current, attribute: kAXTitleAttribute) as? String
        let description = axValue(current, attribute: kAXDescriptionAttribute) as? String
        let value = axValue(current, attribute: kAXValueAttribute) as? String
        let identifier = axValue(current, attribute: kAXIdentifierAttribute) as? String

        if role == kAXButtonRole as String, [title, description, value, identifier].contains(label) {
            return current
        }

        queue.append(contentsOf: axChildren(of: current))
    }

    return nil
}

func matchesText(_ candidate: String?, expected: String) -> Bool {
    candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
}

func findElement(
    in root: AXUIElement,
    where predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    var queue = [root]

    while let current = queue.first {
        queue.removeFirst()

        if predicate(current) {
            return current
        }

        queue.append(contentsOf: axChildren(of: current))
    }

    return nil
}

func focusNotesEditor() throws {
    let window = try firstWindowElement(for: "com.apple.Notes")
    guard let editor = findElement(in: window, where: { element in
        let role = axValue(element, attribute: kAXRoleAttribute) as? String
        let identifier = axValue(element, attribute: kAXIdentifierAttribute) as? String
        let title = axValue(element, attribute: kAXTitleAttribute) as? String
        return role == kAXTextAreaRole as String
            && (matchesText(identifier, expected: "Note Body Text View")
                || matchesText(title, expected: "Note Body Text View"))
    }) else {
        throw ActionHostError.accessibilityLookupFailed("Could not find the Notes body text view")
    }

    let focusResult = AXUIElementSetAttributeValue(
        editor,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard focusResult == .success else {
        throw ActionHostError.accessibilityActionFailed("Failed to focus Notes editor: \(focusResult.rawValue)")
    }
}

struct CalculatorButtonSnapshot: Encodable {
    let role: String
    let title: String?
    let detail: String?
    let value: String?
    let identifier: String?
}

func calculatorButtons() throws -> [CalculatorButtonSnapshot] {
    let window = try firstWindowElement(for: "com.apple.calculator")
    var queue = [window]
    var result: [CalculatorButtonSnapshot] = []

    while let current = queue.first {
        queue.removeFirst()

        let role = axValue(current, attribute: kAXRoleAttribute) as? String ?? ""
        let title = axValue(current, attribute: kAXTitleAttribute) as? String
        let detail = axValue(current, attribute: kAXDescriptionAttribute) as? String
        let value = axValue(current, attribute: kAXValueAttribute) as? String
        let identifier = axValue(current, attribute: kAXIdentifierAttribute) as? String

        if role == kAXButtonRole as String {
            result.append(
                CalculatorButtonSnapshot(
                    role: role,
                    title: title,
                    detail: detail,
                    value: value,
                    identifier: identifier
                )
            )
        }

        queue.append(contentsOf: axChildren(of: current))
    }

    return result
}

func clickCalculatorButton(label: String) throws {
    let window = try firstWindowElement(for: "com.apple.calculator")
    guard let button = findButton(in: window, label: label) else {
        throw ActionHostError.accessibilityLookupFailed("Could not find Calculator button \(label)")
    }

    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard result == .success else {
        throw ActionHostError.accessibilityActionFailed("Accessibility press failed for Calculator button \(label): \(result.rawValue)")
    }
}

func shareableContent() async throws -> SCShareableContent {
    guard screenRecordingStatus() == .granted else {
        throw ActionHostError.unsupportedOS("Screen Recording permission has not been granted yet.")
    }

    return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
}

struct WindowSelection {
    let content: SCShareableContent
    let window: SCWindow
    let display: SCDisplay
}

struct RegionSelection {
    let display: SCDisplay
    let sourceRect: CGRect
}

func displayContaining(window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
    let center = CGPoint(
        x: window.frame.midX,
        y: window.frame.midY
    )

    return displays.first(where: { $0.frame.contains(center) }) ?? displays.first
}

func regionSelection(for rect: CGRect, displays: [SCDisplay]) -> RegionSelection? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard let display = displays.first(where: { $0.frame.contains(center) }) ?? displays.first else {
        return nil
    }

    let localRect = CGRect(
        x: rect.origin.x - display.frame.origin.x,
        y: rect.origin.y - display.frame.origin.y,
        width: rect.width,
        height: rect.height
    )

    return RegionSelection(display: display, sourceRect: localRect)
}

func rectArea(_ rect: CGRect) -> CGFloat {
    max(rect.width, 0) * max(rect.height, 0)
}

func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    if intersection.isNull || intersection.isEmpty {
        return 0
    }
    return rectArea(intersection)
}

func bestWindowSelection(for bundleId: String) async throws -> WindowSelection {
    let content = try await shareableContent()

    let candidates = content.windows.filter { window in
        window.owningApplication?.bundleIdentifier == bundleId && window.isOnScreen && window.windowLayer == 0
    }

    let sizableCandidates = candidates.filter { window in
        window.frame.width >= 400 && window.frame.height >= 300
    }
    let titledCandidates = sizableCandidates.filter { window in
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !title.isEmpty
    }
    let primaryCandidates = titledCandidates.isEmpty
        ? (sizableCandidates.isEmpty ? candidates : sizableCandidates)
        : titledCandidates

    let selectedWindow: SCWindow
    if let expectedFrame = try? getWindowFrame(bundleId: bundleId),
       let overlapping = primaryCandidates.max(by: { lhs, rhs in
           overlapArea(lhs.frame, expectedFrame) < overlapArea(rhs.frame, expectedFrame)
       }),
       overlapArea(overlapping.frame, expectedFrame) > 0 {
        selectedWindow = overlapping
    } else if let active = primaryCandidates.first(where: \.isActive) {
        selectedWindow = active
    } else if let largest = primaryCandidates.max(by: { lhs, rhs in
        rectArea(lhs.frame) < rectArea(rhs.frame)
    }) {
        selectedWindow = largest
    } else {
        throw ActionHostError.windowNotFound(bundleId)
    }

    guard let display = displayContaining(window: selectedWindow, displays: content.displays) else {
        throw ActionHostError.windowNotFound(bundleId)
    }

    return WindowSelection(content: content, window: selectedWindow, display: display)
}

func getCaptureWindowFrame(bundleId: String) async throws -> CGRect {
    let selection = try await bestWindowSelection(for: bundleId)
    return selection.window.frame
}

func pngData(from image: CGImage) -> Data? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
}

func colorFromHex(_ hex: String) throws -> NSColor {
    let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard normalized.count == 6 || normalized.count == 8,
          let value = UInt64(normalized, radix: 16) else {
        throw ActionHostError.invalidColor(hex)
    }

    let hasAlpha = normalized.count == 8
    let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func composeRoundedScreenshot(
    inputPath: String,
    outputPath: String,
    radius: CGFloat,
    backgroundHex: String
) throws {
    let inputURL = URL(fileURLWithPath: inputPath)
    guard let sourceImage = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let source = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil) else {
        throw ActionHostError.captureFailed("Unable to read image at \(inputPath)")
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let width = source.width
    let height = source.height
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw ActionHostError.unableToEncodeImage
    }

    let backgroundColor = try colorFromHex(backgroundHex).usingColorSpace(.sRGB) ?? NSColor.white
    context.setFillColor(backgroundColor.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let drawRect = CGRect(x: 0, y: 0, width: width, height: height)
    let clipPath = CGPath(
        roundedRect: drawRect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    context.addPath(clipPath)
    context.clip()
    context.draw(source, in: drawRect)

    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw ActionHostError.unableToEncodeImage
    }

    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ActionHostError.unableToEncodeImage
    }
}

@available(macOS 15.0, *)
@MainActor
final class WindowRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let writer: ResponseWriter
    private let logger: DebugLogger
    private var finishedSignalPath: String?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var recordingStarted = false
    private var recordingFinished = false
    private var recordingError: Error?

    init(writer: ResponseWriter, logger: DebugLogger) {
        self.writer = writer
        self.logger = logger
    }

    func recordRegion(rect: CGRect, outputPath: String, stopSignalPath: String?) async throws {
        try await recordRegion(
            rect: rect,
            outputPath: outputPath,
            stopSignalPath: stopSignalPath,
            finishedSignalPath: nil,
            fps: 15,
            scale: 1
        )
    }

    func recordRegion(rect: CGRect, outputPath: String, stopSignalPath: String?, finishedSignalPath: String?, fps: Double, scale: Double, includeSupervisionOverlay: Bool = true) async throws {
        logger.log("record-region: begin rect=\(rect) outputPath=\(outputPath)")
        self.finishedSignalPath = finishedSignalPath
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let content = try await shareableContent()
        guard let selection = regionSelection(for: rect, displays: content.displays) else {
            throw ActionHostError.unsupportedOS("Could not resolve a display for rect \(rect)")
        }

        logger.log("record-region: display frame=\(selection.display.frame) sourceRect=\(selection.sourceRect)")
        let supervisionWindows: [SCWindow]
        if !includeSupervisionOverlay, let overlayPID = ActionSupervisionRegistry.overlayPID() {
            supervisionWindows = content.windows.filter {
                $0.owningApplication?.processID == overlayPID
            }
        } else {
            supervisionWindows = []
        }
        logger.log("record-region: includeSupervisionOverlay=\(includeSupervisionOverlay) excluding supervision windows=\(supervisionWindows.count)")
        let filter = SCContentFilter(display: selection.display, excludingWindows: supervisionWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(selection.sourceRect.width * scale), 1)
        configuration.height = max(Int(selection.sourceRect.height * scale), 1)
        configuration.minimumFrameInterval = CMTime(seconds: 1 / max(fps, 1), preferredTimescale: 600)
        configuration.sourceRect = selection.sourceRect
        logger.log("record-region: fps=\(fps) scale=\(scale) output=\(configuration.width)x\(configuration.height)")

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        logger.log("record-region: encoding container=mov codec=h264 fps=\(fps) dimensions=\(configuration.width)x\(configuration.height)")

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput

        try await stream.startCapture()
        try await waitForRecordingStart()
        try writer.write(ActionHostResponse(status: "recording", outputPath: outputPath, detail: nil))

        if let stopSignalPath {
            try waitForStopSignal(at: stopSignalPath)
        } else {
            _ = try FileHandle.standardInput.readToEnd()
        }

        try await stream.stopCapture()
        try await waitForRecordingFinish()
        try writer.write(ActionHostResponse(status: "finished", outputPath: outputPath, detail: nil))
        try writeSignalFile(path: finishedSignalPath, contents: "finished\n")
    }

    func recordAppWindow(bundleId: String, outputPath: String) async throws {
        try await recordAppWindow(
            bundleId: bundleId,
            outputPath: outputPath,
            stopSignalPath: nil,
            finishedSignalPath: nil
        )
    }

    func recordAppWindow(bundleId: String, outputPath: String, stopSignalPath: String?, finishedSignalPath: String?) async throws {
        logger.log("record: begin bundleId=\(bundleId) outputPath=\(outputPath)")
        self.finishedSignalPath = finishedSignalPath
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        logger.log("record: finding window")
        let selection = try await bestWindowSelection(for: bundleId)
        let window = selection.window
        logger.log("record: window id=\(window.windowID) frame=\(window.frame)")
        logger.log("record: creating content filter")
        let filter = SCContentFilter(display: selection.display, including: [window])
        logger.log("record: creating stream configuration")
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(window.frame.width), 1)
        configuration.height = max(Int(window.frame.height), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.sourceRect = window.frame
        logger.log("record: configuration width=\(configuration.width) height=\(configuration.height)")

        logger.log("record: creating stream")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264

        logger.log("record: creating recording output")
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        logger.log("record: adding recording output")
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput

        logger.log("record: starting capture")
        try await stream.startCapture()
        logger.log("record: capture started")
        try await waitForRecordingStart()
        try writer.write(ActionHostResponse(status: "recording", outputPath: outputPath, detail: nil))
        logger.log("record: wrote recording reply")

        if let stopSignalPath {
            logger.log("record: waiting for stop file \(stopSignalPath)")
            try waitForStopSignal(at: stopSignalPath)
        } else {
            logger.log("record: waiting for stdin EOF")
            _ = try FileHandle.standardInput.readToEnd()
        }

        logger.log("record: stopping capture")
        try await stream.stopCapture()
        logger.log("record: capture stopped")
        try await waitForRecordingFinish()
        try writer.write(ActionHostResponse(status: "finished", outputPath: outputPath, detail: nil))
        try writeSignalFile(path: finishedSignalPath, contents: "finished\n")
        logger.log("record: wrote finished reply")
    }

    private func waitForStopSignal(at path: String) throws {
        let stopURL = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: stopURL.path) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func waitForRecordingStart() async throws {
        if let recordingError {
            throw recordingError
        }

        if recordingStarted {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    private func waitForRecordingFinish() async throws {
        if let recordingError {
            throw recordingError
        }

        if recordingFinished {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    private func writeSignalFile(path: String?, contents: String) throws {
        guard let path else {
            return
        }

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func handleRecordingFailure(message: String, logPrefix: String, stderrPrefix: String) {
        let error = NSError(
            domain: "ActionHostRecording",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        recordingError = error
        logger.log("\(logPrefix) \(message)")
        try? writeSignalFile(path: finishedSignalPath, contents: "error:\(message)\n")
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        finishContinuation?.resume(throwing: error)
        finishContinuation = nil
        FileHandle.standardError.write(Data("\(stderrPrefix): \(message)\n".utf8))
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.handleRecordingFailure(
                message: message,
                logPrefix: "record: recordingOutput failed",
                stderrPrefix: "ActionHost recording failed"
            )
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            logger.log("record: recording output started")
            recordingStarted = true
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            logger.log("record: recording output finished")
            recordingFinished = true
            finishContinuation?.resume()
            finishContinuation = nil
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.handleRecordingFailure(
                message: message,
                logPrefix: "record: stream stopped with error",
                stderrPrefix: "ActionHost stream stopped"
            )
        }
    }
}

func captureAppWindowScreenshot(bundleId: String, outputPath: String, writer: ResponseWriter) async throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let selection = try await bestWindowSelection(for: bundleId)
    let window = selection.window
    guard let image = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        CGWindowID(window.windowID),
        [.bestResolution, .boundsIgnoreFraming]
    ) else {
        throw ActionHostError.unableToEncodeImage
    }

    guard let data = pngData(from: image) else {
        throw ActionHostError.unableToEncodeImage
    }

    try data.write(to: outputURL)
    try writer.write(ActionHostResponse(status: "screenshot", outputPath: outputPath, detail: nil))
}

func captureRegionScreenshot(rect: CGRect, outputPath: String, writer: ResponseWriter) async throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let content = try await shareableContent()
    guard let selection = regionSelection(for: rect, displays: content.displays) else {
        throw ActionHostError.unsupportedOS("Could not resolve a display for rect \(rect)")
    }

    guard let image = CGDisplayCreateImage(selection.display.displayID, rect: selection.sourceRect) else {
        throw ActionHostError.unableToEncodeImage
    }

    guard let data = pngData(from: image) else {
        throw ActionHostError.unableToEncodeImage
    }

    try data.write(to: outputURL)
    try writer.write(ActionHostResponse(status: "screenshot", outputPath: outputPath, detail: nil))
}

func captureScreenScreenshot(outputPath: String, writer: ResponseWriter) async throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
        throw ActionHostError.unableToEncodeImage
    }

    guard let data = pngData(from: image) else {
        throw ActionHostError.unableToEncodeImage
    }

    try data.write(to: outputURL)
    try writer.write(ActionHostResponse(status: "screenshot", outputPath: outputPath, detail: "main-display"))
}

struct OverlayBounds: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OverlayViewport: Decodable {
    let id: String
    let bounds: OverlayBounds
    let surfaceId: String?
    let dimming: String
}

struct OverlayInputState: Decodable {
    let kind: String
    let keys: [String]?
    let text: String?
    let style: String?
}

struct StageOverlayState: Decodable {
    let sessionId: String
    let phase: String
    let backdrop: String
    let viewport: OverlayViewport?
    let targetApp: String?
    let summary: String
    let detail: String?
    let countdownRemaining: Int?
    let elapsedMs: Double?
    let isRecording: Bool
    let stepCurrent: Int?
    let stepTotal: Int?
    let stepLabel: String?
    let inputOverlay: OverlayInputState?
    let recentLogs: [String]?
}

final class StageOverlayView: NSView {
    var state: StageOverlayState? {
        didSet {
            needsDisplay = true
        }
    }

    let screenFrame: CGRect

    init(frame frameRect: NSRect, screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let state else {
            return
        }

        guard let viewport = viewportRect(for: state) else {
            return
        }

        drawBackdrop(state: state, viewport: viewport)
        drawViewportFrame(state: state, viewport: viewport)

        if state.phase == "countdown", let countdown = state.countdownRemaining {
            drawCountdown(String(countdown), viewport: viewport)
        }

        drawInputOverlay(state: state, viewport: viewport)
    }

    private func viewportRect(for state: StageOverlayState) -> CGRect? {
        guard let bounds = state.viewport?.bounds else {
            return nil
        }

        return CGRect(
            x: bounds.x - screenFrame.minX,
            y: bounds.y - screenFrame.minY,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func drawBackdrop(state: StageOverlayState, viewport: CGRect) {
        let outer = NSBezierPath(rect: bounds)
        let cutout = NSBezierPath(
            roundedRect: viewport,
            xRadius: 8,
            yRadius: 8
        )
        outer.append(cutout)
        outer.windingRule = .evenOdd
        outer.addClip()

        let gradient: NSGradient
        switch state.backdrop {
        case "neutral":
            // Keep the production back sheet opaque so private desktop pixels
            // cannot leak around a staged window or along capture edges.
            NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.12, alpha: 1).setFill()
            bounds.fill()
            return
        case "matte":
            gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.96, alpha: 1),
                NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.95, alpha: 1),
            ])!
        case "gradient":
            gradient = NSGradient(colors: [
                NSColor(calibratedWhite: 0.18, alpha: 1),
                NSColor(calibratedWhite: 0.05, alpha: 1),
            ])!
        case "spotlight":
            gradient = NSGradient(colors: [
                NSColor(calibratedWhite: 0.16, alpha: 1),
                NSColor(calibratedWhite: 0.04, alpha: 1),
            ])!
        default:
            gradient = NSGradient(colors: [
                NSColor(calibratedWhite: 0.14, alpha: 1),
                NSColor(calibratedWhite: 0.04, alpha: 1),
            ])!
        }

        gradient.draw(in: bounds, angle: 300)

        let veilAlpha: CGFloat = state.phase == "countdown" || state.isRecording ? 0.62 : 0.42
        NSColor(calibratedWhite: 0.03, alpha: veilAlpha).setFill()
        bounds.fill()

        drawOrb(
            rect: CGRect(x: 42, y: bounds.height - 220, width: 280, height: 280),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.08)
        )
        drawOrb(
            rect: CGRect(x: bounds.width - 260, y: 42, width: 220, height: 220),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.05)
        )
    }

    private func drawOrb(rect: CGRect, color: NSColor) {
        guard let gradient = NSGradient(colorsAndLocations:
            (color, 0.0),
            (color.withAlphaComponent(0), 1.0)
        ) else {
            return
        }

        let path = NSBezierPath(ovalIn: rect)
        gradient.draw(in: path, relativeCenterPosition: NSZeroPoint)
    }

    private func drawViewportFrame(state: StageOverlayState, viewport: CGRect) {
        let outer = viewport
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.4)
        shadow.set()

        let glowPath = NSBezierPath(roundedRect: outer, xRadius: 8, yRadius: 8)
        let accent = state.isRecording
            ? NSColor(calibratedWhite: 0.9, alpha: 0.82)
            : NSColor(calibratedWhite: 1, alpha: 0.22)
        accent.setStroke()
        glowPath.lineWidth = state.isRecording ? 2 : 1.5
        glowPath.stroke()

        NSGraphicsContext.saveGraphicsState()
        let innerPath = NSBezierPath(roundedRect: viewport, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCountdown(_ text: String, viewport: CGRect) {
        let glow = NSShadow()
        glow.shadowBlurRadius = 36
        glow.shadowOffset = .zero
        glow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.6)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: min(viewport.width, viewport.height) * 0.28, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 0.95),
            .shadow: glow,
        ]
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(
            x: viewport.midX - size.width / 2,
            y: viewport.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attrs)
    }

    private func drawInputOverlay(state: StageOverlayState, viewport: CGRect) {
        guard let overlay = state.inputOverlay else {
            return
        }

        switch overlay.kind {
        case "keys":
            drawKeyOverlay(keys: overlay.keys ?? [], viewport: viewport)
        case "typing":
            drawTypingOverlay(text: overlay.text ?? "", style: overlay.style ?? "default", viewport: viewport)
        default:
            break
        }
    }

    private func drawKeyOverlay(keys: [String], viewport: CGRect) {
        guard !keys.isEmpty else {
            return
        }

        let labels = keys.map(keyOverlayLabel)
        let fonts = labels.map { label in
            NSFont.systemFont(ofSize: ["⌘", "⇧", "⌥", "⌃", "fn"].contains(label) ? 28 : 23, weight: .medium)
        }
        let sizes = zip(labels, fonts).map { label, font in
            (label as NSString).size(withAttributes: [.font: font])
        }
        let keyWidths = zip(labels, sizes).map { label, size in
            max(size.width + 26, ["⌘", "⇧", "⌥", "⌃", "fn"].contains(label) ? 54 : 46)
        }

        let spacing: CGFloat = 8
        let totalWidth = keyWidths.reduce(0, +) + (CGFloat(keyWidths.count - 1) * spacing)
        let panelRect = CGRect(
            x: viewport.midX - totalWidth / 2 - 18,
            y: viewport.minY + 24,
            width: totalWidth + 36,
            height: 72
        )

        let panelShadow = NSShadow()
        panelShadow.shadowBlurRadius = 20
        panelShadow.shadowOffset = .zero
        panelShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.24)
        panelShadow.set()

        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.08, alpha: 0.76).setFill()
        panelPath.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        var cursorX = panelRect.minX + 18
        for (index, label) in labels.enumerated() {
            let width = keyWidths[index]
            let keyRect = CGRect(x: cursorX, y: panelRect.minY + 11, width: width, height: 50)
            drawKeyCap(label: label, rect: keyRect, font: fonts[index])
            cursorX += width + spacing
        }
    }

    private func drawKeyCap(label: String, rect: CGRect, font: NSFont) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.24)
        shadow.set()

        let capRect = rect.insetBy(dx: 2, dy: 2)
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.15, alpha: 0.98).setFill()
        capPath.fill()

        let topRect = CGRect(x: capRect.minX, y: capRect.minY + capRect.height * 0.42, width: capRect.width, height: capRect.height * 0.58)
        let topPath = NSBezierPath(roundedRect: topRect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.24, alpha: 1.0).setFill()
        topPath.fill()

        NSColor(calibratedWhite: 0.08, alpha: 1.0).setStroke()
        capPath.lineWidth = 1
        capPath.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let labelRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 + 2,
            width: size.width,
            height: size.height
        )
        (label as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    private func drawTypingOverlay(text: String, style: String, viewport: CGRect) {
        guard !text.isEmpty else {
            return
        }

        let summary = summarizeTypingText(text)
        let panelWidth = min(viewport.width - 56, max(320, CGFloat(summary.count) * 10.4))
        let panelRect = CGRect(
            x: viewport.midX - panelWidth / 2,
            y: viewport.minY + 24,
            width: panelWidth,
            height: 56
        )

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.16)
        shadow.set()

        let path = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)
        let background: NSColor
        let border: NSColor
        let foreground: NSColor
        let font: NSFont

        switch style {
        case "notes":
            background = NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.90, alpha: 0.97)
            border = NSColor(calibratedRed: 0.90, green: 0.84, blue: 0.66, alpha: 0.85)
            foreground = NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.11, alpha: 1)
            font = NSFont.systemFont(ofSize: 18, weight: .medium)
        case "terminal":
            background = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.95)
            border = NSColor(calibratedRed: 0.26, green: 0.54, blue: 0.32, alpha: 0.72)
            foreground = NSColor(calibratedRed: 0.62, green: 0.95, blue: 0.70, alpha: 1)
            font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        case "code":
            background = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 0.95)
            border = NSColor(calibratedWhite: 1, alpha: 0.12)
            foreground = NSColor(calibratedWhite: 0.94, alpha: 1)
            font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        default:
            background = NSColor(calibratedWhite: 0.12, alpha: 0.90)
            border = NSColor(calibratedWhite: 1, alpha: 0.10)
            foreground = NSColor(calibratedWhite: 0.96, alpha: 1)
            font = NSFont.systemFont(ofSize: 18, weight: .medium)
        }

        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let displayText = style == "terminal" ? "$ \(summary)▌" : "\(summary)▌"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        let size = (displayText as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: panelRect.minX + 20,
            y: panelRect.midY - size.height / 2,
            width: panelRect.width - 40,
            height: size.height
        )
        (displayText as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private func summarizeTypingText(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 46 else {
            return compact
        }
        let index = compact.index(compact.startIndex, offsetBy: 43)
        return "\(compact[..<index])..."
    }

    private func drawText(
        text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

}

/// Controls whether a beat renders a synthetic pointer at all.
///
/// - `auto`: the pointer appears only for deliberate mouse interactions. Keyboard
///   beats (`--key-label`) render captions and key caps with no cursor.
/// - `pointer`: always draw the pointer, even on keyboard beats.
/// - `hidden`: never draw a pointer or caret — captions only.
enum DemoCursorPresentation: String {
    case auto
    case pointer
    case hidden

    static func parse(_ raw: String?) -> DemoCursorPresentation {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "none", "hidden", "off", "caption", "captions", "caption-only":
            return .hidden
        case "pointer", "cursor", "arrow", "always":
            return .pointer
        default:
            return .auto
        }
    }
}

@MainActor
final class DemoCursorOverlayController: NSObject {
    private let writer: ResponseWriter
    private let duration: TimeInterval
    private let startPoint: CGPoint?
    private let endPoint: CGPoint?
    private let clickProgress: Double
    private let labelOverride: String?
    private let statusDetail: String?
    private let keyLabel: String?
    private let typingText: String?
    private let playsTimedTypingSound: Bool
    private let statusOnly: Bool
    private let presentation: DemoCursorPresentation
    private let traceFile: String?
    private let traceTitle: String
    private let previewImagePath: String?
    private var overlayWindow: NSWindow?
    private var overlayView: DemoCursorOverlayView?
    private var timer: Timer?
    private let startedAt = Date()
    private let soundPlayer = DemoCueSoundPlayer()
    private var didPlayClickSound = false
    private var nextTypingSoundProgress = 0.18
    private var nextTracePoll = 0.0
    private var lastTraceData: Data?

    init(
        writer: ResponseWriter,
        durationMs: Double,
        startPoint: CGPoint?,
        endPoint: CGPoint?,
        clickProgress: Double,
        labelOverride: String?,
        statusDetail: String?,
        keyLabel: String?,
        typingText: String?,
        playsTimedTypingSound: Bool,
        statusOnly: Bool,
        presentation: DemoCursorPresentation,
        traceFile: String?,
        traceTitle: String,
        previewImagePath: String?
    ) {
        self.writer = writer
        self.duration = max(0.28, durationMs / 1000.0)
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.clickProgress = min(0.92, max(0.08, clickProgress))
        self.labelOverride = labelOverride
        self.statusDetail = statusDetail
        self.keyLabel = keyLabel
        self.typingText = typingText
        self.playsTimedTypingSound = playsTimedTypingSound
        self.statusOnly = statusOnly
        self.presentation = presentation
        self.traceFile = traceFile
        self.traceTitle = traceTitle
        self.previewImagePath = previewImagePath
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = Self.resolveScreen(startPoint: startPoint, endPoint: endPoint) else {
            throw ActionHostError.unsupportedOS("Could not resolve a screen for demo cursor overlay")
        }

        createWindow(screen: screen)
        try writer.write(
            ActionHostResponse(
                status: "cursor-overlay-running",
                outputPath: nil,
                detail: String(ProcessInfo.processInfo.processIdentifier)
            )
        )

        timer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(tick(_:)),
            userInfo: nil,
            repeats: true
        )

        app.run()
    }

    @objc
    private func tick(_ timer: Timer) {
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= duration {
            timer.invalidate()
            overlayWindow?.orderOut(nil)
            NSApplication.shared.terminate(nil)
            return
        }
        let progress = elapsed / duration
        overlayView?.progress = progress
        reloadTraceLines(elapsed: elapsed)
        playCueSounds(progress: progress)
    }

    private func reloadTraceLines(elapsed: TimeInterval) {
        guard elapsed >= nextTracePoll else {
            return
        }
        nextTracePoll = elapsed + 0.16

        guard let traceFile, !traceFile.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: traceFile)
        guard let data = try? Data(contentsOf: url), data != lastTraceData else {
            return
        }
        lastTraceData = data
        let text = String(decoding: data, as: UTF8.self)
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .suffix(7)
        overlayView?.traceLines = Array(lines)
    }

    private func playCueSounds(progress: Double) {
        if typingText?.isEmpty == false {
            guard playsTimedTypingSound else {
                return
            }
            while progress >= nextTypingSoundProgress && nextTypingSoundProgress < 0.92 {
                soundPlayer.playTyping()
                nextTypingSoundProgress += 0.13
            }
            return
        }

        guard shouldPlayClickSound, !didPlayClickSound, progress >= clickProgress else {
            return
        }
        didPlayClickSound = true
        soundPlayer.playClick()
    }

    private var shouldPlayClickSound: Bool {
        // Keep the audio cue in lockstep with the click affordance: if no pointer is
        // drawn there is nothing on screen for the click to belong to.
        switch presentation {
        case .hidden:
            return false
        case .auto:
            // Keyboard beats never draw a pointer under auto, so no click tick.
            if !(keyLabel?.isEmpty ?? true) || !(typingText?.isEmpty ?? true) {
                return false
            }
        case .pointer:
            break
        }
        guard keyLabel?.isEmpty != false, typingText?.isEmpty != false else {
            return false
        }
        guard let label = labelOverride?.lowercased(), !label.isEmpty else {
            return true
        }
        return label.contains("click") || label.contains("tap") || label.contains("press")
    }

    /// Prefer the display that contains the beat points; fall back to the main screen.
    /// Callers pass start/end in global AppKit coordinates (primary origin at (0,0)).
    static func resolveScreen(startPoint: CGPoint?, endPoint: CGPoint?) -> NSScreen? {
        if let startPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(startPoint) }) {
            return screen
        }
        if let endPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(endPoint) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// `NSWindow(contentRect:…:screen:)` treats `contentRect` as **screen-local**
    /// (origin at the screen's bottom-left). Passing `screen.frame` (global) therefore
    /// double-applies the display origin — e.g. origin.x=3440 becomes window.x=6880.
    /// Content rect must be origin-zero sized to the screen; pin with `setFrame` after.
    static func panelContentRect(for screen: NSScreen) -> CGRect {
        CGRect(origin: .zero, size: screen.frame.size)
    }

    /// Convert a global AppKit point into the overlay view's local coordinates.
    static func localPoint(_ global: CGPoint, on screen: NSScreen) -> CGPoint {
        let origin = screen.frame.origin
        return CGPoint(x: global.x - origin.x, y: global.y - origin.y)
    }

    private func createWindow(screen: NSScreen) {
        let screenFrame = screen.frame
        let overlayWindow = NSPanel(
            contentRect: Self.panelContentRect(for: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Pin in global coordinates so the panel fills this display exactly —
        // including when `NSScreen.main` is not the zero-origin primary.
        overlayWindow.setFrame(screenFrame, display: false)
        overlayWindow.level = .screenSaver
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let size = screenFrame.size
        let resolvedStart = startPoint.map { Self.localPoint($0, on: screen) }
            ?? CGPoint(x: size.width * 0.58, y: size.height * 0.74)
        let resolvedEnd = endPoint.map { Self.localPoint($0, on: screen) }
            ?? CGPoint(x: size.width * 0.93, y: size.height * 0.40)
        let previewImage = previewImagePath.flatMap { NSImage(contentsOfFile: $0) }
        let overlayView = DemoCursorOverlayView(
            frame: CGRect(origin: .zero, size: size),
            startPoint: resolvedStart,
            endPoint: resolvedEnd,
            duration: duration,
            clickProgress: clickProgress,
            labelOverride: labelOverride,
            statusDetail: statusDetail,
            keyLabel: keyLabel,
            typingText: typingText,
            playsTimedTypingSound: playsTimedTypingSound,
            statusOnly: statusOnly,
            presentation: presentation,
            traceLines: [],
            traceTitle: traceTitle,
            previewImage: previewImage
        )
        overlayWindow.contentView = overlayView
        overlayWindow.orderFrontRegardless()

        self.overlayWindow = overlayWindow
        self.overlayView = overlayView
    }
}

@MainActor
final class DemoCueSoundPlayer {
    private let clickData: Data
    private let typingData: [Data]
    private var typingSoundIndex = 0
    private var activeSounds: [NSSound] = []

    init() {
        self.clickData = DemoCueSoundPlayer.makeToneData(
            duration: 0.075,
            volume: 0.24,
            body: { time, phase in
                let bend = 1.0 - phase
                return sin(2.0 * .pi * (620.0 + 280.0 * bend) * time) * 0.78
                    + sin(2.0 * .pi * 1240.0 * time) * 0.18
            }
        )
        let installedTypingData = DemoCueSoundPlayer.loadInstalledTypingKeyData()
        self.typingData = installedTypingData.isEmpty
            ? (0..<4).map { index in
                DemoCueSoundPlayer.makeCreamyTypingKeyData(seed: UInt64(0xA17C10 + index * 73))
            }
            : installedTypingData
    }

    func playClick() {
        play(data: clickData, duration: 0.075, volume: 0.72)
    }

    func playTyping() {
        guard !typingData.isEmpty else {
            return
        }
        let data = typingData[typingSoundIndex % typingData.count]
        typingSoundIndex += 1
        play(data: data, duration: 0.096, volume: 0.38)
    }

    private func play(data: Data, duration: TimeInterval, volume: Float) {
        activeSounds.removeAll { !$0.isPlaying }
        guard let sound = NSSound(data: data) else {
            return
        }
        sound.volume = volume
        activeSounds.append(sound)
        sound.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak self, weak sound] in
            guard let sound else {
                return
            }
            self?.activeSounds.removeAll { $0 === sound }
        }
    }

    private static func makeToneData(
        duration: Double,
        volume: Double,
        body: (Double, Double) -> Double
    ) -> Data {
        let sampleRate = 44_100
        let sampleCount = max(1, Int(duration * Double(sampleRate)))
        var samples = Data(capacity: sampleCount * 2)

        for index in 0..<sampleCount {
            let phase = Double(index) / Double(sampleCount - 1)
            let time = Double(index) / Double(sampleRate)
            let attack = min(1.0, phase / 0.12)
            let decay = pow(max(0.0, 1.0 - phase), 2.4)
            let value = max(-1.0, min(1.0, body(time, phase) * attack * decay * volume))
            appendInt16(Int16(value * Double(Int16.max)), to: &samples)
        }

        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32(UInt32(36 + samples.count), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(UInt32(samples.count), to: &data)
        data.append(samples)
        return data
    }

    private static func makeCreamyTypingKeyData(seed: UInt64) -> Data {
        let sampleRate = 44_100
        let duration = 0.096
        let sampleCount = max(1, Int(duration * Double(sampleRate)))
        let pitchOffset = Double(Int(seed % 5) - 2) * 2.0
        let releaseCenter = 0.047 + Double(seed % 4) * 0.0014
        var randomState = seed == 0 ? 1 : seed
        var feltNoise = 0.0
        var clothNoise = 0.0
        var samples = Data(capacity: sampleCount * 2)

        for index in 0..<sampleCount {
            let phase = Double(index) / Double(sampleCount - 1)
            let time = Double(index) / Double(sampleRate)
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let rawNoise = (Double((randomState >> 33) & 0xFFFF) / 32_767.5) - 1.0
            feltNoise = feltNoise * 0.94 + rawNoise * 0.06
            clothNoise = clothNoise * 0.985 + rawNoise * 0.015

            let pressEnvelope = exp(-time * 34.0)
            let releaseDistance = (time - releaseCenter) / 0.012
            let releaseEnvelope = exp(-(releaseDistance * releaseDistance)) * 0.12
            let bodyEnvelope = exp(-time * 27.0)
            let feltEnvelope = exp(-time * 40.0)
            let airEnvelope = exp(-time * 88.0)

            let body = sin(2.0 * .pi * (96.0 + pitchOffset) * time) * bodyEnvelope * 0.34
                + sin(2.0 * .pi * (188.0 + pitchOffset * 1.4) * time) * bodyEnvelope * 0.21
            let felt = sin(2.0 * .pi * (360.0 + pitchOffset * 2.0) * time) * feltEnvelope * 0.075
            let softPress = feltNoise * pressEnvelope * 0.055
            let softRelease = clothNoise * releaseEnvelope * 0.09
            let air = rawNoise * airEnvelope * 0.018
            let attack = min(1.0, phase / 0.045)
            let value = max(-1.0, min(1.0, (body + felt + softPress + softRelease + air) * attack * 0.42))
            appendInt16(Int16(value * Double(Int16.max)), to: &samples)
        }

        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32(UInt32(36 + samples.count), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(UInt32(samples.count), to: &data)
        data.append(samples)
        return data
    }

    private static func loadInstalledTypingKeyData() -> [Data] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        if let override = ProcessInfo.processInfo.environment["ACTION_TYPING_SOUNDS_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(applicationSupport.appendingPathComponent("Action/Typing", isDirectory: true))
        }

        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let soundFiles = files
                .filter { ["wav", "aif", "aiff", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let data = soundFiles.compactMap { try? Data(contentsOf: $0) }
            if !data.isEmpty {
                return data
            }
        }

        return []
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

final class DemoCursorOverlayView: NSView {
    /// Drawn height of the pointer glyph in points. Sized to read as a real macOS
    /// pointer at recording scale rather than as a prop: precise, not a focal point.
    private static let pointerHeight: CGFloat = 23

    /// Pointer silhouette normalised to a 1.0-tall bounding box with the hotspot at
    /// the origin and the body extending down-right (view coordinates are y-up).
    private static let pointerUnitPath: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),
        CGPoint(x: 0.000, y: -0.735),
        CGPoint(x: 0.180, y: -0.560),
        CGPoint(x: 0.300, y: -0.955),
        CGPoint(x: 0.436, y: -0.900),
        CGPoint(x: 0.318, y: -0.512),
        CGPoint(x: 0.620, y: -0.512),
    ]

    private let startPoint: CGPoint
    private let endPoint: CGPoint
    private let duration: TimeInterval
    private let clickProgress: Double
    private let labelOverride: String?
    private let statusDetail: String?
    private let keyLabel: String?
    private let typingText: String?
    private let playsTimedTypingSound: Bool
    private let statusOnly: Bool
    private let presentation: DemoCursorPresentation
    private let traceTitle: String
    private let previewImage: NSImage?
    var traceLines: [String] {
        didSet {
            needsDisplay = true
        }
    }
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    init(
        frame frameRect: CGRect,
        startPoint: CGPoint,
        endPoint: CGPoint,
        duration: TimeInterval,
        clickProgress: Double,
        labelOverride: String?,
        statusDetail: String?,
        keyLabel: String?,
        typingText: String?,
        playsTimedTypingSound: Bool,
        statusOnly: Bool,
        presentation: DemoCursorPresentation,
        traceLines: [String],
        traceTitle: String,
        previewImage: NSImage?
    ) {
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.duration = max(0.05, duration)
        self.clickProgress = clickProgress
        self.labelOverride = labelOverride
        self.statusDetail = statusDetail
        self.keyLabel = keyLabel
        self.typingText = typingText
        self.playsTimedTypingSound = playsTimedTypingSound
        self.statusOnly = statusOnly
        self.presentation = presentation
        self.traceLines = traceLines
        self.traceTitle = traceTitle
        self.previewImage = previewImage
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if statusOnly {
            drawScreenStatusHUD()
            drawPreviewPanel()
            drawTraceStrip()
            return
        }

        let point = cursorPoint(for: progress)

        if showsPointer {
            drawTrail(progress: progress)
            drawClickFeedback(at: point)
            if isTypingCue {
                drawTypingCaret(at: point)
            } else {
                drawCursor(at: point, scale: cursorScale())
            }
        }
        drawKeyChordCue(at: point)
        drawTypingCue(at: point)
        drawActionPill(at: point)
        drawScreenStatusHUD()
        drawPreviewPanel()
        drawTraceStrip()
    }

    /// True when this beat is a deliberate mouse interaction that deserves a synthetic
    /// pointer. Keyboard beats (key chords and typing) resolve to `false` under `.auto`
    /// so captions and key caps stand alone with no cursor or caret on screen.
    private var showsPointer: Bool {
        switch presentation {
        case .hidden:
            return false
        case .pointer:
            return true
        case .auto:
            let hasKeyChord = !(keyLabel?.isEmpty ?? true)
            let hasTyping = !(typingText?.isEmpty ?? true)
            return !hasKeyChord && !hasTyping
        }
    }

    private func cursorPoint(for rawProgress: Double) -> CGPoint {
        // With no pointer on screen the cue panels anchor on a fixed point rather than
        // tracking an invisible one.
        if isTypingCue || !showsPointer {
            return startPoint
        }

        let clipped = min(1, max(0, rawProgress))
        let eased = pointerEase(clipped)
        let base = CGPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * eased,
            y: startPoint.y + (endPoint.y - startPoint.y) * eased
        )
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let distance = max(1, hypot(dx, dy))
        // A shallow bow reads as a hand moving a mouse; anything larger reads as a cartoon.
        let arc = sin(.pi * clipped) * min(14, distance * 0.035)

        return CGPoint(
            x: base.x + (-dy / distance) * arc,
            y: base.y + (dx / distance) * arc
        )
    }

    /// Instantaneous pointer speed in points per second, sampled across one frame.
    private func pointerSpeed(at rawProgress: Double) -> Double {
        let frame = 1.0 / 60.0
        let step = frame / duration
        let head = cursorPoint(for: rawProgress)
        let tail = cursorPoint(for: max(0, rawProgress - step))
        return hypot(head.x - tail.x, head.y - tail.y) / frame
    }

    private func drawTrail(progress: Double) {
        guard !isTypingCue else {
            return
        }

        // The trail is a speed readout, not decoration: it fades out as the pointer
        // settles, so arrival always looks precise.
        let speed = pointerSpeed(at: progress)
        let intensity = min(1.0, max(0.0, (speed - 240) / 1500))
        guard intensity > 0.03 else {
            return
        }

        let tailSeconds = 0.13
        let segments = 11
        let span = tailSeconds / duration
        let points = (0...segments).map { index -> CGPoint in
            cursorPoint(for: max(0, progress - span * Double(index) / Double(segments)))
        }

        for index in 0..<segments {
            let fade = 1 - Double(index) / Double(segments)
            let alpha = CGFloat(intensity * 0.30 * fade * fade)
            guard alpha > 0.004 else {
                continue
            }
            let width = CGFloat(0.6 + 1.9 * fade)
            let segment = NSBezierPath()
            segment.move(to: points[index])
            segment.line(to: points[index + 1])
            segment.lineCapStyle = .round

            // Dual contrast: a dark outer pass keeps the trail visible on light
            // desktops, the light inner pass keeps it visible on dark ones.
            segment.lineWidth = width + 1.3
            NSColor(calibratedWhite: 0.05, alpha: alpha * 0.42).setStroke()
            segment.stroke()

            segment.lineWidth = width
            NSColor(calibratedWhite: 1, alpha: alpha).setStroke()
            segment.stroke()
        }
    }

    private func drawClickFeedback(at point: CGPoint) {
        guard showsClickFeedback else {
            return
        }

        // Timed in seconds rather than progress so the affordance reads identically
        // whether the beat is 900ms or 2600ms long.
        let elapsedSinceClick = (progress - clickProgress) * duration
        let leadIn = 0.04
        let ringLife = 0.26
        guard elapsedSinceClick > -leadIn, elapsedSinceClick < ringLife else {
            return
        }

        let t = max(0, elapsedSinceClick / ringLife)
        let ease = 1 - pow(1 - t, 2.4)
        let radius = CGFloat(8.5 + 21 * ease)
        let alpha = CGFloat(0.52 * pow(1 - t, 1.6))

        let ring = NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        ring.lineWidth = CGFloat(1.9 - 1.1 * t) + 1.1
        NSColor(calibratedWhite: 0.05, alpha: alpha * 0.34).setStroke()
        ring.stroke()
        ring.lineWidth = CGFloat(1.9 - 1.1 * t)
        NSColor(calibratedWhite: 1, alpha: alpha).setStroke()
        ring.stroke()

        // A tight flash at the hotspot marks the exact contact point.
        let flash = CGFloat(max(0, 1 - abs(elapsedSinceClick) / 0.09))
        guard flash > 0 else {
            return
        }
        let dotRadius: CGFloat = 3.4
        NSColor(calibratedWhite: 1, alpha: 0.62 * flash * flash).setFill()
        NSBezierPath(
            ovalIn: CGRect(
                x: point.x - dotRadius,
                y: point.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
        ).fill()
    }

    private func drawCursor(at point: CGPoint, scale: CGFloat) {
        let height = DemoCursorOverlayView.pointerHeight * scale
        let path = NSBezierPath()
        for (index, unit) in DemoCursorOverlayView.pointerUnitPath.enumerated() {
            let resolved = CGPoint(x: point.x + unit.x * height, y: point.y + unit.y * height)
            if index == 0 {
                path.move(to: resolved)
            } else {
                path.line(to: resolved)
            }
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        // Wide, faint ambient pass: separates the silhouette from bright desktops
        // without reading as a glow.
        NSGraphicsContext.saveGraphicsState()
        let ambient = NSShadow()
        ambient.shadowBlurRadius = 10
        ambient.shadowOffset = CGSize(width: 0, height: -2)
        ambient.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        ambient.set()
        NSColor(calibratedWhite: 0, alpha: 0.001).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Contact shadow rides a real path fill so AppKit actually casts it.
        NSGraphicsContext.saveGraphicsState()
        let contact = NSShadow()
        contact.shadowBlurRadius = 3.2
        contact.shadowOffset = CGSize(width: 0, height: -1.1)
        contact.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.36)
        contact.set()
        NSColor(calibratedWhite: 0.97, alpha: 0.99).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Soft vertical shading on top of the filled body — physical, not painted.
        if let body = NSGradient(colors: [
            NSColor(calibratedWhite: 1.00, alpha: 0.99),
            NSColor(calibratedWhite: 0.93, alpha: 0.99),
        ]) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            body.draw(in: path.bounds, angle: 270)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Hairline outline for light desktops; scaled so it never thickens into a
        // cartoon border as the press dip changes size. Dual shadows above keep
        // the glyph readable on near-black wallpapers without a second outline.
        NSColor(calibratedWhite: 0.07, alpha: 0.94).setStroke()
        path.lineWidth = max(0.9, height * 0.046)
        path.stroke()
    }

    private func drawTypingCaret(at point: CGPoint) {
        // Blink on a wall-clock period so short and long beats pulse at the same rate.
        let elapsed = progress * duration
        let pulse = 0.78 + 0.22 * abs(sin(elapsed * .pi / 0.45))
        let height: CGFloat = 30
        let width: CGFloat = 3
        let caretRect = CGRect(
            x: point.x - width / 2,
            y: point.y - height * 0.46,
            width: width,
            height: height
        )

        let halo = NSBezierPath(
            roundedRect: caretRect.insetBy(dx: -10, dy: -6),
            xRadius: 12,
            yRadius: 12
        )
        NSColor(calibratedRed: 0.79, green: 0.74, blue: 0.60, alpha: 0.055 * pulse).setFill()
        halo.fill()

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(calibratedRed: 0.66, green: 0.62, blue: 0.48, alpha: 0.14 * pulse)
        shadow.set()

        let caret = NSBezierPath(roundedRect: caretRect, xRadius: 2.5, yRadius: 2.5)
        NSColor(calibratedRed: 0.92, green: 0.86, blue: 0.70, alpha: 0.76 * pulse).setFill()
        caret.fill()

        let capWidth: CGFloat = 20
        let topCap = NSBezierPath(
            roundedRect: CGRect(x: point.x - capWidth / 2, y: caretRect.maxY - 2, width: capWidth, height: 4),
            xRadius: 2,
            yRadius: 2
        )
        let bottomCap = NSBezierPath(
            roundedRect: CGRect(x: point.x - capWidth / 2, y: caretRect.minY - 2, width: capWidth, height: 4),
            xRadius: 2,
            yRadius: 2
        )
        NSColor(calibratedRed: 0.92, green: 0.86, blue: 0.70, alpha: 0.36 * pulse).setFill()
        topCap.fill()
        bottomCap.fill()
    }

    private var showsClickFeedback: Bool {
        guard showsPointer else {
            return false
        }
        guard keyLabel?.isEmpty != false, typingText?.isEmpty != false else {
            return false
        }
        guard let label = labelOverride?.lowercased(), !label.isEmpty else {
            return true
        }
        return label.contains("click") || label.contains("tap") || label.contains("press")
    }

    private var isTypingCue: Bool {
        typingText?.isEmpty == false
    }

    private func cursorScale() -> CGFloat {
        // The only scale change is a shallow press dip at the click instant. Travel
        // bounce reads as playful; a press dip reads as mechanical and deliberate.
        guard showsClickFeedback else {
            return 1
        }
        let elapsedSinceClick = abs(progress - clickProgress) * duration
        let window = 0.11
        guard elapsedSinceClick < window else {
            return 1
        }
        let press = 1 - elapsedSinceClick / window
        return CGFloat(1 - 0.085 * press * press)
    }

    private func drawActionPill(at point: CGPoint) {
        let label: String
        let accent: NSColor
        if let labelOverride, !labelOverride.isEmpty {
            label = labelOverride
            accent = accentColor(for: labelOverride)
        } else if progress < clickProgress - 0.08 {
            label = "Move"
            accent = accentColor(for: label)
        } else if progress < clickProgress + 0.12 {
            label = "Click"
            accent = accentColor(for: label)
        } else {
            label = "Typing"
            accent = accentColor(for: label)
        }

        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let pillRect = CGRect(
            x: min(bounds.maxX - textSize.width - 46, point.x + 34),
            y: max(bounds.minY + 18, point.y - 62),
            width: textSize.width + 30,
            height: 32
        )

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.14)
        shadow.set()

        let path = NSBezierPath(roundedRect: pillRect, xRadius: 16, yRadius: 16)
        NSColor(calibratedWhite: 0.06, alpha: 0.62).setFill()
        path.fill()
        accent.withAlphaComponent(0.34).setStroke()
        path.lineWidth = 1.1
        path.stroke()

        accent.withAlphaComponent(0.58).setFill()
        NSBezierPath(ovalIn: CGRect(x: pillRect.minX + 11, y: pillRect.midY - 4, width: 8, height: 8)).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.96),
        ]
        (label as NSString).draw(
            in: CGRect(
                x: pillRect.minX + 25,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attrs
        )
    }

    private func drawKeyChordCue(at point: CGPoint) {
        guard let keyLabel, !keyLabel.isEmpty else {
            return
        }
        let alpha = cueAlpha()
        guard alpha > 0 else {
            return
        }

        let rect = anchoredRect(near: point, width: 292, height: 92, yOffset: 58)
        drawOverlayPanel(rect: rect, alpha: alpha, accent: accentColor(for: "key"))

        drawText(
            text: "Key chord",
            in: CGRect(x: rect.minX + 18, y: rect.maxY - 31, width: rect.width - 36, height: 18),
            font: NSFont.systemFont(ofSize: 12, weight: .medium),
            color: NSColor(calibratedWhite: 1, alpha: 0.48 * alpha)
        )
        drawText(
            text: keyLabel,
            in: CGRect(x: rect.minX + 18, y: rect.minY + 19, width: rect.width - 36, height: 42),
            font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold),
            color: NSColor(calibratedWhite: 1, alpha: 0.90 * alpha),
            alignment: .center
        )
    }

    private func drawTypingCue(at point: CGPoint) {
        guard let typingText, !typingText.isEmpty else {
            return
        }
        let alpha = cueAlpha()
        guard alpha > 0 else {
            return
        }

        let rect = anchoredRect(near: point, width: 430, height: 86, yOffset: 58)
        drawOverlayPanel(rect: rect, alpha: alpha, accent: accentColor(for: "typing"))

        drawText(
            text: "Typing",
            in: CGRect(x: rect.minX + 18, y: rect.maxY - 30, width: rect.width - 36, height: 18),
            font: NSFont.systemFont(ofSize: 12, weight: .medium),
            color: NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.74, alpha: 0.50 * alpha)
        )

        let displayText = summarizeOverlayText(typingText)
        drawText(
            text: "\(displayText)|",
            in: CGRect(x: rect.minX + 18, y: rect.minY + 20, width: rect.width - 36, height: 32),
            font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            color: NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.84, alpha: 0.88 * alpha)
        )
    }

    private func drawScreenStatusHUD() {
        let label = currentActionLabel()
        let alpha = cueAlpha()
        guard alpha > 0 else {
            return
        }

        let rect = CGRect(
            x: bounds.maxX - 294,
            y: bounds.maxY - 86,
            width: 262,
            height: statusDetail?.isEmpty == false ? 56 : 42
        )
        let accent = accentColor(for: label)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.12 * alpha)
        shadow.set()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.045, alpha: 0.42 * alpha).setFill()
        panel.fill()
        NSColor(calibratedWhite: 1, alpha: 0.055 * alpha).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        accent.withAlphaComponent(0.50 * alpha).setFill()
        NSBezierPath(ovalIn: CGRect(x: rect.minX + 13, y: rect.midY - 4, width: 8, height: 8)).fill()

        drawText(
            text: "Action",
            in: CGRect(x: rect.minX + 29, y: rect.maxY - 22, width: 62, height: 15),
            font: NSFont.systemFont(ofSize: 10, weight: .medium),
            color: NSColor(calibratedWhite: 1, alpha: 0.36 * alpha)
        )
        drawText(
            text: label,
            in: CGRect(x: rect.minX + 29, y: rect.maxY - 40, width: rect.width - 42, height: 18),
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: NSColor(calibratedWhite: 1, alpha: 0.78 * alpha)
        )

        if let statusDetail, !statusDetail.isEmpty {
            drawText(
                text: statusDetail,
                in: CGRect(x: rect.minX + 29, y: rect.minY + 8, width: rect.width - 42, height: 15),
                font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                color: NSColor(calibratedWhite: 1, alpha: 0.46 * alpha)
            )
        }

        let trackRect = CGRect(x: rect.maxX - 76, y: rect.maxY - 16, width: 48, height: 2)
        NSColor(calibratedWhite: 1, alpha: 0.08 * alpha).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1).fill()
        accent.withAlphaComponent(0.38 * alpha).setFill()
        NSBezierPath(
            roundedRect: CGRect(
                x: trackRect.minX,
                y: trackRect.minY,
                width: trackRect.width * CGFloat(min(1, max(0, progress))),
                height: trackRect.height
            ),
            xRadius: 1,
            yRadius: 1
        ).fill()
    }

    private func drawPreviewPanel() {
        guard let previewImage else {
            return
        }
        let alpha = cueAlpha()
        guard alpha > 0 else {
            return
        }

        let rect = CGRect(
            x: bounds.maxX - 392,
            y: bounds.maxY - 336,
            width: 360,
            height: 222
        )
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.16 * alpha)
        shadow.set()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.045, alpha: 0.42 * alpha).setFill()
        panel.fill()
        NSColor(calibratedWhite: 1, alpha: 0.055 * alpha).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        drawText(
            text: "Preview",
            in: CGRect(x: rect.minX + 14, y: rect.maxY - 25, width: rect.width - 28, height: 15),
            font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            color: NSColor(calibratedWhite: 1, alpha: 0.48 * alpha)
        )

        let imageBounds = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: rect.width - 24, height: rect.height - 46)
        let imageSize = previewImage.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return
        }
        let scale = min(imageBounds.width / imageSize.width, imageBounds.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let imageRect = CGRect(
            x: imageBounds.midX - drawSize.width / 2,
            y: imageBounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageBounds, xRadius: 9, yRadius: 9).addClip()
        NSColor(calibratedWhite: 0, alpha: 0.20 * alpha).setFill()
        NSBezierPath(rect: imageBounds).fill()
        previewImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 0.92 * alpha)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func currentActionLabel() -> String {
        if let keyLabel, !keyLabel.isEmpty {
            return keyLabel
        }
        if typingText?.isEmpty == false {
            return "Typing"
        }
        if let labelOverride, !labelOverride.isEmpty {
            return labelOverride
        }
        if progress < clickProgress - 0.08 {
            return "Move"
        }
        if progress < clickProgress + 0.12 {
            return "Click"
        }
        return "Typing"
    }

    private func drawTraceStrip() {
        guard !traceLines.isEmpty else {
            return
        }
        let alpha = cueAlpha()
        guard alpha > 0 else {
            return
        }

        let visibleLines = Array(traceLines.suffix(7))
        let width: CGFloat = 360
        let rowHeight: CGFloat = 20
        let height = CGFloat(42 + visibleLines.count * Int(rowHeight))
        let rect = CGRect(
            x: bounds.maxX - width - 32,
            y: bounds.maxY - (previewImage == nil ? 104 : 354) - height,
            width: width,
            height: height
        )

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.12 * alpha)
        shadow.set()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.045, alpha: 0.36 * alpha).setFill()
        panel.fill()
        NSColor(calibratedWhite: 1, alpha: 0.045 * alpha).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        drawText(
            text: traceTitle,
            in: CGRect(x: rect.minX + 14, y: rect.maxY - 27, width: rect.width - 28, height: 15),
            font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            color: NSColor(calibratedWhite: 1, alpha: 0.46 * alpha)
        )

        for (index, line) in visibleLines.enumerated() {
            let parsed = parseTraceLine(line)
            let y = rect.maxY - 49 - CGFloat(index) * rowHeight
            let dotRect = CGRect(x: rect.minX + 15, y: y + 4, width: 7, height: 7)
            accentColor(for: parsed.kind).withAlphaComponent(0.54 * alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            drawText(
                text: parsed.text,
                in: CGRect(x: rect.minX + 30, y: y - 1, width: rect.width - 46, height: 16),
                font: NSFont.systemFont(ofSize: 11, weight: index == visibleLines.count - 1 ? .semibold : .regular),
                color: NSColor(calibratedWhite: 1, alpha: (index == visibleLines.count - 1 ? 0.72 : 0.48) * alpha)
            )
        }
    }

    private func parseTraceLine(_ line: String) -> (kind: String, text: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.firstIndex(of: "|") {
            let kind = String(trimmed[..<separator])
            let text = String(trimmed[trimmed.index(after: separator)...])
            return (kind: kind, text: summarizeTraceText(text))
        }
        return (kind: trimmed, text: summarizeTraceText(trimmed))
    }

    private func summarizeTraceText(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 52 else {
            return compact
        }
        let index = compact.index(compact.startIndex, offsetBy: 49)
        return "\(compact[..<index])..."
    }

    private func accentColor(for label: String) -> NSColor {
        let lower = label.lowercased()
        if lower.contains("observe") {
            return NSColor(calibratedRed: 0.56, green: 0.61, blue: 0.76, alpha: 1)
        }
        if lower.contains("act") {
            return NSColor(calibratedRed: 0.70, green: 0.61, blue: 0.47, alpha: 1)
        }
        if lower.contains("type") || lower.contains("typing") {
            return NSColor(calibratedRed: 0.76, green: 0.69, blue: 0.51, alpha: 1)
        }
        if lower.contains("inspect") {
            return NSColor(calibratedRed: 0.66, green: 0.57, blue: 0.78, alpha: 1)
        }
        if lower.contains("resolve") {
            return NSColor(calibratedRed: 0.52, green: 0.69, blue: 0.66, alpha: 1)
        }
        if lower.contains("verify") {
            return NSColor(calibratedRed: 0.58, green: 0.72, blue: 0.50, alpha: 1)
        }
        if lower.contains("open") {
            return NSColor(calibratedRed: 0.72, green: 0.60, blue: 0.48, alpha: 1)
        }
        if lower.contains("click") || lower.contains("tap") || lower.contains("press") {
            return NSColor(calibratedRed: 0.50, green: 0.64, blue: 0.73, alpha: 1)
        }
        if lower.contains("key") || lower.contains("command") {
            return NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.75, alpha: 1)
        }
        return NSColor(calibratedRed: 0.56, green: 0.63, blue: 0.69, alpha: 1)
    }

    private func cueAlpha() -> CGFloat {
        let fadeIn = min(1, max(0, progress / 0.16))
        let fadeOut = min(1, max(0, (1 - progress) / 0.18))
        return CGFloat(min(fadeIn, fadeOut))
    }

    private func anchoredRect(near point: CGPoint, width: CGFloat, height: CGFloat, yOffset: CGFloat) -> CGRect {
        let x = min(bounds.maxX - width - 24, max(bounds.minX + 24, point.x - width / 2))
        let y = min(bounds.maxY - height - 24, max(bounds.minY + 24, point.y + yOffset))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func drawOverlayPanel(rect: CGRect, alpha: CGFloat, accent: NSColor) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -7)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.14 * alpha)
        shadow.set()

        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.05, alpha: 0.64 * alpha).setFill()
        path.fill()
        accent.withAlphaComponent(0.30 * alpha).setStroke()
        path.lineWidth = 1.1
        path.stroke()
    }

    private func summarizeOverlayText(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 34 else {
            return compact
        }
        let index = compact.index(compact.startIndex, offsetBy: 31)
        return "\(compact[..<index])..."
    }

    private func drawText(
        text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

    /// Restrained ease-in-out: starts deliberate, arrives without overshoot.
    /// Replaces the older playful cubic that overshot and read as cartoon motion.
    private func pointerEase(_ value: Double) -> Double {
        let clipped = min(1, max(0, value))
        // Smoothstep (Hermite): 3t² − 2t³ — no overshoot, no bounce.
        return clipped * clipped * (3 - 2 * clipped)
    }
}

@MainActor
final class StageOverlayController: NSObject {
    private let stateFile: String
    private let stopFile: String
    private let writer: ResponseWriter
    private let logger: DebugLogger
    private let controlFile: String?
    private let parentProcessID: pid_t?
    private var overlayWindow: NSWindow?
    private var controlWindow: StageHUDPanel?
    private var overlayView: StageOverlayView?
    private var controlViewModel: StageHUDViewModel?
    private var lastStateData: Data?
    private var pollTimer: Timer?
    private var currentPhase: String = "staging"
    private var supervisionRegistrationID: String?

    init(
        stateFile: String,
        stopFile: String,
        replyFile: String?,
        debugLogPath: String?,
        controlFile: String?,
        parentProcessID: pid_t?
    ) {
        self.stateFile = stateFile
        self.stopFile = stopFile
        self.writer = ResponseWriter(replyFile: replyFile)
        self.logger = DebugLogger(path: debugLogPath)
        self.controlFile = controlFile
        self.parentProcessID = parentProcessID
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try writer.write(
            ActionHostResponse(
                status: "overlay-running",
                outputPath: nil,
                detail: String(ProcessInfo.processInfo.processIdentifier)
            )
        )
        try refreshState(force: true)
        startPolling()
        app.run()
    }

    private func refreshState(force: Bool) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: stateFile))
        if !force, data == lastStateData {
            return
        }

        let state = try JSONDecoder().decode(StageOverlayState.self, from: data)
        lastStateData = data
        currentPhase = state.phase
        logger.log("stage-overlay: apply phase=\(state.phase) summary=\(state.summary)")
        apply(state: state)
    }

    private func apply(state: StageOverlayState) {
        guard let viewport = state.viewport else {
            return
        }

        let viewportRect = CGRect(
            x: viewport.bounds.x,
            y: viewport.bounds.y,
            width: viewport.bounds.width,
            height: viewport.bounds.height
        )
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: viewportRect.midX, y: viewportRect.midY)) })
            ?? NSScreen.main
        guard let screen else {
            return
        }

        if overlayWindow == nil || overlayWindow?.screen != screen {
            logger.log("stage-overlay: create window on screen \(screen.frame)")
            createWindow(screen: screen)
        }

        overlayWindow?.setFrame(screen.frame, display: true)
        overlayView?.state = state
        controlViewModel?.phase = state.phase
        controlViewModel?.targetApp = state.targetApp ?? "Action"
        controlViewModel?.summary = state.summary
        controlViewModel?.detail = state.detail
        controlViewModel?.stepLabel = state.stepLabel
        controlViewModel?.countdownRemaining = state.countdownRemaining
        controlViewModel?.recentLogs = state.recentLogs ?? []
        controlViewModel?.elapsedMs = state.elapsedMs
        if let dockFrame = controlPanelFrame(screenFrame: screen.frame, viewportRect: viewportRect) {
            controlWindow?.setFrame(dockFrame, display: true)
        }
        overlayWindow?.orderFrontRegardless()
        controlWindow?.orderFrontRegardless()
        updateSupervisionRegistration(for: state)
        logger.log("stage-overlay: window ordered front viewport=\(viewportRect)")
    }

    private func createWindow(screen: NSScreen) {
        let overlayWindow = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // The interactive HUD is constrained to the floating layer. Keep the
        // paired veil there too, then order the HUD after it deterministically.
        overlayWindow.level = .floating
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let overlayView = StageOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame)
        overlayWindow.contentView = overlayView
        self.overlayWindow = overlayWindow
        self.overlayView = overlayView

        guard controlFile != nil else {
            self.controlWindow = nil
            self.controlViewModel = nil
            return
        }

        let controlSize = CGSize(width: 336, height: 456)
        let controlWindow = StageHUDPanel(
            contentRect: CGRect(origin: .zero, size: controlSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        controlWindow.level = actionHUDPanelLevel()
        controlWindow.isOpaque = false
        controlWindow.backgroundColor = .clear
        // AppKit shadows follow the rectangular window bounds, not the
        // chamfered transparent shell. SwiftUI draws the shape-aware shadow.
        controlWindow.hasShadow = false
        controlWindow.ignoresMouseEvents = false
        controlWindow.isMovable = false
        controlWindow.isFloatingPanel = true
        controlWindow.hidesOnDeactivate = false
        controlWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        controlWindow.isReleasedWhenClosed = false
        let controlViewModel = StageHUDViewModel()
        controlViewModel.onCommand = { [weak self] command in
            self?.appendControlCommand(command)
        }
        let controlView = NSHostingView(rootView: StageHUDRootView(model: controlViewModel))
        controlView.frame = CGRect(origin: .zero, size: controlSize)
        controlView.autoresizingMask = [.width, .height]
        controlWindow.contentView = controlView
        self.controlWindow = controlWindow
        self.controlViewModel = controlViewModel
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        if FileManager.default.fileExists(atPath: stopFile) {
            logger.log("stage-overlay: stop signal received")
            shutdown()
            return
        }

        // The drape is an opaque sheet over the operator's screen, and it is launched
        // through open(1), so it is not a child of the runtime and the OS will not reap
        // it. The stop file is written by clearStage, which a crashed or killed
        // orchestrator never reaches — leaving the desktop covered with no way to
        // dismiss it and no indication of what put it there. Outliving the process that
        // asked for it is the one thing a drape must not do.
        if let parentProcessID, kill(parentProcessID, 0) != 0 {
            logger.log("stage-overlay: orchestrator \(parentProcessID) is gone, dismissing")
            shutdown()
            return
        }

        enforceTopOrder()

        if shouldHandleControlCommandsLocally() {
            let commands = readControlCommands()
            if commands.contains("clear") || commands.contains("quit") {
                logger.log("stage-overlay: local dismiss command received")
                shutdown()
                return
            }
        }

        do {
            try refreshState(force: false)
        } catch {
            logger.log("stage-overlay: refresh failed \(error.localizedDescription)")
        }
    }

    private func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        overlayWindow?.orderOut(nil)
        controlWindow?.orderOut(nil)
        if let supervisionRegistrationID {
            ActionSupervisionRegistry.unregister(id: supervisionRegistrationID)
            self.supervisionRegistrationID = nil
        }
        NSApplication.shared.stop(nil)
    }

    private func controlPanelFrame(screenFrame: CGRect, viewportRect: CGRect) -> CGRect? {
        let edgePadding: CGFloat = 16
        let topPadding: CGFloat = 18
        let bottomPadding: CGFloat = 16
        let panelWidth: CGFloat = 336
        let panelHeight: CGFloat = min(456, screenFrame.height - topPadding - bottomPadding)
        let x = screenFrame.maxX - edgePadding - panelWidth
        let preferredTopAlignedY = viewportRect.maxY - panelHeight + 6
        let y = min(
            screenFrame.maxY - topPadding - panelHeight,
            max(screenFrame.minY + bottomPadding, preferredTopAlignedY)
        )
        return CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private func appendControlCommand(_ command: String) {
        guard let controlFile else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let line = "\(command)\n"
            do {
                let url = URL(fileURLWithPath: controlFile)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: controlFile) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                } else {
                    try Data(line.utf8).write(to: url)
                }
            } catch {
                FileHandle.standardError.write(Data("ActionHost control write failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func shouldHandleControlCommandsLocally() -> Bool {
        switch currentPhase {
        case "created", "staging", "completed", "failed", "cancelled":
            return true
        default:
            return false
        }
    }

    private func readControlCommands() -> [String] {
        guard let controlFile,
              FileManager.default.fileExists(atPath: controlFile),
              let raw = try? String(contentsOfFile: controlFile, encoding: .utf8) else {
            return []
        }

        let commands = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return commands
    }

    private func enforceTopOrder() {
        overlayWindow?.orderFrontRegardless()
        controlWindow?.orderFrontRegardless()
    }

    private func updateSupervisionRegistration(for state: StageOverlayState) {
        guard controlFile != nil || !stopFile.isEmpty else {
            return
        }

        let registrationID = "stage-overlay-\(state.sessionId)"
        if supervisionRegistrationID != registrationID {
            if let supervisionRegistrationID {
                ActionSupervisionRegistry.unregister(id: supervisionRegistrationID)
            }
            supervisionRegistrationID = registrationID
        }

        let detail = state.targetApp.map { "\($0) · \(state.phase)" } ?? "Action · \(state.phase)"
        do {
            try ActionSupervisionRegistry.register(
                id: registrationID,
                title: "Action Supervision",
                detail: detail,
                controlFile: controlFile,
                stopFile: stopFile,
                ownsVisibleControls: controlWindow != nil
            )
        } catch {
            logger.log("stage-overlay: supervision registration failed \(error.localizedDescription)")
        }
    }
}

func rectFromOptions(_ options: CommandOptions) throws -> CGRect {
    let x = Double(try options.required("x")) ?? 0
    let y = Double(try options.required("y")) ?? 0
    let width = Double(try options.required("width")) ?? 0
    let height = Double(try options.required("height")) ?? 0

    return CGRect(x: x, y: y, width: width, height: height)
}

func resolvedFinishedSignalPath(from options: CommandOptions) -> String {
    if let path = options.options["finished-file"], !path.isEmpty {
        return path
    }

    let outputBase = options.options["output"] ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).path
    return "\(outputBase).finished"
}

func waitForFinishedSignal(at path: String) throws {
    while !FileManager.default.fileExists(atPath: path) {
        Thread.sleep(forTimeInterval: 0.1)
    }

    let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    if contents.hasPrefix("error:") {
        throw ActionHostError.captureFailed(String(contents.dropFirst("error:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Quit the launcher without disconnecting persistent monitors or stopping independent tasks.
///
/// Asks first with `terminate()` — the quit Apple Event, which lets the app run
/// `applicationWillTerminate` and stop its agent child — and escalates to
/// `forceTerminate()` only for whatever is still standing when the grace period
/// runs out. A single healthy instance answers in about 0.15s; the long tail is
/// an instance that is wedged, and forcing that one is the point.
func terminateRunningActionApps(timeout: TimeInterval = 6, logger: DebugLogger) -> Bool {
    let bundleId = ActionAppIdentity.mainBundleIdentifier

    // Everything except this process. `bun run native:host -- quit-app` runs the same
    // executable out of the same bundle, so it is itself an instance of
    // dev.lattices.Action: without this filter the command terminates itself
    // before it can write its reply, and the caller sees a hang followed by
    // "ActionHost did not write a reply file".
    let selfPid = ProcessInfo.processInfo.processIdentifier
    // Snapshot only positively identified launchers. Unknown processes are preserved;
    // a shared bundle ID is not ownership of a display, recording, or another task.
    let launchers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0.processIdentifier != selfPid }
        .filter { app in
            let args = ActionProcessRole.arguments(pid: app.processIdentifier)
            let quit = ActionProcessRole.isLauncher(args)
            logger.log("quit-app: pid=\(app.processIdentifier) role=\(args?.dropFirst().first ?? "unknown") action=\(quit ? "quit-launcher" : "preserve-helper")")
            return quit
        }
    func running() -> [NSRunningApplication] { launchers.filter { !$0.isTerminated } }

    guard !running().isEmpty else {
        return true
    }

    for app in running() {
        _ = app.terminate()
    }

    func waitForExit(until deadline: Date) -> Bool {
        while Date() < deadline {
            if running().isEmpty {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return running().isEmpty
    }

    if waitForExit(until: Date().addingTimeInterval(timeout)) {
        return true
    }

    for app in running() {
        _ = app.forceTerminate()
    }

    return waitForExit(until: Date().addingTimeInterval(2))
}

@MainActor
func run(command: ActionHostCommand, options: CommandOptions, writer: ResponseWriter, logger: DebugLogger) async throws {
    let agentBridge = ActionAgentCommandBridge()
    switch command {
    case .agent:
        throw ActionHostError.unsupportedOS("agent should be started before command dispatch")
    case .launcher:
        throw ActionHostError.unsupportedOS("launcher should be started via runUICommand")
    case .webkitSmoke:
        throw ActionHostError.unsupportedOS("webkit-smoke should be started via runUICommand")
    case .stageOverlay:
        throw ActionHostError.unsupportedOS("stage-overlay should be started via runUICommand")
    case .drape:
        throw ActionHostError.unsupportedOS("drape should be started via runUICommand")
    case .agentLayer:
        throw ActionHostError.unsupportedOS("agent-layer should be started via runUICommand")
    case .agentDisplay:
        throw ActionHostError.unsupportedOS("agent-display should be started via runUICommand")
    case .demoCursorOverlay:
        throw ActionHostError.unsupportedOS("demo-cursor-overlay should be started via runUICommand")
    case .agentCursorOverlay:
        throw ActionHostError.unsupportedOS("agent-cursor-overlay should be started via runUICommand")
    case .clickFeedbackOverlay:
        throw ActionHostError.unsupportedOS("click-feedback-overlay should be started via runUICommand")
    case .terminalSession:
        throw ActionHostError.unsupportedOS("terminal-session should be started via runUICommand")
    case .guidedCalculatorDemo:
        let runner = GuidedCaptureSessionRunner(writer: writer, logger: logger, options: options)
        try await runner.run()
    case .quitApp:
        let didQuit = terminateRunningActionApps(logger: logger)
        try writer.write(
            ActionHostResponse(
                status: didQuit ? "quit" : "error",
                outputPath: nil,
                detail: didQuit
                    ? "terminated-action-launchers-preserved-independent-helpers"
                    : "action-still-running-after-force-terminate"
            )
        )
    case .capabilities:
        try writer.write(ActionBuildProvenance.current)
    case .isolationContext:
        try writer.write(ActionIsolationContext.capture())
    case .status:
        try writer.write(snapshot(promptAccessibility: false))
    case .request:
        _ = accessibilityStatus(prompt: true)
        _ = await actionRequestScreenRecordingAccess()
        try writer.write(snapshot(promptAccessibility: false))
    case .openAccessibilitySettings:
        openSettingsPane(anchor: "Privacy_Accessibility")
        try writer.write(ActionHostResponse(status: "opened", outputPath: nil, detail: "accessibility"))
    case .openScreenRecordingSettings:
        openSettingsPane(anchor: "Privacy_ScreenCapture")
        try writer.write(ActionHostResponse(status: "opened", outputPath: nil, detail: "screen-recording"))
    case .currentSurface:
        try writer.write(try currentSurface())
    case .supervisionOverlay:
        throw ActionHostError.unsupportedOS("supervision-overlay should be started via runUICommand")
    case .supervisorStop:
        let count = ActionSupervisionRegistry.triggerStopAll()
        try writer.write(
            ActionHostResponse(
                status: "stopping",
                outputPath: nil,
                detail: "\(count)"
            )
        )
    case .recordAppWindow:
        guard #available(macOS 15.0, *) else {
            throw ActionHostError.unsupportedOS("Window recording requires macOS 15.0 or newer.")
        }

        let bundleId = try options.required("bundle-id")
        let outputPath = try options.required("output")
        let finishedSignalPath = resolvedFinishedSignalPath(from: options)
        var params: [String: String] = [
            "bundleId": bundleId,
            "output": outputPath,
            "finishedFile": finishedSignalPath,
        ]
        if let debugLog = options.options["debug-log"] {
            params["debugLog"] = debugLog
        }
        if let stopFile = options.options["stop-file"] {
            params["stopFile"] = stopFile
        }
        let response = try await agentBridge.send(method: .recordAppWindow, params: params)
        if !response.ok {
            throw ActionHostError.captureFailed(response.error ?? "Failed to start app-window recording")
        }
        try writer.write(
            ActionHostResponse(
                status: response.result?["status"] ?? "recording",
                outputPath: response.result?["outputPath"] ?? outputPath,
                detail: response.result?["detail"]
            )
        )
        try waitForFinishedSignal(at: finishedSignalPath)
    case .recordAppWindowLocal:
        guard #available(macOS 15.0, *) else {
            throw ActionHostError.unsupportedOS("Window recording requires macOS 15.0 or newer.")
        }

        let bundleId = try options.required("bundle-id")
        let outputPath = try options.required("output")
        let recorder = WindowRecorder(writer: writer, logger: logger)
        try await recorder.recordAppWindow(
            bundleId: bundleId,
            outputPath: outputPath,
            stopSignalPath: options.options["stop-file"],
            finishedSignalPath: options.options["finished-file"]
        )
    case .recordRegion:
        guard #available(macOS 15.0, *) else {
            throw ActionHostError.unsupportedOS("Region recording requires macOS 15.0 or newer.")
        }

        let outputPath = try options.required("output")
        let rect = try rectFromOptions(options)
        let finishedSignalPath = resolvedFinishedSignalPath(from: options)
        var params: [String: String] = [
            "output": outputPath,
            "finishedFile": finishedSignalPath,
            "x": String(describing: rect.origin.x),
            "y": String(describing: rect.origin.y),
            "width": String(describing: rect.size.width),
            "height": String(describing: rect.size.height),
            "fps": String(describing: options.double("fps", default: 15)),
            "scale": String(describing: options.double("scale", default: 1)),
            "includeSupervisionOverlay": String(options.bool("include-supervision-overlay", default: true)),
        ]
        if let debugLog = options.options["debug-log"] {
            params["debugLog"] = debugLog
        }
        if let stopFile = options.options["stop-file"] {
            params["stopFile"] = stopFile
        }
        let response = try await agentBridge.send(method: .recordRegion, params: params)
        if !response.ok {
            throw ActionHostError.captureFailed(response.error ?? "Failed to start region recording")
        }
        try writer.write(
            ActionHostResponse(
                status: response.result?["status"] ?? "recording",
                outputPath: response.result?["outputPath"] ?? outputPath,
                detail: response.result?["detail"]
            )
        )
        try waitForFinishedSignal(at: finishedSignalPath)
    case .recordRegionLocal:
        guard #available(macOS 15.0, *) else {
            throw ActionHostError.unsupportedOS("Region recording requires macOS 15.0 or newer.")
        }

        let outputPath = try options.required("output")
        let rect = try rectFromOptions(options)
        let recorder = WindowRecorder(writer: writer, logger: logger)
        try await recorder.recordRegion(
            rect: rect,
            outputPath: outputPath,
            stopSignalPath: options.options["stop-file"],
            finishedSignalPath: options.options["finished-file"],
            fps: options.double("fps", default: 15),
            scale: options.double("scale", default: 1),
            includeSupervisionOverlay: options.bool("include-supervision-overlay", default: true)
        )
    case .recordingProbe:
        throw ActionHostError.unsupportedOS("recording-probe must be started through the UI command path")
    case .screenshotAppWindow:
        guard #available(macOS 14.0, *) else {
            throw ActionHostError.unsupportedOS("Window screenshots require macOS 14.0 or newer.")
        }

        let app = try resolveTargetApplication(from: options)
        let outputPath = try options.required("output")
        var params: [String: String] = [
            "pid": String(app.processIdentifier),
            "output": outputPath,
        ]
        if let bundleId = app.bundleIdentifier {
            params["bundleId"] = bundleId
        }
        let response = try await agentBridge.send(
            method: .screenshotAppWindow,
            params: params
        )
        try writer.write(
            ActionHostResponse(
                status: response.result?["status"] ?? (response.ok ? "screenshot" : "error"),
                outputPath: response.result?["outputPath"] ?? outputPath,
                detail: response.error
            )
        )
    case .screenshotRegion:
        let outputPath = try options.required("output")
        let rect = try rectFromOptions(options)
        let response = try await agentBridge.send(
            method: .screenshotRegion,
            params: [
                "output": outputPath,
                "x": String(describing: rect.origin.x),
                "y": String(describing: rect.origin.y),
                "width": String(describing: rect.size.width),
                "height": String(describing: rect.size.height),
            ]
        )
        try writer.write(
            ActionHostResponse(
                status: response.result?["status"] ?? (response.ok ? "screenshot" : "error"),
                outputPath: response.result?["outputPath"] ?? outputPath,
                detail: response.error
            )
        )
    case .screenshotScreen:
        let outputPath = try options.required("output")
        let response = try await agentBridge.send(
            method: .screenshotScreen,
            params: ["output": outputPath]
        )
        try writer.write(
            ActionHostResponse(
                status: response.result?["status"] ?? (response.ok ? "screenshot" : "error"),
                outputPath: response.result?["outputPath"] ?? outputPath,
                detail: response.result?["detail"] ?? response.error
            )
        )
    case .activateApp:
        let app = try resolveTargetApplication(from: options)
        try await activateApplicationAndWait(
            app: app,
            timeoutMilliseconds: options.double("timeout-ms", default: 3_000),
            logger: logger
        )
        try writer.write(ActionHostResponse(status: "activated", outputPath: nil, detail: targetLabel(for: app)))
    case .focusWindow:
        let app = try resolveTargetApplication(from: options)
        let label = targetLabel(for: app)
        let requestedTitle = options.options["title"].flatMap { $0.isEmpty ? nil : $0 }
        var focusedTitle: String?
        if let requestedTitle {
            // Raise before activating so the app comes forward with the requested window on top.
            // A title that matches nothing throws here rather than quietly focusing some other window.
            focusedTitle = try ActionNativeAutomation.raiseWindow(pid: app.processIdentifier, matching: requestedTitle)
            logger.log("focus-window: raised target=\(label) title=\(focusedTitle ?? requestedTitle)")
        }
        try await activateApplicationAndWait(
            app: app,
            timeoutMilliseconds: options.double("timeout-ms", default: 3_000),
            logger: logger
        )
        try writer.write(
            ActionHostResponse(
                status: "focused",
                outputPath: nil,
                detail: focusedTitle.map { "\(label): \($0)" } ?? label
            )
        )
    case .raiseWindow:
        let bundleId = try options.required("bundle-id")
        let requestedTitle = options.options["title"].flatMap { $0.isEmpty ? nil : $0 }
        let raisedTitle: String
        if let requestedTitle {
            raisedTitle = try ActionNativeAutomation.raiseWindow(bundleId: bundleId, matching: requestedTitle)
        } else {
            raisedTitle = try ActionNativeAutomation.raiseWindow(bundleId: bundleId, matching: "")
        }
        logger.log("raise-window: bundle=\(bundleId) title=\(raisedTitle)")
        try writer.write(
            ActionHostResponse(
                status: "raised",
                outputPath: nil,
                detail: "\(bundleId): \(raisedTitle)"
            )
        )
    case .windowOrder:
        let bounds: CGRect?
        if let spec = options.options["bounds"] {
            let numbers = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else {
                throw ActionHostError.missingOption("--bounds x,y,width,height")
            }
            bounds = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        } else {
            bounds = nil
        }
        try writer.write(windowOrder(bounds: bounds))
    case .listAppWindows:
        let app = try resolveTargetApplication(from: options)
        let response = try listAppWindows(
            app: app,
            raise: options.bool("raise", default: false),
            minWindows: options.int("min-windows", default: 0),
            logger: logger
        )
        try writer.write(response)
    case .requestApplicationActivation:
        if let pidOption = options.options["pid"], let pid = Int32(pidOption) {
            try ActionNativeAutomation.activateApplication(pid: pid)
            try writer.write(ActionHostResponse(status: "activation-requested", outputPath: nil, detail: "pid \(pid)"))
        } else {
            let bundleId = try options.required("bundle-id")
            try ActionNativeAutomation.activateApplication(bundleId: bundleId)
            try writer.write(ActionHostResponse(status: "activation-requested", outputPath: nil, detail: bundleId))
        }
    case .launchApp:
        let bundleId = try options.required("bundle-id")
        let timeoutMilliseconds = options.double("timeout-ms", default: 10_000)
        // Background: launch or reopen without activating, so an agent layer can take
        // the window. No wait for frontmost, since nothing comes to the front.
        let url = ActionBackgroundOpen.url(from: options.options["url"])
        if options.bool("background", default: false) || url != nil {
            let app = try await ActionBackgroundOpen.open(bundleId: bundleId, url: url)
            if !options.bool("background", default: false) {
                try await activateApplicationAndWait(
                    bundleId: bundleId,
                    timeoutMilliseconds: timeoutMilliseconds,
                    logger: logger
                )
            }
            try writer.write(ActionHostResponse(status: "launched", outputPath: nil, detail: "\(bundleId) pid \(app.processIdentifier)"))
            break
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            try await MainActor.run {
                try ActionNativeAutomation.launchApplication(bundleId: bundleId)
            }
            // openApplication only queues the launch, so wait for the process to exist before we
            // insist on frontmost; otherwise activation races the launch and reports a false failure.
            try await waitForRunningApplication(bundleId: bundleId, timeoutMilliseconds: timeoutMilliseconds)
        }
        // An already-running app is activated below, never through openApplication: that call
        // leaves an activation request in flight that outlives this process and blocks the
        // accessibility activation from taking effect while we are still waiting on it.
        try await activateApplicationAndWait(
            bundleId: bundleId,
            timeoutMilliseconds: timeoutMilliseconds,
            logger: logger
        )
        try writer.write(ActionHostResponse(status: "launched", outputPath: nil, detail: bundleId))
    case .prepareNotesNote:
        let noteName = try prepareNotesNote()
        try writer.write(ActionHostResponse(status: "prepared", outputPath: nil, detail: noteName))
    case .getCaptureWindowFrame:
        let bundleId = try options.required("bundle-id")
        let rect = try await getCaptureWindowFrame(bundleId: bundleId)
        try writer.write(
            WindowFrameResponse(
                status: "capture-window-frame",
                bundleId: bundleId,
                frame: overlayBounds(from: rect)
            )
        )
    case .composeRoundedScreenshot:
        let inputPath = try options.required("input")
        let outputPath = try options.required("output")
        let radius = CGFloat(options.double("radius", default: 24))
        let background = options.options["background"] ?? "E8EDF5"
        try composeRoundedScreenshot(
            inputPath: inputPath,
            outputPath: outputPath,
            radius: radius,
            backgroundHex: background
        )
        try writer.write(
            ActionHostResponse(
                status: "composed",
                outputPath: outputPath,
                detail: "radius=\(Int(radius)) background=\(background)"
            )
        )
    case .typeText:
        let text = try options.required("text")
        let delayMs = Int(options.double("delay-ms", default: 0))
        try postText(text, delayMs: delayMs > 0 ? delayMs : nil)
        try writer.write(ActionHostResponse(status: "typed", outputPath: nil, detail: text))
    case .typeAppText:
        let bundleId = try options.required("bundle-id")
        let text = try options.required("text")
        let delayMs = Int(options.double("delay-ms", default: 0))
        try postTextToApp(bundleId: bundleId, text: text, delayMs: delayMs > 0 ? delayMs : nil)
        try writer.write(ActionHostResponse(status: "typed-app-text", outputPath: nil, detail: "\(bundleId) \(text)"))
    case .pressKey:
        let key = try options.required("key")
        let modifiers = options.options["modifiers"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        try postKeyPress(key, modifiers: modifiers)
        let detail = modifiers.isEmpty ? key : "\(modifiers.joined(separator: "+"))+\(key)"
        try writer.write(ActionHostResponse(status: "pressed", outputPath: nil, detail: detail))
    case .pressAppKey:
        let bundleId = try options.required("bundle-id")
        let key = try options.required("key")
        let modifiers = options.options["modifiers"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        try postKeyPressToApp(bundleId: bundleId, key: key, modifiers: modifiers)
        let detail = modifiers.isEmpty ? "\(bundleId) \(key)" : "\(bundleId) \(modifiers.joined(separator: "+"))+\(key)"
        try writer.write(ActionHostResponse(status: "pressed-app-key", outputPath: nil, detail: detail))
    case .blinkClick:
        let x = options.double("x", default: .nan)
        let y = options.double("y", default: .nan)
        guard x.isFinite, y.isFinite else {
            throw ActionHostError.missingOption("--x/--y")
        }
        // A requested hold is a HID gesture AXPress can't express; `--pointer` forces the
        // pointer for elements whose press action misbehaves.
        let wantsPointer = options.options["hold-ms"] != nil || options.bool("pointer", default: false)
        ActionAgentLayerDisplay.announceAim(at: CGPoint(x: x, y: y))
        let detail = try ActionBlinkInput.click(
            at: CGPoint(x: x, y: y),
            holdMs: Int(options.double("hold-ms", default: Double(ActionBlinkInput.clickHoldMilliseconds))),
            accessibilityFirst: !wantsPointer,
            anyDisplay: options.bool("any-display", default: false),
            pointerEventLogPath: options.options["pointer-event-log"]
        )
        ActionAgentLayerDisplay.announceAct(at: CGPoint(x: x, y: y))
        try writer.write(ActionHostResponse(status: "blink-clicked", outputPath: nil, detail: detail))
    case .blinkType:
        let app = try resolveTargetApplication(from: options)
        let delayMs = Int(options.double("delay-ms", default: 0))
        let detail = try ActionBlinkInput.type(
            try options.required("text"),
            into: app,
            delayMs: delayMs > 0 ? delayMs : nil,
            // A typing cadence is a keystroke thing; `--keys` forces keystrokes outright.
            accessibilityFirst: delayMs <= 0 && !options.bool("keys", default: false),
            anyDisplay: options.bool("any-display", default: false)
        )
        ActionAgentLayerDisplay.announceAct(focusedIn: app)
        try writer.write(ActionHostResponse(status: "blink-typed", outputPath: nil, detail: detail))
    case .blinkKey:
        let app = try resolveTargetApplication(from: options)
        let modifiers = options.options["modifiers"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let detail = try ActionBlinkInput.press(
            try options.required("key"),
            modifiers: modifiers,
            into: app,
            anyDisplay: options.bool("any-display", default: false)
        )
        ActionAgentLayerDisplay.announceAct(focusedIn: app)
        try writer.write(ActionHostResponse(status: "blink-key-pressed", outputPath: nil, detail: detail))
    case .blinkDrag:
        let from = CGPoint(x: options.double("from-x", default: .nan), y: options.double("from-y", default: .nan))
        let to = CGPoint(x: options.double("to-x", default: .nan), y: options.double("to-y", default: .nan))
        guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite else {
            throw ActionHostError.missingOption("--from-x --from-y --to-x --to-y")
        }
        ActionAgentLayerDisplay.announceAim(at: from)
        let detail = try ActionBlinkInput.drag(
            from: from,
            to: to,
            durationMs: Int(options.double("duration-ms", default: 200)),
            anyDisplay: options.bool("any-display", default: false),
            pointerEventLogPath: options.options["pointer-event-log"]
        )
        ActionAgentLayerDisplay.announceAct("drag", at: to, from: from)
        try writer.write(ActionHostResponse(status: "blink-dragged", outputPath: nil, detail: detail))
    case .blinkScroll:
        let point = CGPoint(x: options.double("x", default: .nan), y: options.double("y", default: .nan))
        guard point.x.isFinite, point.y.isFinite else {
            throw ActionHostError.missingOption("--x/--y")
        }
        ActionAgentLayerDisplay.announceAim(at: point)
        let detail = try ActionBlinkInput.scroll(
            at: point,
            deltaX: options.double("delta-x", default: 0),
            deltaY: options.double("delta-y", default: 0),
            durationMs: Int(options.double("duration-ms", default: 0)),
            anyDisplay: options.bool("any-display", default: false)
        )
        ActionAgentLayerDisplay.announceAct("scroll", at: point, deltaY: options.double("delta-y", default: 0))
        try writer.write(ActionHostResponse(status: "blink-scrolled", outputPath: nil, detail: detail))
    case .pointerEventLogInit:
        // Written natively so the header's monotonic reference comes from the same clock the
        // click processes will stamp against. A JS caller cannot produce a comparable reading.
        let path = try options.required("path")
        let feedback = ActionPointerFeedbackSettings(
            enabled: options.bool("click-feedback", default: false),
            style: options.options["click-feedback-style"] ?? "pulse",
            durationMs: options.double("click-feedback-duration-ms", default: 320),
            radius: options.double("click-feedback-radius", default: 34)
        )
        let created = try ActionPointerEventLog.create(
            at: path,
            recordingId: try options.required("recording-id"),
            sessionId: options.options["session-id"],
            feedback: feedback
        )
        try writer.write(
            ActionHostResponse(
                status: "pointer-event-log-created",
                outputPath: created.path,
                detail: created.header.startedAt
            )
        )
    case .clickPoint:
        let x = options.double("x", default: .nan)
        let y = options.double("y", default: .nan)
        guard x.isFinite, y.isFinite else {
            throw ActionHostError.missingOption("--x/--y")
        }
        let holdMs = Int(options.double("hold-ms", default: Double(defaultClickHoldMilliseconds)))
        let gesture = try clickPoint(
            CGPoint(x: x, y: y),
            holdMs: holdMs,
            pointerEventLogPath: options.options["pointer-event-log"]
        )
        var clickDetail = holdMs > defaultClickHoldMilliseconds
            ? "\(Int(x)),\(Int(y)) hold=\(holdMs)ms"
            : "\(Int(x)),\(Int(y))"
        if gesture.recorded {
            clickDetail += " pointerEvent=\(gesture.correlationId)"
        }
        try writer.write(ActionHostResponse(status: "clicked", outputPath: nil, detail: clickDetail))
    case .drag:
        let fromX = options.double("from-x", default: .nan)
        let fromY = options.double("from-y", default: .nan)
        let toX = options.double("to-x", default: .nan)
        let toY = options.double("to-y", default: .nan)
        let durationMs = Int(options.double("duration-ms", default: 300))
        let filePath = options.options["file-path"]

        guard fromX.isFinite, fromY.isFinite, toX.isFinite, toY.isFinite else {
            throw ActionHostError.missingOption("--from-x --from-y --to-x --to-y")
        }
        if let filePath, !filePath.isEmpty, !FileManager.default.fileExists(atPath: filePath) {
            throw ActionHostError.fileNotFound(filePath)
        }
        let pointerEventLogPath = options.options["pointer-event-log"]
        if let filePath, !filePath.isEmpty {
            let gesture = try ActionNativeAutomation.dragFile(
                path: filePath,
                from: CGPoint(x: fromX, y: fromY),
                to: CGPoint(x: toX, y: toY),
                durationMs: durationMs,
                pointerEventLogPath: pointerEventLogPath
            )
            let detail = gesture.recorded
                ? "file=\(filePath) pointerEvent=\(gesture.correlationId)"
                : "file=\(filePath)"
            try writer.write(ActionHostResponse(status: "dragged", outputPath: nil, detail: detail))
        } else {
            let gesture = try ActionNativeAutomation.drag(
                from: CGPoint(x: fromX, y: fromY),
                to: CGPoint(x: toX, y: toY),
                durationMs: durationMs,
                pointerEventLogPath: pointerEventLogPath
            )
            var detail = "\(Int(fromX)),\(Int(fromY))->\(Int(toX)),\(Int(toY))"
            if gesture.recorded {
                detail += " pointerEvent=\(gesture.correlationId)"
            }
            try writer.write(ActionHostResponse(status: "dragged", outputPath: nil, detail: detail))
        }
    case .scroll:
        let x = options.double("x", default: .nan)
        let y = options.double("y", default: .nan)
        let deltaX = options.double("delta-x", default: 0)
        let deltaY = options.double("delta-y", default: 0)
        let durationMs = Int(options.double("duration-ms", default: 0))

        guard x.isFinite, y.isFinite else {
            throw ActionHostError.missingOption("--x/--y")
        }
        guard deltaX != 0 || deltaY != 0 else {
            throw ActionHostError.missingOption("--delta-x/--delta-y")
        }

        try ActionNativeAutomation.scroll(
            at: CGPoint(x: x, y: y),
            deltaX: deltaX,
            deltaY: deltaY,
            durationMs: durationMs
        )
        try writer.write(
            ActionHostResponse(
                status: "scrolled",
                outputPath: nil,
                detail: "\(Int(x)),\(Int(y)) delta=\(Int(deltaX)),\(Int(deltaY))"
            )
        )
    case .pressAccessibilityElement:
        let bundleId = try options.required("bundle-id")
        let label = try options.required("label")
        let role = options.options["role"]
        let match = try ActionNativeAutomation.pressAccessibilityElement(
            bundleId: bundleId,
            label: label,
            role: role
        )
        try writer.write(
            ActionHostResponse(
                status: "pressed",
                outputPath: nil,
                detail: "\(bundleId) \(match.role) \(label)"
            )
        )
    case .performAccessibilityAction:
        let bundleId = try options.required("bundle-id")
        let label = try options.required("label")
        let action = try options.required("action")
        let role = options.options["role"]
        let match = try ActionNativeAutomation.performAccessibilityAction(
            bundleId: bundleId,
            label: label,
            action: action,
            role: role
        )
        try writer.write(
            ActionHostResponse(
                status: "performed",
                outputPath: nil,
                detail: "\(bundleId) \(match.role) \(label) \(action)"
            )
        )
    case .setAccessibilityValue:
        let bundleId = try options.required("bundle-id")
        let label = try options.required("label")
        let value = try options.required("value")
        let role = options.options["role"]
        let match = try ActionNativeAutomation.setAccessibilityValue(
            bundleId: bundleId,
            label: label,
            role: role,
            value: value
        )
        try writer.write(
            ActionHostResponse(
                status: "value-set",
                outputPath: nil,
                detail: "\(bundleId) \(match.role) \(label)"
            )
        )
    case .setFocusedAccessibilityValue:
        let bundleId = try options.required("bundle-id")
        let value = try options.required("value")
        let role = options.options["role"]
        let match = try ActionNativeAutomation.setFocusedAccessibilityValue(
            bundleId: bundleId,
            role: role,
            value: value
        )
        try writer.write(
            ActionHostResponse(
                status: "focused-value-set",
                outputPath: nil,
                detail: "\(bundleId) \(match.role)"
            )
        )
    case .setAccessibilityRoleValue:
        let bundleId = try options.required("bundle-id")
        let role = try options.required("role")
        let value = try options.required("value")
        let match = try ActionNativeAutomation.setAccessibilityRoleValue(
            bundleId: bundleId,
            role: role,
            value: value
        )
        try writer.write(
            ActionHostResponse(
                status: "role-value-set",
                outputPath: nil,
                detail: "\(bundleId) \(match.role)"
            )
        )
    case .clickCalculatorButton:
        let button = try options.required("button")
        try clickCalculatorButton(label: button)
        try writer.write(ActionHostResponse(status: "clicked", outputPath: nil, detail: button))
    case .inspectCalculatorButtons:
        try writer.write(calculatorButtons())
    case .inspectCalculatorUI:
        try writer.write(ActionNativeAutomation.calculatorAccessibilityNodes())
    case .inspectAppUI:
        let app = try resolveTargetApplication(from: options)
        let maxDepth = Int(options.double("max-depth", default: 6))
        let maxNodes = Int(options.double("max-nodes", default: 250))
        try writer.write(
            ActionNativeAutomation.accessibilityNodes(
                pid: app.processIdentifier,
                maxDepth: maxDepth,
                maxNodes: maxNodes
            )
        )
    case .getCalculatorDisplay:
        try writer.write(
            ActionHostResponse(
                status: "calculator-display",
                outputPath: nil,
                detail: try ActionNativeAutomation.calculatorDisplayValue()
            )
        )
    case .setWindowFrame:
        let bundleId = try options.required("bundle-id")
        let rect = try rectFromOptions(options)
        try ActionNativeAutomation.setWindowFrame(bundleId: bundleId, rect: rect)
        try writer.write(ActionHostResponse(status: "window-framed", outputPath: nil, detail: bundleId))
    case .getWindowFrame:
        let bundleId = try options.required("bundle-id")
        let rect = try ActionNativeAutomation.getWindowFrame(bundleId: bundleId)
        try writer.write(
            WindowFrameResponse(
                status: "window-frame",
                bundleId: bundleId,
                frame: overlayBounds(from: rect)
            )
        )
    case .getDisplayFrame:
        let requestedPoint = CGPoint(
            x: options.double("x", default: 0),
            y: options.double("y", default: 0)
        )
        try writer.write(
            WindowFrameResponse(
                status: "display-frame",
                bundleId: "display",
                frame: overlayBounds(from: try activeDisplayBounds(containing: requestedPoint))
            )
        )
    case .ocrScreenshot:
        let inputPath = try options.required("input")
        let result = try actionRecognizeText(in: inputPath)
        if let outputPath = options.options["output"] {
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: outputURL)
        }
        try writer.write(result)
    }
}

@main
struct ActionHostMain {
    static func main() {
        let options = CommandOptions(arguments: CommandLine.arguments)
        if options.command != .isolationContext, Bundle.main.bundleIdentifier == ActionAppIdentity.mainBundleIdentifier {
            ActionPreferenceMigration.migrateIfNeeded()
        }

        let writer = ResponseWriter(replyFile: options.options["reply-file"])
        let logger = DebugLogger(path: options.options["debug-log"])
        let command = options.command ?? .launcher

        if command == .agent {
            MainActor.assumeIsolated {
                ActionAgentRuntime.run(arguments: CommandLine.arguments)
            }
        }

        if runUICommandIfNeeded(command: command, options: options) {
            return
        }

        let terminationReason = "ActionHost command in progress"
        ProcessInfo.processInfo.disableAutomaticTermination(terminationReason)
        ProcessInfo.processInfo.disableSuddenTermination()

        Task {
            do {
                defer {
                    ProcessInfo.processInfo.enableSuddenTermination()
                    ProcessInfo.processInfo.enableAutomaticTermination(terminationReason)
                }
                try await run(command: command, options: options, writer: writer, logger: logger)
                Darwin.exit(0)
            } catch {
                defer {
                    ProcessInfo.processInfo.enableSuddenTermination()
                    ProcessInfo.processInfo.enableAutomaticTermination(terminationReason)
                }
                logger.log("error: \(error.localizedDescription)")
                if options.options["reply-file"] != nil {
                    try? writer.write(
                        ActionHostResponse(
                            status: "error",
                            outputPath: options.options["output"],
                            detail: error.localizedDescription
                        )
                    )
                }
                FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        dispatchMain()
    }

    private static func runUICommandIfNeeded(command: ActionHostCommand, options: CommandOptions) -> Bool {
        switch command {
        case .supervisionOverlay:
            let replyFile = options.options["reply-file"]
            let debugLogPath = options.options["debug-log"]
            MainActor.assumeIsolated {
                let controller = ActionSupervisionOverlayController(
                    replyFile: replyFile,
                    debugLogPath: debugLogPath
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .drape:
            MainActor.assumeIsolated {
                do {
                    let controller = try ActionDrapeController(options: options)
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .agentDisplay:
            MainActor.assumeIsolated {
                do {
                    let controller = try ActionAgentDisplayController(options: options)
                    try controller.run()
                } catch {
                    let writer = ResponseWriter(replyFile: options.options["reply-file"])
                    try? writer.write(ActionHostResponse(status: "error", outputPath: nil, detail: error.localizedDescription))
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .agentLayer:
            MainActor.assumeIsolated {
                do {
                    let controller = try ActionAgentLayerController(options: options)
                    try controller.run()
                } catch {
                    let writer = ResponseWriter(replyFile: options.options["reply-file"])
                    try? writer.write(ActionHostResponse(status: "error", outputPath: nil, detail: error.localizedDescription))
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .stageOverlay:
            let stateFile: String
            let stopFile: String
            do {
                stateFile = try options.required("state-file")
                stopFile = try options.required("stop-file")
            } catch {
                FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
            let replyFile = options.options["reply-file"]
            let debugLogPath = options.options["debug-log"]
            let controlFile = options.options["control-file"]
            MainActor.assumeIsolated {
                let controller = StageOverlayController(
                    stateFile: stateFile,
                    stopFile: stopFile,
                    replyFile: replyFile,
                    debugLogPath: debugLogPath,
                    controlFile: controlFile,
                    parentProcessID: options.options["parent-pid"].flatMap { pid_t($0) }
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .clickFeedbackOverlay:
            let replyFile = options.options["reply-file"]
            let debugLogPath = options.options["debug-log"]
            guard let eventLog = options.options["event-log"], !eventLog.isEmpty else {
                FileHandle.standardError.write(Data("ActionHost failed: --event-log is required for click-feedback-overlay\n".utf8))
                Darwin.exit(1)
            }
            let stopFile = options.options["stop-file"] ?? "\(eventLog).stop"
            MainActor.assumeIsolated {
                let controller = ClickFeedbackOverlayController(
                    eventLogPath: eventLog,
                    stopFile: stopFile,
                    replyFile: replyFile,
                    debugLogPath: debugLogPath
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .agentCursorOverlay:
            let replyFile = options.options["reply-file"]
            let debugLogPath = options.options["debug-log"]
            guard let stateFile = options.options["state-file"], !stateFile.isEmpty else {
                FileHandle.standardError.write(Data("ActionHost failed: --state-file is required for agent-cursor-overlay\n".utf8))
                Darwin.exit(1)
            }
            let stopFile = options.options["stop-file"]
                ?? "\(stateFile).stop"
            let leaseStopFile = options.options["lease-stop-file"]
            MainActor.assumeIsolated {
                let controller = AgentCursorOverlayController(
                    stateFile: stateFile,
                    stopFile: stopFile,
                    leaseStopFile: leaseStopFile,
                    replyFile: replyFile,
                    debugLogPath: debugLogPath
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .demoCursorOverlay:
            let writer = ResponseWriter(replyFile: options.options["reply-file"])
            let durationMs = options.double("duration-ms", default: 1700)
            let startX = options.double("start-x", default: .nan)
            let startY = options.double("start-y", default: .nan)
            let endX = options.double("end-x", default: .nan)
            let endY = options.double("end-y", default: .nan)
            let clickProgress = options.double("click-progress", default: 0.68)
            let labelOverride = options.options["label"]
            let statusDetail = options.options["status-detail"]
            let keyLabel = options.options["key-label"]
            let typingText = options.options["typing-text"]
            let typingSoundMode = options.options["typing-sound"]?.lowercased() ?? "actual"
            let playsTimedTypingSound = typingSoundMode == "timed"
            let statusOnly = ["1", "true", "yes"].contains(options.options["status-only"]?.lowercased() ?? "")
            // `--cursor auto|pointer|hidden` (aliases: caption-only, none, always, …).
            // Defaults to auto: mouse beats get the pointer; keyboard beats are captions only.
            let presentation = DemoCursorPresentation.parse(
                options.options["cursor"] ?? options.options["presentation"]
            )
            let traceFile = options.options["trace-file"]
            let traceTitle = options.options["trace-title"] ?? "Action trace"
            let previewImagePath = options.options["preview-image"]
            let startPoint = startX.isFinite && startY.isFinite
                ? CGPoint(x: startX, y: startY)
                : nil
            let endPoint = endX.isFinite && endY.isFinite
                ? CGPoint(x: endX, y: endY)
                : nil
            MainActor.assumeIsolated {
                let controller = DemoCursorOverlayController(
                    writer: writer,
                    durationMs: durationMs,
                    startPoint: startPoint,
                    endPoint: endPoint,
                    clickProgress: clickProgress,
                    labelOverride: labelOverride,
                    statusDetail: statusDetail,
                    keyLabel: keyLabel,
                    typingText: typingText,
                    playsTimedTypingSound: playsTimedTypingSound,
                    statusOnly: statusOnly,
                    presentation: presentation,
                    traceFile: traceFile,
                    traceTitle: traceTitle,
                    previewImagePath: previewImagePath
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .terminalSession:
            let writer = ResponseWriter(replyFile: options.options["reply-file"])
            let controlFile = options.options["control-file"]
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("action-terminal-\(UUID().uuidString).controls").path
            let stopFile = options.options["stop-file"]
            let shellPath = options.options["shell"] ?? "/bin/sh"
            let workingDirectory = options.options["cwd"]
            let homeDirectory = options.options["home"]
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("action-terminal-home", isDirectory: true).path
            MainActor.assumeIsolated {
                let controller = ActionTerminalSessionController(
                    writer: writer,
                    controlFile: controlFile,
                    stopFile: stopFile,
                    shellPath: shellPath,
                    workingDirectory: workingDirectory,
                    homeDirectory: homeDirectory
                )
                do {
                    try controller.run()
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
            }
            return true
        case .launcher:
            MainActor.assumeIsolated {
                ActionLauncherController.shared.run()
            }
            return true
        case .webkitSmoke:
            let urlString = options.options["url"] ?? "https://example.com"
            guard let url = URL(string: urlString) else {
                FileHandle.standardError.write(Data("ActionHost failed: missing or invalid --url\n".utf8))
                Darwin.exit(1)
            }
            MainActor.assumeIsolated {
                let runner = WebKitSmokeAppRunner(url: url)
                runner.run()
            }
            return true
        case .recordingProbe:
            guard #available(macOS 15.0, *) else {
                FileHandle.standardError.write(Data("ActionHost failed: recording-probe requires macOS 15.0 or newer.\n".utf8))
                Darwin.exit(1)
            }
            let writer = ResponseWriter(replyFile: options.options["reply-file"])
            let logger = DebugLogger(path: options.options["debug-log"])
            let target: RecordingProbeAppRunner.Target
            if let bundleId = options.options["bundle-id"], !bundleId.isEmpty {
                target = .appWindow(bundleId)
            } else {
                let rect: CGRect
                do {
                    rect = try rectFromOptions(options)
                } catch {
                    FileHandle.standardError.write(Data("ActionHost failed: \(error.localizedDescription)\n".utf8))
                    Darwin.exit(1)
                }
                target = .region(rect)
            }
            let outputPath = options.options["output"] ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording-probe-\(UUID().uuidString).mov").path
            let config = RecordingProbeAppRunner.Configuration(
                target: target,
                outputPath: outputPath,
                stopSignalPath: options.options["stop-file"],
                finishedSignalPath: options.options["finished-file"],
                fps: options.double("fps", default: 15),
                scale: options.double("scale", default: 1),
                includeSupervisionOverlay: options.bool("include-supervision-overlay", default: true)
            )
            MainActor.assumeIsolated {
                let runner = RecordingProbeAppRunner(configuration: config, writer: writer, debugLogger: logger)
                runner.run()
            }
            return true
        default:
            return false
        }
    }
}
