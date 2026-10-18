import XCTest
@testable import Lattices

final class MouseGestureInkTests: XCTestCase {
    private func rule(
        _ id: String,
        button: MouseShortcutButton = .middle,
        kind: MouseShortcutTriggerKind,
        direction: MouseGestureDirection? = nil,
        shape: GestureShapeLabel? = nil,
        action: MouseShortcutActionDefinition,
        enabled: Bool = true
    ) -> MouseShortcutRule {
        MouseShortcutRule(
            id: id,
            enabled: enabled,
            device: .any,
            trigger: MouseShortcutTrigger(button: button, kind: kind, direction: direction, shape: shape),
            action: action
        )
    }

    func testTitlesNameTheAction() {
        XCTAssertEqual(MouseGestureInkTitle.of(.init(type: .spaceNext)), .init("Next desktop"))
        XCTAssertEqual(MouseGestureInkTitle.of(.init(type: .appActivate, app: "Ghostty")), .init("Ghostty"))
        let area = MouseShortcutKeyStroke(key: "4", keyCode: nil, modifiers: [.command, .shift])
        XCTAssertEqual(MouseGestureInkTitle.of(.init(type: .shortcutSend, shortcut: area)), .init("Screenshot area", detail: "⇧⌘4"))
        let other = MouseShortcutKeyStroke(key: "k", keyCode: nil, modifiers: [.command, .option, .control])
        XCTAssertEqual(MouseGestureInkTitle.of(.init(type: .shortcutSend, shortcut: other)), .init("⌃⌥⌘K"))
    }

    func testMenuKeepsTheFirstEnabledRuleForTheButton() {
        let rules = [
            rule("off", kind: .drag, direction: .right, action: .init(type: .dictationStart), enabled: false),
            rule("next", kind: .drag, direction: .right, action: .init(type: .spaceNext)),
            rule("shadowed", kind: .drag, direction: .right, action: .init(type: .screenMapToggle)),
            rule("back", button: .button4, kind: .drag, direction: .left, action: .init(type: .spacePrevious)),
            rule("circle", kind: .shape, shape: .circle, action: .init(type: .screenMapToggle)),
            rule("click", kind: .click, action: .init(type: .dictationStart)),
        ]
        let menu = MouseGestureInkMenu.build(rules: rules, button: .middle, device: nil, threshold: 68)
        XCTAssertEqual(menu.drags, [.right: .init("Next desktop")])
        XCTAssertEqual(menu.shapes, [.circle: .init("Screen map")])
        XCTAssertEqual(menu.threshold, 68)
    }

