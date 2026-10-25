import XCTest
@testable import Lattices

final class MonitorInputsTests: XCTestCase {
    func testOwnerIsTheMachineOnTheCurrentInput() {
        let map = ["archie": 18, "arts-mini": 15]
        XCTAssertEqual(MonitorInputs.owner(of: 18, in: map), "archie")
        XCTAssertEqual(MonitorInputs.owner(of: 15, in: map), "arts-mini")
        XCTAssertNil(MonitorInputs.owner(of: 17, in: map))
        XCTAssertNil(MonitorInputs.owner(of: nil, in: map))
    }

    func testAssigningKeepsOneMachinePerInput() {
        var map = MonitorInputs.assigning(18, to: "archie", in: [:])
        XCTAssertEqual(map, ["archie": 18])
        map = MonitorInputs.assigning(15, to: "arts-mini", in: map)
        XCTAssertEqual(map, ["archie": 18, "arts-mini": 15])
        // Reassigning an input moves it; reassigning a machine replaces its input.
        map = MonitorInputs.assigning(18, to: "arts-mini", in: map)
        XCTAssertEqual(map, ["arts-mini": 18])
    }

    func testParsesAHostReply() {
        let reply: [String: Any] = ["key": "aw3425dwm|jwlc444", "ddc": true,
                                    "input": ["code": 18, "name": "HDMI-2"],
                                    "inputs": [["code": 15, "name": "DP-1"], ["code": 17, "name": "HDMI-1"], ["code": 18, "name": "HDMI-2"]]]
        let result = MonitorInputs.result(reply, key: "aw3425dwm|jwlc444")
        XCTAssertTrue(result.ddc)
        XCTAssertEqual(result.input?.code, 18)
        XCTAssertEqual(result.input?.name, "HDMI-2")
        XCTAssertEqual(result.inputs.map(\.code), [15, 17, 18])
    }

    func testParsesAHostWithoutDDC() {
        let result = MonitorInputs.result(["key": "k", "ddc": false, "input": NSNull(), "inputs": []], key: "k")
        XCTAssertFalse(result.ddc)
        XCTAssertNil(result.input)
        XCTAssertTrue(result.inputs.isEmpty)
    }

    func testMonitorsCarryTheirIdentity() {
        let displays: [[String: Any]] = [
            ["displayId": "HDMI-A-1", "frame": ["x": 0.0, "y": 0.0, "w": 3440.0, "h": 1440.0],
             "monitor": ["make": "Dell Inc.", "model": "AW3425DWM", "serial": "JWLC444", "key": "aw3425dwm|jwlc444"]],
            ["displayId": "eDP-1", "frame": ["x": 3440.0, "y": 0.0, "w": 1920.0, "h": 1200.0]],
        ]
        let monitors = MachineArrangementStore.parseMonitors(displays)
        XCTAssertEqual(monitors.map(\.key), ["aw3425dwm|jwlc444", nil])
        XCTAssertEqual(monitors.first?.model, "AW3425DWM")
    }

    func testMonitorsCarryPhysicalSize() {
        let displays: [[String: Any]] = [
            ["displayId": "HDMI-A-1", "frame": ["x": 0.0, "y": 0.0, "w": 3440.0, "h": 1440.0],
             "monitor": ["model": "AW3425DWM", "serial": "JWLC444", "key": "aw3425dwm|jwlc444", "widthMm": 800, "heightMm": 335]],
            ["displayId": "DP-1", "frame": ["x": 3440.0, "y": 0.0, "w": 3840.0, "h": 2160.0],
             "monitor": ["model": "U32J59x", "serial": "HCRY300398", "key": "u32j59x|hcry300398", "widthMm": 0, "heightMm": 400]],
        ]
        let monitors = MachineArrangementStore.parseMonitors(displays)
        XCTAssertEqual(monitors.first?.widthMm, 800)
        XCTAssertEqual(monitors.first?.heightMm, 335)
        XCTAssertNil(monitors.last?.widthMm)
        XCTAssertNil(monitors.last?.heightMm)
    }

    func testIdentityEncodesPhysicalSizeOnlyWhenKnown() {
        let dell = MonitorIdentity(make: "DEL", model: "DELL S3422DWG", serial: "3KN2KK3")
        guard case .object(let bare) = dell.json else { return XCTFail() }
        XCTAssertNil(bare["widthMm"])
        let sized = dell.sized(CGSize(width: 799.6, height: 334.7))
        XCTAssertEqual(sized.widthMm, 800)
        XCTAssertEqual(sized.heightMm, 335)
        XCTAssertEqual(sized.key, dell.key)
        guard case .object(let obj) = sized.json else { return XCTFail() }
        XCTAssertEqual(obj["widthMm"], .int(800))
        XCTAssertEqual(obj["heightMm"], .int(335))
        XCTAssertNil(dell.sized(.zero).widthMm)
        XCTAssertNil(dell.sized(CGSize(width: 800, height: 0)).heightMm)
    }

    func testSizedMonitorsRoundTripTheCache() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MonitorInputsTests.sized"))
        defer { defaults.removePersistentDomain(forName: "MonitorInputsTests.sized") }
        let monitor = MachineArrangementStore.Monitor(name: "HDMI-A-1", frame: .init(x: 0, y: 0, width: 3440, height: 1440),
                                                      key: "aw3425dwm|jwlc444", model: "AW3425DWM", widthMm: 800, heightMm: 335)
        MachineArrangementStore.cache([monitor], for: "archie", defaults: defaults)
        XCTAssertEqual(MachineArrangementStore.monitors("archie", defaults: defaults), [monitor])
    }

    func testOlderCachedMonitorsStillDecode() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MonitorInputsTests"))
        defer { defaults.removePersistentDomain(forName: "MonitorInputsTests") }
        let old = #"{"version":1,"monitors":[{"name":"HDMI-A-1","frame":{"height":1440,"x":0,"width":3440,"y":0}}]}"#
        defaults.set(Data(old.utf8), forKey: "machines.monitors.archie")
        let monitors = MachineArrangementStore.monitors("archie", defaults: defaults)
        XCTAssertEqual(monitors.count, 1)
        XCTAssertNil(monitors.first?.key)
    }

    func testMachineNamesMatchIgnoringCase() {
        let map = ["Arts-Mini": 17, MonitorInputs.here: 15]
        XCTAssertEqual(MonitorInputs.code(of: "arts-mini", in: map), 17)
        XCTAssertNil(MonitorInputs.code(of: "archie", in: map))
        let next = MonitorInputs.assigning(18, to: "arts-mini", in: map)
        XCTAssertEqual(next, ["arts-mini": 18, MonitorInputs.here: 15])
    }
}
