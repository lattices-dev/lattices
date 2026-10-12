@testable import ActionCore
import Foundation
import XCTest

final class ActionBuildProvenanceTests: XCTestCase {
    func testUnbundledBuildDoesNotInventIdentity() {
        let value = ActionBuildProvenance.load(resourceURL: nil)
        XCTAssertNil(value.build)
        XCTAssertTrue(value.features.privateLayer)
        XCTAssertTrue(value.routing.rawWebSocket.contains("not the complete"))
    }

    func testReadsOnlyProvidedBundleResource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ActionBuildProvenance(
            schemaVersion: 1,
            build: .init(version: "0.3.0", commit: "test-commit", sourceDigest: "test-digest", sourceScope: "native", builtAt: "2026-10-11", dirty: true, configuration: "debug", bundleBuild: "202610114", orchestrationSourceDigest: "orchestration-digest"),
            features: .init(privateLayer: true, isolationContext: true, persistentAgentDisplay: true), routing: ActionBuildProvenance.routingContract)
        try Data(fixture.json.utf8).write(to: directory.appendingPathComponent("build-provenance.json"))
        let value = ActionBuildProvenance.load(resourceURL: directory)
        XCTAssertEqual(value.build?.commit, "test-commit")
        XCTAssertEqual(value.build?.sourceDigest, "test-digest")
        XCTAssertEqual(value.build?.dirty, true)
        XCTAssertEqual(value.build?.bundleBuild, "202610114")
        XCTAssertEqual(value.build?.orchestrationSourceDigest, "orchestration-digest")
        XCTAssertEqual(value.features.isolationContext, true)
        XCTAssertEqual(value.features.persistentAgentDisplay, true)
    }

    func testMalformedManifestDoesNotInventIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("build-provenance.json"))
        XCTAssertNil(ActionBuildProvenance.load(resourceURL: directory).build)
    }
}
