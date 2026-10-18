import CoreGraphics
import XCTest
@testable import Lattices

final class WindowRelocationTests: XCTestCase {
    private final class Desktop {
        let physicalFrame = CGRect(x: 0, y: 0, width: 1720, height: 1440)
        let virtualFrame = CGRect(x: 3440, y: 0, width: 720, height: 900)
        var displays = [
            WindowRelocation.Display(id: "physical", index: 0, currentSpaceId: 3, spaceIds: [1, 3, 4]),
            WindowRelocation.Display(id: "virtual", index: 2, currentSpaceId: 2377, spaceIds: [1956, 2377]),
        ]
        var state: WindowRelocation.Snapshot
        var operations: [String] = []
        var refusedSpaces: Set<Int> = []
        var ignoreSpace = false
        var ignoreFrame = false
        var preserveWrongMembership = false
        var transferredSpaceIds: [Int]?
        var transientStagingFrame = false
        var stagingSettled = false

        init(sourceSpace: Int = 1956) {
            state = .init(frame: CGRect(x: 3440, y: 0, width: 720, height: 900), displayId: "virtual", spaceIds: [sourceSpace])
        }

        var destination: WindowRelocation.Destination {
            .init(displayId: "physical", spaceId: 3, frame: physicalFrame)
        }

        var environment: WindowRelocation.Environment {
            .init(
                displays: { self.displays },
                snapshot: { self.state },
                moveSpace: { space in
                    self.operations.append("space:\(space)")
                    if self.refusedSpaces.contains(space) { return "simulated refusal" }
                    if self.ignoreSpace { return nil }
                    guard let display = self.displays.first(where: { $0.spaceIds.contains(space) }),
                          display.id == self.state.displayId else { return "cross-display carry refused" }
                    self.state = .init(frame: self.state.frame, displayId: display.id, spaceIds: [space])
                    if self.transientStagingFrame && space == 2377 {
                        self.state = .init(frame: CGRect(x: 3501, y: 66, width: 659, height: 824), displayId: display.id, spaceIds: [space])
                    }
                    return nil
                },
                moveFrame: { frame in
                    self.operations.append("frame:\(Int(frame.minX))")
                    guard !self.ignoreFrame,
                          let source = self.displays.first(where: { $0.id == self.state.displayId }),
                          self.state.spaceIds == [source.currentSpaceId] else { return }
                    let target = self.displays.first(where: { $0.id == (frame.minX >= 3440 ? "virtual" : "physical") })!
                    self.state = .init(frame: frame, displayId: target.id,
                                       spaceIds: self.preserveWrongMembership ? self.state.spaceIds :
                                        (target.id == "physical" ? self.transferredSpaceIds : nil) ?? [target.currentSpaceId])
                },
                wait: { predicate in
                    // Model Mission Control having committed membership while
                    // the CG window still has thumbnail geometry.
                    if self.transientStagingFrame && self.state.spaceIds == [2377] && !predicate(self.state) {
                        self.state = .init(frame: self.virtualFrame, displayId: "virtual", spaceIds: [2377])
                        self.stagingSettled = true
                    }
                    return self.state
                }
            )
        }

        func move(to destination: WindowRelocation.Destination? = nil) -> WindowRelocation.Result {
            WindowRelocation.execute(from: state, to: destination ?? self.destination, tolerance: 6, environment: environment)
        }
    }

    func testInactiveVirtualDesktopStagesBeforeMovingToPhysicalDesktopTwo() {
        let desktop = Desktop()
        let result = desktop.move()
        XCTAssertTrue(result.verified)
        XCTAssertEqual(desktop.operations, ["space:2377", "frame:0"])
        XCTAssertEqual(result.after.displayId, "physical")
        XCTAssertEqual(result.after.spaceIds, [3], "Physical Desktop 2 must not be confused with virtual Desktop 2 (1956)")
        XCTAssertEqual(result.after.frame, desktop.physicalFrame)
    }

    func testInactiveDestinationMovesAfterDisplayTransfer() {
        let desktop = Desktop()
        let destination = WindowRelocation.Destination(displayId: "physical", spaceId: 4, frame: desktop.physicalFrame)
        let result = desktop.move(to: destination)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(desktop.operations, ["space:2377", "frame:0", "space:4"])
    }

