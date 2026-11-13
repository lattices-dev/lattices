import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func actionAXWindowNumber(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// An explicit process/window selection never activates the app or changes its focused window.
public struct ActionNativeWindowTarget: Sendable {
    public let bundleId: String?
    public let pid: pid_t?
    public let windowNumber: CGWindowID?
    private let bundlePath: String?

    public init(bundleId: String? = nil, pid: String? = nil, windowNumber: String? = nil, bundlePath: String? = nil) throws {
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        if let pid {
            guard let parsed = Int32(pid), parsed > 0 else {
                throw ActionNativeAutomationError.accessibilityLookupFailed("--pid must be a positive process id")
            }
            self.pid = parsed
        } else {
            self.pid = nil
        }
        if let windowNumber {
            guard let parsed = UInt32(windowNumber), parsed > 0 else {
                throw ActionNativeAutomationError.accessibilityLookupFailed("--window-number must be a positive CGWindowID")
            }
            self.windowNumber = parsed
        } else {
            self.windowNumber = nil
        }
    }

    public func application() throws -> NSRunningApplication {
        do {
            return try resolveApplication()
        } catch {
            if windowNumber != nil {
                throw ActionNativeAutomationError.accessibilityLookupFailed("window-not-found: \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func resolveApplication() throws -> NSRunningApplication {
        let app: NSRunningApplication
        if let pid {
            app = try ActionNativeAutomation.runningApplication(pid: pid)
        } else if let bundlePath, !bundlePath.isEmpty {
            app = try ActionNativeAutomation.runningApplication(bundlePath: bundlePath)
        } else if let bundleId, !bundleId.isEmpty {
            app = try ActionNativeAutomation.runningApplication(bundleId: bundleId)
        } else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("Missing --pid or --bundle-id")
        }
        try validateBundleIdentifier(app.bundleIdentifier, pid: app.processIdentifier)
        guard !app.isTerminated else {
            throw ActionNativeAutomationError.applicationNotRunning("pid \(app.processIdentifier)")
        }
        return app
    }

    func validateBundleIdentifier(_ actual: String?, pid: pid_t) throws {
        if let bundleId, actual != bundleId {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "Target pid \(pid) has bundle id \(actual ?? "unknown"), not \(bundleId)"
            )
        }
    }
}

public struct ActionNativeAppWindowSnapshot: Encodable, Sendable {
    public let pid: pid_t
    public let bundleId: String
    public let appName: String
    public let windowNumber: CGWindowID
    public let title: String
    public let frame: ActionAccessibilityBounds
    public let onScreen: Bool
    public let layer: Int
}

public struct ActionCalculatorButtonSnapshot: Codable, Sendable {
    public let role: String
    public let title: String?
    public let detail: String?
    public let value: String?
    public let identifier: String?

    public init(role: String, title: String?, detail: String?, value: String?, identifier: String?) {
        self.role = role
        self.title = title
        self.detail = detail
        self.value = value
        self.identifier = identifier
    }
}

public struct ActionAccessibilityNodeSnapshot: Codable, Sendable {
    public let role: String
    public let title: String?
    public let detail: String?
    public let value: String?
    public let identifier: String?
    public let depth: Int
    public let frame: ActionAccessibilityBounds?
    public let actions: [String]
    public let settableAttributes: [String]
    public let enabled: Bool?
    public let focused: Bool?
    /// Zero-based AXChildren indices from the inspection root; "root" names the root itself.
    public let path: String?
    /// Inspection metadata lives only on the root node, preserving the existing JSON array.
    public var root: ActionAccessibilityRoot?
    public var rootWindow: ActionAccessibilityWindowSnapshot?
    public var truncated: Bool?

    public init(
        role: String,
        title: String?,
        detail: String?,
        value: String?,
        identifier: String?,
        depth: Int,
        frame: ActionAccessibilityBounds? = nil,
        actions: [String] = [],
        settableAttributes: [String] = [],
        enabled: Bool? = nil,
        focused: Bool? = nil,
        path: String? = nil
    ) {
        self.role = role
        self.title = title
        self.detail = detail
        self.value = value
        self.identifier = identifier
        self.depth = depth
        self.frame = frame
        self.actions = actions
        self.settableAttributes = settableAttributes
        self.enabled = enabled
        self.focused = focused
        self.path = path
    }
}

public struct ActionAccessibilityBounds: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ActionAccessibilityRoot: String, Codable, Sendable {
    case window
    case application

    public static func parse(_ value: String) throws -> Self {
        guard let root = Self(rawValue: value) else {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "path-mismatch: invalid root \(value); expected window or application"
            )
        }
        return root
    }
}

public struct ActionAccessibilityWindowSnapshot: Codable, Sendable {
    public let title: String?
    public let frame: ActionAccessibilityBounds?
}

/// Pure parsing and expectation checks shared by all path-addressed actions.
public struct ActionAccessibilityPathTarget: Sendable {
    public let indices: [Int]
    public let path: String
    public let root: ActionAccessibilityRoot
    private let expectRole: String?
    private let expectLabel: String?
    private let expectFrame: ActionAccessibilityBounds?

    public init(
        path: String,
        root: String = "window",
        expectRole: String? = nil,
        expectLabel: String? = nil,
        expectFrame: String? = nil
    ) throws {
        self.root = try ActionAccessibilityRoot.parse(root)
        if path == "root" {
            indices = []
        } else {
            indices = try path.split(separator: ".", omittingEmptySubsequences: false).map { component in
                guard !component.isEmpty,
                      component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let index = Int(component) else {
                    throw ActionNativeAutomationError.accessibilityLookupFailed(
                        "path-mismatch: invalid path \(path); expected root or zero-based child indices such as 0.3.2"
                    )
                }
                return index
            }
        }
        self.path = indices.isEmpty ? "root" : indices.map(String.init).joined(separator: ".")
        self.expectRole = expectRole
        self.expectLabel = expectLabel
        if let expectFrame {
            let parts = expectFrame.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite),
                  values[2] >= 0, values[3] >= 0 else {
                throw ActionNativeAutomationError.accessibilityLookupFailed(
                    "path-mismatch: invalid expected frame; expected finite x,y,width,height with nonnegative size"
                )
            }
            self.expectFrame = ActionAccessibilityBounds(x: values[0], y: values[1], width: values[2], height: values[3])
        } else {
            self.expectFrame = nil
        }
    }

    func validate(role: String, labelCandidates: [String], frame: ActionAccessibilityBounds?) throws {
        if let expectRole, normalizedRole(expectRole) == nil || normalizedRole(role) != normalizedRole(expectRole) {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "path-mismatch: \(path) role \(role) does not match \(expectRole)"
            )
        }
        if let expectLabel, !labelCandidates.contains(where: { normalizedText($0) == normalizedText(expectLabel) }) {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "path-mismatch: \(path) label candidates do not match \(expectLabel)"
            )
        }
        if let expectFrame {
            guard let frame,
                  abs(frame.x - expectFrame.x) <= 2, abs(frame.y - expectFrame.y) <= 2,
                  abs(frame.width - expectFrame.width) <= 2, abs(frame.height - expectFrame.height) <= 2 else {
                throw ActionNativeAutomationError.accessibilityLookupFailed(
                    "path-mismatch: \(path) frame does not match expected frame within 2pt"
                )
            }
        }
    }
}

