import CoreGraphics
import XCTest
@testable import Lattices

final class SpatialLensTests: XCTestCase {
    private let visibleFrame = CGRect(x: 100, y: 40, width: 900, height: 600)

    func testUnknownGeometryStartsAtHalf() {
        let result = SpatialPlacementCycle.resolve(
            direction: .left,
            currentFrame: CGRect(x: 240, y: 160, width: 420, height: 260),
            sourceVisibleFrame: visibleFrame
        )

        XCTAssertEqual(result.cycleIndex, 0)
        XCTAssertEqual(result.placement, .tile(.left))
        XCTAssertEqual(result.label, "Left ½")
    }

    func testCycleUsesLiveGeometryAndWraps() {
        let steps = SpatialPlacementCycle.steps(for: .right)

        for index in steps.indices {
            let current = WindowTiler.tileFrame(
                fractions: steps[index].placement.fractions,
                inDisplay: visibleFrame
            )
            let result = SpatialPlacementCycle.resolve(
                direction: .right,
                currentFrame: current,
                sourceVisibleFrame: visibleFrame
            )
            XCTAssertEqual(result, steps[(index + 1) % steps.count])
        }
    }

    func testDirectionalCyclesHaveExpectedFractions() {
        assertFractions(.left, [
            (0, 0, 0.5, 1),
            (0, 0, 1.0 / 3.0, 1),
            (0, 0, 2.0 / 3.0, 1),
        ])
        assertFractions(.right, [
            (0.5, 0, 0.5, 1),
            (2.0 / 3.0, 0, 1.0 / 3.0, 1),
            (1.0 / 3.0, 0, 2.0 / 3.0, 1),
        ])
        assertFractions(.up, [
            (0, 0, 1, 0.5),
            (0, 0, 1, 1.0 / 3.0),
            (0, 0, 1, 2.0 / 3.0),
        ])
        assertFractions(.down, [
            (0, 0.5, 1, 0.5),
            (0, 2.0 / 3.0, 1, 1.0 / 3.0),
            (0, 1.0 / 3.0, 1, 2.0 / 3.0),
        ])
    }

    func testDirectionHasDeadzoneAndUsesAppKitAxes() {
        XCTAssertNil(SpatialLensGesture.direction(delta: CGVector(dx: 20, dy: 5)))
        XCTAssertEqual(SpatialLensGesture.direction(delta: CGVector(dx: -80, dy: 5)), .left)
        XCTAssertEqual(SpatialLensGesture.direction(delta: CGVector(dx: 80, dy: -5)), .right)
        XCTAssertEqual(SpatialLensGesture.direction(delta: CGVector(dx: 5, dy: 80)), .up)
        XCTAssertEqual(SpatialLensGesture.direction(delta: CGVector(dx: -5, dy: -80)), .down)
    }

    func testLensTargetsExposeFourCyclesAndFourCorners() {
        XCTAssertEqual(Set(SpatialLensTarget.allCases), Set([
            .topLeft, .top, .topRight,
            .left, .right,
            .bottomLeft, .bottom, .bottomRight,
        ]))
        XCTAssertEqual(SpatialLensTarget.top.cardinalDirection, .up)
        XCTAssertEqual(SpatialLensTarget.left.cardinalDirection, .left)
        XCTAssertEqual(SpatialLensTarget.topLeft.cornerPlacement, .tile(.topLeft))
        XCTAssertEqual(SpatialLensTarget.bottomRight.cornerPlacement, .tile(.bottomRight))
    }

