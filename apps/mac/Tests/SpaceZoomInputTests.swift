import XCTest
import CoreGraphics
@testable import Lattices

final class SpaceZoomInputTests: XCTestCase {
    func testBothVerticalArrowsOpenCanvasThenControlZoomDirection() {
        for key: Int64 in [125, 126] {
            XCTAssertTrue(SpaceZoomKey.zoomsOut(keyCode: key, canvas: false))
        }
        XCTAssertTrue(SpaceZoomKey.zoomsOut(keyCode: 125, canvas: true))
        XCTAssertFalse(SpaceZoomKey.zoomsOut(keyCode: 126, canvas: true))
        for canvas in [false, true] {
            XCTAssertTrue(SpaceZoomKey.zoomsOut(keyCode: 27, canvas: canvas))
            XCTAssertFalse(SpaceZoomKey.zoomsOut(keyCode: 24, canvas: canvas))
        }
    }

    func testRightPullRequiresDeliberateUpwardMovementAndOnlyFiresOnce() {
        var pull = SpaceCanvasPull()
        XCTAssertFalse(pull.update(delta: CGPoint(x: 2, y: -20), flags: []))
        XCTAssertTrue(pull.update(delta: CGPoint(x: 2, y: -44), flags: []))
        XCTAssertFalse(pull.update(delta: CGPoint(x: 0, y: -90), flags: []))
        XCTAssertTrue(pull.opened)
    }

    func testOtherFirstDirectionsAndModifierChordsCannotTurnIntoCanvasPull() {
        for delta in [CGPoint(x: 50, y: -5), CGPoint(x: 0, y: 50), CGPoint(x: 44, y: -44)] {
            var pull = SpaceCanvasPull()
            XCTAssertFalse(pull.update(delta: delta, flags: []))
            XCTAssertFalse(pull.update(delta: CGPoint(x: 0, y: -100), flags: []))
            XCTAssertTrue(pull.rejected)
        }
        XCTAssertFalse(SpaceCanvasPull.accepts(button: 2, flags: []))
        for flag: CGEventFlags in [.maskControl, .maskAlternate, .maskCommand, .maskShift] {
            XCTAssertFalse(SpaceCanvasPull.accepts(button: 1, flags: flag))
            var pull = SpaceCanvasPull()
            XCTAssertFalse(pull.update(delta: CGPoint(x: 0, y: -60), flags: flag))
            XCTAssertFalse(pull.update(delta: CGPoint(x: 0, y: -80), flags: []))
        }
    }

    func testCanvasHandoffConsumesRemainingGestureAndMomentum() {
        var scroll = SpaceZoomScroll()
        XCTAssertEqual(scroll.step(delta: -30, precise: true, began: true, momentum: false, time: 0), true)
        XCTAssertTrue(scroll.consumeTail(began: false, momentum: false, time: 0.1))
        XCTAssertTrue(scroll.consumeTail(began: false, momentum: true, time: 1))
        XCTAssertFalse(scroll.consumeTail(began: true, momentum: false, time: 1.1))
        XCTAssertFalse(scroll.consumeTail(began: false, momentum: false, time: 1.2))
    }

    func testTrackpadMakesOneStepAndIgnoresMomentum() {
        var scroll = SpaceZoomScroll()
        XCTAssertNil(scroll.step(delta: -10, precise: true, began: true, momentum: false, time: 0))
        XCTAssertEqual(scroll.step(delta: -14, precise: true, began: false, momentum: false, time: 0.02), true)
        XCTAssertNil(scroll.step(delta: -100, precise: true, began: false, momentum: false, time: 0.05))
        XCTAssertNil(scroll.step(delta: -100, precise: true, began: false, momentum: true, time: 1))
        XCTAssertEqual(scroll.step(delta: 30, precise: true, began: true, momentum: false, time: 1.1), false)
    }

    func testWheelBurstDoesNotSkipLevelsButNextBurstCan() {
        var scroll = SpaceZoomScroll()
        XCTAssertEqual(scroll.step(delta: -1, precise: false, began: false, momentum: false, time: 0), true)
        XCTAssertNil(scroll.step(delta: -1, precise: false, began: false, momentum: false, time: 0.1))
        XCTAssertNil(scroll.step(delta: -1, precise: false, began: false, momentum: false, time: 0.2))
        XCTAssertEqual(scroll.step(delta: -1, precise: false, began: false, momentum: false, time: 0.6), true)
    }

