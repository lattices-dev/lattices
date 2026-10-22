import CoreGraphics
import XCTest
@testable import Lattices

final class SpaceOptimizationServiceTests: XCTestCase {
    private struct Distribution {
        let targets: [SpaceOptimizationService.Target]
        let region: SpaceOptimizationService.Region?
    }

    private final class Desktop {
        var inventories: [[WindowEntry]]
        var frontmostApp: String?
        var reads = 0
        var events: [String] = []
        var queued: [Distribution] = []
        var applied: [Distribution] = []

        init(_ windows: [WindowEntry], frontmostApp: String? = nil) {
            inventories = [windows]
            self.frontmostApp = frontmostApp
        }

        var service: SpaceOptimizationService {
            SpaceOptimizationService(
                allWindows: {
                    self.events.append("inventory")
                    let windows = self.inventories[min(self.reads, self.inventories.count - 1)]
                    self.reads += 1
                    return windows
                },
                frontmostAppName: {
                    self.events.append("frontmost")
                    return self.frontmostApp
                },
                enqueueDistribution: { targets, region in
                    self.events.append("enqueue")
                    self.queued.append(Distribution(targets: targets, region: region))
                }
            )
        }

        func applyQueued() {
            applied.append(contentsOf: queued)
            queued.removeAll()
        }
    }

    func testDefaultEligibilityPreservesInventoryOrderAndFirstWindowIdentity() throws {
        let desktop = Desktop([
            window(7, title: "", pid: 70),
            window(1, app: "Lattices"),
            window(2, onScreen: false),
            window(3, width: 50),
            window(4, height: 50),
            window(8, app: "lattices", width: 51, height: 51),
            window(7, pid: 71),
        ])
        let result = try desktop.service.optimize(params: nil)

        XCTAssertEqual(result, .object([
            "ok": .bool(true), "scope": .string("visible"), "strategy": .string("balanced"),
            "windowCount": .int(2), "wids": .array([.int(7), .int(8)]),
            "trace": .array([.string("resolved scope visible"), .string("resolved strategy balanced"),
                             .string("using visible window scope")]),
        ]))
        XCTAssertEqual(desktop.events, ["inventory", "enqueue"])
        XCTAssertEqual(desktop.queued.first?.targets.map(\.wid), [7, 8])
        XCTAssertEqual(desktop.queued.first?.targets.map(\.pid), [70, 108])
        XCTAssertNil(desktop.queued.first?.region)
        XCTAssertTrue(desktop.applied.isEmpty, "The receipt acknowledges queued work before application")
        desktop.applyQueued()
        XCTAssertEqual(desktop.applied.count, 1)
    }

    func testScopeInferenceUsesKeyPresenceAndOverridesExplicitScope() throws {
        let cases: [(JSON, String, [Int])] = [
            (.object(["windowIds": .null, "app": .string("Safari"), "type": .string("editor"),
                      "scope": .string("invalid")]), "selection", []),
            (.object(["app": .null, "type": .string("editor"), "scope": .string("invalid")]), "app", []),
            (.object(["type": .null, "scope": .string("invalid")]), "type", []),
            (.object(["app": .string("Safari"), "type": .string("editor"),
                      "scope": .string("active-type")]), "app", [1]),
        ]
        for (params, scope, expected) in cases {
            let desktop = Desktop([window(1), window(2, app: "Xcode")], frontmostApp: "Xcode")
            let result = try desktop.service.optimize(params: params)
            XCTAssertEqual(result["scope"]?.stringValue, scope)
            XCTAssertEqual(ids(result), expected)
            XCTAssertFalse(desktop.events.contains("frontmost"))
            XCTAssertEqual(desktop.queued.count, expected.isEmpty ? 0 : 1)
        }
    }

    func testSelectionUsesInventoryOrderAndIgnoresTitleFilter() throws {
        let desktop = Desktop([window(7), window(2), window(7, pid: 90), window(9)])
        let result = try desktop.service.optimize(params: .object([
            "windowIds": .array([.int(2), .int(7), .int(2), .string("9")]),
            "title": .string("does not occur"),
        ]))
        XCTAssertEqual(ids(result), [7, 2])
        XCTAssertEqual(trace(result), ["resolved scope selection", "resolved strategy balanced", "selection size 3"])
        XCTAssertEqual(desktop.queued.first?.targets.map(\.pid), [107, 102])
    }

