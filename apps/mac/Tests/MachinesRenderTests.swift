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
            let view = MachineArrangementCanvas(model: model, machines: machines, monitorFixtures: monitors)
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
            let view = VStack(spacing: 0) {
                MachineRow(name: "archie", address: "100.64.0.1", reachability: "Reachable", build: "0.13.2 · a1234567 · Behind",
                    paired: true, placement: "right", visiting: true, selected: true, canVisit: false, canOpen: true,
                    select: {}, visit: {}, open: {})
                MachineRow(name: "arts-mini", address: "arts-mini.local", reachability: "Unreachable", build: "? · ?",
                    paired: true, placement: "left", visiting: false, selected: false, canVisit: true, canOpen: true,
                    select: {}, visit: {}, open: {})
                MachineRow(name: "MacBook Air", address: "air.local", reachability: "Connecting", build: "0.13.3 · abcdef01",
                    paired: false, placement: "Unplaced", visiting: false, selected: false, canVisit: false, canOpen: true,
                    select: {}, visit: {}, open: {})
            }.padding(16).frame(width: width).foregroundStyle(Palette.text).background(Palette.bg)
                .buttonStyle(.bordered).controlSize(.small).tint(Palette.textDim).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cluster-rows-\(Int(width)).png"))
        }
    }
}
