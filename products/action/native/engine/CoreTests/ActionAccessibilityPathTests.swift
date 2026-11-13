@testable import ActionCore
import Foundation
import XCTest

final class ActionAccessibilityPathTests: XCTestCase {
    func testRootAndChildPathsAreCanonicalized() throws {
        let root = try ActionAccessibilityPathTarget(path: "root")
        XCTAssertEqual(root.path, "root")
        XCTAssertEqual(root.indices, [])
        XCTAssertEqual(root.root, .window)

        let child = try ActionAccessibilityPathTarget(path: "00.003.2", root: "application")
        XCTAssertEqual(child.path, "0.3.2")
        XCTAssertEqual(child.indices, [0, 3, 2])
        XCTAssertEqual(child.root, .application)
        XCTAssertEqual(try ActionAccessibilityPathTarget(path: child.path).indices, child.indices)
    }

    func testMalformedPathsAndUnknownRootsFailClosed() {
        for path in ["", "ROOT", "root.0", ".0", "0.", "0..1", "-1", "+1", "1.5x", " 0", "0 ", "１", "١", String(repeating: "9", count: 100)] {
            assertPathMismatch {
                _ = try ActionAccessibilityPathTarget(path: path)
            }
        }
        assertPathMismatch {
            _ = try ActionAccessibilityPathTarget(path: "root", root: "desktop")
        }
    }

    func testNoExpectationsAcceptAnUnlabelledElementWithoutFrame() throws {
        try ActionAccessibilityPathTarget(path: "0").validate(
            role: "", labelCandidates: [], frame: nil
        )
    }