    func testStraightenedShapeJoinsSegmentEnds() {
        // A wobbly V: down-right then up-right, in view coordinates (y up).
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: -50), CGPoint(x: 42, y: -100), CGPoint(x: 60, y: -40), CGPoint(x: 80, y: 6)]
        let segments = [
            DirectionSegment(direction: .down, startIndex: 0, endIndex: 2, length: 100),
            DirectionSegment(direction: .up, startIndex: 2, endIndex: 4, length: 106),
        ]
        let ideal = MouseGestureInkRenderer.idealShape(.vShape, path: path, segments: segments)
        XCTAssertEqual(ideal, [CGPoint(x: 0, y: 0), CGPoint(x: 42, y: -100), CGPoint(x: 80, y: 6)])
    }

    func testCircleIsFittedToTheStroke() {
        let path = (0...16).map { i -> CGPoint in
            let a = CGFloat(i) / 16 * 2 * .pi
            return CGPoint(x: 100 + 40 * cos(a), y: 100 + 40 * sin(a))
        }
        let ideal = MouseGestureInkRenderer.idealShape(.circle, path: path, segments: [])
        XCTAssertEqual(ideal.count, 65)
        for point in ideal {
            XCTAssertEqual(hypot(point.x - 100, point.y - 100), 40, accuracy: 0.5)
        }
        XCTAssertEqual(ideal[0].x, path[0].x, accuracy: 0.5)
        // Counter-clockwise stroke, counter-clockwise ideal.
        XCTAssertGreaterThan(ideal[4].y, ideal[0].y)
    }

    func testSmoothingKeepsBothEndsAndCalmsJitter() {
        let jittery = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: $0.isMultiple(of: 2) ? 3 : -3) }
        let smooth = MouseGestureInkRenderer.smoothed(jittery)
        XCTAssertEqual(smooth.first, jittery.first)
        XCTAssertEqual(smooth.last, jittery.last)
        // Away from the ends, where the averaging window is full.
        for point in smooth.dropFirst(16).dropLast(16) {
            XCTAssertLessThan(abs(point.y), 1.5)
        }
    }

    func testResampleSpacesPointsEvenly() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(MouseGestureInkRenderer.resample(line, count: 5),
                       [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 10, y: 10)])
    }

    func testMorphEndsOnTheIdealShape() {
        let wobble = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 8), CGPoint(x: 60, y: -6), CGPoint(x: 90, y: 4)]
        let ideal = MouseGestureInkRenderer.idealDrag(from: wobble[0], to: wobble[3], direction: .right)
        XCTAssertEqual(ideal, [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0)])
        let settled = MouseGestureInkRenderer.morph(wobble, into: ideal, t: 1)
        XCTAssertTrue(settled.allSatisfy { $0.y == 0 })
        XCTAssertEqual(MouseGestureInkRenderer.morph(wobble, into: ideal, t: 0).last, wobble.last)
    }

    private func menu(drags: [MouseGestureDirection] = [], shapes: [GestureShapeLabel]) -> MouseGestureInkMenu {
        var menu = MouseGestureInkMenu(threshold: 68)
        for d in drags { menu.drags[d] = .init(d.displayLabel) }
        for s in shapes { menu.shapes[s] = .init(s.displayName) }
        return menu
    }

    /// CG coordinates: y grows downward.
    private func line(_ from: CGPoint, _ to: CGPoint, steps: Int = 10) -> [CGPoint] {
        (1...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    func testPredictsAVOnceTheSecondArmStarts() {
        let shapes = menu(drags: [.down], shapes: [.vShape, .lShapeDownRight])
        let down = [CGPoint(x: 0, y: 0)] + line(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 90))
        XCTAssertNil(MouseGestureInkPredictor.predict(points: down, menu: shapes))
        let turning = down + line(CGPoint(x: 10, y: 90), CGPoint(x: 16, y: 50), steps: 4)
        XCTAssertEqual(MouseGestureInkPredictor.predict(points: turning, menu: shapes), .vShape)
    }

    func testOneStrokeOnlyPredictsWhenNothingElseStartsThatWay() {
        let down = [CGPoint(x: 0, y: 0)] + line(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 60))
        XCTAssertEqual(MouseGestureInkPredictor.predict(points: down, menu: menu(shapes: [.uShape])), .uShape)
        XCTAssertNil(MouseGestureInkPredictor.predict(points: down, menu: menu(shapes: [.uShape, .vShape])))
    }

    func testPredictsACircleHalfwayRound() {
        let half = (0...24).map { i -> CGPoint in
            let a = CGFloat(i) / 24 * 1.1 * .pi
            return CGPoint(x: 60 * cos(a), y: 60 * sin(a))
        }
        XCTAssertEqual(MouseGestureInkPredictor.predict(points: half, menu: menu(shapes: [.circle, .uShape])), .circle)
        let corner = [CGPoint(x: 0, y: 0)] + line(.zero, CGPoint(x: 0, y: 80)) + line(CGPoint(x: 0, y: 80), CGPoint(x: 80, y: 80))
        XCTAssertFalse(MouseGestureInkPredictor.isTurningSmoothly(corner))
    }

    func testTaperRunsFromHairlineToThePen() {
        let long = (0...100).map { CGPoint(x: CGFloat($0) * 4, y: 0) }
        let widths = MouseGestureInkRenderer.taper(long)
        XCTAssertEqual(widths.last, MouseGestureInkRenderer.headWidth)
        XCTAssertEqual(widths.first, MouseGestureInkRenderer.tailWidth)
        XCTAssertTrue(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testPenInksInSwellsWithTheNibAndLiftsOff() {
        let circle = (0...96).map { i -> CGPoint in
            let a = CGFloat(i) / 96 * 2 * .pi
            return CGPoint(x: 80 * cos(a), y: 80 * sin(a))
        }
        let widths = MouseGestureInkRenderer.penWidths(circle)
        let middle = widths[10..<86]
        XCTAssertLessThan(widths.first!, middle.max()! / 2)
        XCTAssertLessThan(widths.last!, middle.max()! / 2)
        // A broad nib: some of the way round runs full, some runs fine.
        XCTAssertGreaterThan(middle.max()! / middle.min()!, 2)
    }

    func testLatticeHoldsToThePressAndLightsTheCellsCrossed() {
        let origin = CGPoint(x: 7, y: 3)
        let path = [origin, CGPoint(x: 67, y: 3)]
        let cells = MouseGestureInkRenderer.latticeCells(origin: origin, path: path)
        let touched = Set(cells.filter(\.touched).map { [$0.column, $0.row] })
        XCTAssertEqual(touched, [[0, 0], [1, 0], [2, 0], [3, 0]])
        // The reach fades out: nothing more than reach plus a cell away.
        let reach = Int(MouseGestureInkRenderer.latticeReach / MouseGestureInkRenderer.latticePitch) + 1
        XCTAssertTrue(cells.allSatisfy { abs($0.row) <= reach && $0.column >= -reach && $0.column <= 3 + reach })
        XCTAssertTrue(cells.allSatisfy { $0.near > 0 || $0.touched })
    }
}