    func testAppAndTypeFiltersMatchFullTitlesIgnoringCase() throws {
        var fullTitleWindow = window(1, app: "Safari", title: "elided")
        fullTitleWindow.fullTitle = "An Expanded NEEDLE document"
        let windows = [fullTitleWindow, window(2, app: "Safari", title: "unrelated"),
                       window(3, app: "Firefox", title: "needle")]
        let appDesktop = Desktop(windows)
        let appResult = try appDesktop.service.optimize(params: .object([
            "app": .string("sAfArI"), "title": .string("needle"),
        ]))
        XCTAssertEqual(ids(appResult), [1])
        XCTAssertEqual(trace(appResult).suffix(2), ["filtered by app sAfArI", "title contains needle"])

        let typeDesktop = Desktop(windows)
        let typeResult = try typeDesktop.service.optimize(params: .object([
            "type": .string(" Browser "), "title": .string("NEEDLE"),
        ]))
        XCTAssertEqual(ids(typeResult), [1, 3])
        XCTAssertTrue(trace(typeResult).contains("filtered by type browser"))
    }

    func testVisibleScopeIgnoresTitleAndDoesNotReadFrontmostApp() throws {
        let desktop = Desktop([window(1), window(2, app: "Xcode")], frontmostApp: "Xcode")
        let result = try desktop.service.optimize(params: .object(["title": .string("absent")]))
        XCTAssertEqual(ids(result), [1, 2])
        XCTAssertEqual(desktop.events, ["inventory", "enqueue"])
    }

    func testUnknownOrMissingTypeAndMissingAppYieldSuccessfulEmptyReceipt() throws {
        for params: JSON in [.object(["type": .string("unknown")]), .object(["scope": .string("type")]),
                             .object(["scope": .string("app")])] {
            let desktop = Desktop([window(1)])
            let result = try desktop.service.optimize(params: params)
            XCTAssertEqual(result["ok"], .bool(true))
            XCTAssertEqual(result["windowCount"], .int(0))
            XCTAssertEqual(ids(result), [])
            XCTAssertEqual(trace(result).last, "no eligible windows resolved")
            XCTAssertEqual(desktop.events, ["inventory"])
            XCTAssertTrue(desktop.queued.isEmpty)
        }
    }

    func testActiveAppAliasesReadFrontmostAfterInventoryWithoutFallbackRead() throws {
        for scope in [" Active_App ", "frontmost-app", "current app"] {
            let desktop = Desktop([window(1), window(2, app: "Xcode")], frontmostApp: "safari")
            let result = try desktop.service.optimize(params: .object(["scope": .string(scope)]))
            XCTAssertEqual(ids(result), [1])
            XCTAssertEqual(desktop.events, ["inventory", "frontmost", "enqueue"])
            XCTAssertTrue(trace(result).contains("resolved active app safari"))
        }
    }

    func testActiveAppFallbackRereadsInventoryButFiltersOriginalInventory() throws {
        for frontmost: String? in [nil, "LATTICES Settings"] {
            let desktop = Desktop([window(1), window(2, app: "Xcode")], frontmostApp: frontmost)
            desktop.inventories.append([window(99, app: "Xcode")])
            let result = try desktop.service.optimize(params: .object(["scope": .string("active-app")]))
            XCTAssertEqual(ids(result), [2])
            XCTAssertEqual(desktop.events, ["inventory", "frontmost", "inventory", "enqueue"])
            XCTAssertTrue(trace(result).contains("resolved active app Xcode"))
        }
    }

    func testActiveTypeGroupsKnownAppsButKeepsSystemAndUnknownAppsExact() throws {
        let windows = [window(1, app: "Xcode"), window(2, app: "Code"),
                       window(3, app: "Finder"), window(4, app: "Activity Monitor"),
                       window(5, app: "Custom One"), window(6, app: "Custom Two")]
        for scope in ["active-type", "frontmost-type", "current-type"] {
            let desktop = Desktop(windows, frontmostApp: "Xcode")
            let result = try desktop.service.optimize(params: .object(["scope": .string(scope)]))
            XCTAssertEqual(ids(result), [1, 2])
        }
        for (app, expected) in [("Finder", 3), ("Custom One", 5)] {
            let desktop = Desktop(windows, frontmostApp: app)
            let result = try desktop.service.optimize(params: .object(["scope": .string("active-type")]))
            XCTAssertEqual(ids(result), [expected])
        }
        let desktop = Desktop(windows)
        let result = try desktop.service.optimize(params: .object(["type": .string("system")]))
        XCTAssertEqual(ids(result), [3, 4], "Explicit type scope still includes every system app")
    }

