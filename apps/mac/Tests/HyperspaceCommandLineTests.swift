import XCTest
@testable import Lattices

final class HyperspaceCommandLineTests: XCTestCase {
    private func parse(_ s: String) -> HyperspaceCommandLine.Command? {
        try? HyperspaceCommandLine.parse(s).get()
    }

    func testVerbsAndAliases() {
        XCTAssertEqual(parse("g"), .balanced)
        XCTAssertEqual(parse("grid 3x2"), .grid(columns: 3, rows: 2))
        XCTAssertEqual(parse("p chrome"), .pick("chrome"))
        XCTAssertEqual(parse("  only  zed  "), .only("zed"))
        XCTAssertEqual(parse("w"), .apply(leave: false))
        XCTAssertEqual(parse("wq"), .apply(leave: true))
        XCTAssertEqual(parse("q"), .quit)
        XCTAssertEqual(parse("layer Work"), .layer("Work"))
    }

    func testPlacements() {
        guard case .place(let spec, _)? = parse("left") else { return XCTFail() }
        XCTAssertEqual(spec, PlacementSpec(string: "left"))
        guard case .place(let tl, _)? = parse("tl") else { return XCTFail() }
        XCTAssertEqual(tl, PlacementSpec(string: "top-left"))
        guard case .place(let cell, _)? = parse("3x2:1,1") else { return XCTFail() }
        XCTAssertEqual(cell, PlacementSpec(string: "3x2:1,1"))
    }

    func testFailures() {
        XCTAssertNil(parse("grid 0x2"))
        XCTAssertNil(parse("pick"))
        XCTAssertNil(parse("frobnicate"))
    }

    func testCompletion() {
        XCTAssertTrue(HyperspaceCommandLine.completions(for: "gr", arguments: []).contains("grid"))
        XCTAssertEqual(HyperspaceCommandLine.completions(for: "layer wo", arguments: ["Work", "Writing"]), ["layer Work"])
    }

    func testMatchesKeepTheBestTierInOrder() {
        let c: [HyperspaceCommandLine.Candidate] = [
            .init(wid: 1, app: "Ghostty", title: "zsh", extra: ["/Users/a/dev/vox"]),
            .init(wid: 2, app: "Google Chrome", title: "vox — GitHub"),
            .init(wid: 3, app: "Google Chrome", title: "Docs"),
        ]
        XCTAssertEqual(HyperspaceCommandLine.matches("chrome", in: c).map(\.wid), [2, 3])
        XCTAssertEqual(HyperspaceCommandLine.matches("vox", in: c).map(\.wid), [2])
        XCTAssertEqual(HyperspaceCommandLine.matches("dev vox", in: c).map(\.wid), [1])
        XCTAssertEqual(HyperspaceCommandLine.matches("nothing", in: c), [])
        XCTAssertEqual(HyperspaceCommandLine.ranked("vox", in: c).map(\.wid), [2, 1])
        XCTAssertEqual(HyperspaceCommandLine.ranked("", in: c).map(\.wid), [1, 2, 3])
    }

    func testSpatialAim() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100),
                      CGRect(x: 200, y: 0, width: 100, height: 100),
                      CGRect(x: 0, y: 200, width: 100, height: 100)]
        XCTAssertEqual(HyperspaceSpatialAim.next(from: frames[0], direction: .right, among: frames), 1)
        XCTAssertEqual(HyperspaceSpatialAim.next(from: frames[0], direction: .up, among: frames), 2)
        XCTAssertNil(HyperspaceSpatialAim.next(from: frames[0], direction: .left, among: frames))
    }
}
