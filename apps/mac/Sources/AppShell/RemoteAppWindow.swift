import AppKit
import Combine
import SwiftUI

/// A remote app as an ordinary Mac window. The app moves to a headless
/// display on its host, tiled there at this window's size, and the window
/// shows that tile alone. Resizing the window resizes the
/// display; closing it returns the app to where it was. A saved definition
/// (RemoteAppDefinitions) gives the window its name and first size.
@MainActor
final class RemoteAppWindows: NSObject, NSWindowDelegate {
    static let shared = RemoteAppWindows()

    /// Apps such as Spotify ignore a fractional or 2x output scale and draw
    /// at half size, so the headless display stays at 1x.
    private static let scale = 1

    @MainActor private final class Presented {
        let host: String
        let app: String
        /// What the window is called here, e.g. "Spotify".
        let name: String
        let definition: String?
        let wid: Int
        let displayName: String
        let address: String
        let port: UInt16
        /// Replaced when the host drops it: a window can sit idle for hours.
        var control: RemoteHostConnection
        let session: RemoteViewSession
        let presentation = RemoteViewerPresentation()
        var observers: [AnyCancellable] = []
        var resize: DispatchWorkItem?
        var appliedSize: CGSize
        /// What the compositor keeps from the display around a tiled window:
        /// bar reserve and gaps. The display is that much larger than the window.
        let margin: CGSize

        var ledger: RemoteAppLedger.Entry { .init(host: host, wid: wid, display: displayName, pid: ProcessInfo.processInfo.processIdentifier) }

        init(host: String, app: String, name: String, definition: String?, wid: Int, displayName: String, address: String, port: UInt16,
             control: RemoteHostConnection, session: RemoteViewSession, size: CGSize, margin: CGSize) {
            self.host = host; self.app = app; self.name = name; self.definition = definition
            self.wid = wid; self.displayName = displayName
            self.address = address; self.port = port
            self.control = control; self.session = session; self.appliedSize = size; self.margin = margin
        }

        /// One call on the control connection, reconnecting once if it has closed.
        func call(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> Any? {
            do {
                return try await control.call(method, params: params, timeout: timeout)
            } catch RemoteHostConnection.Failure.closed {
                let fresh = RemoteHostConnection(address: address, port: port)
                try await RemoteAppWindows.connect(fresh)
                control.cancel()
                control = fresh
                return try await fresh.call(method, params: params, timeout: timeout)
            }
        }
    }

    enum Failure: LocalizedError {
        case noHost(String), noWindow(String, String), host(String), noDefinition(String)
        var errorDescription: String? {
            switch self {
            case .noDefinition(let id): "No saved remote app named \(id)"
            case .noHost(let host): "No configured host named \(host)"
            case .noWindow(let app, let host): "No \(app) window on \(host)"
            case .host(let message): message
            }
        }
    }

    private var open: [NSWindow: Presented] = [:]
    /// Returns still in flight after their windows closed.
    private var releasing: [Task<Void, Never>] = []

    var hasOpenWindows: Bool { !open.isEmpty }

