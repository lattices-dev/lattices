import AppKit
import XCTest
@testable import Lattices

/// Launcher handoff validation is independent of native window movement. These
/// tests use fixtures only; they never present a panel or touch the desktop.
final class MotionArrangementRequestTests: XCTestCase {
    private func window(_ wid: UInt32, title: String = "Terminal", onScreen: Bool = true,
                        width: Double = 800, pid: Int32? = nil) -> WindowEntry {
        WindowEntry(wid: wid, app: "Ghostty",
                    pid: pid ?? ProcessInfo.processInfo.processIdentifier + 1000 + Int32(wid),
                    title: title, frame: WindowFrame(x: 0, y: 0, w: width, h: 600),
                    spaceIds: [1], isOnScreen: onScreen, latticesSession: nil)
    }

    func testKeepsRequestedOrderAndDoesNotAddOtherSameAppWindows() throws {
        let request = MotionArrangementRequest(windowIDs: [3, 1, 2], displayID: 17)
        let candidates = [window(1), window(2), window(3), window(4)]

        let result = try XCTUnwrap(request.resolve(in: candidates) { _ in 17 })

        XCTAssertEqual(result.map(\.wid), [3, 1, 2])
    }

    func testMissingWindowRejectsWholeHandoffRatherThanKeepingSurvivors() {
        let request = MotionArrangementRequest(windowIDs: [1, 9, 2], displayID: 17)

        XCTAssertNil(request.resolve(in: [window(1), window(2), window(3)]) { _ in 17 })
    }

    func testMovedWindowRejectsWholeHandoffRatherThanChangingItsDisplay() {
        let request = MotionArrangementRequest(windowIDs: [1, 2, 3], displayID: 17)

        XCTAssertNil(request.resolve(in: [window(1), window(2), window(3)]) {
            $0.wid == 2 ? 29 : 17
        })
        XCTAssertNil(request.resolve(in: [window(1), window(2), window(3)]) { _ in nil })
    }

    func testEmptyAndDuplicateRequestsAreRejected() {
        let candidates = [window(1), window(2)]

        XCTAssertNil(MotionArrangementRequest(windowIDs: [], displayID: 17)
            .resolve(in: candidates) { _ in 17 })
        XCTAssertNil(MotionArrangementRequest(windowIDs: [1, 2, 1], displayID: 17)
            .resolve(in: candidates) { _ in 17 })
    }

    func testHandoffUsesTheSamePlaceableEligibilityAsTheLauncher() {
        let request = MotionArrangementRequest(windowIDs: [1, 2], displayID: 17)
        let ineligible = [
            window(2, title: ""),
            window(2, onScreen: false),
            window(2, width: 50),
            window(2, pid: ProcessInfo.processInfo.processIdentifier),
        ]

        for candidate in ineligible {
            XCTAssertNil(request.resolve(in: [window(1), candidate]) { _ in 17 })
        }
    }

    func testSameTargetsMayRetainTheirOwnPreviewAndStagedChanges() {
        XCTAssertTrue(MotionArrangementRequest.canRetainChanges(
            for: [3, 1, 2], movedWindowIDs: [1, 2], stagedWindowIDs: [3]))
        XCTAssertTrue(MotionArrangementRequest.canRetainChanges(
            for: [3, 1, 2], movedWindowIDs: [], stagedWindowIDs: []))
    }

    func testUnrelatedStagedChangesRejectNarrowedHandoff() {
        XCTAssertFalse(MotionArrangementRequest.canRetainChanges(
            for: [3, 1, 2], movedWindowIDs: [], stagedWindowIDs: [4]))
    }

    func testUnrelatedPreviewedMovesRejectNarrowedHandoff() {
        XCTAssertFalse(MotionArrangementRequest.canRetainChanges(
            for: [3, 1, 2], movedWindowIDs: [1, 4], stagedWindowIDs: []))
    }
}
