import XCTest
@testable import Lattices

final class ComputerAppLaunchTargetTests: XCTestCase {
    func testBundleIdentityOverridesSimilarRunningNames() throws {
        let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes")
        XCTAssertFalse(target.matches(name: "Notes", bundleIdentifier: "com.example.Notes", url: nil))
        XCTAssertFalse(target.matches(name: "Notes Helper", bundleIdentifier: "com.apple.Notes.helper", url: nil))
        XCTAssertTrue(target.matches(name: "Renamed Notes", bundleIdentifier: "com.apple.Notes", url: nil))
    }

    func testExplicitPathDistinguishesInstallationsWithTheSameBundleID() throws {
        let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.example.Notes",
                                               path: "/Applications/Notes.app")
        XCTAssertFalse(target.matches(name: "Notes", bundleIdentifier: "com.example.Notes",
                                      url: URL(fileURLWithPath: "/Users/example/Applications/Notes.app")))
        XCTAssertFalse(target.matches(name: "Notes", bundleIdentifier: "com.example.Other",
                                      url: URL(fileURLWithPath: "/Applications/Notes.app")))
        XCTAssertTrue(target.matches(name: "Notes", bundleIdentifier: "com.example.Notes",
                                     url: URL(fileURLWithPath: "/Applications/Notes.app")))
    }

    func testMissingExplicitBundleDoesNotFallBackToName() throws {
        let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.example.Missing")
        XCTAssertThrowsError(try target.applicationURL(lookup: { _ in nil }))
    }

    func testMissingExplicitPathDoesNotUseBundleLookup() throws {
        let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes",
                                               path: "/missing-\(UUID().uuidString)/Notes.app")
        XCTAssertThrowsError(try target.applicationURL(lookup: { _ in
            XCTFail("An explicit path must not fall back to another installation")
            return nil
        }))
    }

    func testWrongLaunchServicesBundleIsRejected() throws {
        try withBundle(identifier: "com.example.Decoy") { url in
            let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes")
            XCTAssertThrowsError(try target.applicationURL(lookup: { _ in url }))
        }
    }

    func testExplicitPathAndBundleMustAgreeBeforeLaunch() throws {
        try withBundle(identifier: "com.example.Decoy") { url in
            let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes", path: url.path)
            XCTAssertThrowsError(try target.applicationURL(lookup: { _ in nil }))
        }
    }

    func testValidPathResolvesSymlinksAndIgnoresDisplayName() throws {
        try withBundle(identifier: "com.example.Target") { url in
            let alias = url.deletingLastPathComponent().appendingPathComponent("Alias.app")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            let target = try ComputerAppLaunchTarget(appName: "Different name", path: alias.path)
            XCTAssertEqual(try target.applicationURL(lookup: { _ in nil })?.path, url.resolvingSymlinksInPath().path)
            XCTAssertTrue(target.matches(name: "Target", bundleIdentifier: "com.example.Target", url: url))
        }
    }

    func testExplicitWindowSelectionUsesTheResolvedProcessAndTitle() throws {
        let target = try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: "com.example.Target")
        let decoy = window(1, pid: 11, title: "Work", onscreen: true, z: 0)
        let background = window(2, pid: 22, title: "Work", onscreen: false, z: 1)
        let foreground = window(3, pid: 22, title: "Home", onscreen: true, z: 2)
        let windows = [decoy, background, foreground]
        XCTAssertEqual(target.window(in: windows, processIDs: [22], title: nil)?.wid, 3)
        XCTAssertEqual(target.window(in: windows, processIDs: [22], title: "work")?.wid, 2)
        XCTAssertNil(target.window(in: windows, processIDs: [], title: nil))
        XCTAssertNil(target.window(in: windows, processIDs: [22], title: "Missing"))
    }

    func testNameOnlyTargetsKeepLegacyMatching() throws {
        let target = try ComputerAppLaunchTarget(appName: "notes")
        XCTAssertFalse(target.isPrecise)
        XCTAssertTrue(target.matches(name: "Notes Preview", bundleIdentifier: nil, url: nil))
        XCTAssertTrue(target.matches(name: "Different", bundleIdentifier: "com.example.notes", url: nil))
        XCTAssertNil(try target.applicationURL(lookup: { _ in
            XCTFail("A name-only target uses the existing name lookup")
            return nil
        }))
    }

    func testInvalidExplicitSelectorsCannotBecomeNameOnlyTargets() {
        XCTAssertThrowsError(try ComputerAppLaunchTarget(appName: "Notes", bundleIdentifier: " "))
        XCTAssertThrowsError(try ComputerAppLaunchTarget(appName: "Notes", path: ""))
        XCTAssertThrowsError(try ComputerAppLaunchTarget(appName: "Notes", path: "Notes.app"))
        XCTAssertThrowsError(try ComputerAppLaunchTarget(appName: "Notes", path: "/Applications/Notes.txt"))
    }

    private func window(_ wid: UInt32, pid: Int32, title: String, onscreen: Bool, z: Int) -> WindowEntry {
        WindowEntry(wid: wid, app: "Notes", pid: pid, title: title,
                    frame: WindowFrame(x: 0, y: 0, w: 800, h: 600), spaceIds: [1],
                    isOnScreen: onscreen, latticesSession: nil, zIndex: z)
    }

    private func withBundle(identifier: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-launch-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Target.app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": "Target",
        ], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try body(url)
    }
}
