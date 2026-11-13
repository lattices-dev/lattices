import Foundation
import XCTest
@testable import Lattices

final class ScreenTextPolicyTests: XCTestCase {
    func testOrdinaryAppsStayEligibleWithoutAnAllowlist() {
        let policy = ScreenTextPolicy(enabled: true, excludedBundleIDs: ScreenTextPolicy.defaultExcludedBundleIDs)
        for app in ["com.apple.Safari", "com.apple.Terminal", "com.microsoft.VSCode", "dev.example.new-app"] {
            XCTAssertTrue(policy.allows(bundleID: app, isOwnProcess: false, isOnScreen: true, width: 800, height: 600))
        }
        for app in ScreenTextPolicy.defaultExcludedBundleIDs {
            XCTAssertFalse(policy.allows(bundleID: app, isOwnProcess: false, isOnScreen: true, width: 800, height: 600))
        }
    }

    func testOffAndIneligibleWindowsCannotEnterIndex() {
        let off = ScreenTextPolicy(enabled: false, excludedBundleIDs: [])
        XCTAssertFalse(off.allows(bundleID: "dev.example", isOwnProcess: false, isOnScreen: true, width: 800, height: 600))
        let on = ScreenTextPolicy(enabled: true, excludedBundleIDs: ["dev.private"])
        XCTAssertFalse(on.allows(bundleID: "dev.private", isOwnProcess: false, isOnScreen: true, width: 800, height: 600))
        XCTAssertFalse(on.allows(bundleID: nil, isOwnProcess: false, isOnScreen: true, width: 800, height: 600))
        XCTAssertFalse(on.allows(bundleID: "dev.example", isOwnProcess: true, isOnScreen: true, width: 800, height: 600))
        XCTAssertFalse(on.allows(bundleID: "dev.example", isOwnProcess: false, isOnScreen: false, width: 800, height: 600))
        XCTAssertFalse(on.allows(bundleID: "dev.example", isOwnProcess: false, isOnScreen: true, layer: 10, width: 800, height: 600))
        XCTAssertFalse(on.allows(bundleID: "dev.example", isOwnProcess: false, isOnScreen: true, width: 1, height: 600))
    }

    func testSecureAndHiddenAccessibilitySubtreesAreSkipped() {
        XCTAssertFalse(ScreenTextPolicy.allowsAccessibilityNode(subrole: "AXSecureTextField", hidden: false))
        XCTAssertFalse(ScreenTextPolicy.allowsAccessibilityNode(subrole: nil, hidden: true))
        XCTAssertTrue(ScreenTextPolicy.allowsAccessibilityNode(subrole: "AXSearchField", hidden: false))
    }

    func testTextAreaRespectsVisibleUTF16RangeAndRejectsMalformedRange() {
        let text = "hidden 🔒 visible trailing"
        let visible = (text as NSString).range(of: "visible")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: visible), "visible")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: NSRange(location: 999, length: 2)), "")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: NSRange(location: 1, length: Int.max)), "")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: NSRange(location: NSNotFound, length: 0)), "")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: NSRange(location: -1, length: 2)), "")
        XCTAssertEqual(ScreenTextPolicy.visibleText(text, range: NSRange(location: 0, length: -1)), "")
    }

    func testCancelledScanCannotPublishOrPersistAfterReenable() {
        let gate = ScreenTextScanGate()
        let old = gate.current()
        gate.invalidate()
        var writes = 0
        XCTAssertFalse(gate.commit(old) { writes += 1 })
        let current = gate.current()
        XCTAssertTrue(gate.commit(current) { writes += 1 })
        XCTAssertFalse(gate.commit(old) { writes += 1 })
        XCTAssertEqual(writes, 1)
    }

    func testStopWaitsForAlreadyCommittingWriteThenRejectsQueuedWrite() {
        let gate = ScreenTextScanGate()
        let permit = gate.current()
        let began = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let stopped = expectation(description: "stop completed")
        DispatchQueue.global().async {
            gate.commit(permit) { began.signal(); _ = finish.wait(timeout: .now() + 2) }
        }
        XCTAssertEqual(began.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { gate.invalidate(); stopped.fulfill() }
        finish.signal()
        wait(for: [stopped], timeout: 2)
        XCTAssertFalse(gate.commit(permit) { XCTFail("Cancelled write committed") })
    }
}
