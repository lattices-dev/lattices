import XCTest
@testable import Lattices

@MainActor
final class VoiceLaunchResolutionTests: XCTestCase {
    func testExplicitLaunchDoesNotDependOnTheAppNameEmbedding() {
        for (text, target) in [
            ("Open Codex, please.", "codex"),
            ("Can you open Codex, please?", "codex"),
            ("Launch the Zed app", "zed"),
            ("Open my quux workspace", "quux workspace"),
        ] {
            let match = VoiceIntentResolver.shared.match(text: text)
            XCTAssertEqual(match?.intentName, "launch", text)
            XCTAssertEqual(match?.slots["project"]?.stringValue, target, text)
        }
    }

    func testLaunchPreservesTheRecognizedTargetForValidation() {
        let match = VoiceIntentResolver.shared.match(text: "Open codecs, please.")
        XCTAssertEqual(match?.intentName, "launch")
        XCTAssertEqual(match?.slots["project"]?.stringValue, "codecs",
                       "Intent parsing must not silently rewrite an app name")
    }

    func testExplicitLaunchRequiresATarget() {
        for text in ["Open", "Launch"] {
            let match = VoiceIntentResolver.shared.match(text: text)
            XCTAssertFalse(match?.intentName == "launch" && match?.slots["project"] != nil, text)
        }
    }

    func testDeclaredCommandsKeepTheirIntent() {
        for (text, intent) in [
            ("find all terminal windows", "search"),
            ("show me all windows", "list_windows"),
            ("where's my mouse", "find_mouse"),
        ] {
            XCTAssertEqual(VoiceIntentResolver.shared.match(text: text)?.intentName, intent, text)
        }
    }
}
