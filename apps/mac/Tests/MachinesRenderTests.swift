import AppKit
import SwiftUI
import XCTest
@testable import Lattices

@MainActor
final class MachinesRenderTests: XCTestCase {
    func testOfflineCanvasFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["MACHINES_RENDER_DIR"] else { throw XCTSkip("Opt-in offline render") }
        let model = MachinesModel()
        model.screens = [
            .init(number: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), main: true, elsewhere: false, displayID: 1),
            .init(number: 2, name: "Second", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), main: false, elsewhere: false, displayID: 2),
            .init(number: 3, name: "Elsewhere", frame: CGRect(x: 0, y: 1440, width: 1920, height: 1080), main: false, elsewhere: true, displayID: 3, machine: "arts-mini"),
        ]
        let hosts: [VisitTrust.Host] = [
            .init(name: "archie", address: "fixture.invalid", side: .right, bridgePublicKey: "fixture", bridgeFingerprint: "fixture", capabilities: [], pairedAt: Date(), placement: .init(x: 2560, y: 0)),
            .init(name: "arts-mini", address: "fixture2.invalid", side: .bottom, bridgePublicKey: "fixture", bridgeFingerprint: "fixture", capabilities: [], pairedAt: Date(), placement: .init(x: 0, y: 1440)),
        ]
        model.visit.hosts = hosts; model.reachable = ["archie": true]
        let machines = MachineInventory.merge(hosts.map { .init(name: $0.name, address: $0.address, visit: $0) } + [.init(name: "Offline machine", address: "fixture3.invalid")])
        let monitors: [String: [MachineArrangementStore.Monitor]] = ["archie": [
            .init(name: "HDMI-A-1", frame: .init(x: 0, y: 0, width: 3440, height: 1440)),
            .init(name: "LATS-1", frame: .init(x: 3440, y: 0, width: 1920, height: 1080)),
        ]]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for width in [720.0, 1100.0] {
            let view = MachineArrangementCanvas(model: model, machines: machines, selection: .constant(machines.first?.id), monitorFixtures: monitors, trackpad: false)
                .padding(16).frame(width: width, height: 360).background(Palette.bg).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let cg = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("machines-\(Int(width)).png"))
        }
    }
}

@MainActor
final class ClusterRowsRenderTests: XCTestCase {
    func testOfflineRows() throws {
        guard let dir = ProcessInfo.processInfo.environment["MACHINES_RENDER_DIR"] else { throw XCTSkip("Opt-in offline render") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for width in [720.0, 1100.0] {
            let view = MachineTable {
                MachineRow(name: "archie", address: "100.64.0.1", platform: "linux", status: "Reachable", build: "0.13.2 · a1234567",
                    drift: .behind, displays: 1, visiting: true, selected: true, canVisit: false, canView: true, select: {}, visit: {}, view: {})
                MachineColumn.divider
                MachineRow(name: "arts-mini", address: "arts-mini", platform: "macos", status: "Unreachable", build: "? · ?",
                    displays: 2, visiting: false, selected: false, canVisit: true, canView: false, select: {}, visit: {}, view: {})
                MachineColumn.divider
                MachineRow(name: "MacBook Air", address: "air.local", status: "Connecting", build: "0.13.3 · abcdef01",
                    drift: .different, visiting: false, selected: false, canVisit: nil, canView: false, select: {}, visit: {}, view: {})
            }.padding(16).frame(width: width).foregroundStyle(Palette.text).background(Palette.bg)
                .buttonStyle(.bordered).controlSize(.small).tint(Palette.textDim).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cluster-rows-\(Int(width)).png"))
        }
    }
}

@MainActor
final class DeskCanvasTests: XCTestCase {
    private let dell = "dell s3422dwg|3kn2kk3"
    private let samsung = "u32j59x|hcry300398"
    private let alienware = "aw3425dwm|jwlc444"

    private func fixtures() -> (screens: [VisitController.Screen], identities: [CGDirectDisplayID: MonitorIdentity],
                                machines: [(name: String, monitors: [MachineArrangementStore.Monitor])]) {
        let screens: [VisitController.Screen] = [
            .init(number: 1, name: "DELL S3422DWG", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), main: true, elsewhere: false, displayID: 1),
            .init(number: 2, name: "U32J59x", frame: CGRect(x: -3840, y: -396, width: 3840, height: 2160), main: false, elsewhere: false, displayID: 2),
            .init(number: 3, name: "Action Agent Layer", frame: CGRect(x: 3440, y: 0, width: 1920, height: 1080), main: false, elsewhere: false, displayID: 3),
        ]
        let identities: [CGDirectDisplayID: MonitorIdentity] = [
            1: MonitorIdentity(make: "DEL", model: "DELL S3422DWG", serial: "3KN2KK3", widthMm: 800, heightMm: 335),
            2: MonitorIdentity(make: "SAM", model: "U32J59x", serial: "HCRY300398", widthMm: 698, heightMm: 393),
        ]
        let machines: [(name: String, monitors: [MachineArrangementStore.Monitor])] = [
            ("arts-mini", [
                .init(name: "Dell AW3425DWM", frame: .init(x: 0, y: 0, width: 3440, height: 1440), key: alienware, model: "AW3425DWM", widthMm: 800, heightMm: 335),
                .init(name: "U32J59x", frame: .init(x: 3440, y: 235, width: 3840, height: 2160), key: samsung, model: "U32J59x"),
            ]),
            ("archie", [.init(name: "HDMI-A-1", frame: .init(x: 0, y: 0, width: 3440, height: 1440), key: alienware, model: "AW3425DWM")]),
        ]
        return (screens, identities, machines)
    }

