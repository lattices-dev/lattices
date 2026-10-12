import AppKit
import XCTest
@testable import Lattices

/// Overview from fixtures: the projection, the model's selection, scope and
/// edits, and every desktop call through a spy. No live windows, AX or
/// window-server reads.
final class OverviewProjectionTests: XCTestCase {
    // MARK: Fixtures

    private let main = CGRect(x: 0, y: 0, width: 3440, height: 1440)

    /// The main monitor shows Desktop 1 of three; the right one shows its
    /// second desktop and has a full-screen Space beside them.
    private lazy var displays = [
        OverviewDisplay(index: 0, name: "Studio", bounds: main, desktops: [1, 2, 3], currentSpaceId: 1, displayId: 1),
        OverviewDisplay(
            index: 1, name: "Side", bounds: CGRect(x: 3440, y: 0, width: 1920, height: 1080),
            desktops: [10, 11], currentSpaceId: 11, spaceIds: [10, 11, 12], displayId: 2
        ),
    ]

    private func window(
        _ wid: UInt32, _ app: String, _ title: String, spaces: [Int], frame: CGRect,
        hidden: Bool = false, collapsed: Bool = false, session: String? = nil
    ) -> WindowEntry {
        var entry = WindowEntry(
            wid: wid, app: app, pid: Int32(wid) + 100, title: title,
            frame: WindowFrame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
            spaceIds: spaces, isOnScreen: false, latticesSession: session, zIndex: Int(wid), appHidden: hidden
        )
        entry.collapsed = collapsed
        return entry
    }

    private let home = CGRect(x: 300, y: 200, width: 900, height: 600)
    private let parkedFrame = CGRect(x: 3420, y: 1000, width: 900, height: 600)

    /// 1 showing, 2 on Desktop 3, 3 showing on the side monitor, 4 a hidden
    /// app's collapsed window, 5 parked, 6 minimized or closed, 7 full
    /// screen, 8 on Desktop 2 with no usable frame.
    private lazy var windows: [WindowEntry] = [
        window(1, "Ghostty", "tideline: dev", spaces: [1], frame: CGRect(x: 100, y: 100, width: 1200, height: 800), session: "tideline"),
        window(2, "Zed", "tideline", spaces: [3], frame: CGRect(x: 200, y: 100, width: 1200, height: 800)),
        window(3, "Safari", "Docs", spaces: [11], frame: CGRect(x: 3500, y: 100, width: 1200, height: 800)),
        window(4, "Mail", "Inbox", spaces: [1], frame: CGRect(x: 1400, y: 100, width: 1000, height: 700), hidden: true, collapsed: true),
        window(5, "Notes", "Todo", spaces: [1], frame: parkedFrame),
        window(6, "Figma", "Tideline", spaces: [], frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
        window(7, "Keynote", "Deck", spaces: [12], frame: CGRect(x: 3440, y: 0, width: 1920, height: 1080)),
        window(8, "Ghostty", "scratch", spaces: [2], frame: .zero),
    ]

    private func member(_ wid: UInt32, tier: LayerMembership.Tier) -> LayerOverview.Window {
        let entry = windows.first { $0.wid == wid }!
        return LayerOverview.Window(
            wid: wid, app: entry.app, title: entry.title, spot: .at(.here), spaceIds: entry.spaceIds,
            frame: CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h), tier: tier
        )
    }

    /// Tideline holds 1 (pinned), 2 and 3 across both monitors and three
    /// Spaces, 6 unknown, and keeps 5 tucked; Mail holds 4.
    private func layers(tidelineActive: Bool = true) -> [LayerOverview] {
        [
            LayerOverview(index: 0, id: "tideline", label: "Tideline", layout: "auto", isActive: tidelineActive, entries: [
                .init(index: 0, name: "Ghostty", pattern: nil, windows: [member(1, tier: .pin)], missing: nil),
                .init(index: 1, name: "Zed", pattern: nil, windows: [member(2, tier: .app), member(3, tier: .app)], missing: nil,
                      unknown: [.init(wid: 6, app: "Figma", title: "Tideline", tier: .app)]),
            ]),
            LayerOverview(index: 1, id: "mail", label: "Mail", layout: nil, isActive: !tidelineActive, entries: [
                .init(index: 0, name: "Mail", pattern: nil, windows: [member(4, tier: .app)], missing: nil),
            ]),
        ]
    }

    /// Scene extras: Tideline's 8 is unclaimed; its 4 has since been taken
    /// by Mail.
    private func inputs(windows: [WindowEntry]? = nil, tidelineActive: Bool = true) -> OverviewProjection.Inputs {
        OverviewProjection.Inputs(
            windows: windows ?? self.windows,
            layers: layers(tidelineActive: tidelineActive),
            displays: displays,
            main: main,
            homes: [5: home],
            tucked: ["tideline": [5]],
            extras: ["tideline": [8, 4]],
            appType: { ["Ghostty": .terminal, "Zed": .editor, "Safari": .browser][$0] ?? .other }
        )
    }

