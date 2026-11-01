import Foundation

public struct ActionAgentRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: [String: String]

    public init(id: String = UUID().uuidString, method: String, params: [String: String] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ActionAgentResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: [String: String]?
    public let error: String?

    public init(id: String, ok: Bool, result: [String: String]? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public enum ActionAgentMethod: String, CaseIterable, Sendable {
    case ping
    case status
    case launchApp = "app.launch"
    case permissionsSnapshot = "permissions.snapshot"
    case permissionsRequest = "permissions.request"
    case accessibilityRequest = "permissions.requestAccessibility"
    case openAccessibilitySettings = "settings.openAccessibility"
    case openScreenRecordingSettings = "settings.openScreenRecording"
    case activateApp = "app.activate"
    case typeText = "input.typeText"
    case drag = "input.drag"
    case pressAccessibilityElement = "accessibility.pressElement"
    case setAccessibilityValue = "accessibility.setValue"
    case setWindowFrame = "window.setFrame"
    case getWindowFrame = "window.getFrame"
    case calculatorButtons = "calculator.buttons"
    case clickCalculatorButton = "calculator.clickButton"
    case calculatorDisplayValue = "calculator.displayValue"
    case driveBegin = "drive.begin"
    case driveTouch = "drive.touch"
    case driveRelease = "drive.release"
    case driveStatus = "drive.status"
    case sessionsPrune = "sessions.prune"
    case sessionsClear = "sessions.clear"
    case workspaceDragFile = "workspace.dragFile"
    case workspaceCancelOperation = "workspace.cancelOperation"
    case recordAppWindow = "capture.recordAppWindow"
    case recordRegion = "capture.recordRegion"
    case screenshotAppWindow = "capture.screenshotAppWindow"
    case screenshotRegion = "capture.screenshotRegion"
    case screenshotScreen = "capture.screenshotScreen"
}

public enum ActionAgentDefaults {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 4319
    /// A connection silent this long, with no driving lease, is dropped so it can't pin the agent.
    public static let silentConnectionSeconds: TimeInterval = 30 * 60
}
