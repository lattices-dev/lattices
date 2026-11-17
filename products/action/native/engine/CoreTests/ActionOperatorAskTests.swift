import Foundation
import XCTest
@testable import ActionCore

final class ActionOperatorAskTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ changes: [String: Any] = [:]) throws -> ActionOperatorAskRequest {
        var json: [String: Any] = [
            "schema": 1,
            "id": "ask_20261105_abcd",
            "key": "tcc:com.trycua.driver:accessibility+screen-recording",
            "requester": ["agent": "Claude Code", "task": "Live-test trycua-cua"],
            "title": "Let CuaDriver control this Mac",
            "why": "macOS needs your approval for two permissions.",
            "items": [
                ["id": "accessibility", "label": "Accessibility", "state": "missing"],
                ["id": "screen-recording", "label": "Screen Recording", "state": "unknown"],
            ],
            "steps": [
                ["id": "open-ax", "label": "Open Accessibility", "action": ["kind": "open-settings", "pane": "accessibility"]],
                ["id": "reveal", "label": "Show CuaDriver", "action": ["kind": "reveal", "path": "/Applications/CuaDriver.app"]],
                ["id": "retry", "label": "Ask macOS again", "action": ["kind": "agent"]],
            ],
        ]
        json.merge(changes) { _, new in new }
        return try ActionOperatorAskRequest.parse(JSONSerialization.data(withJSONObject: json))
    }

    private func step(_ action: [String: Any]) -> [[String: Any]] {
        [["id": "step", "label": "Continue", "action": action]]
    }

    private func control(_ json: String) -> Data { Data(json.utf8) }

    func testValidRequestAndCodableRoundTrip() throws {
        let value = try request(["expiresAt": "2026-11-05T22:10:00Z"])
        XCTAssertEqual(value.schema, 1)
        XCTAssertEqual(value.requester.agent, "Claude Code")
        XCTAssertEqual(value.resolution, .verify)
        XCTAssertEqual(value.items.map(\.state), [.missing, .unknown])
        XCTAssertEqual(value.steps[0].action, .openSettings(pane: .accessibility))
        XCTAssertEqual(value.steps[1].action, .reveal(path: "/Applications/CuaDriver.app"))
        XCTAssertEqual(value.steps[2].action, .agent)
        XCTAssertNotNil(value.expiresAt)
        XCTAssertEqual(try ActionOperatorAskRequest.parse(JSONEncoder().encode(value)), value)
    }

    func testSubjectAndItemStepLinks() throws {
        let value = try request([
            "subject": ["name": "CuaDriver", "path": "/Applications/CuaDriver.app"],
            "items": [["id": "accessibility", "label": "Accessibility", "state": "missing", "step": "open-ax"]],
        ])
        XCTAssertEqual(value.subject, ActionOperatorAskSubject(name: "CuaDriver", path: "/Applications/CuaDriver.app"))
        XCTAssertEqual(value.items.first?.step, "open-ax")
        XCTAssertEqual(try ActionOperatorAskRequest.parse(JSONEncoder().encode(value)), value)
        XCTAssertNil(try request().subject)
        XCTAssertThrowsError(try request(["subject": ["name": "CuaDriver", "path": "CuaDriver.app"]]))
        XCTAssertThrowsError(try request(["items": [["id": "a", "label": "A", "state": "missing", "step": "nope"]]]))
    }

    func testOptionalChecklistAndDefaultResolution() throws {
        let value = try request(["items": NSNull(), "steps": []])
        XCTAssertEqual(value.items, [])
        XCTAssertEqual(value.steps, [])
        XCTAssertEqual(value.resolution, .verify)
        XCTAssertNil(value.expiresAt)
    }

    func testAcceptsOpenAppByBundleOrPathAndHTTPSURL() throws {
        XCTAssertEqual(try request(["steps": step(["kind": "open-app", "bundleId": "com.apple.finder"])]).steps[0].action,
                       .openApp(bundleId: "com.apple.finder", path: nil))
        XCTAssertEqual(try request(["steps": step(["kind": "open-app", "path": "/Applications/CuaDriver.app"])]).steps[0].action,
                       .openApp(bundleId: nil, path: "/Applications/CuaDriver.app"))
        XCTAssertEqual(try request(["steps": step(["kind": "open-url", "url": "https://example.com/help"])]).steps[0].action,
                       .openURL(url: URL(string: "https://example.com/help")!))
    }

    func testRejectsUnknownKindAndBadPane() {
        XCTAssertThrowsError(try request(["steps": step(["kind": "shell", "command": "echo hello"])]))
        XCTAssertThrowsError(try request(["steps": step(["kind": "open-settings", "pane": "bluetooth"])]))
    }

    func testRejectsRelativePathsAndMissingAppDestination() {
        for kind in ["reveal", "open-app"] {
            for path in ["Applications/CuaDriver.app", "~/Applications/CuaDriver.app", ""] {
                XCTAssertThrowsError(try request(["steps": step(["kind": kind, "path": path])]), "\(kind): \(path)")
            }
        }
        XCTAssertThrowsError(try request(["steps": step(["kind": "open-app"])]))
        XCTAssertThrowsError(try request(["steps": step(["kind": "open-app", "bundleId": " "])]))
        XCTAssertThrowsError(try request(["steps": step(["kind": "reveal"])]))
    }

    func testRejectsNonHTTPSAndMalformedURLs() {
        for url in ["http://example.com", "file:///tmp/help", "javascript:alert(1)", "https:", "https:relative", "https://example.com/a b"] {
            XCTAssertThrowsError(try request(["steps": step(["kind": "open-url", "url": url])]), url)
        }
    }

    func testRejectsTooManyStepsAndEmptyTitle() throws {
        let steps = (0..<5).map { ["id": "step-\($0)", "label": "Continue", "action": ["kind": "agent"]] as [String: Any] }
        XCTAssertThrowsError(try request(["steps": steps]))
        XCTAssertEqual(try request(["steps": Array(steps.prefix(4))]).steps.count, 4)
        for title in ["", " \n\t"] { XCTAssertThrowsError(try request(["title": title])) }
    }

    func testRejectsUnsupportedSchemaInvalidStatesAndDuplicateIDs() {
        XCTAssertThrowsError(try request(["schema": 2]))
        XCTAssertThrowsError(try request(["resolution": "automatic"]))
        XCTAssertThrowsError(try request(["expiresAt": "tomorrow"]))
        XCTAssertThrowsError(try request(["items": [["id": "ax", "label": "Accessibility", "state": "ready"]]]))
        XCTAssertThrowsError(try request(["steps": step(["kind": "agent"]) + step(["kind": "agent"])]))
        let item = ["id": "ax", "label": "Accessibility", "state": "missing"]
        XCTAssertThrowsError(try request(["items": [item, item]]))
    }

    func testSettingsPaneURLs() {
        let expected: [ActionOperatorAskSettingsPane: String] = [
            .accessibility: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            .screenRecording: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            .automation: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            .inputMonitoring: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            .fullDiskAccess: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        XCTAssertEqual(expected.count, ActionOperatorAskSettingsPane.allCases.count)
        for (pane, url) in expected { XCTAssertEqual(pane.url.absoluteString, url) }
    }

    func testWaitingMergesByIDAndIgnoresUnknownIDs() throws {
        var state = ActionOperatorAskState(request: try request())
        state.applyControl(data: control(#"{"status":"waiting","detail":"Waiting for Screen Recording…","items":[{"id":"accessibility","state":"granted"},{"id":"unrelated","state":"granted"}]}"#), now: start)
        XCTAssertEqual(state.items.map(\.state), [.granted, .unknown])
        XCTAssertEqual(state.detail, "Waiting for Screen Recording…")
        XCTAssertEqual(state.lastControl?.status, .waiting)
        XCTAssertNil(state.outcome)
    }

    func testMissingPartialAndGarbageControlKeepLastGoodState() throws {
        var state = ActionOperatorAskState(request: try request())
        state.applyControl(data: control(#"{"status":"waiting","detail":"Still waiting","items":[{"id":"accessibility","state":"granted"}]}"#), now: start)
        let good = state
        let invalid: [Data?] = [nil, Data(), control("garbage"), control(#"{"status":"satisfied""#),
            control(#"{"status":"unknown"}"#), control(#"{"status":"waiting","items":[{"id":"accessibility","state":"bad"}]}"#)]
        for data in invalid {
            state.applyControl(data: data, now: start)
            XCTAssertEqual(state, good)
        }
    }

    func testVerifyHasNoDoneAndGrantedChecklistDoesNotSatisfy() throws {
        var state = ActionOperatorAskState(request: try request())
        XCTAssertFalse(state.allowsDone)
        state.confirm()
        XCTAssertNil(state.outcome)
        state.applyControl(data: control(#"{"status":"waiting","items":[{"id":"accessibility","state":"granted"},{"id":"screen-recording","state":"granted"}]}"#), now: start)
        state.finishSatisfaction(now: start.addingTimeInterval(20))
        XCTAssertEqual(state.items.map(\.state), [.granted, .granted])
        XCTAssertFalse(state.isShowingSuccess)
        XCTAssertNil(state.outcome)
    }

    func testVerifyOffersDoneOnlyOnceEveryRowIsGrantedAndClosesAsDeclined() throws {
        var state = ActionOperatorAskState(request: try request())
        XCTAssertFalse(state.allGranted)
        XCTAssertFalse(state.offersDone)
        state.done()
        XCTAssertNil(state.outcome)
        state.applyControl(data: control(#"{"status":"waiting","items":[{"id":"accessibility","state":"granted"}]}"#), now: start)
        XCTAssertFalse(state.offersDone)
        state.applyControl(data: control(#"{"status":"waiting","items":[{"id":"screen-recording","state":"granted"}]}"#), now: start)
        XCTAssertTrue(state.allGranted)
        XCTAssertTrue(state.offersDone)
        XCTAssertNil(state.outcome)
        state.done()
        // Declined is the wire's safe close; the caller re-checks and upgrades.
        XCTAssertEqual(state.outcome, .declined)
        XCTAssertEqual(state.detail, "Done with every row granted")
        XCTAssertFalse(state.offersDone)
    }

    func testDoneIsNotOfferedWithoutRowsOrDuringSuccess() throws {
        var empty = ActionOperatorAskState(request: try request(["items": NSNull()]))
        XCTAssertFalse(empty.allGranted)
        XCTAssertFalse(empty.offersDone)
        empty.done()
        XCTAssertNil(empty.outcome)

        var success = ActionOperatorAskState(request: try request())
        success.applyControl(data: control(#"{"status":"satisfied"}"#), now: start)
        XCTAssertTrue(success.allGranted)
        XCTAssertFalse(success.offersDone)
        success.done()
        XCTAssertNil(success.outcome)
        success.finishSatisfaction(now: start.addingTimeInterval(1.3))
        XCTAssertEqual(success.outcome, .satisfied)
    }

    func testUserDoneUsesTheSameControlAndConfirms() throws {
        var state = ActionOperatorAskState(request: try request(["resolution": "user"]))
        XCTAssertTrue(state.offersDone)
        state.done()
        XCTAssertEqual(state.outcome, .confirmed)
    }

    func testUserDoneConfirmsWithoutClaimingSatisfaction() throws {
        var state = ActionOperatorAskState(request: try request(["resolution": "user"]))
        XCTAssertTrue(state.allowsDone)
        state.confirm()
        XCTAssertEqual(state.outcome, .confirmed)
        state.applyControl(data: control(#"{"status":"satisfied"}"#), now: start)
        state.finishSatisfaction(now: start.addingTimeInterval(10))
        XCTAssertEqual(state.outcome, .confirmed)
    }

    func testSatisfiedControlShowsAllSetBeforeResolvingAndDoesNotRestartTimer() throws {
        var state = ActionOperatorAskState(request: try request())
        let satisfied = control(#"{"status":"satisfied","detail":"Verified"}"#)
        state.applyControl(data: satisfied, now: start)
        XCTAssertEqual(state.items.map(\.state), [.granted, .granted])
        XCTAssertEqual(state.detail, "All set")
        XCTAssertTrue(state.isShowingSuccess)
        XCTAssertNil(state.outcome)
        state.applyControl(data: satisfied, now: start.addingTimeInterval(1))
        state.applyControl(data: control(#"{"status":"waiting","items":[{"id":"accessibility","state":"missing"}]}"#), now: start.addingTimeInterval(1))
        XCTAssertEqual(state.satisfactionStartedAt, start)
        XCTAssertEqual(state.items.map(\.state), [.granted, .granted])
        state.finishSatisfaction(now: start.addingTimeInterval(1.1))
        XCTAssertNil(state.outcome)
        state.finishSatisfaction(now: start.addingTimeInterval(1.3))
        XCTAssertEqual(state.outcome, .satisfied)
    }

    func testDeclineAndCancellationAreTerminal() throws {
        var declined = ActionOperatorAskState(request: try request())
        declined.decline()
        declined.applyControl(data: control(#"{"status":"satisfied"}"#), now: start)
        declined.finishSatisfaction(now: start.addingTimeInterval(10))
        XCTAssertEqual(declined.outcome, .declined)

        var cancelled = ActionOperatorAskState(request: try request())
        cancelled.applyControl(data: control(#"{"status":"satisfied"}"#), now: start)
        cancelled.applyControl(data: control(#"{"status":"cancelled","detail":"Agent withdrew request"}"#), now: start)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.detail, "Agent withdrew request")
        cancelled.decline()
        XCTAssertEqual(cancelled.outcome, .cancelled)
    }

    func testExpiryClosesWaitingOrSuccessAtDeadline() throws {
        let deadline = "2026-11-05T22:10:00.250Z"
        let value = try request(["expiresAt": deadline])
        let date = try XCTUnwrap(value.expiresAt)
        for showingSuccess in [false, true] {
            var state = ActionOperatorAskState(request: value)
            if showingSuccess { state.applyControl(data: control(#"{"status":"satisfied"}"#), now: date.addingTimeInterval(-0.5)) }
            state.expireIfNeeded(now: date.addingTimeInterval(-0.01))
            XCTAssertNil(state.outcome)
            state.expireIfNeeded(now: date)
            XCTAssertEqual(state.outcome, .expired)
            state.finishSatisfaction(now: date.addingTimeInterval(10))
            XCTAssertEqual(state.outcome, .expired)
        }
    }

    func testReplyEncodingMatchesWireContract() throws {
        let reply = ActionOperatorAskReply.answered(outcome: .declined, detail: "Not now")
        let encoded = try JSONEncoder().encode(reply)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(json, ["status": "answered", "outcome": "declined", "detail": "Not now"])
        XCTAssertEqual(try JSONDecoder().decode(ActionOperatorAskReply.self, from: encoded), reply)
        let error = try JSONEncoder().encode(ActionOperatorAskReply.error(detail: "Invalid request"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: error) as? [String: String], ["status": "error", "detail": "Invalid request"])
    }
}
