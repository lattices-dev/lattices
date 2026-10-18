import AppKit
import Foundation

enum MouseGestureDirection: String, CaseIterable, Codable, Equatable {
    case left
    case right
    case up
    case down

    var displayLabel: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        }
    }
}

enum MouseShortcutTriggerKind: String, Codable, Equatable {
    case drag
    case click
    case shape
}

enum MouseShortcutActionType: String, Codable, Equatable {
    case spaceNext = "space.next"
    case spacePrevious = "space.previous"
    case screenMapToggle = "screenmap.toggle"
    case dictationStart = "dictation.start"
    case shortcutSend = "shortcut.send"
    case appActivate = "app.activate"
}

/// Shift is sampled at mouse-down, so releasing it before the button cannot
/// accidentally turn a window move into a desktop switch.
enum MouseGestureSpaceMove {
    static func offset(for action: MouseShortcutActionType, flags: CGEventFlags) -> Int? {
        guard flags.contains(.maskShift) else { return nil }
        switch action {
        case .spacePrevious: return -1
        case .spaceNext: return 1
        default: return nil
        }
    }

    /// Ordinary desktops only; fullscreen apps are not window destinations.
    static func destination(in desktops: [Int], sourceSpaces: [Int], offset: Int) -> Int? {
        guard sourceSpaces.count == 1, let source = sourceSpaces.first,
              let index = desktops.firstIndex(of: source), abs(offset) == 1,
              desktops.indices.contains(index + offset) else { return nil }
        return desktops[index + offset]
    }
}

enum MouseShortcutModifier: String, CaseIterable, Codable, Equatable {
    case command
    case control
    case option
    case shift

    var appleScriptToken: String {
        switch self {
        case .command: return "command down"
        case .control: return "control down"
        case .option: return "option down"
        case .shift: return "shift down"
        }
    }

    var displayLabel: String {
        switch self {
        case .command: return "Cmd"
        case .control: return "Ctrl"
        case .option: return "Option"
        case .shift: return "Shift"
        }
    }
}

enum MouseShortcutButton: Hashable, Codable, Equatable {
    case right
    case middle
    case button4
    case button5
    case number(Int)

    init(rawButtonNumber: Int) {
        switch rawButtonNumber {
        case 1: self = .right
        case 2: self = .middle
        case 3: self = .button4
        case 4: self = .button5
        default: self = .number(rawButtonNumber)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = MouseShortcutButton(rawButtonNumber: intValue)
            return
        }

        let stringValue = try container.decode(String.self)
        switch stringValue.lowercased() {
        case "right", "button.right":
            self = .right
        case "middle", "button.middle":
            self = .middle
        case "back", "button.back", "button4", "button.button4":
            self = .button4
        case "forward", "button.forward", "button5", "button.button5":
            self = .button5
        default:
            if let raw = Int(stringValue.filter(\.isNumber)) {
                self = MouseShortcutButton(rawButtonNumber: raw)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported mouse button '\(stringValue)'")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(configValue)
    }

    var rawButtonNumber: Int {
        switch self {
        case .right: return 1
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        case .number(let value): return value
        }
    }

    var configValue: String {
        switch self {
        case .right: return "right"
        case .middle: return "middle"
        case .button4: return "back"
        case .button5: return "forward"
        case .number(let value): return "button\(value)"
        }
    }

    var displayLabel: String {
        switch self {
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        case .button4: return "Back Button"
        case .button5: return "Forward Button"
        case .number(let value): return "Button \(value)"
        }
    }

    var triggerToken: String {
        switch self {
        case .right: return "button.right"
        case .middle: return "button.middle"
        case .button4: return "button.back"
        case .button5: return "button.forward"
        case .number(let value): return "button.\(value)"
        }
    }
}

struct MouseShortcutDeviceSelector: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case match
        case vendorId
        case productId
        case locationId
        case product
        case manufacturer
        case transport
    }

    var match: String?
    var vendorId: Int?
    var productId: Int?
    var locationId: Int?
    var product: String?
    var manufacturer: String?
    var transport: String?

    static let any = MouseShortcutDeviceSelector(match: "any")

    init(
        match: String? = "any",
        vendorId: Int? = nil,
        productId: Int? = nil,
        locationId: Int? = nil,
        product: String? = nil,
        manufacturer: String? = nil,
        transport: String? = nil
    ) {
        self.match = match
        self.vendorId = vendorId
        self.productId = productId
        self.locationId = locationId
        self.product = product
        self.manufacturer = manufacturer
        self.transport = transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = MouseShortcutDeviceSelector(match: stringValue)
            return
        }

