import CoreGraphics
import XCTest
@testable import Lattices

final class DesktopInventoryTests: XCTestCase {
    /// macOS 27 reports a hidden app's windows as 1×1 here.
    private let collapsedRect = CGRect(x: 1720, y: 720, width: 1, height: 1)

    private func row(
        _ wid: UInt32,
        app: String,
        pid: Int32,
        title: String? = nil,
        frame: CGRect,
        layer: Int = 0,
        onScreen: Bool = true
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: wid,
            kCGWindowOwnerName as String: app,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: frame.dictionaryRepresentation,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: onScreen,
        ]
        if let title { info[kCGWindowName as String] = title }
        return info
    }

    private func sources(
        hidden: Set<Int32> = [],
        accessory: Set<Int32> = [],
        spaces: [UInt32: [Int]] = [:],
        trueBounds: [UInt32: CGRect] = [:],
        asked: ((UInt32) -> Void)? = nil
    ) -> DesktopModel.InventorySources {
        DesktopModel.InventorySources(
            appFacts: { pid in
                DesktopModel.AppFacts(bundleId: "com.example.\(pid)", isHidden: hidden.contains(pid), isRegular: !accessory.contains(pid))
            },
            spaces: { spaces[$0] ?? [] },
            trueBounds: { wid in
                asked?(wid)
                return trueBounds[wid]
            }
        )
    }

    private func entry(
        _ wid: UInt32,
        pid: Int32 = 10,
        title: String = "Doc",
        frame: WindowFrame = WindowFrame(x: 0, y: 0, w: 800, h: 600),
        spaceIds: [Int] = [1],
        isOnScreen: Bool = true
    ) -> WindowEntry {
        WindowEntry(wid: wid, app: "App\(pid)", pid: pid, title: title, frame: frame,
                    spaceIds: spaceIds, isOnScreen: isOnScreen, latticesSession: nil)
    }

    func testCaptureInventoryKeepsUntitledPanelsWithoutChangingPlacementInventory() {
        let panel = row(134, app: "Scout", pid: 782,
                        frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), layer: 3)
        let hidden = row(135, app: "Scout", pid: 782,
                         frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                         layer: 3, onScreen: false)
        let entries = DesktopModel.captureWindows(in: [panel, hidden])
        XCTAssertEqual(entries.map(\.wid), [134])
        XCTAssertEqual(entries.first?.title, "")
        XCTAssertEqual(entries.first?.cgLayer, 3)
        XCTAssertEqual(entries.first?.axVerified, false)
        XCTAssertTrue(DesktopModel.sweep([panel], sources: sources(), recoverCollapsed: false).entries.isEmpty)
    }

    func testLiveCaptureInventoryWhenRequested() throws {
        guard let raw = ProcessInfo.processInfo.environment["LATTICES_CAPTURE_REPRO_WID"],
              let wid = UInt32(raw) else { throw XCTSkip("Set LATTICES_CAPTURE_REPRO_WID for read-only live inventory repro") }
        let entry = try XCTUnwrap(DesktopModel.captureWindows().first { $0.wid == wid })
        let resolved = try CaptureController.shared.resolveWindow(params: .object(["wid": .int(Int(wid))]))
        XCTAssertEqual(resolved.wid, wid)
        XCTAssertEqual(entry.app, "Scout")
        XCTAssertEqual(entry.cgLayer, 3)
        print("Live capture inventory: wid=\(entry.wid) app=\(entry.app) cgLayer=\(entry.cgLayer ?? -1) frame=\(entry.frame)")
    }

    func testAppCaptureRequiresExplicitChoiceForAmbiguousPanels() throws {
        let rows = [
            row(123, app: "Scout", pid: 782, title: "Scout", frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            row(134, app: "Scout", pid: 782, frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), layer: 3),
        ]
        let entries = DesktopModel.captureWindows(in: rows)
        XCTAssertThrowsError(try CaptureController.windowForCapture(app: "scout", title: nil, candidates: entries)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("wid:123"))
            XCTAssertTrue(message.contains("wid:134"))
            XCTAssertTrue(message.contains("(untitled)"))
            XCTAssertTrue(message.contains("lats capture window <wid>"))
        }
        XCTAssertEqual(try CaptureController.windowForCapture(app: "scout", title: "Scout", candidates: entries).wid, 123)
    }

    // MARK: - Sweep

    func testSweepKeepsAHiddenAppsCollapsedWindowWithItsTrueFrame() {
        let list = [
            row(1, app: "Calculator", pid: 20, title: "Calculator", frame: collapsedRect, onScreen: false),
            row(2, app: "Calculator", pid: 20, frame: collapsedRect, onScreen: false),
        ]
        let sweep = DesktopModel.sweep(list, sources: sources(
            hidden: [20],
            spaces: [1: [1], 2: [1]],
            trueBounds: [1: CGRect(x: 784, y: 537, width: 230, height: 461), 2: CGRect(x: 790, y: 540, width: 200, height: 300)]
        ), recoverCollapsed: true)

        let calculator = sweep.entries[1]
        XCTAssertEqual(calculator?.frame, WindowFrame(x: 784, y: 537, w: 230, h: 461))
        XCTAssertEqual(calculator?.collapsed, true)
        XCTAssertEqual(calculator?.appHidden, true)
        XCTAssertEqual(calculator?.bundleId, "com.example.20")
        XCTAssertEqual(calculator?.spaceIds, [1])
        // Untitled, but its app is hidden: kept too.
        XCTAssertEqual(sweep.entries[2]?.frame.h, 300)
        XCTAssertTrue(sweep.unresolved.isEmpty)
    }

    func testSweepKeepsATitledCollapsedWindowOfAShowingApp() {
        let list = [row(3, app: "Blink", pid: 30, title: "Blink Settings", frame: collapsedRect, onScreen: false)]
        let sweep = DesktopModel.sweep(list, sources: sources(
            accessory: [30], spaces: [3: [4]], trueBounds: [3: CGRect(x: 708, y: 361, width: 860, height: 720)]
        ), recoverCollapsed: true)
        XCTAssertEqual(sweep.entries[3]?.frame, WindowFrame(x: 708, y: 361, w: 860, h: 720))
        XCTAssertEqual(sweep.entries[3]?.appHidden, false)
    }

    func testSweepDropsTinyUntitledWindowsWithoutAskingForTheirFrame() {
        var asked: [UInt32] = []
        let list = [
            row(4, app: "Google Chrome", pid: 40, frame: CGRect(x: 10, y: 10, width: 1, height: 1)),
            row(5, app: "Google Chrome", pid: 40, frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
        ]
        let sweep = DesktopModel.sweep(list, sources: sources(asked: { asked.append($0) }), recoverCollapsed: true)
        XCTAssertTrue(sweep.entries.isEmpty)
        XCTAssertTrue(asked.isEmpty)
    }

    func testSweepWithoutRecoveryLeavesCollapsedWindowsOut() {
        let list = [
            row(1, app: "Calculator", pid: 20, title: "Calculator", frame: collapsedRect, onScreen: false),
            row(6, app: "Notes", pid: 60, title: "Notes", frame: CGRect(x: 0, y: 0, width: 900, height: 700)),
        ]
        let sweep = DesktopModel.sweep(list, sources: sources(
            hidden: [20], trueBounds: [1: CGRect(x: 784, y: 537, width: 230, height: 461)]
        ), recoverCollapsed: false)
        XCTAssertEqual(Array(sweep.entries.keys), [6])
        XCTAssertEqual(sweep.entries[6]?.collapsed, false)
    }

    func testSweepKeepsTheOldFilters() {
        let big = CGRect(x: 0, y: 0, width: 600, height: 400)
        let list = [
            row(7, app: "Menu", pid: 70, title: "Menu", frame: big, layer: 25),
            row(8, app: "AutoFillPanelService", pid: 71, title: "Fill", frame: big),
            row(9, app: "FooAgent", pid: 72, title: "Foo", frame: big),
            row(10, app: "com.apple.Thing", pid: 73, frame: big),
            row(11, app: "Finder", pid: 74, title: "Home", frame: big),
        ]
        let sweep = DesktopModel.sweep(list, sources: sources(), recoverCollapsed: true)
        XCTAssertEqual(Array(sweep.entries.keys), [11])
        XCTAssertEqual(sweep.entries[11]?.zIndex, 0)
    }

    func testAnUnresolvedCollapsedWindowTakesAXsFrameThenItsLastOne() {
        let list = [
            row(12, app: "Pages", pid: 80, title: "Report", frame: collapsedRect, onScreen: false),
            row(13, app: "Pages", pid: 80, title: "Notes", frame: collapsedRect, onScreen: false),
            row(14, app: "Pages", pid: 80, title: "Draft", frame: collapsedRect, onScreen: false),
        ]
        var sweep = DesktopModel.sweep(list, sources: sources(hidden: [80]), recoverCollapsed: true)
        XCTAssertEqual(sweep.unresolved, [12, 13, 14])

        let last = WindowFrame(x: 5, y: 5, w: 500, h: 400)
        DesktopModel.resolveCollapsed(
            &sweep,
            axFrames: [12: CGRect(x: 100, y: 100, width: 640, height: 480), 13: CGRect(x: 0, y: 0, width: 20, height: 20)],
            lastFrames: [12: last, 13: last]
        )
        XCTAssertEqual(sweep.entries[12]?.frame, WindowFrame(x: 100, y: 100, w: 640, h: 480))
        XCTAssertEqual(sweep.entries[13]?.frame, last)
        XCTAssertNil(sweep.entries[14])
        XCTAssertTrue(sweep.unresolved.isEmpty)
    }

    // MARK: - Reconcile

    func testReconcileVerifiesAnElidedTitleByWindowNumber() {
        let elided = "Domains | Registrations | Tidel…ine.dev's Account | Cloudflare"
        let whole = "Domains | Registrations | Tideline Studio's tideline.dev's Account | Cloudflare - Google Chrome - Work"
        var entries: [UInt32: WindowEntry] = [134002: entry(134002, pid: 40, title: elided)]
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in
            [134002: DesktopModel.AXWindow(title: whole, frame: nil)]
        }
        XCTAssertEqual(entries[134002]?.axVerified, true)
        XCTAssertEqual(entries[134002]?.axListed, true)
        XCTAssertEqual(entries[134002]?.fullTitle, whole)
        XCTAssertEqual(entries[134002]?.titleContains("Google Chrome"), true)
    }

    func testReconcileUnverifiesAWindowAXDoesntList() {
        var entries: [UInt32: WindowEntry] = [
            1: entry(1, pid: 40, title: "Inbox"),
            2: entry(2, pid: 40, title: "", frame: WindowFrame(x: 0, y: 0, w: 400, h: 300)),
        ]
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in
            [1: DesktopModel.AXWindow(title: "Inbox", frame: nil)]
        }
        XCTAssertEqual(entries[1]?.axVerified, true)
        XCTAssertEqual(entries[2]?.axVerified, false)
    }

    func testReconcileAsksOnlyAboutShowingDesktopsAndLeavesOthersAlone() {
        var entries: [UInt32: WindowEntry] = [
            1: entry(1, pid: 40, title: "Here", spaceIds: [1]),
            2: entry(2, pid: 40, title: "There", spaceIds: [4], isOnScreen: false),
            3: entry(3, pid: 999, title: "Lattices", spaceIds: [1]),
        ]
        var asked: [Int32: Set<UInt32>] = [:]
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { pid, candidates in
            asked[pid] = Set(candidates.keys)
            return [:]
        }
        XCTAssertEqual(asked, [40: [1]])
        XCTAssertEqual(entries[1]?.axVerified, false)
        XCTAssertEqual(entries[2]?.axVerified, true)
        XCTAssertEqual(entries[2]?.axListed, false)
        XCTAssertEqual(entries[3]?.axVerified, true)
    }

    func testReconcileLeavesAHiddenAppAloneWhenAXListsNothing() {
        var hidden = entry(1, pid: 20, title: "Calculator", isOnScreen: false)
        hidden.appHidden = true
        var entries: [UInt32: WindowEntry] = [1: hidden]
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in [:] }
        XCTAssertEqual(entries[1]?.axVerified, true)

        // AX lists the hidden app's other windows: this one isn't among them.
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in
            [77: DesktopModel.AXWindow(title: "Other", frame: nil)]
        }
        XCTAssertEqual(entries[1]?.axVerified, false)
    }

    func testReconcileLeavesWindowsAloneWhenAXDoesntAnswer() {
        var entries: [UInt32: WindowEntry] = [1: entry(1, pid: 40)]
        _ = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in nil }
        XCTAssertEqual(entries[1]?.axVerified, true)
    }

    func testReconcileReturnsAXFrames() {
        var entries: [UInt32: WindowEntry] = [1: entry(1, pid: 40)]
        let frames = DesktopModel.reconcile(&entries, current: [1], me: 999) { _, _ in
            [1: DesktopModel.AXWindow(title: "Doc", frame: CGRect(x: 1, y: 2, width: 300, height: 200))]
        }
        XCTAssertEqual(frames, [1: CGRect(x: 1, y: 2, width: 300, height: 200)])
    }

    func testCarriesAWholeTitleWhileTheCGTitleHolds() {
        var entries: [UInt32: WindowEntry] = [
            1: entry(1, title: "Long…title", spaceIds: [4], isOnScreen: false),
            2: entry(2, title: "Changed", spaceIds: [4], isOnScreen: false),
        ]
        DesktopModel.carryFullTitles(&entries, known: [
            1: (cg: "Long…title", ax: "Long and whole title"),
            2: (cg: "Before", ax: "Before, whole"),
        ])
        XCTAssertEqual(entries[1]?.fullTitle, "Long and whole title")
        XCTAssertNil(entries[2]?.fullTitle)
    }

    // MARK: - Proxies

    func testDropsAnUntitledStandInOverAnotherAppsWindow() {
        let frame = WindowFrame(x: 1354, y: 409, w: 736, h: 625)
        var entries: [UInt32: WindowEntry] = [
            1: entry(1, pid: 50, title: "Login Items", frame: frame),
            2: entry(2, pid: 51, title: "", frame: WindowFrame(x: 1355, y: 409, w: 736, h: 624), spaceIds: []),
            // Same app: a window of its own, not a stand-in.
            3: entry(3, pid: 50, title: "", frame: frame, spaceIds: []),
            // A regular app's window with a Space stays.
            4: entry(4, pid: 52, title: "", frame: frame, spaceIds: [1]),
            // Elsewhere: stays.
            5: entry(5, pid: 53, title: "", frame: WindowFrame(x: 0, y: 0, w: 736, h: 625), spaceIds: []),
        ]
        DesktopModel.dropProxies(&entries, facts: [51: .init(isRegular: false), 52: .init(isRegular: true)])
        XCTAssertEqual(Set(entries.keys), [1, 3, 4, 5])

        // An accessory app's stand-in drops even with a Space.
        entries[6] = entry(6, pid: 54, title: "", frame: frame, spaceIds: [1])
        DesktopModel.dropProxies(&entries, facts: [54: .init(isRegular: false)])
        XCTAssertNil(entries[6])
    }

    func testAnUnverifiedWindowIsNoOwner() {
        let frame = WindowFrame(x: 0, y: 0, w: 736, h: 625)
        var owner = entry(1, pid: 50, title: "Doc", frame: frame)
        owner.axVerified = false
        var entries: [UInt32: WindowEntry] = [1: owner, 2: entry(2, pid: 51, title: "", frame: frame, spaceIds: [])]
        DesktopModel.dropProxies(&entries, facts: [:])
        XCTAssertNotNil(entries[2])
    }

    // MARK: - Content

    func testIsContent() {
        XCTAssertTrue(DesktopModel.isContent(entry(1)))
        // Untitled with a Space: only once AX has listed it.
        var listed = entry(1, title: "", spaceIds: [4])
        XCTAssertFalse(DesktopModel.isContent(listed))
        listed.axListed = true
        XCTAssertTrue(DesktopModel.isContent(listed))
        var nowhere = entry(1, title: "", spaceIds: [])
        nowhere.axListed = true
        XCTAssertFalse(DesktopModel.isContent(nowhere))
        XCTAssertFalse(DesktopModel.isContent(entry(1, frame: WindowFrame(x: 0, y: 0, w: 119, h: 600))))
        XCTAssertFalse(DesktopModel.isContent(entry(1, pid: getpid())))

        var unverified = entry(1)
        unverified.axVerified = false
        XCTAssertFalse(DesktopModel.isContent(unverified))

        var wholeTitleOnly = entry(1, title: "", spaceIds: [])
        wholeTitleOnly.fullTitle = "Untitled in CG"
        XCTAssertTrue(DesktopModel.isContent(wholeTitleOnly))

        var hidden = entry(1, isOnScreen: false)
        hidden.appHidden = true
        hidden.collapsed = true
        XCTAssertTrue(DesktopModel.isContent(hidden))
    }

    func testTitleContainsReadsBothTitles() {
        var window = entry(1, title: "Domains | Reg…ions")
        XCTAssertTrue(window.titleContains("domains"))
        XCTAssertFalse(window.titleContains("Google Chrome"))
        window.fullTitle = "Domains | Registrations - Google Chrome"
        XCTAssertTrue(window.titleContains("google chrome"))
    }
}
