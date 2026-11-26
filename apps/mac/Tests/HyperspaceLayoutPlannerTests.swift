import XCTest
@testable import Lattices

final class HyperspaceLayoutPlannerTests: XCTestCase {
    private let area = CGRect(x: 100, y: 30, width: 1600, height: 1000)

    func testThreeColumnsKeepExplicitOrderAndEqualWidths() throws {
        let plan = try XCTUnwrap(HyperspaceLayoutPlanner.columns([9, 3, 7], in: area))
        XCTAssertEqual(Set(plan.frames.keys), [9, 3, 7])
        let first = try XCTUnwrap(plan.frames[9])
        let second = try XCTUnwrap(plan.frames[3])
        let third = try XCTUnwrap(plan.frames[7])
        XCTAssertEqual(first.width, second.width, accuracy: 1)
        XCTAssertEqual(second.width, third.width, accuracy: 1)
        XCTAssertEqual(first.minX, area.minX)
        XCTAssertEqual(third.maxX, area.maxX, accuracy: 1)
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertLessThan(second.maxX, third.minX)
    }

    func testRejectsEmptyDuplicateAndTooNarrowColumns() {
        XCTAssertNil(HyperspaceLayoutPlanner.columns([], in: area))
        XCTAssertNil(HyperspaceLayoutPlanner.columns([1, 1], in: area))
        XCTAssertNil(HyperspaceLayoutPlanner.columns([1, 2, 3], in: CGRect(x: 0, y: 0, width: 700, height: 500)))
    }

