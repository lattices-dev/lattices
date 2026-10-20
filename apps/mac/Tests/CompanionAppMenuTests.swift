import AppKit
import XCTest
@testable import Lattices

final class CompanionAppMenuTests: XCTestCase {
    @MainActor
    func testActualMenuDispatchesEachMissingProductToInstaller() {
        _ = NSApplication.shared // NSMenu dispatch uses NSApp; no application run loop is launched.
        struct MissingApps: CompanionLaunchServicesLocating {
            func urlForApplication(bundleIdentifier: String) -> URL? { nil }
        }
        let discovery = CompanionAppDiscovery(launchServices: MissingApps(), identityReader: PlistCompanionBundleIdentityReader(), fileSystem: FoundationCompanionAppFileSystem(), applicationsDirectories: [])
        var requested: [CompanionProductID] = []
        let controller = CompanionAppsMenuController(discovery: discovery, install: { requested.append($0) })
        let root = NSMenu()
        controller.attach(to: root)
        let apps = root.items.first!.submenu!
        XCTAssertEqual(apps.items.map(\.title), ["Canvas", "Action", "Voice"])
        for product in apps.items {
            let menu = product.submenu!
            XCTAssertEqual(menu.items.last?.title, "Install")
            menu.performActionForItem(at: menu.numberOfItems - 1)
        }
        XCTAssertEqual(requested, [.blink, .action, .speech])
    }
}
