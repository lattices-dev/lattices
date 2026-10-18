import AppKit
import IOKit.hid

/// Opt-in paired Easy-Switch handoff. Both buttons and modifiers must be
/// released before either HID command can disconnect the devices.
final class LogitechDeviceHandoff {
    static let shared = LogitechDeviceHandoff()
    static let enabledKey = "logitechControlRightDragHandoffEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    private let queue = DispatchQueue(label: "dev.lattices.mouse-handoff")
    private var inFlight = false
    private var cooldown = MouseHandoffCooldown()

    func inspectHardware() {
        queue.async {
            let status: String
            do { status = try LogitechHostConnection.inspect() }
            catch { status = "not ready: \(error.localizedDescription)" }
            DispatchQueue.main.async { DiagnosticLog.shared.info("Device handoff: \(status)") }
        }
    }

    func requestSwitch(direction: MouseHandoffDirection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.isEnabled, !inFlight else { return }
        inFlight = true
        waitForRelease(direction: direction, deadline: ProcessInfo.processInfo.systemUptime + 3)
    }

    private func waitForRelease(direction: MouseHandoffDirection, deadline: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.isEnabled, now < deadline else {
            inFlight = false
            DiagnosticLog.shared.info("Device handoff cancelled: release Control and all mouse buttons within 3 seconds")
            return
        }
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        guard NSEvent.pressedMouseButtons == 0,
              CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                self.waitForRelease(direction: direction, deadline: deadline)
            }
            return
        }
        guard cooldown.reserve(at: now) else { inFlight = false; return }
        DiagnosticLog.shared.info("Device handoff: Control + right drag \(direction.rawValue) released; preflighting keyboard and mouse")
        queue.async {
            let result: String
            do { result = try LogitechHostConnection.switchPair(direction: direction) }
            catch { result = "blocked: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                self.inFlight = false
                DiagnosticLog.shared.info("Device handoff: \(result)")
            }
        }
    }

}

/// Owns a short-lived, non-seizing connection on a worker run loop. No HID I/O
/// waits occur on the app's main thread or an event tap. Feature index is always
/// discovered: 0x0A happened to be this mouse's index, not a protocol constant.
final class LogitechHostConnection {
    enum Device: String {
        case keyboard = "ERGO K860"
        case mouse = "MX Master 3S"

        var productID: Int { self == .mouse ? 0xb034 : 0xb359 }
        var matching: [String: Any] { [
            kIOHIDVendorIDKey: 0x046d, kIOHIDProductIDKey: productID,
            kIOHIDDeviceUsagePageKey: 0xff43, kIOHIDDeviceUsageKey: 0x0202,
            kIOHIDTransportKey: "Bluetooth Low Energy",
        ] }
    }

    struct HostInfo {
        let feature: UInt8
        let count: UInt8
        let current: UInt8 // zero-based
    }

    private var reply: [UInt8]?
    private var expectedFeature: UInt8 = 0
    private var expectedFunction: UInt8 = 0

    static func frame(feature: UInt8, function: UInt8, parameters: [UInt8] = []) -> [UInt8] {
        precondition(parameters.count <= 16)
        return [0x11, 0xff, feature, (function << 4) | 0x0b] + parameters
            + [UInt8](repeating: 0, count: 16 - parameters.count)
    }

