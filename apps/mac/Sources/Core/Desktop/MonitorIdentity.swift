import AppKit
import IOKit

/// The physical monitor behind a display, read from its EDID strings. One
/// monitor cabled to several hosts reports the same model and serial on each,
/// so `key` names it across the cluster. Product id differs per input and is
/// never part of the key.
struct MonitorIdentity: Equatable {
    let make: String?
    let model: String
    let serial: String
    /// Physical image size from EDID, in millimetres; nil when the panel doesn't report one.
    var widthMm: Int? = nil
    var heightMm: Int? = nil

    var key: String { Self.key(model: model, serial: serial) ?? "" }

    /// lowercase(trim(model)) + "|" + lowercase(trim(serial)); nil when either
    /// is blank (virtual, headless and built-in panels carry no serial).
    static func key(model: String?, serial: String?) -> String? {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let s = (serial ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !m.isEmpty, !s.isEmpty else { return nil }
        return "\(m)|\(s)"
    }

    var json: JSON {
        var obj: [String: JSON] = ["model": .string(model), "serial": .string(serial), "key": .string(key)]
        if let make { obj["make"] = .string(make) }
        if let widthMm, let heightMm { obj["widthMm"] = .int(widthMm); obj["heightMm"] = .int(heightMm) }
        return .object(obj)
    }

    /// The same identity with a physical size in mm; a zero or missing
    /// dimension (projectors, some virtual panels) leaves it unsized.
    func sized(_ mm: CGSize) -> MonitorIdentity {
        var copy = self
        let w = Int(mm.width.rounded()), h = Int(mm.height.rounded())
        guard w > 0, h > 0 else { copy.widthMm = nil; copy.heightMm = nil; return copy }
        copy.widthMm = w; copy.heightMm = h
        return copy
    }

    // MARK: - Registry

    /// One framebuffer's `DisplayAttributes.ProductAttributes`.
    struct Attributes: Equatable {
        let make: String?
        let model: String?
        let serial: String?
        let numericSerial: UInt32?
        let vendor: UInt32?
        let product: UInt32?

        init(make: String?, model: String?, serial: String?, numericSerial: UInt32?, vendor: UInt32?, product: UInt32?) {
            self.make = make; self.model = model; self.serial = serial
            self.numericSerial = numericSerial; self.vendor = vendor; self.product = product
        }

        init?(displayAttributes: Any?) {
            guard let attrs = displayAttributes as? [String: Any],
                  let product = attrs["ProductAttributes"] as? [String: Any] else { return nil }
            func number(_ k: String) -> UInt32? { (product[k] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) } }
            self.init(make: product["ManufacturerID"] as? String, model: product["ProductName"] as? String,
                      serial: product["AlphanumericSerialNumber"] as? String, numericSerial: number("SerialNumber"),
                      vendor: number("LegacyManufacturerID"), product: number("ProductID"))
        }

        var identity: MonitorIdentity? {
            guard Self.nonBlank(model) != nil, Self.nonBlank(serial) != nil, let model, let serial else { return nil }
            return MonitorIdentity(make: Self.nonBlank(make), model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                                   serial: serial.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func nonBlank(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
    }

    /// Framebuffer classes that carry `DisplayAttributes` on Apple Silicon.
    static let framebufferClasses = ["AppleCLCD2", "IOMobileFramebufferShim"]

    /// Pure match: CG's numeric serial and vendor against the registry's
    /// `SerialNumber` and `LegacyManufacturerID`. A display whose EDID numeric
    /// serial is 0 falls back to vendor + product when that pair is unique.
    static func match(vendor: UInt32, model: UInt32, serial: UInt32, among all: [Attributes]) -> Attributes? {
        if serial != 0, let hit = all.first(where: { $0.vendor == vendor && $0.numericSerial == serial }) { return hit }
        let same = all.filter { $0.vendor == vendor && $0.product == model }
        return same.count == 1 ? same[0] : nil
    }

    private static let cacheLock = NSLock()
    private static var cached: (at: Date, attributes: [Attributes])?

    /// Every framebuffer's attributes, cached for a few seconds so encoders
    /// that run per request don't walk the registry each time.
    static func registryAttributes() -> [Attributes] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.attributes }
        var found: [Attributes] = []
        for cls in framebufferClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                let value = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                if let attrs = Attributes(displayAttributes: value) { found.append(attrs) }
            }
        }
        cached = (Date(), found)
        return found
    }

    static func forDisplay(_ id: CGDirectDisplayID) -> MonitorIdentity? {
        guard CGDisplayIsBuiltin(id) == 0 else { return nil }
        return match(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                     serial: CGDisplaySerialNumber(id), among: registryAttributes())?.identity?.sized(CGDisplayScreenSize(id))
    }

    /// A built-in panel's size in millimetres; nil for external and virtual displays.
    static func builtinSize(_ id: CGDirectDisplayID) -> CGSize? {
        guard CGDisplayIsBuiltin(id) != 0 else { return nil }
        return CGDisplayScreenSize(id)
    }

    /// A built-in panel by display UUID, as the API reports it: `{widthMm, heightMm}`, sized when known.
    static func builtinJSON(uuid: String) -> JSON? {
        guard let size = displayID(uuid: uuid).flatMap(builtinSize) else { return nil }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        return .object(w > 0 && h > 0 ? ["widthMm": .int(w), "heightMm": .int(h)] : [:])
    }

    /// By the display UUID string the API reports as `displayId` / screen id.
    static func forDisplay(uuid: String) -> MonitorIdentity? {
        displayID(uuid: uuid).flatMap { forDisplay($0) }
    }

    static func displayID(uuid: String) -> CGDirectDisplayID? {
        let wanted = uuid.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased()
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { id in
            guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let str = CFUUIDCreateString(nil, ref) as String? else { return false }
            return str.lowercased() == wanted
        }
    }

    /// Identities of every attached external monitor.
    static func attached() -> [MonitorIdentity] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { forDisplay($0) }
    }
}
