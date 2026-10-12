import XCTest
@testable import Lattices

final class EditorBridgeTests: XCTestCase {
    private func subject(_ projects: String = "{\"app\":\"Safari\"}", label: String = "Web") throws -> EditorSubject {
        try EditorSubject(data: Data("{\"name\":\"Test\",\"layers\":[{\"id\":\"web\",\"label\":\"\(label)\",\"projects\":[\(projects)]}]}".utf8))
    }
    private func window(_ wid: UInt32, app: String = "Safari", title: String = "Page") -> WindowEntry {
        WindowEntry(wid: wid, app: app, pid: 1, title: title, frame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
                    spaceIds: [1], isOnScreen: true, latticesSession: nil, zIndex: Int(wid))
    }
    private func snapshot(_ subject: EditorSubject, windows: [WindowEntry] = []) throws -> EditorBridge.Snapshot {
        .init(subject: subject, projection: try subject.project(windows: windows, sources: .init(isRunning: { _ in false })))
    }
    private func request(_ kind: String, revision: String? = nil) -> [String: Any] {
        ["v": 1, "requestId": "test", "subjectId": kind == "capabilities" ? NSNull() : EditorSubject.id as Any,
         "revision": revision as Any? ?? NSNull(), "kind": kind, "payload": [String: Any]()]
    }

