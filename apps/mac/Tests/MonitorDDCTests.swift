import XCTest
@testable import Lattices

final class MonitorIdentityTests: XCTestCase {
    func testKeyLowercasesAndTrims() {
        XCTAssertEqual(MonitorIdentity.key(model: "AW3425DWM", serial: "JWLC444"), "aw3425dwm|jwlc444")
        XCTAssertEqual(MonitorIdentity.key(model: " U32J59x ", serial: "HCRY300398\n"), "u32j59x|hcry300398")
        XCTAssertEqual(MonitorIdentity.key(model: "DELL S3422DWG", serial: "3KN2KK3"), "dell s3422dwg|3kn2kk3")
    }

    func testKeyNilWithoutModelOrSerial() {
        XCTAssertNil(MonitorIdentity.key(model: "Color LCD", serial: ""))
        XCTAssertNil(MonitorIdentity.key(model: nil, serial: "X"))
        XCTAssertNil(MonitorIdentity.key(model: "  ", serial: "X"))
    }

    func testAttributesFromRegistryDictionary() {
        let attrs = MonitorIdentity.Attributes(displayAttributes: [
            "ProductAttributes": ["ManufacturerID": "SAM", "SerialNumber": 809054789, "ProductName": "U32J59x",
                                  "AlphanumericSerialNumber": "HCRY300398", "LegacyManufacturerID": 19501, "ProductID": 3891],
        ])
        XCTAssertEqual(attrs?.identity, MonitorIdentity(make: "SAM", model: "U32J59x", serial: "HCRY300398"))
        XCTAssertEqual(attrs?.identity?.key, "u32j59x|hcry300398")
        XCTAssertEqual(attrs?.identity?.json["make"]?.stringValue, "SAM")
        // A built-in panel has no alphanumeric serial: no identity.
        XCTAssertNil(MonitorIdentity.Attributes(displayAttributes: ["ProductAttributes": ["ProductName": "Color LCD"]])?.identity)
    }

    func testMatchBySerialAndVendorNotProduct() {
        let samsung = MonitorIdentity.Attributes(make: "SAM", model: "U32J59x", serial: "HCRY300398", numericSerial: 809054789, vendor: 19501, product: 3891)
        let dell = MonitorIdentity.Attributes(make: "DEL", model: "DELL S3422DWG", serial: "3KN2KK3", numericSerial: 811028054, vendor: 4268, product: 53540)
        // Same monitor on another input reports a different product id.
        XCTAssertEqual(MonitorIdentity.match(vendor: 19501, model: 3922, serial: 809054789, among: [dell, samsung]), samsung)
        XCTAssertEqual(MonitorIdentity.match(vendor: 4268, model: 53540, serial: 0, among: [dell, samsung]), dell)
        XCTAssertNil(MonitorIdentity.match(vendor: 4268, model: 1, serial: 0, among: [dell, samsung]))
    }
}

