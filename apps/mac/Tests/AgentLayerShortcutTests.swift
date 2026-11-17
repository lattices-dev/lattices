import XCTest
@testable import Lattices

final class AgentLayerShortcutTests: XCTestCase {
    private static let empty = #"{"ok":true,"workspaces":[{"workspace":"default","layer":{"active":false}}]}"#
    private static let active = #"{"ok":true,"workspaces":[{"workspace":"agent","layer":{"active":true}}]}"#
    private static let visible = #"{"ok":true,"layer":{"active":true,"layer":{"pip":true}}}"#

    private func reply(_ json: String) throws -> AgentLayerReply {
        try AgentLayerCommand.decode(stdout: Data(json.utf8), stderr: Data(), status: 0)
    }

    func testListParsingAndBunEcho() throws {
        XCTAssertEqual(try reply("$ bun {checkout}/main.ts layer list\n" + Self.active).activeWorkspaces(), ["agent"])
        XCTAssertEqual(try reply(Self.empty).activeWorkspaces(), [])
        XCTAssertThrowsError(try reply(#"{"ok":true}"#).activeWorkspaces())
        XCTAssertThrowsError(try reply(#"{"ok":true,"workspaces":[{"workspace":"agent","layer":{}}]}"#))
        XCTAssertThrowsError(try reply("unexpected {log}\n" + Self.active))
    }

    func testErrorsAndExitStatusAreNotSuccessfulEmptyLists() throws {
        XCTAssertThrowsError(try reply(#"{"ok":false,"error":"Workspace identity mismatch"}"#)) {
            XCTAssertEqual($0.localizedDescription, "Workspace identity mismatch")
        }
        XCTAssertThrowsError(try AgentLayerCommand.decode(stdout: Data(Self.empty.utf8), stderr: Data(), status: 1))
        XCTAssertThrowsError(try AgentLayerCommand.decode(stdout: Data(), stderr: Data("bun: not found".utf8), status: 1)) {
            XCTAssertTrue($0.localizedDescription.contains("bun: not found"))
        }
    }

    func testPipMustActuallyBecomeVisible() throws {
        try reply(Self.visible).requireVisiblePreview()
        XCTAssertThrowsError(try reply(#"{"ok":true,"layer":{"active":true,"layer":{"pip":false}}}"#).requireVisiblePreview())
        XCTAssertThrowsError(try reply(#"{"ok":true,"layer":{"active":false}}"#).requireVisiblePreview())
    }

    func testFinderEnvironmentSupportsNestedExecutableLookup() throws {
        let env = AgentLayerCommand.environment(bun: "/bin/sh", inherited: ["PATH": "/usr/sbin", "CLAUDECODE": "1"])
        XCTAssertNil(env["CLAUDECODE"])
        let result = try AgentLayerCommand.capture(executable: "/bin/sh", arguments: ["-c", "sh -c 'printf nested'"], environment: env, timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "nested")
    }

    func testCapturesBothPipesWithoutDeadlockAndReportsExit() throws {
        let result = try AgentLayerCommand.capture(executable: "/bin/sh", arguments: ["-c", "printf output; printf problem >&2; exit 7"], environment: [:], timeout: 2)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "output")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "problem")
    }

    func testOutputLargerThanPipeCapacityIsDrained() throws {
        let result = try AgentLayerCommand.capture(executable: "/bin/sh", arguments: [
            "-c", "/usr/bin/head -c 131072 /dev/zero; /usr/bin/head -c 131072 /dev/zero >&2",
        ], environment: [:], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 131072)
        XCTAssertEqual(result.stderr.count, 131072)
    }

    func testExcessiveOutputAndMissingExecutableFailPromptly() throws {
        XCTAssertThrowsError(try AgentLayerCommand.capture(executable: "/usr/bin/yes", arguments: [], environment: [:], timeout: 3)) {
            XCTAssertTrue($0.localizedDescription.contains("too much output"))
        }
        XCTAssertThrowsError(try AgentLayerCommand.capture(executable: "/missing/agent-layer-test", arguments: [], environment: [:], timeout: 1))
    }

    func testTimeoutKillsNestedChildAndAllowsNextCommand() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        XCTAssertThrowsError(try AgentLayerCommand.capture(executable: "/bin/sh", arguments: [
            "-c", "/bin/sleep 30 & echo $! > \"$1\"; wait", "test", pidFile.path,
        ], environment: [:], timeout: 0.2)) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // A killed descendant can briefly remain a zombie until launchd reaps it.
        let state = try AgentLayerCommand.capture(executable: "/bin/ps", arguments: ["-p", String(pid), "-o", "stat="], environment: [:], timeout: 2)
        let value = String(decoding: state.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(value.isEmpty || value.hasPrefix("Z"), "Child survived timeout: \(value)")
        let result = try AgentLayerCommand.capture(executable: "/usr/bin/true", arguments: [], environment: [:], timeout: 2)
        XCTAssertEqual(result.status, 0)
    }

    @MainActor
    func testEmptyStatusCanBeClickedAgainWhenTaskAppears() async throws {
        let commands = Commands()
        let model = AgentLayerShortcut(command: { try await commands.run($0) })
        model.show()
        try await wait { await commands.count == 1 }
        await commands.answer(try reply(Self.empty))
        try await wait { await MainActor.run { !model.busy } }
        XCTAssertTrue(model.canShow)
        XCTAssertNotNil(model.lastError)
        model.show()
        try await wait { await commands.count == 2 }
        await commands.answer(try reply(Self.active))
        try await wait { await commands.count == 3 }
        await commands.answer(try reply(Self.visible))
        try await wait { await MainActor.run { !model.busy } }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.activeWorkspaces, ["agent"])
        let calls = await commands.calls
        XCTAssertEqual(calls.last, ["layer", "pip", "--workspace", "agent"])
    }

    @MainActor
    func testRefreshFailurePreservesStatusAndSuccessfulRefreshClearsError() async throws {
        let commands = Commands()
        let model = AgentLayerShortcut(command: { try await commands.run($0) })
        model.refresh()
        try await wait { await commands.count == 1 }
        await commands.answer(try reply(Self.active))
        try await wait { await MainActor.run { !model.refreshing } }
        model.refresh()
        try await wait { await commands.count == 2 }
        await commands.fail("CLI unavailable")
        try await wait { await MainActor.run { !model.refreshing } }
        XCTAssertEqual(model.activeWorkspaces, ["agent"])
        XCTAssertEqual(model.lastError, "CLI unavailable")
        XCTAssertTrue(model.canShow)
        model.refresh()
        try await wait { await commands.count == 3 }
        await commands.answer(try reply(Self.empty))
        try await wait { await MainActor.run { !model.refreshing } }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.activeWorkspaces, [])
    }

    @MainActor
    func testClickDuringRefreshIsSerializedAndReadsFreshStatus() async throws {
        let commands = Commands()
        let model = AgentLayerShortcut(command: { try await commands.run($0) })
        model.refresh()
        try await wait { await commands.count == 1 }
        model.show()
        model.show() // Double click must not enqueue another show.
        model.refresh()
        XCTAssertTrue(model.busy)
        await commands.answer(try reply(Self.empty))
        try await wait { await commands.count == 2 }
        await commands.answer(try reply(Self.active))
        try await wait { await commands.count == 3 }
        await commands.answer(try reply(Self.visible))
        try await wait { await MainActor.run { !model.busy && !model.refreshing } }
        XCTAssertEqual(model.activeWorkspaces, ["agent"])
        let calls = await commands.calls
        XCTAssertEqual(calls, [["layer", "list"], ["layer", "list"], ["layer", "pip", "--workspace", "agent"]])
    }

    @MainActor
    func testRefreshTriggerDuringReadIsReplayed() async throws {
        let commands = Commands()
        let model = AgentLayerShortcut(command: { try await commands.run($0) })
        model.refresh()
        try await wait { await commands.count == 1 }
        model.refresh()
        await commands.answer(try reply(Self.empty))
        try await wait { await commands.count == 2 }
        await commands.answer(try reply(Self.active))
        try await wait { await MainActor.run { !model.refreshing } }
        XCTAssertEqual(model.activeWorkspaces, ["agent"])
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await predicate()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for command"); throw AgentLayerCommandError(message: "Test timed out") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private actor Commands {
        var calls: [[String]] = []
        var count: Int { calls.count }
        var continuation: CheckedContinuation<AgentLayerReply, Error>?
        func run(_ args: [String]) async throws -> AgentLayerReply {
            calls.append(args)
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func answer(_ reply: AgentLayerReply) { continuation?.resume(returning: reply); continuation = nil }
        func fail(_ message: String) { continuation?.resume(throwing: AgentLayerCommandError(message: message)); continuation = nil }
    }
}