    func testAdvisoryTitleCandidatesAreNotMembership() throws {
        let subject = try subject(#"{"app":"Xcode","title":"Talkie"}"#)
        let windows = [window(1, app: "Google Chrome", title: "Talkie docs"),
                       window(2, app: "Xcode", title: "Unrelated"),
                       window(3, app: "Xcode", title: "Talkie utility")]
        let candidates = EditorSubject.titleCandidates(for: subject.layers[0].projects[0],
            windows: windows + [windows[0]], isContent: { $0.wid != 3 })
        XCTAssertTrue(candidates.isEmpty)
        let projected = try subject.project(windows: windows, sources: .init(isContent: { $0.wid != 3 }))
        let group = (projected["groups"] as! [[String: Any]])[0]
        XCTAssertTrue((group["rows"] as! [[String: Any]]).isEmpty)
        let unmatched = try XCTUnwrap(group["unmatchedRules"] as? [[String: Any]])
        XCTAssertEqual(unmatched.count, 1)
        XCTAssertEqual(unmatched[0]["ruleIndex"] as? Int, 0)
        XCTAssertEqual(unmatched[0]["entryKey"] as? String, subject.entries[0]["key"] as? String)
        XCTAssertEqual((unmatched[0]["titleCandidates"] as? [[String: Any]])?.count, 0)
    }

    func testTitleSuggestionsOmitMatchedAndDuplicateEntries() throws {
        let entry = #"{"app":"Xcode","title":"Talkie"}"#
        for (entries, windows) in [(entry, [window(1, app: "Xcode", title: "Talkie")]),
                                   (entry + "," + entry, [window(1, title: "Talkie")])] {
            let subject = try subject(entries)
            let projection = try subject.project(windows: windows, sources: .init(isContent: { _ in true }))
            XCTAssertNil((projection["groups"] as! [[String: Any]])[0]["unmatchedRules"])
        }
    }

    func testUnmatchedRuleCanSuggestAWindowOwnedByAStrongerRule() throws {
        let subject = try subject(#"{"match":{"appEquals":"Xcode","titleEquals":"Talkie"}},{"app":"Xcode","title":"Talkie"}"#)
        let projection = try subject.project(windows: [window(1, app: "Xcode", title: "Talkie")],
                                             sources: .init(isContent: { _ in true }))
        let group = (projection["groups"] as! [[String: Any]])[0]
        let rows = group["rows"] as! [[String: Any]]
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["matchedRule"] as? Int, 0)
        let rules = try XCTUnwrap(group["unmatchedRules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["ruleIndex"] as? Int, 1)
        let candidates = rules[0]["titleCandidates"] as! [[String: Any]]
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0]["windowId"] as? UInt32, 1)
    }

    func testAdvisoryTitleCandidatesRequireValidTitlePredicate() throws {
        for entry in [#"{"app":"Safari"}"#, #"{"match":{"titleRegex":"["}}"#,
                      #"{"title":"  "}"#] {
            let subject = try subject(entry)
            XCTAssertTrue(EditorSubject.titleCandidates(for: subject.layers[0].projects[0],
                windows: [window(1)], isContent: { _ in true }).isEmpty)
        }
        let subject = try subject(#"{"match":{"appEquals":"Safari","titleRegex":"^page$"}}"#)
        XCTAssertEqual(EditorSubject.titleCandidates(for: subject.layers[0].projects[0],
            windows: [window(1)], isContent: { _ in true }).map(\.wid), [1])
    }

    func testHostChromeUIStateDoesNotCaptureOrMutateSubject() throws {
        var captures = 0
        let bridge = EditorBridge(hostChrome: true) {
            captures += 1
            throw EditorBridgeError("unavailable", "No subject")
        }
        let capabilities = bridge.reply(to: request("capabilities"))["payload"] as! [String: Any]
        XCTAssertEqual(capabilities["chrome"] as? String, "host")
        XCTAssertTrue((capabilities["methods"] as! [String]).contains("ui.state"))
        let baseline = captures
        var received: EditorUIState?
        bridge.onUIState = { received = $0 }
        var call = request("ui.state")
        call["payload"] = ["arrangement": "columns", "panels": ["chat", "preview"], "sourceOpen": false]
        let reply = bridge.reply(to: call)
        XCTAssertEqual(reply["kind"] as? String, "ui.state.result")
        XCTAssertEqual((reply["payload"] as? [String: Any])?.count, 0)
        XCTAssertEqual(received?.view, "workspace")
        XCTAssertEqual(received?.arrangement, "columns")
        XCTAssertEqual(captures, baseline)
        for invalid: [String: Any] in [
            ["arrangement": "bad", "panels": ["chat"], "sourceOpen": false],
            ["arrangement": "grid", "panels": ["terminal"], "sourceOpen": false],
            ["arrangement": "grid", "panels": ["source"], "sourceOpen": false],
            ["arrangement": "grid", "panels": ["chat", "chat"], "sourceOpen": false]
        ] {
            call["payload"] = invalid
            XCTAssertEqual(bridge.reply(to: call)["kind"] as? String, "error")
        }
        XCTAssertEqual(received?.arrangement, "columns")
        XCTAssertEqual(captures, baseline)
    }

    func testHostUICommandsUseEnvelopeAndRejectUnknownCommands() {
        let bridge = EditorBridge(hostChrome: true) { throw EditorBridgeError("unavailable", "Unused") }
        var events: [[String: Any]] = []
        bridge.onEvent = { events.append($0) }
        bridge.sendUICommand("arrangement", value: "grid")
        bridge.sendUICommand("togglePanel", value: "history")
        bridge.sendUICommand("toggleSource")
        bridge.sendUICommand("view", value: "overview")
        bridge.sendUICommand("view", value: "workspace")
        bridge.sendUICommand("view", value: "invalid")
        bridge.sendUICommand("activate", value: "web")
        bridge.sendUICommand("arrangement", value: "invalid")
        bridge.sendUICommand("togglePanel", value: "terminal")
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy { $0["kind"] as? String == "ui.command" })
        XCTAssertTrue(events.allSatisfy { $0["subjectId"] as? String == EditorSubject.id })
        XCTAssertEqual((events[0]["payload"] as? [String: String])?["value"], "grid")
        let standalone = EditorBridge { throw EditorBridgeError("unavailable", "Unused") }
        standalone.onEvent = { _ in XCTFail("No host command without host chrome") }
        standalone.sendUICommand("toggleSource")
        XCTAssertEqual(standalone.reply(to: request("ui.state"))["kind"] as? String, "error")
        XCTAssertNil((standalone.reply(to: request("capabilities"))["payload"] as? [String: Any])?["chrome"])
    }

    func testLayersNavigationAndPageActionSelectionIdentity() {
        XCTAssertEqual(AppPage.navigationGroups.first?.pages, [.home, .overview, .layers, .machines])
        XCTAssertEqual(AppPage.named("layers"), .layers)
        let off = PageAction(id: "source", title: "Source", isOn: false) {}
        let on = PageAction(id: "source", title: "Source", isOn: true) {}
        XCTAssertNotEqual(off, on)
        let first = PageAction(id: "panels", title: "Panels", menu: [
            PageActionItem(id: "chat", title: "Chat", isOn: false) {}
        ])
        let second = PageAction(id: "panels", title: "Panels", menu: [
            PageActionItem(id: "chat", title: "Chat", isOn: true) {}
        ])
        XCTAssertNotEqual(first, second)
    }

    func testOverviewStateAndSegmentSelection() throws {
        for view in EditorUIState.views {
            let state = try EditorUIState(payload: ["view": view, "arrangement": "grid", "panels": ["preview"], "sourceOpen": false])
            XCTAssertEqual(state.view, view)
        }
        XCTAssertThrowsError(try EditorUIState(payload: ["view": "invalid", "arrangement": "grid", "panels": ["preview"], "sourceOpen": false]))
        let overview = PageAction(id: "view", title: "View", segments: [PageActionItem(id: "overview", title: "Overview", isOn: true) {}])
        let workspace = PageAction(id: "view", title: "View", segments: [PageActionItem(id: "overview", title: "Overview", isOn: false) {}])
        XCTAssertNotEqual(overview, workspace)
    }

    func testSharedLayerSelectionPersistsAndDeduplicates() {
        let suite = "LayerIndexTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = LayerIndexState(defaults: defaults)
        XCTAssertEqual(index.selected, [])
        index.choose("lattices")
        index.choose("fab", additive: true)
        XCTAssertEqual(index.selected, ["lattices", "fab"])
        index.select(["fab", "fab", "lattices"])
        XCTAssertEqual(LayerIndexState(defaults: defaults).selected, ["fab", "lattices"])
        index.choose(nil)
        XCTAssertEqual(index.selected, [])
    }

    func testSharedSelectionBridgeIsUIOnly() throws {
        let bridge = EditorBridge(hostChrome: true) { throw EditorBridgeError("unavailable", "unused") }
        bridge.selectedLayerIds = { ["fab"] }
        let capabilities = bridge.reply(to: request("capabilities"))["payload"] as! [String: Any]
        XCTAssertEqual(capabilities["selectedLayerIds"] as? [String], ["fab"])
        var event: [String: Any]?
        bridge.onEvent = { event = $0 }
        bridge.selectLayers(["fab", "lattices"])
        XCTAssertEqual((event?["payload"] as? [String: Any])?["value"] as? [String], ["fab", "lattices"])
        let state = try EditorUIState(payload: ["view": "overview", "arrangement": "grid", "panels": ["preview"], "sourceOpen": false, "selectedLayerIds": ["fab"]])
        XCTAssertEqual(state.selectedLayerIds, ["fab"])
        XCTAssertThrowsError(try EditorUIState(payload: ["view": "overview", "arrangement": "grid", "panels": ["preview"], "sourceOpen": false, "selectedLayerIds": ["fab", "fab"]]))
    }

    func testRevisionIgnoresObjectKeyOrderAndUnrelatedRootButPreservesUnknownEntryFields() throws {
        let a = try subject("{\"app\":\"Safari\",\"future\":{\"z\":2,\"a\":1}}")
        let b = try EditorSubject(data: Data("{\"other\":true,\"layers\":[{\"projects\":[{\"future\":{\"a\":1,\"z\":2},\"app\":\"Safari\"}],\"label\":\"Web\",\"id\":\"web\"}]}".utf8))
        XCTAssertEqual(a.revision, b.revision)
        XCTAssertEqual(a.source, b.source)
        XCTAssertTrue(a.source.contains("\"future\""))
        XCTAssertNotEqual(a.revision, try subject().revision)
        XCTAssertNotEqual(a.entries[0]["key"] as? String, try subject().entries[0]["key"] as? String)
    }

    func testUTF16RangesAndDuplicateEntriesAreExplicitlyAmbiguous() throws {
        let entry = "{\"app\":\"Safari\",\"title\":\"🧭 \\\"quoted\\\"\",\"nested\":{\"app\":\"Safari\"}}"
        let subject = try subject(entry + "," + entry, label: "🌍 Web")
        XCTAssertEqual(subject.entries.count, 1)
        let address = try XCTUnwrap(subject.entries.first)
        XCTAssertEqual(address["ambiguous"] as? Bool, true)
        let ranges = try XCTUnwrap(address["ranges"] as? [[String: Int]])
        XCTAssertEqual(ranges.count, 2)
        for range in ranges {
            let text = (subject.source as NSString).substring(with: NSRange(location: range["from"]!, length: range["to"]! - range["from"]!))
            let raw = try JSONSerialization.jsonObject(with: Data(text.utf8))
            XCTAssertEqual(try EditorSubject.canonical(raw), address["canonical"] as? String)
        }
    }

    func testEntryKeySurvivesReorderButDoesNotCrossLayers() throws {
        let a = try subject("{\"app\":\"Safari\"},{\"app\":\"Notes\"}")
        let b = try subject("{\"app\":\"Notes\"},{\"app\":\"Safari\"}")
        XCTAssertEqual(a.entries.map { $0["key"] as! String }, b.entries.map { $0["key"] as! String })
        XCTAssertNotEqual(a.revision, b.revision)
        let c = try EditorSubject(data: Data(a.source.replacingOccurrences(of: "\"web\"", with: "\"other\"").utf8))
        XCTAssertNotEqual(a.entries.map { $0["key"] as! String }, c.entries.map { $0["key"] as! String })
    }

    func testProjectionUsesNativeMembershipIncludingPinsAndUnassigned() throws {
        let subject = try subject("{\"app\":\"Safari\",\"pins\":[{\"wid\":2,\"app\":\"Notes\",\"title\":\"Note\"}]}")
        let windows = [window(1), window(2, app: "Notes", title: "Note"), window(3, app: "Finder")]
        let sources = LayerMembership.Sources(isRunning: { _ in false })
        let native = LayerMembership.resolve(subject.layers, windows: windows, sources: sources)
        let projection = try subject.project(windows: windows, sources: sources)
        let groups = try XCTUnwrap(projection["groups"] as? [[String: Any]])
        let rows = try XCTUnwrap(groups[0]["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["windowId"] as! UInt32 }, native.layers[0].map(\.entry.wid))
        XCTAssertEqual(rows[0]["entryKeys"] as? [String], [subject.entries[0]["key"] as! String])
        XCTAssertEqual((groups[1]["rows"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(groups[1]["label"] as? String, "Unassigned")
    }

    func testDuplicateRowsReferenceSharedKeyNotFirstRange() throws {
        let subject = try subject("{\"app\":\"Safari\"},{\"app\":\"Safari\"}")
        let result = try subject.project(windows: [window(1)], sources: .init())
        let row = ((result["groups"] as! [[String: Any]])[0]["rows"] as! [[String: Any]])[0]
        XCTAssertEqual(row["entryKeys"] as? [String], [subject.entries[0]["key"] as! String])
        XCTAssertNil(row["projectIndex"])
        XCTAssertTrue(subject.entries[0]["ambiguous"] as! Bool)
    }

    func testDiscoveryReadSubscribeAndStaleProjection() throws {
        var current = try snapshot(subject())
        let bridge = EditorBridge { current }
        let capabilities = bridge.reply(to: request("capabilities"))
        XCTAssertEqual(capabilities["kind"] as? String, "capabilities.result")
        XCTAssertEqual(capabilities["subjectId"] as? String, EditorSubject.id)
        XCTAssertEqual((capabilities["payload"] as? [String: Any])?["readOnly"] as? Bool, true)
        let read = bridge.reply(to: request("subject.read"))
        XCTAssertEqual(read["revision"] as? String, current.subject.revision)
        let subscribe = bridge.reply(to: request("events.subscribe"))
        XCTAssertEqual(subscribe["kind"] as? String, "events.subscribe.result")
        let oldRevision = current.subject.revision
        current = try snapshot(subject(label: "Changed"))
        let stale = bridge.reply(to: request("preview.project", revision: oldRevision))
        XCTAssertEqual(stale["kind"] as? String, "error")
        XCTAssertEqual((stale["payload"] as? [String: Any])?["code"] as? String, "stale_revision")
        XCTAssertEqual(stale["revision"] as? String, current.subject.revision)
        XCTAssertEqual(bridge.reply(to: request("preview.project", revision: current.subject.revision))["kind"] as? String, "preview.project.result")
    }

    func testEventsAreInvalidationsAndSubscriptionIsIdempotent() throws {
        let subject = try subject()
        var current = try snapshot(subject)
        let bridge = EditorBridge { current }
        var events: [[String: Any]] = []
        bridge.onEvent = { events.append($0) }
        _ = bridge.reply(to: request("events.subscribe"))
        bridge.poll()
        XCTAssertTrue(events.isEmpty)
        current = try snapshot(subject, windows: [window(1)])
        bridge.poll()
        XCTAssertEqual(events.map { $0["kind"] as! String }, ["windows.changed"])
        events = []
        current = try snapshot(self.subject(label: "Changed"), windows: [window(1)])
        bridge.poll()
        XCTAssertEqual(events.first?["kind"] as? String, "config.changed")
        XCTAssertEqual((events.first?["payload"] as? [String: Any])?["subscriptionId"] as? String, bridge.subscriptionId)
        let again = bridge.reply(to: request("events.subscribe"))
        XCTAssertEqual((again["payload"] as? [String: Any])?["subscriptionId"] as? String, bridge.subscriptionId)
    }

    func testUnreadableSubjectSubscriptionRecoversWithoutReload() throws {
        let good = try snapshot(subject())
        var broken = true
        let bridge = EditorBridge {
            if broken { throw EditorBridgeError("unavailable", "Invalid JSON") }
            return good
        }
        var events: [[String: Any]] = []
        bridge.onEvent = { events.append($0) }
        XCTAssertEqual(bridge.reply(to: request("capabilities"))["kind"] as? String, "capabilities.result")
        XCTAssertEqual(bridge.reply(to: request("events.subscribe"))["kind"] as? String, "events.subscribe.result")
        XCTAssertEqual(bridge.reply(to: request("subject.read"))["kind"] as? String, "error")
        broken = false
        bridge.poll()
        XCTAssertEqual(events.last?["kind"] as? String, "config.changed")
        XCTAssertEqual(events.last?["revision"] as? String, good.subject.revision)
        events = []
        broken = true
        bridge.poll(); bridge.poll()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["revision"] as? String, good.subject.revision)
        broken = false
        bridge.poll()
        XCTAssertEqual(events.count, 2) // unchanged content still recovers
        XCTAssertEqual(bridge.reply(to: request("subject.read"))["kind"] as? String, "subject.read.result")
    }

    func testInvalidRequestRevisionTypesAreRejected() throws {
        let good = try snapshot(subject())
        let bridge = EditorBridge { good }
        var malformed = request("subject.read")
        malformed["revision"] = 4
        XCTAssertEqual((bridge.reply(to: malformed)["payload"] as? [String: Any])?["code"] as? String, "invalid_request")
    }

    func testClosedReadOnlyMethodAllowlistNeverCapturesOrRunsEffects() {
        var captures = 0
        let bridge = EditorBridge { captures += 1; throw EditorBridgeError("unavailable", "fixture") }
        for method in ["change.apply", "layers.assign", "change.undo", "agent.start", "anything"] {
            let reply = bridge.reply(to: request(method))
            XCTAssertEqual((reply["payload"] as? [String: Any])?["code"] as? String, "unsupported")
        }
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(bridge.reply(to: [:])["kind"] as? String, "error")
        XCTAssertEqual(captures, 0)
    }

    func testDuplicateLayerIDsRejectedInsteadOfPickingFirst() {
        XCTAssertThrowsError(try EditorSubject(data: Data("{\"layers\":[{\"id\":\"a\",\"label\":\"A\",\"projects\":[]},{\"id\":\"a\",\"label\":\"B\",\"projects\":[]}]}".utf8)))
    }

    func testSchemeRejectsOtherOriginsAndTraversal() throws {
        let root = URL(fileURLWithPath: "/tmp/editor-fixture")
        let handler = EditorBundleHandler(root: root)
        XCTAssertEqual(try handler.file(for: EditorTransport.indexURL).path, root.appendingPathComponent("index.html").path)
        for url in ["https://example.com/index.html", "lattices-editor://evil/index.html",
                    "lattices-editor://bundle/../secret", "lattices-editor://bundle/%2e%2e/secret",
                    "lattices-editor://bundle:12/index.html"] {
            XCTAssertThrowsError(try handler.file(for: URL(string: url)!))
        }
    }
}
