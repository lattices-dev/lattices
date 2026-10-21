import XCTest
@testable import Lattices

final class CompanionDeckTransportTests: XCTestCase {
    func testNativeBridgeAcceptsOnlyTheBundledDocument() throws {
        XCTAssertTrue(CompanionDeckTransport.isDocument(CompanionDeckTransport.indexURL))
        for value in ["https://bundle/deck-builder", "lattices-deck://other/deck-builder", "lattices-deck://user@bundle/deck-builder", "lattices-deck://bundle:80/deck-builder", "lattices-deck://bundle/_next/static/script.js"] {
            XCTAssertFalse(CompanionDeckTransport.isDocument(try XCTUnwrap(URL(string: value))))
        }
    }

    func testResourceResolutionConfinesSymlinksAndPathsToBundle() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_next/static"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data("editor".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("script".utf8).write(to: root.appendingPathComponent("_next/static/app.js"))
        try Data("outside".utf8).write(to: temp.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("_next/static/escape.js"), withDestinationURL: temp.appendingPathComponent("secret"))
        let handler = CompanionDeckBundleHandler(roots: [root])
        XCTAssertEqual(try handler.file(for: CompanionDeckTransport.indexURL).lastPathComponent, "index.html")
        XCTAssertEqual(try handler.file(for: XCTUnwrap(URL(string: "lattices-deck://bundle/_next/static/app.js"))).lastPathComponent, "app.js")
        for value in ["lattices-deck://bundle/_next/static/escape.js", "lattices-deck://bundle/_next/static/../../../secret", "lattices-deck://bundle/secret", "file:///etc/passwd"] {
            XCTAssertThrowsError(try handler.file(for: XCTUnwrap(URL(string: value))))
        }
    }
}