        let object = try decoder.container(keyedBy: CodingKeys.self)
        match = try object.decodeIfPresent(String.self, forKey: .match)
        vendorId = try object.decodeIfPresent(Int.self, forKey: .vendorId)
        productId = try object.decodeIfPresent(Int.self, forKey: .productId)
        locationId = try object.decodeIfPresent(Int.self, forKey: .locationId)
        product = try object.decodeIfPresent(String.self, forKey: .product)
        manufacturer = try object.decodeIfPresent(String.self, forKey: .manufacturer)
        transport = try object.decodeIfPresent(String.self, forKey: .transport)
    }

    func encode(to encoder: Encoder) throws {
        if isAny {
            var container = encoder.singleValueContainer()
            try container.encode("any")
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(match, forKey: .match)
        try container.encodeIfPresent(vendorId, forKey: .vendorId)
        try container.encodeIfPresent(productId, forKey: .productId)
        try container.encodeIfPresent(locationId, forKey: .locationId)
        try container.encodeIfPresent(product, forKey: .product)
        try container.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try container.encodeIfPresent(transport, forKey: .transport)
    }

    var isAny: Bool {
        let normalized = (match ?? "any").lowercased()
        return normalized == "any"
            && vendorId == nil
            && productId == nil
            && locationId == nil
            && product == nil
            && manufacturer == nil
            && transport == nil
    }

    func matches(_ device: MouseInputDeviceInfo?) -> Bool {
        if isAny { return true }
        guard let device else { return false }
        if let vendorId, vendorId != device.vendorId { return false }
        if let productId, productId != device.productId { return false }
        if let locationId, locationId != device.locationId { return false }
        if let product, device.product?.localizedCaseInsensitiveContains(product) != true { return false }
        if let manufacturer, device.manufacturer?.localizedCaseInsensitiveContains(manufacturer) != true { return false }
        if let transport, device.transport?.localizedCaseInsensitiveContains(transport) != true { return false }
        return true
    }
}

struct MouseShortcutTrigger: Codable, Equatable {
    var button: MouseShortcutButton
    var kind: MouseShortcutTriggerKind
    var direction: MouseGestureDirection?
    var shape: GestureShapeLabel?

    var triggerName: String {
        let detail: String?
        switch kind {
        case .drag:
            detail = direction?.rawValue
        case .shape:
            detail = shape?.rawValue
        case .click:
            detail = nil
        }
        return ([button.triggerToken, kind.rawValue] + [detail].compactMap { $0 }).joined(separator: ".")
    }

    var displayLabel: String {
        switch kind {
        case .click:
            return "\(button.displayLabel) click"
        case .drag:
            if let direction {
                return "\(button.displayLabel) drag \(direction.displayLabel.lowercased())"
            }
            return "\(button.displayLabel) drag"
        case .shape:
            if let shape {
                return "\(button.displayLabel) \(shape.displayName)"
            }
            return "\(button.displayLabel) shape"
        }
    }
}

struct MouseShortcutKeyStroke: Codable, Equatable {
    var key: String?
    var keyCode: Int?
    var modifiers: [MouseShortcutModifier]

    var displayLabel: String {
        let keyLabel = key?.uppercased() ?? "KeyCode \(keyCode ?? -1)"
        let parts = modifiers.map(\.displayLabel) + [keyLabel]
        return parts.joined(separator: "+")
    }
}

struct MouseShortcutActionDefinition: Codable, Equatable {
    var type: MouseShortcutActionType
    var shortcut: MouseShortcutKeyStroke?
    var app: String?

    init(type: MouseShortcutActionType, shortcut: MouseShortcutKeyStroke? = nil, app: String? = nil) {
        self.type = type
        self.shortcut = shortcut
        self.app = app
    }

    var label: String {
        switch type {
        case .spaceNext:
            return "Next Space"
        case .spacePrevious:
            return "Previous Space"
        case .screenMapToggle:
            return "Screen Map Overview"
        case .dictationStart:
            return "Dictation"
        case .shortcutSend:
            return shortcut?.displayLabel ?? "Send Shortcut"
        case .appActivate:
            return app.map { "Activate \($0)" } ?? "Activate App"
        }
    }
}

struct MouseShortcutVisualDefinition: Codable, Equatable {
    var renderer: String
    var theme: String?
    var asset: String?
    var character: String?
    var markers: [String: String]?
    var events: [String: String]?

    init(
        renderer: String = "native",
        theme: String? = nil,
        asset: String? = nil,
        character: String? = nil,
        markers: [String: String]? = nil,
        events: [String: String]? = nil
    ) {
        self.renderer = renderer
        self.theme = theme
        self.asset = asset
        self.character = character
        self.markers = markers
        self.events = events
    }

    var isLottiePOC: Bool {
        renderer.localizedCaseInsensitiveCompare("lottie") == .orderedSame
    }

    func marker(phase: String, shape: GestureShapeLabel?, success: Bool?) -> String? {
        let keys: [String] = [
            success.map { "\(phase).\($0 ? "success" : "failure")" },
            shape.map { "recognized:\($0.rawValue)" },
            phase,
        ].compactMap { $0 }

        for key in keys {
            if let marker = markers?[key] {
                return marker
            }
            if let marker = events?[key] {
                return marker
            }
        }
        return nil
    }
}