public enum ActionAccessibilityPathOperation: Sendable {
    case press
    case setValue(String)
    case performAction(String)
}

/// Facts captured before the action, since a successful action may remove its target.
public struct ActionAccessibilityPathResponse: Encodable, Sendable {
    public let status: String
    public let root: ActionAccessibilityRoot
    public let path: String
    public let role: String
    public let labelCandidates: [String]
    public let frame: ActionAccessibilityBounds?
}

/// Add executable capabilities without changing or inventing signed build provenance.
public struct ActionNativeHostCapabilities: Encodable {
    public init() {}

    public func encode(to encoder: Encoder) throws {
        try ActionBuildProvenance.current.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([
            "press-accessibility-path",
            "set-accessibility-value-path",
            "perform-accessibility-action-path",
        ], forKey: .accessibilityPathCommands)
        try container.encode(["click-point"], forKey: .restoringInputCommands)
        try container.encode(true, forKey: .windowScopedAccessibility)
        try container.encode(1, forKey: .operatorAsk)
    }

    private enum CodingKeys: String, CodingKey {
        case accessibilityPathCommands
        case windowScopedAccessibility
        case operatorAsk
        /// Commands that accept `--restore auto|true|false`: the pointer and frontmost app go back right after the input (auto: only while a person is co-driving).
        case restoringInputCommands
    }
}

public enum ActionNativeAutomationError: LocalizedError {
    case applicationNotRunning(String)
    case ambiguousApplication(String)
    case accessibilityLookupFailed(String)
    case accessibilityActionFailed(String)
    /// The app accepted a value write and the value did not end up applied. Distinct from a
    /// failed action so a caller can tell "refused" from "silently ignored".
    case accessibilityValueNotApplied(String)
    case dragPathNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotRunning(let target):
            return "No running application matches \(target)"
        case .ambiguousApplication(let detail):
            return detail
        case .accessibilityLookupFailed(let detail):
            return detail
        case .accessibilityActionFailed(let detail):
            return detail
        case .accessibilityValueNotApplied(let detail):
            return detail
        case .dragPathNotFound(let path):
            return "Drag source path not found: \(path)"
        }
    }
}