    private func project(_ scope: OverviewScope = .all, selection: Set<UInt32> = []) -> OverviewProjection {
        OverviewProjection.make(inputs(), scope: scope, selection: selection)
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var spy: SpyActions!

    override func setUp() {
        super.setUp()
        suiteName = "overview.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        spy = SpyActions()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func model(_ inputs: OverviewProjection.Inputs? = nil) -> OverviewModel {
        OverviewModel(defaults: defaults, actions: spy, inputs: inputs ?? self.inputs())
    }

    // MARK: Scope and selection (plan 1–7)

    func testFirstOpenIsAllAndASavedScopeComesBack() {
        XCTAssertEqual(OverviewScope.load(from: defaults), .all)
        let first = model()
        XCTAssertEqual(first.scope, .all)
        first.scope = OverviewScope(display: 0, spaceId: 3, layerId: "tideline", search: "zed", preset: "Editors")
        XCTAssertEqual(model().scope, OverviewScope(display: 0, spaceId: 3, layerId: "tideline", search: "zed", preset: "Editors"))
    }

    func testASavedPickOfAGoneLayerIsDropped() {
        OverviewScope(layerIds: ["terms", "mail"], scopedWindowIds: []).save(to: defaults)
        let model = model()
        model.update(inputs())
        XCTAssertEqual(model.scope.layerIds, ["mail"])
        XCTAssertFalse(model.workingRows.isEmpty)
    }

    func testScopeChangesKeepTheSelectionAndSayWhyRowsAreOutside() {
        let model = model()
        model.setSelection([1, 3])
        model.scope.display = 0
        XCTAssertEqual(model.selection, [1, 3])
        XCTAssertEqual(model.projection.outOfScopeSelection.map(\.wid), [3])
        XCTAssertEqual(model.projection.outOfScopeSelection.first?.reason, .outsideMonitor)

        model.scope.spaceId = 3
        XCTAssertEqual(model.projection.outOfScopeSelection.first { $0.wid == 1 }?.reason, .outsideSpace)

        model.scope = .all
        model.scope.search = "safari"
        XCTAssertEqual(model.selection, [1, 3])
        XCTAssertEqual(model.projection.outOfScopeSelection.first?.wid, 1)
        XCTAssertEqual(model.projection.outOfScopeSelection.first?.reason, .search)

        model.scope = .all
        model.scope.layerId = "mail"
        XCTAssertEqual(Set(model.projection.outOfScopeSelection.map(\.reason)), [.outsideLayer])
        XCTAssertEqual(spy.calls, [], "browsing never touches the desktop")
    }

    func testShowInScopeGoesToDesktopThreeSelectsAndOnlySetsState() {
        let model = model()
        model.scope.display = 1
        model.showInScope(2)
        XCTAssertEqual(model.scope.display, 0)
        XCTAssertEqual(model.scope.spaceId, 3)
        XCTAssertTrue(model.selection.contains(2))
        XCTAssertTrue(model.projection.all[2]!.inScope)
        XCTAssertEqual(model.revealRequest, .init(wid: 2, serial: 1))
        XCTAssertEqual(spy.calls, [])
    }

    func testShowInScopeAsksForAScrollEvenWhenTheRowIsAlreadyFocused() {
        let model = model()
        model.select(2)
        model.scope.search = "safari"
        XCTAssertFalse(model.projection.inScopeRows.contains { $0.wid == 2 })
        model.showInScope(2)
        model.showInScope(2)
        XCTAssertEqual(model.revealRequest, .init(wid: 2, serial: 2))
    }

    func testShowInScopeClearsOnlyTheFilterThatHidesTheRow() {
        let hiddenBySearch = OverviewProjection.scope(
            showing: 1, from: OverviewScope(search: "safari", preset: "Terminals"), inputs: inputs()
        )
        XCTAssertEqual(hiddenBySearch?.search, "")
        XCTAssertEqual(hiddenBySearch?.preset, "Terminals")

        let hiddenByPreset = OverviewProjection.scope(
            showing: 3, from: OverviewScope(search: "docs", preset: "Terminals"), inputs: inputs()
        )
        XCTAssertEqual(hiddenByPreset?.search, "docs")
        XCTAssertNil(hiddenByPreset?.preset)
        XCTAssertEqual(hiddenByPreset?.display, 1)
        XCTAssertEqual(hiddenByPreset?.spaceId, 11)

        let hiddenByLayer = OverviewProjection.scope(showing: 4, from: OverviewScope(layerId: "tideline"), inputs: inputs())
        XCTAssertNil(hiddenByLayer?.layerId)

        let model = model()
        model.scope = OverviewScope(search: "safari", preset: "Terminals")
        model.showInScope(1)
        XCTAssertTrue(model.projection.inScopeRows.contains { $0.wid == 1 })
    }

    func testCanvasSelectionReplacesOnlyItsOwnPart() {
        let model = model()
        XCTAssertEqual(model.canvasWids, [1, 3])
        model.setSelection([2, 1])
        model.canvasSelected([3])
        XCTAssertEqual(model.selection, [2, 3])
        model.canvasSelected([3, 99])
        XCTAssertEqual(model.selection, [2, 3], "a window the canvas doesn't draw isn't taken from it")
        model.canvasSelected([])
        XCTAssertEqual(model.selection, [2])
        XCTAssertEqual(model.canvasHost.selected, [2])
    }

    func testOnlyAClearOrAClosedWindowEmptiesTheSelection() {
        let model = model()
        model.setSelection([1, 2, 5])
        model.update(inputs())
        model.scope.search = "nothing matches"
        model.scope.preset = "Browsers"
        model.scope = OverviewScope(display: 1, spaceId: 11, layerId: "mail")
        XCTAssertEqual(model.selection, [1, 2, 5])

        model.update(inputs(windows: windows.filter { $0.wid != 2 }))
        XCTAssertEqual(model.selection, [1, 5])
        model.clearSelection()
        XCTAssertEqual(model.selection, [])
    }

    func testTheSharedStoreGetsTheWholeSelectionWhileOverviewOwnsIt() {
        let store = WindowSelectionStore.shared
        let model = model()
        model.claimSharedSelection()
        model.setSelection([1, 2])
        model.scope.display = 1
        model.update(inputs())
        model.canvasSelected([])
        drainMain()
        XCTAssertEqual(Set(store.windowIds), [1, 2], "a scope change, refresh or canvas trim keeps the shared selection")
        XCTAssertEqual(store.source, OverviewModel.selectionSource)

        model.releaseSharedSelection()
        model.setSelection([3])
        drainMain()
        XCTAssertEqual(Set(store.windowIds), [1, 2], "released, Overview stops publishing")
        store.clear()
        drainMain()
    }

    private func drainMain() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    // MARK: List keys and the hosted canvas

    func testListArrowsStepAndExtend() {
        let model = model()
        let rows = model.projection.rows.map(\.wid)
        model.step(1, extend: false)
        XCTAssertEqual(model.selection, [rows[0]])
        model.step(1, extend: true)
        XCTAssertEqual(model.selection, [rows[0], rows[1]])
        XCTAssertEqual(model.focusedWid, rows[1])
        model.step(-5, extend: false)
        XCTAssertEqual(model.selection, [rows[0]])
    }

    func testCanvasKeysOnlyWhileTheCanvasHasFocus() {
        func route(_ key: UInt16, _ mods: NSEvent.ModifierFlags = [], focused: Bool = true, searching: Bool = false) -> OverviewModel.CanvasKeyRoute {
            OverviewModel.canvasKeyRoute(key, modifiers: mods, canvasFocused: focused, searching: searching)
        }
        XCTAssertEqual(route(17), .overview(.bulk(.tile)))
        XCTAssertEqual(route(2), .overview(.bulk(.distribute)))
        XCTAssertEqual(route(123), .overview(.monitor(-1)))
        XCTAssertEqual(route(124), .overview(.monitor(1)))
        XCTAssertEqual(route(44), .overview(.search))
        for key: UInt16 in [0, 7, 18, 19, 20, 21, 15, 29, 49] { XCTAssertEqual(route(key), .canvas, "key \(key)") }

        // The list and native controls: ↑ ↓ Return Tab Escape pass, and
        // with the canvas unfocused so does every key, Space included.
        for key: UInt16 in [125, 126, 36, 48, 53, 3, 8] { XCTAssertEqual(route(key), .pass, "key \(key)") }
        for key: UInt16 in [17, 2, 123, 124, 44, 0, 49, 125, 126, 36, 48, 53] {
            XCTAssertEqual(route(key, focused: false), .pass, "unfocused key \(key)")
        }
        XCTAssertEqual(route(17, .command), .pass)
        XCTAssertEqual(route(123, .shift), .pass)
        XCTAssertEqual(route(17, searching: true), .pass)
        XCTAssertEqual(route(17, .capsLock), .overview(.bulk(.tile)), "caps lock isn't a modifier")
    }

    func testMonitorStepsMoveTheSharedScopeLeftToRight() {
        let model = model()
        model.scope.spaceId = 3
        model.stepMonitor(1)
        XCTAssertEqual(model.scope.display, 0)
        XCTAssertNil(model.scope.spaceId)
        model.stepMonitor(1)
        XCTAssertEqual(model.scope.display, 1)
        model.stepMonitor(1)
        XCTAssertNil(model.scope.display, "wraps to All monitors")
        model.stepMonitor(-1)
        XCTAssertEqual(model.scope.display, 1)
        XCTAssertEqual(spy.calls, [])
    }

    func testSlashAsksForOverviewsSearch() {
        let model = model()
        model.requestSearch()
        XCTAssertEqual(model.searchRequest, 1)
    }

    // MARK: Counts and membership (plan 8–11)

    func testALayerAcrossTwoMonitorsAndThreeSpacesCountsDistinctWindows() {
        let scoped = project(OverviewScope(layerId: "tideline"))
        // Members 1 2 3, tucked 5, unclaimed 8; 6 unknown, apart.
        XCTAssertEqual(scoped.counts.matched, 5)
        XCTAssertEqual(scoped.counts.unknown, 1)
        XCTAssertEqual(Set(scoped.rows.map(\.wid)), [1, 2, 3, 5, 6, 8])
    }

    func testAMonitorWithoutMembersStillListsThemAll() {
        let layer = OverviewProjection.make(
            inputs(), scope: OverviewScope(display: 1, spaceId: 10, layerId: "mail"), selection: []
        )
        XCTAssertEqual(layer.counts.line, "1 matched window · 0 in this scope · 1 elsewhere")
        XCTAssertEqual(layer.rows.map(\.wid), [4])
    }

    func testStatesStayDistinct() {
        let all = project().all
        XCTAssertEqual(all[1]?.state, .showing)
        XCTAssertEqual(all[2]?.state, .otherSpace(desktop: 3))
        XCTAssertEqual(all[3]?.state, .showing, "each monitor has its own current Space")
        XCTAssertEqual(all[4]?.state, .appHidden)
        XCTAssertEqual(all[5]?.state, .parked)
        XCTAssertEqual(all[6]?.state, .unknown)
        XCTAssertEqual(all[7]?.state, .fullScreen)
        XCTAssertEqual(all[8]?.state, .otherSpace(desktop: 2))

        let tideline = project(OverviewScope(layerId: "tideline")).all
        XCTAssertEqual(tideline[1]?.role, .member)
        XCTAssertEqual(tideline[5]?.role, .tucked)
        XCTAssertEqual(tideline[8]?.role, .unclaimed)
    }

    /// A monitor showing its full-screen Space: the window there is still
    /// full screen, never showing, and no action takes it.
    func testAFullScreenSpaceThatIsCurrentIsStillFullScreen() {
        var fixture = inputs()
        fixture.displays[1] = OverviewDisplay(
            index: 1, name: "Side", bounds: displays[1].bounds,
            desktops: [10, 11], currentSpaceId: 12, spaceIds: [10, 11, 12], displayId: 2
        )
        let projection = OverviewProjection.make(fixture, scope: .all, selection: [7])
        XCTAssertEqual(projection.all[7]?.state, .fullScreen)
        XCTAssertEqual(projection.all[3]?.state, .otherSpace(desktop: 2))
        XCTAssertFalse(projection.canvas.contains { $0.wid == 7 })

        let plan = projection.bulk(.tile, selection: [7, 3])
        XCTAssertFalse(plan.isEnabled)
        XCTAssertEqual(Set(plan.excluded.map(\.reason)), [.fullScreen, .otherSpace(desktop: 2)])
        XCTAssertEqual(projection.placeExclusion(7), .fullScreen)
        XCTAssertEqual(projection.moveTargets(for: 7).count, 0)

        let model = model(fixture)
        model.setSelection([7])
        XCTAssertEqual(model.run(model.plan(.distribute)), 0)
        XCTAssertFalse(model.place(7, at: .maximize))
        XCTAssertFalse(model.move(7, toSpace: 10))
        XCTAssertEqual(spy.calls, [])
    }

    /// A selected window the search hides changes Space, then monitor. The
    /// visible list doesn't change, but the plan must.
    func testAHiddenSelectedWindowsMoveStillReachesTheBulkPlan() {
        let model = model()
        model.scope.search = "safari"
        model.setSelection([2])
        let visible = model.projection.groups
        XCTAssertFalse(model.plan(.tile).isEnabled, "on Desktop 3")

        var moved = windows
        moved[1] = window(2, "Zed", "tideline", spaces: [1], frame: CGRect(x: 200, y: 100, width: 1200, height: 800))
        model.update(inputs(windows: moved))
        XCTAssertEqual(model.projection.groups, visible)
        XCTAssertEqual(model.plan(.tile).groups.map(\.displayId), [1])

        moved[1] = window(2, "Zed", "tideline", spaces: [11], frame: CGRect(x: 3600, y: 100, width: 1200, height: 800))
        model.update(inputs(windows: moved))
        XCTAssertEqual(model.projection.groups, visible)
        XCTAssertEqual(model.plan(.tile).groups.map(\.displayId), [2])
        XCTAssertEqual(model.run(model.plan(.tile)), 1)
        XCTAssertEqual(spy.distributed.map(\.displayId), [2])
        XCTAssertEqual(model.projection.placeExclusion(2), nil)
    }

    func testAHiddenWindowWithNoSpaceIsUnknownAndAHiddenParkedOneIsParked() {
        var hiddenNowhere = windows[5]
        hiddenNowhere.appHidden = true
        var hiddenParked = windows[4]
        hiddenParked.appHidden = true
        let all = OverviewProjection.make(inputs(windows: [hiddenNowhere, hiddenParked]), scope: .all, selection: []).all
        XCTAssertEqual(all[6]?.state, .unknown)
        XCTAssertEqual(all[5]?.state, .parked)
        XCTAssertEqual(all[5]?.frame, home)
    }

    func testAStickyWindowGoesWhereItsGeometryIs() {
        let sticky = window(9, "Clock", "Clock", spaces: [1, 11], frame: CGRect(x: 4000, y: 100, width: 400, height: 400))
        let row = OverviewProjection.make(inputs(windows: [sticky]), scope: .all, selection: []).all[9]
        XCTAssertEqual(row?.display, 1)
        XCTAssertEqual(row?.spaceId, 11)
        XCTAssertEqual(row?.state, .showing)
    }

    func testAPinnedMemberSaysPinAndARuleMemberSaysItsRule() {
        let all = project().all
        XCTAssertEqual(all[1]?.tier, .pin)
        XCTAssertEqual(all[2]?.tier, .app)
        XCTAssertEqual(all[6]?.tier, .app)
        XCTAssertNil(all[8]?.tier)
    }

    /// A scene extra another layer has claimed since is that layer's: not
    /// Unclaimed in the old one, as `LayerStage.want` leaves it out.
    func testASceneExtraAnotherLayerClaimedIsntUnclaimed() {
        let tideline = project(OverviewScope(layerId: "tideline"))
        XCTAssertNil(tideline.all[4]?.role)
        XCTAssertFalse(tideline.rows.contains { $0.wid == 4 })
        XCTAssertEqual(tideline.all[8]?.role, .unclaimed)

        var tuckedElsewhere = inputs()
        tuckedElsewhere.tucked["mail"] = [8]
        XCTAssertNil(OverviewProjection.make(tuckedElsewhere, scope: OverviewScope(layerId: "tideline"), selection: []).all[8]?.role)
    }

    // MARK: Outlines (plan 13–16)

    func testOutlinesUseTheTrueOrHomeFrameAndNeverInventOne() {
        let canvas = Dictionary(uniqueKeysWithValues: project().canvas.map { ($0.wid, $0) })
        XCTAssertEqual(canvas[1]?.position, .live)
        XCTAssertEqual(canvas[2]?.position, .lastKnown)
        XCTAssertEqual(canvas[2]?.frame, CGRect(x: 200, y: 100, width: 1200, height: 800))
        XCTAssertEqual(canvas[4]?.position, .lastKnown)
        XCTAssertEqual(canvas[4]?.frame, CGRect(x: 1400, y: 100, width: 1000, height: 700))
        XCTAssertEqual(canvas[5]?.position, .savedHome)
        XCTAssertEqual(canvas[5]?.frame, home)
        XCTAssertNil(canvas[6])
        XCTAssertNil(canvas[7])
        XCTAssertNil(canvas[8])
        XCTAssertEqual(project().all[8]?.position, .none("No known position"))
        XCTAssertNil(project().all[8]?.frame)
    }

    // MARK: Bulk (plan 17–22)

    func testTileActsOnlyOnShowingWindowsPerMonitor() {
        let plan = project().bulk(.tile, selection: [1, 2, 3])
        XCTAssertEqual(plan.eligibleCount, 2)
        XCTAssertEqual(plan.groups.map(\.displayId), [1, 2])
        XCTAssertEqual(plan.label, "Tile 2 here · 1 on Desktop 3 excluded")
    }

    func testNothingEligibleDisablesTheActionAndSaysWhy() {
        let plan = project().bulk(.distribute, selection: [2, 4, 6, 7])
        XCTAssertFalse(plan.isEnabled)
        XCTAssertEqual(plan.excludedSummary, "1 app hidden, 1 on Desktop 3, 1 full screen, 1 minimized or closed")
    }

    func testAParkedWindowIsNeverMoved() {
        let model = model()
        model.setSelection([1, 3, 5])
        let plan = model.plan(.tile)
        XCTAssertEqual(plan.label, "Tile 2 here · 1 parked excluded")
        XCTAssertEqual(model.run(plan), 2)
        XCTAssertFalse(spy.distributed.flatMap(\.wids).contains(5))
        XCTAssertEqual(model.selection, [1, 3, 5], "excluded windows stay selected")
    }

    func testTileAndDistributeLayOutDifferently() {
        let model = model()
        model.setSelection([1, 3])
        model.run(model.plan(.tile))
        model.run(model.plan(.distribute))
        XCTAssertEqual(spy.distributed.map(\.shape), [nil, nil, [1], [1]])
        XCTAssertEqual(OverviewModel.shape(.distribute, count: 3), [3])
        XCTAssertEqual(OverviewModel.shape(.arrange([2, 1]), count: 3), [2, 1])
        XCTAssertNil(OverviewModel.shape(.arrange([2, 2]), count: 3))
        XCTAssertNil(OverviewModel.shape(.tile, count: 3))
    }

    // MARK: Direct actions

    func testPlaceOnlyAShowingWindowOnItsOwnMonitor() {
        let model = model()
        XCTAssertTrue(model.place(3, at: .left))
        XCTAssertEqual(spy.calls, ["place 3 left on 2"])
        for wid: UInt32 in [2, 4, 5, 6, 7, 99] { XCTAssertFalse(model.place(wid, at: .left), "window \(wid)") }
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(model.projection.placeExclusion(5), .parked)
        XCTAssertEqual(model.projection.placeExclusion(99), .gone)
    }

    func testMoveDestinationsDistinguishEveryDisplayAndDesktop() throws {
        let projection = project()
        XCTAssertEqual(projection.moveTargets(for: 1).map(\.spaceId), [2, 3, 10, 11])
        XCTAssertEqual(projection.moveTargets(for: 2).map(\.spaceId), [1, 2, 10, 11])
        XCTAssertEqual(projection.moveTargets(for: 3).map(\.spaceId), [1, 2, 3, 10])
        let desktop2 = projection.moveTargets(for: 2).filter { $0.desktop == 2 }
        XCTAssertEqual(desktop2.map(\.title), ["Studio · Desktop 2", "Side · Desktop 2"])
        XCTAssertEqual(desktop2.map(\.spaceId), [2, 11])
        for wid: UInt32 in [4, 5, 6, 7] { XCTAssertEqual(projection.moveTargets(for: wid).count, 0, "window \(wid)") }
        XCTAssertEqual(OverviewProjection.moveExclusion(projection.all[7]!), .fullScreen)
        XCTAssertEqual(OverviewProjection.moveExclusion(projection.all[5]!), .parked)

        let model = model()
        XCTAssertFalse(model.move(1, toSpace: 1), "its own desktop")
        XCTAssertFalse(model.move(1, toSpace: 12), "full-screen Space is not a move destination")
        XCTAssertTrue(model.move(1, toSpace: 11), "another monitor's explicit Desktop")
        XCTAssertEqual(model.moving, [1])
        XCTAssertFalse(model.move(1, toSpace: 2), "one move at a time")
        XCTAssertFalse(model.move(2, toSpace: 2), "Mission Control moves serialize across windows")
        spy.finishMove?("Mission Control didn't open")
        XCTAssertEqual(model.moving, [])
        XCTAssertEqual(model.actionError, "Couldn't move Ghostty: Mission Control didn't open")
        XCTAssertEqual(spy.calls, ["move 1 to 11"])
    }

    func testBringHereUsesHostShowingSpaceRegardlessOfBrowsedOrSourceDesktop() throws {
        let model = model()
        model.hostDisplayId = 1
        model.chooseDesktop(10)
        XCTAssertEqual(model.bringHereTarget(for: 3)?.title, "Studio · Desktop 1")
        XCTAssertEqual(model.bringHereTarget(for: 3)?.spaceId, 1)
        XCTAssertNil(model.bringHereTarget(for: 1), "already here")
        model.hostDisplayId = 2
        XCTAssertEqual(model.bringHereTarget(for: 2)?.spaceId, 11)
        XCTAssertEqual(model.bringHereTarget(for: 2)?.displayIndex, 1)
        model.hostDisplayId = nil
        XCTAssertNil(model.bringHereTarget(for: 2), "unresolved host must not guess from selected window")
        XCTAssertEqual(spy.calls, [], "computing a destination never moves or focuses a window")
    }

    func testInactiveVirtualWindowCanChoosePhysicalDesktopWithSameNumber() throws {
        let virtual = OverviewDisplay(index: 2, name: "Action Agent Layer",
            bounds: CGRect(x: 3440, y: 0, width: 1440, height: 900),
            desktops: [1955, 1956, 2376, 2377], currentSpaceId: 1955, displayId: 20)
        let physical = OverviewDisplay(index: 0, name: "DELL", bounds: main,
            desktops: [1, 3], currentSpaceId: 3, displayId: 10)
        let row = window(100, "Ghostty", "disposable", spaces: [2377], frame: virtual.bounds)
        let projection = OverviewProjection.make(
            .init(windows: [row], displays: [physical, virtual], main: main),
            scope: .all, selection: [100]
        )
        let targets = projection.moveTargets(for: 100).filter { $0.desktop == 2 }
        XCTAssertEqual(targets.map(\.title), ["DELL · Desktop 2", "Action Agent Layer · Desktop 2"])
        XCTAssertEqual(targets.map(\.spaceId), [3, 1956])
        XCTAssertEqual(projection.bringHereTarget(for: 100, hostDisplayId: 10)?.spaceId, 3)
    }

    // MARK: Edit layer (plan 23)

    private func tideline(_ model: OverviewModel) -> LayerOverview { model.layers[0] }

    func testSaveWritesConfigurationOnlyAndRearrangeIsForTheActiveLayer() {
        let model = model()
        model.beginEditing(tideline(model))
        model.editing?.layout = "columns"
        model.editing?.tucked = []
        XCTAssertEqual(model.editing?.savePlan(), LayerEditPlan(layerId: "tideline", layout: .some("columns"), tuck: [], untuck: [5], rearrange: false))
        XCTAssertTrue(model.canRearrange)
        XCTAssertTrue(model.saveLayer())
        XCTAssertNil(model.editing)
        XCTAssertEqual(spy.calls, ["save tideline layout tuck0 untuck1"])

        model.beginEditing(model.layers[1])
        XCTAssertFalse(model.canRearrange, "Mail isn't active")
        XCTAssertNil(model.editing?.saveAndRearrangePlan(isActive: false))
        XCTAssertFalse(model.saveAndRearrange())
        XCTAssertEqual(spy.calls.count, 1)
    }

    func testRearrangeFollowsTheLiveActiveLayer() {
        let model = model()
        model.beginEditing(tideline(model))
        model.editing?.layout = "columns"
        model.update(inputs(tidelineActive: false))
        XCTAssertFalse(model.canRearrange)
        XCTAssertFalse(model.saveAndRearrange())
        XCTAssertEqual(spy.calls, [])

        model.update(inputs())
        XCTAssertTrue(model.saveAndRearrange())
        XCTAssertEqual(spy.calls, ["save tideline layout tuck0 untuck0", "rearrange tideline"])
    }

    func testAFailedSaveKeepsTheDraftAndNeverRearranges() {
        let model = model()
        spy.saveError = OverviewEditError.layerGone("tideline")
        model.beginEditing(tideline(model))
        model.editing?.layout = "columns"
        XCTAssertFalse(model.saveAndRearrange())
        XCTAssertEqual(model.editing?.layout, "columns")
        XCTAssertEqual(model.editError, "Layer tideline is gone; nothing was saved")
        XCTAssertFalse(spy.calls.contains("rearrange tideline"))
    }

    /// A tuck-only Save whose stage write fails is a failed Save too.
    func testAFailedTuckOnlySaveKeepsTheDraft() {
        let model = model()
        spy.saveError = CocoaError(.fileWriteNoPermission)
        model.beginEditing(tideline(model))
        model.editing?.tucked = [5, 8]
        XCTAssertFalse(model.saveLayer())
        XCTAssertEqual(model.editing?.tucked, [5, 8])
        XCTAssertNotNil(model.editError)
        XCTAssertFalse(model.saveAndRearrange())
        XCTAssertEqual(model.editing?.tucked, [5, 8])
        XCTAssertEqual(spy.calls.filter { $0.hasPrefix("rearrange") }, [])

        spy.saveError = nil
        XCTAssertTrue(model.saveLayer())
        XCTAssertNil(model.editError)
        XCTAssertNil(model.editing)
    }

    func testAFailedRearrangeShowsAfterTheDraftCloses() {
        let model = model()
        spy.rearrangeError = OverviewEditError.notActive("tideline")
        model.beginEditing(tideline(model))
        XCTAssertFalse(model.saveAndRearrange())
        XCTAssertNil(model.editing)
        XCTAssertEqual(model.editError, "Layer tideline is no longer active; saved without rearranging")

        model.beginEditing(tideline(model))
        XCTAssertNil(model.editError, "a new edit starts clean")
        spy.saveError = OverviewEditError.layerGone("tideline")
        XCTAssertFalse(model.saveLayer())
        XCTAssertNotNil(model.editError)
        model.cancelEditing()
        XCTAssertNil(model.editError)
    }

    func testAPlanNamesItsLayerByIdOnly() {
        let model = model()
        model.beginEditing(model.layers[1])
        // The layers reorder under the open edit.
        var reordered = inputs()
        reordered.layers = Array(reordered.layers.reversed())
        model.update(reordered)
        XCTAssertEqual(model.editing?.savePlan().layerId, "mail")
    }

    // MARK: Desk

    func testTheDeskListsEveryMonitorAndDesktopEmptyOnesToo() {
        let desk = project().desk
        XCTAssertEqual(desk.map(\.display.name), ["Studio", "Side"], "left to right")
        XCTAssertEqual(desk[0].spaces.map(\.spaceId), [1, 2, 3])
        XCTAssertEqual(desk[1].spaces.map(\.spaceId), [10, 11, 12], "the full-screen Space holds a window")
        XCTAssertEqual(desk[1].spaces[0].rows, [], "an empty Desktop still shows")
        XCTAssertEqual(desk[1].spaces[2].title, "Full screen")
        XCTAssertTrue(desk[0].spaces[2].rows.contains { $0.wid == 2 })
        XCTAssertTrue(desk[1].spaces[1].isCurrent)
    }

    func testTheDeskRowsAreTheKeyOrderAndUnplacedComeLast() {
        let projection = project()
        XCTAssertTrue(projection.unplaced.contains { $0.wid == 6 })
        XCTAssertEqual(projection.rows.suffix(projection.unplaced.count).map(\.wid), projection.unplaced.map(\.wid))
        XCTAssertEqual(Set(projection.rows.map(\.wid)), Set(projection.desk.flatMap { $0.spaces.flatMap(\.rows) }.map(\.wid) + projection.unplaced.map(\.wid)))
    }

    func testScopeMarksTheDeskWithoutHidingAnyOfIt() {
        let desk = project(OverviewScope(display: 1, spaceId: 11)).desk
        XCTAssertEqual(desk.count, 2)
        XCTAssertFalse(desk[0].inScope)
        XCTAssertEqual(desk[0].spaces.map(\.inScope), [false, false, false])
        XCTAssertEqual(desk[1].spaces.map(\.inScope), [false, true, false])
    }

    func testOnlyTheShowingSpaceDrawsLive() {
        let desk = project().desk
        let showing = desk[0].spaces[0]
        XCTAssertNil(showing.mapNote)
        XCTAssertTrue(showing.drawsLive(project().all[1]!))

        let desktop3 = desk[0].spaces[2]
        let zed = desktop3.rows.first { $0.wid == 2 }!
        XCTAssertFalse(desktop3.drawsLive(zed))
        XCTAssertNotNil(desktop3.mapNote, "a Desktop that isn't showing says its frames aren't live")

        let fullScreen = desk[1].spaces[2]
        XCTAssertFalse(fullScreen.isCurrent)
        XCTAssertFalse(fullScreen.drawsLive(fullScreen.rows[0]), "a full-screen Space not showing isn't drawn live")
        XCTAssertEqual(fullScreen.mapNote, "not showing")
    }

    // MARK: Membership sidebar

    func testMembershipHoldsMembersTuckedAndUnclaimedApart() throws {
        let m = try XCTUnwrap(OverviewMembership.make(layerId: "tideline", inputs: inputs(), projection: project()))
        XCTAssertEqual(m.members.map(\.wid), [1, 2, 3, 6])
        XCTAssertEqual(m.members.map(\.entry), ["Ghostty", "Zed", "Zed", "Zed"])
        XCTAssertEqual(m.members.last?.location, "Minimized or closed")
        XCTAssertEqual(m.tucked.map(\.wid), [5])
        XCTAssertEqual(m.unclaimed.map(\.wid), [8], "4 is Mail's now, so it isn't unclaimed")
        XCTAssertNil(m.unclaimed[0].entry)
        XCTAssertEqual(m.missing, [])
        XCTAssertEqual(m.total, 5, "unclaimed windows aren't configured membership")
    }

    func testAConfiguredEntryWithNoWindowSitsApartFromAnUnclaimedWindow() throws {
        var layers = layers()
        layers[0] = LayerOverview(index: 0, id: "tideline", label: "Tideline", layout: "auto", isActive: true,
                                  entries: layers[0].entries + [
                                      .init(index: 2, name: "Chrome", pattern: "chrome", windows: [], missing: nil),
                                  ])
        var input = inputs()
        input.layers = layers
        let projection = OverviewProjection.make(input, scope: .all, selection: [])
        let m = try XCTUnwrap(OverviewMembership.make(layerId: "tideline", inputs: input, projection: projection))
        XCTAssertEqual(m.missing.map(\.name), ["Chrome"])
        XCTAssertEqual(m.missing.first?.note, "No window")
        XCTAssertEqual(m.missing.first?.pattern, "chrome")
        XCTAssertEqual(m.unclaimed.map(\.wid), [8])
        XCTAssertFalse(m.members.contains { $0.wid == 8 })
    }

    func testBrowsingNeverShrinksTheMembership() throws {
        let model = model()
        let whole = try XCTUnwrap(model.membership)
        model.scope.display = 1
        model.scope.spaceId = 10
        model.scope.search = "nothing matches"
        model.scope.preset = "Browsers"
        XCTAssertEqual(model.membership, whole)
        XCTAssertEqual(model.membershipLayer, "tideline")
        XCTAssertEqual(spy.calls, [])
    }

    func testFirstOpenShowsTheScopedLayerBeforeTheActiveOne() {
        // Scoped to Mail while Tideline is active, no sidebar choice yet.
        OverviewScope(layerId: "mail").save(to: defaults)
        XCTAssertNil(defaults.string(forKey: OverviewModel.membershipLayerKey))
        let first = model()
        XCTAssertEqual(first.membershipLayer, "mail")
        XCTAssertEqual(first.membership?.layerId, "mail")

        first.chooseMembershipLayer("tideline")
        XCTAssertEqual(model().membershipLayer, "tideline", "a remembered choice outlasts the scoped layer")
    }

    func testWithNoScopedLayerTheActiveOneShows() {
        XCTAssertEqual(model().membershipLayer, "tideline")
        XCTAssertEqual(model(inputs(tidelineActive: false)).membershipLayer, "mail")
    }

    func testTheSidebarLayerSurvivesMonitorScopeAndHiding() throws {
        let model = model()
        model.chooseMembershipLayer("mail")
        model.membershipShown = true
        let shown = try XCTUnwrap(model.membership)
        model.stepMonitor(1)
        model.scope.spaceId = 3
        model.toggleMembership()
        XCTAssertFalse(model.membershipShown)
        model.toggleMembership()
        XCTAssertEqual(model.membershipLayer, "mail")
        XCTAssertEqual(model.membership, shown)
    }

    func testBrowsingALayerPointsTheSidebarAtIt() {
        let model = model()
        model.chooseMembershipLayer("tideline")
        model.scope.layerId = "mail"
        XCTAssertEqual(model.membershipLayer, "mail")
        model.scope.layerId = nil
        XCTAssertEqual(model.membershipLayer, "mail", "clearing the layer scope keeps the sidebar where it is")
    }

    func testRevealSelectsWithoutMovingTheScopeOrAWindow() {
        let model = model()
        model.scope.display = 0
        model.reveal(3)
        XCTAssertEqual(model.selection, [3])
        XCTAssertEqual(model.scope.display, 0)
        XCTAssertEqual(model.revealRequest, .init(wid: 3, serial: 1))
        XCTAssertTrue(model.isListed(3), "dimmed, not hidden: another monitor's rows stay on the desk")
        XCTAssertEqual(spy.calls, [])
    }

    // MARK: Layer, then Desktop

    func testADesktopNarrowsTheLayerAndAllDesktopsRestoresIt() throws {
        let model = model()
        model.chooseLayer("tideline")
        let whole = try XCTUnwrap(model.workingMembership)
        XCTAssertEqual(whole.count, 6)

        model.chooseDesktop(1)
        XCTAssertEqual(model.scope.display, 0, "the Desktop brings its monitor")
        let here = try XCTUnwrap(model.workingMembership)
        XCTAssertEqual(here.members.map(\.wid), [1])
        XCTAssertEqual(here.tucked.map(\.wid), [5])
        XCTAssertEqual(here.unclaimed, [], "8 is on Desktop 2")
        XCTAssertEqual(model.layerMembership, whole, "the layer itself stays whole")

        model.chooseDesktop(1)
        XCTAssertNil(model.scope.spaceId, "the same Desktop again gives the whole list back")
        model.chooseDesktop(2)
        XCTAssertEqual(model.workingMembership?.unclaimed.map(\.wid), [8])
        model.chooseDesktop(nil)
        XCTAssertNil(model.scope.display)
        XCTAssertEqual(model.workingMembership, whole, "All desktops brings back the unknown and tucked ones")
        XCTAssertEqual(spy.calls, [])
    }

    func testSwitchingLayersDropsTheDesktop() {
        let model = model()
        model.chooseLayer("tideline")
        model.chooseDesktop(3)
        model.chooseLayer("mail")
        XCTAssertNil(model.scope.spaceId)
        XCTAssertNil(model.scope.display)
        XCTAssertEqual(model.workingMembership?.members.map(\.wid), [4])
        model.chooseLayer(nil)
        XCTAssertNil(model.workingMembership)
    }

    func testSearchAndKindNeverNarrowTheLayersList() throws {
        let model = model()
        model.chooseLayer("tideline")
        let whole = try XCTUnwrap(model.workingMembership)
        model.scope.search = "nothing matches"
        model.scope.preset = "Browsers"
        XCTAssertEqual(model.workingMembership, whole)
        XCTAssertEqual(model.scope.layerId, "tideline")
    }

    func testDesktopStepsWalkTheStripAndWrapThroughAllDesktops() {
        let model = model()
        XCTAssertEqual(model.desktopOrder, [1, 2, 3, 10, 11, 12])
        model.stepDesktop(1)
        XCTAssertEqual(model.scope.spaceId, 1)
        model.stepDesktop(-1)
        XCTAssertNil(model.scope.spaceId)
        model.stepDesktop(-1)
        XCTAssertEqual(model.scope.spaceId, 12)
        XCTAssertEqual(model.scope.display, 1)
        model.chooseDesktop(11)
        XCTAssertEqual(model.workingRows.map(\.wid), [3], "every window's list narrows the same way")
        XCTAssertEqual(spy.calls, [])
    }
}

// MARK: - Tuck persistence

final class LayerStageTuckTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func read(_ path: String) throws -> LayerStage.State {
        try JSONDecoder().decode(LayerStage.State.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testTucksAreWrittenInOneBatch() throws {
        var start = LayerStage.State()
        start.tucked["tideline"] = [5]
        let path = folder.appendingPathComponent("nested/layer-stage.json").path
        let next = try LayerStage.committingTucks(tuck: [8, 7], untuck: [5], layer: "tideline", to: start, path: path)
        XCTAssertEqual(next.tucked["tideline"], [7, 8])
        XCTAssertEqual(next.untucked["tideline"], [5])
        XCTAssertEqual(try read(path), next)
    }

    /// A write that can't land throws, and the ledger on disk is as it was.
    func testAFailedWriteThrowsAndChangesNothing() throws {
        let path = folder.appendingPathComponent("layer-stage.json").path
        var start = LayerStage.State()
        start.tucked["tideline"] = [5]
        try LayerStage.write(start, to: path)

        // A file where the folder should be: making the folder fails.
        let blocker = folder.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let blocked = blocker.appendingPathComponent("layer-stage.json").path
        XCTAssertThrowsError(try LayerStage.committingTucks(tuck: [8], untuck: [5], layer: "tideline", to: start, path: blocked))

        // A read-only folder: the atomic write fails.
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try LayerStage.committingTucks(
            tuck: [8], untuck: [], layer: "tideline", to: start, path: locked.appendingPathComponent("layer-stage.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locked.appendingPathComponent("layer-stage.json").path))
        XCTAssertEqual(try read(path), start)
    }

    func testNoChangeWritesNothing() throws {
        var start = LayerStage.State()
        start.tucked["tideline"] = [5]
        let path = folder.appendingPathComponent("blocker").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let next = try LayerStage.committingTucks(tuck: [5], untuck: [9], layer: "tideline", to: start, path: path + "/layer-stage.json")
        XCTAssertEqual(next, start)
    }
}

// MARK: - Spy

private final class SpyActions: OverviewActions {
    var calls: [String] = []
    var distributed: [(wids: [UInt32], displayId: UInt32, shape: [Int]?)] = []
    var finishMove: ((String?) -> Void)?
    var saveError: Error?
    var rearrangeError: Error?

    func distribute(_ windows: [(wid: UInt32, pid: Int32)], displayId: UInt32, shape: [Int]?) {
        distributed.append((windows.map(\.wid), displayId, shape))
        calls.append("distribute \(windows.map(\.wid)) on \(displayId)")
    }

    func focus(wid: UInt32, pid: Int32) { calls.append("focus \(wid)") }

    func place(wid: UInt32, pid: Int32, position: TilePosition, displayId: UInt32) {
        calls.append("place \(wid) \(position.rawValue) on \(displayId)")
    }

    func moveToSpace(wid: UInt32, pid: Int32, spaceId: Int, completion: @escaping (String?) -> Void) {
        calls.append("move \(wid) to \(spaceId)")
        finishMove = completion
    }

    func saveLayer(_ plan: LayerEditPlan) throws {
        if let saveError { throw saveError }
        calls.append("save \(plan.layerId) \(plan.layout == nil ? "-" : "layout") tuck\(plan.tuck.count) untuck\(plan.untuck.count)")
    }

    func rearrange(layerId: String) throws {
        calls.append("rearrange \(layerId)")
        if let rearrangeError { throw rearrangeError }
    }
}