    func testSmallReversalDoesNotReusePreviousDirectionDistance() {
        var scroll = SpaceZoomScroll()
        XCTAssertNil(scroll.step(delta: -23, precise: true, began: true, momentum: false, time: 0))
        XCTAssertNil(scroll.step(delta: 20, precise: true, began: false, momentum: false, time: 0.1))
        XCTAssertEqual(scroll.step(delta: 4, precise: true, began: false, momentum: false, time: 0.2), false)
    }

    func testLeaseRestoresUserDisabledShortcutsAndIsIdempotent() {
        let fixture = LeaseFixture()
        fixture.enabled[33] = false
        fixture.lease.setActive(true)
        XCTAssertEqual(fixture.enabled, [32: false, 33: false])
        let count = fixture.writes
        fixture.lease.setActive(true)
        XCTAssertEqual(fixture.writes, count)
        fixture.lease.setActive(false)
        XCTAssertEqual(fixture.enabled, [32: true, 33: false])
        XCTAssertNil(fixture.backup)
    }

    func testRecoversInterruptedGestureAndTerminationRejectsLateAcquire() {
        let fixture = LeaseFixture()
        fixture.enabled = [32: false, 33: false]
        fixture.backup = ["32": true, "33": false]
        fixture.lease.setActive(false)
        XCTAssertEqual(fixture.enabled, [32: true, 33: false])
        fixture.lease.setActive(true)
        fixture.lease.setActive(false, terminating: true)
        fixture.lease.setActive(true)
        XCTAssertEqual(fixture.enabled, [32: true, 33: false])
        XCTAssertNil(fixture.backup)
    }

    func testFailedRestoreRetainsRecoverySnapshot() {
        let fixture = LeaseFixture()
        fixture.lease.setActive(true)
        fixture.failing = 32
        fixture.lease.setActive(false)
        XCTAssertEqual(fixture.backup, ["32": true])
        fixture.failing = nil
        fixture.lease.setActive(false)
        XCTAssertEqual(fixture.enabled[32], true)
        XCTAssertNil(fixture.backup)
    }
    func testHeldZoomKeyKeepsTheLeaseUntilItsKeyUp() {
        var state = SpaceZoomEngagement(strip: false, canvas: true)
        state.heldKeys.insert(125)
        // Ctrl+Down at the minimum closes the canvas while the key is down.
        state.canvas = false
        XCTAssertFalse(state.engaged, "No new chord is claimed once the surface is gone")
        XCTAssertTrue(state.leased, "The repeats and key-up still belong to the press that exited")
        state.heldKeys.remove(125)
        XCTAssertFalse(state.leased)
    }

    func testZoomDriveTapAndRepeatedEventsDoNotAddMotion() {
        var drive = SpaceCanvasZoomDrive()
        XCTAssertTrue(drive.press(126, at: 0))
        XCTAssertTrue(drive.active)
        XCTAssertFalse(drive.driving)
        XCTAssertEqual(drive.advance(to: 0.05), 0)
        XCTAssertFalse(drive.press(126, at: 0.1), "OS repeat must not reset the hold delay")
        XCTAssertEqual(drive.advance(to: 0.1), 0)
        drive.release(126)
        XCTAssertFalse(drive.active)
        XCTAssertEqual(drive.advance(to: 0.5), 0)
    }

    func testZoomDriveHeldKeyContinuesWithoutRepeatAndBrakesOnRelease() {
        var drive = SpaceCanvasZoomDrive()
        drive.press(126, at: 0)
        var distance = 0.0
        for frame in 1...36 { distance += drive.advance(to: Double(frame) / 60) }
        XCTAssertTrue(drive.driving)
        XCTAssertGreaterThan(distance, 0.9, "A held key must travel beyond the caller's initial tap step")
        XCTAssertGreaterThan(drive.velocity, 2.49)
        drive.release(126)
        XCTAssertEqual(drive.direction, 0)
        XCTAssertTrue(drive.active, "Release keeps only the short braking tail")
        let releaseSpeed = drive.velocity
        let brakingDistance = drive.advance(to: 0.6 + 1.0 / 60)
        XCTAssertGreaterThan(brakingDistance, 0)
        XCTAssertLessThan(drive.velocity, releaseSpeed)
        for frame in 2...20 { _ = drive.advance(to: 0.6 + Double(frame) / 60) }
        XCTAssertEqual(drive.velocity, 0)
        XCTAssertFalse(drive.active)
    }

