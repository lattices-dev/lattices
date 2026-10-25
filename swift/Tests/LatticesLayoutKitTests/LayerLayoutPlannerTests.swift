import CoreGraphics
import XCTest
import LatticesLayoutKit

final class LayerLayoutPlannerTests: XCTestCase {
    private typealias Planner = LayerLayoutPlanner

    func testEmptyLayoutsAndSingleWindowAtAspectBoundary() {
        for kind in [Planner.Kind.auto, .columns, .masterStack] {
            XCTAssertTrue(Planner.frames(kind, lanes: [], aspect: 2).isEmpty)
            assertFrames(Planner.frames(kind, lanes: [.right], aspect: 1.999),
                         [CGRect(x: 0, y: 0, width: 1, height: 1)])
            assertFrames(Planner.frames(kind, lanes: [.right], aspect: 2),
                         [CGRect(x: 0.25, y: 0, width: 0.5, height: 1)])
        }
    }

    func testWideAutoUsesLaneWidthsAndPreservesInputOrder() {
        assertFrames(Planner.frames(.auto, lanes: [.right, .left, .middle], aspect: 2.4), [
            CGRect(x: 0.7, y: 0, width: 0.3, height: 1),
            CGRect(x: 0, y: 0, width: 0.3, height: 1),
            CGRect(x: 0.3, y: 0, width: 0.4, height: 1),
        ])
    }

    func testWideAutoSplitsTwoUsedLanesEqually() {
        assertFrames(Planner.frames(.auto, lanes: [.right, .middle, .middle], aspect: 2.4), [
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
        ])
    }

    func testWideAutoDistributesASingleLaneAcrossFourColumns() {
        assertFrames(Planner.frames(.auto, lanes: Array(repeating: .right, count: 5), aspect: 2.4), [
            CGRect(x: 0, y: 0, width: 0.25, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5),
            CGRect(x: 0.25, y: 0, width: 0.25, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.25, height: 1),
            CGRect(x: 0.75, y: 0, width: 0.25, height: 1),
        ])
    }