public enum ActionNativeAutomation {
    /// Window-server discovery includes windows on private displays and other Spaces, without AX.
    public static func listAppWindows() -> [ActionNativeAppWindowSnapshot] {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid > 0,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID, windowNumber > 0,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return nil }
            return ActionNativeAppWindowSnapshot(
                pid: pid, bundleId: bundleId, appName: app.localizedName ?? bundleId,
                windowNumber: windowNumber, title: info[kCGWindowName as String] as? String ?? "",
                frame: ActionAccessibilityBounds(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false, layer: layer
            )
        }
    }

    /// Capture the requested CG window directly; never select a sibling or require AX access.
    public static func screenshotWindow(selection: ActionNativeWindowTarget, outputPath: String) throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ActionCaptureError.screenRecordingPermissionMissing
        }
        let app = try selection.application()
        guard let windowNumber = selection.windowNumber else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("Missing --window-number")
        }
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowNumber) as? [[String: Any]] ?? []
        guard windows.contains(where: {
            ($0[kCGWindowNumber as String] as? CGWindowID) == windowNumber &&
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
        }) else {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "window-not-found: No window \(windowNumber) found for pid \(app.processIdentifier)"
            )
        }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowNumber, [.bestResolution, .boundsIgnoreFraming]),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ActionCaptureError.unableToEncodeImage
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL)
    }

    @MainActor
    public static func launchApplication(bundleId: String) throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ActionNativeAutomationError.applicationNotRunning(bundleId)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    public static func activateApplication(bundleId: String) throws {
        let app = try runningApplication(bundleId: bundleId)
        try activateApplication(pid: app.processIdentifier)
    }

    public static func activateApplication(pid: pid_t) throws {
        let application = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Failed to activate pid \(pid): \(result.rawValue)"
            )
        }
    }

    /// Brings the window whose title matches `title` to the front of its application's
    /// window order and marks it as the main window. Returns the title that matched so the
    /// caller can report which window it actually landed on.
    @discardableResult
    public static func raiseWindow(bundleId: String, matching title: String) throws -> String {
        let app = try runningApplication(bundleId: bundleId)
        return try raiseWindow(pid: app.processIdentifier, matching: title)
    }

    @discardableResult
    public static func raiseWindow(pid: pid_t, matching title: String) throws -> String {
        let application = AXUIElementCreateApplication(pid)

        // AXWindows often fails the Swift `[AXUIElement]` cast (it arrives as a CFArray),
        // and a freshly launched host can see an empty list for a tick. Walk every
        // known source — attribute, children, focused/main — before giving up.
        var windows = collectWindows(of: application)
        if windows.isEmpty {
            for _ in 0..<8 {
                usleep(50_000)
                windows = collectWindows(of: application)
                if !windows.isEmpty {
                    break
                }
            }
        }
        guard !windows.isEmpty else {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "No accessibility windows found for pid \(pid)"
            )
        }

        let titles = windows.map { stringValue(axValue($0, attribute: kAXTitleAttribute)) ?? "" }
        let needle = title.lowercased()
        let match: Int?
        if title.isEmpty {
            match = titles.indices.first
        } else {
            match = titles.firstIndex(of: title)
                ?? titles.firstIndex { $0.lowercased() == needle }
                ?? titles.firstIndex { $0.lowercased().contains(needle) }
        }

        guard let match else {
            let available = titles.filter { !$0.isEmpty }.map { "\"\($0)\"" }.joined(separator: ", ")
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "No window titled \"\(title)\" in pid \(pid); open windows: \(available.isEmpty ? "none" : available)"
            )
        }

        let window = windows[match]
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raise != .success {
            // Some windows advertise AXRaise and then refuse it. Calculator returns
            // kAXErrorAttributeUnsupported (-25205). Mark the window main and bring
            // the app forward so that window is the one that lands above a same-level
            // drape. This can also lift sibling windows of the same app.
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let front = AXUIElementSetAttributeValue(
                application,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            guard front == .success else {
                throw ActionNativeAutomationError.accessibilityActionFailed(
                    "Failed to raise window \"\(titles[match])\" in pid \(pid): raise=\(raise.rawValue) frontmost=\(front.rawValue)"
                )
            }
        }

        return titles[match]
    }

    public static func typeText(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create event source")
        }

        for scalar in text.utf16 {
            var unicode = [scalar]
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create keyboard events")
            }

            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    public static func setWindowFrame(bundleId: String, rect: CGRect) throws {
        let window = try firstWindowElement(for: bundleId)

        let positionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            pointValue(rect.origin)
        )
        guard positionResult == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Failed to set window position for \(bundleId): \(positionResult.rawValue)"
            )
        }

        let sizeResult = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue(rect.size)
        )
        _ = sizeResult
    }

    public static func getWindowFrame(bundleId: String) throws -> CGRect {
        let window = try firstWindowElement(for: bundleId)
        let position = point(from: axValue(window, attribute: kAXPositionAttribute))
        let size = size(from: axValue(window, attribute: kAXSizeAttribute))
        guard let position, let size else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("Failed to read window frame for \(bundleId)")
        }
        return CGRect(origin: position, size: size)
    }

    /// Resolves a bundle identifier to exactly one running process. Two processes can share a
    /// bundle id (a production install and a dev build of the same app), and silently picking
    /// one targets the wrong instance — the caller must disambiguate with pid or bundle path.
    public static func runningApplication(bundleId: String) throws -> NSRunningApplication {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = matches.first else {
            throw ActionNativeAutomationError.applicationNotRunning("bundle identifier \(bundleId)")
        }
        guard matches.count == 1 else {
            let candidates = matches
                .map { "pid=\($0.processIdentifier) path=\($0.bundleURL?.path ?? "unknown")" }
                .joined(separator: "; ")
            throw ActionNativeAutomationError.ambiguousApplication(
                "\(matches.count) running applications share bundle identifier \(bundleId); target one by pid or bundle path: \(candidates)"
            )
        }

        return app
    }

    public static func runningApplication(pid: pid_t) throws -> NSRunningApplication {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw ActionNativeAutomationError.applicationNotRunning("pid \(pid)")
        }

        return app
    }

    public static func runningApplication(bundlePath: String) throws -> NSRunningApplication {
        let expected = URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path
        let matches = NSWorkspace.shared.runningApplications.filter { app in
            guard let url = app.bundleURL else {
                return false
            }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == expected
        }
        guard let app = matches.first else {
            throw ActionNativeAutomationError.applicationNotRunning("bundle path \(bundlePath)")
        }
        guard matches.count == 1 else {
            let pids = matches.map { String($0.processIdentifier) }.joined(separator: ", ")
            throw ActionNativeAutomationError.ambiguousApplication(
                "\(matches.count) running applications share bundle path \(bundlePath) (pids \(pids)); target one by pid"
            )
        }

        return app
    }

    /// Raises every accessibility window the process exposes without activating the app.
    /// This is the raise path for accessory / LSUIElement apps, whose floating panels must
    /// come forward for screenshots and clicks even though the app never becomes frontmost.
    @discardableResult
    public static func raiseAllWindows(pid: pid_t) -> Int {
        let application = AXUIElementCreateApplication(pid)
        guard let windows = axValue(application, attribute: kAXWindowsAttribute) as? [AXUIElement],
              !windows.isEmpty else {
            return 0
        }

        var raised = 0
        for window in windows {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                raised += 1
            }
        }
        return raised
    }

    public static func calculatorButtons() throws -> [ActionCalculatorButtonSnapshot] {
        let window = try firstWindowElement(for: "com.apple.calculator")
        var queue = [window]
        var result: [ActionCalculatorButtonSnapshot] = []

        while let current = queue.first {
            queue.removeFirst()

            let role = axValue(current, attribute: kAXRoleAttribute) as? String ?? ""
            let title = axValue(current, attribute: kAXTitleAttribute) as? String
            let detail = axValue(current, attribute: kAXDescriptionAttribute) as? String
            let value = axValue(current, attribute: kAXValueAttribute) as? String
            let identifier = axValue(current, attribute: kAXIdentifierAttribute) as? String

            if role == kAXButtonRole as String {
                result.append(
                    ActionCalculatorButtonSnapshot(
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

    public static func clickCalculatorButton(label: String) throws {
        let window = try firstWindowElement(for: "com.apple.calculator")
        guard let button = findButton(in: window, label: label) else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("Could not find Calculator button \(label)")
        }

        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed("Accessibility press failed for Calculator button \(label): \(result.rawValue)")
        }
    }

    public static func pressAccessibilityElement(
        bundleId: String,
        label: String,
        role: String? = nil
    ) throws -> ActionAccessibilityNodeSnapshot {
        let match = try findAccessibilityElement(
            bundleId: bundleId,
            label: label,
            role: role,
            preferWritableText: false
        )

        let result = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        guard result == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Accessibility press failed for \(bundleId) element \(label): \(result.rawValue)"
            )
        }

        return snapshot(of: match.element, depth: match.depth)
    }

    public static func actOnAccessibilityPath(
        bundleId: String,
        target: ActionAccessibilityPathTarget,
        operation: ActionAccessibilityPathOperation
    ) throws -> ActionAccessibilityPathResponse {
        try actOnAccessibilityPath(
            selection: ActionNativeWindowTarget(bundleId: bundleId), target: target, operation: operation
        )
    }

    public static func actOnAccessibilityPath(
        selection: ActionNativeWindowTarget,
        target: ActionAccessibilityPathTarget,
        operation: ActionAccessibilityPathOperation
    ) throws -> ActionAccessibilityPathResponse {
        let element = try resolveAccessibilityPath(selection: selection, target: target)
        let role = axValue(element, attribute: kAXRoleAttribute) as? String ?? ""
        let labels = accessibilityLabelCandidates(for: element)
        let frame = bounds(of: element)
        try target.validate(role: role, labelCandidates: labels, frame: frame)

        let status: String
        // Only action-stage errors get this prefix; resolution/expectation failures never act.
        do {
            switch operation {
            case .setValue(let value):
                _ = try writeAccessibilityValue(
                    to: element,
                    depth: target.indices.count,
                    value: value,
                    describing: "\(selection.bundleId ?? "pid \(selection.pid ?? 0)") path \(target.path)"
                )
                status = "value-set"
            case .press, .performAction:
                let actionName: String
                if case .performAction(let action) = operation {
                    actionName = normalizedAccessibilityActionName(action)
                } else {
                    actionName = kAXPressAction as String
                }
                let availableActions = axActions(of: element)
                guard availableActions.contains(actionName) else {
                    throw ActionNativeAutomationError.accessibilityActionFailed(
                        "\(actionName) is not available at \(target.path); available actions: \(availableActions.joined(separator: ", "))"
                    )
                }
                let result = AXUIElementPerformAction(element, actionName as CFString)
                guard result == .success else {
                    throw ActionNativeAutomationError.accessibilityActionFailed(
                        "\(actionName) failed at \(target.path): \(result.rawValue)"
                    )
                }
                status = if case .press = operation { "pressed" } else { "performed" }
            }
        } catch {
            throw ActionNativeAutomationError.accessibilityActionFailed("ax-action-failed: \(error.localizedDescription)")
        }
        return ActionAccessibilityPathResponse(
            status: status, root: selection.windowNumber == nil ? target.root : .window, path: target.path,
            role: role, labelCandidates: labels, frame: frame
        )
    }

    public static func performAccessibilityAction(
        bundleId: String,
        label: String,
        action: String,
        role: String? = nil
    ) throws -> ActionAccessibilityNodeSnapshot {
        let match = try findAccessibilityElement(
            bundleId: bundleId,
            label: label,
            role: role,
            preferWritableText: false
        )
        let actionName = normalizedAccessibilityActionName(action)
        let availableActions = axActions(of: match.element)
        guard availableActions.contains(actionName) else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Accessibility action \(actionName) is not available for \(bundleId) element \(label). Available actions: \(availableActions.joined(separator: ", "))"
            )
        }

        let result = AXUIElementPerformAction(match.element, actionName as CFString)
        guard result == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Accessibility action \(actionName) failed for \(bundleId) element \(label): \(result.rawValue)"
            )
        }

        return snapshot(of: match.element, depth: match.depth)
    }

    public static func setAccessibilityValue(
        bundleId: String,
        label: String,
        role: String? = nil,
        value: String
    ) throws -> ActionAccessibilityNodeSnapshot {
        let match = try findAccessibilityElement(
            bundleId: bundleId,
            label: label,
            role: role,
            preferWritableText: true
        )

        return try writeAccessibilityValue(
            to: match.element,
            depth: match.depth,
            value: value,
            describing: "\(bundleId) element \(label)"
        )
    }

    public static func setFocusedAccessibilityValue(
        bundleId: String,
        role: String? = nil,
        value: String
    ) throws -> ActionAccessibilityNodeSnapshot {
        let app = try runningApplication(bundleId: bundleId)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success, let focusedElement = focusedValue else {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "Could not resolve focused accessibility element in \(bundleId)"
            )
        }

        let element = focusedElement as! AXUIElement
        let actualRole = axValue(element, attribute: kAXRoleAttribute) as? String ?? ""
        if let role, normalizedRole(actualRole) != normalizedRole(role) {
            throw ActionNativeAutomationError.accessibilityLookupFailed(
                "Focused accessibility element in \(bundleId) had role \(actualRole), expected \(role)"
            )
        }

        return try writeAccessibilityValue(
            to: element,
            depth: 0,
            value: value,
            describing: "focused \(bundleId) element"
        )
    }

    public static func setAccessibilityRoleValue(
        bundleId: String,
        role: String,
        value: String
    ) throws -> ActionAccessibilityNodeSnapshot {
        let match = try findAccessibilityElementByRole(
            bundleId: bundleId,
            role: role,
            preferWritableText: true
        )

        _ = AXUIElementSetAttributeValue(
            match.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        return try writeAccessibilityValue(
            to: match.element,
            depth: match.depth,
            value: value,
            describing: "first \(role) in \(bundleId)"
        )
    }

    /// Writes `kAXValue`, then reads it back and refuses to call an ignored write a success.
    ///
    /// `AXUIElementSetAttributeValue` returning `.success` only means the app accepted the
    /// message. A terminal's text area accepts the write and does nothing with it, which surfaced
    /// as `act.execute {kind:"type"}` reporting `succeeded` with no text anywhere — the expensive
    /// failure, because a wrong error costs a retry while a false success costs the recording.
    ///
    /// The read-back is polled: some apps apply the value on their next run loop turn, so a single
    /// immediate read would report a working write as ignored.
    private static func writeAccessibilityValue(
        to element: AXUIElement,
        depth: Int,
        value: String,
        describing target: String
    ) throws -> ActionAccessibilityNodeSnapshot {
        let before = readableAccessibilityValue(of: element)
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        )
        guard result == .success else {
            throw ActionNativeAutomationError.accessibilityActionFailed(
                "Accessibility value update failed for \(target): \(result.rawValue)"
            )
        }

        // A secure field echoes bullets or nothing by design, so there is no read-back to judge.
        if isSecureTextElement(element) {
            return snapshot(of: element, depth: depth)
        }

        var observed = before
        var verdict = ActionAccessibilityValueVerdict.unchanged
        for attempt in 0..<accessibilityValueReadBackAttempts {
            if attempt > 0 {
                usleep(accessibilityValueReadBackIntervalUs)
            }
            observed = readableAccessibilityValue(of: element)
            verdict = actionAccessibilityValueVerdict(
                requested: value,
                before: before,
                observed: observed
            )
            if verdict == .matched {
                break
            }
        }

        guard verdict == .matched else {
            throw ActionNativeAutomationError.accessibilityValueNotApplied(
                actionAccessibilityValueFailureDetail(
                    verdict: verdict,
                    requested: value,
                    observed: observed,
                    describing: target
                )
            )
        }

        return snapshot(of: element, depth: depth)
    }

    /// Press and release go through `ActionPointerChannel` so a drag is recorded — and optionally
    /// shown — by exactly the same path as a click. The interpolated `leftMouseDragged` motion in
    /// between stays here: it carries no button transition, so it is not a pointer event.
    @discardableResult
    public static func drag(
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int = 300,
        pointerEventLogPath: String? = nil
    ) throws -> ActionPointerGesture {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create event source")
        }

        let normalizedDuration = max(40, durationMs)
        let steps = max(6, Int(Double(normalizedDuration) / 10.0))
        let stepDelayUs = UInt32((Double(normalizedDuration) * 1000.0 / Double(steps)).rounded())
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y

        let press = try ActionPointerChannel.beginPrimaryPress(
            at: start,
            gesture: .drag,
            source: "drag",
            eventSource: source,
            log: ActionPointerEventLog.active(explicitPath: pointerEventLogPath)
        )
        usleep(15000)

        for index in 1...steps {
            let ratio = Double(index) / Double(steps)
            let current = CGPoint(
                x: start.x + (deltaX * ratio),
                y: start.y + (deltaY * ratio)
            )
            guard let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: current, mouseButton: .left) else {
                throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create drag events")
            }

            drag.post(tap: .cghidEventTap)
            usleep(stepDelayUs)
        }

        return try ActionPointerChannel.endPrimaryPress(press, at: end)
    }

    /// Scrolls at a screen point using pixel-unit scroll wheel events.
    ///
    /// Deltas are the raw CGEvent scroll wheel values, not a screen direction: `deltaY` becomes
    /// `wheel1` and `deltaX` becomes `wheel2`, with positive meaning up and left respectively.
    /// Which way the content then moves is the target app's decision — an app that honours the
    /// system's natural-scrolling preference inverts it — so callers that care should scroll once
    /// and observe rather than reason from the sign. Pixel units keep the motion smooth, which
    /// maps to trackpad gestures and — over a Simulator window — to Digital Crown rotation.
    /// A `durationMs` above zero spreads the deltas across interpolated steps the way `drag` does;
    /// zero posts the whole delta as a single event.
    public static func scroll(
        at point: CGPoint,
        deltaX: Double,
        deltaY: Double,
        durationMs: Int = 0
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create event source")
        }

        CGWarpMouseCursorPosition(point)
        usleep(10000)

        let steps = durationMs > 0 ? max(1, Int(Double(durationMs) / 16.0)) : 1
        let stepDelayUs = durationMs > 0
            ? UInt32((Double(durationMs) * 1000.0 / Double(steps)).rounded())
            : 0

        // Emit rounded prefix sums so the posted integer deltas always add up to the request.
        var postedX = 0
        var postedY = 0

        for index in 1...steps {
            let ratio = Double(index) / Double(steps)
            let targetX = Int((deltaX * ratio).rounded())
            let targetY = Int((deltaY * ratio).rounded())
            let stepX = targetX - postedX
            let stepY = targetY - postedY
            postedX = targetX
            postedY = targetY

            if stepX == 0 && stepY == 0 && steps > 1 {
                usleep(stepDelayUs)
                continue
            }

            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(stepY),
                wheel2: Int32(stepX),
                wheel3: 0
            ) else {
                throw ActionNativeAutomationError.accessibilityActionFailed("Unable to create scroll events")
            }

            event.location = point
            event.post(tap: .cghidEventTap)

            if stepDelayUs > 0 {
                usleep(stepDelayUs)
            }
        }
    }

    @discardableResult
    public static func dragFile(
        path: String,
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int = 300,
        pointerEventLogPath: String? = nil
    ) throws -> ActionPointerGesture {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ActionNativeAutomationError.dragPathNotFound(path)
        }

        return try drag(
            from: start,
            to: end,
            durationMs: durationMs,
            pointerEventLogPath: pointerEventLogPath
        )
    }

    /// Resolves the narrow Scout workspace drag semantically. The source is accepted only
    /// when Finder exposes an AXURL equal to the exact run fixture URL; no filename or
    /// coordinate fallback is used. The destination is the exact titled Scout-owned window.
    static func resolveWorkspaceDragFile(
        _ request: ActionWorkspaceDragFileRequest
    ) throws -> ActionWorkspaceDragResolution {
        let finderWindow = try exactWindowElement(
            bundleID: "com.apple.finder",
            title: request.finderWindowTitle
        )
        let requestedFinderFrame = ActionWorkspaceDragFileOperation.finderFrame(in: request.displayBounds)
        let positionResult = AXUIElementSetAttributeValue(
            finderWindow,
            kAXPositionAttribute as CFString,
            pointValue(requestedFinderFrame.origin)
        )
        let sizeResult = AXUIElementSetAttributeValue(
            finderWindow,
            kAXSizeAttribute as CFString,
            sizeValue(requestedFinderFrame.size)
        )
        guard positionResult == .success, sizeResult == .success else {
            throw ActionWorkspaceDragFileError.sourceNotFound
        }
        usleep(120_000)
        guard let finderFrame = cgBounds(of: finderWindow) else {
            throw ActionWorkspaceDragFileError.sourceNotFound
        }

        let expectedURL = request.fixtureURL.resolvingSymlinksInPath().standardizedFileURL
        var queue = [finderWindow]
        var visited = 0
        var sourceFrames: [CGRect] = []
        while let current = queue.first {
            queue.removeFirst()
            visited += 1
            if visited > 2_000 { break }

            if let candidateURL = accessibilityURL(of: current),
               candidateURL.resolvingSymlinksInPath().standardizedFileURL == expectedURL,
               let frame = cgBounds(of: current) {
                sourceFrames.append(frame)
            }
            queue.append(contentsOf: axChildren(of: current))
        }
        guard sourceFrames.count == 1, let sourceFrame = sourceFrames.first else {
            throw ActionWorkspaceDragFileError.sourceNotFound
        }

        let destinationWindow = try exactWindowElement(
            bundleID: request.destinationBundleID,
            title: request.destinationWindowTitle
        )
        guard let destinationFrame = cgBounds(of: destinationWindow) else {
            throw ActionWorkspaceDragFileError.destinationNotFound
        }
        var destinationQueue = [destinationWindow]
        var destinationVisited = 0
        var destinationTargetFrames: [CGRect] = []
        while let current = destinationQueue.first {
            destinationQueue.removeFirst()
            destinationVisited += 1
            if destinationVisited > 2_000 { break }
            if (axValue(current, attribute: kAXIdentifierAttribute) as? String)
                == request.destinationAXIdentifier,
               let frame = cgBounds(of: current) {
                destinationTargetFrames.append(frame)
            }
            destinationQueue.append(contentsOf: axChildren(of: current))
        }
        guard destinationTargetFrames.count == 1, let destinationTargetFrame = destinationTargetFrames.first else {
            throw ActionWorkspaceDragFileError.destinationNotFound
        }

        return ActionWorkspaceDragResolution(
            source: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            destination: CGPoint(x: destinationTargetFrame.midX, y: destinationTargetFrame.midY),
            finderWindowFrame: finderFrame,
            destinationWindowFrame: destinationFrame
        )
    }

    static func closeWorkspaceFinderWindow(title: String) throws {
        let window = try exactWindowElement(bundleID: "com.apple.finder", title: title)
        guard let closeButton = axValue(window, attribute: kAXCloseButtonAttribute) else {
            return
        }
        _ = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }

    public static func calculatorDisplayValue() throws -> String {
        let window = try firstWindowElement(for: "com.apple.calculator")
        var queue = [window]
        var candidates: [String] = []

        while let current = queue.first {
            queue.removeFirst()

            let role = axValue(current, attribute: kAXRoleAttribute) as? String ?? ""
            let title = sanitizedCalculatorString(stringValue(axValue(current, attribute: kAXTitleAttribute)))
            let value = sanitizedCalculatorString(stringValue(axValue(current, attribute: kAXValueAttribute)))
            let description = sanitizedCalculatorString(stringValue(axValue(current, attribute: kAXDescriptionAttribute)))

            if role != kAXButtonRole as String {
                for candidate in [value, title, description].compactMap({ $0 }) {
                    if isCalculatorDisplayCandidate(candidate, role: role) {
                        candidates.append(candidate)
                    }
                }
            }

            queue.append(contentsOf: axChildren(of: current))
        }

        guard !candidates.isEmpty else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("Could not find Calculator display value")
        }

        if let resolved = candidates.last(where: looksLikeResolvedCalculatorResult(_:)) {
            return resolved
        }

        return candidates.last!
    }

    public static func calculatorAccessibilityNodes() throws -> [ActionAccessibilityNodeSnapshot] {
        try accessibilityNodes(bundleId: "com.apple.calculator")
    }

    public static func accessibilityNodes(
        bundleId: String,
        maxDepth: Int = 6,
        maxNodes: Int = 250,
        root: ActionAccessibilityRoot = .window
    ) throws -> [ActionAccessibilityNodeSnapshot] {
        let app = try runningApplication(bundleId: bundleId)
        return try accessibilityNodes(pid: app.processIdentifier, maxDepth: maxDepth, maxNodes: maxNodes, root: root)
    }

    public static func accessibilityNodes(
        selection: ActionNativeWindowTarget,
        maxDepth: Int = 6,
        maxNodes: Int = 250,
        root: ActionAccessibilityRoot = .window
    ) throws -> [ActionAccessibilityNodeSnapshot] {
        let app = try selection.application()
        return try accessibilityNodes(
            pid: app.processIdentifier, maxDepth: maxDepth, maxNodes: maxNodes,
            root: root, windowNumber: selection.windowNumber
        )
    }

    public static func accessibilityNodes(
        pid: pid_t,
        maxDepth: Int = 6,
        maxNodes: Int = 250,
        root: ActionAccessibilityRoot = .window,
        windowNumber: CGWindowID? = nil
    ) throws -> [ActionAccessibilityNodeSnapshot] {
        guard maxNodes > 0 else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("max-nodes must be greater than zero")
        }
        let root = windowNumber == nil ? root : .window
        let rootElement = try accessibilityRoot(pid: pid, root: root, windowNumber: windowNumber)
        let rootWindow = root == .window ? ActionAccessibilityWindowSnapshot(
            title: stringValue(axValue(rootElement, attribute: kAXTitleAttribute)),
            frame: bounds(of: rootElement)
        ) : nil
        var queue: [(AXUIElement, Int, String)] = [(rootElement, 0, "root")]
        var cursor = 0
        var result: [ActionAccessibilityNodeSnapshot] = []

        while cursor < queue.count, result.count < maxNodes {
            let (current, depth, path) = queue[cursor]
            cursor += 1
            result.append(snapshot(of: current, depth: depth, path: path))

            if depth < maxDepth {
                queue.append(contentsOf: axChildren(of: current).enumerated().map { index, child in
                    (child, depth + 1, path == "root" ? "\(index)" : "\(path).\(index)")
                })
            }
        }
        result[0].root = root
        result[0].rootWindow = rootWindow
        result[0].truncated = cursor < queue.count
        return result
    }
}

