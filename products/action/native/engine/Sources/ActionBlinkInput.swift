import ActionCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Blink acts: input borrowed for a few milliseconds and handed straight back.
///
/// A blink click saves the operator's pointer, decouples the physical mouse from it,
/// clicks, warps the pointer back and re-couples. A blink keystroke makes the target
/// frontmost, posts to it, and returns focus to whoever held it. Aimed at the agent
/// layer, the pointer leaves the operator's screens entirely for the length of the
/// click, so there is nothing on their displays to see.
///
/// By default every blink act refuses a target outside an agent-layer display: a blink
/// click on the operator's own screen would be exactly the stolen click this exists to
/// avoid. `--any-display` lifts that for tests.
enum ActionBlinkInput {
    private static func acquireInputLease() throws -> ActionWorkspaceLock {
        try ActionWorkspaceLock(url: ActionLayerSafetyGate.defaultURL.deletingLastPathComponent().appendingPathComponent("native-input.lock"))
    }
    /// A click this short is still one click to every app we've driven; the whole blink,
    /// warp to warp-back, stays under ~25ms.
    static let clickHoldMilliseconds = 8
    /// How long a click may take to activate the app it landed in before we give up waiting.
    static let activationWaitMilliseconds = 250

    // MARK: Click

    static func click(
        at point: CGPoint,
        holdMs: Int,
        accessibilityFirst: Bool,
        anyDisplay: Bool,
        pointerEventLogPath: String?,
        handBack: Bool = true
    ) throws -> String {
        let inputLease = try acquireInputLease()
        defer { withExtendedLifetime(inputLease) {} }
        if !anyDisplay {
            guard ActionAgentLayerDisplay.contains(point) else {
                throw ActionHostError.accessibilityActionFailed(
                    "blink-click refused: \(Int(point.x)),\(Int(point.y)) is not on an agent layer (open one, or pass --any-display)"
                )
            }
        }

        // The pointer is the fallback. A pressable element under the point takes AXPress,
        // which moves nothing and activates nothing.
        if accessibilityFirst, let role = pressElement(at: point) {
            return "\(Int(point.x)),\(Int(point.y)) via=ax role=\(role)"
        }

        let previous = frontmostPID().flatMap(NSRunningApplication.init(processIdentifier:))
        let target = ownerOfWindow(at: point)
        let saved = CGEvent(source: nil)?.location ?? .zero
        // A private source keeps the operator's held modifiers out of the click.
        let source = CGEventSource(stateID: .privateState)

        CGAssociateMouseAndMouseCursorPosition(0)
        let gesture: ActionPointerGesture
        do {
            gesture = try ActionPointerChannel.primaryClick(
                at: point,
                holdMs: max(1, holdMs),
                source: "blink-click",
                eventSource: source,
                log: ActionPointerEventLog.active(explicitPath: pointerEventLogPath)
            )
        } catch {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
            throw error
        }
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)

