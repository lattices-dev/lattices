import AppKit
import DeckKit

/// Visiting a paired host with this Mac's mouse and keyboard (docs/visit.md).
///
/// Armed, a listen-only tap watches mouse moves for a deliberate push past an
/// edge that faces a paired host. Crossing parks the cursor where it is
/// (`CGAssociateMouseAndMouseCursorPosition(0)`), and a session tap swallows
/// mouse and key events and forwards them over the visit channel. Nothing is
/// tapped unless armed.
final class VisitController {
    static let shared = VisitController()

    /// Points of push past the edge that start a visit.
    static let push: Double = 60
    /// A push older than this starts over.
    static let pushWindow: TimeInterval = 0.4
    /// After a visit ends, crossing waits this long.
    static let cooldown: TimeInterval = 0.6
    /// A visit with no `ready` by then ends.
    static let readyWait: TimeInterval = 3

    private static let armedKey = "visit.armed"
    private static let elsewhereKey = "visit.elsewhere"

    /// Posted on main when arming, a visit, or its readiness changes. A visit
    /// that ended carries `ended` (the reason) and `failed` in its userInfo.
    static let changed = Notification.Name("VisitController.changed")

    struct Status {
        var armed: Bool
        var visiting: String?
        var hosts: [VisitTrust.Host]
        /// While visiting: the host has answered `ready`.
        var ready = false
        /// While visiting: where the cursor is parked, in global (top-left) coordinates.
        var parked: CGPoint?
        var side: VisitTrust.Side?
    }

    private struct Visit {
        var host: VisitTrust.Host
        var channel: VisitChannel
        var parked: CGPoint
        var display: CGRect
        var ready = false
    }

    // Main thread.
    private(set) var armed = false
    private var visit: Visit?
    private var edgeTap: CFMachPort?
    private var edgeSource: CFRunLoopSource?
    private var captureTap: CFMachPort?
    private var captureSource: CFRunLoopSource?
    private var screensObserver: NSObjectProtocol?

    // Read on the tap thread, under `lock`.
    private let lock = NSLock()
    private var displays: [CGRect] = []
    /// Displays marked elsewhere: plugged into another machine, so the pointer
    /// is kept off them and sliding into one is a crossing.
    private var away: [CGRect] = []
    private var placements: [(String, CGRect)] = []
    private var pushedTarget: String?
    private var pushed: Double = 0
    private var pushedAt: TimeInterval = 0
    private var quietUntil: TimeInterval = 0
    private var crossing = false
    private var forward: VisitChannel?
    private var holdKey: Int64 = -1

    // MARK: Arming

    /// Arms again on launch if it was armed when the app quit.
    func restore() {
        if UserDefaults.standard.bool(forKey: Self.armedKey) { arm(true) }
    }

