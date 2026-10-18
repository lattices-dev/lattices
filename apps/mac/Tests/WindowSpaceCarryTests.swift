import XCTest
@testable import Lattices

final class WindowSpaceCarryTests: XCTestCase {
    private struct Node: Equatable {
        let identifier: String
        var children: [Node] = []
    }

    private func displays(_ roots: [Node]) -> [Node] {
        WindowSpaceCarry.displayNodes(in: roots, identifier: { $0.identifier }, children: { $0.children })
    }

    func testRecognizesDirectWindowManagerDisplays() {
        let display = Node(identifier: "mc.display")
        XCTAssertEqual(displays([Node(identifier: "WindowManager", children: [display])]), [display])
    }

    func testRecognizesDockMissionControlWhenWindowManagerIsEmpty() {
        let display = Node(identifier: "mc.display")
        let dock = Node(identifier: "Dock", children: [
            Node(identifier: "AXList"), Node(identifier: "mc", children: [display, display]),
        ])
        XCTAssertEqual(displays([Node(identifier: "WindowManager"), dock]), [display, display])
    }

    func testClosedMissionControlAndUnrelatedGroupsAreNotDisplays() {
        let unrelated = Node(identifier: "unrelated", children: [Node(identifier: "mc.display")])
        XCTAssertEqual(displays([Node(identifier: "Dock", children: [unrelated])]), [])
        XCTAssertEqual(displays([]), [])
    }

    func testDoesNotDuplicateDisplaysAcrossHosts() {
        let display = Node(identifier: "mc.display")
        let root = Node(identifier: "host", children: [display])
        XCTAssertEqual(displays([root, root]), [display])
    }
}
