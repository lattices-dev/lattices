// Opt-in installed-app test. Build with swiftc and run on a desktop with input access.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
final class FixtureWindows: NSObject, NSApplicationDelegate {
    let idsFile: URL
    var windows: [NSWindow] = []

    init(idsFile: URL) { self.idsFile = idsFile }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { exit(1) }
        let area = screen.visibleFrame
        for index in 0..<4 {
            let frame = CGRect(x: area.minX + area.width * (0.08 + 0.21 * CGFloat(index)),
                               y: area.minY + area.height * 0.20, width: area.width * 0.17, height: area.height * 0.23)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = ["Replay editor", "Replay terminal A", "Replay terminal B", "Replay terminal C"][index]
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        app.activate(ignoringOtherApps: true)
        do { try JSONEncoder().encode(windows.map(\.windowNumber)).write(to: idsFile, options: .atomic) }
        catch { exit(1) }
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--windows" {
    let fixture = FixtureWindows(idsFile: URL(fileURLWithPath: CommandLine.arguments[2]))
    app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
    exit(0)
}

let originalApp = NSWorkspace.shared.frontmostApplication
let originalMouse = CGEvent(source: nil)!.location
func wait(_ duration: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func find(_ nodes: [AXUIElement], depth: Int, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
    for node in nodes {
        if matches(node) { return node }
        if depth > 0, let children = attr(node, "AXChildren") as? [AXUIElement],
           let found = find(children, depth: depth - 1, matches) { return found }
    }
    return nil
}
guard let lattices = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.lattices.app.dev").first else {
    print("Start the Lattices dev app before running the motion replay")
    exit(1)
}
let ax = AXUIElementCreateApplication(lattices.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 1)
func hud() -> AXUIElement? {
    (attr(ax, "AXWindows") as? [AXUIElement])?.first { attr($0, "AXTitle") as? String == "Hyperspace" }
}
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.postToPid(lattices.processIdentifier)
        wait(0.05)
    }
}
func mouse(_ point: CGPoint) {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
        wait(0.12)
    }
    wait(0.25)
}
struct Failed: Error { let why: String; init(_ why: String) { self.why = why } }
func run() throws {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw Failed("Fixture lacks input access") }
    guard hud() == nil else { throw Failed("Hyperspace is in use") }
    let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }!
    let area = display.visibleFrame
    guard area.width >= 960, area.height >= 560 else { throw Failed("Display too small") }
    let child = Process()
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("hyperspace-replay-" + UUID().uuidString)
    let contents = directory.appendingPathComponent("Replay.app/Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    try files.createDirectory(at: macOS, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let executable = macOS.appendingPathComponent("Replay")
    guard let driver = Bundle.main.executableURL else { throw Failed("Run the compiled replay executable") }
    try files.copyItem(at: driver, to: executable)
    let plist = ["CFBundleExecutable": "Replay", "CFBundleName": "Hyperspace Replay",
                 "CFBundleIdentifier": "local.lattices.qa.motion-replay", "CFBundlePackageType": "APPL",
                 "NSPrincipalClass": "NSApplication"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let idsFile = directory.appendingPathComponent("windows.json")
    child.executableURL = executable
    child.arguments = ["--windows", idsFile.path]
    try child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    for _ in 0..<40 where !FileManager.default.fileExists(atPath: idsFile.path) { wait(0.10) }
    let ids = try JSONDecoder().decode([Int].self, from: Data(contentsOf: idsFile))
    let primaryH = NSScreen.screens[0].frame.height
    func frames() throws -> [CGRect] {
        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        return try ids.map { id in
            guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? Int) == id }),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { throw Failed("Fixture frame unavailable") }
            return CGRect(x: rect.minX, y: primaryH - rect.maxY, width: rect.width, height: rect.height)
        }
    }
    var opened = false
    defer {
        if opened { for _ in 0..<4 where hud() != nil { key(53); wait(0.25) } }
        CGWarpMouseCursorPosition(originalMouse)
        originalApp?.activate(options: [])
    }
    wait(1.2)
    func cg(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: area.minX + x * area.width, y: primaryH - area.maxY + y * area.height)
    }
    CGWarpMouseCursorPosition(cg(0.15, 0.68))
    guard let menu = attr(ax, "AXMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID(),
          let item = find([menu as! AXUIElement], depth: 4, { attr($0, "AXTitle") as? String == "Hyperspace" }),
          AXUIElementPerformAction(item, "AXPress" as CFString) == .success else { throw Failed("Hyperspace menu unavailable") }
    opened = true
    wait(1.3)
    func pickedIDs() throws -> Set<String> {
        guard let h = hud() else { throw Failed("HUD unavailable") }
        var ids = Set<String>()
        _ = find([h], depth: 14) { node in
            if let identifier = attr(node,"AXIdentifier") as? String, identifier.hasPrefix("hud.window."),
               (attr(node,"AXValue") as? String)?.hasPrefix("Selected,") == true { ids.insert(identifier) }
            return false
        }
        return ids
    }
    guard try pickedIDs().isEmpty else { throw Failed("Fixture needs a fresh selection") }
    let initial = try frames()
    for f in initial { mouse(CGPoint(x: f.midX, y: primaryH - f.midY)) }
    let selected = Set(ids.map { "hud.window.\($0)" })
    guard try pickedIDs() == selected else { throw Failed("Could not isolate four fixture windows") }
    func command(_ letters: [CGKeyCode]) {
        key(41, flags: .maskShift)
        for letter in letters { key(letter) }
        key(36)
        wait(0.55)
    }
    func event(_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags, pause: TimeInterval = 0.09) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        wait(pause)
    }
    func gesture(_ from: CGPoint, _ to: CGPoint, _ flags: CGEventFlags = []) {
        let action = flags.contains(.maskShift) ? "Shift-drag" : flags.contains(.maskAlternate) ? "Option-click" : "Drag"
        print("\(action)  (\(Int(from.x)), \(Int(from.y))) → (\(Int(to.x)), \(Int(to.y)))")
        event(.mouseMoved, from, flags)
        event(.leftMouseDown, from, flags)
        if from != to {
            for step in 1...10 {
                let t = CGFloat(step) / 10
                event(.leftMouseDragged, CGPoint(x: from.x + t * (to.x - from.x), y: from.y + t * (to.y - from.y)), flags)
            }
        }
        event(.leftMouseUp, to, flags)
        wait(0.25)
    }
    func check(_ condition: Bool, _ why: String) throws { if !condition { throw Failed(why) } }
    func apply() throws {
        guard try pickedIDs() == selected else { throw Failed("Fixture selection changed before Apply") }
        print("Apply the proposal")
        command([13])
        wait(0.7)
    }
    print("Display", area)
    gesture(cg(0.30, 0.09), cg(0.30, 0.91), .maskShift)
    gesture(cg(0.33, 0.40), cg(0.94, 0.40), .maskShift)
    try check(try frames() == initial, "Drawing moved the live windows before Apply")
    try check(try pickedIDs() == selected, "Drawing changed the selection")
    try apply()
    let cut = try frames()
    print("Two strokes", cut)
    try check(abs(cut[0].height - area.height) < 8 && abs(cut[0].width - area.width * 0.30) < 8, "Vertical cut missing")
    try check(abs(cut[1].height - area.height * 0.40) < 8 && cut[2].minY == cut[3].minY
        && cut[2].maxX <= cut[3].minX && cut[1].minX > cut[0].maxX - 1, "Nested cut missing")
    // Keep the editor in its current frame while changing the other three.
    gesture(cg(0.15, 0.45), cg(0.15, 0.45), .maskAlternate)
    command([5,15,34,2]) // grid
    try apply()
    let anchored = try frames()
    print("Pin and grid", anchored)
    try check(anchored[0] == cut[0] && anchored != cut && anchored.dropFirst().allSatisfy { $0.minX >= cut[0].maxX },
        "Pinned layout failed")
    // Apply clears the pin. A fresh grid exposes a shared four-window divider.
    command([5,15,34,2])
    // The staged grid covers this display. Background windows must not contribute
    // handles inside its four panes.
    func visibleHandles() -> [CGRect] {
        let overlays = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return overlays.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? Int32 == lattices.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == Int(CGShieldingWindowLevel()) + 7,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  (4...11).contains(min(rect.width, rect.height)), (24...82).contains(max(rect.width, rect.height)),
                  area.contains(CGPoint(x: rect.midX, y: primaryH - rect.midY)) else { return nil }
            return rect
        }
    }
    let handles = visibleHandles()
    try check(handles.count == 2
        && handles.contains { $0.width == 4 && abs($0.midX - cg(0.5, 0.5).x) < 2 }
        && handles.contains { $0.height == 4 && abs($0.midY - cg(0.5, 0.5).y) < 2 },
        "Expected just the two visible grid seams, found \(handles)")
    func feedbackVisible() -> Bool {
        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return infos.contains { info in
            guard info[kCGWindowOwnerPID as String] as? Int32 == lattices.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == Int(CGShieldingWindowLevel()) + 7,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict) else { return false }
            return frame.size == display.frame.size && frame.contains(cg(0.50, 0.36))
        }
    }
    func expectFeedback(_ visible: Bool, _ message: String) throws {
        let deadline = Date().addingTimeInterval(1)
        while feedbackVisible() != visible && Date() < deadline { wait(0.03) }
        try check(feedbackVisible() == visible, message)
    }
    event(.mouseMoved, cg(0.45, 0.36), [])
    try check(!feedbackVisible(), "Seam feedback persisted over a tile")
    let seamX = cg(0.50, 0).x
    func nearSeam(_ offset: CGFloat, _ y: CGFloat = 0.36) -> CGPoint {
        CGPoint(x: seamX + offset, y: cg(0, y).y)
    }
    func checkGrip(at point: CGPoint) throws -> CGRect {
        event(.mouseMoved, point, [])
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let grip = visibleHandles().first(where: {
                $0.width < $0.height && abs($0.midX - seamX) < 2 && abs($0.midY - point.y) < 2
            }) { return grip }
            wait(0.025)
        } while Date() < deadline
        throw Failed("No grip near the hand at \(point), found \(visibleHandles())")
    }
    let approaching = try checkGrip(at: nearSeam(-30))
    try expectFeedback(true, "Approaching the seam did not show its feedback")
    let closer = try checkGrip(at: nearSeam(-16, 0.38))
    let hottest = try checkGrip(at: nearSeam(1, 0.39))
    try check(approaching.width < closer.width && closer.width < hottest.width
        && approaching.height < closer.height && closer.height < hottest.height, "The grip did not grow with proximity")
    print("Approaching grip", approaching.size, closer.size, hottest.size)
    let junction = cg(0.50, 0.50)
    func checkAxis(dx: CGFloat, dy: CGFloat, vertical: Bool) throws {
        event(.mouseMoved, CGPoint(x: junction.x + dx, y: junction.y + dy), [])
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if visibleHandles().contains(where: {
                min($0.width, $0.height) > 6 && ($0.width < $0.height) == vertical
            }) { return }
            wait(0.025)
        } while Date() < deadline
        throw Failed("Unexpected resize axis at the grid crossing")
    }
    try checkAxis(dx: 2, dy: -8, vertical: true)
    try checkAxis(dx: 3, dy: -1, vertical: true)
    try checkAxis(dx: 18, dy: -2, vertical: false)
    event(.mouseMoved, nearSeam(48, 0.37), [])
    try expectFeedback(false, "Stopping inside the tile left seam feedback visible")
    // Grab from inside the tile. The resize follows travel from mouse-down.
    gesture(nearSeam(-28), cg(1.0 / 3.0 - 26 / area.width, 0.36))
    try check(try frames() == anchored, "Seam changed live windows before Apply")
    try apply()
    let seam = try frames()
    print("Shared seam", seam)
    try check(abs(seam[0].width - area.width / 3) < 7 && seam[0].width == seam[2].width
        && seam[1].minX == seam[3].minX && seam[1].minX >= seam[0].maxX, "Shared seam missed one-third")
    // The live desktop still has an off-center seam. Stage a balanced grid, then
    // cancel only the drag. Late drag and mouse-up events must leave that grid intact.
    command([5,15,34,2])
    let source = cg(0.75, 0.25)
    let opposite = cg(0.25, 0.75)
    event(.mouseMoved, source, [])
    event(.leftMouseDown, source, [])
    event(.leftMouseDragged, opposite, [])
    key(53)
    event(.leftMouseDragged, cg(0.05, 0.75), [])
    event(.leftMouseUp, cg(0.05, 0.75), [])
    try check(try frames() == seam, "Cancel moved live windows")
    try apply()
    let balanced = try frames()
    try check(balanced[0].minX == balanced[2].minX && balanced[1].minX == balanced[3].minX
        && balanced[0].minY == balanced[1].minY && balanced[2].minY == balanced[3].minY
        && balanced[0].minX < balanced[1].minX && balanced[0].minY > balanced[2].minY
        && abs(balanced[0].width - area.width / 2) < 8 && abs(balanced[0].height - area.height / 2) < 8,
        "Escape did not restore the staged grid with its original occupants")
    print("Escape restored the staged grid; Apply placed its four original occupants")

    // Use the observed target's dimensions. On narrow displays split along the
    // upper edge when that axis can accommodate both windows.
    let target = balanced[2]
    let side = target.width >= 564
    let canShare = side || target.height >= 364
    let boundary = 0.24 * (side ? target.width : target.height)
    func sample(_ offset: CGFloat) -> CGPoint {
        let depth = boundary + offset
        return side ? CGPoint(x: target.minX + depth, y: primaryH - target.midY)
                    : CGPoint(x: target.midX, y: primaryH - target.maxY + depth)
    }
    func dragAcrossBoundary(_ offsets: [CGFloat], startingFrames: [CGRect]) throws {
        command([5,15,34,2])
        event(.mouseMoved, source, [])
        event(.leftMouseDown, source, [])
        var hand = source
        defer { event(.leftMouseUp, hand, []) }
        for offset in offsets {
            hand = sample(offset)
            event(.leftMouseDragged, hand, [])
            try check(try frames() == startingFrames, "Preview changed a live window while the mouse was down")
        }
    }
    var beforeSwap = balanced
    if canShare {
        try dragAcrossBoundary([-24, 5, -3, 8], startingFrames: balanced)
        try check(try frames() == balanced, "Releasing an edge landing moved a live window before Apply")
        try apply()
        beforeSwap = try frames()
        let moved = beforeSwap[1], neighbor = beforeSwap[2]
        let shared = side ? moved.minY == neighbor.minY && moved.maxX <= neighbor.minX
                          : moved.minX == neighbor.minX && moved.minY >= neighbor.maxY
        try check(shared && moved.union(neighbor) == target && moved.width > 0 && moved.height > 0,
                  "A small crossing of the edge boundary lost the shared landing")
        let vacated = balanced[1]
        try check([beforeSwap[0], beforeSwap[3]].contains(where: { $0.contains(vacated) }),
                  "Sharing the target left the old top-right slot unfilled")
        print("The edge landing held through eight points of jitter", beforeSwap)
    } else {
        print("Skipping edge sharing: neither half of the target fits the minimum window size")
    }
    try dragAcrossBoundary([-24, 5, 24, -5], startingFrames: beforeSwap)
    try check(try frames() == beforeSwap, "Releasing a swap moved a live window before Apply")
    try apply()
    let swap = try frames()
    try check(swap == [balanced[0], balanced[2], balanced[1], balanced[3]],
              "The deliberate crossing did not exchange exactly the two diagonal occupants")
    print("Diagonal swap", swap)
    // Move a real foreground window across part of the vertical seam, after
    // Apply has removed the plates. The top pair still has an exposed contact.
    let fixtureAX = AXUIElementCreateApplication(child.processIdentifier)
    guard let windows = attr(fixtureAX, "AXWindows") as? [AXUIElement],
          let cover = windows.first(where: { attr($0, "AXTitle") as? String == "Replay terminal C" })
    else { throw Failed("The foreground fixture window is unavailable") }
    var origin = cg(0.25, 0.18)
    guard let position = AXValueCreate(.cgPoint, &origin),
          AXUIElementSetAttributeValue(cover, kAXPositionAttribute as CFString, position) == .success,
          AXUIElementPerformAction(cover, kAXRaiseAction as CFString) == .success
    else { throw Failed("Could not place the foreground fixture window") }
    func atRequestedPosition(_ frame: CGRect) -> Bool {
        abs(frame.minX - origin.x) < 2 && abs(primaryH - frame.maxY - origin.y) < 2
    }
    var actual = try frames()[3]
    let moveDeadline = Date().addingTimeInterval(2)
    while !atRequestedPosition(actual) && Date() < moveDeadline {
        wait(0.05)
        actual = try frames()[3]
    }
    try check(atRequestedPosition(actual), "Expected the covering window at \(origin), got \(actual) in AppKit coordinates")
    let boundaryX = cg(0.5, 0).x
    let top = cg(0, 0).y
    func hasExposedGrip() -> Bool {
        let bars = visibleHandles().filter { $0.width == 4 && abs($0.midX - boundaryX) < 2 }
        let covered = CGRect(x: actual.minX, y: primaryH - actual.maxY, width: actual.width, height: actual.height)
        return bars.contains { $0.minY >= top && $0.maxY <= covered.minY }
            && !bars.contains { $0.intersects(covered) }
    }
    let deadline = Date().addingTimeInterval(5)
    while !hasExposedGrip() && Date() < deadline { wait(0.1) }
    try check(hasExposedGrip(), "The native divider grip did not follow the exposed edge")
    print("The live grip stayed on the exposed seam above the covering window")
    print("PASS: nested sketch, pin, shared seam, mid-drag Escape, diagonal swap and staged Apply")
}
do { try run() } catch { print(error); exit(1) }