    func testEmptyActiveScopeResolvesFallbackWithoutEnqueuing() throws {
        let desktop = Desktop([])
        let result = try desktop.service.optimize(params: .object(["scope": .string("active-app")]))
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(trace(result), ["resolved scope active-app", "resolved strategy balanced",
                                      "no active app available", "no eligible windows resolved"])
        XCTAssertEqual(desktop.events, ["inventory", "frontmost", "inventory"])
        XCTAssertTrue(desktop.queued.isEmpty)
    }

    func testInvalidScopeOrStrategyThrowsBeforeInventoryOrEffects() {
        let cases: [(JSON, String)] = [
            (.object(["scope": .string("unsupported")]), "Unsupported optimization scope: unsupported"),
            (.object(["strategy": .string("unsupported")]), "Unsupported optimization strategy: unsupported"),
        ]
        for (params, message) in cases {
            let desktop = Desktop([window(1)])
            XCTAssertThrowsError(try desktop.service.optimize(params: params)) { error in
                XCTAssertEqual(error.localizedDescription, message)
            }
            XCTAssertTrue(desktop.events.isEmpty)
        }
    }

    func testRegionAndMosaicAreCapturedWithoutApplyingDistribution() throws {
        let desktop = Desktop([window(1), window(2)])
        let result = try desktop.service.optimize(params: .object([
            "region": .string("right"), "strategy": .string(" Mosaic "),
        ]))
        let distribution = try XCTUnwrap(desktop.queued.first)
        let region = try XCTUnwrap(distribution.region)
        XCTAssertEqual([region.0, region.1, region.2, region.3], [0.5, 0, 0.5, 1])
        XCTAssertEqual(distribution.targets.map(\.wid), [1, 2])
        XCTAssertEqual(result["strategy"], .string("mosaic"))
        XCTAssertEqual(trace(result).last, "strategy mosaic currently uses the smart-grid distributor")
        XCTAssertTrue(trace(result).contains { $0.hasPrefix("region right → fractions ") })
        XCTAssertTrue(desktop.applied.isEmpty)
    }

    func testUnknownRegionFallsBackAndEmptyScopeStillReportsRegionAndStrategy() throws {
        let desktop = Desktop([window(1)])
        let result = try desktop.service.optimize(params: .object(["region": .string("unknown")]))
        XCTAssertNil(desktop.queued.first?.region)
        XCTAssertEqual(trace(result).last, "unknown region unknown, using full screen")

        let emptyDesktop = Desktop([])
        let empty = try emptyDesktop.service.optimize(params: .object([
            "region": .string("unknown"), "strategy": .string("mosaic"),
        ]))
        XCTAssertEqual(trace(empty).suffix(3), ["unknown region unknown, using full screen",
                                              "strategy mosaic currently uses the smart-grid distributor",
                                              "no eligible windows resolved"])
        XCTAssertTrue(emptyDesktop.queued.isEmpty)
    }

    func testCompatibilityEntryPointPreservesCanonicalReceiptsAndEffects() throws {
        let requests: [JSON?] = [nil, .string("ignored"), .object(["app": .string("Safari")]),
                                .object(["type": .string("editor"), "region": .string("right")]),
                                .object(["windowIds": .array([.int(2)]), "scope": .string("visible"),
                                         "strategy": .string("mosaic")])]
        for params in requests {
            let windows = [window(1), window(2, app: "Xcode")]
            let canonical = Desktop(windows)
            let compatibility = Desktop(windows)
            XCTAssertEqual(try compatibility.service.distribute(params: params),
                           try canonical.service.optimize(params: params))
            XCTAssertEqual(compatibility.events, canonical.events)
            XCTAssertEqual(compatibility.queued.first?.targets.map(\.wid), canonical.queued.first?.targets.map(\.wid))
            XCTAssertEqual(compatibility.queued.count, canonical.queued.count)
        }
    }

    private func window(_ id: UInt32, app: String = "Safari", title: String = "Document",
                        width: Double = 400, height: Double = 300, onScreen: Bool = true,
                        pid: Int32? = nil) -> WindowEntry {
        WindowEntry(wid: id, app: app, pid: pid ?? Int32(id + 100), title: title,
                    frame: WindowFrame(x: 0, y: 0, w: width, h: height), spaceIds: [1],
                    isOnScreen: onScreen, latticesSession: nil)
    }

    private func ids(_ result: JSON) -> [Int] {
        result["wids"]?.arrayValue?.compactMap(\.intValue) ?? []
    }

    private func trace(_ result: JSON) -> [String] {
        result["trace"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