    /// Mac windows showing a saved definition, by definition id.
    var openDefinitions: [String: NSWindow] {
        Dictionary(open.compactMap { window, presented in presented.definition.map { ($0, window) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Opens a saved definition, or brings its window forward.
    @discardableResult
    func open(definition id: String) async throws -> [String: Any] {
        guard let definition = RemoteAppDefinitions.get(id) else { throw Failure.noDefinition(id) }
        let size = definition.width.flatMap { w in definition.height.map { CGSize(width: w, height: $0) } }
        return try await open(app: definition.app, on: definition.host, name: definition.name, definition: definition.id, size: size)
    }

    /// Opens `app` from `hostName` in its own window, or brings that window forward.
    @discardableResult
    func open(app: String, on hostName: String, name: String? = nil, definition: String? = nil, size requested: CGSize? = nil) async throws -> [String: Any] {
        if let (window, presented) = open.first(where: { $0.value.host == hostName && $0.value.app.caseInsensitiveCompare(app) == .orderedSame }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return ["ok": true, "wid": presented.wid, "display": presented.displayName, "window": window.windowNumber, "reused": true]
        }
        guard let host = RemoteHostsModel.configuredHosts().first(where: { $0.name == hostName }) else { throw Failure.noHost(hostName) }

        let control = RemoteHostConnection(address: host.address, port: host.port)
        try await Self.connect(control)
        do {
            let windows = try await control.call("windows.list") as? [[String: Any]] ?? []
            guard let remote = windows.first(where: { ($0["app"] as? String)?.caseInsensitiveCompare(app) == .orderedSame })
                    ?? windows.first(where: { ($0["app"] as? String)?.localizedCaseInsensitiveContains(app) == true }),
                  let wid = (remote["wid"] as? NSNumber)?.intValue else { throw Failure.noWindow(app, hostName) }
            let appName = remote["app"] as? String ?? app

            let size = Self.clamp(requested ?? CGSize(width: 1180, height: 760))
            let created = try await control.call("displays.create", params: Self.displaySpec(size, margin: .zero), timeout: 15) as? [String: Any]
            guard let displayName = created?["name"] as? String,
                  let display = created?["display"] as? [String: Any],
                  let index = (display["displayIndex"] as? NSNumber ?? display["index"] as? NSNumber)?.intValue else {
                throw Failure.host("\(hostName) did not report the new display")
            }
            let margin: CGSize
            let frame: CGRect
            do {
                _ = try await control.call("windows.move", params: ["wid": wid, "display": index], timeout: 10)
                // Measure what the tile loses to bar and gaps, then grow the
                // display by that so the tile itself is the requested size.
                let (tile, displayFrame) = try await Self.settle(control, wid: wid, display: index)
                margin = CGSize(width: displayFrame.width - tile.width, height: displayFrame.height - tile.height)
                if margin == .zero {
                    frame = tile
                } else {
                    var spec = Self.displaySpec(size, margin: margin)
                    spec["name"] = displayName
                    _ = try await control.call("displays.create", params: spec, timeout: 10)
                    frame = try await Self.settle(control, wid: wid, display: index, size: size).tile
                }
            } catch {
                _ = try? await control.call("windows.moveBack", params: ["wid": wid])
                _ = try? await control.call("displays.remove", params: ["displayId": displayName])
                throw error
            }

            let session = RemoteViewSession(host: host.name, address: host.address, port: host.port,
                                            target: .region(frame))
            session.localShortcuts = true
            let presented = Presented(host: host.name, app: appName, name: name ?? appName, definition: definition,
                                      wid: wid, displayName: displayName,
                                      address: host.address, port: host.port,
                                      control: control, session: session, size: size, margin: margin)
            RemoteAppLedger.add(presented.ledger)
            let window = show(presented, title: remote["title"] as? String, size: size)
            DiagnosticLog.shared.info("RemoteApp: \(appName) on \(hostName) opened on \(displayName) (wid \(wid))")
            return ["ok": true, "wid": wid, "display": displayName, "window": window.windowNumber, "reused": false]
        } catch {
            control.cancel()
            throw error
        }
    }

    private func show(_ presented: Presented, title: String?, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // A fixed "Spotify — archie" is what search, Window menus and Mission
        // Control show; the app's own title (the track) rides underneath.
        window.title = "\(presented.name) — \(presented.host)"
        window.subtitle = title ?? ""
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("RemoteApp.\(presented.host).\(presented.app)")
        presented.presentation.window = window
        window.contentView = NSHostingView(rootView: RemoteViewerView(session: presented.session, presentation: presented.presentation, plain: true))
        window.delegate = self
        open[window] = presented

        let session = presented.session
        // Control is the point of this window; take it as soon as the host offers it.
        presented.observers.append(session.$canControl.sink { [weak session, weak presentation = presented.presentation] can in
            DispatchQueue.main.async {
                guard can, let session, !session.controlling else { return }
                session.controlling = true
                presentation?.requestRemoteInput()
            }
        })
        presented.observers.append(session.$windows.sink { [weak window] windows in
            DispatchQueue.main.async {
                guard let window, let remote = windows.first(where: { Int($0.id) == presented.wid }) else { return }
                window.subtitle = remote.title
            }
        })
        session.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        update(window)
        // A remembered frame may differ from the display just created.
        scheduleResize(window, delay: 0)
        return window
    }

    private func update(_ window: NSWindow) {
        guard let session = open[window]?.session else { return }
        session.engaged = window.isKeyWindow && NSApp.isActive
        session.visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func scheduleResize(_ window: NSWindow, delay: TimeInterval) {
        guard let presented = open[window] else { return }
        presented.resize?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, let presented = self.open[window] else { return }
            let size = Self.clamp(window.contentLayoutRect.size)
            guard size != presented.appliedSize else { return }
            presented.appliedSize = size
            Task {
                var spec = Self.displaySpec(size, margin: presented.margin)
                spec["name"] = presented.displayName
                do {
                    let created = try await presented.call("displays.create", params: spec) as? [String: Any]
                    let display = created?["display"] as? [String: Any]
                    guard let index = (display?["displayIndex"] as? NSNumber)?.intValue else { return }
                    let tile = try await Self.settle(presented.control, wid: presented.wid, display: index, size: size).tile
                    guard presented.appliedSize == size else { return }
                    presented.session.target = .region(tile)
                } catch {
                    DiagnosticLog.shared.warn("RemoteApp: resize \(presented.displayName) failed: \(error.localizedDescription)")
                }
            }
        }
        presented.resize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        scheduleResize(window, delay: window.inLiveResize ? 0.35 : 0.05)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        scheduleResize(window, delay: 0)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        update(window)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        open[window]?.presentation.setFullScreen(true)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        open[window]?.presentation.setFullScreen(false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let presented = open.removeValue(forKey: window) else { return }
        presented.resize?.cancel()
        presented.observers.removeAll()
        presented.presentation.invalidate()
        presented.session.visible = false
        presented.session.stop()
        releasing.append(Task { await release(presented) })
    }

    /// Waits for returns started by closed windows, so a quit doesn't cut them off.
    func settle() async {
        let tasks = releasing
        releasing.removeAll()
        for task in tasks { await task.value }
    }

    /// Returns the app before its display goes, so it lands where it was
    /// rather than wherever the compositor drops orphaned windows.
    private func release(_ presented: Presented) async {
        var done = true
        do { _ = try await presented.call("windows.moveBack", params: ["wid": presented.wid]) }
        catch { DiagnosticLog.shared.warn("RemoteApp: moveBack \(presented.wid) failed: \(error.localizedDescription)") }
        do { _ = try await presented.call("displays.remove", params: ["displayId": presented.displayName]) }
        catch {
            done = false
            DiagnosticLog.shared.warn("RemoteApp: remove \(presented.displayName) failed: \(error.localizedDescription)")
        }
        presented.control.cancel()
        // An unremoved display stays in the ledger for the next launch to finish.
        if done { RemoteAppLedger.remove(presented.ledger) }
        DiagnosticLog.shared.info("RemoteApp: \(presented.app) on \(presented.host) closed")
    }

    /// Closes every remote app window and returns each app to its host, for quit.
    func closeAll() async {
        let windows = Array(open.keys)
        let all = windows.compactMap { open.removeValue(forKey: $0) }
        for presented in all {
            presented.resize?.cancel()
            presented.observers.removeAll()
            presented.session.stop()
        }
        windows.forEach { $0.delegate = nil; $0.close() }
        await withTaskGroup(of: Void.self) { group in
            for presented in all { group.addTask { await self.release(presented) } }
        }
    }

    /// Finishes returns a previous run left behind: a kill or crash skips the close.
    func recoverStranded() async {
        let stranded = RemoteAppLedger.entries()
        guard !stranded.isEmpty else { return }
        let hosts = RemoteHostsModel.configuredHosts()
        let me = ProcessInfo.processInfo.processIdentifier
        // A remote app bundle that is still running holds its own entry.
        for entry in stranded where entry.pid.map({ $0 == me || kill($0, 0) != 0 }) ?? true {
            guard let host = hosts.first(where: { $0.name == entry.host }) else {
                RemoteAppLedger.remove(entry)
                continue
            }
            let control = RemoteHostConnection(address: host.address, port: host.port)
            do { try await Self.connect(control) } catch {
                DiagnosticLog.shared.warn("RemoteApp: \(entry.host) unreachable; \(entry.display) stays for next launch")
                continue
            }
            // Either may already be done; the host answering is what counts.
            _ = try? await control.call("windows.moveBack", params: ["wid": entry.wid], timeout: 10)
            _ = try? await control.call("displays.remove", params: ["displayId": entry.display], timeout: 10)
            control.cancel()
            RemoteAppLedger.remove(entry)
            DiagnosticLog.shared.info("RemoteApp: returned stranded wid \(entry.wid) from \(entry.display) on \(entry.host)")
        }
    }

    // MARK: Helpers

    /// Even sizes keep the encoded picture whole for 4:2:0.
    private static func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: min(3840, max(480, (size.width / 2).rounded() * 2)),
               height: min(2160, max(320, (size.height / 2).rounded() * 2)))
    }

    private static func displaySpec(_ size: CGSize, margin: CGSize) -> [String: Any] {
        ["width": Int(size.width + margin.width) * scale, "height": Int(size.height + margin.height) * scale, "scale": scale]
    }

    /// Waits for the window to tile on `display`, at `size` when given, and
    /// returns its frame with the display's, both in host layout coordinates.
    private static func settle(_ control: RemoteHostConnection, wid: Int, display: Int, size: CGSize? = nil) async throws -> (tile: CGRect, display: CGRect) {
        var last: (tile: CGRect, display: CGRect)?
        for _ in 0..<20 {
            async let windowsCall = control.call("windows.list", timeout: 5)
            async let displaysCall = control.call("spaces.list", timeout: 5)
            let windows = try await windowsCall as? [[String: Any]] ?? []
            let displays = try await displaysCall as? [[String: Any]] ?? []
            if let window = windows.first(where: { ($0["wid"] as? NSNumber)?.intValue == wid }),
               (window["displayIndex"] as? NSNumber)?.intValue == display,
               let tile = rect(window["frame"]),
               let screen = displays.first(where: { ($0["displayIndex"] as? NSNumber)?.intValue == display }),
               let frame = rect(screen["frame"]) {
                let reading = (tile: tile, display: frame)
                let sized = size.map { abs(tile.width - $0.width) <= 2 && abs(tile.height - $0.height) <= 2 } ?? true
                if sized, let last, last == reading { return reading }
                last = reading
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let last else { throw Failure.host("The window did not reach the new display") }
        return last
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let f = value as? [String: Any],
              let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
              let w = (f["w"] as? NSNumber)?.doubleValue, let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    fileprivate static func connect(_ connection: RemoteHostConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.onReady = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            connection.onClose = { reason in
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: Failure.host(reason ?? "Couldn't connect"))
            }
            connection.start()
        }
        connection.onReady = nil
        connection.onClose = nil
    }
}
