import AppKit
import IOKit

struct HIDKeyboardModifierMapping: Codable, Equatable {
    var src: Int64
    var dst: Int64
}

/// A mapping belongs to one HID service, not to the aggregate output of
/// hidutil. In particular, a disconnected keyboard's old service says
/// nothing about the keyboard that has just reconnected.
enum CapsLockHIDMapping {
    static let caps: Int64 = 0x700000039
    static let f18: Int64 = 0x70000006D
    static let transport = HIDKeyboardModifierMapping(src: caps, dst: f18)

    static func enabling(_ current: [HIDKeyboardModifierMapping]) -> [HIDKeyboardModifierMapping]? {
        if current.contains(transport) { return current }
        guard !current.contains(where: { $0.src == caps }) else { return nil }
        return current + [transport]
    }

    static func restoring(_ current: [HIDKeyboardModifierMapping]) -> [HIDKeyboardModifierMapping] {
        current.filter { $0 != transport }
    }

    /// Refuse ambiguous selectors rather than copying one keyboard's settings
    /// onto another. Empty/null mapping is a valid, unmapped service.
    static func parse(_ output: String, registryID: UInt64) -> [HIDKeyboardModifierMapping]? {
        let headers = try! NSRegularExpression(pattern: #"(?m)^([0-9a-fA-F]+)\s+UserKeyMapping\s+"#)
        let matches = headers.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard matches.count == 1, let idRange = Range(matches[0].range(at: 1), in: output),
              UInt64(output[idRange], radix: 16) == registryID else { return nil }
        let payload = String(output[Range(matches[0].range, in: output)!.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "(null)" { return [] }
        guard let data = payload.data(using: .utf8),
              let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return nil }
        var result: [HIDKeyboardModifierMapping] = []
        for row in rows {
            func integer(_ value: Any?) -> Int64? {
                if let value = value as? NSNumber { return value.int64Value }
                if let value = value as? String { return Int64(value) }
                return nil
            }
            guard let src = integer(row["HIDKeyboardModifierMappingSrc"]),
                  let dst = integer(row["HIDKeyboardModifierMappingDst"]) else { return nil }
            result.append(.init(src: src, dst: dst))
        }
        return result
    }
}

final class CapsLockHIDTransportController {
    static let transportKeyCode: Int64 = 79 // F18
    var onActiveChanged: ((Bool) -> Void)?
    private(set) var isActive = false // main queue only
    private var requested = false // main queue only
    private var generation: UInt64 = 0 // main queue only
    private let worker = DispatchQueue(label: "dev.lattices.keyboard-hid", qos: .utility)
    private var enabled = false // remaining state belongs to worker
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var reconcileWork: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private static let ownedKey = "keyboardRemaps.capsLockHIDOwnedServices"
    private var owned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: ownedKey) ?? [])
    private var activeGeneration: UInt64 = 0

