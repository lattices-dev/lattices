import XCTest
@testable import Lattices

final class SystemSpaceChangeFeedbackTests: XCTestCase {
    private func display(_ current: Int, fullscreen: [Int] = [], id: String = "A", index: Int = 0) -> DisplaySpaces {
        DisplaySpaces(displayIndex: index, displayId: id,
            spaces: [1, 2, 3].enumerated().map { SpaceInfo(id: $0.element, index: $0.offset + 1, display: index, isCurrent: $0.element == current) },
            currentSpaceId: current, orderedSpaceIds: [1, 2, 3] + fullscreen)
    }

    func testNativeFullScreenRemovalDoesNotShowDesktopNavigation() {
        let policy = SystemSpaceChangeFeedback()
        policy.seed([display(90, fullscreen: [90])])
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .fullScreenReturn)
        XCTAssertEqual(policy.observe([display(2)], activeSpaceID: 2), .show)
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .show)
    }

    func testSwipeAwayFromExistingFullScreenAndDesktopSwitchStillShow() {
        let policy = SystemSpaceChangeFeedback()
        policy.seed([display(90, fullscreen: [90])])
        XCTAssertEqual(policy.observe([display(1, fullscreen: [90])], activeSpaceID: 1), .show)
        XCTAssertEqual(policy.observe([display(2, fullscreen: [90])], activeSpaceID: 2), .show)
        XCTAssertEqual(policy.observe([display(90, fullscreen: [90])], activeSpaceID: 90), .none)
    }

    func testViewerNotificationBeforeCompletionConsumesExactExit() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        policy.seed([source])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        // Native topology may still contain the retiring fullscreen Space.
        XCTAssertEqual(policy.observe([display(1, fullscreen: [90])], activeSpaceID: 1), .fullScreenReturn)
        policy.completeFullScreenExit(token, display: display(1))
        XCTAssertEqual(policy.observe([display(2)], activeSpaceID: 2), .show)
    }

    func testViewerCompletionBeforeNotificationRecognizesTheReturn() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        policy.seed([source])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        policy.completeFullScreenExit(token, display: display(1))
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .fullScreenReturn)
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .none)
        XCTAssertEqual(policy.observe([display(2)], activeSpaceID: 2), .show)
    }

    func testUnmatchedReturnDoesNotHideALaterRealSwitchOrRevisit() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        policy.seed([source])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        policy.completeFullScreenExit(token, display: display(1))
        XCTAssertEqual(policy.observe([display(2)], activeSpaceID: 2), .show)
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .show)
    }

    func testEarlyCompletionWithUnsettledTopologyKeepsTheExactMarker() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        policy.seed([source])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        policy.completeFullScreenExit(token, display: source)
        XCTAssertEqual(policy.observe([display(1, fullscreen: [90])], activeSpaceID: 1), .fullScreenReturn)
    }

    func testFailedExitLeavesSwipeFeedbackAvailable() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        policy.seed([source])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        policy.cancelFullScreenExit(token)
        XCTAssertEqual(policy.observe([display(1, fullscreen: [90])], activeSpaceID: 1), .show)
    }

    func testOtherDisplayNavigationAndDisplayReorderingDoNotConsumeAnExit() throws {
        let policy = SystemSpaceChangeFeedback()
        let source = display(90, fullscreen: [90])
        func other(_ current: Int) -> DisplaySpaces {
            DisplaySpaces(displayIndex: 1, displayId: "B",
                spaces: [11, 12].enumerated().map { SpaceInfo(id: $0.element, index: $0.offset + 1, display: 1, isCurrent: $0.element == current) },
                currentSpaceId: current, orderedSpaceIds: [11, 12])
        }
        policy.seed([source, other(11)])
        let token = try XCTUnwrap(policy.beginFullScreenExit(source))
        XCTAssertEqual(policy.observe([other(12), source], activeSpaceID: 12), .show)
        policy.completeFullScreenExit(token, display: display(1))
        XCTAssertEqual(policy.observe([other(12), display(1)], activeSpaceID: 1), .fullScreenReturn)
        XCTAssertEqual(policy.observe([display(2), other(12)], activeSpaceID: 2), .show)
    }

    func testUnknownSpaceAndEmptyReadsAreNotClassifiedAsFullScreen() {
        let policy = SystemSpaceChangeFeedback()
        policy.seed([display(1)])
        XCTAssertNil(policy.beginFullScreenExit(display(99)))
        XCTAssertNil(policy.beginFullScreenExit(display(1)))
        XCTAssertEqual(policy.observe([], activeSpaceID: 0), .none)
        XCTAssertEqual(policy.observe([display(2)], activeSpaceID: 2), .show)
    }

    func testObservingProgrammaticLandingAdvancesTheNextDesktopBaseline() {
        let policy = SystemSpaceChangeFeedback()
        policy.seed([display(1)])
        _ = policy.observe([display(2)], activeSpaceID: 2) // caller skips its duplicate bezel
        XCTAssertEqual(policy.observe([display(1)], activeSpaceID: 1), .show)
    }
}