    func testFreeDragMovesOnlySourceAndStaysWithinDisplay() {
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 1400, y: 700, width: 500, height: 400),
            start: CGPoint(x: 900, y: 500), at: CGPoint(x: 1000, y: 530), in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Move window")
        XCTAssertEqual(Set(plan.frames.keys), [1])
        XCTAssertEqual(plan.frames[1]?.maxX, area.maxX)
        XCTAssertEqual(plan.frames[1]?.maxY, area.maxY)
    }

    func testQuartileCenterLandsAsThatQuarter() throws {
        let point = CGPoint(x: area.minX + area.width * 0.75, y: area.minY + area.height * 0.75)
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 200, y: 100, width: 500, height: 400),
            start: CGPoint(x: 300, y: 200), at: point, in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Bottom right quarter")
        let frame = try XCTUnwrap(plan.frames[1])
        XCTAssertEqual(frame.width, (area.width - HyperspaceLayoutPlanner.gap) / 2, accuracy: 1)
        XCTAssertEqual(frame.height, (area.height - HyperspaceLayoutPlanner.gap) / 2, accuracy: 1)
        XCTAssertGreaterThan(frame.minX, area.midX)
        XCTAssertGreaterThan(frame.minY, area.midY)
    }

    func testTwoWindowsShareTheBottomRightQuarter() throws {
        let originals = [
            UInt32(1): CGRect(x: 200, y: 80, width: 500, height: 400),
            UInt32(2): CGRect(x: 760, y: 220, width: 420, height: 360),
        ]
        let point = CGPoint(x: area.minX + area.width * 0.75, y: area.minY + area.height * 0.75)
        let plan = HyperspaceLayoutPlanner.dropGroup([1, 2], originals: originals, anchor: 1,
            start: CGPoint(x: 300, y: 200), at: point, in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Bottom right quarter")
        let left = try XCTUnwrap(plan.frames[1])
        let right = try XCTUnwrap(plan.frames[2])
        XCTAssertEqual(left.width, right.width, accuracy: 1)
        XCTAssertEqual(left.height, right.height, accuracy: 1)
        XCTAssertEqual(left.minY, right.minY, accuracy: 1)
        XCTAssertEqual(right.minX - left.maxX, HyperspaceLayoutPlanner.gap, accuracy: 1)
        XCTAssertGreaterThan(left.minX, area.midX)
        XCTAssertGreaterThan(left.minY, area.midY)
        XCTAssertEqual(right.maxX, area.maxX, accuracy: 1)
    }

    func testApproachDrawsTheQuarterBeforeThePointerEntersIt() throws {
        let point = CGPoint(x: area.minX + area.width * 0.60, y: area.minY + area.height * 0.60)
        let source = CGRect(x: 200, y: 100, width: 500, height: 400)
        let drag = HyperspaceLayoutPlanner.drop(1, original: source, start: source.origin, at: point, in: area, neighbors: [])
        XCTAssertEqual(drag.title, "Move window")
        let guide = try XCTUnwrap(HyperspaceLayoutPlanner.approach(1, at: point, in: area))
        XCTAssertEqual(guide.title, "Bottom right quarter")
        let pair = try XCTUnwrap(HyperspaceLayoutPlanner.approachGroup([1, 2], anchor: 1, at: point, in: area))
        XCTAssertEqual(pair.title, "Bottom right quarter")
        XCTAssertEqual(Set(pair.frames.keys), [1, 2])
        let pairLeft = try XCTUnwrap(pair.frames[1])
        let pairRight = try XCTUnwrap(pair.frames[2])
        XCTAssertEqual(pairRight.minX - pairLeft.maxX, HyperspaceLayoutPlanner.gap, accuracy: 1)
        let heart = CGPoint(x: area.minX + area.width * 0.75, y: area.minY + area.height * 0.75)
        XCTAssertNil(HyperspaceLayoutPlanner.approach(1, at: heart, in: area))
        XCTAssertNil(HyperspaceLayoutPlanner.approach(1, at: CGPoint(x: area.midX, y: area.midY), in: area))
    }

    func testOpenHalfOfASplitQuarterBeatsTheWholeQuarter() throws {
        let occupied = CGRect(x: area.midX, y: area.midY, width: area.width / 4, height: area.height / 2)
        let point = CGPoint(x: area.minX + area.width * 0.875, y: area.minY + area.height * 0.75)
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 200, y: 100, width: 400, height: 300),
            start: CGPoint(x: 300, y: 200), at: point, in: area, neighbors: [(9, occupied)])
        XCTAssertEqual(plan.title, "Bottom right quarter, right half")
        let frame = try XCTUnwrap(plan.frames[1])
        XCTAssertFalse(frame.intersects(occupied))
        XCTAssertGreaterThanOrEqual(frame.minX, occupied.maxX)
        XCTAssertEqual(frame.maxX, area.maxX, accuracy: 1)
        XCTAssertGreaterThan(frame.minY, area.midY)
        XCTAssertEqual(frame.maxY, area.maxY, accuracy: 1)
    }

    func testAGroupDropKeepsOutsidersInPlaceAndTakesTheOpenHalf() throws {
        let chrome = CGRect(x: area.midX, y: area.midY, width: area.width / 4, height: area.height / 2)
        let rex = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2)
        let originals = [
            UInt32(1): CGRect(x: 200, y: 80, width: 420, height: 300),
            UInt32(2): CGRect(x: 280, y: 160, width: 420, height: 300),
        ]
        let point = CGPoint(x: area.minX + area.width * 0.875, y: area.minY + area.height * 0.75)
        let plan = HyperspaceLayoutPlanner.dropGroup([1, 2], originals: originals, anchor: 1,
            start: CGPoint(x: 300, y: 200), at: point, in: area, neighbors: [(8, rex), (9, chrome)])
        XCTAssertEqual(plan.title, "Bottom right quarter, right half")
        XCTAssertEqual(Set(plan.frames.keys), [1, 2])
        for frame in plan.frames.values {
            XCTAssertFalse(frame.intersects(chrome))
            XCTAssertFalse(frame.intersects(rex))
        }
    }

    func testAGroupDropDoesNotAdoptTheWindowUnderThePointer() throws {
        let neighbor = CGRect(x: 800, y: 100, width: 800, height: 800)
        let originals = [
            UInt32(1): CGRect(x: 100, y: 100, width: 500, height: 400),
            UInt32(2): CGRect(x: 180, y: 180, width: 480, height: 360),
        ]
        let plan = HyperspaceLayoutPlanner.dropGroup([1, 2], originals: originals, anchor: 1,
            start: CGPoint(x: 300, y: 200), at: CGPoint(x: 830, y: 450), in: area,
            neighbors: [(9, neighbor)])
        XCTAssertEqual(Set(plan.frames.keys), [1, 2])
        XCTAssertNotEqual(plan.title, "Share space")
    }

    func testOpenTopHalfOfASplitQuarter() throws {
        let occupied = CGRect(x: area.midX, y: area.midY + area.height / 4,
                              width: area.width / 2, height: area.height / 4)
        let point = CGPoint(x: area.minX + area.width * 0.62, y: area.minY + area.height * 0.62)
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 200, y: 100, width: 400, height: 300),
            start: CGPoint(x: 300, y: 200), at: point, in: area, neighbors: [(9, occupied)])
        XCTAssertEqual(plan.title, "Bottom right quarter, top half")
        let frame = try XCTUnwrap(plan.frames[1])
        XCTAssertFalse(frame.intersects(occupied))
        XCTAssertLessThan(frame.maxY, occupied.minY)
    }

    func testSmartDropPreviewsBothWindowsAndLeavesOthersAlone() throws {
        let neighbor = CGRect(x: 800, y: 100, width: 800, height: 800)
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 100, y: 100, width: 500, height: 500),
            start: CGPoint(x: 300, y: 200), at: CGPoint(x: 830, y: 450), in: area,
            neighbors: [(2, neighbor), (3, CGRect(x: 100, y: 100, width: 300, height: 300))])
        XCTAssertEqual(Set(plan.frames.keys), [1, 2])
        let source = try XCTUnwrap(plan.frames[1])
        let destination = try XCTUnwrap(plan.frames[2])
        XCTAssertEqual(source.minX, neighbor.minX)
        XCTAssertEqual(destination.maxX, neighbor.maxX)
        XCTAssertEqual(destination.minX - source.maxX, HyperspaceLayoutPlanner.gap)
        XCTAssertEqual(source.height, neighbor.height)
    }

    func testNoSplitWhenNeighborCannotFitTwoWindows() {
        let neighbor = CGRect(x: 800, y: 100, width: 400, height: 400)
        let plan = HyperspaceLayoutPlanner.drop(1, original: CGRect(x: 100, y: 100, width: 300, height: 300),
            start: CGPoint(x: 200, y: 200), at: CGPoint(x: 810, y: 250), in: area, neighbors: [(2, neighbor)])
        XCTAssertEqual(Set(plan.frames.keys), [1])
    }

    func testDividerKeepsOuterEdgesAndClampsMinimumSize() throws {
        let columns = try XCTUnwrap(HyperspaceLayoutPlanner.columns([1, 2], in: area))
        let divider = try XCTUnwrap(HyperspaceLayoutPlanner.dividers(columns.frames.map { ($0.key, $0.value) }).first)
        let plan = divider.plan(at: CGPoint(x: area.minX, y: area.midY))
        let a = try XCTUnwrap(plan.frames[1]), b = try XCTUnwrap(plan.frames[2])
        XCTAssertEqual(a.minX, area.minX)
        XCTAssertEqual(b.maxX, area.maxX)
        XCTAssertEqual(a.width, HyperspaceLayoutPlanner.minimumSize.width, accuracy: 1)
        XCTAssertEqual(b.minX - a.maxX, HyperspaceLayoutPlanner.gap, accuracy: 1)
    }

    func testContinuousDividerResizesBothRowsAndPreservesTheirGutters() throws {
        let tiles: [(UInt32, CGRect)] = [
            (1, CGRect(x: -1200, y: 30, width: 590, height: 390)),
            (2, CGRect(x: -602, y: 30, width: 450, height: 390)),
            (3, CGRect(x: -1200, y: 428, width: 590, height: 360)),
            (4, CGRect(x: -602, y: 428, width: 320, height: 360)),
        ]
        let seams = HyperspaceLayoutPlanner.dividers(tiles.reversed())
        let divider = try XCTUnwrap(seams.first { $0.vertical })
        XCTAssertEqual(seams.filter(\.vertical).count, 1)
        XCTAssertEqual(divider.hitFrame.minY, 30)
        XCTAssertEqual(divider.hitFrame.maxY, 788)
        let plan = divider.plan(at: CGPoint(x: 100, y: 40), from: CGPoint(x: -603, y: 40))
        XCTAssertEqual(Set(plan.frames.keys), [1, 2, 3, 4])
        for (id, original) in tiles {
            let frame = try XCTUnwrap(plan.frames[id])
            XCTAssertEqual(frame.minY, original.minY)
            XCTAssertEqual(frame.height, original.height)
            if id == 1 || id == 3 {
                XCTAssertEqual(frame.minX, original.minX)
                XCTAssertEqual(frame.maxX, original.maxX + 40)
            } else {
                XCTAssertEqual(frame.minX, original.minX + 40)
                XCTAssertEqual(frame.maxX, original.maxX)
            }
        }
    }

    func testHorizontalTJunctionAndDisconnectedParallelSeam() throws {
        let tiles: [(UInt32, CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 904, height: 500)),
            (2, CGRect(x: 0, y: 500, width: 450, height: 300)),
            (3, CGRect(x: 454, y: 500, width: 450, height: 300)),
            (4, CGRect(x: 980, y: 0, width: 450, height: 500)),
            (5, CGRect(x: 980, y: 500, width: 450, height: 300)),
        ]
        let seams = HyperspaceLayoutPlanner.dividers(tiles).filter { !$0.vertical }
        XCTAssertEqual(seams.count, 2)
        let seam = try XCTUnwrap(seams.first { $0.hitFrame.contains(CGPoint(x: 700, y: 500)) })
        let plan = seam.plan(at: CGPoint(x: 700, y: 460))
        XCTAssertEqual(Set(plan.frames.keys), [1, 2, 3])
        XCTAssertEqual(plan.frames[1]?.maxY, 460)
        XCTAssertEqual(plan.frames[2]?.minY, 460)
        XCTAssertEqual(plan.frames[3]?.height, 340)
    }

    func testDesktopDragExchangesDiagonalSlotsAndPreservesEdgeSplit() throws {
        let grid = try XCTUnwrap(HyperspaceLayoutPlanner.grid([1, 2, 3, 4], in: area))
        let source = try XCTUnwrap(grid.frames[2]), destination = try XCTUnwrap(grid.frames[3])
        let neighbors = grid.frames.filter { $0.key != 2 }.map { ($0.key, $0.value) }
        let start = CGPoint(x: source.midX, y: source.midY)
        let swap = HyperspaceLayoutPlanner.desktopDrop(2, original: source, start: start,
            at: CGPoint(x: destination.midX, y: destination.midY), in: area, neighbors: neighbors)
        XCTAssertEqual(swap.frames, [2: destination, 3: source])
        let split = HyperspaceLayoutPlanner.desktopDrop(2, original: source, start: start,
            at: CGPoint(x: destination.minX + 8, y: destination.midY), in: area, neighbors: neighbors)
        XCTAssertEqual(split.title, "Share space")
        // The remaining top tile takes the width that the dragged tile vacated.
        XCTAssertEqual(split.frames[1]?.width, area.width)
        XCTAssertEqual(split.frames[2]?.minX, destination.minX)
        XCTAssertEqual(split.frames[3]?.maxX, destination.maxX)
    }

    func testEdgeDropCompactsThreeColumnsAndLeavesFloatingWindowAlone() throws {
        let area = CGRect(x: -1200, y: 40, width: 1200, height: 800)
        let columns = try XCTUnwrap(HyperspaceLayoutPlanner.columns([1, 2, 3], in: area))
        let a = try XCTUnwrap(columns.frames[1])
        let b = try XCTUnwrap(columns.frames[2])
        let c = try XCTUnwrap(columns.frames[3])
        let floating = CGRect(x: -350, y: 260, width: 300, height: 205)
        let drag = HyperspaceLayoutPlanner.DesktopDrop(id: 1, original: a, start: a.origin, area: area,
            neighbors: [(4, floating), (2, b), (3, c)])
        let plan = drag.plan(at: CGPoint(x: b.midX, y: b.minY + 8))
        XCTAssertEqual(Set(plan.frames.keys), [1, 2, 3])
        let upper = try XCTUnwrap(plan.frames[1])
        let lower = try XCTUnwrap(plan.frames[2])
        let right = try XCTUnwrap(plan.frames[3])
        XCTAssertEqual(upper.minX, area.minX)
        XCTAssertEqual(upper.width, right.width, accuracy: 2)
        XCTAssertEqual(upper.maxX, lower.maxX)
        XCTAssertEqual(lower.maxY, area.maxY)
        XCTAssertEqual(lower.minY - upper.maxY, HyperspaceLayoutPlanner.gap)
        XCTAssertEqual(right.maxX, area.maxX)
        XCTAssertEqual(right.height, area.height)
        XCTAssertNil(plan.frames[4])
        XCTAssertEqual(drag.plan(at: CGPoint(x: b.midX, y: b.midY)).frames, [1: b, 2: a])
    }

    func testSecondDropUsesStagedSiblingsAboveTheLiveDesktop() throws {
        let area = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let columns = try XCTUnwrap(HyperspaceLayoutPlanner.columns([1, 2, 3], in: area))
        let a = try XCTUnwrap(columns.frames[1])
        let b = try XCTUnwrap(columns.frames[2])
        let c = try XCTUnwrap(columns.frames[3])
        let first = HyperspaceLayoutPlanner.desktopDrop(1, original: a, start: a.origin,
            at: CGPoint(x: b.midX, y: b.minY + 8), in: area, neighbors: [(2, b), (3, c)])
        let upper = try XCTUnwrap(first.frames[1])
        let lower = try XCTUnwrap(first.frames[2])
        let right = try XCTUnwrap(first.frames[3])
        let drag = HyperspaceLayoutPlanner.DesktopDrop(id: 1, original: upper, start: upper.origin,
            area: area, neighbors: [(90, right), (2, lower), (3, right)], prior: first)
        let second = drag.plan(at: CGPoint(x: right.midX, y: right.maxY - 8))
        XCTAssertEqual(Set(second.frames.keys), [1, 2, 3])
        XCTAssertEqual(second.frames[2]?.minY, area.minY)
        XCTAssertEqual(second.frames[2]?.height, area.height)
        XCTAssertEqual(second.frames[1]?.maxY, area.maxY)
        XCTAssertEqual(second.frames[3]?.minY, area.minY)
    }

    func testStagedPairDoesNotAbsorbAnAdjoiningUnstagedWindow() throws {
        let columns = try XCTUnwrap(HyperspaceLayoutPlanner.columns([1, 2, 3], in: area))
        let a = try XCTUnwrap(columns.frames[1])
        let b = try XCTUnwrap(columns.frames[2])
        let c = try XCTUnwrap(columns.frames[3])
        let prior = HyperspaceLayoutPlan(title: "Pair", frames: [1: a, 2: b])
        let drag = HyperspaceLayoutPlanner.DesktopDrop(id: 1, original: a, start: a.origin, area: area,
            neighbors: [(2, b), (3, c)], prior: prior)
        let plan = drag.plan(at: CGPoint(x: b.midX, y: b.maxY - 8))
        XCTAssertEqual(Set(plan.frames.keys), [1, 2])
        XCTAssertEqual(plan.frames[1]?.minX, a.minX)
        XCTAssertEqual(plan.frames[1]?.maxX, b.maxX)
    }

    func testDesktopDropOnNarrowTileSwapsOnlyTheFrontmostOccupant() {
        let source = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tile = CGRect(x: 404, y: 0, width: 400, height: 300)
        let start = CGPoint(x: 200, y: 150)
        let plan = HyperspaceLayoutPlanner.desktopDrop(1, original: source, start: start,
            at: CGPoint(x: 410, y: 150), in: source.union(tile), neighbors: [(3, tile), (2, tile)])
        XCTAssertEqual(plan.frames, [1: tile, 3: source])
    }

    func testDesktopDropPreservesFreeDragForOverlappingWindows() {
        let source = CGRect(x: 400, y: 200, width: 600, height: 400)
        let tile = source.offsetBy(dx: 150, dy: 0)
        let point = CGPoint(x: tile.midX, y: tile.midY)
        let plan = HyperspaceLayoutPlanner.desktopDrop(1, original: source, start: source.origin,
            at: point, in: area, neighbors: [(2, tile)])
        XCTAssertNil(plan.frames[2])
    }

    func testNonAdjacentWindowsDoNotGetAResizeDivider() {
        XCTAssertTrue(HyperspaceLayoutPlanner.dividers([
            (1, CGRect(x: 0, y: 0, width: 600, height: 600)),
            (2, CGRect(x: 800, y: 0, width: 600, height: 600)),
        ]).isEmpty)
    }

    func testAlternativesKeepEverySelectedWindowInBoundsWithoutOverlap() {
        for count in 1...8 {
            let ids = (1...count).map(UInt32.init)
            let plans = HyperspaceLayoutPlanner.options(ids, in: area)
            XCTAssertFalse(plans.isEmpty, "No feasible alternative for \(count) windows")
            XCTAssertLessThanOrEqual(plans.count, 4)
            for plan in plans {
                XCTAssertEqual(Set(plan.frames.keys), Set(ids))
                let frames = Array(plan.frames.values)
                for frame in frames {
                    XCTAssertGreaterThanOrEqual(frame.width, HyperspaceLayoutPlanner.minimumSize.width)
                    XCTAssertGreaterThanOrEqual(frame.height, HyperspaceLayoutPlanner.minimumSize.height)
                    XCTAssertTrue(area.insetBy(dx: -1, dy: -1).contains(frame))
                }
                for i in frames.indices {
                    for j in frames.indices where j > i {
                        XCTAssertFalse(frames[i].intersects(frames[j]), "Overlapping \(plan.title) windows")
                    }
                }
            }
        }
    }

    func testThreeWindowOptionsOfferBothMainPositionsAndPreserveFirstPick() throws {
        let plans = HyperspaceLayoutPlanner.options([9, 3, 7], in: area)
        XCTAssertEqual(plans.count, 4)
        let left = try XCTUnwrap(plans.first { $0.title == "Main left" })
        let right = try XCTUnwrap(plans.first { $0.title == "Main right" })
        XCTAssertEqual(left.frames[9]?.minX, area.minX)
        XCTAssertEqual(try XCTUnwrap(right.frames[9]?.maxX), area.maxX, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(left.frames[9]?.width), try XCTUnwrap(left.frames[3]?.width))
        XCTAssertLessThan(try XCTUnwrap(left.frames[3]?.minY), try XCTUnwrap(left.frames[7]?.minY))
    }

    func testAlternativesRejectInvalidSelectionsAndSuppressImpossibleGeometry() {
        XCTAssertTrue(HyperspaceLayoutPlanner.options([], in: area).isEmpty)
        XCTAssertTrue(HyperspaceLayoutPlanner.options([1, 1], in: area).isEmpty)
        XCTAssertTrue(HyperspaceLayoutPlanner.options([1, 2, 3], in: CGRect(x: 0, y: 0, width: 500, height: 300)).isEmpty)
        let plans = HyperspaceLayoutPlanner.options([1, 2, 3], in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(plans.contains { $0.title.contains("columns") })
        XCTAssertTrue(plans.contains { $0.title == "Main left" })
    }

    func testCornersAndVerticalEdgesOfferQuarterAndHalfLandings() throws {
        let source = CGRect(x: 200, y: 100, width: 500, height: 400)
        let points = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                      CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
        for point in points {
            let plan = HyperspaceLayoutPlanner.drop(1, original: source, start: source.origin, at: point, in: area, neighbors: [])
            let frame = try XCTUnwrap(plan.frames[1])
            XCTAssertTrue(plan.title.contains("quarter"))
            XCTAssertEqual(frame.width, (area.width - HyperspaceLayoutPlanner.gap) / 2, accuracy: 1)
            XCTAssertEqual(frame.height, (area.height - HyperspaceLayoutPlanner.gap) / 2, accuracy: 1)
            XCTAssertTrue(area.insetBy(dx: -1, dy: -1).contains(frame))
        }
        for point in [CGPoint(x: area.midX, y: area.minY), CGPoint(x: area.midX, y: area.maxY)] {
            let plan = HyperspaceLayoutPlanner.drop(1, original: source, start: source.origin, at: point, in: area, neighbors: [])
            XCTAssertEqual(plan.frames[1]?.width, area.width)
            XCTAssertTrue(plan.title.contains("half"))
        }
    }

    func testReflowKeepsTheLayoutAndFollowsTheNewOrder() throws {
        let columns = try XCTUnwrap(HyperspaceLayoutPlanner.columns([9, 3, 7], in: area))
        let swapped = try XCTUnwrap(HyperspaceLayoutPlanner.reflow(columns, ids: [7, 3, 9], in: area))
        XCTAssertTrue(swapped.title.contains("column"))
        XCTAssertLessThan(try XCTUnwrap(swapped.frames[7]?.maxX), try XCTUnwrap(swapped.frames[3]?.minX))
        XCTAssertLessThan(try XCTUnwrap(swapped.frames[3]?.maxX), try XCTUnwrap(swapped.frames[9]?.minX))

        let main = try XCTUnwrap(HyperspaceLayoutPlanner.mainAndCompanions([9, 3, 7], in: area, leading: true))
        let moved = try XCTUnwrap(HyperspaceLayoutPlanner.reflow(main, ids: [3, 9, 7], in: area))
        XCTAssertEqual(moved.title, "Main left")
        XCTAssertEqual(moved.frames[3]?.minX, area.minX)
        XCTAssertGreaterThan(try XCTUnwrap(moved.frames[3]?.width), try XCTUnwrap(moved.frames[9]?.width))

        let movedWindow = HyperspaceLayoutPlan(title: "Move window", frames: columns.frames)
        XCTAssertNil(HyperspaceLayoutPlanner.reflow(movedWindow, ids: [9, 3, 7], in: area))
    }

    func testOverviewSpotsUseQuartileCentersEdgesAndThirds() throws {
        let source = CGRect(x: 200, y: 100, width: 500, height: 400)
        func spot(_ fx: CGFloat, _ fy: CGFloat) -> HyperspaceLayoutPlan {
            let point = CGPoint(x: area.minX + fx * area.width, y: area.minY + fy * area.height)
            return HyperspaceLayoutPlanner.spot(1, original: source, start: source.origin, at: point, in: area, neighbors: [])
        }
        XCTAssertEqual(spot(0.25, 0.25).title, "Top left quarter")
        XCTAssertEqual(spot(0.75, 0.75).title, "Bottom right quarter")
        XCTAssertEqual(spot(0.02, 0.02).title, "Top left quarter")
        XCTAssertEqual(spot(0.05, 0.50).title, "Left half")
        XCTAssertEqual(spot(0.50, 0.05).title, "Top half")
        XCTAssertEqual(spot(0.26, 0.50).title, "Left third")
        XCTAssertEqual(spot(0.74, 0.50).title, "Right third")
        XCTAssertEqual(spot(0.50, 0.26).title, "Top third")
        XCTAssertEqual(spot(0.50, 0.50).title, "Move window")

        let third = try XCTUnwrap(spot(0.26, 0.50).frames[1])
        XCTAssertEqual(third.minX, area.minX)
        XCTAssertEqual(third.width, (area.width - HyperspaceLayoutPlanner.gap * 2) / 3, accuracy: 1)
        XCTAssertEqual(third.height, area.height, accuracy: 1)

        let neighbor = CGRect(x: 800, y: 100, width: 800, height: 800)
        let shared = HyperspaceLayoutPlanner.spot(1, original: source, start: source.origin,
            at: CGPoint(x: 830, y: 450), in: area, neighbors: [(2, neighbor)])
        XCTAssertEqual(shared.title, "Share space")
        XCTAssertEqual(Set(shared.frames.keys), [1, 2])
    }

    func testTwoSelectedWindowsSplitTheRightHalfEvenly() throws {
        let originals = [
            UInt32(1): CGRect(x: 200, y: 80, width: 500, height: 400),
            UInt32(2): CGRect(x: 760, y: 220, width: 420, height: 360),
        ]
        let plan = HyperspaceLayoutPlanner.dropGroup([1, 2], originals: originals, anchor: 1,
            start: CGPoint(x: 300, y: 200), at: CGPoint(x: area.maxX - 4, y: area.midY),
            in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Right half")
        let top = try XCTUnwrap(plan.frames[1])
        let bottom = try XCTUnwrap(plan.frames[2])
        XCTAssertEqual(top.width, bottom.width, accuracy: 1)
        XCTAssertEqual(top.height, bottom.height, accuracy: 1)
        XCTAssertEqual(top.minX, bottom.minX, accuracy: 1)
        XCTAssertGreaterThan(top.minX, area.midX)
        XCTAssertEqual(bottom.minY - top.maxY, HyperspaceLayoutPlanner.gap, accuracy: 1)
        XCTAssertEqual(bottom.maxX, area.maxX, accuracy: 1)
        XCTAssertEqual(bottom.maxY, area.maxY, accuracy: 1)
    }

    func testTwoSelectedWindowsSplitTheTopHalfSideBySide() throws {
        let originals = [
            UInt32(4): CGRect(x: 200, y: 80, width: 500, height: 400),
            UInt32(5): CGRect(x: 760, y: 220, width: 420, height: 360),
        ]
        let plan = HyperspaceLayoutPlanner.dropGroup([4, 5], originals: originals, anchor: 5,
            start: CGPoint(x: 800, y: 300), at: CGPoint(x: area.midX, y: area.minY + 4),
            in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Top half")
        let left = try XCTUnwrap(plan.frames[4])
        let right = try XCTUnwrap(plan.frames[5])
        XCTAssertEqual(left.width, right.width, accuracy: 1)
        XCTAssertEqual(left.height, right.height, accuracy: 1)
        XCTAssertEqual(left.minY, area.minY, accuracy: 1)
        XCTAssertEqual(right.minX - left.maxX, HyperspaceLayoutPlanner.gap, accuracy: 1)
        XCTAssertLessThan(left.maxY, area.midY)
    }

    func testAFreeGroupDragCarriesEveryWindowByTheSameAmount() throws {
        let originals = [
            UInt32(1): CGRect(x: 200, y: 80, width: 400, height: 300),
            UInt32(2): CGRect(x: 700, y: 200, width: 360, height: 280),
        ]
        let plan = HyperspaceLayoutPlanner.dropGroup([1, 2], originals: originals, anchor: 1,
            start: CGPoint(x: 900, y: 500), at: CGPoint(x: 960, y: 540),
            in: area, neighbors: [])
        XCTAssertEqual(plan.title, "Move windows")
        let first = try XCTUnwrap(plan.frames[1])
        let second = try XCTUnwrap(plan.frames[2])
        XCTAssertEqual(first.minX - originals[1]!.minX, second.minX - originals[2]!.minX, accuracy: 1)
        XCTAssertEqual(first.minY - originals[1]!.minY, second.minY - originals[2]!.minY, accuracy: 1)
    }

    func testGridOnUltrawideIsTwoByTwoNotFourColumns() throws {
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let plans = HyperspaceLayoutPlanner.arrangements([1, 2, 3, 4], in: ultrawide)
        let grid = try XCTUnwrap(plans.first)
        XCTAssertEqual(grid.title, "Balanced grid")
        XCTAssertEqual(Set(grid.frames.values.map(\.minY)).count, 2)
        XCTAssertEqual(Set(grid.frames.values.map(\.minX)).count, 2)
    }

    func testGridForSixOnUltrawideIsThreeAcross() throws {
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let grid = try XCTUnwrap(HyperspaceLayoutPlanner.grid([1, 2, 3, 4, 5, 6], in: ultrawide))
        XCTAssertEqual(Set(grid.frames.values.map(\.minY)).count, 2)
        XCTAssertEqual(Set(grid.frames.values.map(\.minX)).count, 3)
    }

    func testThreeWindowsOfferAGridWithTheFirstPickOnTop() throws {
        let plans = HyperspaceLayoutPlanner.options([1, 2, 3], in: area)
        let grid = try XCTUnwrap(plans.first { $0.title == "Balanced grid" })
        let top = try XCTUnwrap(grid.frames[1])
        XCTAssertEqual(top.minY, area.minY, accuracy: 1)
        XCTAssertEqual(top.width, area.width, accuracy: 1)
        XCTAssertLessThan(try XCTUnwrap(grid.frames[2]).width, top.width)
    }

    func testArrangementsKeepRowsWhenFourWindowsAlreadyFillTheTray() throws {
        let plans = HyperspaceLayoutPlanner.arrangements([1, 2, 3, 4], in: area)
        XCTAssertEqual(plans.map(\.title).first, "Balanced grid")
        XCTAssertTrue(plans.contains { $0.title == "Rows" })
        XCTAssertTrue(plans.contains { $0.title == "Main left" })
        XCTAssertGreaterThan(plans.count, HyperspaceLayoutPlanner.options([1, 2, 3, 4], in: area).count)
        for plan in plans {
            XCTAssertEqual(Set(plan.frames.keys), [1, 2, 3, 4])
        }
    }

    func testLandingSlotPicksTheWindowUnderThePointer() throws {
        let plan = try XCTUnwrap(HyperspaceLayoutPlanner.columns([9, 3, 7], in: area))
        let third = try XCTUnwrap(plan.frames[7])
        XCTAssertEqual(HyperspaceLayoutPlanner.landingSlot(9, at: CGPoint(x: third.midX, y: third.midY), slots: plan.frames), 7)
        let first = try XCTUnwrap(plan.frames[9])
        XCTAssertNil(HyperspaceLayoutPlanner.landingSlot(9, at: CGPoint(x: first.midX, y: first.midY), slots: plan.frames))
        let gap = CGPoint(x: first.maxX + 1, y: first.midY)
        XCTAssertNotNil(HyperspaceLayoutPlanner.landingSlot(7, at: gap, slots: plan.frames))
    }
}
