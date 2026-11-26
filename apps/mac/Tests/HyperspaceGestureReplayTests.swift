import XCTest
@testable import Lattices

final class HyperspaceGestureReplayTests: XCTestCase {
    typealias Planner = HyperspaceLayoutPlanner
    let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let ids: [UInt32] = [1, 2, 3, 4]

    func testDrawTwoDividersThenPinTheEditor() throws {
        let initial: [UInt32: CGRect] = [
            1: CGRect(x: 40, y: 240, width: 420, height: 360),
            2: CGRect(x: 900, y: 20, width: 420, height: 190),
            3: CGRect(x: 930, y: 300, width: 420, height: 210),
            4: CGRect(x: 920, y: 720, width: 420, height: 190)]
        let down = [CGPoint(x: 639, y: 50), CGPoint(x: 645, y: 510), CGPoint(x: 635, y: 940)]
        let first = try XCTUnwrap(Planner.sketch(down, ids: ids, frames: initial, in: area, prior: nil))
        let editor = try XCTUnwrap(first.frames[1])
        XCTAssertEqual(editor, CGRect(x: 0, y: 0, width: 638, height: 1000))
        XCTAssertEqual(first.frames[2]?.minX, 642)
        XCTAssertEqual(first.sketchRegions.map(\.ids), [ids, [1], [2, 3, 4]])
        let right = [CGPoint(x: 680, y: 400), CGPoint(x: 1080, y: 407), CGPoint(x: 1550, y: 393)]
        let second = try XCTUnwrap(Planner.sketch(right, ids: ids, frames: first.frames, in: area, prior: first))
        XCTAssertEqual(second.frames[1], editor)
        XCTAssertEqual(second.frames[2], CGRect(x: 642, y: 0, width: 958, height: 398))
        XCTAssertEqual(second.frames[3]?.minY, 402)
        XCTAssertEqual(second.frames[4]?.minY, 402)
        // Repeating the cut after Apply discovers the same stack in the live frames.
        let afterApply = try XCTUnwrap(Planner.sketch(right, ids: ids, frames: first.frames, in: area, prior: nil))
        XCTAssertEqual(afterApply.frames[2], second.frames[2])
        XCTAssertNil(afterApply.frames[1])
        let pin = [UInt32(1): editor]
        XCTAssertEqual(Planner.respectingPins(afterApply, pins: pin, in: area)?.frames, second.frames)
        let preset = try XCTUnwrap(Planner.grid(ids, in: area))
        let around = try XCTUnwrap(Planner.respectingPins(preset, pins: pin, in: area))
        XCTAssertEqual(around.frames[1], editor)
        for id in ids.dropFirst() {
            let f = try XCTUnwrap(around.frames[id])
            XCTAssertGreaterThanOrEqual(f.minX, editor.maxX + Planner.gap)
            XCTAssertTrue(area.contains(f))
            for other in ids where other != id { XCTAssertTrue(f.intersection(around.frames[other]!).isEmpty) }
        }
        XCTAssertNil(Planner.respectingPins(.init(title: "Move window", frames: [2: editor]), pins: pin, in: area))
        XCTAssertEqual(Planner.respectingPins(preset, pins: [:], in: area), preset)
        XCTAssertNil(Planner.sketch([.zero, CGPoint(x: 600, y: 650)], ids: ids, frames: initial, in: area, prior: first))
        XCTAssertNil(Planner.sketch([.zero, CGPoint(x: 2, y: 900), CGPoint(x: 1, y: 240)],
                                   ids: ids, frames: initial, in: area, prior: first))
    }

    func testEdgeAndCenterKeepTheirLandingThroughPointerJitter() throws {
        let left = CGRect(x: 0, y: 0, width: 798, height: 1000)
        let right = CGRect(x: 802, y: 0, width: 798, height: 1000)
        let drag = Planner.DesktopDrop(id: 1, original: left, start: left.origin, area: area, neighbors: [(2, right)])
        func sample(_ depth: CGFloat) -> String { drag.plan(at: CGPoint(x: right.midX, y: depth)).title }
        XCTAssertEqual([230, 241, 237, 249, 255, 237, 229, 225].map(sample),
                       ["Share space", "Share space", "Share space", "Share space",
                        "Swap windows", "Swap windows", "Swap windows", "Share space"])
    }

    func testSharedSeamSnapsHoldsAndReleasesAllFourWindows() throws {
        let grid = try XCTUnwrap(Planner.grid(ids, in: area))
        let seams = Planner.dividers(Array(grid.frames))
        let seam = try XCTUnwrap(seams.first { $0.vertical })
        XCTAssertEqual(Set(ids.filter(seam.touches)), Set(ids))
        XCTAssertEqual(seam.affectedFrames.count, 4)
        let start = CGPoint(x: seam.hitFrame.midX + 3, y: 410)
        let targets = seam.snapTargets(alongside: seams)
        var held: CGFloat?
        var edges: [CGFloat] = []
        for x: CGFloat in [542, 545, 554] {
            let next = seam.snapped(at: CGPoint(x: x, y: 410), from: start, targets: targets, held: held)
            held = next.snap
            let left = try XCTUnwrap(next.plan.frames[1])
            edges.append(left.maxX)
            XCTAssertEqual(left.maxX, next.plan.frames[3]?.maxX)
            XCTAssertEqual(next.plan.frames[2]?.minX, next.plan.frames[4]?.minX)
        }
        XCTAssertEqual(edges, [531, 531, 549])
        XCTAssertNil(held)
    }