    func testFeedsThisMacFirstAndSkipsUnkeyedDisplays() throws {
        let f = fixtures()
        let hosts = DeskCanvas.hosts(screens: f.screens, identities: f.identities, machines: f.machines)
        XCTAssertEqual(hosts.map(\.name), [MonitorInputs.here, "arts-mini", "archie"])
        XCTAssertEqual(hosts[0].displays.map(\.key), [dell, samsung, nil])
        XCTAssertEqual(hosts[0].displays[0].widthMm, 800)
        let desk = DeskLayout.stitch(hosts: hosts)
        XCTAssertEqual(desk.monitors.sorted { $0.origin.x < $1.origin.x }.map(\.key), [alienware, samsung, dell])
        XCTAssertEqual(desk.monitor(samsung)?.hosts, [MonitorInputs.here, "arts-mini"])
    }

    func testALaptopScreenIsItsHostsOwnMonitor() throws {
        let air = MachineArrangementStore.parseMonitors([
            ["name": "Built-in Display", "frame": ["x": 0.0, "y": 0.0, "w": 2560.0, "h": 1664.0],
             "builtin": ["widthMm": 302, "heightMm": 196]],
        ])
        XCTAssertEqual(air.first?.builtin, true)
        XCTAssertNil(air.first?.key)
        let f = fixtures()
        let hosts = DeskCanvas.hosts(screens: f.screens, identities: f.identities, machines: f.machines + [("air", air)])
        let desk = DeskLayout.stitch(hosts: hosts)
        let screen = try XCTUnwrap(desk.monitor(DeskCanvas.builtinKey("air")))
        XCTAssertEqual(screen.hosts, ["air"])
        XCTAssertEqual(screen.size, CGSize(width: 302, height: 196))
        XCTAssertEqual(screen.model, DeskCanvas.builtinModel)
    }

    func testCurrentHostIsTheInputOwnerOrTheOnlyHost() {
        let shared = DeskMonitor(key: samsung, model: nil, size: .zero, origin: .zero, hosts: [MonitorInputs.here, "arts-mini"], source: .derived)
        XCTAssertEqual(DeskCanvas.current(shared, owner: "Arts-Mini"), "arts-mini")
        XCTAssertNil(DeskCanvas.current(shared, owner: nil))
        XCTAssertNil(DeskCanvas.current(shared, owner: "archie"))
        let single = DeskMonitor(key: dell, model: nil, size: .zero, origin: .zero, hosts: [MonitorInputs.here], source: .derived)
        XCTAssertEqual(DeskCanvas.current(single, owner: nil), MonitorInputs.here)
        XCTAssertNil(DeskCanvas.current(single, owner: nil, onlyShowing: false))
        XCTAssertEqual(DeskCanvas.current(single, owner: nil, onlyShowing: true), MonitorInputs.here)
    }

    func testOfflineDeskFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["MACHINES_RENDER_DIR"] else { throw XCTSkip("Opt-in offline render") }
        let f = fixtures()
        let suite = "desk-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeskStore(defaults: defaults)
        let inputs = MonitorInputs(defaults: defaults)
        // A host's picture shows only on a tile where that host is on screen: here, the single-host Dell.
        let still = NSImage(size: NSSize(width: 344, height: 144), flipped: false) { rect in
            NSColor(white: 0.32, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: rect.width, height: 14).fill()
            return true
        }
        var hosts = DeskCanvas.hosts(screens: f.screens, identities: f.identities, machines: f.machines)
        // Archie has a monitor of its own below the Alienware; the second render pins the Samsung
        // where this Mac's arrangement disagrees.
        hosts[2].displays.append(.init(key: "lg 27gl850|abc", model: "LG 27GL850", frame: CGRect(x: 0, y: 1440, width: 2560, height: 1440)))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, pinned, width) in [("desk", nil as String?, 720.0), ("desk-archie", "archie", 1100.0)] {
            let desk = DeskLayout.stitch(hosts: hosts, origins: name == "desk" ? [:] : [samsung: CGPoint(x: 1700, y: 0)])
            let view = DeskCanvas(desk: desk, image: { host, key in host == "arts-mini" || key == self.dell ? still : nil },
                                  inputs: inputs, store: store, trackpad: false, pinned: pinned)
                .padding(16).frame(width: width, height: 360).background(Palette.bg).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let cg = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(width)).png"))
        }
    }
}
