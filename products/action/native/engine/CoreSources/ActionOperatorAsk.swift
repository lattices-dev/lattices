import Foundation

public enum ActionOperatorAskItemState: String, Codable, Sendable {
    case missing, granted, unknown
}

public struct ActionOperatorAskItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public var state: ActionOperatorAskItemState
    /// The step that fixes this row; the panel shows it on the row instead of the footer.
    public let step: String?

    public init(id: String, label: String, state: ActionOperatorAskItemState, step: String? = nil) {
        self.id = id
        self.label = label
        self.state = state
        self.step = step
    }
}

/// The app the operator acts on. The panel shows its icon and lets them drag it into a list.
public struct ActionOperatorAskSubject: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
}

public enum ActionOperatorAskSettingsPane: String, Codable, CaseIterable, Sendable {
    case accessibility
    case screenRecording = "screen-recording"
    case automation
    case inputMonitoring = "input-monitoring"
    case fullDiskAccess = "full-disk-access"
    case loginItems = "login-items"

    public var url: URL {
        let destination: String
        switch self {
        // The extension form moves an open Settings window to the new list;
        // the legacy com.apple.preference.security form only works on launch.
        case .accessibility: destination = "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        case .screenRecording: destination = "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        case .automation: destination = "com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        case .inputMonitoring: destination = "com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        case .fullDiskAccess: destination = "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        case .loginItems: destination = "com.apple.LoginItems-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:\(destination)")!
    }
}

public enum ActionOperatorAskAction: Codable, Equatable, Sendable {
    case openSettings(pane: ActionOperatorAskSettingsPane)
    case reveal(path: String)
    case openApp(bundleId: String?, path: String?)
    case openURL(url: URL)
    case agent

    private enum CodingKeys: String, CodingKey { case kind, pane, path, bundleId, url }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "open-settings":
            self = .openSettings(pane: try values.decode(ActionOperatorAskSettingsPane.self, forKey: .pane))
        case "reveal":
            let path = try values.decode(String.self, forKey: .path)
            try Self.validateAbsolutePath(path)
            self = .reveal(path: path)
        case "open-app":
            let bundleId = try values.decodeIfPresent(String.self, forKey: .bundleId)
            let path = try values.decodeIfPresent(String.self, forKey: .path)
            if let path { try Self.validateAbsolutePath(path) }
            if let bundleId, bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ActionOperatorAskValidationError("open-app bundleId must not be empty.")
            }
            guard bundleId != nil || path != nil else {
                throw ActionOperatorAskValidationError("open-app requires a bundleId or absolute path.")
            }
            self = .openApp(bundleId: bundleId, path: path)
        case "open-url":
            let raw = try values.decode(String.self, forKey: .url)
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty,
                  raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw ActionOperatorAskValidationError("open-url requires an https URL.")
            }
            self = .openURL(url: url)
        case "agent":
            self = .agent
        default:
            throw ActionOperatorAskValidationError("Unknown action kind: \(kind).")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openSettings(let pane):
            try values.encode("open-settings", forKey: .kind)
            try values.encode(pane, forKey: .pane)
        case .reveal(let path):
            try values.encode("reveal", forKey: .kind)
            try values.encode(path, forKey: .path)
        case .openApp(let bundleId, let path):
            try values.encode("open-app", forKey: .kind)
            try values.encodeIfPresent(bundleId, forKey: .bundleId)
            try values.encodeIfPresent(path, forKey: .path)
        case .openURL(let url):
            try values.encode("open-url", forKey: .kind)
            try values.encode(url.absoluteString, forKey: .url)
        case .agent:
            try values.encode("agent", forKey: .kind)
        }
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ActionOperatorAskValidationError("Action path must be absolute.")
        }
    }
}

public struct ActionOperatorAskStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let action: ActionOperatorAskAction
}

public struct ActionOperatorAskRequester: Codable, Equatable, Sendable {
    public let agent: String
    public let task: String
}

public enum ActionOperatorAskResolution: String, Codable, Sendable {
    case verify, user
}

