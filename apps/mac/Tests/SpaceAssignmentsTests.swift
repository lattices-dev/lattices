import XCTest
@testable import Lattices

final class SpaceAssignmentsTests: XCTestCase {
    private let uuids = ["": 1, "AAA": 5, "EDA": 6, "U32": 46]

    func testParsesDesktopAllAndMissingBindings() {
        let parsed = SpaceAssignments.parse([
            "com.google.chrome": "EDA",
            "com.apple.finder": "",
            "com.openai.chat": "AllSpaces",
            "to.talkie.app.mac.dev": "GONE",
        ], spaceIdsByUUID: uuids)
        XCTAssertEqual(SpaceAssignments.binding(forBundleId: "com.google.Chrome", in: parsed), .desktop(spaceId: 6))
        XCTAssertEqual(SpaceAssignments.binding(forBundleId: "com.apple.finder", in: parsed), .desktop(spaceId: 1))
        XCTAssertEqual(SpaceAssignments.binding(forBundleId: "com.openai.chat", in: parsed), .allDesktops)
        XCTAssertEqual(SpaceAssignments.binding(forBundleId: "to.talkie.app.mac.dev", in: parsed), .missing(uuid: "GONE"))
        XCTAssertNil(SpaceAssignments.binding(forBundleId: "com.apple.calculator", in: parsed))
    }

    func testInvalidPreferenceValuesAreIgnored() {
        let parsed = SpaceAssignments.parse(["invalid": 123, "all": "AllSpaces", "missing": "GONE"], spaceIdsByUUID: [:])
        XCTAssertEqual(parsed.map(\.bundleId), ["all", "missing"])
        XCTAssertNil(SpaceAssignments.binding(forBundleId: nil, in: parsed))
    }
}