    func testProposedSeamStillOwnsTheDragAboveIdenticalLiveWindows() throws {
        let grid = try XCTUnwrap(Planner.grid(ids, in: area))
        let background = try XCTUnwrap(Planner.columns([8, 9, 10], in: area))
        let surfaces = (Array(grid.frames) + Array(background.frames)).map { Planner.DividerSurface(target: $0.0, frame: $0.1) }
        let visible = Planner.dividers(surfaces: surfaces, in: area)
        XCTAssertEqual(visible.count, 2)
        let seam = try XCTUnwrap(visible.first { $0.vertical })
        XCTAssertTrue(ids.allSatisfy(seam.touches))
        XCTAssertFalse(seam.touches(9))
        XCTAssertTrue(seam.contains(CGPoint(x: area.midX, y: area.midY)))
    }

    func testGripsWarmFromEitherSideAndFollowThePointerAlongBothAxes() throws {
        let grid = try XCTUnwrap(Planner.grid(ids, in: area))
        let dividers = Planner.dividers(Array(grid.frames))
        XCTAssertEqual(dividers.count, 2)
        for divider in dividers {
            let cross = divider.vertical ? area.midX : area.midY
            func sample(_ offset: CGFloat, _ along: CGFloat = 200) -> CGPoint {
                divider.vertical ? CGPoint(x: cross + offset, y: along) : CGPoint(x: along, y: cross + offset)
            }
            XCTAssertFalse(divider.contains(sample(-40)))
            XCTAssertFalse(divider.contains(sample(40)))
            for offset: CGFloat in [-30, 30] {
                XCTAssertTrue(divider.contains(sample(offset)))
                let far = divider.handleFrame(near: sample(offset))
                let close = divider.handleFrame(near: sample(4))
                XCTAssertLessThan(divider.warmth(at: sample(offset)), divider.warmth(at: sample(4)))
                XCTAssertLessThan(far.width, close.width)
                XCTAssertLessThan(far.height, close.height)
                XCTAssertEqual(divider.vertical ? close.midY : close.midX, 200)
                let atEnd = divider.handleFrame(near: sample(4, 3))
                XCTAssertGreaterThanOrEqual(divider.vertical ? atEnd.minY : atEnd.minX, 0)
            }
        }
    }

    func testHandleAndDragOnlyUseExposedContactOnBothSides() throws {
        let pair = try XCTUnwrap(Planner.columns([1, 2], in: area))
        let tiles = pair.frames.map { Planner.DividerSurface(target: $0.key, frame: $0.value) }
        // Cover one side of the seam, leaving the right tile visible all the way down.
        let cover = Planner.DividerSurface(target: nil, frame: CGRect(x: 400, y: 100, width: 400, height: 700))
        let seam = try XCTUnwrap(Planner.dividers(surfaces: [cover] + tiles, in: area).first)
        XCTAssertFalse(seam.contains(CGPoint(x: area.midX, y: 500)))
        XCTAssertFalse(seam.contains(CGPoint(x: area.midX + 30, y: 500)))
        XCTAssertGreaterThanOrEqual(seam.handleFrame(near: CGPoint(x: area.midX + 4, y: 801)).minY, cover.frame.maxY)
        XCTAssertTrue(seam.contains(CGPoint(x: area.midX, y: 900)))
        XCTAssertEqual(seam.handleFrame.midY, 900)
        XCTAssertFalse(seam.handleFrame.intersects(cover.frame))
        let uncovered = try XCTUnwrap(Planner.dividers(surfaces: tiles + [cover], in: area).first)
        XCTAssertTrue(uncovered.contains(CGPoint(x: area.midX, y: 500)))
        XCTAssertEqual(uncovered.handleFrame.midY, 500)
        let short = try XCTUnwrap(Planner.dividers(surfaces: tiles, in: CGRect(x: 0, y: 500, width: 1600, height: 28)).first)
        XCTAssertEqual(short.handleFrame.height, 28)
        XCTAssertTrue(Planner.dividers(surfaces: [.init(target: nil, frame: area)] + tiles, in: area).isEmpty)
    }

    func testShortSeamCanAlignWithAdjacentRow() throws {
        let frames: [(UInt32, CGRect)] = [
            (1, .init(x: 0, y: 0, width: 698, height: 498)), (2, .init(x: 702, y: 0, width: 898, height: 498)),
            (3, .init(x: 0, y: 502, width: 638, height: 498)), (4, .init(x: 642, y: 502, width: 958, height: 498))]
        let seams = Planner.dividers(frames)
        let upper = try XCTUnwrap(seams.first { $0.vertical && $0.touches(1) })
        let sample = upper.snapped(at: CGPoint(x: 647, y: 240), from: CGPoint(x: 700, y: 240),
                                   targets: upper.snapTargets(alongside: seams), held: nil)
        XCTAssertEqual(sample.snap, 640)
        XCTAssertEqual(sample.plan.frames[1]?.maxX, 638)
        XCTAssertNil(sample.plan.frames[3])
    }
}