    func setEnabled(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requested != value else { return }
        requested = value
        generation &+= 1
        let token = generation
        if value {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.worker.async { [weak self] in self?.reconcile() }
            }
            worker.async { [self] in
                enabled = true
                activeGeneration = token
                startObserving()
                reconcile()
            }
        } else {
            disable()
        }
    }

    func disable() {
        dispatchPrecondition(condition: .onQueue(.main))
        requested = false
        generation &+= 1
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        // Termination must finish restoring our mappings before the process exits.
        worker.sync {
            enabled = false
            reconcileWork?.cancel()
            reconcileWork = nil
            iterators.forEach { IOObjectRelease($0) }
            iterators.removeAll()
            if let port { IONotificationPortDestroy(port) }
            port = nil
            for device in devices() ?? [] where owned.contains(String(device.id)) {
                guard let current = read(device) else { continue }
                let restored = CapsLockHIDMapping.restoring(current)
                if restored == current || (write(restored, device) && read(device) == restored) {
                    owned.remove(String(device.id))
                }
            }
            persistOwnership()
        }
        isActive = false
        onActiveChanged?(false)
    }

    private struct Device {
        let id: UInt64
        let name: String
        let selector: String
    }

    private func keyboardMatching() -> CFMutableDictionary? {
        guard let matching = IOServiceMatching("IOHIDEventService") else { return nil }
        let dictionary = matching as NSMutableDictionary
        dictionary[kIOPropertyMatchKey] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6]
        return matching
    }

    private func devices() -> [Device]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, keyboardMatching(), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("PrimaryUsagePage") as? NSNumber)?.intValue == 1,
                  (property("PrimaryUsage") as? NSNumber)?.intValue == 6 else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
            var match: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6]
            for key in ["VendorID", "ProductID", "LocationID", "Transport", "Product"] {
                if let value = property(key) { match[key] = value }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: match, options: [.sortedKeys]),
                  let selector = String(data: data, encoding: .utf8) else { continue }
            result.append(Device(id: id, name: property("Product") as? String ?? "Keyboard", selector: selector))
        }
        return result
    }

    private func startObserving() {
        guard port == nil, let created = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = created
        IONotificationPortSetDispatchQueue(created, worker)
        for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(created, notification,
                keyboardMatching(), { context, iterator in
                    guard let context else { return }
                    let owner = Unmanaged<CapsLockHIDTransportController>.fromOpaque(context).takeUnretainedValue()
                    while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
                    owner.scheduleReconcile()
                }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
            guard status == KERN_SUCCESS else {
                DiagnosticLog.shared.warn("KeyboardRemap: HID connection observation failed status=\(status)")
                continue
            }
            iterators.append(iterator)
            // Drain to arm future notifications; initial reconciliation follows.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
        }
    }

    private func scheduleReconcile() {
        guard enabled else { return }
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        // Service properties settle after registration. No periodic HID polling
        // and no subprocess or filesystem work on a keyboard event-tap thread.
        worker.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reconcile() {
        guard enabled else { return }
        var active = false
        guard let connected = devices() else {
            DiagnosticLog.shared.warn("KeyboardRemap: could not enumerate keyboard HID services")
            return
        }
        var migrationVerified = true
        let legacyOwned = UserDefaults.standard.bool(forKey: "keyboardRemaps.capsLockHIDTransportOwned")
        for device in connected {
            guard let current = read(device) else {
                migrationVerified = false
                DiagnosticLog.shared.warn("KeyboardRemap: could not verify HID mapping device=\(device.name) service=\(device.id)")
                continue
            }
            guard let next = CapsLockHIDMapping.enabling(current) else {
                DiagnosticLog.shared.warn("KeyboardRemap: preserving existing Caps Lock mapping device=\(device.name)")
                continue
            }
            if next == current {
                active = true
                // Earlier versions owned a single global mapping. Adopt only
                // the exact Caps->F18 pair, never their flattened mapping list.
                if legacyOwned { owned.insert(String(device.id)) }
                continue
            }
            owned.insert(String(device.id))
            persistOwnership()
            let applied = write(next, device) && read(device) == next
            active = active || applied
            DiagnosticLog.shared.info("KeyboardRemap: HID transport device=\(device.name) service=\(device.id) applied=\(applied)")
        }
        owned.formIntersection(Set(connected.map { String($0.id) }))
        persistOwnership()
        // Migrate the old global ownership record only after inspecting the
        // connected keyboards. Disconnected services cannot retain mappings
        // on a new registry identity.
        if legacyOwned && migrationVerified {
            UserDefaults.standard.removeObject(forKey: "keyboardRemaps.capsLockHIDTransportOriginalMappings")
            UserDefaults.standard.removeObject(forKey: "keyboardRemaps.capsLockHIDTransportOwned")
        }
        DiagnosticLog.shared.info("KeyboardRemap: HID transport verified keyboards=\(connected.count) active=\(active)")
        let token = activeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requested, self.generation == token else { return }
            self.isActive = active
            self.onActiveChanged?(active)
        }
    }

    private func persistOwnership() {
        UserDefaults.standard.set(Array(owned).sorted(), forKey: Self.ownedKey)
    }

    private func read(_ device: Device) -> [HIDKeyboardModifierMapping]? {
        let result = run(["property", "--matching", device.selector, "--get", "UserKeyMapping"])
        guard result.status == 0 else { return nil }
        return CapsLockHIDMapping.parse(result.output, registryID: device.id)
    }

    private func write(_ mappings: [HIDKeyboardModifierMapping], _ device: Device) -> Bool {
        let rows = mappings.map { ["HIDKeyboardModifierMappingSrc": $0.src, "HIDKeyboardModifierMappingDst": $0.dst] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": rows]),
              let payload = String(data: data, encoding: .utf8) else { return false }
        return run(["property", "--matching", device.selector, "--set", payload]).status == 0
    }

    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        // Drain before waiting: a large output must not fill the pipe and
        // deadlock the child. This work is confined to the HID utility queue.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
