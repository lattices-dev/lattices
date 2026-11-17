import AppKit
import XCTest
@testable import Lattices

final class SpaceCanvasWindowMovementTests: XCTestCase {
    func testFullMonitorOriginBecomesUsablePlacementWithoutResizing() throws {
        let plan = try SpaceCanvasWindowMovement.destination(normalizedOrigin: CGPoint(x: 0.9, y: -0.4),
            windowSize: CGSize(width: 400, height: 300),
            displayBounds: CGRect(x: -1000, y: -100, width: 1000, height: 800),
            usableBounds: CGRect(x: -1000, y: -76, width: 1000, height: 726))
        XCTAssertEqual(plan.frame, CGRect(x: -400, y: -76, width: 400, height: 300))
        let fractions = plan.placement.fractions
        XCTAssertEqual(fractions.0, 0.6, accuracy: 0.00001)
        XCTAssertEqual(fractions.1, 0)
        XCTAssertEqual(fractions.2, 0.4)
        XCTAssertEqual(fractions.3, 300.0 / 726, accuracy: 0.00001)
    }

    func testSameDesktopMoveTargetsCapturedWindowAndReportsObservedNormalizedFrame() throws {
        let fixture = MovementFixture()
        let result = try SpaceCanvasWindowMovement.execute(fixture.request(destination: 1), environment: fixture.environment()).get()
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests[0]["wid"]?.intValue, 42)
        XCTAssertEqual(fixture.targets[0].pid, 100)
        XCTAssertEqual(fixture.requests[0]["display"]?.intValue, 2)
        XCTAssertEqual(fixture.requests[0]["spaceId"]?.intValue, 1)
        XCTAssertEqual(result.windowID, 42)
        XCTAssertEqual(result.spaceID, 1)
        XCTAssertEqual(result.actualFrame.width, 400, accuracy: 0.00001)
        XCTAssertEqual(result.actualFrame.height, 300, accuracy: 0.00001)
        XCTAssertEqual(result.normalizedFrame.minX, 0.3, accuracy: 0.00001)
        XCTAssertEqual(result.normalizedFrame.minY, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result.normalizedFrame.width, 0.4, accuracy: 0.00001)
        XCTAssertEqual(result.normalizedFrame.height, 0.375, accuracy: 0.00001)
        XCTAssertTrue(fixture.restoreRequests.isEmpty)
    }

    func testInactiveSourceAndDestinationPreserveOriginalShowingDesktop() throws {
        let fixture = MovementFixture()
        fixture.leaveViewingDestination = true
        let result = try SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()).get()
        XCTAssertEqual(fixture.targets[0].spaceIds, [1])
        XCTAssertEqual(result.spaceID, 2)
        XCTAssertEqual(fixture.activeSpace, 3)
        XCTAssertEqual(fixture.restoreRequests, [3])
    }

    func testStaleIdentityAndMembershipDoNotMutate() {
        let fixture = MovementFixture()
        let reused = SpaceCanvasWindowMovement.Request(windowID: 42, pid: 101, sourceSpaceID: 1,
            destinationSpaceID: 2, normalizedOrigin: .zero)
        assertFailure(SpaceCanvasWindowMovement.execute(reused, environment: fixture.environment()))
        fixture.memberships = [2]
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()))
        fixture.memberships = [1, 2]
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()))
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testDifferentDisplayDestinationIsRejectedBeforeMutation() {
        let fixture = MovementFixture()
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(destination: 99), environment: fixture.environment()))
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testNominalSuccessWithoutVerificationCannotReportMoved() {
        let fixture = MovementFixture()
        fixture.verified = false
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()))
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testVerifiedReceiptStillNeedsMatchingLiveFrameAndMembership() {
        let wrongFrame = MovementFixture()
        wrongFrame.frameOffset = 50
        assertFailure(SpaceCanvasWindowMovement.execute(wrongFrame.request(), environment: wrongFrame.environment()))
        let wrongSpace = MovementFixture()
        wrongSpace.leaveWindowOnSource = true
        assertFailure(SpaceCanvasWindowMovement.execute(wrongSpace.request(), environment: wrongSpace.environment()))
    }

    func testFailedActiveDesktopRestorationCannotReportSuccess() {
        let fixture = MovementFixture()
        fixture.leaveViewingDestination = true
        fixture.canRestore = false
        let result = SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment())
        if case .failure(let failure) = result {
            XCTAssertTrue(failure.message.contains("restore your original desktop"))
        } else { XCTFail("A failed restoration must not report success") }
        XCTAssertEqual(fixture.restoreRequests, [3])
    }

    func testThrownRelocationStillRestoresShowingDesktop() {
        let fixture = MovementFixture()
        fixture.leaveViewingDestination = true
        fixture.throwAfterMove = true
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()))
        XCTAssertEqual(fixture.activeSpace, 3)
        XCTAssertEqual(fixture.restoreRequests, [3])
    }

    func testOversizedAndNonfiniteGeometryNeverResizeOrExecute() {
        let fixture = MovementFixture()
        fixture.frame.size.width = 1200
        assertFailure(SpaceCanvasWindowMovement.execute(fixture.request(), environment: fixture.environment()))
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(fixture.frame.width, 1200)
        XCTAssertThrowsError(try SpaceCanvasWindowMovement.destination(
            normalizedOrigin: CGPoint(x: CGFloat.nan, y: 0), windowSize: CGSize(width: 400, height: 300),
            displayBounds: fixture.bounds, usableBounds: fixture.usable))
    }

    private func assertFailure(_ result: Result<SpaceCanvasWindowMovement.Outcome, SpaceCanvasWindowMovement.Failure>,
                               file: StaticString = #filePath, line: UInt = #line) {
        if case .success = result { XCTFail("Expected an independently verified failure", file: file, line: line) }
    }
}