public struct ActionOperatorAskRequest: Codable, Equatable, Sendable {
    public let schema: Int
    public let id: String
    public let key: String
    public let requester: ActionOperatorAskRequester
    public let title: String
    public let why: String
    public let subject: ActionOperatorAskSubject?
    public let items: [ActionOperatorAskItem]
    public let steps: [ActionOperatorAskStep]
    public let resolution: ActionOperatorAskResolution
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schema, id, key, requester, title, why, subject, items, steps, resolution, expiresAt
    }

    public static func parse(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        guard schema == 1 else { throw ActionOperatorAskValidationError("Unsupported ask-user schema: \(schema).") }
        id = try values.decode(String.self, forKey: .id)
        key = try values.decode(String.self, forKey: .key)
        requester = try values.decode(ActionOperatorAskRequester.self, forKey: .requester)
        title = try values.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionOperatorAskValidationError("Request title must not be empty.")
        }
        why = try values.decode(String.self, forKey: .why)
        subject = try values.decodeIfPresent(ActionOperatorAskSubject.self, forKey: .subject)
        if let subject {
            guard !subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  subject.path.hasPrefix("/"), !subject.path.contains("\0") else {
                throw ActionOperatorAskValidationError("subject needs a name and an absolute path.")
            }
        }
        items = try values.decodeIfPresent([ActionOperatorAskItem].self, forKey: .items) ?? []
        steps = try values.decode([ActionOperatorAskStep].self, forKey: .steps)
        guard steps.count <= 4 else { throw ActionOperatorAskValidationError("Request may have at most four steps.") }
        guard Set(items.map(\.id)).count == items.count, Set(steps.map(\.id)).count == steps.count else {
            throw ActionOperatorAskValidationError("Item ids and step ids must be unique within their lists.")
        }
        let stepIDs = Set(steps.map(\.id))
        for item in items where item.step.map({ !stepIDs.contains($0) }) ?? false {
            throw ActionOperatorAskValidationError("Item \(item.id) links an unknown step.")
        }
        resolution = try values.decodeIfPresent(ActionOperatorAskResolution.self, forKey: .resolution) ?? .verify
        if let raw = try values.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = Self.parseDate(raw) else {
                throw ActionOperatorAskValidationError("expiresAt must be an ISO8601 date.")
            }
            expiresAt = date
        } else {
            expiresAt = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(id, forKey: .id)
        try values.encode(key, forKey: .key)
        try values.encode(requester, forKey: .requester)
        try values.encode(title, forKey: .title)
        try values.encode(why, forKey: .why)
        try values.encodeIfPresent(subject, forKey: .subject)
        try values.encode(items, forKey: .items)
        try values.encode(steps, forKey: .steps)
        try values.encode(resolution, forKey: .resolution)
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try values.encode(formatter.string(from: expiresAt), forKey: .expiresAt)
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public struct ActionOperatorAskValidationError: LocalizedError, Sendable {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { detail }
}

public struct ActionOperatorAskControl: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case waiting, satisfied, cancelled }
    public struct ItemUpdate: Codable, Equatable, Sendable {
        public let id: String
        public let state: ActionOperatorAskItemState
    }
    public let status: Status
    public let detail: String?
    public let items: [ItemUpdate]?
}

public enum ActionOperatorAskOutcome: String, Codable, Sendable {
    case satisfied, confirmed, declined, cancelled, expired
}

public struct ActionOperatorAskReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case answered, error }
    public let status: Status
    public let outcome: ActionOperatorAskOutcome?
    public let detail: String

    public static func answered(outcome: ActionOperatorAskOutcome, detail: String) -> Self {
        Self(status: .answered, outcome: outcome, detail: detail)
    }

    public static func error(detail: String) -> Self {
        Self(status: .error, outcome: nil, detail: detail)
    }
}

/// File-driven state only. Item checks never imply satisfaction; the caller's
/// explicit satisfied control status is the sole source of that outcome.
public struct ActionOperatorAskState: Equatable, Sendable {
    public let request: ActionOperatorAskRequest
    public private(set) var items: [ActionOperatorAskItem]
    public private(set) var detail: String?
    public private(set) var lastControl: ActionOperatorAskControl?
    public private(set) var outcome: ActionOperatorAskOutcome?
    public private(set) var satisfactionStartedAt: Date?

    public init(request: ActionOperatorAskRequest) {
        self.request = request
        items = request.items
    }

    public var allowsDone: Bool { request.resolution == .user }
    public var isShowingSuccess: Bool { satisfactionStartedAt != nil && outcome == nil }
    /// Every row reads granted. Display only: the verifier can lag behind the
    /// rows, so this never implies satisfaction.
    public var allGranted: Bool { !items.isEmpty && items.allSatisfy { $0.state == .granted } }
    /// Done is on offer when the operator decides (resolution user) or, under
    /// verify, once every row reads granted and the verifier has not caught up.
    public var offersDone: Bool { outcome == nil && !isShowingSuccess && (allowsDone || allGranted) }

    /// The operator's Done. Under user resolution it confirms. Under verify it
    /// closes as declined, the wire's safe close: the caller re-checks the real
    /// grants and upgrades the answer to satisfied when they hold.
    public mutating func done() {
        guard offersDone else { return }
        if allowsDone {
            outcome = .confirmed
        } else {
            detail = "Done with every row granted"
            outcome = .declined
        }
    }

    public mutating func applyControl(data: Data?, now: Date) {
        guard outcome == nil, let data,
              let control = try? JSONDecoder().decode(ActionOperatorAskControl.self, from: data) else { return }
        // A stale waiting write cannot undo the success display or restart its
        // timer. Cancellation can still withdraw the request before completion.
        if satisfactionStartedAt != nil && control.status == .waiting { return }
        lastControl = control
        switch control.status {
        case .waiting:
            detail = control.detail
            for update in control.items ?? [] {
                if let index = items.firstIndex(where: { $0.id == update.id }) {
                    items[index].state = update.state
                }
            }
        case .satisfied:
            if satisfactionStartedAt == nil { satisfactionStartedAt = now }
            detail = "All set"
            for index in items.indices { items[index].state = .granted }
        case .cancelled:
            detail = control.detail
            outcome = .cancelled
        }
    }

    public mutating func confirm() {
        guard outcome == nil, allowsDone, !isShowingSuccess else { return }
        outcome = .confirmed
    }

    public mutating func decline() {
        guard outcome == nil else { return }
        outcome = .declined
    }

    public mutating func expireIfNeeded(now: Date) {
        guard outcome == nil, let expiresAt = request.expiresAt, now >= expiresAt else { return }
        outcome = .expired
    }

    public mutating func finishSatisfaction(now: Date) {
        guard outcome == nil, let startedAt = satisfactionStartedAt,
              now.timeIntervalSince(startedAt) >= 1.2 else { return }
        outcome = .satisfied
    }
}