private func exactWindowElement(bundleID: String, title: String) throws -> AXUIElement {
    let app: NSRunningApplication
    do {
        app = try ActionNativeAutomation.runningApplication(bundleId: bundleID)
    } catch {
        if bundleID == ActionWorkspaceDragFileRequest.scoutBundleID {
            throw ActionWorkspaceDragFileError.destinationNotFound
        }
        throw ActionWorkspaceDragFileError.sourceNotFound
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    guard let windows = axValue(application, attribute: kAXWindowsAttribute) as? [AXUIElement] else {
        if bundleID == ActionWorkspaceDragFileRequest.scoutBundleID {
            throw ActionWorkspaceDragFileError.destinationNotFound
        }
        throw ActionWorkspaceDragFileError.sourceNotFound
    }
    let matches = windows.filter {
        (axValue($0, attribute: kAXTitleAttribute) as? String) == title
    }
    guard matches.count == 1, let window = matches.first else {
        if bundleID == ActionWorkspaceDragFileRequest.scoutBundleID {
            throw ActionWorkspaceDragFileError.destinationNotFound
        }
        throw ActionWorkspaceDragFileError.sourceNotFound
    }
    return window
}

private func accessibilityURL(of element: AXUIElement) -> URL? {
    let raw = axValue(element, attribute: kAXURLAttribute)
    if let url = raw as? URL { return url }
    if let string = raw as? String { return URL(string: string) }
    return nil
}

private func cgBounds(of element: AXUIElement) -> CGRect? {
    guard let bounds = bounds(of: element) else { return nil }
    return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
}

private struct ActionAccessibilityElementMatch {
    let element: AXUIElement
    let depth: Int
    let score: Int
}

private func axValue(_ element: AXUIElement, attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        return nil
    }

    return value
}