private final class MovementFixture {
    let bounds = CGRect(x: -1000, y: -100, width: 1000, height: 800)
    let usable = CGRect(x: -1000, y: -76, width: 1000, height: 726)
    var frame = CGRect(x: -900, y: 0, width: 400, height: 300)
    var memberships = [1]
    var activeSpace = 3
    var requests: [JSON] = []
    var targets: [WindowEntry] = []
    var restoreRequests: [Int] = []
    var leaveViewingDestination = false
    var canRestore = true
    var verified = true
    var frameOffset: CGFloat = 0
    var leaveWindowOnSource = false
    var throwAfterMove = false

    func request(destination: Int = 2) -> SpaceCanvasWindowMovement.Request {
        .init(windowID: 42, pid: 100, sourceSpaceID: 1, destinationSpaceID: destination,
            normalizedOrigin: CGPoint(x: 0.3, y: 0.2))
    }

    func environment() -> SpaceCanvasWindowMovement.Environment {
        .init(display: { [self] in
            .init(id: "display-uuid", index: 2, spaceIDs: [1, 2, 3], currentSpaceID: activeSpace,
                bounds: bounds, usableBounds: usable)
        }, window: { [self] wid in
            guard wid == 42 else { return nil }
            return WindowEntry(wid: 42, app: "Editor", pid: 100, title: "Captured window",
                frame: WindowFrame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
                spaceIds: memberships, isOnScreen: memberships == [activeSpace], latticesSession: nil)
        }, relocate: { [self] params, target in
            requests.append(params)
            targets.append(target)
            let placement = try XCTUnwrap(PlacementSpec(json: params["placement"]))
            let fractions = placement.fractions
            frame = CGRect(x: usable.minX + usable.width * fractions.0 + frameOffset,
                y: usable.minY + usable.height * fractions.1,
                width: usable.width * fractions.2, height: usable.height * fractions.3)
            let destination = try XCTUnwrap(params["spaceId"]?.intValue)
            if !leaveWindowOnSource { memberships = [destination] }
            if leaveViewingDestination { activeSpace = destination }
            if throwAfterMove { throw SpaceCanvasWindowMovement.Failure(message: "Runtime failed") }
            return .object([
                "status": .string("ok"), "verified": .bool(verified),
                "wid": .int(42), "pid": .int(100),
                "verifiedFrame": .bool(true), "verifiedDisplay": .bool(true), "verifiedSpace": .bool(true),
                "verificationTolerance": .int(6),
            ])
        }, restoreSpace: { [self] space in
            restoreRequests.append(space)
            if canRestore { activeSpace = space }
            return canRestore
        })
    }
}
