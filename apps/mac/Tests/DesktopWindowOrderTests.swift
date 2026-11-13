import CoreGraphics
import XCTest
@testable import Lattices

final class DesktopWindowOrderTests: XCTestCase {
    func testVisibleOrderOverridesAllWindowOrderAndReachesInventory() {
        let all = [row(559), row(526), row(5657)]
        let onScreen = [row(5657), row(559), row(526)]
        let ordered = DesktopModel.orderedWindowList(all: all, onScreen: onScreen)
        let sweep = DesktopModel.sweep(ordered, sources: sources(), recoverCollapsed: false)

        XCTAssertEqual(ids(ordered), [5657, 559, 526])
        XCTAssertEqual(sweep.entries[5657]?.zIndex, 0)
        XCTAssertEqual(sweep.entries[559]?.zIndex, 1)
        XCTAssertEqual(sweep.entries[526]?.zIndex, 2)
    }

    func testOffscreenWindowsKeepTheirRelativeOrderAndSpaceMembership() {
        let all = [row(1, onScreen: false), row(2), row(3, onScreen: false),
                   row(4), row(5, onScreen: false)]
        let ordered = DesktopModel.orderedWindowList(all: all, onScreen: [row(4), row(2)])
        let sweep = DesktopModel.sweep(ordered, sources: sources(), recoverCollapsed: false)

        XCTAssertEqual(ids(ordered), [4, 2, 1, 3, 5])
        XCTAssertEqual(sweep.entries.count, 5)
        for wid in [UInt32(1), 3, 5] {
            XCTAssertEqual(sweep.entries[wid]?.isOnScreen, false)
            XCTAssertEqual(sweep.entries[wid]?.spaceIds, [Int(wid)])
        }
    }

    func testNewOnscreenWindowsAreIncludedOnceWithLatestMetadata() {
        var fresh = row(2)
        fresh[kCGWindowName as String] = "Raised"
        fresh[kCGWindowBounds as String] = CGRect(x: 200, y: 300, width: 640, height: 480).dictionaryRepresentation
        let ordered = DesktopModel.orderedWindowList(
            all: [row(1, onScreen: false), row(2, onScreen: false), row(2)],
            onScreen: [fresh, row(3), row(3)]
        )
        let sweep = DesktopModel.sweep(ordered, sources: sources(), recoverCollapsed: false)

        XCTAssertEqual(ids(ordered), [2, 3, 1])
        XCTAssertEqual(sweep.entries[2]?.title, "Raised")
        XCTAssertEqual(sweep.entries[2]?.isOnScreen, true)
        XCTAssertEqual(sweep.entries[2]?.frame, WindowFrame(x: 200, y: 300, w: 640, h: 480))
    }

    func testUnavailableOrEmptyOnscreenQueryKeepsCompleteInventory() {
        let all = [row(3), row(1, onScreen: false), row(2)]
        XCTAssertEqual(ids(DesktopModel.orderedWindowList(all: all, onScreen: nil)), [3, 1, 2])
        XCTAssertEqual(ids(DesktopModel.orderedWindowList(all: all, onScreen: [])), [3, 1, 2])
    }

    private func row(_ wid: UInt32, onScreen: Bool = true) -> [String: Any] {
        [
            kCGWindowNumber as String: wid,
            kCGWindowOwnerName as String: "Fixture",
            kCGWindowOwnerPID as String: Int32(100),
            kCGWindowName as String: "Window \(wid)",
            kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: onScreen,
        ]
    }

    private func ids(_ list: [[String: Any]]) -> [UInt32] {
        list.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    }

    private func sources() -> DesktopModel.InventorySources {
        DesktopModel.InventorySources(
            appFacts: { _ in DesktopModel.AppFacts() },
            spaces: { [Int($0)] },
            trueBounds: { _ in nil }
        )
    }
}