    func testTransferLandingOnAnotherDestinationDesktopCompletesRequestedMove() {
        let desktop = Desktop(sourceSpace: 2377)
        // macOS can retain the app's remembered desktop on the new monitor.
        desktop.transferredSpaceIds = [4]
        let result = desktop.move()
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.rollbackAttempted)
        XCTAssertEqual(desktop.operations, ["frame:0", "space:3"])
        XCTAssertEqual(result.after.spaceIds, [3])
        XCTAssertEqual(result.after.frame, desktop.physicalFrame)
    }

    func testTransferLandingOnRequestedInactiveDesktopNeedsNoExtraCarry() {
        let desktop = Desktop(sourceSpace: 2377)
        desktop.transferredSpaceIds = [4]
        let result = desktop.move(to: .init(displayId: "physical", spaceId: 4, frame: desktop.physicalFrame))
        XCTAssertTrue(result.verified)
        XCTAssertEqual(desktop.operations, ["frame:0"])
    }

    func testRefusedCarryAfterUnexpectedLandingReportsFailedRollback() {
        let desktop = Desktop(sourceSpace: 2377)
        desktop.transferredSpaceIds = [4]
        desktop.refusedSpaces = [3]
        let result = desktop.move(to: .init(displayId: "physical", spaceId: 3, frame: desktop.physicalFrame))
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.rollbackAttempted)
        // Restoring geometry also needs desktop 3 staging, which was refused.
        XCTAssertFalse(result.rollbackVerified)
        XCTAssertEqual(result.after.spaceIds, [4])
        XCTAssertTrue(result.failure?.contains("Destination desktop move failed") == true)
    }

    func testUnknownOrMultipleMembershipAfterTransferIsNeverAccepted() {
        for spaces in [[9999], [3, 4], []] {
            let desktop = Desktop(sourceSpace: 2377)
            desktop.transferredSpaceIds = spaces
            let result = desktop.move()
            XCTAssertFalse(result.verified)
            XCTAssertFalse(result.rollbackVerified)
            XCTAssertEqual(desktop.operations, ["frame:0"])
        }
    }

    func testSourceStagingWaitsForWindowGeometryAfterMissionControl() {
        let desktop = Desktop()
        desktop.transientStagingFrame = true
        let result = desktop.move()
        XCTAssertTrue(result.verified)
        XCTAssertTrue(desktop.stagingSettled)
        XCTAssertEqual(result.after.frame, desktop.physicalFrame)
    }

    func testActiveSourceNeedsNoStaging() {
        let desktop = Desktop(sourceSpace: 2377)
        XCTAssertTrue(desktop.move().verified)
        XCTAssertEqual(desktop.operations, ["frame:0"])
    }

    func testSameDisplayDesktopMoveDoesNotTouchGeometry() {
        let desktop = Desktop()
        let result = desktop.move(to: .init(displayId: "virtual", spaceId: 2377, frame: desktop.virtualFrame))
        XCTAssertTrue(result.verified)
        XCTAssertEqual(desktop.operations, ["space:2377"])
    }

    func testStagingRefusalStopsBeforeFrameMutation() {
        let desktop = Desktop()
        desktop.refusedSpaces = [2377]
        let result = desktop.move()
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.rollbackAttempted)
        XCTAssertTrue(result.rollbackVerified, "The original state is confirmed unchanged")
        XCTAssertEqual(desktop.operations, ["space:2377"])
        XCTAssertEqual(result.after.spaceIds, [1956])
    }

    func testUnverifiedCarryDoesNotBecomeSuccess() {
        let desktop = Desktop()
        desktop.ignoreSpace = true
        let result = desktop.move()
        XCTAssertFalse(result.verified)
        XCTAssertEqual(desktop.operations, ["space:2377"])
        XCTAssertEqual(result.after.spaceIds, [1956])
    }

    func testRefusedGeometryRollsBackStagingToOriginalDesktop() {
        let desktop = Desktop()
        desktop.ignoreFrame = true
        let result = desktop.move()
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.rollbackAttempted)
        XCTAssertTrue(result.rollbackVerified)
        XCTAssertEqual(desktop.operations, ["space:2377", "frame:0", "space:1956"])
        XCTAssertEqual(result.after.spaceIds, [1956])
        XCTAssertEqual(result.after.frame, desktop.virtualFrame)
    }

    func testRefusedDestinationDesktopRestoresOriginalDisplayAndDesktop() {
        let desktop = Desktop()
        desktop.refusedSpaces = [4]
        let result = desktop.move(to: .init(displayId: "physical", spaceId: 4, frame: desktop.physicalFrame))
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.rollbackAttempted)
        XCTAssertTrue(result.rollbackVerified)
        XCTAssertEqual(desktop.operations, ["space:2377", "frame:0", "space:4", "frame:3440", "space:1956"])
        XCTAssertEqual(result.after.spaceIds, [1956])
        XCTAssertEqual(result.after.displayId, "virtual")
    }

    func testFrameOnPhysicalDisplayWithVirtualMembershipIsNeverSuccess() {
        let desktop = Desktop(sourceSpace: 2377)
        desktop.preserveWrongMembership = true
        let result = desktop.move()
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.rollbackVerified, "An inconsistent partial transfer must remain visible in the receipt")
        XCTAssertEqual(result.after.frame, desktop.physicalFrame)
        XCTAssertEqual(result.after.spaceIds, [2377])
        XCTAssertNotNil(result.failure)
    }

    func testMismatchedDestinationDisplayAndDesktopIsRejectedBeforeMutation() {
        let desktop = Desktop()
        let result = desktop.move(to: .init(displayId: "physical", spaceId: 1956, frame: desktop.physicalFrame))
        XCTAssertFalse(result.verified)
        XCTAssertEqual(desktop.operations, [])
    }

    func testFullScreenActiveDesktopIsRejectedBeforeMutation() {
        let desktop = Desktop()
        desktop.displays[0] = .init(id: "physical", index: 0, currentSpaceId: 9999, spaceIds: [1, 3, 4])
        let result = desktop.move()
        XCTAssertFalse(result.verified)
        XCTAssertEqual(desktop.operations, [])
    }
}