        // The operator clicking through the viewer keeps the focus the click gave, so
        // their typing follows it; an agent's click hands it straight back.
        let refocused = handBack && handBackFocus(to: previous, after: target)
        var detail = "\(Int(point.x)),\(Int(point.y)) via=pointer pointer=\(Int(saved.x)),\(Int(saved.y))"
        if refocused { detail += " refocused=\(previous?.bundleIdentifier ?? "pid \(previous?.processIdentifier ?? 0)")" }
        if gesture.recorded { detail += " pointerEvent=\(gesture.correlationId)" }
        return detail
    }

    // MARK: Drag and scroll

    /// A drag held entirely on the layer: the pointer leaves the operator's screens for
    /// the length of the gesture (kept short by default) and comes straight back. Unlike a
    /// click it has no accessibility equivalent, and events posted straight to the app
    /// don't reach web content, so the mouse-down activates the app until focus is
    /// handed back.
    static func drag(from start: CGPoint, to end: CGPoint, durationMs: Int, anyDisplay: Bool, pointerEventLogPath: String?, handBack: Bool = true) throws -> String {
        let inputLease = try acquireInputLease()
        defer { withExtendedLifetime(inputLease) {} }
        try requireOnLayer([start, end], command: "blink-drag", anyDisplay: anyDisplay)
        let previous = frontmostPID().flatMap(NSRunningApplication.init(processIdentifier:))
        let target = ownerOfWindow(at: start)
        let saved = try borrowPointer {
            try ActionNativeAutomation.drag(from: start, to: end, durationMs: durationMs, pointerEventLogPath: pointerEventLogPath)
        }
        var detail = "\(Int(start.x)),\(Int(start.y))→\(Int(end.x)),\(Int(end.y)) via=pointer pointer=\(Int(saved.x)),\(Int(saved.y))"
        if handBack, handBackFocus(to: previous, after: target) {
            detail += " refocused=\(previous?.bundleIdentifier ?? "pid \(previous?.processIdentifier ?? 0)")"
        }
        return detail
    }

    /// Scroll wheel events go to the window under the pointer and activate nothing, so a
    /// scroll needs the pointer on the layer only for the instant the events post.
    static func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, durationMs: Int, anyDisplay: Bool) throws -> String {
        let inputLease = try acquireInputLease()
        defer { withExtendedLifetime(inputLease) {} }
        try requireOnLayer([point], command: "blink-scroll", anyDisplay: anyDisplay)
        let saved = try borrowPointer {
            try ActionNativeAutomation.scroll(at: point, deltaX: deltaX, deltaY: deltaY, durationMs: durationMs)
        }
        return "\(Int(point.x)),\(Int(point.y)) dx=\(Int(deltaX)) dy=\(Int(deltaY)) via=pointer pointer=\(Int(saved.x)),\(Int(saved.y))"
    }

    private static func requireOnLayer(_ points: [CGPoint], command: String, anyDisplay: Bool) throws {
        guard !anyDisplay else { return }
        for point in points where !ActionAgentLayerDisplay.contains(point) {
            throw ActionHostError.accessibilityActionFailed(
                "\(command) refused: \(Int(point.x)),\(Int(point.y)) is not on an agent layer (open one, or pass --any-display)"
            )
        }
    }

    /// Decouples the physical mouse, runs `body`, warps the pointer back and re-couples.
    /// Returns where the pointer was.
    private static func borrowPointer(_ body: () throws -> Void) throws -> CGPoint {
        let saved = CGEvent(source: nil)?.location ?? .zero
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        try body()
        return saved
    }

    /// Roles whose AXPress is the click. Containers that also advertise AXPress (groups,
    /// web areas, rows) are left to the pointer: pressing them rarely does what a click
    /// at that spot would.
    private static let pressableRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXMenuItemRole, kAXDisclosureTriangleRole, "AXLink", "AXTab",
    ]

    private static let focusableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Presses the pressable element at `point`, climbing a few parents from the hit
    /// element (a button's label or image is often what the hit test returns). Returns
    /// the pressed role, or nil when nothing there takes AXPress.
    private static func pressElement(at point: CGPoint) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }

        for _ in 0..<4 {
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole || role == kAXApplicationRole { return nil }
            // A click into a text field is a focus change; accessibility can make it
            // directly. Checked by reading focus back, since web views may ignore the write.
            if focusableRoles.contains(role) {
                var settable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
                      settable.boolValue,
                      AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                      boolAttribute(element, kAXFocusedAttribute) == true else { return nil }
                return "\(role) focused"
            }
            if pressableRoles.contains(role) {
                guard boolAttribute(element, kAXEnabledAttribute) != false,
                      actionNames(element).contains(kAXPressAction),
                      AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return nil }
                return role
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: Keys

    static func type(
        _ text: String,
        into app: NSRunningApplication,
        delayMs: Int?,
        accessibilityFirst: Bool,
        anyDisplay: Bool
    ) throws -> String {
        let inputLease = try acquireInputLease()
        defer { withExtendedLifetime(inputLease) {} }
        try requireLayerWindow(app, anyDisplay: anyDisplay)
        // "url\n" is text plus a submit. An accessibility write can't press Return, and a
        // single-line field drops the newline, so insert the text and press Return after.
        var body = text
        var submits = 0
        while body.hasSuffix("\n") {
            body.removeLast()
            submits += 1
        }
        if accessibilityFirst, !body.isEmpty, !body.contains("\n"), let role = insertText(body, into: app) {
            if submits > 0, !confirmFocusedField(of: app, action: kAXConfirmAction) {
                try borrowFocus(of: app, anyDisplay: anyDisplay) {
                    for _ in 0..<submits {
                        try postKeyPressToApp(app: app, key: "return", modifiers: [], holdMicroseconds: 8_000)
                    }
                }
            }
            return "\(targetLabel(for: app)) \(text.count) chars via=ax role=\(role)\(submits > 0 ? " +return" : "")"
        }
        var landed = false
        try borrowFocus(of: app, anyDisplay: anyDisplay) {
            let field = focusedTextElement(of: app)
            let before = field.flatMap { stringAttribute($0, kAXValueAttribute) }
            try postTextToApp(app: app, text: text, delayMs: delayMs)
            // Draining the app's main loop isn't enough when the field lives in another
            // process (a web view): hold focus until the text shows up in the field.
            if let field, let before {
                landed = waitForValue(of: field, toContain: text, changedFrom: before, timeoutMs: 1_000 + 8 * text.count)
            }
        }
        return "\(targetLabel(for: app)) \(text.count) chars via=keys\(landed ? " verified" : "")"
    }

    /// Inserts `text` at the caret of the app's focused text element by replacing its
    /// selected text, which is what typing does, without the app coming forward. Only
    /// counts it when the element's value visibly took the text: some apps accept the
    /// write and ignore it. Secure fields, and elements without a readable value, are
    /// left to keystrokes.
    private static func insertText(_ text: String, into app: NSRunningApplication) -> String? {
        guard let element = focusedTextElement(of: app) else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let before = stringAttribute(element, kAXValueAttribute),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return nil }
        // A web view applies the edit in its content process, a beat later.
        if waitForValue(of: element, toContain: text, changedFrom: before, timeoutMs: 300) {
            return stringAttribute(element, kAXRoleAttribute)
        }
        // The field took the write but reshaped it (trimmed, autocompleted, formatted).
        // Typing it again on top would double it, so a changed value counts as landed.
        guard let after = stringAttribute(element, kAXValueAttribute), after != before else { return nil }
        return stringAttribute(element, kAXRoleAttribute)
    }

    /// The app's focused element when it is a non-secure text element.
    private static func focusedTextElement(of app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        guard focusableRoles.contains(role), subrole != kAXSecureTextFieldSubrole else { return nil }
        return element
    }

    private static func waitForValue(of element: AXUIElement, toContain text: String, changedFrom before: String, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        repeat {
            if let value = stringAttribute(element, kAXValueAttribute), value != before, value.contains(text) {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    static func press(_ key: String, modifiers: [String], into app: NSRunningApplication, anyDisplay: Bool) throws -> String {
        let inputLease = try acquireInputLease()
        defer { withExtendedLifetime(inputLease) {} }
        let combo = modifiers.isEmpty ? key : "\(modifiers.joined(separator: "+"))+\(key)"
        // Most chords are a menu's key equivalent (⌘N, ⌘L, ⌘T). Pressing that item
        // through accessibility runs the same command without bringing the app forward.
        try requireLayerWindow(app, anyDisplay: anyDisplay)
        if let item = pressMenuEquivalent(key, modifiers: modifiers, in: app) {
            return "\(targetLabel(for: app)) \(combo) via=ax menu=\"\(item)\""
        }
        // Return and Escape in a text field are its confirm and cancel actions.
        if modifiers.isEmpty, let action = ["return": kAXConfirmAction, "escape": kAXCancelAction][key],
           confirmFocusedField(of: app, action: action) {
            return "\(targetLabel(for: app)) \(combo) via=ax \(action)"
        }
        try borrowFocus(of: app, anyDisplay: anyDisplay) {
            try postKeyPressToApp(app: app, key: key, modifiers: modifiers, holdMicroseconds: 8_000)
        }
        return "\(targetLabel(for: app)) \(combo) via=keys"
    }

    /// Performs AXConfirm or AXCancel on the app's focused text element, if it offers it.
    private static func confirmFocusedField(of app: NSRunningApplication, action: String) -> Bool {
        // In a text area Return is a newline, not a submit.
        guard let field = focusedTextElement(of: app),
              stringAttribute(field, kAXRoleAttribute) != kAXTextAreaRole,
              actionNames(field).contains(action) else { return false }
        return AXUIElementPerformAction(field, action as CFString) == .success
    }

    /// Finds the enabled menu item whose key equivalent is this chord and presses it.
    /// Only chords with a modifier besides Shift are menu equivalents worth looking for;
    /// a bare key belongs to the focused element.
    private static func pressMenuEquivalent(_ key: String, modifiers: [String], in app: NSRunningApplication) -> String? {
        guard key.count == 1, modifiers.contains(where: { $0 != "shift" }) else { return nil }
        // AXMenuItemCmdModifiers: Shift 1, Option 2, Control 4, and 8 when Command is absent.
        var mask = 0
        if modifiers.contains("shift") { mask |= 1 }
        if modifiers.contains("opt") || modifiers.contains("option") { mask |= 2 }
        if modifiers.contains("ctrl") || modifiers.contains("control") { mask |= 4 }
        if !modifiers.contains("cmd") && !modifiers.contains("command") { mask |= 8 }
        let char = key.uppercased()

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }

        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return (value as? [AXUIElement]) ?? []
        }
        func number(_ element: AXUIElement, _ name: String) -> Int? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return (value as? NSNumber)?.intValue
        }
        func find(in menu: AXUIElement, depth: Int) -> AXUIElement? {
            for item in children(menu) {
                if stringAttribute(item, kAXMenuItemCmdCharAttribute)?.uppercased() == char,
                   (number(item, kAXMenuItemCmdModifiersAttribute) ?? 0) == mask,
                   (number(item, kAXEnabledAttribute) ?? 1) != 0 {
                    return item
                }
                if depth < 2 {
                    for submenu in children(item) {
                        if let found = find(in: submenu, depth: depth + 1) { return found }
                    }
                }
            }
            return nil
        }
        // The app menu (index 0) holds Quit and Hide; never reach for those by chord.
        for barItem in children(bar as! AXUIElement).dropFirst() {
            for menu in children(barItem) {
                if let item = find(in: menu, depth: 0),
                   AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                    return stringAttribute(item, kAXTitleAttribute) ?? char
                }
            }
        }
        return nil
    }

    /// Makes `app` frontmost, runs `body`, waits for the app to take the events, and puts
    /// the previous frontmost app back.
    /// Keys and inserted text land in the app's focused window. When the app also has
    /// windows on the operator's screens (a browser the layer borrowed one window of),
    /// that has to be the layer window: raise it within the app, without activating the
    /// app, and refuse if focus still isn't on the layer.
    private static func requireLayerWindow(_ app: NSRunningApplication, anyDisplay: Bool) throws {
        guard !anyDisplay else { return }
        let layers = ActionAgentLayerDisplay.displays().map(CGDisplayBounds)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        func onLayer(_ window: AXUIElement) -> Bool {
            guard let frame = windowFrame(window) else { return false }
            return layers.contains { $0.intersects(frame) }
        }
        func focusedWindow() -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        if let focused = focusedWindow(), onLayer(focused) { return }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        let all = (windows as? [AXUIElement]) ?? []
        // No windows anywhere: a key such as ⌘N can only reach the app itself, and the
        // window it opens is adopted by the layer.
        if all.isEmpty, !layers.isEmpty { return }
        guard let layerWindow = all.first(where: onLayer) else {
            throw ActionHostError.accessibilityActionFailed(
                "blink refused: \(targetLabel(for: app)) has no window on an agent layer (open one, or pass --any-display)"
            )
        }
        AXUIElementSetAttributeValue(layerWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(layerWindow, kAXRaiseAction as CFString)
        for _ in 0..<20 {
            if let focused = focusedWindow(), onLayer(focused) { return }
            usleep(10_000)
        }
        throw ActionHostError.accessibilityActionFailed(
            "blink refused: \(targetLabel(for: app))'s focused window is off the agent layer and would not move there"
        )
    }

    private static func windowFrame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func borrowFocus(of app: NSRunningApplication, anyDisplay: Bool, _ body: () throws -> Void) throws {
        try requireLayerWindow(app, anyDisplay: anyDisplay)

        let previous = frontmostPID().flatMap(NSRunningApplication.init(processIdentifier:))
        let alreadyFront = previous?.processIdentifier == app.processIdentifier
        if !alreadyFront {
            try ActionNativeAutomation.activateApplication(pid: app.processIdentifier)
            _ = waitForFrontmost(pid: app.processIdentifier, timeoutMs: activationWaitMilliseconds)
        }

        defer {
            if !alreadyFront {
                drain(pid: app.processIdentifier)
                if let previous, previous.processIdentifier != app.processIdentifier {
                    try? ActionNativeAutomation.activateApplication(pid: previous.processIdentifier)
                }
            }
        }
        try body()
    }

    // MARK: Focus

    /// A click on another app's window activates that app asynchronously. Wait for the
    /// switch, then switch back, so the operator's keyboard focus returns to where it was.
    private static func handBackFocus(to previous: NSRunningApplication?, after target: pid_t?) -> Bool {
        guard let previous, let target, target != previous.processIdentifier else { return false }
        guard waitForFrontmost(pid: target, timeoutMs: activationWaitMilliseconds) else { return false }
        return (try? ActionNativeAutomation.activateApplication(pid: previous.processIdentifier)) != nil
    }

    @discardableResult
    private static func waitForFrontmost(pid: pid_t, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while Date() < deadline {
            if frontmostPID() == pid { return true }
            usleep(5_000)
        }
        return frontmostPID() == pid
    }

    /// NSWorkspace only refreshes `frontmostApplication` on the main run loop, which a
    /// busy-wait never turns; the accessibility system-wide element answers live.
    private static func frontmostPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        var pid: pid_t = 0
        AXUIElementGetPid(value as! AXUIElement, &pid)
        return pid
    }

    /// Events posted to a pid queue behind its main run loop. One accessibility round trip
    /// is served by that same loop, so when it returns the app has caught up with the input
    /// ahead of it, and focus can move on without stranding keystrokes.
    private static func drain(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        usleep(10_000)
    }

    private static func ownerOfWindow(at point: CGPoint) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return pid
        }
        return nil
    }
}