    func testZoomDriveLatestKeyReversesThenReleaseResumesOlderKey() {
        var drive = SpaceCanvasZoomDrive()
        drive.press(126, at: 0, delay: 0)
        for frame in 1...24 { _ = drive.advance(to: Double(frame) / 60) }
        XCTAssertTrue(drive.press(125, at: 0.4))
        XCTAssertEqual(drive.direction, -1)
        XCTAssertTrue(drive.driving, "Reversal must not wait through another tap delay")
        XCTAssertFalse(drive.press(126, at: 0.41), "An older key's repeat cannot retake direction")
        for frame in 1...6 { _ = drive.advance(to: 0.4 + Double(frame) / 60) }
        XCTAssertLessThan(drive.velocity, 0)
        drive.release(125)
        XCTAssertEqual(drive.direction, 1)
        XCTAssertTrue(drive.driving)
        for frame in 1...6 { _ = drive.advance(to: 0.5 + Double(frame) / 60) }
        XCTAssertGreaterThan(drive.velocity, 0)
        drive.reset()
        XCTAssertFalse(drive.active)
        XCTAssertFalse(drive.driving)
        XCTAssertEqual(drive.advance(to: 1), 0)
    }

    func testZoomDriveBoundaryDoesNoWorkUntilDirectionChanges() {
        var drive = SpaceCanvasZoomDrive()
        drive.press(125, at: 0, delay: 0)
        XCTAssertLessThan(drive.advance(to: 0.05), 0)
        drive.stopAtBoundary()
        XCTAssertTrue(drive.active, "The physical key still belongs to the chooser")
        XCTAssertEqual(drive.velocity, 0)
        for frame in 2...20 { XCTAssertEqual(drive.advance(to: Double(frame) / 20), 0) }
        drive.press(126, at: 1)
        XCTAssertGreaterThan(drive.advance(to: 1.05), 0)
        drive.release(126)
        XCTAssertEqual(drive.direction, -1)
        drive.release(125)
        drive.stopAtBoundary()
        XCTAssertFalse(drive.active)
    }

    func testReleasingOlderKeyKeepsTheCurrentBoundaryPaused() {
        var drive = SpaceCanvasZoomDrive()
        drive.press(126, at: 0, delay: 0)
        drive.press(125, at: 0.5, delay: 0)
        drive.stopAtBoundary()
        XCTAssertTrue(drive.atBoundary)
        drive.release(126)
        XCTAssertTrue(drive.atBoundary)
        XCTAssertTrue(drive.active)
        drive.release(125)
        XCTAssertFalse(drive.atBoundary)
        XCTAssertFalse(drive.active)
    }

    func testZoomDriveDistanceIsIndependentOfFrameRateAcrossDelayAndBrake() {
        func run(hz: Int) -> (distance: Double, velocity: Double, active: Bool) {
            var drive = SpaceCanvasZoomDrive()
            drive.press(126, at: 0)
            var distance = 0.0
            for frame in 1...hz { distance += drive.advance(to: Double(frame) / Double(hz)) }
            drive.release(126)
            for frame in 1...hz { distance += drive.advance(to: 1 + Double(frame) / Double(hz)) }
            return (distance, drive.velocity, drive.active)
        }
        let expected = run(hz: 120)
        for hz in [30, 60] {
            let actual = run(hz: hz)
            XCTAssertEqual(actual.distance, expected.distance, accuracy: 1e-10)
            XCTAssertEqual(actual.velocity, expected.velocity, accuracy: 1e-10)
            XCTAssertFalse(actual.active)
        }
    }

    func testZoomDriveStalledTickIsBoundedAndNeverRunsTimeBackward() {
        var drive = SpaceCanvasZoomDrive()
        drive.press(126, at: 0, delay: 0)
        for frame in 1...30 { _ = drive.advance(to: Double(frame) / 60) }
        let stalledDistance = drive.advance(to: 4)
        XCTAssertGreaterThan(stalledDistance, 0)
        XCTAssertLessThanOrEqual(stalledDistance, SpaceCanvasZoomDrive.speed * SpaceCanvasZoomDrive.maximumTick)
        XCTAssertEqual(drive.advance(to: 3), 0)
        XCTAssertEqual(drive.advance(to: 4), 0)
        XCTAssertEqual(drive.advance(to: .infinity), 0)
        XCTAssertLessThanOrEqual(drive.advance(to: 4 + 1.0 / 60), SpaceCanvasZoomDrive.speed / 60 + 1e-12)
    }
}

private final class LeaseFixture {
    var enabled: [Int32: Bool] = [32: true, 33: true]
    var backup: [String: Bool]?
    var writes = 0
    var failing: Int32?
    lazy var lease = SpaceZoomHotkeyLease(read: { self.enabled[$0] ?? true }, write: {
        self.writes += 1
        guard self.failing != $0 else { return false }
        self.enabled[$0] = $1
        return true
    }, load: { self.backup }, save: { self.backup = $0 })
}
