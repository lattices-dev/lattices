@testable import ActionCore
import Foundation
import XCTest

final class ActionVirtualWorkspaceTests: XCTestCase {
    func testIdentityPreservesDefaultAndSeparatesNamedWorkspaces() throws {
        XCTAssertEqual(try ActionVirtualWorkspace().serialNumber, 0x41435401)
        XCTAssertEqual(try ActionVirtualWorkspace().ownerLockName, "display-owner.lock")
        XCTAssertEqual(try ActionVirtualWorkspace("stage").serialNumber, try ActionVirtualWorkspace("stage").serialNumber)
        XCTAssertNotEqual(try ActionVirtualWorkspace("stage").serialNumber, try ActionVirtualWorkspace("agent").serialNumber)
        XCTAssertEqual(try ActionVirtualWorkspace("stage").serialNumber & 0x80000000, 0x80000000)
    }

    func testRejectsInvalidNames() {
        for name in ["", "../stage", "Stage", "0stage", "a/b", "stage\n", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try ActionVirtualWorkspace(name), name)
        }
    }

    func testPlacementClearsAllDisplaysNotOnlyPhysicalAnchor() {
        let displays = [CGRect(x: -3840, y: -396, width: 3840, height: 2160), CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 1440, width: 1440, height: 900)]
        XCTAssertEqual(ActionVirtualWorkspace.offscreenOrigin(otherBounds: displays), CGPoint(x: 4880, y: 2340))
        XCTAssertNil(ActionVirtualWorkspace.offscreenOrigin(otherBounds: []))
    }

    func testPreviewRejectsSelfCaptureAndRecursiveDisplayGraphs() {
        XCTAssertTrue(ActionVirtualWorkspace.previewWouldCycle(source: 11, destination: 11, edges: [:]))
        XCTAssertTrue(ActionVirtualWorkspace.previewWouldCycle(source: 11, destination: 12, edges: [12: 11]))
        XCTAssertTrue(ActionVirtualWorkspace.previewWouldCycle(source: 11, destination: 12, edges: [12: 13, 13: 11]))
        XCTAssertFalse(ActionVirtualWorkspace.previewWouldCycle(source: 11, destination: 12, edges: [12: 2]))
        XCTAssertFalse(ActionVirtualWorkspace.previewWouldCycle(source: 11, destination: 2, edges: [12: 11]))
    }

    func testSharedPreviewLeasePreventsExclusiveRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.lock")
        var preview: ActionWorkspaceLock? = try ActionWorkspaceLock(url: url, shared: true)
        XCTAssertNotNil(preview)
        XCTAssertThrowsError(try ActionWorkspaceLock(url: url))
        let secondPreview = try ActionWorkspaceLock(url: url, shared: true)
        try withExtendedLifetime(secondPreview) { XCTAssertThrowsError(try ActionWorkspaceLock(url: url)) }
        preview = nil
    }

    func testExclusiveLockReleasesAtEndOfOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        var owner: ActionWorkspaceLock? = try ActionWorkspaceLock(url: url)
        XCTAssertNotNil(owner)
        XCTAssertThrowsError(try ActionWorkspaceLock(url: url))
        owner = nil
        XCTAssertNoThrow(try ActionWorkspaceLock(url: url))
    }
}