/// Recognises agent-layer displays by the vendor/model the layer stamps on them, so a
/// one-shot blink process can check a point without talking to the layer process.
enum ActionAgentLayerDisplay {
    static let vendorID: UInt32 = 0x4163 // "Ac"
    static let productID: UInt32 = 0x4C59 // "LY"
    /// Posted by the host after each blink act, so the layer's viewer can mark the spot.
    static let actNotification = Notification.Name("com.arach.action.agent-layer.act")

    /// How far ahead of a pointer act the viewer's pointer sets off, so it lands as the
    /// act does rather than after it.
    static let aimLeadMilliseconds: UInt32 = 260

    /// Tell a running layer where a pointer act is about to land, and give its pointer a
    /// head start. Costs nothing when no layer is up.
    static func announceAim(at point: CGPoint) {
        guard contains(point) else { return }
        post(["kind": "aim", "x": point.x, "y": point.y])
        usleep(aimLeadMilliseconds * 1_000)
    }

    /// Tell a running layer where an act landed: the point of a click, drag (with where it
    /// started) or scroll (with its wheel delta), or the focused field's frame for typing
    /// and keys. Global top-left coordinates; the layer ignores spots off its display.
    static func announceAct(
        _ kind: String = "click",
        at point: CGPoint? = nil,
        from start: CGPoint? = nil,
        deltaY: Double? = nil,
        focusedIn app: NSRunningApplication? = nil
    ) {
        var info: [String: Any] = [:]
        if let point {
            info = ["kind": kind, "x": point.x, "y": point.y]
            if let start { info["fromX"] = start.x; info["fromY"] = start.y }
            if let deltaY { info["dy"] = deltaY }
        } else if let app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let field = focused, CFGetTypeID(field) == AXUIElementGetTypeID() else { return }
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXUIElementCopyAttributeValue(field as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(field as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let positionRef, let sizeRef,
                  AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return }
            info = ["kind": "field", "fx": origin.x, "fy": origin.y, "fw": size.width, "fh": size.height]
        }
        guard !info.isEmpty else { return }
        post(info)
    }

    private static func post(_ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            actNotification, object: nil, userInfo: info, deliverImmediately: true
        )
    }

    static func isAgentLayer(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(display) == vendorID && CGDisplayModelNumber(display) == productID
    }

    static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter(isAgentLayer)
    }

    static func contains(_ point: CGPoint) -> Bool {
        displays().contains { CGDisplayBounds($0).contains(point) }
    }

    static func hasWindow(pid: pid_t) -> Bool {
        let layers = displays().map(CGDisplayBounds)
        guard !layers.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return info.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return layers.contains { $0.intersects(bounds) }
        }
    }
}