    func testPaintedLensTargetsAreTheirHitTargets() {
        let anchor = CGPoint(x: 500, y: 400)
        let regions = SpatialLensTargetLayout.regions(
            center: anchor,
            within: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(regions.count, 8)
        XCTAssertEqual(SpatialLensTargetLayout.center(of: regions), anchor)
        for region in regions {
            let selection = SpatialLensTargetLayout.selection(
                at: CGPoint(x: region.rect.midX, y: region.rect.midY),
                anchor: anchor,
                regions: regions
            )
            XCTAssertEqual(selection?.target, region.target)
            XCTAssertEqual(selection?.source, .paintedTarget)
        }
        XCTAssertNil(SpatialLensTargetLayout.target(at: anchor, anchor: anchor, regions: regions))
    }

    func testLensTargetsStayVisibleNearScreenEdges() {
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 500)
        let regions = SpatialLensTargetLayout.regions(
            center: CGPoint(x: bounds.minX, y: bounds.maxY),
            within: bounds
        )

        for region in regions {
            XCTAssertTrue(bounds.insetBy(dx: SpatialLensTargetLayout.edgeInset, dy: SpatialLensTargetLayout.edgeInset).contains(region.rect))
        }
    }

    func testLongFlickUsesEightWayDirection() {
        XCTAssertEqual(SpatialLensTargetLayout.nearestTarget(to: CGVector(dx: 200, dy: 0)), .right)
        XCTAssertEqual(SpatialLensTargetLayout.nearestTarget(to: CGVector(dx: 200, dy: 200)), .topRight)
        XCTAssertEqual(SpatialLensTargetLayout.nearestTarget(to: CGVector(dx: 0, dy: 200)), .top)
        XCTAssertEqual(SpatialLensTargetLayout.nearestTarget(to: CGVector(dx: -200, dy: -200)), .bottomLeft)
        XCTAssertEqual(SpatialLensTargetLayout.nearestTarget(to: CGVector(dx: 0, dy: -200)), .bottom)

        let anchor = CGPoint(x: 500, y: 400)
        let regions = SpatialLensTargetLayout.regions(
            center: anchor,
            within: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        XCTAssertEqual(
            SpatialLensTargetLayout.selection(
                at: CGPoint(x: anchor.x - 270, y: anchor.y),
                anchor: anchor,
                regions: regions
            ),
            SpatialLensTargetSelection(target: .left, source: .outerFlick)
        )
    }

    func testDisplayPushRequiresDeliberateOuterFlick() {
        let thresholds = SpatialLensGesture.displayPushThresholds(minDimension: 1_440)
        XCTAssertEqual(thresholds.enter, 432, accuracy: 0.001)
        XCTAssertEqual(thresholds.exit, 336.96, accuracy: 0.001)

        XCTAssertFalse(SpatialLensGesture.displayPushRequested(
            selectionSource: .paintedTarget,
            wasPushed: false,
            distance: 1_000,
            minDimension: 1_440
        ))
        XCTAssertFalse(SpatialLensGesture.displayPushRequested(
            selectionSource: .outerFlick,
            wasPushed: false,
            distance: 270,
            minDimension: 1_440
        ))
        XCTAssertTrue(SpatialLensGesture.displayPushRequested(
            selectionSource: .outerFlick,
            wasPushed: false,
            distance: thresholds.enter,
            minDimension: 1_440
        ))
    }

    func testDisplayPushUsesHysteresis() {
        XCTAssertFalse(SpatialLensGesture.pushed(
            wasPushed: false, distance: 199, enterThreshold: 200, exitThreshold: 140
        ))
        XCTAssertTrue(SpatialLensGesture.pushed(
            wasPushed: false, distance: 200, enterThreshold: 200, exitThreshold: 140
        ))
        XCTAssertTrue(SpatialLensGesture.pushed(
            wasPushed: true, distance: 140, enterThreshold: 200, exitThreshold: 140
        ))
        XCTAssertFalse(SpatialLensGesture.pushed(
            wasPushed: true, distance: 139, enterThreshold: 200, exitThreshold: 140
        ))
    }

    func testExactControlOptionHoldPressesAndReleases() {
        var state = SpatialLensModifierState()

        XCTAssertNil(state.flagsChanged(control: true, option: false, command: false, shift: false))
        XCTAssertEqual(
            state.flagsChanged(control: true, option: true, command: false, shift: false),
            .pressed(generation: 1)
        )
        XCTAssertEqual(
            state.flagsChanged(control: true, option: false, command: false, shift: false),
            .released(generation: 1)
        )
    }

    func testHyperFlagsNeverActivateControlOptionHold() {
        var state = SpatialLensModifierState()

        XCTAssertNil(state.flagsChanged(control: true, option: true, command: true, shift: true))
        XCTAssertNil(state.keyDown())
        XCTAssertNil(state.flagsChanged(control: true, option: true, command: true, shift: false))
        XCTAssertNil(state.flagsChanged(control: true, option: true, command: false, shift: false))
    }

    func testShiftFirstLayerChordDoesNotOpenLensWhenShiftLiftsFirst() {
        var state = SpatialLensModifierState()

        XCTAssertNil(state.flagsChanged(control: false, option: false, command: false, shift: true))
        XCTAssertNil(state.flagsChanged(control: true, option: false, command: false, shift: true))
        XCTAssertNil(state.flagsChanged(control: true, option: true, command: false, shift: true))
        XCTAssertNil(state.flagsChanged(control: true, option: true, command: false, shift: false))
        XCTAssertNil(state.flagsChanged(control: true, option: false, command: false, shift: false))
        XCTAssertEqual(
            state.flagsChanged(control: true, option: true, command: false, shift: false),
            .pressed(generation: 1)
        )
    }

    func testControlOptionShortcutCancelsUntilPairReleased() {
        var state = SpatialLensModifierState()

        XCTAssertEqual(
            state.flagsChanged(control: true, option: true, command: false, shift: false),
            .pressed(generation: 1)
        )
        XCTAssertEqual(state.keyDown(), .chorded(generation: 1))
        XCTAssertNil(state.flagsChanged(control: true, option: true, command: false, shift: false))
        XCTAssertNil(state.flagsChanged(control: true, option: false, command: false, shift: false))
        XCTAssertEqual(
            state.flagsChanged(control: true, option: true, command: false, shift: false),
            .pressed(generation: 2)
        )
    }

    func testTopologyFindsPhysicalNeighborsIndependentOfArrayOrder() {
        let topology = DisplayTopology(displays: [
            display("below", x: 0, y: 100),
            display("right", x: 100, y: 0),
            display("source", x: 0, y: 0),
            display("left", x: -100, y: 0),
            display("above", x: 0, y: -100),
        ])

        XCTAssertEqual(topology.adjacent(to: "source", direction: .left)?.id, "left")
        XCTAssertEqual(topology.adjacent(to: "source", direction: .right)?.id, "right")
        XCTAssertEqual(topology.adjacent(to: "source", direction: .up)?.id, "above")
        XCTAssertEqual(topology.adjacent(to: "source", direction: .down)?.id, "below")
        XCTAssertEqual(topology.spatialOrder.map(\.id), ["left", "above", "source", "below", "right"])
    }

    func testTopologyPrefersPerpendicularOverlap() {
        let topology = DisplayTopology(displays: [
            display("diagonal", x: 70, y: 250),
            display("source", x: 0, y: 0),
            display("aligned", x: 120, y: 10),
        ])

        XCTAssertEqual(topology.adjacent(to: "source", direction: .right)?.id, "aligned")
    }

    private func display(_ id: String, x: CGFloat, y: CGFloat) -> DisplayTopology.Display {
        let frame = CGRect(x: x, y: y, width: 100, height: 100)
        return DisplayTopology.Display(
            id: id,
            apiIndex: Int(x + y + 1_000),
            name: id,
            frame: frame,
            visibleFrame: frame
        )
    }

    private func assertFractions(
        _ direction: SpatialDirection,
        _ expected: [(CGFloat, CGFloat, CGFloat, CGFloat)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = SpatialPlacementCycle.steps(for: direction).map(\.placement.fractions)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (value, wanted) in zip(actual, expected) {
            XCTAssertEqual(value.0, wanted.0, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(value.1, wanted.1, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(value.2, wanted.2, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(value.3, wanted.3, accuracy: 0.0001, file: file, line: line)
        }
    }
}
