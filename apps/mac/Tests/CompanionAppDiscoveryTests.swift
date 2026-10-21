import XCTest
@testable import Lattices

final class CompanionAppDiscoveryTests: XCTestCase {
    private var root: URL!
    private var userApps: URL!
    private var systemApps: URL!
    private var helpers: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattices-companion-apps-\(UUID().uuidString)", isDirectory: true)
        userApps = root.appendingPathComponent("UserApplications", isDirectory: true)
        systemApps = root.appendingPathComponent("SystemApplications", isDirectory: true)
        helpers = root.appendingPathComponent("Lattices.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testMissingBundleIsNotInstalled() {
        let discovery = makeDiscovery()
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .missing
        )
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .action)),
            .missing
        )
    }

    func testValidUserApplicationsInstallResolvesByIdentity() throws {
        let blinkURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let actionURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Action.app"),
            bundleIdentifier: CompanionBundleIdentifiers.action
        )
        let discovery = makeDiscovery()

        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .installed(url: blinkURL)
        )
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .action)),
            .installed(url: actionURL)
        )
    }

    func testLaunchServicesHitIsUsedWhenIdentityMatches() throws {
        let registered = try makeAppBundle(
            at: root.appendingPathComponent("RegisteredBlink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.blink] = registered
        let discovery = makeDiscovery(launchServices: locator)

        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .installed(url: registered)
        )
    }

    func testCanvasFilenameResolvesByExistingBlinkIdentity() throws {
        let canvasURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Canvas.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        XCTAssertEqual(
            makeDiscovery().installState(for: CompanionAppCatalog.product(id: .blink)),
            .installed(url: canvasURL)
        )
    }

    func testWrongBundleIdentityIsNotInstalled() throws {
        let decoy = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: "com.example.not-blink"
        )
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.blink] = decoy
        let discovery = makeDiscovery(launchServices: locator)

        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .missing
        )
        XCTAssertNil(discovery.validatedURL(bundleIdentifier: CompanionBundleIdentifiers.blink))
    }

    func testFileNamedLikeAnAppIsNotInstalled() throws {
        let fake = userApps.appendingPathComponent("Blink.app")
        try Data("not a bundle".utf8).write(to: fake)
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.blink] = fake
        let discovery = makeDiscovery(launchServices: locator)

        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .missing
        )
    }

    func testDeletedBundleIsNotInstalled() throws {
        let blinkURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.blink] = blinkURL
        let discovery = makeDiscovery(launchServices: locator)
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .installed(url: blinkURL)
        )

        try FileManager.default.removeItem(at: blinkURL)
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .missing
        )
    }

    func testStaleLaunchServicesURLFallsBackToUserApplications() throws {
        let stale = try makeAppBundle(
            at: root.appendingPathComponent("StaleBlink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let current = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.blink] = stale
        try FileManager.default.removeItem(at: stale)

        let discovery = makeDiscovery(launchServices: locator)
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .blink)),
            .installed(url: current)
        )
    }

    func testVoiceIsNotDiscoveredByFilenameOrProcess() throws {
        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("Voice.app"),
            bundleIdentifier: "dev.example.voice"
        )
        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("Speech.app"),
            bundleIdentifier: "dev.example.speech"
        )
        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("SpeakEasy.app"),
            bundleIdentifier: "com.example.speakeasy"
        )
        let voice = CompanionAppCatalog.product(id: .speech)
        XCTAssertEqual(voice.displayName, "Voice")
        XCTAssertEqual(voice.bundleIdentifier, "dev.lattices.Speech")
        XCTAssertEqual(makeDiscovery().installState(for: voice), .missing)
        XCTAssertEqual(CompanionAppCatalog.action(for: voice, installState: .missing), .get)
    }

    /// Standalone releases shipped as Speech.app with the same frozen bundle ID.
    func testStandaloneSpeechAppIsDiscoveredByItsIdentity() throws {
        let url = try makeAppBundle(at: userApps.appendingPathComponent("Speech.app"), bundleIdentifier: CompanionBundleIdentifiers.speech)
        XCTAssertEqual(makeDiscovery().installState(for: CompanionAppCatalog.product(id: .speech)), .installed(url: url))
    }

    func testEmbeddedVoiceWinsOverStandaloneCopies() throws {
        let embedded = try makeAppBundle(
            at: helpers.appendingPathComponent("Voice.app"),
            bundleIdentifier: CompanionBundleIdentifiers.speech
        )
        let registered = try makeAppBundle(
            at: root.appendingPathComponent("RegisteredSpeech.app"),
            bundleIdentifier: CompanionBundleIdentifiers.speech
        )
        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("Speech.app"),
            bundleIdentifier: CompanionBundleIdentifiers.speech
        )
        let locator = FakeLaunchServices()
        locator.urls[CompanionBundleIdentifiers.speech] = registered
        let discovery = makeDiscovery(launchServices: locator, helpersDirectory: helpers)
        let voice = CompanionAppCatalog.product(id: .speech)

        XCTAssertEqual(discovery.installState(for: voice), .installed(url: embedded))
        let launcher = CompanionAppLauncher(
            catalog: CompanionAppCatalog.firstParty,
            discovery: discovery,
            opener: FakeCompanionURLOpener()
        )
        XCTAssertEqual(try launcher.resolveOpenTarget(voice).get(), embedded)
        XCTAssertEqual(
            CompanionAppMenuModel.make(discovery: discovery).items.first { $0.productID == .speech }?.action,
            .open
        )

        try FileManager.default.removeItem(at: embedded)
        XCTAssertEqual(discovery.installState(for: voice), .installed(url: registered))
    }

    func testEmbeddedHelperIsValidatedByIdentity() throws {
        _ = try makeAppBundle(
            at: helpers.appendingPathComponent("Voice.app"),
            bundleIdentifier: "com.example.not-voice"
        )
        let standalone = try makeAppBundle(
            at: userApps.appendingPathComponent("Speech.app"),
            bundleIdentifier: CompanionBundleIdentifiers.speech
        )
        let discovery = makeDiscovery(helpersDirectory: helpers)

        XCTAssertNil(discovery.embeddedURL(bundleIdentifier: CompanionBundleIdentifiers.speech))
        XCTAssertEqual(
            discovery.installState(for: CompanionAppCatalog.product(id: .speech)),
            .installed(url: standalone)
        )
    }

    func testHelpersDirectoryExistsOnlyInsideAnAppBundle() {
        XCTAssertEqual(
            CompanionAppDiscovery.helpersDirectory(
                inAppAt: URL(fileURLWithPath: "/Applications/Lattices.app", isDirectory: true)
            )?.path,
            "/Applications/Lattices.app/Contents/Helpers"
        )
        XCTAssertNil(CompanionAppDiscovery.helpersDirectory(
            inAppAt: URL(fileURLWithPath: "/tmp/lattices/.build/release", isDirectory: true)
        ))
    }

    func testMenuModelRefreshesFromCurrentDiscovery() throws {
        let discovery = makeDiscovery()
        var model = CompanionAppMenuModel.make(discovery: discovery)
        XCTAssertEqual(model.items.map(\.action), [.get, .get, .get])
        XCTAssertEqual(model.items.map(\.actionTitle), ["Install", "Install", "Install"])
        XCTAssertEqual(
            model.items.first { $0.productID == .speech }?.statusText,
            nil
        )
        XCTAssertTrue(model.items.contains { $0.actionTitle == "Install" })

        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        model = CompanionAppMenuModel.make(discovery: discovery)
        XCTAssertEqual(model.items.first { $0.productID == .blink }?.action, .open)
        XCTAssertEqual(model.items.first { $0.productID == .action }?.action, .get)
        XCTAssertEqual(model.items.first { $0.productID == .speech }?.action, CompanionAppAction.get)
    }

    func testOpenRevalidatesDeletedTargetAndReportsFailure() throws {
        let blinkURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let opener = FakeCompanionURLOpener()
        var launcher = CompanionAppLauncher(
            catalog: CompanionAppCatalog.firstParty,
            discovery: makeDiscovery(),
            opener: opener
        )
        XCTAssertEqual(
            try launcher.resolveOpenTarget(CompanionAppCatalog.product(id: .blink)).get(),
            blinkURL
        )

        try FileManager.default.removeItem(at: blinkURL)
        let expectation = expectation(description: "open reports missing after delete")
        launcher.open(CompanionAppCatalog.product(id: .blink)) { result in
            XCTAssertEqual(result, .failed(.notInstalled))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertTrue(opener.openedApplications.isEmpty)
    }

    func testOpenReportsLaunchFailureFromOpener() throws {
        let blinkURL = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        let opener = FakeCompanionURLOpener()
        opener.applicationError = NSError(
            domain: "CompanionAppDiscoveryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Workspace rejected the launch."]
        )
        let launcher = CompanionAppLauncher(
            catalog: CompanionAppCatalog.firstParty,
            discovery: makeDiscovery(),
            opener: opener
        )
        let expectation = expectation(description: "open reports workspace failure")
        launcher.open(CompanionAppCatalog.product(id: .blink)) { result in
            XCTAssertEqual(result, .failed(.launchFailed("Workspace rejected the launch.")))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(opener.openedApplications, [blinkURL])
    }

    func testGetOpensOfficialProductPage() {
        let opener = FakeCompanionURLOpener()
        let launcher = CompanionAppLauncher(
            catalog: CompanionAppCatalog.firstParty,
            discovery: makeDiscovery(),
            opener: opener
        )
        let result = launcher.get(CompanionAppCatalog.product(id: .action))
        XCTAssertEqual(result, .openedProductPage(url: CompanionProductPages.action))
        XCTAssertEqual(opener.openedURLs, [CompanionProductPages.action])
        XCTAssertTrue(opener.openedApplications.isEmpty)
    }

    func testVoiceProductPageIsOptional() {
        let opener = FakeCompanionURLOpener()
        let launcher = CompanionAppLauncher(
            catalog: CompanionAppCatalog.firstParty,
            discovery: makeDiscovery(),
            opener: opener
        )
        XCTAssertEqual(
            launcher.get(CompanionAppCatalog.product(id: .speech)),
            .failed(.missingProductPage)
        )
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAppsSubmenuRebuildsOpenAndGetOnPresentation() throws {
        let controller = CompanionAppsMenuController(
            catalog: CompanionAppCatalog.firstParty,
            discovery: makeDiscovery(),
            launcher: CompanionAppLauncher(
                catalog: CompanionAppCatalog.firstParty,
                discovery: makeDiscovery(),
                opener: FakeCompanionURLOpener()
            ),
            presentFailure: { _, _ in }
        )
        let root = NSMenu()
        controller.attach(to: root)
        let apps = try XCTUnwrap(root.items.first { $0.title == CompanionAppsMenu.title }?.submenu)
        XCTAssertEqual(apps.item(at: 0)?.title, "Canvas")
        XCTAssertEqual(apps.item(at: 0)?.submenu?.item(at: 0)?.title, "Install")
        XCTAssertEqual(apps.item(at: 1)?.submenu?.item(at: 0)?.title, "Install")
        XCTAssertEqual(
            apps.item(at: 2)?.submenu?.item(at: 0)?.title,
            "Install"
        )
        XCTAssertTrue(apps.item(at: 2)?.submenu?.item(at: 0)?.isEnabled ?? false)

        _ = try makeAppBundle(
            at: userApps.appendingPathComponent("Blink.app"),
            bundleIdentifier: CompanionBundleIdentifiers.blink
        )
        controller.menuNeedsUpdate(apps)
        XCTAssertEqual(apps.item(at: 0)?.submenu?.item(at: 0)?.title, "Open")
        XCTAssertEqual(apps.item(at: 1)?.submenu?.item(at: 0)?.title, "Install")
        XCTAssertTrue(
            apps.items.contains { item in
                item.title == "Install" || item.submenu?.items.contains { $0.title == "Install" } == true
            }
        )
    }

    private func makeDiscovery(
        launchServices: CompanionLaunchServicesLocating = FakeLaunchServices(),
        helpersDirectory: URL? = nil
    ) -> CompanionAppDiscovery {
        CompanionAppDiscovery(
            launchServices: launchServices,
            identityReader: PlistCompanionBundleIdentityReader(),
            fileSystem: FoundationCompanionAppFileSystem(),
            applicationsDirectories: [userApps, systemApps],
            helpersDirectory: helpersDirectory
        )
    }

    @discardableResult
    private func makeAppBundle(at url: URL, bundleIdentifier: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Fixture",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: true)
    }
}

private final class FakeLaunchServices: CompanionLaunchServicesLocating {
    var urls: [String: URL] = [:]

    func urlForApplication(bundleIdentifier: String) -> URL? {
        urls[bundleIdentifier]
    }
}

private final class FakeCompanionURLOpener: CompanionURLOpening {
    var openedApplications: [URL] = []
    var openedURLs: [URL] = []
    var applicationError: Error?
    var urlOpenSucceeds = true

    func openApplication(at url: URL, completion: @escaping (Error?) -> Void) {
        openedApplications.append(url)
        completion(applicationError)
    }

    func openURL(_ url: URL) -> Bool {
        openedURLs.append(url)
        return urlOpenSucceeds
    }
}