struct MouseShortcutRule: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool
    var device: MouseShortcutDeviceSelector
    var trigger: MouseShortcutTrigger
    var action: MouseShortcutActionDefinition
    var actions: [MouseShortcutActionDefinition]?
    var visual: MouseShortcutVisualDefinition?

    init(
        id: String,
        enabled: Bool,
        device: MouseShortcutDeviceSelector,
        trigger: MouseShortcutTrigger,
        action: MouseShortcutActionDefinition,
        actions: [MouseShortcutActionDefinition]? = nil,
        visual: MouseShortcutVisualDefinition? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.device = device
        self.trigger = trigger
        self.action = action
        self.actions = actions
        self.visual = visual
    }

    var effectiveActions: [MouseShortcutActionDefinition] {
        if let actions, !actions.isEmpty { return actions }
        return [action]
    }

    var summary: String {
        let steps = effectiveActions
        if steps.count > 1 {
            return "\(trigger.triggerName) -> [\(steps.map(\.type.rawValue).joined(separator: " → "))]"
        }
        return "\(trigger.triggerName) -> \(action.type.rawValue)"
    }
}

struct MouseShortcutTuning: Codable, Equatable {
    var dragThreshold: CGFloat
    var holdTolerance: CGFloat
    var axisBias: CGFloat

    static let defaults = MouseShortcutTuning(
        dragThreshold: 68,
        holdTolerance: 10,
        axisBias: 1.2
    )
}

struct MouseShortcutConfig: Codable, Equatable {
    var version: Int
    var tuning: MouseShortcutTuning
    var rules: [MouseShortcutRule]

    static let defaults = MouseShortcutConfig(
        version: 1,
        tuning: .defaults,
        rules: [
            MouseShortcutRule(
                id: "space-previous",
                enabled: true,
                device: .any,
                trigger: MouseShortcutTrigger(button: .middle, kind: .drag, direction: .left, shape: nil),
                action: MouseShortcutActionDefinition(type: .spacePrevious)
            ),
            MouseShortcutRule(
                id: "space-next",
                enabled: true,
                device: .any,
                trigger: MouseShortcutTrigger(button: .middle, kind: .drag, direction: .right, shape: nil),
                action: MouseShortcutActionDefinition(type: .spaceNext)
            ),
            MouseShortcutRule(
                id: "screenmap-overview",
                enabled: true,
                device: .any,
                trigger: MouseShortcutTrigger(button: .middle, kind: .drag, direction: .down, shape: nil),
                action: MouseShortcutActionDefinition(type: .screenMapToggle)
            ),
            MouseShortcutRule(
                id: "dictation",
                enabled: true,
                device: .any,
                trigger: MouseShortcutTrigger(button: .middle, kind: .drag, direction: .up, shape: nil),
                action: MouseShortcutActionDefinition(
                    type: .shortcutSend,
                    shortcut: MouseShortcutKeyStroke(
                        key: "d",
                        keyCode: 2,
                        modifiers: [.control, .option, .shift, .command]
                    )
                )
            ),
            MouseShortcutRule(
                id: "back-circle-screenshot-area",
                enabled: true,
                device: .any,
                trigger: MouseShortcutTrigger(button: .button4, kind: .shape, direction: nil, shape: .circle),
                action: MouseShortcutActionDefinition(
                    type: .shortcutSend,
                    shortcut: MouseShortcutKeyStroke(key: "4", keyCode: 21, modifiers: [.command, .shift])
                ),
                visual: MouseShortcutVisualDefinition(renderer: "matrix", theme: "lattices")
            ),
        ]
    )
}

struct MouseShortcutMatchResult {
    let rule: MouseShortcutRule
    let action: MouseShortcutActionDefinition
    let triggerName: String
}

struct MouseShortcutTriggerEvent {
    let button: MouseShortcutButton
    let kind: MouseShortcutTriggerKind
    let direction: MouseGestureDirection?
    let shape: GestureShapeLabel?
    let device: MouseInputDeviceInfo?

    init(
        button: MouseShortcutButton,
        kind: MouseShortcutTriggerKind,
        direction: MouseGestureDirection? = nil,
        shape: GestureShapeLabel? = nil,
        device: MouseInputDeviceInfo? = nil
    ) {
        self.button = button
        self.kind = kind
        self.direction = direction
        self.shape = shape
        self.device = device
    }

    var triggerName: String {
        MouseShortcutTrigger(button: button, kind: kind, direction: direction, shape: shape).triggerName
    }
}

struct MouseShortcutObservedEvent {
    let timestamp: Date
    let phase: String
    let buttonNumber: Int
    let location: CGPoint
    let delta: CGPoint
    let modifiers: NSEvent.ModifierFlags
    let frontmostAppName: String?
    let frontmostBundleId: String?
    let candidateTrigger: String?
    let device: MouseInputDeviceInfo?
    let matchedRuleSummary: String?
    let willFire: Bool
    let note: String?
}