    func testRoleNormalizationUsesExistingAliases() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectRole: " input ")
        try target.validate(role: "AXTextField", labelCandidates: [], frame: nil)
        assertPathMismatch {
            try target.validate(role: "AXTextArea", labelCandidates: [], frame: nil)
        }
        assertPathMismatch {
            try target.validate(role: "", labelCandidates: [], frame: nil)
        }
    }

    func testEachLabelCandidateCanSatisfyNormalizedExactExpectation() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectLabel: " save changes ")
        // Title, description, value, identifier and help all participate in label matching.
        for candidateIndex in 0..<5 {
            var candidates = Array(repeating: "unrelated", count: 5)
            candidates[candidateIndex] = "  Save\n\tChanges  "
            try target.validate(role: "AXButton", labelCandidates: candidates, frame: nil)
        }
    }

    func testLabelExpectationNeverUsesPrefixOrSubstringMatching() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectLabel: "Save")
        for candidates in [["Save changes"], ["Autosave"], ["Sa"], [String]()] {
            assertPathMismatch {
                try target.validate(role: "AXButton", labelCandidates: candidates, frame: nil)
            }
        }
    }

    func testFrameToleranceIncludesExactlyTwoPointsPerComponent() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectFrame: "10,20,30,40")
        try target.validate(
            role: "AXButton", labelCandidates: [],
            frame: ActionAccessibilityBounds(x: 8, y: 22, width: 28, height: 42)
        )
        try target.validate(
            role: "AXButton", labelCandidates: [],
            frame: ActionAccessibilityBounds(x: 12, y: 18, width: 32, height: 38)
        )
    }

    func testEachFrameComponentMustBeWithinTolerance() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectFrame: "10,20,30,40")
        let mismatches = [
            ActionAccessibilityBounds(x: 12.01, y: 20, width: 30, height: 40),
            ActionAccessibilityBounds(x: 10, y: 17.99, width: 30, height: 40),
            ActionAccessibilityBounds(x: 10, y: 20, width: 32.01, height: 40),
            ActionAccessibilityBounds(x: 10, y: 20, width: 30, height: 37.99),
        ]
        for frame in mismatches {
            assertPathMismatch {
                try target.validate(role: "AXButton", labelCandidates: [], frame: frame)
            }
        }
        assertPathMismatch {
            try target.validate(role: "AXButton", labelCandidates: [], frame: nil)
        }
    }

    func testInvalidExpectedFramesFailBeforeResolution() {
        for frame in ["", "1,2,3", "1,2,3,4,5", "1,,3,4", "x,2,3,4", "nan,2,3,4", "1,inf,3,4", "1,2,-3,4", "1,2,3,-4"] {
            assertPathMismatch {
                _ = try ActionAccessibilityPathTarget(path: "0", expectFrame: frame)
            }
        }
    }

    func testNegativeScreenCoordinatesAndZeroSizedExpectedFramesAreValid() throws {
        let target = try ActionAccessibilityPathTarget(path: "root", expectFrame: " -100, -200, 0, 0 ")
        try target.validate(
            role: "AXWindow", labelCandidates: [],
            frame: ActionAccessibilityBounds(x: -100, y: -200, width: 0, height: 0)
        )
    }

    func testNonfiniteObservedFramesFailAnExpectation() throws {
        let target = try ActionAccessibilityPathTarget(path: "0", expectFrame: "10,20,30,40")
        for frame in [
            ActionAccessibilityBounds(x: .nan, y: 20, width: 30, height: 40),
            ActionAccessibilityBounds(x: 10, y: .infinity, width: 30, height: 40),
            ActionAccessibilityBounds(x: 10, y: 20, width: -.infinity, height: 40),
            ActionAccessibilityBounds(x: 10, y: 20, width: 30, height: .nan),
        ] {
            assertPathMismatch {
                try target.validate(role: "AXButton", labelCandidates: [], frame: frame)
            }
        }
    }

    func testEverySuppliedExpectationMustMatch() throws {
        let target = try ActionAccessibilityPathTarget(
            path: "0.3", expectRole: "button", expectLabel: "Save", expectFrame: "10,20,30,40"
        )
        let frame = ActionAccessibilityBounds(x: 10, y: 20, width: 30, height: 40)
        try target.validate(role: "AXButton", labelCandidates: ["Save"], frame: frame)
        assertPathMismatch {
            try target.validate(role: "AXButton", labelCandidates: ["Cancel"], frame: frame)
        }
        assertPathMismatch {
            try target.validate(role: "AXStaticText", labelCandidates: ["Save"], frame: frame)
        }
    }

    func testLegacySnapshotDecodesWithoutPathOrRootMetadata() throws {
        let data = Data(#"{"role":"AXButton","title":"Save","depth":1,"actions":["AXPress"],"settableAttributes":[]}"#.utf8)
        let node = try JSONDecoder().decode(ActionAccessibilityNodeSnapshot.self, from: data)
        XCTAssertEqual(node.role, "AXButton")
        XCTAssertEqual(node.title, "Save")
        XCTAssertNil(node.path)
        XCTAssertNil(node.root)
        XCTAssertNil(node.rootWindow)
        XCTAssertNil(node.truncated)
    }

    func testSnapshotPathRoundTripsWithoutChangingArrayShape() throws {
        let node = ActionAccessibilityNodeSnapshot(
            role: "AXButton", title: "Save", detail: nil, value: nil, identifier: nil,
            depth: 3, path: "0.3.2"
        )
        let data = try JSONEncoder().encode([node])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["path"] as? String, "0.3.2")
        XCTAssertEqual(json[0]["depth"] as? Int, 3)
        XCTAssertEqual(try JSONDecoder().decode([ActionAccessibilityNodeSnapshot].self, from: data)[0].path, "0.3.2")
    }

    func testRootMetadataIsAdditiveAndDescribesWindow() throws {
        var node = ActionAccessibilityNodeSnapshot(
            role: "AXWindow", title: "Document", detail: nil, value: nil, identifier: nil,
            depth: 0, path: "root"
        )
        node.root = .window
        node.rootWindow = ActionAccessibilityWindowSnapshot(
            title: "Document", frame: ActionAccessibilityBounds(x: 10, y: 20, width: 800, height: 600)
        )
        node.truncated = true
        let data = try JSONEncoder().encode([node])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json[0]["root"] as? String, "window")
        XCTAssertEqual(json[0]["truncated"] as? Bool, true)
        let window = try XCTUnwrap(json[0]["rootWindow"] as? [String: Any])
        XCTAssertEqual(window["title"] as? String, "Document")
        XCTAssertEqual((window["frame"] as? [String: Double])?["width"], 800)
        let decoded = try JSONDecoder().decode([ActionAccessibilityNodeSnapshot].self, from: data)
        XCTAssertEqual(decoded[0].rootWindow?.title, "Document")
    }

    func testCapabilitiesAppendPathCommandsAndRemainProvenanceDecodable() throws {
        let data = try JSONEncoder().encode(ActionNativeHostCapabilities())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["accessibilityPathCommands"] as? [String], [
            "press-accessibility-path", "set-accessibility-value-path", "perform-accessibility-action-path",
        ])
        XCTAssertEqual(json["windowScopedAccessibility"] as? Bool, true)
        let provenance = try JSONDecoder().decode(ActionBuildProvenance.self, from: data)
        XCTAssertEqual(provenance.schemaVersion, ActionBuildProvenance.current.schemaVersion)
        XCTAssertEqual(provenance.routing.nativeHost, ActionBuildProvenance.current.routing.nativeHost)
    }

    func testWindowSelectionPreservesProcessAndCGIdentity() throws {
        let selection = try ActionNativeWindowTarget(bundleId: "com.google.Chrome", pid: "1234", windowNumber: "4294967295")
        XCTAssertEqual(selection.bundleId, "com.google.Chrome")
        XCTAssertEqual(selection.pid, 1234)
        XCTAssertEqual(selection.windowNumber, UInt32.max)
        let processOnly = try ActionNativeWindowTarget(pid: "1234")
        XCTAssertNil(processOnly.bundleId)
        XCTAssertNil(processOnly.windowNumber)
    }

    func testWindowSelectionRejectsInvalidNumericIDsInsteadOfFallingBack() {
        for pid in ["", "0", "-1", "2147483648", "abc", "1.5"] {
            XCTAssertThrowsError(try ActionNativeWindowTarget(bundleId: "com.google.Chrome", pid: pid))
        }
        for window in ["", "0", "-1", "4294967296", "abc", "1.5"] {
            XCTAssertThrowsError(try ActionNativeWindowTarget(bundleId: "com.google.Chrome", windowNumber: window))
        }
    }

    func testGoneProcessRefusesEveryPathOperationBeforeActing() throws {
        let selection = try ActionNativeWindowTarget(pid: String(Int32.max), windowNumber: "42")
        XCTAssertThrowsError(try selection.application()) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("window-not-found:"), error.localizedDescription)
        }
        let target = try ActionAccessibilityPathTarget(path: "root")
        for operation in [ActionAccessibilityPathOperation.press, .setValue("must not write"), .performAction("AXRaise")] {
            assertPathMismatch {
                _ = try ActionNativeAutomation.actOnAccessibilityPath(selection: selection, target: target, operation: operation)
            }
        }
    }

    func testPidAndBundleIdentityMustAgree() throws {
        let selection = try ActionNativeWindowTarget(bundleId: "com.google.Chrome", pid: "1234", windowNumber: "42")
        XCTAssertNoThrow(try selection.validateBundleIdentifier("com.google.Chrome", pid: 1234))
        XCTAssertThrowsError(try selection.validateBundleIdentifier("com.apple.Safari", pid: 1234))
        XCTAssertThrowsError(try selection.validateBundleIdentifier(nil, pid: 1234))
        let pidOnly = try ActionNativeWindowTarget(pid: "1234", windowNumber: "42")
        XCTAssertNoThrow(try pidOnly.validateBundleIdentifier(nil, pid: 1234))
    }

    private func assertPathMismatch(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("path-mismatch:"), error.localizedDescription, file: file, line: line)
        }
    }
}
