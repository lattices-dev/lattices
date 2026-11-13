import AppKit
import XCTest
@testable import Lattices

final class DesktopCanvasTests: XCTestCase {
    private let monitor = CGRect(x: -3440, y: -396, width: 3440, height: 1415)
    private let viewport = CGRect(x: 8000, y: -1200, width: 3440, height: 1415)

    func testNativeViewportPreservesScaleAndRoundTripsAcrossNegativeMonitorCoordinates() {
        let logical = CGRect(x: 8200, y: -1100, width: 1000, height: 700)
        let physical = DesktopCanvasModel.physicalFrame(logical, viewport: viewport, screen: monitor)!
        XCTAssertEqual(physical.size, logical.size)
        XCTAssertEqual(physical.origin, CGPoint(x: -3240, y: -296))
        XCTAssertEqual(DesktopCanvasModel.logicalFrame(physical, viewport: viewport, screen: monitor), logical)
    }

    func testOffCameraWindowsParkAndBoundaryWindowsKeepReachableControls() {
        XCTAssertNil(DesktopCanvasModel.physicalFrame(CGRect(x: 12000, y: -1100, width: 1000, height: 700), viewport: viewport, screen: monitor))
        let edge = DesktopCanvasModel.physicalFrame(CGRect(x: 7800, y: -1100, width: 1000, height: 700), viewport: viewport, screen: monitor)!
        XCTAssertEqual(edge.minX, monitor.minX)
        XCTAssertEqual(edge.width, 1000)
    }

    func testCanvasExpandsBeyondInitialTwelveThousandPoints() {
        var model = DesktopCanvasModel(items: [.init(id: 1, pid: 2, title: "Test", frame: CGRect(x: 14000, y: -13000, width: 800, height: 600))], viewport: viewport)
        model.expand()
        XCTAssertTrue(model.extent.contains(model.items[0].frame))
        XCTAssertGreaterThan(model.extent.width, 12000)
    }

    func testGestureDoesNotClaimDesktopOverviewOrApplicationModifierVariants() {
        XCTAssertTrue(DesktopCanvasModel.usesGesture([.maskControl, .maskCommand]))
        for flags: CGEventFlags in [[.maskControl, .maskAlternate], [.maskControl], [.maskCommand], [.maskControl, .maskCommand, .maskShift], [.maskControl, .maskCommand, .maskAlternate]] {
            XCTAssertFalse(DesktopCanvasModel.usesGesture(flags))
        }
    }

