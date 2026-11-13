import ActionCore
import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// The escape belongs to the display owner, not to its disposable viewer. No window
/// is closed, and the display is retained whenever recovery cannot be verified.
@MainActor
final class ActionMonitorReturn: NSObject {
    static let shortcut = "Control-Option-Command-Escape"

    struct Request: Codable, Equatable {
        let requestId: String
        let workspace: String
        let displayId: CGDirectDisplayID
        let displayOwnerPid: pid_t
        let displayStartedAt: String
        let reason: String?
    }

    struct Destination {
        let id: CGDirectDisplayID
        let index: Int
        let space: Int
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct Window: Codable {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let spaces: [Int]
    }

    /// These leases deliberately outlive the last scan and the display disconnect.
    final class Recovery {
        let leases: [ActionWorkspaceLock]
        let windows: [Window]
        let destinations: [CGWindowID: Destination]
        let focusID: CGWindowID?
        init(leases: [ActionWorkspaceLock], windows: [Window], destinations: [CGWindowID: Destination], focusID: CGWindowID?) {
            self.leases = leases; self.windows = windows; self.destinations = destinations; self.focusID = focusID
        }
    }

    private let directory: URL
    private let logger: DebugLogger
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var callback: (() -> Void)?
    private var executable: String?
    private var homeWindowID: CGWindowID?
    private var homePointer = CGPoint.zero
    private let spaces = ActionMonitorSpaceReader()

    init(directory: URL, logger: DebugLogger) { self.directory = directory; self.logger = logger }
    var requestURL: URL { directory.appendingPathComponent("return-to-mac.request") }
    private var statusURL: URL { directory.appendingPathComponent("return-to-mac.status.json") }
    private var ledgerURL: URL { directory.appendingPathComponent("return-to-mac.windows.json") }

    func prepare(onRequest: @escaping () -> Void) async throws {
        guard AXIsProcessTrusted() else { throw failure("Return to Mac requires Accessibility permission before connecting a monitor.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        executable = ["\(home)/.bun/bin/lattices", "/opt/homebrew/bin/lattices", "/usr/local/bin/lattices"].first(where: FileManager.default.isExecutableFile(atPath:))
        guard executable != nil else { throw failure("Lattices is required to recover windows and their desktop membership.") }
        let schema = try await call("api.schema")
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema),
              let text = String(data: schemaData, encoding: .utf8), text.contains("windows.move"), text.contains("spaceId") else {
            throw failure("Lattices does not expose verified window relocation.")
        }
        _ = try spaces.managed()
        let snapshot = try await desktop()
        _ = try destinations(snapshot)
        homeWindowID = (snapshot["frontmost"] as? [String: Any])?["wid"].flatMap { ($0 as? NSNumber)?.uint32Value }
        homePointer = CGEvent(source: nil)?.location ?? .zero
        if FileManager.default.fileExists(atPath: requestURL.path) {
            let prior = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
            guard let status = try JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any],
                  status["state"] as? String == "returned", status["requestId"] as? String == prior.requestId else {
                throw failure("An unresolved Return to Mac recovery remains. Preserve its window records before preparing another monitor.")
            }
            try FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: ledgerURL)
        }
        callback = onRequest
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4152544D, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<ActionMonitorReturn>.fromOpaque(context).takeUnretainedValue().callback?()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { throw failure("Could not install the Return to Mac shortcut handler (\(installed)).") }
        let registered = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x4152544D, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr, hotKey != nil else {
            if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
            throw failure("Control–Option–Command–Escape is unavailable (\(registered)); the monitor was not connected.")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Return to Mac"
        item.button?.toolTip = "Return every window and disconnect this monitor · ⌃⌥⌘Escape"
        let menu = NSMenu()
        let action = NSMenuItem(title: "Return windows and disconnect monitor", action: #selector(returnNow), keyEquivalent: "")
        action.target = self; menu.addItem(action)
        let line = NSMenuItem(title: "Shortcut: ⌃⌥⌘Escape", action: nil, keyEquivalent: "")
        menu.addItem(line); statusLine = line; item.menu = menu; statusItem = item
    }

    @objc private func returnNow() { callback?() }

    func writeRequest(_ request: Request) throws {
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
    }

    func status(_ state: String, request: Request, detail: String, windows: [CGWindowID] = []) {
        let json: [String: Any] = ["requestId": request.requestId, "workspace": request.workspace,
            "displayId": request.displayId, "displayOwnerPid": request.displayOwnerPid,
            "displayStartedAt": request.displayStartedAt, "state": state, "detail": detail,
            "updatedAt": ISO8601DateFormatter().string(from: Date()), "recoveredWindowIds": windows]
        do { try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: statusURL, options: .atomic) }
        catch { logger.log("return-to-mac: could not persist status: \(error.localizedDescription)") }
        statusLine?.title = detail
        statusItem?.button?.title = state == "failed" ? "Return to Mac failed" : "Return to Mac"
        statusItem?.button?.toolTip = "\(detail) · ⌃⌥⌘Escape retries recovery"
        logger.log("return-to-mac: \(state): \(detail)")
    }