private func collectWindows(of application: AXUIElement) -> [AXUIElement] {
    var seen = Set<ObjectIdentifier>()
    var windows: [AXUIElement] = []

    func append(_ element: AXUIElement) {
        let id = ObjectIdentifier(element)
        guard !seen.contains(id) else { return }
        seen.insert(id)
        windows.append(element)
    }

    for element in axElementArray(application, attribute: kAXWindowsAttribute) {
        append(element)
    }
    for child in axChildren(of: application) {
        let role = axValue(child, attribute: kAXRoleAttribute) as? String
        if role == (kAXWindowRole as String) {
            append(child)
        }
    }
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let raw = axValue(application, attribute: attribute),
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            append(unsafeDowncast(raw, to: AXUIElement.self))
        }
    }
    return windows
}

/// `AXWindows` arrives as a CFArray of AXUIElements. The Swift `as? [AXUIElement]`
/// cast loses that array, which is why raise-window saw no windows while inspect
/// still found the focused one.
private func axElementArray(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else {
        return []
    }
    if let windows = value as? [AXUIElement] {
        return windows
    }
    guard CFGetTypeID(value) == CFArrayGetTypeID() else {
        return []
    }
    let array = value as! CFArray
    var windows: [AXUIElement] = []
    let count = CFArrayGetCount(array)
    windows.reserveCapacity(count)
    for index in 0..<count {
        guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
        let element = unsafeBitCast(pointer, to: AXUIElement.self)
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { continue }
        windows.append(element)
    }
    return windows
}