    func testStandardAutoLeadsWithFirstMiddleLaneAndStacksInLaneOrder() {
        assertFrames(Planner.frames(.auto, lanes: [.right, .middle, .left, .middle], aspect: 1.6), [
            CGRect(x: 0.5, y: 2.0 / 3, width: 0.5, height: 1.0 / 3),
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0 / 3),
            CGRect(x: 0.5, y: 1.0 / 3, width: 0.5, height: 1.0 / 3),
        ])
    }

    func testStandardAutoWithoutMiddleLaneLeadsWithFirstUsedLane() {
        assertFrames(Planner.frames(.auto, lanes: [.right, .left], aspect: 1.6), [
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
        ])
    }

    func testStandardColumnsGiveExtraWindowsToLeftColumn() {
        assertFrames(Planner.frames(.columns, lanes: Array(repeating: .right, count: 4), aspect: 1.6), [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5),
            CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
            CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1),
        ])
    }

    func testMasterStackLastOddWindowSpansItsRow() {
        assertFrames(Planner.frames(.masterStack, lanes: Array(repeating: .right, count: 6), aspect: 1.6), [
            CGRect(x: 0, y: 0, width: 0.62, height: 1),
            CGRect(x: 0.62, y: 0, width: 0.19, height: 1.0 / 3),
            CGRect(x: 0.81, y: 0, width: 0.19, height: 1.0 / 3),
            CGRect(x: 0.62, y: 1.0 / 3, width: 0.19, height: 1.0 / 3),
            CGRect(x: 0.81, y: 1.0 / 3, width: 0.19, height: 1.0 / 3),
            CGRect(x: 0.62, y: 2.0 / 3, width: 0.38, height: 1.0 / 3),
        ])
    }

    func testPlanFiltersEachEligibilityFactWithoutReordering() {
        let candidates = [candidate(7), candidate(1, placed: true), candidate(2),
                          candidate(3, hasTitle: false), candidate(4, spaces: [2]),
                          candidate(5), candidate(8)]
        let plan = Planner.plan(.columns, candidates: candidates,
                                context: context(excluding: [2], standard: [1, 2, 3, 4, 7, 8]))
        XCTAssertEqual(plan.map(\.windowID), [7, 8])
        XCTAssertEqual(plan.map(\.inputIndex), [0, 6])
        XCTAssertEqual(plan.map(\.frame), [CGRect(x: 0, y: 0, width: 500, height: 600),
                                          CGRect(x: 500, y: 0, width: 500, height: 600)])
    }

    func testMainDisplayCentreTakesPrecedenceAndOtherDisplayCentreIsExcluded() {
        let candidates = [candidate(1, frame: CGRect(x: 850, y: 100, width: 200, height: 100)),
                          candidate(2, frame: CGRect(x: 980, y: 100, width: 200, height: 100))]
        let plan = Planner.plan(.columns, candidates: candidates,
            context: context(others: [CGRect(x: 900, y: 0, width: 800, height: 600)]))
        XCTAssertEqual(plan.map(\.windowID), [1])
    }

    func testPlanKeepsIntersectingAndRightParkedWindowsButRejectsUnrelatedOffscreenWindow() {
        let candidates = [candidate(1, frame: CGRect(x: -200, y: 50, width: 300, height: 100)),
                          candidate(2, frame: CGRect(x: 1010, y: 50, width: 300, height: 100)),
                          candidate(3, frame: CGRect(x: -300, y: 50, width: 100, height: 100))]
        let plan = Planner.plan(.columns, candidates: candidates, context: context())
        XCTAssertEqual(plan.map(\.windowID), [1, 2])
    }

    func testParkedWindowOnAnotherDisplayRemainsExcluded() {
        let plan = Planner.plan(.columns,
            candidates: [candidate(1, frame: CGRect(x: 1010, y: 50, width: 300, height: 100))],
            context: context(others: [CGRect(x: 1000, y: 0, width: 1000, height: 600)]))
        XCTAssertTrue(plan.isEmpty)
    }

    func testPlanPreservesRepeatedIDsThroughOriginalInputIndices() {
        let plan = Planner.plan(.columns, candidates: [candidate(9, placed: true), candidate(9), candidate(9)],
                                context: context())
        XCTAssertEqual(plan.map(\.windowID), [9, 9])
        XCTAssertEqual(plan.map(\.inputIndex), [1, 2])
    }

    func testProjectionRoundsEdgesAtNegativeOriginsWithoutGaps() {
        let visible = CGRect(x: -100.25, y: 24.25, width: 1000, height: 600)
        let plan = Planner.plan(.columns, candidates: [candidate(1), candidate(2), candidate(3)],
                                context: context(visible: visible))
        XCTAssertEqual(plan.map(\.frame), [CGRect(x: -100, y: 24, width: 333, height: 600),
                                          CGRect(x: 233, y: 24, width: 333, height: 600),
                                          CGRect(x: 566, y: 24, width: 334, height: 600)])
        XCTAssertEqual(plan[0].frame.maxX, plan[1].frame.minX)
        XCTAssertEqual(plan[1].frame.maxX, plan[2].frame.minX)
        XCTAssertEqual(plan.last?.frame.maxX, 900)
    }

    func testPlanRequiresAnOrdinarySpaceAndFiniteUsableFrame() {
        for space in [0, -1] {
            XCTAssertTrue(Planner.plan(.columns, candidates: [candidate(1)],
                                      context: context(space: space)).isEmpty)
        }
        for visible in [CGRect.zero, CGRect(x: 0, y: 0, width: 100, height: 0),
                        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertTrue(Planner.plan(.columns, candidates: [candidate(1)],
                                      context: context(visible: visible)).isEmpty)
        }
    }

    private func candidate(_ id: UInt32, frame: CGRect = CGRect(x: 50, y: 50, width: 400, height: 300),
                           spaces: [Int] = [1], placed: Bool = false, hasTitle: Bool = true,
                           lane: Planner.Lane = .right) -> Planner.Candidate {
        .init(windowID: id, frame: frame, spaceIDs: spaces, isPlaced: placed, hasTitle: hasTitle, lane: lane)
    }

    private func context(visible: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 600),
                         others: [CGRect] = [], space: Int = 1, excluding: Set<UInt32> = [],
                         standard: Set<UInt32> = Set((1...100).map { UInt32($0) })) -> Planner.Context {
        .init(mainBounds: CGRect(x: 0, y: 0, width: 1000, height: 600), otherDisplayBounds: others,
              currentSpaceID: space, visibleFrame: visible, excludedWindowIDs: excluding, standardWindowIDs: standard)
    }

    private func assertFrames(_ actual: [CGRect], _ expected: [CGRect],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            for (a, e) in [(actual.minX, expected.minX), (actual.minY, expected.minY),
                           (actual.width, expected.width), (actual.height, expected.height)] {
                XCTAssertEqual(a, e, accuracy: 1e-9, file: file, line: line)
            }
        }
    }
}