    func recover(request: Request, serial: UInt32) async throws -> Recovery {
        try validateDisplay(request, serial: serial)
        let registry = ActionLayerSafetyGate.defaultURL.deletingLastPathComponent()
        // An incoming preview is another workspace's dependency, not ours to kill.
        let preview = try ActionWorkspaceLock(url: directory.appendingPathComponent("display-preview.lock"))
        var session = try readSession(request)
        var candidates = try inventory(display: request.displayId)
        candidates = try mergeLedger(candidates, request: request, session: session)
        try saveLedger(candidates, request: request)
        if session != nil { try Data().write(to: directory.appendingPathComponent("layer.stop"), options: .atomic) }
        let sessionLease = try await waitForLock(directory.appendingPathComponent("display-session.lock"), seconds: 12)
        let inputLease = try await waitForLock(registry.appendingPathComponent("native-input.lock"), seconds: 3)
        let topology = try ActionWorkspaceLock(url: registry.appendingPathComponent("display-topology.lock"))
        try validateDisplay(request, serial: serial)
        // The session may have journaled one last loan before observing the request.
        session = try readSession(request) ?? session
        candidates = try mergeLedger(try inventory(display: request.displayId), request: request, session: session)
        try saveLedger(candidates, request: request)
        let snapshot = try await desktop()
        let physical = try destinations(snapshot)
        let focused = (snapshot["frontmost"] as? [String: Any])?["wid"] as? NSNumber
        let originals = trackedFrames(session)
        var targets: [CGWindowID: Destination] = [:]
        for (index, window) in candidates.enumerated() {
            try validateDisplay(request, serial: serial)
            guard let live = try windowByID(window.id) else { continue } // Closed by its user, never by recovery.
            guard live.pid == window.pid else { throw failure("Window \(window.id) changed owner; recovery stopped.") }
            let original = originals[window.id]
            let destination = original.flatMap { frame in physical.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } }
                ?? physical.first(where: { $0.frame.contains(homePointer) }) ?? physical[0]
            let frame = fitted(original ?? live.frame, to: destination.visibleFrame, cascade: original == nil ? index : nil)
            let area = destination.visibleFrame
            let placement: [String: Any] = ["kind": "fractions", "x": (frame.minX - area.minX) / area.width,
                "y": (frame.minY - area.minY) / area.height, "w": frame.width / area.width, "h": frame.height / area.height]
            let receipt = try await call("windows.move", ["wid": window.id, "display": destination.index,
                "spaceId": destination.space, "placement": placement], timeout: 45)
            guard (receipt as? [String: Any])?["verified"] as? Bool == true else {
                throw failure("Lattices could not verify window \(window.id) on the current physical desktop. The monitor remains connected.")
            }
            targets[window.id] = destination
            try verify(window, destination: destination)
        }
        // A late dialog or manually moved window must not fall through the gap.
        guard try inventory(display: request.displayId).isEmpty else {
            throw failure("Another window remains on the virtual monitor. Press ⌃⌥⌘Escape to retry.")
        }
        for window in candidates { if let destination = targets[window.id] { try verify(window, destination: destination) } }
        let focus = focused.map { CGWindowID($0.uint32Value) }.flatMap { targets[$0] == nil ? nil : $0 } ?? homeWindowID
        return Recovery(leases: [preview, sessionLease, inputLease, topology], windows: candidates, destinations: targets, focusID: focus)
    }

