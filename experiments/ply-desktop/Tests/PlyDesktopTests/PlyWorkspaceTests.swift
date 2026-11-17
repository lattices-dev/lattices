import Foundation
import Testing
@testable import PlyDesktop

private let layers = Data(#"{"layers":[{"id":"one","label":"One","index":0,"projectCount":2},{"id":"two","label":"Two","index":1,"projectCount":1}],"active":0,"focusActive":true}"#.utf8)
private let switched = Data(#"{"layers":[{"id":"one","label":"One","index":0,"projectCount":2},{"id":"two","label":"Two","index":1,"projectCount":1}],"active":1,"focusActive":true}"#.utf8)

private actor WorkspaceFixture {
    var requests: [PlyWorkspaceRequest] = []
    var replies: [Data]
    init(_ replies: [Data]) { self.replies = replies }
    func call(_ request: PlyWorkspaceRequest) throws -> Data {
        requests.append(request)
        guard !replies.isEmpty else { throw PlyWorkspaceError.unavailable }
        return replies.removeFirst()
    }
}

@Test @MainActor func noRequestsUntilOpenedAndCurrentWorkspaceDoesNotSwitch() async throws {
    let fixture = WorkspaceFixture([layers])
    let store = PlyWorkspaceStore { try await fixture.call($0) }
    #expect(await fixture.requests.isEmpty)
    #expect(store.phase == .idle)
    await store.refresh()
    let current = try #require(store.snapshot?.layers.first)
    await store.focus(current)
    #expect(await fixture.requests == [.list])
    #expect(store.phase == .ready)
}

@Test @MainActor func switchUsesStableIDAndConfirmsFreshState() async throws {
    let fixture = WorkspaceFixture([layers, Data(#"{"ok":true,"id":"two","mode":"focus"}"#.utf8), switched])
    let store = PlyWorkspaceStore { try await fixture.call($0) }
    await store.refresh()
    let target = try #require(store.snapshot?.layers.last)
    await store.focus(target)
    #expect(await fixture.requests == [.list, .focus("two"), .list])
    #expect(store.phase == .success("Two"))
    #expect(store.snapshot?.isCurrent(target) == true)
}

@Test @MainActor func rejectedOrUnconfirmedSwitchDoesNotCelebrateOrRetry() async throws {
    for receipt in [#"{"ok":false,"id":"two","mode":"focus"}"#, #"{"ok":true,"id":"wrong","mode":"focus"}"#,
                    #"{"ok":true,"id":"two","mode":"focus"}"#] {
        let fixture = WorkspaceFixture([layers, Data(receipt.utf8), layers])
        let store = PlyWorkspaceStore { try await fixture.call($0) }
        await store.refresh()
        await store.focus(try #require(store.snapshot?.layers.last))
        guard case .failed = store.phase else { Issue.record("Switch must fail verification"); continue }
        #expect(store.snapshot == nil)
        #expect(await fixture.requests.filter { $0 == .focus("two") }.count == 1)
    }
}

@Test @MainActor func unavailableAndMalformedResponsesAllowExplicitRecovery() async {
    let fixture = WorkspaceFixture([Data("not JSON".utf8), layers])
    let store = PlyWorkspaceStore { try await fixture.call($0) }
    await store.refresh()
    #expect(store.phase.pose == .question)
    #expect(store.snapshot == nil)
    await store.refresh()
    #expect(store.phase == .ready)
    await store.refresh() // fixture exhausted: equivalent to unavailable daemon
    #expect(store.phase.pose == .question)
    #expect(store.snapshot == nil)
}

@Test func rememberedLayerIsNotReportedAsActiveAfterExitingFocus() throws {
    let snapshot = try JSONDecoder().decode(PlyWorkspaces.self, from:
        Data(#"{"layers":[{"id":"one","label":"One","index":0,"projectCount":2}],"active":0,"focusActive":false,"rememberedIndex":0}"#.utf8))
    #expect(!snapshot.isCurrent(snapshot.layers[0]))
}

@Test func workspaceNamesRemainOneJSONArgument() throws {
    let name = "quotes\" / spaces & $(touch never); <tag>"
    let args = PlyWorkspaceRequest.focus(name).arguments
    #expect(args.count == 3)
    #expect(args[1] == "layers.activate")
    let parameters = try JSONDecoder().decode([String: String].self, from: Data(args[2].utf8))
    #expect(parameters == ["name": name, "mode": "focus"])
}

private actor SuspendedWorkspaceFixture {
    var calls = 0
    var waiting: CheckedContinuation<Data, Never>?
    func call() async -> Data {
        calls += 1
        return await withCheckedContinuation { waiting = $0 }
    }
    func finish() { waiting?.resume(returning: layers); waiting = nil }
    var ready: Bool { waiting != nil }
}

@Test @MainActor func duplicateRefreshIsCoalescedAndDismissalDiscardsLateRead() async {
    let fixture = SuspendedWorkspaceFixture()
    let store = PlyWorkspaceStore { _ in await fixture.call() }
    let first = Task { await store.refresh() }
    while !(await fixture.ready) { await Task.yield() }
    await store.refresh()
    #expect(await fixture.calls == 1)
    store.dismiss()
    await fixture.finish()
    await first.value
    #expect(store.phase == .idle)
    #expect(store.snapshot == nil)
}

@Test @MainActor func reopenDuringSlowReadReusesTheRequest() async {
    let fixture = SuspendedWorkspaceFixture()
    let store = PlyWorkspaceStore { _ in await fixture.call() }
    let first = Task { await store.refresh() }
    while !(await fixture.ready) { await Task.yield() }
    store.dismiss()
    let reopened = Task { await store.refresh() }
    while store.phase != .loading { await Task.yield() }
    await fixture.finish()
    await first.value
    await reopened.value
    #expect(await fixture.calls == 1)
    #expect(store.phase == .ready)
}

@Test func cliBridgeDrainsLargeOutputAndBoundsAHungProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ply-cli-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("bin/lattices.ts")
    // Substitute a test executable for Bun; no real daemon or workspace mutation.
    try Data("printf '%s' \"$3\"\n".utf8).write(to: script)
    let client = PlyLatticesClient(bun: URL(fileURLWithPath: "/bin/sh"), repository: root, timeout: 2)
    let longID = String(repeating: "x", count: 100_000)
    let result = try await client.call(.focus(longID))
    let parameters = try JSONDecoder().decode([String: String].self, from: result)
    #expect(parameters["name"] == longID)

    try Data("exec /bin/sleep 10\n".utf8).write(to: script)
    let bounded = PlyLatticesClient(bun: URL(fileURLWithPath: "/bin/sh"), repository: root, timeout: 0.1)
    let start = Date()
    await #expect(throws: (any Error).self) { try await bounded.call(.list) }
    #expect(Date().timeIntervalSince(start) < 3)
}