/// Read-back budget for a value write: six reads spaced 40ms apart, so an app that applies the
/// value on its next run loop turn still gets confirmed, and a write that is being ignored costs
/// about 200ms before it is reported.
private let accessibilityValueReadBackAttempts = 6
private let accessibilityValueReadBackIntervalUs: UInt32 = 40_000

/// Reads `kAXValue` as text. Numeric values (sliders, steppers) are compared by their string form
/// rather than treated as unreadable, so setting one is still verifiable.
private func readableAccessibilityValue(of element: AXUIElement) -> String? {
    let raw = axValue(element, attribute: kAXValueAttribute)
    if let text = raw as? String {
        return text
    }
    if let number = raw as? NSNumber {
        return number.stringValue
    }
    return nil
}

private func isSecureTextElement(_ element: AXUIElement) -> Bool {
    let role = axValue(element, attribute: kAXRoleAttribute) as? String
    let subrole = axValue(element, attribute: kAXSubroleAttribute) as? String
    // AppKit exposes this as a subrole constant only; the same string is the role a plain
    // secure field reports, so both are checked against the literal.
    let secureRole = "AXSecureTextField"
    return role == secureRole || subrole == secureRole
}

private func axChildren(of element: AXUIElement) -> [AXUIElement] {
    if let direct = axValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
        return direct
    }

    return []
}

