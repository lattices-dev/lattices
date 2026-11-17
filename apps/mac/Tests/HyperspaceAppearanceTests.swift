import AppKit
import SwiftUI
import XCTest
@testable import Lattices

/// Opt-in native visual fixture. It hosts the production views on an already
/// provisioned agent display, with inert window data and no MotionPanel/input tap.
/// Action captures and operates these panels; no real window can be rearranged.
@MainActor
final class HyperspaceAppearanceTests: XCTestCase {
    func testAgentDisplayAppearance() throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["HYPERSPACE_RENDER_DIR"],
              let display = env["HYPERSPACE_RENDER_DISPLAY"].flatMap(UInt32.init) else {
            throw XCTSkip("Opt-in native appearance fixture requires an agent display")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        })
        XCTAssertNotEqual(screen, NSScreen.screens.first, "Use an agent display, not the main desktop")
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fixture = HyperspaceAppearanceFixture(screen: screen)
        defer { fixture.close() }
        fixture.show("desktop")
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("ready.pid"))

        let deadline = Date().addingTimeInterval(300)
        var previous = ""
        while Date() < deadline {
            let command = (try? String(contentsOfFile: output + "/mode", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if command == "done" { break }
            if command != previous, ["desktop", "overview", "selected", "proposal", "tray", "unavailable", "layers", "grid", "map"].contains(command) {
                fixture.show(command)
                previous = command
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(fixture.hud.canBecomeKey)
        XCTAssertFalse(fixture.field.canBecomeKey)
    }
}

@MainActor
private final class HyperspaceAppearanceFixture {
    final class PassivePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let screen: NSScreen
    let hud = HyperspaceDesktopHUD()
    let field = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let preview = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let canvas = ExposeCanvas()
    private let drag = HyperspaceDrag()
    private var mode = ""
    private var proposed: HyperspaceLayoutPlan?
    private var selected: [UInt32] = []
    private var entries: [WindowEntry] = []
    private var images: [NSImage] = []

    init(screen: NSScreen) {
        self.screen = screen
        for (index, app) in ["Chrome", "Chrome", "Rex", "Rex", "Notes", "Notes"].enumerated() {
            let wid = UInt32(700_001 + index)
            let title = ["Lattices — Workspace", "Material reference", "lattices · swift build", "Design notes", "This week's ideas", "Window arrangements"][index]
            let frame = WindowFrame(x: Double(index % 3) * 420, y: Double(index / 3) * 330, w: 680, h: 430)
            let entry = WindowEntry(wid: wid, app: app, pid: Int32(wid), title: title, frame: frame,
                                    spaceIds: [], isOnScreen: false, latticesSession: nil, zIndex: index, appHidden: false)
            let image = Self.thumbnail(app: app, title: title, dark: app == "Rex")
            entries.append(entry)
            images.append(image)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                WindowPreviewStore.shared.ingest(cgImage: cg, for: wid, frame: frame)
            }
        }
        for panel in [field, preview] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .aqua)
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        field.setFrame(screen.frame, display: false)
        field.level = .floating
        preview.level = NSWindow.Level(rawValue: hud.level.rawValue + 1)
        preview.hasShadow = true
        hud.onPresentation = { [weak self] desktop in self?.show(desktop ? "desktop" : "overview") }
        hud.onPick = { [weak self] wid in self?.pick(wid) }
        hud.onLayout = { [weak self] in self?.show("selected") }
        hud.onChooseLayout = { [weak self] plan in
            self?.proposed = plan
            self?.show(self?.mode ?? "overview")
        }
        hud.onDiscard = { [weak self] in
            self?.proposed = nil
            self?.show(self?.mode ?? "overview")
        }
        hud.onApply = { [weak self] in
            // The fixture can verify dispatch, but deliberately has no AX mutation.
            self?.proposed = nil
            self?.show(self?.mode ?? "overview")
        }
        hud.onTool = { [weak self] tool in
            guard let self else { return }
            self.canvas.tool = self.canvas.tool == tool ? nil : tool
            self.show(self.mode)
        }
    }

    /// A fitted split for the fixture: a tall reading column, a wide main, a short console.
    private static func suggestion(_ ids: [UInt32], in area: CGRect) -> HyperspaceLayoutPlan? {
        guard ids.count == 3 else { return nil }
        let a = area
        return .init(title: "Reading column", frames: [
            ids[0]: CGRect(x: a.minX + a.width * 0.28, y: a.minY, width: a.width * 0.72, height: a.height * 0.68),
            ids[1]: CGRect(x: a.minX, y: a.minY, width: a.width * 0.28, height: a.height),
            ids[2]: CGRect(x: a.minX + a.width * 0.28, y: a.minY + a.height * 0.68, width: a.width * 0.72, height: a.height * 0.32),
        ])
    }

    func show(_ next: String) {
        if next != mode {
            if next == "selected" || next == "proposal" || next == "tray" { selected = Array(entries.prefix(3).map(\.wid)) }
            if next == "selected" { proposed = nil }
            if next == "proposal" || next == "tray" {
                proposed = HyperspaceLayoutPlanner.mainAndCompanions(selected, in: CGRect(origin: .zero, size: screen.frame.size), leading: true)
            }
            if let tool = HyperspaceTool.allCases.first(where: { $0.rawValue.lowercased() == next }) { canvas.tool = tool }
            mode = next
        }
        let desktop = next == "desktop" || next == "unavailable" || next == "tray"
        let members = entries.enumerated().map { index, entry in
            ExposeView.LayerMember(id: entry.wid,
                                  frac: CGRect(x: Double(index % 3) / 3, y: Double(index / 3) / 2, width: 0.32, height: 0.48),
                                  tint: HyperspaceChrome.sage, image: images[index])
        }
        let clusters = stride(from: 0, to: entries.count, by: 2).map { offset in
            ExposeView.Cluster(id: offset, name: entries[offset].app, rule: "2 windows", userDefined: false,
                               hint: ["A", "S", "D"][offset / 2], searchQuery: "", searchActive: false,
                               tiles: (offset..<offset + 2).map { index in
                let entry = entries[index]
                return ExposeView.Tile(id: entry.wid, app: entry.app, title: entry.title, tint: HyperspaceChrome.sage,
                                       image: images[index], hint: ["Q", "W", "E", "R", "T", "Y"][index],
                                       pickSlot: selected.firstIndex(of: entry.wid).map { $0 + 1 }, isAimed: false, appIcon: Self.icon(for: entry.app))
            })
        }
        let layers: [ExposeView.LayerPile] = [
            .init(id: "work", name: "Work", count: 3, members: Array(members.prefix(3))),
            .init(id: "notes", name: "Notes", count: 2, members: Array(members.suffix(2))),
            .init(id: "new", name: "New layer", count: 0, isNew: true),
        ]
        let area = CGRect(origin: .zero, size: screen.frame.size)
        let markers = (proposed?.frames ?? [:]).map { id, frame in
            ExposeView.StagedMarker(id: id,
                frac: CGRect(x: frame.minX / area.width, y: frame.minY / area.height,
                             width: frame.width / area.width, height: frame.height / area.height),
                tint: HyperspaceChrome.accent, image: entries.firstIndex(where: { $0.wid == id }).map { images[$0] }, label: proposed?.title ?? "")
        }
        let view = ExposeView(clusters: clusters, tileWidth: 190, canvas: canvas, drag: drag,
                              screenID: "appearance", bandHeight: 200, unifiedChrome: true,
                              screenAspect: screen.frame.width / screen.frame.height,
                              onPick: { [weak self] in self?.pick($0) }, layers: layers, stagedPlan: markers, hasLayoutProposal: proposed != nil, currentLayout: members,
                              pickedWids: Set(selected), pickedOrder: selected,
                              layoutArea: area, layoutPreview: proposed)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        field.contentView = host
        field.orderFrontRegardless()
        if desktop { field.orderOut(nil) }

        hud.update(.init(windows: entries.map { entry in
            .init(id: entry.wid, app: entry.app, title: entry.title,
                  frame: CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h),
                  icon: Self.icon(for: entry.app), slot: selected.firstIndex(of: entry.wid).map { $0 + 1 })
        }, area: area, desktop: desktop, aimedID: nil, hasChanges: false, canUndo: false,
                         preview: proposed, notice: nil, busy: false, tool: canvas.tool,
                         // As in the app: layouts whenever two or more windows are picked.
                         layouts: selected.count >= 2 ? HyperspaceLayoutPlanner.arrangements(selected, in: area) : [],
                         suggestion: selected.count >= 2 ? Self.suggestion(selected, in: area) : nil), on: screen)

        if desktop && next != "tray" {
            let state = HUDState()
            var entry = entries[0]
            if next == "unavailable" {
                entry = WindowEntry(wid: 799_999, app: "Chrome", pid: 799_999, title: "Unavailable window preview",
                                    frame: entry.frame, spaceIds: [], isOnScreen: false, latticesSession: nil, zIndex: 0, appHidden: false)
            }
            state.hoveredPreviewItem = .window(entry)
            let previewView = HUDHoverPreviewView(state: state, appearance: .hyperspace,
                                                  actionTitle: selected.contains(entry.wid) ? "Deselect" : "Select",
                                                  onActivate: { [weak self] in self?.pick($0.wid) })
            let previewHost = NSHostingView(rootView: previewView)
            previewHost.sizingOptions = []
            preview.contentView = previewHost
            preview.setFrame(CGRect(x: hud.frame.midX - 180, y: hud.frame.maxY + 10, width: 360, height: 270), display: true)
            preview.orderFrontRegardless()
        } else { preview.orderOut(nil) }
    }

    private static func icon(for app: String) -> NSImage? {
        let bundleID = ["Chrome": "com.google.Chrome", "Rex": "com.superlogical.rex", "Notes": "com.apple.Notes"][app] ?? ""
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func pick(_ wid: UInt32) {
        proposed = nil
        if let index = selected.firstIndex(of: wid) { selected.remove(at: index) }
        else { selected.append(wid) }
        show(mode)
    }

    func close() {
        hud.orderOut(nil)
        preview.close()
        field.close()
    }

    private static func thumbnail(app: String, title: String, dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 680, height: 430))
        image.lockFocus()
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: 680, height: 430).fill()
        NSColor(calibratedWhite: dark ? 0.18 : 0.91, alpha: 1).setFill()
        NSRect(x: 0, y: 390, width: 680, height: 40).fill()
        let color = dark ? NSColor.white : NSColor.darkGray
        (title as NSString).draw(at: NSPoint(x: 24, y: 340), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: color])
        let lines = dark ? ["$ swift build --package-path apps/mac", "Building Lattices…", "Build complete."] : [app, "A calmer place to arrange your work.", "Window preview fixture"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 24, y: 280 - index * 42), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular), .foregroundColor: color.withAlphaComponent(0.7)])
        }
        image.unlockFocus()
        return image
    }
}
