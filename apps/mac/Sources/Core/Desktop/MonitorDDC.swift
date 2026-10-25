import Foundation
import IOKit

// Apple Silicon DDC/CI over the DCP's AV service (private IOKit, as MonitorControl's Arm64DDC).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// A monitor's input source (VCP 0x60) over DDC/CI. One read or one write per
/// call, never polled. A monitor that doesn't answer (the M1 Mac mini's own
/// HDMI port passes no DDC) reports `ddc: false` rather than an error.
enum MonitorDDC {
    struct Input: Equatable {
        let code: Int
        let name: String
        init(code: Int) { self.code = code & 0xff; self.name = MonitorDDC.inputName(code) }
        var json: JSON { .object(["code": .int(code), "name": .string(name)]) }
    }

    struct Result: Equatable {
        let key: String
        let ddc: Bool
        let input: Input?
        let inputs: [Input]
        var json: JSON {
            .object(["key": .string(key), "ddc": .bool(ddc), "input": input?.json ?? .null, "inputs": .array(inputs.map(\.json))])
        }
    }

    struct SetResult: Equatable {
        let ok: Bool
        let input: Input?
        var json: JSON { .object(["ok": .bool(ok), "input": input?.json ?? .null]) }
    }

    static let inputSourceVCP: UInt8 = 0x60

    // MARK: - Framing (pure)

    static let chipAddress: UInt8 = 0x37
    static let hostAddress: UInt8 = 0x51

    /// XOR of `seed` and every byte. Requests seed with 0x6E (the display's
    /// write address); replies with 0x50 (the host's virtual address).
    static func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Get VCP Feature: `[0x51, 0x82, 0x01, vcp, checksum]`.
    static func getRequest(vcp: UInt8) -> [UInt8] {
        let body: [UInt8] = [hostAddress, 0x82, 0x01, vcp]
        return body + [checksum(body, seed: 0x6E)]
    }

