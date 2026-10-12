import AppKit
import CryptoKit
import SwiftUI

/// One authenticated visitor at a time. The bridge owns trust; this class owns
/// the socket and input lifetime after upgrade, with cleanup on every exit.
final class MacVisitHost {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "visit.host.enabled") }
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "visit.host.enabled")
        if on {
            DispatchQueue.main.async { Preferences.shared.companionBridgeEnabled = true }
        } else { disconnect() }
    }
    static func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if activeFD >= 0 { shutdown(activeFD, SHUT_RDWR) }
    }
    private static let lock = NSLock()
    private static var activeFD: Int32 = -1
    private let fd: Int32
    private let key: SymmetricKey
    private let device: String
    private let nonce: String
    private var up: UInt64 = 0
    private var down: UInt64 = 0
    private var session: VisitHostSession
    private var cursor: NSPanel?
    private var saved: CGPoint?

    static func accept(fd: Int32, headers: [String: String], auth: AuthorizedBridgeRequest, key: SymmetricKey) -> Bool {
        guard enabled, headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13", let token = headers["sec-websocket-key"],
              Data(base64Encoded: token)?.count == 16 else { return false }
        lock.lock()
        guard activeFD == -1 else { lock.unlock(); return false }
        activeFD = fd; lock.unlock()
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let displays = DispatchQueue.main.sync { VisitController.screens().filter { !$0.name.hasPrefix("LATS-") }.map(\.frame) }
        let host = MacVisitHost(fd: fd, key: key, device: auth.device.id, nonce: auth.requestNonce, displays: displays)
        let digest = Insecure.SHA1.hash(data: Data((token + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
        DispatchQueue.global(qos: .userInteractive).async {
            defer {
                host.cleanup()
                lock.lock(); activeFD = -1; lock.unlock()
                close(fd)
            }
            guard host.write(Data(response.utf8)) else { return }
            host.run()
        }
        return true
    }
    private init(fd: Int32, key: SymmetricKey, device: String, nonce: String, displays: [CGRect]) {
        self.fd = fd; self.key = key; self.device = device; self.nonce = nonce
        session = VisitHostSession(displays: displays)
    }
    private func aad(_ direction: String, _ seq: UInt64) -> Data { Data("visit\n\(direction)\n\(device)\n\(nonce)\n\(seq)".utf8) }
    private func run() {
        // Bound each complete frame, not each individual byte: trickling cannot
        // hold input ownership past the heartbeat deadline.
        var lastMessage = Date()
        while Self.enabled && Date().timeIntervalSince(lastMessage) < 6 {
            guard let head = read(2, deadline: lastMessage.addingTimeInterval(6)) else { break }
            let opcode = head[0] & 15
            guard head[0] & 0x80 != 0, head[0] & 0x70 == 0, head[1] & 0x80 != 0 else { closePolicy(); break }
            var length = Int(head[1] & 127)
            if length == 126 {
                guard let n = read(2, deadline: lastMessage.addingTimeInterval(6)) else { break }
                length = Int(n[0]) << 8 | Int(n[1])
            } else if length == 127 { closePolicy(); break }
            guard length <= 32768, let mask = read(4, deadline: lastMessage.addingTimeInterval(6)),
                  let body = read(length, deadline: lastMessage.addingTimeInterval(6)) else { break }
            let payload = Data(body.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            if opcode == 8 { break }
            // Transport pings don't extend the authenticated heartbeat.
            if opcode == 9 && length <= 125 { _ = frame(payload, opcode: 10); continue }
            guard opcode == 2 else { closePolicy(); break }
            do {
                let box = try ChaChaPoly.SealedBox(combined: payload)
                let plain = try ChaChaPoly.open(box, using: key, authenticating: aad("up", up))
                guard let message = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw VisitTrust.Failure.bad("Invalid JSON") }
                up += 1; lastMessage = Date()
                let effects = try session.handle(message)
                for effect in effects {
                    if case .reply(let type, let edge, let at) = effect {
                        var reply: [String: Any] = ["t": type]
                        if let edge { reply["edge"] = edge }; if let at { reply["at"] = at }
                        if type == "ready", let p = session.position { reply["x"] = p.x; reply["y"] = p.y }
                        let data = try JSONSerialization.data(withJSONObject: reply)
                        let sealed = try ChaChaPoly.seal(data, using: key, authenticating: aad("down", down)).combined
                        down += 1
                        guard frame(sealed) else { return }
                    } else { DispatchQueue.main.sync { self.perform(effect) } }
                }
                if effects.contains(.end) { return }
            } catch { closePolicy(); break }
        }
    }
    private func cleanup() {
        let effects = session.finish()
        DispatchQueue.main.sync { for effect in effects { self.perform(effect) } }
    }
    private func closePolicy() { _ = frame(Data([0x03, 0xf0]), opcode: 8) }
    private func read(_ count: Int, deadline: Date) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, Int32(min(remaining * 1000, 6000))) > 0 else { return nil }
            let n = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard n > 0 else { return nil }; offset += n
        }
        return bytes
    }
    private func write(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, 1000) > 0 else { return false }
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard n > 0 else { return false }; offset += n
        }
        return true
    }
    private func frame(_ data: Data, opcode: UInt8 = 2) -> Bool {
        var wire = Data([0x80 | opcode])
        if data.count < 126 { wire.append(UInt8(data.count)) }
        else { wire.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        wire.append(data); return write(wire)
    }
    private func perform(_ effect: VisitHostSession.Effect) {
        switch effect {
        case .show(let name, let p):
            saved = CGEvent(source: nil)?.location
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: VisitorCursor(name: name))
            cursor = panel; moveCursor(p); panel.orderFrontRegardless()
        case .move(let p):
            moveCursor(p)
            for button in session.held { postButton(button, down: true, at: p, drag: true) }
        case .button(let button, let down, let p): postButton(button, down: down, at: p)
        case .scroll(let dx, let dy, let p):
            CGWarpMouseCursorPosition(p)
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
            e?.location = p; e?.post(tap: .cghidEventTap)
        case .key(let key, let mods):
            guard let code = (VisitKeys.special.merging(VisitKeys.plain) { a, _ in a }).first(where: { $0.value == key })?.key else { return }
            var flags: CGEventFlags = []
            for mod in mods { flags.insert(mod == "ctrl" ? .maskControl : mod == "shift" ? .maskShift : mod == "alt" ? .maskAlternate : .maskCommand) }
            for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap) }
        case .text(let text):
            // Unicode keyboard events are limited to small UTF-16 batches.
            for scalar in text.unicodeScalars {
                let units = Array(String(scalar).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                    e?.post(tap: .cghidEventTap)
                }
            }
        case .end:
            cursor?.orderOut(nil); cursor = nil
            if let saved { CGWarpMouseCursorPosition(saved); self.saved = nil }
        case .reply: break
        }
    }
    private func moveCursor(_ p: CGPoint) {
        let top = CGDisplayBounds(CGMainDisplayID()).height
        cursor?.setFrameOrigin(CGPoint(x: p.x - 6, y: top - p.y - 50))
    }
    private func postButton(_ button: String, down: Bool, at p: CGPoint, drag: Bool = false) {
        let b: CGMouseButton = button == "left" ? .left : button == "right" ? .right : .center
        let type: CGEventType = drag ? (b == .left ? .leftMouseDragged : b == .right ? .rightMouseDragged : .otherMouseDragged) :
            b == .left ? (down ? .leftMouseDown : .leftMouseUp) : b == .right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: b)?.post(tap: .cghidEventTap)
    }
}

private struct VisitorCursor: View {
    let name: String
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "location.north.fill").font(.system(size: 20, weight: .bold)).rotationEffect(.degrees(-30))
                .shadow(color: Long.coral.opacity(0.6), radius: 5)
            Text(name).font(Typo.body(11)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Long.coral.opacity(0.18), in: Capsule())
        }.foregroundStyle(Long.coral).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
    }
}