    static func matches(_ bytes: [UInt8], feature: UInt8, function: UInt8) -> Bool {
        guard bytes.count >= 7, bytes[0] == 0x10 || bytes[0] == 0x11,
              bytes.count >= (bytes[0] == 0x11 ? 20 : 7),
              bytes[1] == 0xff || bytes[1] == 0 else { return false }
        let header = (function << 4) | 0x0b
        if bytes[2] == 0xff || bytes[2] == 0x8f {
            return bytes[3] == feature && bytes[4] == header
        }
        return bytes[2] == feature && bytes[3] == header
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "LogitechDeviceHandoff", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Both devices must answer before either is switched. There is no atomic
    /// HID transaction across devices; report partial delivery honestly.
    static func switchPair(direction: MouseHandoffDirection) throws -> String {
        try withDevice(.keyboard) { keyboard, keyboardDevice in
            try withDevice(.mouse) { mouse, mouseDevice in
                let keyboardHost = try keyboard.hostInfo(keyboardDevice)
                let mouseHost = try mouse.hostInfo(mouseDevice)
                guard let target = pairedTarget(keyboard: keyboardHost, mouse: mouseHost, direction: direction) else {
                    throw failure("Keyboard and mouse must both have three hosts and be on the same channel; no switches sent")
                }
                try keyboard.write(keyboardDevice, frame: frame(feature: keyboardHost.feature, function: 1, parameters: [target]))
                do {
                    try mouse.write(mouseDevice, frame: frame(feature: mouseHost.feature, function: 1, parameters: [target]))
                } catch {
                    throw failure("Keyboard channel \(target + 1) command accepted; mouse command failed: \(error.localizedDescription). Pair handoff is incomplete")
                }
                return "keyboard then mouse channel \(target + 1) commands accepted by HID; destination connection requires observation"
            }
        }
    }

    static func pairedTarget(keyboard: HostInfo, mouse: HostInfo,
                             direction: MouseHandoffDirection) -> UInt8? {
        guard keyboard.count == 3, mouse.count == 3, keyboard.current < 3,
              keyboard.current == mouse.current else { return nil }
        return direction.target(from: mouse.current)
    }

    /// Read-only preflight also runs in the installed app to expose permission
    /// failures under its own TCC identity without changing either channel.
    static func inspect() throws -> String {
        try withDevice(.keyboard) { keyboard, keyboardDevice in
            let key = try keyboard.hostInfo(keyboardDevice)
            return try withDevice(.mouse) { mouse, mouseDevice in
                let pointer = try mouse.hostInfo(mouseDevice)
                return "ERGO K860: feature \(key.feature), channel \(key.current + 1)/\(key.count); MX Master 3S: feature \(pointer.feature), channel \(pointer.current + 1)/\(pointer.count)"
            }
        }
    }

    private static func withDevice<T>(_ kind: Device, body: (LogitechHostConnection, IOHIDDevice) throws -> T) throws -> T {
        let connection = LogitechHostConnection()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, kind.matching as CFDictionary)
        let opened = IOHIDManagerOpen(manager, 0)
        guard opened == kIOReturnSuccess else { throw failure("HID manager open \(opened)") }
        defer { IOHIDManagerClose(manager, 0) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count == 1, let device = devices.first else {
            throw failure("Expected one Bluetooth \(kind.rawValue); found \(devices.count)")
        }
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else { throw failure("HID device open \(result)") }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0)
            buffer.deallocate()
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, reportID, bytes, count in
            guard result == kIOReturnSuccess, let context, count > 0 else { return }
            let owner = Unmanaged<LogitechHostConnection>.fromOpaque(context).takeUnretainedValue()
            var frame = Array(UnsafeBufferPointer(start: bytes, count: count))
            if frame[0] != UInt8(reportID), reportID == 0x10 || reportID == 0x11 {
                frame.insert(UInt8(reportID), at: 0)
            }
            if LogitechHostConnection.matches(frame, feature: owner.expectedFeature, function: owner.expectedFunction) { owner.reply = frame }
        }, Unmanaged.passUnretained(connection).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return try body(connection, device)
    }

    private func hostInfo(_ device: IOHIDDevice) throws -> HostInfo {
        let discovered = try call(device, feature: 0, function: 0, parameters: [0x18, 0x14])
        let feature = discovered[4]
        guard feature != 0 else { throw Self.failure("ChangeHost 0x1814 is unavailable") }
        let host = try call(device, feature: feature, function: 0)
        return HostInfo(feature: feature, count: host[4], current: host[5])
    }

    private func write(_ device: IOHIDDevice, frame: [UInt8]) throws {
        let result = frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(frame[0]), $0.baseAddress!, frame.count)
        }
        guard result == kIOReturnSuccess else { throw Self.failure("HID write \(result); delivery unverified") }
    }

    private func call(_ device: IOHIDDevice, feature: UInt8, function: UInt8,
                      parameters: [UInt8] = []) throws -> [UInt8] {
        expectedFeature = feature
        expectedFunction = function
        reply = nil
        try write(device, frame: Self.frame(feature: feature, function: function, parameters: parameters))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while reply == nil, ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        guard let reply else { throw Self.failure("HID++ query timed out; no switch sent") }
        guard reply[2] != 0xff, reply[2] != 0x8f else {
            throw Self.failure("HID++ error \(reply[5]); no switch sent")
        }
        return reply
    }
}