    /// Set VCP Feature: `[0x51, 0x84, 0x03, vcp, hi, lo, checksum]`.
    static func setRequest(vcp: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [hostAddress, 0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xff)]
        return body + [checksum(body, seed: 0x6E)]
    }

    /// Capabilities Request fragment at `offset`: `[0x51, 0x83, 0xF3, hi, lo, checksum]`.
    static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        let body: [UInt8] = [hostAddress, 0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xff)]
        return body + [checksum(body, seed: 0x6E)]
    }

    /// Get VCP Feature Reply: `[0x6E, 0x88, 0x02, result, vcp, type, maxHi,
    /// maxLo, curHi, curLo, checksum]`. Nil on a bad checksum, an error result
    /// or a reply for another code.
    static func parseReply(_ bytes: [UInt8], vcp: UInt8) -> (current: Int, maximum: Int)? {
        guard bytes.count >= 11, bytes[1] & 0x80 != 0, bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == vcp,
              checksum(Array(bytes[0..<10]), seed: 0x50) == bytes[10] else { return nil }
        return (Int(bytes[8]) << 8 | Int(bytes[9]), Int(bytes[6]) << 8 | Int(bytes[7]))
    }

    /// Capabilities Reply fragment: `[0x6E, 0x80|len, 0xE3, offHi, offLo,
    /// data…, checksum]`. Returns the data bytes; empty marks the end.
    static func parseCapabilitiesFragment(_ bytes: [UInt8], offset: UInt16) -> [UInt8]? {
        guard bytes.count >= 6, bytes[1] & 0x80 != 0, bytes[2] == 0xE3 else { return nil }
        let length = Int(bytes[1] & 0x7f)
        guard length >= 3, bytes.count >= length + 3,
              UInt16(bytes[3]) << 8 | UInt16(bytes[4]) == offset,
              checksum(Array(bytes[0..<(length + 2)]), seed: 0x50) == bytes[length + 2] else { return nil }
        return Array(bytes[5..<(length + 2)])
    }

    /// MCCS names for the common input codes; read values are masked to a byte.
    static func inputName(_ code: Int) -> String {
        switch code & 0xff {
        case 0x01: return "VGA-1"
        case 0x03: return "DVI-1"
        case 0x0f: return "DP-1"
        case 0x10: return "DP-2"
        case 0x11: return "HDMI-1"
        case 0x12: return "HDMI-2"
        case 0x1b: return "USB-C"
        default: return String(format: "Input 0x%02x", code & 0xff)
        }
    }

    /// The input codes listed for VCP 0x60 in a capabilities string such as
    /// `(prot(monitor)…vcp(02 04 10 14(05 08) 60(0F 11 12) D6(01 04))…)`.
    static func capabilityInputs(_ caps: String) -> [Int] {
        guard let start = caps.range(of: "vcp(", options: .caseInsensitive) else { return [] }
        var depth = 1, last: String?, inInputs = false, codes: [Int] = []
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            // Some monitors run codes together ("020410"): split into pairs.
            var pairs: [String] = []
            var chars = Array(token)
            if chars.count % 2 == 1 { chars.insert("0", at: 0) }
            stride(from: 0, to: chars.count, by: 2).forEach { pairs.append(String(chars[$0...$0 + 1])) }
            if inInputs { codes += pairs.compactMap { Int($0, radix: 16) } }
            last = pairs.last
            token = ""
        }
        for ch in caps[start.upperBound...] {
            if ch.isHexDigit { token.append(ch); continue }
            flush()
            if ch == "(" {
                depth += 1
                if depth == 2, last?.uppercased() == "60" { inInputs = true }
            } else if ch == ")" {
                if depth == 2 { inInputs = false }
                depth -= 1
                if depth == 0 { break }
            } else if !ch.isWhitespace {
                last = nil
            }
        }
        return codes
    }

    // MARK: - API

    private static let queue = DispatchQueue(label: "lattices.monitor-ddc", qos: .userInitiated)
    private static let capsLock = NSLock()
    private static var capabilitiesCache: [String: [Input]] = [:]
    /// When a capabilities read last failed per key. A monitor that answers
    /// VCP 0x60 but not capabilities would otherwise cost seconds on every get.
    private static var capabilitiesFailedAt: [String: Date] = [:]
    static let capabilitiesRetryInterval: TimeInterval = 300

    static func input(key: String) async -> Result {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: readInput(key: key)) } }
    }

    /// Writes VCP 0x60. Only from an explicit user action, never automatically.
    static func setInput(key: String, code: Int) async -> SetResult {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: writeInput(key: key, code: code)) } }
    }

    /// For synchronous daemon handlers: runs on the DDC queue and waits.
    static func blocking<T>(_ work: @escaping () -> T) -> T {
        var value: T?
        let done = DispatchSemaphore(value: 0)
        queue.async { value = work(); done.signal() }
        done.wait()
        return value!
    }

    static func readInput(key: String) -> Result {
        let wanted = key.lowercased()
        guard let service = services()[wanted],
              let reply = transact(service, request: getRequest(vcp: inputSourceVCP), replyLength: 11, parse: { parseReply($0, vcp: inputSourceVCP) })
        else { return Result(key: key, ddc: false, input: nil, inputs: []) }
        return Result(key: key, ddc: true, input: Input(code: reply.current), inputs: inputs(for: wanted, service: service))
    }

    static func writeInput(key: String, code: Int) -> SetResult {
        guard (0...0xff).contains(code), let service = services()[key.lowercased()] else { return SetResult(ok: false, input: nil) }
        var frame = setRequest(vcp: inputSourceVCP, value: UInt16(code))
        let ok = write(service, &frame)
        return SetResult(ok: ok, input: ok ? Input(code: code) : nil)
    }

    // MARK: - I2C

    private static func write(_ service: CFTypeRef, _ frame: inout [UInt8]) -> Bool {
        // The first byte (0x51) is the I2C data address; the rest is the payload.
        var payload = Array(frame.dropFirst())
        return IOAVServiceWriteI2C(service, UInt32(chipAddress), UInt32(frame[0]), &payload, UInt32(payload.count)) == kIOReturnSuccess
    }

    private static func transact<T>(_ service: CFTypeRef, request: [UInt8], replyLength: Int, parse: ([UInt8]) -> T?) -> T? {
        var frame = request
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            guard write(service, &frame) else { continue }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: replyLength)
            guard IOAVServiceReadI2C(service, UInt32(chipAddress), UInt32(hostAddress), &reply, UInt32(replyLength)) == kIOReturnSuccess else { continue }
            if let value = parse(reply) { return value }
        }
        return nil
    }

    /// The monitor's advertised inputs, read once per key and cached: the
    /// capabilities string never changes and takes many fragments to read.
    private static func inputs(for key: String, service: CFTypeRef) -> [Input] {
        capsLock.lock()
        if let hit = capabilitiesCache[key] { capsLock.unlock(); return hit }
        if let failed = capabilitiesFailedAt[key], Date().timeIntervalSince(failed) < capabilitiesRetryInterval { capsLock.unlock(); return [] }
        capsLock.unlock()
        var data: [UInt8] = []
        var offset: UInt16 = 0
        while data.count < 2048 {
            guard let fragment = transact(service, request: capabilitiesRequest(offset: offset), replyLength: 38,
                                          parse: { parseCapabilitiesFragment($0, offset: offset) }) else {
                capsLock.lock(); capabilitiesFailedAt[key] = Date(); capsLock.unlock()
                return []
            }
            if fragment.isEmpty { break }
            data += fragment
            offset += UInt16(fragment.count)
        }
        let caps = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        let found = capabilityInputs(caps).map { Input(code: $0) }
        capsLock.lock(); capabilitiesCache[key] = found; capsLock.unlock()
        return found
    }

    /// One IOService-plane entry, as far as pairing cares.
    enum RegistryEntry: Equatable {
        /// A framebuffer; nil identity for panels without model + serial.
        case framebuffer(MonitorIdentity?)
        /// A `DCPAVServiceProxy`; `external` when its Location is External.
        case avService(external: Bool)
    }

    /// Pure pairing: each external AV service proxy belongs to the framebuffer
    /// seen most recently before it (MonitorControl's Arm64DDC order). Returns
    /// monitor key → index of the proxy entry. Every framebuffer resets the
    /// pending identity, so a proxy after an unidentified panel is skipped.
    static func pair(_ entries: [RegistryEntry]) -> [String: Int] {
        var found: [String: Int] = [:]
        var pending: MonitorIdentity?
        for (i, entry) in entries.enumerated() {
            switch entry {
            case .framebuffer(let identity): pending = identity
            case .avService(let external):
                guard external, let identity = pending else { continue }
                found[identity.key] = i
                pending = nil
            }
        }
        return found
    }

    /// External `DCPAVServiceProxy` services keyed by monitor key.
    private static func services() -> [String: CFTypeRef] {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var entries: [RegistryEntry] = []
        var proxies: [Int: io_object_t] = [:]
        defer { proxies.values.forEach { IOObjectRelease($0) } }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var name = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { IOObjectRelease(entry); continue }
            let cls = String(cString: name)
            if MonitorIdentity.framebufferClasses.contains(cls) {
                let value = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                entries.append(.framebuffer(MonitorIdentity.Attributes(displayAttributes: value)?.identity))
                IOObjectRelease(entry)
            } else if cls == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                entries.append(.avService(external: location == "External"))
                proxies[entries.count - 1] = entry
            } else {
                IOObjectRelease(entry)
            }
        }
        var found: [String: CFTypeRef] = [:]
        for (key, index) in pair(entries) {
            if let proxy = proxies[index], let service = IOAVServiceCreateWithService(kCFAllocatorDefault, proxy)?.takeRetainedValue() {
                found[key] = service
            }
        }
        return found
    }

    // MARK: - Endpoints

    static func registerEndpoints(_ api: LatticesApi) {
        let key = Param(name: "key", type: "string", required: true, description: "Monitor key (model|serial) from a display's 'monitor'")
        api.register(Endpoint(
            method: "display.input.get",
            description: "A monitor's current input source over DDC/CI (VCP 0x60); ddc is false when the monitor doesn't answer",
            access: .read,
            params: [key],
            returns: .custom("Object with 'key', 'ddc', 'input' ({code, name} or null) and 'inputs'"),
            handler: { params in
                guard let k = params?["key"]?.stringValue, !k.isEmpty else { throw RouterError.missingParam("key") }
                return blocking { readInput(key: k) }.json
            }
        ))
        api.register(Endpoint(
            method: "display.input.set",
            description: "Switch a monitor's input source over DDC/CI (writes VCP 0x60). Only on an explicit user action",
            access: .mutate,
            params: [key, Param(name: "code", type: "int", required: true, description: "MCCS input code, e.g. 15 (DP-1), 17 (HDMI-1), 18 (HDMI-2)")],
            returns: .custom("Object with 'ok' and 'input'"),
            handler: { params in
                guard let k = params?["key"]?.stringValue, !k.isEmpty else { throw RouterError.missingParam("key") }
                guard let code = params?["code"]?.intValue else { throw RouterError.missingParam("code") }
                guard (0...0xff).contains(code) else { throw RouterError.custom("code must be 0-255") }
                return blocking { writeInput(key: k, code: code) }.json
            }
        ))
    }
}
