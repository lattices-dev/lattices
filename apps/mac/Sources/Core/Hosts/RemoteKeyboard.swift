import AppKit

/// Physical positions, not characters: Hyprland's code bindings and held
/// modifiers must see the same keyboard throughout an immersive session.
enum RemoteKeyboard {
    static let evdev: [UInt16: Int] = [
        0:30, 1:31, 2:32, 3:33, 4:35, 5:34, 6:44, 7:45, 8:46, 9:47, 11:48,
        12:16, 13:17, 14:18, 15:19, 16:21, 17:20, 18:2, 19:3, 20:4, 21:5,
        22:7, 23:6, 24:13, 25:10, 26:8, 27:12, 28:9, 29:11, 30:27, 31:24,
        32:22, 33:26, 34:23, 35:25, 36:28, 37:38, 38:36, 39:40, 40:37,
        41:39, 42:43, 43:51, 44:53, 45:49, 46:50, 47:52, 48:15, 49:57,
        50:41, 51:14, 53:1, 54:126, 55:125, 56:42, 57:58, 58:56, 59:29,
        60:54, 61:100, 62:97, 65:83, 67:55, 69:78, 71:69, 75:98, 76:96,
        78:74, 81:117, 82:82, 83:79, 84:80, 85:81, 86:75, 87:76, 88:77,
        89:71, 91:72, 92:73, 96:63, 97:64, 98:65, 99:61, 100:66, 101:67,
        103:87, 109:68, 111:88, 115:102, 116:104, 117:111, 118:62, 119:107,
        120:60, 121:109, 122:59, 123:105, 124:106, 125:108, 126:103,
    ]

    static func isRelease(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == 53 && flags.contains(.maskControl) && flags.contains(.maskAlternate)
    }

    static func isFullScreen(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return keyCode == 3 && flags.intersection(modifiers) == [.maskControl, .maskCommand]
    }

    static func isClose(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return keyCode == 13 && flags.intersection(modifiers) == [.maskCommand]
    }
}

/// Installed only while this viewer has explicit keyboard capture and focus.
/// The main run loop owns the tap, so callbacks never race view/session state.
@MainActor
final class RemoteKeyboardCapture {
    var active: () -> Bool = { false }
    var key: (Int, Bool) -> Void = { _, _ in }
    var release: () -> Void = {}
    var toggleFullScreen: (() -> Void)?
    var closeWindow: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = Set<UInt16>()
    private var ignoredUntilRelease = Set<UInt16>()

    func start() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<RemoteKeyboardCapture>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        prepareForCapture(keysAlreadyDown: Set(RemoteKeyboard.evdev.keys.filter {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; held.removeAll(); ignoredUntilRelease.removeAll()
    }

    /// Local menus and controls pause capture without changing the user's
    /// capture choice. Release remote keys before discarding their state.
    func suspend() {
        for code in held.sorted() {
            if let remote = RemoteKeyboard.evdev[code] { key(remote, false) }
        }
        stop()
    }

    func prepareForCapture(keysAlreadyDown: Set<UInt16>) {
        ignoredUntilRelease = keysAlreadyDown
    }

    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            release()
            return Unmanaged.passUnretained(event)
        }
        guard active() else { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, RemoteKeyboard.isRelease(keyCode: code, flags: event.flags) {
            release()
            return nil
        }
        if type == .keyDown, let closeWindow,
           RemoteKeyboard.isClose(keyCode: code, flags: event.flags) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                suspend()
                closeWindow()
            }
            return nil
        }
        if type == .keyDown, let toggleFullScreen,
           RemoteKeyboard.isFullScreen(keyCode: code, flags: event.flags) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                suspend()
                toggleFullScreen()
            }
            return nil
        }
        // A modifier held while the toolbar was in use has no matching remote
        // down. Its eventual flagsChanged release must not become a new down.
        if ignoredUntilRelease.contains(code) {
            if type == .keyUp || type == .flagsChanged { ignoredUntilRelease.remove(code) }
            return nil
        }
        guard let remote = RemoteKeyboard.evdev[code] else { return Unmanaged.passUnretained(event) }
        if type == .flagsChanged, code == 57 {
            key(remote, true); key(remote, false)
        } else {
            let down = type == .keyDown || (type == .flagsChanged && !held.contains(code))
            // Remote clients/compositors handle key repeat from the held key.
            if down != held.contains(code) {
                if down { held.insert(code) } else { held.remove(code) }
                key(remote, down)
            }
        }
        return nil
    }
}
