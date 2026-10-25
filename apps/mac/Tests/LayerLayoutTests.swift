import CoreGraphics
import XCTest
@testable import Lattices

final class LayerLayoutTests: XCTestCase {
    private let ultrawide: CGFloat = 3440 / 1440
    private let standard: CGFloat = 1512 / 982

    func testParsesLayoutNames() {
        XCTAssertEqual(LayerLayout.Kind("auto"), .auto)
        XCTAssertEqual(LayerLayout.Kind("Smart"), .auto)
        XCTAssertEqual(LayerLayout.Kind("columns"), .columns)
        XCTAssertEqual(LayerLayout.Kind("master-stack"), .masterStack)
        XCTAssertNil(LayerLayout.Kind("spiral"))
    }

    func testLStepsThroughTheLayoutsAndBackToNone() {
        XCTAssertEqual(LayerLayout.next(after: nil), "auto")
        XCTAssertEqual(LayerLayout.next(after: "auto"), "columns")
        XCTAssertEqual(LayerLayout.next(after: "columns"), "master-stack")
        XCTAssertNil(LayerLayout.next(after: "master-stack"))
        // Other names for a layout step on from it; one it doesn't know starts over.
        XCTAssertEqual(LayerLayout.next(after: "smart"), "columns")
        XCTAssertNil(LayerLayout.next(after: "main"))
        XCTAssertEqual(LayerLayout.next(after: "spiral"), "auto")
        // Every name it steps through reads back as a layout.
        XCTAssertEqual(LayerLayout.cycle.map(\.name).compactMap(LayerLayout.Kind.init), LayerLayout.cycle)
    }

    func testNamesALayoutForThePreview() {
        XCTAssertEqual(LayerLayout.title(nil), "In place")
        XCTAssertEqual(LayerLayout.title("columns"), "Columns")
        XCTAssertEqual(LayerLayout.title("master"), "Master-stack")
        XCTAssertEqual(LayerLayout.title("spiral"), "spiral")
    }

    func testAutoOnAnUltrawideGivesEachLaneAColumn() {
        // Entry order: terminal, browser, editor. Lanes put the editor in the middle.
        let frames = LayerLayout.frames(.auto, types: [.terminal, .browser, .editor], aspect: ultrawide)
        assertEqual(frames, [
            CGRect(x: 0, y: 0, width: 0.3, height: 1),
            CGRect(x: 0.7, y: 0, width: 0.3, height: 1),
            CGRect(x: 0.3, y: 0, width: 0.4, height: 1),
        ])
    }

    func testAutoOnAnUltrawideStacksALane() {
        let frames = LayerLayout.frames(.auto, types: [.editor, .editor, .browser], aspect: ultrawide)
        assertEqual(frames, [
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        ])
    }

    func testAutoOnAStandardDisplayLeadsWithTheEditor() {
        let frames = LayerLayout.frames(.auto, types: [.terminal, .editor, .browser], aspect: standard)
        assertEqual(frames, [
            CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ])
    }

    func testALoneWindowIsCentredOnAnUltrawide() {
        assertEqual(LayerLayout.frames(.auto, types: [.browser], aspect: ultrawide), [CGRect(x: 0.25, y: 0, width: 0.5, height: 1)])
        assertEqual(LayerLayout.frames(.columns, types: [.browser], aspect: standard), [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testColumnsGiveExtrasToTheLeft() {
        let frames = LayerLayout.frames(.columns, types: Array(repeating: .other, count: 4), aspect: standard)
        assertEqual(frames, [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5),
            CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
            CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1),
        ])
    }

    func testMasterStack() {
        let frames = LayerLayout.frames(.masterStack, types: [.editor, .terminal, .browser], aspect: ultrawide)
        assertEqual(frames, [
            CGRect(x: 0, y: 0, width: 0.62, height: 1),
            CGRect(x: 0.62, y: 0, width: 0.38, height: 0.5),
            CGRect(x: 0.62, y: 0.5, width: 0.38, height: 0.5),
        ])
    }

    func testAStackOfFiveIsAGridTwoWide() {
        let frames = LayerLayout.frames(.masterStack, types: Array(repeating: .other, count: 6), aspect: standard)
        let right = 1 - LayerLayout.masterRatio
        assertEqual(Array(frames.dropFirst()), [
            CGRect(x: 0.62, y: 0, width: right / 2, height: 1.0 / 3),
            CGRect(x: 0.62 + right / 2, y: 0, width: right / 2, height: 1.0 / 3),
            CGRect(x: 0.62, y: 1.0 / 3, width: right / 2, height: 1.0 / 3),
            CGRect(x: 0.62 + right / 2, y: 1.0 / 3, width: right / 2, height: 1.0 / 3),
            CGRect(x: 0.62, y: 2.0 / 3, width: right, height: 1.0 / 3),
        ])
    }

    func testPlannerClassifiesNativeAppsAndPreservesMemberOrder() {
        let entries = ["Safari", "Xcode", "Ghostty"].enumerated().map { index, app in
            WindowEntry(wid: UInt32(index + 1), app: app, pid: Int32(index + 10), title: app,
                        frame: WindowFrame(x: 50, y: 50, w: 400, h: 300), spaceIds: [1],
                        isOnScreen: true, latticesSession: nil)
        }
        let members: [LayerMembership.Member] = entries.enumerated().map {
            (entry: $0.element, placed: false, project: $0.offset)
        }
        let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let plan = LayerLayout.plan(.auto, members: members, excluding: [], main: display,
            otherDisplays: [], currentSpace: 1, visibleFrame: display, standardWindows: [1, 2, 3])
        XCTAssertEqual(plan.map(\.entry), entries)
        XCTAssertEqual(plan.map(\.frame), [CGRect(x: 2408, y: 0, width: 1032, height: 1440),
                                          CGRect(x: 1032, y: 0, width: 1376, height: 1440),
                                          CGRect(x: 0, y: 0, width: 1032, height: 1440)])
    }

    func testPlannerUsesFullTitleAndPreservesDistinctEntriesWithRepeatedWindowIDs() {
        func entry(_ fullTitle: String) -> WindowEntry {
            var entry = WindowEntry(wid: 1, app: "Safari", pid: 10, title: "",
                frame: WindowFrame(x: 50, y: 50, w: 400, h: 300), spaceIds: [1],
                isOnScreen: true, latticesSession: nil)
            entry.fullTitle = fullTitle
            return entry
        }
        let entries = [entry("First full title"), entry("Second full title")]
        let members: [LayerMembership.Member] = entries.map { (entry: $0, placed: false, project: 0) }
        let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let plan = LayerLayout.plan(.columns, members: members, excluding: [], main: display,
            otherDisplays: [], currentSpace: 1, visibleFrame: display, standardWindows: [1])
        XCTAssertEqual(plan.map(\.entry), entries)
        XCTAssertEqual(plan.map(\.frame), [CGRect(x: 0, y: 0, width: 500, height: 600),
                                          CGRect(x: 500, y: 0, width: 500, height: 600)])
    }

    private func assertEqual(_ actual: [CGRect], _ expected: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            for (x, y) in [(a.minX, e.minX), (a.minY, e.minY), (a.width, e.width), (a.height, e.height)] {
                XCTAssertEqual(x, y, accuracy: 1e-9, "\(a) ≠ \(e)", file: file, line: line)
            }
        }
    }
}