private func snapshot(of element: AXUIElement, depth: Int, path: String? = nil) -> ActionAccessibilityNodeSnapshot {
    ActionAccessibilityNodeSnapshot(
        role: axValue(element, attribute: kAXRoleAttribute) as? String ?? "",
        title: stringValue(axValue(element, attribute: kAXTitleAttribute)),
        detail: stringValue(axValue(element, attribute: kAXDescriptionAttribute)),
        value: stringValue(axValue(element, attribute: kAXValueAttribute)),
        identifier: stringValue(axValue(element, attribute: kAXIdentifierAttribute)),
        depth: depth,
        frame: bounds(of: element),
        actions: axActions(of: element),
        settableAttributes: settableAttributes(of: element),
        enabled: boolValue(axValue(element, attribute: kAXEnabledAttribute)),
        focused: boolValue(axValue(element, attribute: kAXFocusedAttribute)),
        path: path
    )
}

private func axActions(of element: AXUIElement) -> [String] {
    var actionNames: CFArray?
    let error = AXUIElementCopyActionNames(element, &actionNames)
    guard error == .success, let names = actionNames as? [String] else {
        return []
    }
    return names.sorted()
}

private let auditedSettableAttributes: [(String, String)] = [
    ("value", kAXValueAttribute),
    ("selectedText", kAXSelectedTextAttribute),
    ("focused", kAXFocusedAttribute),
    ("position", kAXPositionAttribute),
    ("size", kAXSizeAttribute),
]

private func settableAttributes(of element: AXUIElement) -> [String] {
    auditedSettableAttributes.compactMap { label, attribute in
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard error == .success, settable.boolValue else {
            return nil
        }
        return label
    }
}

private func bounds(of element: AXUIElement) -> ActionAccessibilityBounds? {
    guard let position = point(from: axValue(element, attribute: kAXPositionAttribute)),
          let size = size(from: axValue(element, attribute: kAXSizeAttribute)) else {
        return nil
    }

    return ActionAccessibilityBounds(
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height
    )
}

private func accessibilityRoot(pid: pid_t, root: ActionAccessibilityRoot, windowNumber: CGWindowID? = nil) throws -> AXUIElement {
    if let windowNumber {
        let application = AXUIElementCreateApplication(pid)
        for window in collectWindows(of: application) {
            var candidate: CGWindowID = 0
            if actionAXWindowNumber(window, &candidate) == .success, candidate == windowNumber {
                return window
            }
        }
        throw ActionNativeAutomationError.accessibilityLookupFailed(
            "window-not-found: No accessibility window \(windowNumber) found for pid \(pid)"
        )
    }
    switch root {
    case .window: return try firstWindowElement(pid: pid)
    case .application: return AXUIElementCreateApplication(pid)
    }
}

private func resolveAccessibilityPath(selection: ActionNativeWindowTarget, target: ActionAccessibilityPathTarget) throws -> AXUIElement {
    do {
        let app = try selection.application()
        var element = try accessibilityRoot(pid: app.processIdentifier, root: target.root, windowNumber: selection.windowNumber)
        for (depth, index) in target.indices.enumerated() {
            let children = axChildren(of: element)
            guard children.indices.contains(index) else {
                throw ActionNativeAutomationError.accessibilityLookupFailed(
                    "child \(index) at depth \(depth + 1) is out of range (\(children.count) children) for \(target.path)"
                )
            }
            element = children[index]
        }
        // A stale/inaccessible AX reference must not reach an action even without expectations.
        guard axValue(element, attribute: kAXRoleAttribute) is String else {
            throw ActionNativeAutomationError.accessibilityLookupFailed("could not read resolved element at \(target.path)")
        }
        return element
    } catch {
        throw ActionNativeAutomationError.accessibilityLookupFailed("path-mismatch: \(error.localizedDescription)")
    }
}

private func firstWindowElement(for bundleId: String) throws -> AXUIElement {
    let app = try ActionNativeAutomation.runningApplication(bundleId: bundleId)
    return try firstWindowElement(pid: app.processIdentifier)
}

private func firstWindowElement(pid: pid_t) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(pid)

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

    throw ActionNativeAutomationError.accessibilityLookupFailed("No accessibility window found for pid \(pid)")
}

private func windowArea(_ element: AXUIElement) -> Double {
    guard let bounds = bounds(of: element) else {
        return 0
    }
    return max(0, bounds.width) * max(0, bounds.height)
}

