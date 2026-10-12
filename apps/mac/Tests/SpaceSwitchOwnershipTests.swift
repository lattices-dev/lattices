import XCTest
@testable import Lattices

final class SpaceSwitchOwnershipTests: XCTestCase {
    func testNativeShortcutsAreReleasedOnlyAfterTapIsReady() {
        let fixture = InputFixture()

        fixture.reconcile()

        XCTAssertEqual(fixture.effects, ["prepare tap", "disable native shortcuts"])
        XCTAssertTrue(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
        XCTAssertEqual(fixture.storage.enabled("79"), 0)
    }

    func testUnavailableTapRestoresBackupFromPreviousProcess() {
        let fixture = InputFixture()
        fixture.tapReady = false
        fixture.storage.hotkeys = ["79": ["enabled": 0], "80": ["enabled": 0]]
        fixture.storage.backup = ["79": true, "80": false]

        fixture.reconcile()

        XCTAssertEqual(fixture.effects, ["prepare tap", "remove tap", "restore native shortcuts"])
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertEqual(fixture.storage.enabled("80"), 0)
    }

    func testBreakerPauseRestoresNativeShortcutsAndRearmReacquiresThem() {
        let fixture = InputFixture()
        fixture.reconcile()
        fixture.effects = []

        fixture.reconcile(breakerArmed: false)

        XCTAssertEqual(fixture.effects, ["remove tap", "restore native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
        fixture.effects = []

        fixture.reconcile()

        XCTAssertEqual(fixture.effects, ["prepare tap", "disable native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 0)
        XCTAssertEqual(fixture.storage.backup, ["79": true, "80": true])
    }

    func testTurningFeatureOffDuringCooldownPreventsLateRearm() {
        let fixture = InputFixture()
        fixture.reconcile()
        fixture.reconcile(breakerArmed: false)
        fixture.reconcile(featureEnabled: false, breakerArmed: false)
        fixture.effects = []

        fixture.reconcile(featureEnabled: false)

        XCTAssertEqual(fixture.effects, ["remove tap", "restore native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
    }

    func testStoppedInterceptorIgnoresLateRearmAndPreferenceEmission() {
        let fixture = InputFixture()
        fixture.reconcile()
        fixture.effects = []

        fixture.reconcile(isRunning: false)
        fixture.reconcile(isRunning: false)

        XCTAssertEqual(fixture.effects, ["remove tap", "restore native shortcuts", "remove tap", "restore native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertNil(fixture.storage.backup)
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
    }

    func testPermissionLossRestoresShortcutsWithoutPreparingTap() {
        let fixture = InputFixture()
        fixture.reconcile()
        fixture.effects = []

        fixture.reconcile(accessibilityGranted: false)

        XCTAssertEqual(fixture.effects, ["remove tap", "restore native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
    }

    func testLostTapReadinessRestoresShortcutsInsteadOfKeepingOwnership() {
        let fixture = InputFixture()
        fixture.reconcile()
        fixture.effects = []
        fixture.tapReady = false

        fixture.reconcile()

        XCTAssertEqual(fixture.effects, ["prepare tap", "remove tap", "restore native shortcuts"])
        XCTAssertEqual(fixture.storage.enabled("79"), 1)
        XCTAssertFalse(fixture.hotkeyOwnership.isHoldingSystemHotkeys)
    }

    func testFreshProcessRestoresInterruptedOwnershipWithoutEnablingUserDisabledShortcut() {
        let storage = HotkeyStorage()
        storage.hotkeys = [
            "79": ["enabled": 0, "value": ["type": "standard"]],
            "80": ["enabled": 0],
            "81": ["enabled": 0],
        ]
        storage.backup = ["79": true, "80": false]
        let ownership = storage.makeOwnership()

        XCTAssertFalse(ownership.isHoldingSystemHotkeys)
        XCTAssertTrue(ownership.restore())

        XCTAssertEqual(storage.enabled("79"), 1)
        XCTAssertEqual(storage.enabled("80"), 0)
        XCTAssertEqual(storage.enabled("81"), 0)
        XCTAssertEqual((storage.hotkeys["79"] as? [String: Any])?["value"] as? [String: String], ["type": "standard"])
        XCTAssertNil(storage.backup)
        XCTAssertEqual(storage.applyCount, 1)
    }

    func testRepeatedAcquisitionPreservesOriginalSettingsAndRestoresOnlyOnce() {
        let storage = HotkeyStorage()
        storage.hotkeys = ["80": ["enabled": 0]]
        let ownership = storage.makeOwnership()

        XCTAssertTrue(ownership.disable())
        XCTAssertTrue(ownership.isHoldingSystemHotkeys)
        XCTAssertFalse(ownership.disable())
        XCTAssertEqual(storage.backup, ["79": true, "80": false])
        XCTAssertEqual(storage.applyCount, 1)

        XCTAssertTrue(ownership.restore())
        XCTAssertFalse(ownership.restore())
        XCTAssertFalse(ownership.isHoldingSystemHotkeys)
        XCTAssertEqual(storage.enabled("79"), 1)
        XCTAssertEqual(storage.enabled("80"), 0)
        XCTAssertEqual(storage.applyCount, 2)
    }

    func testAcquisitionAfterCrashKeepsOriginalBackup() {
        let storage = HotkeyStorage()
        storage.hotkeys = ["79": ["enabled": 0], "80": ["enabled": 0]]
        storage.backup = ["79": true, "80": false]
        let ownership = storage.makeOwnership()

        XCTAssertFalse(ownership.disable())
        XCTAssertEqual(storage.backup, ["79": true, "80": false])
        XCTAssertTrue(ownership.restore())
        XCTAssertEqual(storage.enabled("79"), 1)
        XCTAssertEqual(storage.enabled("80"), 0)
    }

    func testTerminationRestoresOriginalSettingsAndRejectsLateAcquisition() {
        let storage = HotkeyStorage()
        storage.hotkeys = ["79": ["enabled": 1], "80": ["enabled": 0]]
        let ownership = storage.makeOwnership()
        XCTAssertTrue(ownership.disable())

        XCTAssertTrue(ownership.restoreForTermination())
        XCTAssertFalse(ownership.disable())
        XCTAssertFalse(ownership.restoreForTermination())
        XCTAssertFalse(ownership.isHoldingSystemHotkeys)
        XCTAssertEqual(storage.enabled("79"), 1)
        XCTAssertEqual(storage.enabled("80"), 0)
        XCTAssertNil(storage.backup)
        XCTAssertEqual(storage.applyCount, 2)
    }

    func testTerminationBeforeAcquisitionLeavesShortcutsUntouched() {
        let storage = HotkeyStorage()
        let ownership = storage.makeOwnership()

        XCTAssertFalse(ownership.restoreForTermination())
        XCTAssertFalse(ownership.disable())

        XCTAssertTrue(storage.hotkeys.isEmpty)
        XCTAssertNil(storage.backup)
        XCTAssertEqual(storage.applyCount, 0)
        XCTAssertFalse(ownership.isHoldingSystemHotkeys)
    }

    private final class InputFixture {
        var tapReady = true
        var effects: [String] = []
        let storage = HotkeyStorage()
        lazy var hotkeyOwnership = storage.makeOwnership()

        func reconcile(
            isRunning: Bool = true,
            featureEnabled: Bool = true,
            accessibilityGranted: Bool = true,
            breakerArmed: Bool = true
        ) {
            let ownership = SpaceSwitchInputOwnership(
                makeTapReady: {
                    self.effects.append("prepare tap")
                    return self.tapReady
                },
                removeTap: { self.effects.append("remove tap") },
                disableSystemHotkeys: {
                    self.effects.append("disable native shortcuts")
                    self.hotkeyOwnership.disable()
                },
                restoreSystemHotkeys: {
                    self.effects.append("restore native shortcuts")
                    self.hotkeyOwnership.restore()
                }
            )
            ownership.reconcile(
                isRunning: isRunning,
                featureEnabled: featureEnabled,
                accessibilityGranted: accessibilityGranted,
                breakerArmed: breakerArmed
            )
        }
    }

    private final class HotkeyStorage {
        var hotkeys: [String: Any] = [:]
        var backup: [String: Bool]?
        var applyCount = 0

        func enabled(_ id: String) -> Int? {
            (hotkeys[id] as? [String: Any])?["enabled"] as? Int
        }

        func makeOwnership() -> SpaceSwitchHotkeyOwnership {
            SpaceSwitchHotkeyOwnership(
                readHotkeys: { self.hotkeys },
                writeHotkeys: { self.hotkeys = $0 },
                readBackup: { self.backup },
                writeBackup: { self.backup = $0 },
                applySettings: { self.applyCount += 1 }
            )
        }
    }
}