    func testArrangementKeysDoNotConsumeApplicationModifierShortcuts() {
        XCTAssertEqual(DesktopCanvasModel.keyAction(code: 36, flags: []), .work)
        XCTAssertEqual(DesktopCanvasModel.keyAction(code: 76, flags: []), .work)
        XCTAssertEqual(DesktopCanvasModel.keyAction(code: 53, flags: []), .exit)
        XCTAssertEqual(DesktopCanvasModel.keyAction(code: 123, flags: []), .left)
        XCTAssertEqual(DesktopCanvasModel.keyAction(code: 24, flags: [.shift]), .zoomIn)
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            for key: UInt16 in [36, 53, 123, 124, 125, 126, 24, 27] {
                XCTAssertNil(DesktopCanvasModel.keyAction(code: key, flags: modifier))
            }
        }
    }

    @MainActor
    func testZoomingToFullSizeDoesNotCommitWindowPlacement() {
        let model = DesktopCanvasModel(items: [], viewport: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let view = DesktopCanvasView(frame: model.viewport, model: model, images: [:])
        var workRequested = false
        view.onWork = { _ in workRequested = true }
        view.zoom(by: 100)
        XCTAssertFalse(workRequested, "Only an explicit Work action may hand off keyboard input to apps")
        XCTAssertEqual(view.model.viewport, model.viewport)
    }

    func testDisconnectedMonitorRecoveryKeepsWindowControlsOnRemainingScreen() {
        let original = CGRect(x: -3200, y: -100, width: 2000, height: 1100)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let recovered = DesktopCanvasModel.recoveryFrame(original, displays: [main])
        XCTAssertTrue(main.contains(recovered))
        XCTAssertEqual(DesktopCanvasModel.recoveryFrame(original, displays: [main, monitor]), original)
    }

    final class Fake {
        let launched = Date(timeIntervalSince1970: 100)
        var states: [UInt32: DesktopCanvasSession.State] = [:]
        var calls = 0
        var failMove = false
        var knownSpace = 5
        var reachable = true
        var alive: Bool? = true
        var inaccessible: Set<UInt32> = []
        var readOnly: Set<UInt32> = []
        let url: URL
        init(url: URL) {
            self.url = url
            states[1] = .init(frame: CGRect(x: 100, y: 100, width: 800, height: 600), minimized: false, launched: launched)
            states[2] = .init(frame: CGRect(x: 1000, y: 100, width: 800, height: 600), minimized: false, launched: launched)
        }
        var backend: DesktopCanvasSession.Backend {
            .init(read: { [self] id, _ in reachable && !inaccessible.contains(id) ? states[id] : nil }, spaces: { [self] _ in [knownSpace] },
                  move: { [self] id, _, frame in
                      calls += 1
                      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Recovery must be durable before mutation")
                      guard !failMove, let old = states[id] else { return false }
                      states[id] = .init(frame: frame, minimized: old.minimized, launched: old.launched); return true
                  }, minimize: { [self] id, _, minimized in
                      calls += 1
                      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                      guard let old = states[id] else { return false }
                      states[id] = .init(frame: old.frame, minimized: minimized, launched: old.launched); return true
                  }, exists: { [self] _, _, _ in alive },
                  canManage: { [self] id, _ in !readOnly.contains(id) })
        }
        var model: DesktopCanvasModel {
            .init(items: [.init(id: 1, pid: 10, title: "One", frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
                          .init(id: 2, pid: 20, title: "Two", frame: CGRect(x: 5000, y: 100, width: 800, height: 600))],
                  viewport: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        }
    }
    private func fixture() -> (URL, Fake) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("recovery.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (url, Fake(url: url))
    }

    func testCrashRecoveryUnparksEveryWindowAndRestoresOriginalFrames() {
        let (url, fake) = fixture()
        let originals = fake.states
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        XCTAssertTrue(session.apply(fake.model, screen: fake.model.viewport, space: 5))
        XCTAssertTrue(fake.states[2]!.minimized)
        let restarted = DesktopCanvasSession(url: url, backend: fake.backend)
        XCTAssertTrue(restarted.restore())
        for id: UInt32 in [1, 2] {
            XCTAssertEqual(fake.states[id]?.frame, originals[id]?.frame)
            XCTAssertFalse(fake.states[id]!.minimized)
        }
        XCTAssertEqual(try JSONDecoder().decode([DesktopCanvasSession.Record].self, from: Data(contentsOf: url)).count, 0)
    }

    func testUnavailableInventoryWindowDoesNotBlockManagedWindowRoundTrip() {
        let (url, fake) = fixture()
        fake.inaccessible = [2]
        let original = fake.states[1]!.frame
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        var model = fake.model
        model.items = model.items.filter { session.candidateState($0, space: 5) != nil }
        XCTAssertEqual(model.items.map(\.id), [1])
        model.items[0].frame.origin.x += 200
        XCTAssertTrue(session.apply(model, screen: model.viewport, space: 5))
        XCTAssertNotEqual(fake.states[1]!.frame, original)
        XCTAssertTrue(session.restore())
        XCTAssertEqual(fake.states[1]!.frame, original)
        XCTAssertEqual(fake.states[2]!.frame.origin.x, 1000)
    }

    func testReadOnlyOrWrongSpaceWindowIsNotOfferedForArrangement() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        fake.readOnly = [1]
        XCTAssertNil(session.candidateState(fake.model.items[0], space: 5))
        XCTAssertNotNil(session.candidateState(fake.model.items[1], space: 5))
        fake.knownSpace = 7
        XCTAssertNil(session.candidateState(fake.model.items[1], space: 5))
        XCTAssertEqual(fake.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedRestorationRetainsJournalAndRetrySucceeds() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        var changed = fake.model
        changed.items[0].frame.origin.x += 200
        XCTAssertTrue(session.apply(changed, screen: changed.viewport, space: 5))
        fake.failMove = true
        XCTAssertFalse(session.restore())
        let pending = try! JSONDecoder().decode([DesktopCanvasSession.Record].self, from: Data(contentsOf: url))
        XCTAssertEqual(pending.map(\.id), [1], "Only the failed move stays journaled; a parked but unmoved window only needs unminimizing")
        fake.failMove = false
        XCTAssertTrue(session.restore())
    }

    func testLeavingStuckWindowsClearsJournalWithoutMovingThem() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        var changed = fake.model
        changed.items[0].frame.origin.x += 200
        XCTAssertTrue(session.apply(changed, screen: changed.viewport, space: 5))
        fake.failMove = true
        XCTAssertFalse(session.restore())
        let moved = fake.states[1]!.frame
        let calls = fake.calls
        XCTAssertTrue(session.abandon())
        XCTAssertEqual(fake.calls, calls, "Leaving windows as they are must not touch them")
        XCTAssertEqual(fake.states[1]!.frame, moved)
        XCTAssertTrue(session.pendingApps.isEmpty)
        XCTAssertTrue(DesktopCanvasSession(url: url, backend: fake.backend).restore(), "A relaunch has nothing left to recover")
    }

    func testConfirmAndReturnDoNotRewriteUnchangedNativeWindows() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        var unchanged = fake.model
        unchanged.items[1].frame = fake.states[2]!.frame
        XCTAssertTrue(session.apply(unchanged, screen: unchanged.viewport, space: 5))
        XCTAssertEqual(fake.calls, 0)
        XCTAssertTrue(session.restore())
        XCTAssertEqual(fake.calls, 0, "A no-op confirmation must not trigger macOS resize or minimize animations")
    }

    func testHandoffKeepsCoverUntilMotionAndNativeWorkBothFinishExactlyOnce() {
        for first: DesktopCanvasHandoff.Part in [.motion, .native] {
            let handoff = DesktopCanvasHandoff()
            let second: DesktopCanvasHandoff.Part = first == .motion ? .native : .motion
            XCTAssertFalse(handoff.arrive(first))
            XCTAssertFalse(handoff.arrive(first))
            XCTAssertTrue(handoff.arrive(second))
            XCTAssertFalse(handoff.arrive(second))
            XCTAssertFalse(handoff.arrive(first))
        }
    }

    @MainActor
    func testKeyboardPanAccumulatesDuringMotionAndEscapeDoesNotCommit() {
        let model = DesktopCanvasModel(items: [], viewport: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let view = DesktopCanvasView(frame: model.viewport, model: model, images: [:])
        var commits = 0, exits = 0
        view.onWork = { _ in commits += 1 }; view.onExit = { exits += 1 }
        func press(_ code: UInt16) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        view.prepareEntrance(); view.animateEntrance()
        press(124); press(124)
        XCTAssertEqual(view.model.viewport.minX, 2000)
        press(36); XCTAssertEqual(commits, 1)
        view.isBusy = true
        press(124); press(36)
        XCTAssertEqual(view.model.viewport.minX, 2000); XCTAssertEqual(commits, 1)
        press(53); XCTAssertEqual(exits, 1, "Escape remains available while native work is pending")
    }

    @MainActor
    func testLandingPreviewMatchesClampedNativeFrameWithoutChangingArrangement() {
        let viewport = CGRect(x: 1000, y: 0, width: 2000, height: 1200)
        let model = DesktopCanvasModel(items: [.init(id: 1, pid: 10, title: "Edge", frame: CGRect(x: 900, y: 100, width: 800, height: 600))], viewport: viewport)
        let view = DesktopCanvasView(frame: CGRect(origin: .zero, size: viewport.size), model: model, images: [:])
        var changed = false
        view.onChange = { _ in changed = true }
        view.animateLanding(completion: {})
        XCTAssertEqual(view.model.items[0].frame.minX, 1000)
        XCTAssertFalse(changed, "Clamping is a visual handoff, not a change to the saved logical arrangement")
    }

    func testEscapeStopsRemainingMutationsAndJournalRestoresPartialBatch() {
        let (url, fake) = fixture()
        let cancellation = DesktopCanvasSession.Cancellation()
        var backend = fake.backend
        let minimize = backend.minimize
        backend.minimize = { id, pid, value in
            let result = minimize(id, pid, value)
            cancellation.cancel()
            return result
        }
        var changed = fake.model
        changed.items[0].frame.origin.x += 200
        let session = DesktopCanvasSession(url: url, backend: backend)
        XCTAssertFalse(session.apply(changed, screen: changed.viewport, space: 5, cancellation: cancellation))
        XCTAssertEqual(fake.calls, 1, "Escape must stop the batch before the next window is touched")
        XCTAssertTrue(fake.states[2]!.minimized)
        XCTAssertEqual(fake.states[1]!.frame.minX, 100)
        XCTAssertTrue(session.restore())
        XCTAssertFalse(fake.states[2]!.minimized)
        XCTAssertEqual(try JSONDecoder().decode([DesktopCanvasSession.Record].self, from: Data(contentsOf: url)).count, 0)
    }

    func testUnresponsiveWindowsAreRetainedButClosedWindowsAreRetired() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        XCTAssertTrue(session.apply(fake.model, screen: fake.model.viewport, space: 5))
        fake.reachable = false; fake.alive = nil
        XCTAssertFalse(session.restore())
        fake.alive = false
        XCTAssertTrue(session.restore())
    }

    func testSpaceChangeAndUnwritableJournalPreventAllMutations() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        fake.knownSpace = 7
        XCTAssertFalse(session.apply(fake.model, screen: fake.model.viewport, space: 5))
        XCTAssertEqual(fake.calls, 0)
        fake.knownSpace = 5
        let blocked = DesktopCanvasSession(url: URL(fileURLWithPath: "/dev/null/recovery.json"), backend: fake.backend)
        XCTAssertFalse(blocked.apply(fake.model, screen: fake.model.viewport, space: 5))
        XCTAssertEqual(fake.calls, 0)
    }

    func testOtherSpaceAXOmissionKeepsRecoveryUntilWindowsBecomeReachable() throws {
        let (url, fake) = fixture()
        let originals = fake.states
        var backend = fake.backend
        backend.exists = { id, pid, _ in
            DesktopCanvasSession.Backend.windowPresence(id: id, pid: pid, axIDs: [],
                                                        serverOwners: [1: 10, 2: 20], spaces: [5])
        }
        let session = DesktopCanvasSession(url: url, backend: backend)
        XCTAssertTrue(session.apply(fake.model, screen: fake.model.viewport, space: 5))
        fake.reachable = false
        XCTAssertFalse(session.restore())
        XCTAssertEqual(try JSONDecoder().decode([DesktopCanvasSession.Record].self, from: Data(contentsOf: url)).count, 2)
        fake.reachable = true
        XCTAssertTrue(session.restore())
        for id: UInt32 in [1, 2] {
            XCTAssertEqual(fake.states[id]?.frame, originals[id]?.frame)
            XCTAssertFalse(fake.states[id]!.minimized)
        }
    }

    func testWindowPresenceRequiresCompleteEvidenceBeforeRetiringRecovery() {
        let presence = DesktopCanvasSession.Backend.windowPresence
        XCTAssertNil(presence(1, 10, [], nil, []), "Unavailable WindowServer data is not closure")
        XCTAssertEqual(presence(1, 10, [], [:], [5]), true, "Space membership preserves a hidden window")
        XCTAssertEqual(presence(1, 10, [], [:], []), false, "A confirmed closed window can be retired")
        XCTAssertEqual(presence(1, 10, [1], [1: 99], [5]), false, "A reused window ID must never be restored")
    }

    func testReusedProcessIdentityNeverReceivesRecoveryWrites() {
        let (url, fake) = fixture()
        let session = DesktopCanvasSession(url: url, backend: fake.backend)
        XCTAssertTrue(session.apply(fake.model, screen: fake.model.viewport, space: 5))
        for id: UInt32 in [1, 2] {
            fake.states[id] = .init(frame: .zero, minimized: false, launched: Date(timeIntervalSince1970: 999))
        }
        let previousCalls = fake.calls
        XCTAssertTrue(session.restore())
        XCTAssertEqual(fake.calls, previousCalls)
    }
}