    func arm(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        UserDefaults.standard.set(on, forKey: Self.armedKey)
        if !on {
            end(because: "disarmed")
            removeEdgeTap()
            armed = false
            if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
            screensObserver = nil
            DiagnosticLog.shared.info("Visit: off")
            Self.announce()
            return
        }
        guard !armed else { return }
        armed = true
        refreshLayout()
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshLayout() }
        installEdgeTap()
        Self.announce()
        let hosts = VisitTrust.shared.list()
        DiagnosticLog.shared.info("Visit: armed for \(hosts.map { "\($0.name) (\($0.side.rawValue))" }.joined(separator: ", "))")
    }

    func status() -> Status {
        Status(armed: armed, visiting: visit?.host.name, hosts: VisitTrust.shared.list(),
               ready: visit?.ready ?? false, parked: visit?.parked, side: visit?.host.side)
    }

    /// Re-reads displays and paired sides, after pairing or a display change.
    func refreshLayout() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let all = ids.prefix(Int(count)).map { (Self.uuid($0), CGDisplayBounds($0)) }
        let gone = Self.elsewhere
        var rects = all.filter { !gone.contains($0.0) }.map(\.1)
        var awayRects = all.filter { gone.contains($0.0) }.map(\.1)
        if rects.isEmpty { rects = awayRects; awayRects = [] }
        VisitTrust.shared.migratePlacements(displays: rects)
        let labels = UserDefaults.standard.dictionary(forKey: "visit.displayMachines") as? [String: String] ?? [:]
        let paired = VisitTrust.shared.list().compactMap { host -> (String, CGRect)? in
            if let display = all.first(where: { labels[$0.0] == host.name && gone.contains($0.0) }) { return (host.name, display.1) }
            return MachineArrangementStore.rect(for: host).map { (host.name, $0) }
        }
        lock.lock()
        displays = rects
        away = awayRects
        placements = paired
        lock.unlock()
    }

    // MARK: Displays elsewhere

    struct Screen {
        var number: Int
        var name: String
        var frame: CGRect
        var main: Bool
        var elsewhere: Bool
        var displayID: CGDirectDisplayID = 0
        var machine: String? = nil
    }

    /// Main first then left to right, numbered with the shared display inventory.
    static func screens() -> [Screen] {
        let gone = elsewhere
        let ids = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (screen, id)
        }
        let main = CGMainDisplayID()
        let sorted = ids.sorted { a, b in
            if (a.1 == main) != (b.1 == main) { return a.1 == main }
            return CGDisplayBounds(a.1).minX < CGDisplayBounds(b.1).minX
        }
        let inventory = DisplayGather.screens()
        return sorted.enumerated().map { i, pair in
            Screen(number: inventory.first { $0.frame == CGDisplayBounds(pair.1) }?.index ?? i, name: pair.0.localizedName, frame: CGDisplayBounds(pair.1),
                   main: pair.1 == main, elsewhere: gone.contains(uuid(pair.1)), displayID: pair.1,
                   machine: (UserDefaults.standard.dictionary(forKey: "visit.displayMachines") as? [String: String])?[uuid(pair.1)])
        }
    }

    /// Marks display `number` (as `screens()` numbers them) elsewhere, or back here.
    @discardableResult
    func setElsewhere(_ number: Int, _ on: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let screen = Self.screens().first(where: { $0.number == number }),
              let id = Self.displayID(at: screen.frame) else { return false }
        var gone = Self.elsewhere
        if on { gone.insert(Self.uuid(id)) } else { gone.remove(Self.uuid(id)) }
        UserDefaults.standard.set(Array(gone), forKey: Self.elsewhereKey)
        refreshLayout()
        DiagnosticLog.shared.info("Visit: \(screen.name) is \(on ? "elsewhere" : "here")")
        Self.announce()
        return true
    }

    func setDisplayMachine(_ number: Int, name: String?) -> Bool {
        guard let screen = Self.screens().first(where: { $0.number == number }) else { return false }
        var labels = UserDefaults.standard.dictionary(forKey: "visit.displayMachines") as? [String: String] ?? [:]
        labels[Self.uuid(screen.displayID)] = name
        UserDefaults.standard.set(labels, forKey: "visit.displayMachines")
        refreshLayout(); Self.announce()
        return true
    }

    /// Whether `screen` is marked elsewhere.
    static func isElsewhere(_ screen: NSScreen) -> Bool {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return elsewhere.contains(uuid(id))
    }

    private static var elsewhere: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: elsewhereKey) ?? [])
    }

    private static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func displayID(at frame: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayBounds($0) == frame }
    }

    // MARK: Visiting

    /// Explicit visits do not arm edge crossing or change its preference.
    func start(machine name: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard visit == nil else { throw RouterError.custom("End the current visit first") }
        guard let host = VisitTrust.shared.host(named: name) else { throw RouterError.notFound("paired machine \(name)") }
        refreshLayout()
        lock.lock(); let local = displays; let machines = placements; lock.unlock()
        guard let rect = machines.first(where: { $0.0 == host.name })?.1,
              let entry = MachineGeometry.entry(displays: local, machine: rect) else {
            throw RouterError.custom("\(host.name) does not touch a local display")
        }
        // Do not allow an overlapping machine's span to silently redirect this visit.
        guard MachineGeometry.owner(at: entry.point, side: entry.side, display: entry.display, machines: machines)?.0 == host.name else {
            throw RouterError.custom("\(host.name)'s touching span overlaps another machine")
        }
        start(side: entry.side, at: entry.point, explicit: true)
        guard visit != nil else { throw RouterError.custom("Could not start visit to \(host.name); check pairing and Accessibility") }
    }

    /// Starts a visit to the host on its side, the cursor parked at `point`.
    func start(side: VisitTrust.Side, at point: CGPoint, explicit: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        defer { lock.lock(); crossing = false; lock.unlock() }
        guard (armed || explicit), visit == nil else { return }
        lock.lock()
        let rects = displays
        let machines = placements
        lock.unlock()
        guard let display = rects.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return }
        guard let (name, contact) = MachineGeometry.owner(at: point, side: side, display: display, machines: machines),
              var host = VisitTrust.shared.host(named: name) else { return }
        host.side = side
        let channel: VisitChannel
        do {
            channel = try VisitChannel(host: host, crypto: VisitTrust.shared.crypto(for: host))
        } catch {
            DiagnosticLog.shared.warn("Visit: \(host.name): \(error)")
            return
        }
        channel.onMessage = { [weak self] message in DispatchQueue.main.async { self?.received(message, on: channel) } }
        channel.onClose = { [weak self] reason in DispatchQueue.main.async { self?.closed(channel, because: reason) } }

        guard installCaptureTap() else {
            DiagnosticLog.shared.warn("Visit: couldn't tap input")
            return
        }
        if explicit { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(0)
        visit = Visit(host: host, channel: channel, parked: point, display: contact.span(in: display))
        let hold = VisitKeys.fabHoldKey()
        lock.lock(); forward = channel; holdKey = hold; lock.unlock()

        let along = contact.fraction(point)
        channel.open()
        channel.send(["t": "enter", "name": VisitTrust.Host.localName, "edge": side.opposite.rawValue, "at": min(max(along, 0), 1)])
        DiagnosticLog.shared.info("Visit: on \(host.name)")
        Self.announce()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyWait) { [weak self] in
            guard let self, let visit = self.visit, visit.channel === channel, !visit.ready else { return }
            self.end(because: "\(host.name) didn't answer", failed: true)
        }
    }

    /// Ends a visit, if there is one. `at` (0–1) places the cursor along the
    /// edge it left by; otherwise it stays where it was parked.
    func end(because reason: String, at: Double? = nil, failed: Bool = false) {
        let work = { [self] in
            guard let visit else { return }
            self.visit = nil
            lock.lock()
            forward = nil
            quietUntil = ProcessInfo.processInfo.systemUptime + Self.cooldown
            pushed = 0
            lock.unlock()
            removeCaptureTap()
            if let at {
                CGWarpMouseCursorPosition(Self.point(on: visit.host.side, of: visit.display, at: at))
            }
            CGAssociateMouseAndMouseCursorPosition(1)
            visit.channel.close(leaving: true)
            DiagnosticLog.shared.info("Visit: back from \(visit.host.name) (\(reason))")
            Self.announce(["ended": reason, "failed": failed])
        }
        Thread.isMainThread ? work() : DispatchQueue.main.async(execute: work)
    }

    private static func announce(_ info: [String: Any]? = nil) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: info)
    }

    /// A point just inside `display`'s edge on `side`, `at` along it.
    static func point(on side: VisitTrust.Side, of display: CGRect, at: Double) -> CGPoint {
        let at = min(max(at, 0), 1)
        switch side {
        case .right: return CGPoint(x: display.maxX - 3, y: display.minY + at * (display.height - 1))
        case .left: return CGPoint(x: display.minX + 2, y: display.minY + at * (display.height - 1))
        case .top: return CGPoint(x: display.minX + at * (display.width - 1), y: display.minY + 2)
        case .bottom: return CGPoint(x: display.minX + at * (display.width - 1), y: display.maxY - 3)
        }
    }

    private func received(_ message: [String: Any], on channel: VisitChannel) {
        guard let visit, visit.channel === channel else { return }
        switch message["t"] as? String {
        case "ready":
            self.visit?.ready = true
            DiagnosticLog.shared.success("Visit: \(visit.host.name) ready")
            Self.announce()
        case "exit":
            end(because: "left \(visit.host.name)", at: message["at"] as? Double)
        case "error":
            DiagnosticLog.shared.warn("Visit: \(visit.host.name): \(message["message"] as? String ?? "error")")
        default:
            break
        }
    }

    private func closed(_ channel: VisitChannel, because reason: String) {
        guard let visit, visit.channel === channel else { return }
        // A close the host started cleanly isn't a failure; anything else is.
        end(because: reason, failed: !reason.hasPrefix("host closed (1000)"))
    }

    // MARK: Edge tap (armed)

    private func installEdgeTap() {
        guard edgeTap == nil else { return }
        let mask = Self.mask([.mouseMoved])
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: Self.edgeCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DiagnosticLog.shared.warn("Visit: couldn't watch the edge (Accessibility?)")
            return
        }
        edgeTap = tap
        edgeSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let edgeSource { EventTapThread.mouse.add(source: edgeSource) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEdgeTap() {
        if let edgeSource { EventTapThread.mouse.remove(source: edgeSource) }
        if let edgeTap { CFMachPortInvalidate(edgeTap) }
        edgeTap = nil
        edgeSource = nil
    }

    private static let edgeCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<VisitController>.fromOpaque(info).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { if let tap = controller.edgeTap { CGEvent.tapEnable(tap: tap, enable: true) } }
        } else if type == .mouseMoved {
            controller.watchEdge(event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Tap thread. Adds up push against an edge that faces a paired host.
    private func watchEdge(_ event: CGEvent) {
        let p = event.location
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if forward == nil, away.contains(where: { $0.contains(p) }), !displays.contains(where: { $0.contains(p) }) {
            return leaveAway(p, dx: dx, dy: dy, now: now)
        }
        guard !crossing, forward == nil, now >= quietUntil else { return }
        guard let display = displays.first(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else { return }
        let free = { (q: CGPoint) in !self.displays.contains { $0.contains(q) } }
        var side: VisitTrust.Side?
        var into: Double = 0
        if p.x >= display.maxX - 1.5, free(CGPoint(x: display.maxX + 1, y: p.y)) { side = .right; into = dx }
        else if p.x <= display.minX + 0.5, free(CGPoint(x: display.minX - 1, y: p.y)) { side = .left; into = -dx }
        else if p.y >= display.maxY - 1.5, free(CGPoint(x: p.x, y: display.maxY + 1)) { side = .bottom; into = dy }
        else if p.y <= display.minY + 0.5, free(CGPoint(x: p.x, y: display.minY - 1)) { side = .top; into = -dy }
        guard let side, into > 0, let owner = MachineGeometry.owner(at: p, side: side, display: display, machines: placements) else { pushed = 0; pushedTarget = nil; return }
        let target = "\(owner.0):\(side.rawValue)"
        if pushedTarget != target { pushed = 0; pushedTarget = target }
        if now - pushedAt > Self.pushWindow { pushed = 0 }
        pushed += into
        pushedAt = now
        guard pushed >= Self.push else { return }
        pushed = 0
        crossing = true
        DispatchQueue.main.async { self.start(side: side, at: p) }
    }

    /// Tap thread, under `lock`. The pointer slid onto a display that's
    /// elsewhere: put it back just inside the display it came from, and if a
    /// paired host sits that way, that's a crossing.
    private func leaveAway(_ p: CGPoint, dx: Double, dy: Double, now: TimeInterval) {
        let clamp = { (r: CGRect) in CGPoint(x: min(max(p.x, r.minX + 2), r.maxX - 3), y: min(max(p.y, r.minY + 2), r.maxY - 3)) }
        let distance = { (q: CGPoint) in hypot(q.x - p.x, q.y - p.y) }
        guard let display = displays.min(by: { distance(clamp($0)) < distance(clamp($1)) }) else { return }
        let inside = clamp(display)
        let side: VisitTrust.Side = p.x >= display.maxX ? .right : p.x < display.minX ? .left : p.y >= display.maxY ? .bottom : .top
        let into = side == .right ? dx : side == .left ? -dx : side == .bottom ? dy : -dy
        let owner = MachineGeometry.owner(at: inside, side: side, display: display, machines: placements)
        let owns = owner != nil
        let target = owner.map { "\($0.0):\(side.rawValue)" }
        if pushedTarget != target { pushed = 0; pushedTarget = target }
        if now - pushedAt > Self.pushWindow { pushed = 0 }
        if owns && into > 0 { pushed += into; pushedAt = now } else { pushed = 0 }
        let cross = owns && pushed >= Self.push && !crossing && now >= quietUntil
        if cross { crossing = true; pushed = 0 }
        DispatchQueue.main.async {
            CGWarpMouseCursorPosition(inside)
            // Without this a warp freezes the mouse for a quarter second.
            CGAssociateMouseAndMouseCursorPosition(1)
            if cross { self.start(side: side, at: inside) }
        }
    }

    // MARK: Capture tap (visiting)

    private func installCaptureTap() -> Bool {
        let mask = Self.mask([
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ])
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.captureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        captureTap = tap
        captureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let captureSource { EventTapThread.mouse.add(source: captureSource) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeCaptureTap() {
        if let captureSource { EventTapThread.mouse.remove(source: captureSource) }
        if let captureTap { CFMachPortInvalidate(captureTap) }
        captureTap = nil
        captureSource = nil
    }

    private static let captureCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<VisitController>.fromOpaque(info).takeUnretainedValue()
        return controller.capture(type, event)
    }

    /// Tap thread. Forwards and swallows; ⌃⌥⌘ Home ends the visit here, so it
    /// works whatever the channel is doing.
    private func capture(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { if let tap = self.captureTap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let channel = forward
        let hold = holdKey
        lock.unlock()
        guard let channel else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            channel.move(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        case .leftMouseDown, .leftMouseUp:
            channel.send(["t": "button", "button": "left", "down": type == .leftMouseDown])
        case .rightMouseDown, .rightMouseUp:
            channel.send(["t": "button", "button": "right", "down": type == .rightMouseDown])
        case .otherMouseDown, .otherMouseUp:
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                channel.send(["t": "button", "button": "middle", "down": type == .otherMouseDown])
            }
        case .scrollWheel:
            let dy = -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if dx != 0 || dy != 0 { channel.send(["t": "scroll", "dx": dx, "dy": dy]) }
        case .flagsChanged:
            // Fab's dictation key stays on this Mac: hold it to talk to the host.
            if event.getIntegerValueField(.keyboardEventKeycode) == hold { return Unmanaged.passUnretained(event) }
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if VisitKeys.isSummon(keyCode: code, flags: event.flags) {
                DispatchQueue.main.async { self.end(because: "summoned") }
                return nil
            }
            // An app's own ⌘V (Fab delivering a take) pastes this Mac's clipboard there, as text.
            if code == 9, event.flags.contains(.maskCommand), event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
                DispatchQueue.main.async {
                    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { channel.send(["t": "text", "text": text]) }
                }
                return nil
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            let typed = String(utf16CodeUnits: chars, count: length)
            if let message = VisitKeys.message(keyCode: code, flags: event.flags, typed: typed) { channel.send(message) }
        default:
            break
        }
        return nil
    }

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }
}
