import XCTest
@testable import Lattices

final class AppArrangementTargetTests: XCTestCase {
    private func window(_ id: UInt32, app: String = "Ghostty", pid: Int32 = 700,
                        bundle: String? = "com.mitchellh.ghostty", display: Int = 1,
                        visible: Bool = true, width: Double = 600) -> WindowEntry {
        WindowEntry(wid: id, app: app, pid: pid, title: "Window \(id)",
                    frame: WindowFrame(x: Double(display) * 1_000, y: 0, w: width, h: 400),
                    spaceIds: [1], isOnScreen: visible, latticesSession: nil,
                    zIndex: Int(id), bundleId: bundle)
    }

    private func display(_ entry: WindowEntry) -> UInt32? { UInt32(entry.frame.x / 1_000) }

    private func target(_ entries: [WindowEntry], anchor: WindowEntry? = nil) throws -> AppArrangementTarget {
        try XCTUnwrap(AppArrangementTarget.make(anchor: anchor ?? entries.first, windows: entries,
                                               displayName: "Studio Display", displayForWindow: display))
    }

    func testExactAppAndCurrentDisplayExcludeOtherTerminalsHiddenAndHelperWindows() throws {
        let entries = [window(3), window(1), window(2),
                       window(4, app: "iTerm2", pid: 701, bundle: "com.googlecode.iterm2"),
                       window(5, display: 2), window(6, visible: false), window(7, width: 64),
                       window(8, app: "Ghostty", pid: 702, bundle: "example.other")]
        let result = try target(entries)
        XCTAssertEqual(result.windowIDs, [1, 2, 3])
        XCTAssertEqual(result.title, "Arrange 3 Ghostty windows")
        XCTAssertEqual(result.displayID, 1)
    }

    func testBundleIdentityCanSpanProcessesButMissingBundleFallsBackToExactPID() throws {
        let primary = window(1)
        let sameBundle = window(2, pid: 701)
        XCTAssertEqual(try target([primary, sameBundle]).windowIDs, [1, 2])

        let unknown = window(3, bundle: nil)
        let sameProcess = window(4, bundle: nil)
        let sameName = window(5, pid: 702, bundle: nil)
        XCTAssertEqual(try target([unknown, sameProcess, sameName]).windowIDs, [3, 4])
    }

    func testCountIsActualAndSelectionIsNotTruncatedToThree() throws {
        let result = try target((1...5).map { window(UInt32($0)) })
        XCTAssertEqual(result.title, "Arrange 5 Ghostty windows")
        XCTAssertEqual(result.windowIDs.count, 5)
        XCTAssertTrue(result.matches("tile these three Ghostty windows"))
        XCTAssertEqual(result.result.title, "Arrange 5 Ghostty windows")
        XCTAssertEqual(try target([window(1)]).title, "Arrange 1 Ghostty window")
    }

    func testSearchFindsContextualActionWithoutTakingOverPlacementOrOtherAppCommands() throws {
        let result = try target([window(1), window(2), window(3)])
        for query in ["Ghostty", "ghost", "tile ghostty", "arrange", "arrange windows", "grid Ghostty"] {
            XCTAssertTrue(result.matches(query), query)
        }
        for query in ["", "/arrange", "tile ghostty left", "tile ghostty right", "arrange iTerm", "arrange everything", "quit Ghostty"] {
            XCTAssertFalse(result.matches(query), query)
        }
        let state = UnifiedCommandBarState(arrangementTarget: result)
        state.query = "tile ghostty"
        XCTAssertNil(state.nlMatch, "Exact arrangement commands must not fall through to the NL tiler")
        XCTAssertEqual(state.search.arrangementResults(for: "Ghostty").first?.arrangementTarget, result)
        XCTAssertTrue(state.search.arrangementResults(for: "iTerm").isEmpty)
    }

    func testStaleClosedMovedOrReusedIDsFailWithoutAddingNewWindows() throws {
        let original = [window(1), window(2), window(3)]
        let result = try target(original)
        XCTAssertTrue(result.isValid(in: original + [window(4)], displayForWindow: display))
        XCTAssertEqual(result.windowIDs, [1, 2, 3])
        XCTAssertFalse(result.isValid(in: Array(original.prefix(2)), displayForWindow: display))
        XCTAssertFalse(result.isValid(in: [window(1), window(2), window(3, display: 2)], displayForWindow: display))
        XCTAssertFalse(result.isValid(in: [window(1), window(2), window(3, pid: 900)], displayForWindow: display))
        XCTAssertFalse(result.isValid(in: [window(1), window(2), window(3, bundle: "example.other")], displayForWindow: display))
        XCTAssertFalse(result.isValid(in: [window(1), window(2), window(3, visible: false)], displayForWindow: display))
    }

    func testNoPlaceableAnchorProducesNoAction() {
        XCTAssertNil(AppArrangementTarget.make(anchor: nil, windows: [window(1)],
                                              displayName: "Test", displayForWindow: display))
        XCTAssertNil(AppArrangementTarget.make(anchor: window(1, visible: false), windows: [window(1)],
                                              displayName: "Test", displayForWindow: display))
    }
}
