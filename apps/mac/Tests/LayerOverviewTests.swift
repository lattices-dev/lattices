import CoreGraphics
import XCTest
@testable import Lattices

final class LayerOverviewTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 3440, height: 1440)

    /// Where the stage leaves a window: one point in from the corner, less
    /// what macOS clamps back.
    private let parkedFrame = CGRect(x: 3439, y: 1418, width: 1200, height: 800)
    private let tiledFrame = CGRect(x: 0, y: 25, width: 1720, height: 1415)

    private func spot(_ place: LayerRoster.Place?, _ frame: CGRect, hidden: Bool = false) -> LayerOverview.Spot? {
        LayerOverview.spot(place: place, frame: frame, appHidden: hidden, main: main)
    }

    private func window(
        _ wid: UInt32, _ app: String, _ title: String, space: Int = 1, frame: CGRect? = nil, z: Int = 0, hidden: Bool = false
    ) -> WindowEntry {
        let frame = frame ?? tiledFrame
        return WindowEntry(
            wid: wid, app: app, pid: 1, title: title,
            frame: WindowFrame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
            spaceIds: [space], isOnScreen: space == 1, latticesSession: nil, zIndex: z, appHidden: hidden
        )
    }

    private func app(_ app: String, title: String? = nil, launch: String? = nil) -> LayerProject {
        LayerProject(path: nil, group: nil, tile: nil, display: nil, app: app, title: title, url: nil, launch: launch)
    }

    /// Space 1 is the desktop showing, 2 is Desktop 2; Spaces can't place any other.
    private func place(_ spaceIds: [Int]) -> LayerRoster.Place? {
        switch spaceIds.first {
        case 1: return .here
        case 2: return .desktop(2)
        default: return nil
        }
    }

    private func build(_ layers: [Layer], _ windows: [WindowEntry], active: Int? = 0) -> [LayerOverview] {
        LayerOverview.build(
            layers,
            resolution: LayerMembership.resolve(layers, windows: windows),
            active: active,
            main: main,
            place: place,
            missing: { $0.app == "Figma" ? .notOpen : nil }
        )
    }

    func testExitingFocusLeavesDefinitionsAndMembersWithoutAnActiveLayer() {
        let layers = [Layer(id: "notes", label: "Notes", projects: [app("Notes")])]
        let windows = [window(1, "Notes", "Planning", space: 2)]
        let active = build(layers, windows, active: 0)
        let exited = build(layers, windows, active: nil)
        XCTAssertTrue(active[0].isActive)
        XCTAssertFalse(exited[0].isActive)
        XCTAssertEqual(exited[0].id, active[0].id)
        XCTAssertEqual(exited[0].entries, active[0].entries)
        XCTAssertEqual(exited[0].windows[0].spaceIds, [2])
    }

    func testAWindowInThePlaceItsSpacesSay() {
        XCTAssertEqual(spot(.here, tiledFrame), .at(.here))
        XCTAssertEqual(spot(.desktop(2), tiledFrame), .at(.desktop(2)))
        XCTAssertEqual(spot(.display(.left, desktop: nil), CGRect(x: -3840, y: -396, width: 1920, height: 2160)),
                       .at(.display(.left, desktop: nil)))
    }

    func testAWindowInTheCornerIsParked() {
        XCTAssertEqual(spot(.here, parkedFrame), .parked(desktop: nil))
        XCTAssertEqual(spot(.desktop(3), parkedFrame), .parked(desktop: 3))
    }

    func testAHiddenAppsWindowIsHiddenWhereverItIs() {
        XCTAssertEqual(spot(.here, tiledFrame, hidden: true), .hidden)
        XCTAssertEqual(spot(.here, parkedFrame, hidden: true), .hidden)
    }

    func testAWindowSpacesCantPlaceHasNoSpotUnlessItsAppIsHidden() {
        XCTAssertNil(spot(nil, tiledFrame))
        XCTAssertNil(spot(nil, parkedFrame))
        XCTAssertEqual(spot(nil, tiledFrame, hidden: true), .hidden)
    }

    func testTheCornerIsTheStagesForty() {
        XCTAssertTrue(LayerOverview.isParked(CGRect(x: 3400, y: 1000, width: 900, height: 600), main: main))
        XCTAssertFalse(LayerOverview.isParked(CGRect(x: 3399, y: 1000, width: 900, height: 600), main: main))
        // Past the edge: on a display to the right, or below.
        XCTAssertFalse(LayerOverview.isParked(CGRect(x: 3440, y: 1000, width: 900, height: 600), main: main))
        XCTAssertFalse(LayerOverview.isParked(CGRect(x: 3420, y: 1440, width: 900, height: 600), main: main))
    }

    func testNotes() {
        XCTAssertNil(LayerOverview.Spot.at(.here).note)
        XCTAssertEqual(LayerOverview.Spot.at(.desktop(2)).note, "Desktop 2")
        XCTAssertEqual(LayerOverview.Spot.parked(desktop: nil).note, "Parked")
        XCTAssertEqual(LayerOverview.Spot.parked(desktop: 2).note, "Parked, Desktop 2")
        XCTAssertEqual(LayerOverview.Spot.hidden.note, "Hidden")
    }

    func testOnlyWindowsOnAShowingDesktopShow() {
        XCTAssertTrue(LayerOverview.Spot.at(.here).isShowing)
        XCTAssertTrue(LayerOverview.Spot.at(.display(.left, desktop: nil)).isShowing)
        XCTAssertFalse(LayerOverview.Spot.at(.display(.left, desktop: 2)).isShowing)
        XCTAssertFalse(LayerOverview.Spot.at(.desktop(2)).isShowing)
        XCTAssertFalse(LayerOverview.Spot.at(.fullScreen).isShowing)
        XCTAssertFalse(LayerOverview.Spot.parked(desktop: nil).isShowing)
        XCTAssertFalse(LayerOverview.Spot.hidden.isShowing)
    }

    func testOnlyAnotherDisplaysWindowsCantBePutAway() {
        XCTAssertTrue(LayerOverview.Spot.at(.here).canPutAway)
        XCTAssertTrue(LayerOverview.Spot.at(.desktop(2)).canPutAway)
        XCTAssertTrue(LayerOverview.Spot.parked(desktop: nil).canPutAway)
        XCTAssertTrue(LayerOverview.Spot.hidden.canPutAway)
        XCTAssertFalse(LayerOverview.Spot.at(.display(.left, desktop: nil)).canPutAway)
        XCTAssertFalse(LayerOverview.Spot.at(.display(.left, desktop: 2)).canPutAway)
    }

    func testPresence() {
        XCTAssertEqual(LayerOverview.Spot.at(.here).presence, "showing")
        XCTAssertEqual(LayerOverview.Spot.at(.display(.left, desktop: nil)).presence, "showing")
        XCTAssertEqual(LayerOverview.Spot.at(.desktop(2)).presence, "elsewhere")
        XCTAssertEqual(LayerOverview.Spot.at(.display(.left, desktop: 2)).presence, "elsewhere")
        XCTAssertEqual(LayerOverview.Spot.at(.fullScreen).presence, "elsewhere")
        XCTAssertEqual(LayerOverview.Spot.parked(desktop: nil).presence, "parked")
        XCTAssertEqual(LayerOverview.Spot.parked(desktop: 3).presence, "parked")
        XCTAssertEqual(LayerOverview.Spot.hidden.presence, "hidden")
        XCTAssertEqual(LayerOverview.Spot.at(.notOpen).presence, "missing")
    }

    // MARK: Building from a resolution

    func testEachEntryListsTheWindowsItHoldsOnEveryDesktop() {
        let layers = [
            Layer(id: "tideline", label: "Tideline", projects: [
                app("Ghostty", title: "tideline"), app("Google Chrome", title: "tideline"), app("Figma"),
            ], layout: "auto"),
            Layer(id: "mail", label: "Mail", projects: [app("Mail")]),
        ]
        let windows = [
            window(10, "Ghostty", "mini: tideline · claude", z: 0),
            window(11, "Ghostty", "mini: tideline · server", frame: parkedFrame, z: 1),
            window(12, "Google Chrome", "tideline — preview", space: 2, z: 2, hidden: true),
            window(13, "Ghostty", "mini: tideline · logs", space: 2, z: 3),
            window(14, "Mail", "Inbox", space: 2, z: 4),
        ]
        let overviews = build(layers, windows, active: 1)
        XCTAssertEqual(overviews.map(\.id), ["tideline", "mail"])
        XCTAssertEqual(overviews.map(\.isActive), [false, true])
        XCTAssertEqual(overviews[0].layout, "auto")

        let entries = overviews[0].entries
        XCTAssertEqual(entries.map(\.name), ["Ghostty", "Google Chrome", "Figma"])
        XCTAssertEqual(entries.map(\.pattern), ["tideline", "tideline", nil])
        XCTAssertEqual(entries[0].windows.map(\.wid), [10, 11, 13])
        XCTAssertEqual(entries[0].windows.map(\.spot), [.at(.here), .parked(desktop: nil), .at(.desktop(2))])
        XCTAssertEqual(entries[1].windows.map(\.spot), [.hidden])
        XCTAssertNil(entries[1].missing)
        XCTAssertEqual(entries[2].windows, [])
        XCTAssertEqual(entries[2].missing, .notOpen)
        XCTAssertEqual(overviews[0].showingIds, [10])
        XCTAssertEqual(overviews[1].entries[0].windows.map(\.spot), [.at(.desktop(2))])
    }

    func testAWindowIsListedUnderOneLayerOnly() {
        let layers = [
            Layer(id: "browse", label: "Browse", projects: [app("Safari")]),
            Layer(id: "docs", label: "Docs", projects: [app("Safari", title: "Docs")]),
        ]
        let overviews = build(layers, [window(1, "Safari", "Docs — Swift"), window(2, "Safari", "News", z: 1)])
        XCTAssertEqual(overviews[0].windows.map(\.wid), [2])
        XCTAssertEqual(overviews[1].windows.map(\.wid), [1])
    }

    func testWindowsThatArentContentOrCantBePlacedAreLeftOut() {
        let layers = [Layer(id: "notes", label: "Notes", projects: [app("Notes")])]
        let small = window(1, "Notes", "Palette", frame: CGRect(x: 0, y: 25, width: 80, height: 80))
        let nowhere = window(2, "Notes", "Todo", space: 77)
        let overviews = build(layers, [small, nowhere])
        XCTAssertEqual(overviews[0].windows, [])
    }

    /// A member Spaces can't place is kept, apart, as unknown with its
    /// tier; the confirmed windows and counts are as they were.
    func testAMemberSpacesCantPlaceIsUnknownNotDropped() {
        let pinned = window(3, "Notes", "Ideas")
        var entry = app("Notes")
        entry.pins = [LayerPin(pinned)]
        let layers = [Layer(id: "notes", label: "Notes", projects: [entry, app("Zed")])]
        let nowhere = window(2, "Zed", "Todo", space: 77)
        let overviews = build(layers, [pinned, nowhere])
        XCTAssertEqual(overviews[0].windows.map(\.wid), [3])
        XCTAssertEqual(overviews[0].windows.first?.tier, .pin)
        XCTAssertEqual(overviews[0].entries[1].windows, [])
        XCTAssertEqual(overviews[0].entries[1].unknown.map(\.wid), [2])
        XCTAssertEqual(overviews[0].entries[1].unknown.first?.tier, .app)
        XCTAssertEqual(overviews.map(\.windows.count), [1])
    }

    func testEntryNames() {
        func name(_ project: LayerProject, _ index: Int = 0) -> String {
            LayerOverview.name(of: project, at: index, groupLabel: { $0 == "g1" ? "Tideline tabs" : nil })
        }
        func entry(path: String? = nil, group: String? = nil, launch: String? = nil) -> LayerProject {
            LayerProject(path: path, group: group, tile: nil, display: nil, app: nil, title: nil, url: nil, launch: launch)
        }
        XCTAssertEqual(name(app("Ghostty", title: "tideline")), "Ghostty")
        XCTAssertEqual(name(LayerProject(clause: StudioLayerClause(appEquals: "Talkie Agent Dev"))), "App: Talkie Agent Dev")
        XCTAssertEqual(name(entry(launch: "Figma")), "Figma")
        XCTAssertEqual(name(entry(group: "g1")), "Tideline tabs")
        XCTAssertEqual(name(entry(group: "g2")), "g2")
        XCTAssertEqual(name(entry(path: "/Users/me/dev/tideline")), "tideline")
        XCTAssertEqual(name(entry(), 2), "Entry 3")

        XCTAssertEqual(LayerOverview.pattern(of: app("Ghostty", title: "tideline")), "tideline")
        XCTAssertNil(LayerOverview.pattern(of: app("Ghostty")))
        XCTAssertNil(LayerOverview.pattern(of: LayerProject(clause: StudioLayerClause(app: "Ghostty", titleRegex: "^tide"))))
    }

    func testCountsAreEntriesHoldingAWindow() {
        let layers = [
            Layer(id: "tideline", label: "Tideline", projects: [app("Ghostty"), app("Google Chrome"), app("Figma")]),
            Layer(id: "empty", label: "Empty", projects: []),
            Layer(id: "mail", label: "Mail", projects: [app("Mail")]),
        ]
        let windows = [
            window(1, "Ghostty", "one"), window(2, "Ghostty", "two", space: 2, z: 1),
            window(3, "Google Chrome", "tideline", space: 2, z: 2),
        ]
        let counts = LayerMembership.resolve(layers, windows: windows).counts(of: layers)
        XCTAssertEqual(counts.map { $0.running }, [2, 0, 0])
        XCTAssertEqual(counts.map { $0.total }, [3, 0, 1])
    }

    func testShowingIds() {
        let overview = LayerOverview(index: 1, id: "fab", label: "fab", layout: "auto", isActive: false, entries: [
            .init(index: 0, name: "Ghostty", pattern: "mini: fab", windows: [
                .init(wid: 10, app: "Ghostty", title: "mini: fab · claude", spot: .at(.here)),
                .init(wid: 11, app: "Ghostty", title: "mini: fab · docs", spot: .parked(desktop: nil)),
            ], missing: nil),
            .init(index: 1, name: "Google Chrome", pattern: "fab", windows: [], missing: .noWindow),
        ])
        XCTAssertEqual(overview.slot, 2)
        XCTAssertEqual(overview.windows.map(\.wid), [10, 11])
        XCTAssertEqual(overview.showingIds, [10])
    }

    func testScopeIds() {
        let scope = LayerOverview.scopeId(for: "talkie")
        XCTAssertEqual(LayerOverview.layerId(fromScope: scope), "talkie")
        XCTAssertNil(LayerOverview.layerId(fromScope: "8F14E45F-CEA1-467A-9BA6-7C2B1F6E4A10"))
    }

    func testMenusCountWindows() {
        XCTAssertEqual(LayerOverview.countNote(0), "No windows")
        XCTAssertEqual(LayerOverview.countNote(1), "1 window")
        XCTAssertEqual(LayerOverview.countNote(3), "3 windows")
    }

    func testALayersKeyIsItsPadSlot() {
        XCTAssertEqual(LayerOverview.chord(forIndex: 0), "⌘⌥1")
        XCTAssertEqual(LayerOverview.chord(forIndex: 4), "⌘⌥6")
        XCTAssertEqual(LayerOverview.chord(forIndex: 7), "⌘⌥9")
        XCTAssertNil(LayerOverview.chord(forIndex: 8))
    }
}