final class MonitorDDCTests: XCTestCase {
    func testGetRequestFraming() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x60 = 0xDC
        XCTAssertEqual(MonitorDDC.getRequest(vcp: 0x60), [0x51, 0x82, 0x01, 0x60, 0xDC])
        XCTAssertEqual(MonitorDDC.getRequest(vcp: 0x10), [0x51, 0x82, 0x01, 0x10, 0xAC])
    }

    func testSetRequestFraming() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x60 ^ 0x00 ^ 0x12 = 0xCA
        XCTAssertEqual(MonitorDDC.setRequest(vcp: 0x60, value: 0x12), [0x51, 0x84, 0x03, 0x60, 0x00, 0x12, 0xCA])
    }

    func testCapabilitiesRequestFraming() {
        let frame = MonitorDDC.capabilitiesRequest(offset: 0x0020)
        XCTAssertEqual(Array(frame.prefix(5)), [0x51, 0x83, 0xF3, 0x00, 0x20])
        XCTAssertEqual(frame.last, MonitorDDC.checksum(Array(frame.dropLast()), seed: 0x6E))
    }

    private func reply(vcp: UInt8, current: UInt16, maximum: UInt16 = 0x00ff, result: UInt8 = 0) -> [UInt8] {
        let body: [UInt8] = [0x6E, 0x88, 0x02, result, vcp, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xff), UInt8(current >> 8), UInt8(current & 0xff)]
        return body + [MonitorDDC.checksum(body, seed: 0x50)]
    }

    func testParseReply() {
        let parsed = MonitorDDC.parseReply(reply(vcp: 0x60, current: 0x0012), vcp: 0x60)
        XCTAssertEqual(parsed?.current, 0x12)
        XCTAssertEqual(parsed?.maximum, 0xff)
    }

    func testParseReplyRejectsBadReplies() {
        var corrupt = reply(vcp: 0x60, current: 0x11); corrupt[9] ^= 0x01
        XCTAssertNil(MonitorDDC.parseReply(corrupt, vcp: 0x60))
        XCTAssertNil(MonitorDDC.parseReply(reply(vcp: 0x10, current: 0x11), vcp: 0x60))
        XCTAssertNil(MonitorDDC.parseReply(reply(vcp: 0x60, current: 0x11, result: 0x01), vcp: 0x60))
        XCTAssertNil(MonitorDDC.parseReply([0x6E, 0x80], vcp: 0x60))
    }

    func testInputMasksHighBits() {
        // Some monitors set high bits in the current value.
        let parsed = MonitorDDC.parseReply(reply(vcp: 0x60, current: 0x0F11), vcp: 0x60)
        let input = MonitorDDC.Input(code: parsed?.current ?? 0)
        XCTAssertEqual(input.code, 0x11)
        XCTAssertEqual(input.name, "HDMI-1")
    }

    func testInputNames() {
        XCTAssertEqual(MonitorDDC.inputName(0x0f), "DP-1")
        XCTAssertEqual(MonitorDDC.inputName(0x10), "DP-2")
        XCTAssertEqual(MonitorDDC.inputName(0x12), "HDMI-2")
        XCTAssertEqual(MonitorDDC.inputName(0x1b), "USB-C")
        XCTAssertEqual(MonitorDDC.inputName(0x01), "VGA-1")
        XCTAssertEqual(MonitorDDC.inputName(0x03), "DVI-1")
        XCTAssertEqual(MonitorDDC.inputName(0x05), "Input 0x05")
    }

    func testCapabilitiesFragment() {
        let data = Array("vcp(60".utf8)
        let body: [UInt8] = [0x6E, UInt8(0x80 | (data.count + 3)), 0xE3, 0x00, 0x20] + data
        let bytes = body + [MonitorDDC.checksum(body, seed: 0x50)] + [0, 0, 0]
        XCTAssertEqual(MonitorDDC.parseCapabilitiesFragment(bytes, offset: 0x20), data)
        XCTAssertNil(MonitorDDC.parseCapabilitiesFragment(bytes, offset: 0x00))
        let end: [UInt8] = [0x6E, 0x83, 0xE3, 0x00, 0x40]
        XCTAssertEqual(MonitorDDC.parseCapabilitiesFragment(end + [MonitorDDC.checksum(end, seed: 0x50)], offset: 0x40), [])
    }

    func testCapabilityInputs() {
        let caps = "(prot(monitor)type(LCD)model(AW3425DWM)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60(0F 11 12) AA(01 02) D6(01 04 05))mccs_ver(2.1))"
        XCTAssertEqual(MonitorDDC.capabilityInputs(caps), [0x0f, 0x11, 0x12])
        XCTAssertEqual(MonitorDDC.capabilityInputs("vcp(0210 60(0f 11) 62)"), [0x0f, 0x11])
        XCTAssertEqual(MonitorDDC.capabilityInputs("vcp(02 10 12)"), [])
        XCTAssertEqual(MonitorDDC.capabilityInputs("(prot(monitor))"), [])
    }

    func testPairsExternalProxyWithPrecedingFramebuffer() {
        let samsung = MonitorIdentity(make: "SAM", model: "U32J59x", serial: "HCRY300398")
        let dell = MonitorIdentity(make: "DEL", model: "DELL S3422DWG", serial: "3KN2KK3")
        let entries: [MonitorDDC.RegistryEntry] = [
            .framebuffer(nil), .avService(external: false),        // built-in panel
            .framebuffer(samsung), .avService(external: false), .avService(external: true),
            .framebuffer(dell), .avService(external: true),
            .avService(external: true),                              // no framebuffer pending
        ]
        XCTAssertEqual(MonitorDDC.pair(entries), ["u32j59x|hcry300398": 4, "dell s3422dwg|3kn2kk3": 6])
        // An unidentified framebuffer clears the pending monitor.
        XCTAssertEqual(MonitorDDC.pair([.framebuffer(dell), .framebuffer(nil), .avService(external: true)]), [:])
    }

    func testResultJSON() {
        let off = MonitorDDC.Result(key: "u32j59x|hcry300398", ddc: false, input: nil, inputs: [])
        XCTAssertEqual(off.json["ddc"]?.boolValue, false)
        XCTAssertEqual(off.json["input"], .null)
        let on = MonitorDDC.Result(key: "k", ddc: true, input: .init(code: 0x0f), inputs: [.init(code: 0x0f), .init(code: 0x11)])
        XCTAssertEqual(on.json["input"]?["name"]?.stringValue, "DP-1")
        XCTAssertEqual(on.json["inputs"]?.arrayValue?.count, 2)
    }

    /// Read-only probe of the attached monitors: LATTICES_DDC_PROBE=1 swift test
    /// --filter MonitorDDCTests/testProbeAttachedMonitors. Never writes.
    func testProbeAttachedMonitors() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATTICES_DDC_PROBE"] == "1", "hardware probe")
        for monitor in MonitorIdentity.attached() {
            let started = Date()
            let result = await MonitorDDC.input(key: monitor.key)
            print("[ddc-probe] \(monitor.make ?? "-") \(monitor.key) ddc=\(result.ddc) input=\(result.input.map { "\($0.name) (0x\(String($0.code, radix: 16)))" } ?? "nil") inputs=\(result.inputs.map(\.name)) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
    }
}