    func verifyBeforeDisconnect(_ recovery: Recovery, request: Request, serial: UInt32) throws {
        try validateDisplay(request, serial: serial)
        guard try inventory(display: request.displayId).isEmpty else { throw failure("A window appeared on the monitor during recovery; retry Return to Mac.") }
        for window in recovery.windows { if let destination = recovery.destinations[window.id] { try verify(window, destination: destination) } }
    }

    func finish(_ recovery: Recovery, request: Request) async throws {
        for _ in 0..<40 where CGDisplayIsOnline(request.displayId) != 0 { try await Task.sleep(for: .milliseconds(50)) }
        guard CGDisplayIsOnline(request.displayId) == 0 else { throw failure("The virtual monitor has not disconnected yet.") }
        for window in recovery.windows { if let destination = recovery.destinations[window.id] { try verify(window, destination: destination) } }
        let physical = physicalBounds()
        guard let frame = physical.first(where: { $0.contains(homePointer) }) ?? physical.first else { throw failure("No physical display is available for the pointer.") }
        let point = CGPoint(x: min(max(homePointer.x, frame.minX + 20), frame.maxX - 20),
                            y: min(max(homePointer.y, frame.minY + 40), frame.maxY - 20))
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        if let id = recovery.focusID, let live = try windowByID(id), physical.contains(where: { $0.contains(CGPoint(x: live.frame.midX, y: live.frame.midY)) }) {
            _ = try? await call("windows.focus", ["wid": id])
        }
        status("returned", request: request, detail: "Windows returned to the Mac; monitor disconnected.", windows: recovery.destinations.keys.sorted())
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("state.json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("layer.stop"))
    }

    private func validateDisplay(_ request: Request, serial: UInt32) throws {
        guard request.displayOwnerPid == getpid(), CGDisplayIsOnline(request.displayId) != 0,
              CGDisplaySerialNumber(request.displayId) == serial else { throw failure("The monitor identity changed; no display was disconnected.") }
    }

    private func readSession(_ request: Request) throws -> [String: Any]? {
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let session = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              session["workspace"] as? String == request.workspace,
              (session["displayId"] as? NSNumber)?.uint32Value == request.displayId,
              (session["displayOwnerPid"] as? NSNumber)?.int32Value == request.displayOwnerPid,
              session["displayStartedAt"] as? String == request.displayStartedAt else {
            throw failure("The task journal does not belong to this monitor; recovery stopped.")
        }
        return session
    }

    private func mergeLedger(_ found: [Window], request: Request, session: [String: Any]?) throws -> [Window] {
        var byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))
            guard ledger.displayStartedAt == request.displayStartedAt, ledger.displayOwnerPid == request.displayOwnerPid else {
                throw failure("A recovery journal belongs to another monitor owner.")
            }
            for row in ledger.windows { byID[row.id] = byID[row.id] ?? row }
        }
        for row in (session?["windows"] as? [[String: Any]]) ?? [] {
            guard let id = (row["windowId"] as? NSNumber)?.uint32Value,
                  let pid = (row["pid"] as? NSNumber)?.int32Value else { throw failure("A borrowed window has no recoverable identity.") }
            if let live = try windowByID(id) {
                guard live.pid == pid else { throw failure("A borrowed window's process identity changed.") }
                byID[id] = byID[id] ?? live
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private struct Ledger: Codable { let displayStartedAt: String; let displayOwnerPid: pid_t; let windows: [Window] }
    private func saveLedger(_ windows: [Window], request: Request) throws {
        try JSONEncoder().encode(Ledger(displayStartedAt: request.displayStartedAt, displayOwnerPid: request.displayOwnerPid, windows: windows))
            .write(to: ledgerURL, options: .atomic)
    }

    private func trackedFrames(_ session: [String: Any]?) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for row in (session?["windows"] as? [[String: Any]]) ?? [] where row["born"] as? Bool != true {
            if let id = (row["windowId"] as? NSNumber)?.uint32Value, let frame = rect(row["original"]) { result[id] = frame }
        }
        return result
    }

    private func inventory(display: CGDirectDisplayID) throws -> [Window] {
        let bounds = CGDisplayBounds(display)
        let managed = try spaces.managed()
        let uuid = displayUUID(display)
        let ownSpaces = Set(managed.first(where: { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame })
            .map { (($0["Spaces"] as? [[String: Any]]) ?? []).compactMap { ($0["id64"] as? NSNumber)?.intValue ?? ($0["ManagedSpaceID"] as? NSNumber)?.intValue } } ?? [])
        let otherSpaces = Set(managed.filter { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuid) != .orderedSame }
            .flatMap { (($0["Spaces"] as? [[String: Any]]) ?? []).compactMap { ($0["id64"] as? NSNumber)?.intValue ?? ($0["ManagedSpaceID"] as? NSNumber)?.intValue } })
        let exclusiveSpaces = ownSpaces.subtracting(otherSpaces)
        var rows: [CGWindowID: Window] = [:]
        guard let cg = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw failure("The window server inventory is unavailable.")
        }
        for row in cg where (row[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != getpid(), let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw), frame.width > 1, frame.height > 1 else { continue }
            rows[id] = Window(id: id, pid: pid, frame: frame, spaces: try spaces.forWindow(id))
        }
        // Minimized and hidden windows can be absent from the CG scene. AX adds
        // their identities and geometry without activating or unhiding apps.
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() && app.activationPolicy == .regular {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
            if code != .success {
                if rows.values.contains(where: { $0.pid == app.processIdentifier && bounds.intersects($0.frame) }) {
                    throw failure("\(app.localizedName ?? "An app") is not responding to recovery inspection.")
                }
                continue
            }
            for element in (value as? [AXUIElement]) ?? [] {
                guard let id = axWindowID(element), let origin = axPoint(copyAttribute(element, kAXPositionAttribute)),
                      let size = axSize(copyAttribute(element, kAXSizeAttribute)), size.width > 1, size.height > 1 else { continue }
                rows[id] = Window(id: id, pid: app.processIdentifier, frame: CGRect(origin: origin, size: size), spaces: try spaces.forWindow(id))
            }
        }
        return rows.values.filter { row in
            // Shared-Spaces mode must never scoop up unrelated physical windows.
            bounds.intersects(row.frame) || (!exclusiveSpaces.isDisjoint(with: row.spaces) && !physicalBounds().contains(where: { $0.intersects(row.frame) }))
        }.sorted { $0.id < $1.id }
    }

    private func windowByID(_ id: CGWindowID) throws -> Window? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { throw failure("Could not inspect window \(id).") }
        guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { return nil }
        guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let raw = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: raw) else {
            throw failure("Window \(id) has unreadable geometry.")
        }
        return Window(id: id, pid: pid, frame: frame, spaces: try spaces.forWindow(id))
    }

    private func verify(_ window: Window, destination: Destination) throws {
        guard let current = try windowByID(window.id) else { return }
        let managed = try spaces.managed()
        let row = managed.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(displayUUID(destination.id)) == .orderedSame }
            ?? (managed.count == 1 ? managed.first : nil)
        let now = row?["Current Space"] as? [String: Any]
        let currentSpace = (now?["id64"] as? NSNumber)?.intValue ?? (now?["ManagedSpaceID"] as? NSNumber)?.intValue
        guard current.pid == window.pid, current.spaces == [destination.space], currentSpace == destination.space,
              destination.frame.contains(CGPoint(x: current.frame.midX, y: current.frame.midY)),
              current.frame.intersection(destination.visibleFrame).width >= min(100, current.frame.width),
              current.frame.intersection(destination.visibleFrame).height >= min(60, current.frame.height) else {
            throw failure("Window \(window.id) is not verified on the current physical desktop.")
        }
    }

    private func destinations(_ snapshot: [String: Any]) throws -> [Destination] {
        let physical = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  !ActionAgentLayerDisplay.isAgentLayer(id) else { return nil }
            return (id, CGDisplayBounds(id))
        }
        var result: [Destination] = []
        for row in (snapshot["displays"] as? [[String: Any]]) ?? [] {
            guard let uuid = row["displayId"] as? String, let index = row["displayIndex"] as? Int,
                  let space = row["currentSpaceId"] as? Int,
                  ((row["spaces"] as? [[String: Any]]) ?? []).contains(where: { ($0["id"] as? Int) == space }),
                  let match = physical.first(where: { displayUUID($0.0).caseInsensitiveCompare(uuid) == .orderedSame }),
                  let visible = rect(row["visibleFrame"]), visible.width > 0, visible.height > 0 else { continue }
            result.append(Destination(id: match.0, index: index, space: space, frame: match.1, visibleFrame: visible))
        }
        guard !result.isEmpty else { throw failure("Select an ordinary desktop on a physical display before using Return to Mac.") }
        return result
    }

    private func physicalBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  !ActionAgentLayerDisplay.isAgentLayer(id) else { return nil }
            return CGDisplayBounds(id)
        }
    }
    private func displayUUID(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func fitted(_ frame: CGRect, to area: CGRect, cascade: Int?) -> CGRect {
        let width = min(max(frame.width, 100), area.width), height = min(max(frame.height, 60), area.height)
        let step = CGFloat((cascade ?? 0) % 8) * 24
        let x = cascade == nil ? frame.minX : area.minX + 24 + step
        let y = cascade == nil ? frame.minY : area.minY + 24 + step
        return CGRect(x: min(max(x, area.minX), area.maxX - width), y: min(max(y, area.minY), area.maxY - height), width: width, height: height)
    }
    private func rect(_ value: Any?) -> CGRect? {
        guard let row = value as? [String: Any], let x = row["x"] as? Double, let y = row["y"] as? Double,
              let w = (row["w"] ?? row["width"]) as? Double, let h = (row["h"] ?? row["height"]) as? Double,
              x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private func waitForLock(_ url: URL, seconds: TimeInterval) async throws -> ActionWorkspaceLock {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let lease = try? ActionWorkspaceLock(url: url) { return lease }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw failure("Recovery is waiting for \(url.lastPathComponent). The monitor remains connected; retry with ⌃⌥⌘Escape.")
    }
    private func desktop() async throws -> [String: Any] {
        guard let value = try await call("desktop.snapshot", ["includeOffscreen": true]) as? [String: Any] else { throw failure("Lattices returned no desktop snapshot.") }
        return value
    }
    private func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 12) async throws -> Any {
        guard let executable else { throw failure("Lattices is unavailable.") }
        let argument = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!
        let data = try await Task.detached(priority: .userInitiated) { try Self.run(executable, method, argument, timeout: timeout) }.value
        return try JSONSerialization.jsonObject(with: data)
    }
    nonisolated private static func run(_ executable: String, _ method: String, _ argument: String, timeout: TimeInterval) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("action-return-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["call", method, argument]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning {
            process.terminate() // Only this helper child; never a task, app, or display owner.
            throw NSError(domain: "ActionMonitorReturn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lattices \(method) timed out; recovery was not confirmed."])
        }
        guard process.terminationStatus == 0 else { throw NSError(domain: "ActionMonitorReturn", code: 2, userInfo: [NSLocalizedDescriptionKey: "Lattices \(method) failed; recovery was not confirmed."]) }
        return try Data(contentsOf: outputURL)
    }
    private func failure(_ detail: String) -> Error { ActionHostError.unsupportedOS(detail) }
}

/// Read-only Space membership, matching the existing Lattices WindowTiler ABI.
@MainActor
private final class ActionMonitorSpaceReader {
    typealias Connection = @convention(c) () -> Int32
    typealias Managed = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let handle, let symbol = dlsym(handle, name) else { throw ActionHostError.unsupportedOS("Space membership inspection is unavailable; the monitor cannot be recovered safely.") }
        return unsafeBitCast(symbol, to: type)
    }
    func managed() throws -> [[String: Any]] {
        let connection = try symbol("CGSMainConnectionID", as: Connection.self)
        let copy = try symbol("CGSCopyManagedDisplaySpaces", as: Managed.self)
        guard let result = copy(connection())?.takeRetainedValue() as? [[String: Any]], !result.isEmpty else { throw ActionHostError.unsupportedOS("Could not read display Spaces.") }
        return result
    }
    func forWindow(_ id: CGWindowID) throws -> [Int] {
        let connection = try symbol("CGSMainConnectionID", as: Connection.self)
        let copy = try symbol("SLSCopySpacesForWindows", as: Membership.self)
        guard let result = copy(connection(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { throw ActionHostError.unsupportedOS("Could not read Space membership for window \(id).") }
        return result.map(\.intValue)
    }
}