private func findButton(in root: AXUIElement, label: String) -> AXUIElement? {
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

private func findAccessibilityElement(
    bundleId: String,
    label: String,
    role: String?,
    preferWritableText: Bool,
    maxDepth: Int = 20,
    maxNodes: Int = 12_000
) throws -> ActionAccessibilityElementMatch {
    let app = try ActionNativeAutomation.runningApplication(bundleId: bundleId)
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let expectedLabel = normalizedText(label)
    let expectedRole = normalizedRole(role)
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var best: ActionAccessibilityElementMatch?
    var visited = 0

    while let (current, depth) = queue.first {
        queue.removeFirst()
        visited += 1
        if visited > maxNodes {
            break
        }

        let role = axValue(current, attribute: kAXRoleAttribute) as? String ?? ""
        if let score = scoreAccessibilityElement(
            current,
            actualRole: role,
            expectedLabel: expectedLabel,
            expectedRole: expectedRole,
            preferWritableText: preferWritableText
        ) {
            let match = ActionAccessibilityElementMatch(element: current, depth: depth, score: score)
            if best == nil || match.score > best!.score {
                best = match
            }
        }

        if depth < maxDepth {
            queue.append(contentsOf: axChildren(of: current).map { ($0, depth + 1) })
        }
    }

    if let best {
        return best
    }

    let roleDetail = role.map { " role \($0)" } ?? ""
    throw ActionNativeAutomationError.accessibilityLookupFailed(
        "Could not find accessibility element \(label)\(roleDetail) in \(bundleId)"
    )
}

private func findAccessibilityElementByRole(
    bundleId: String,
    role: String,
    preferWritableText: Bool,
    maxDepth: Int = 24,
    maxNodes: Int = 5_000
) throws -> ActionAccessibilityElementMatch {
    let expectedRole = normalizedRole(role)
    var queue: [(AXUIElement, Int)] = [(try firstWindowElement(for: bundleId), 0)]
    var visited = 0

    while let (current, depth) = queue.first {
        queue.removeFirst()
        visited += 1
        if visited > maxNodes {
            break
        }

        let actualRole = axValue(current, attribute: kAXRoleAttribute) as? String ?? ""
        if normalizedRole(actualRole) == expectedRole,
           !preferWritableText || settableAttributes(of: current).contains("value") {
            return ActionAccessibilityElementMatch(element: current, depth: depth, score: 100)
        }

        if depth < maxDepth {
            queue.append(contentsOf: axChildren(of: current).map { ($0, depth + 1) })
        }
    }

    throw ActionNativeAutomationError.accessibilityLookupFailed(
        "Could not find accessibility element with role \(role) in \(bundleId)"
    )
}

private func scoreAccessibilityElement(
    _ element: AXUIElement,
    actualRole: String,
    expectedLabel: String,
    expectedRole: String?,
    preferWritableText: Bool
) -> Int? {
    guard expectedRole == nil || normalizedRole(actualRole) == expectedRole else {
        return nil
    }

    var score = 0
    var matched = false
    for candidate in accessibilityLabelCandidates(for: element) {
        let normalized = normalizedText(candidate)
        if normalized == expectedLabel {
            score = max(score, 100)
            matched = true
        } else if normalized.hasPrefix(expectedLabel) || expectedLabel.hasPrefix(normalized) {
            score = max(score, 84)
            matched = true
        } else if normalized.contains(expectedLabel) || expectedLabel.contains(normalized) {
            score = max(score, 72)
            matched = true
        }
    }

    guard matched else {
        return nil
    }

    let role = normalizedRole(actualRole) ?? ""
    if expectedRole != nil {
        score += 24
    }
    if preferWritableText {
        score += writableTextRoles.contains(role) ? 28 : -20
    } else {
        score += pressableRoles.contains(role) ? 18 : -10
    }

    return score
}

private func accessibilityLabelCandidates(for element: AXUIElement) -> [String] {
    [
        stringValue(axValue(element, attribute: kAXTitleAttribute)),
        stringValue(axValue(element, attribute: kAXDescriptionAttribute)),
        stringValue(axValue(element, attribute: kAXValueAttribute)),
        stringValue(axValue(element, attribute: kAXIdentifierAttribute)),
        stringValue(axValue(element, attribute: kAXHelpAttribute)),
    ].compactMap { value in
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

private let pressableRoles: Set<String> = [
    "button",
    "checkbox",
    "link",
    "menuitem",
    "popupbutton",
    "radiobutton",
]

private let writableTextRoles: Set<String> = [
    "combobox",
    "searchfield",
    "textarea",
    "textfield",
]

private let roleAliases: [String: String] = [
    "input": "textfield",
    "select": "popupbutton",
    "search": "searchfield",
    "text": "textfield",
]

private func normalizedText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private func normalizedRole(_ role: String?) -> String? {
    guard let role else {
        return nil
    }

    let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    let withoutPrefix = trimmed.lowercased().hasPrefix("ax")
        ? String(trimmed.dropFirst(2))
        : trimmed

    return withoutPrefix
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        .withRoleAlias()
}

private func normalizedAccessibilityActionName(_ action: String) -> String {
    let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return kAXPressAction as String
    }
    return trimmed.hasPrefix("AX") ? trimmed : "AX\(trimmed)"
}

private extension String {
    func withRoleAlias() -> String {
        roleAliases[self] ?? self
    }
}

private func isCalculatorDisplayCandidate(_ string: String) -> Bool {
    isCalculatorDisplayCandidate(string, role: nil)
}

private func isCalculatorDisplayCandidate(_ string: String, role: String?) -> Bool {
    guard !string.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789.,+-−×÷*/=()% ")
    let trimmed = sanitizedCalculatorString(string) ?? ""
    guard trimmed.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains(_:)) else {
        return false
    }
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return false
    }
    if let role {
        return role == kAXStaticTextRole as String || role == kAXTextFieldRole as String || role == kAXGroupRole as String
    }
    return true
}

private func looksLikeResolvedCalculatorResult(_ string: String) -> Bool {
    guard let first = string.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) || first == "-" else {
        return false
    }
    let disallowed = CharacterSet(charactersIn: "+×÷*/=%()")
    return string.unicodeScalars.allSatisfy { !disallowed.contains($0) }
}

private func stringValue(_ value: AnyObject?) -> String? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    case let attributed as NSAttributedString:
        return attributed.string
    default:
        return value.map { "\($0)" }
    }
}

private func boolValue(_ value: AnyObject?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    default:
        return nil
    }
}

private func sanitizedCalculatorString(_ string: String?) -> String? {
    guard let string else {
        return nil
    }

    let filteredScalars = string.unicodeScalars.filter { scalar in
        switch scalar.properties.generalCategory {
        case .format, .control:
            return false
        default:
            return true
        }
    }

    let sanitized = String(String.UnicodeScalarView(filteredScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? nil : sanitized
}

private func pointValue(_ point: CGPoint) -> AXValue {
    var point = point
    return AXValueCreate(.cgPoint, &point)!
}

private func sizeValue(_ size: CGSize) -> AXValue {
    var size = size
    return AXValueCreate(.cgSize, &size)!
}

private func point(from value: AnyObject?) -> CGPoint? {
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

private func size(from value: AnyObject?) -> CGSize? {
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
