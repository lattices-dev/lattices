import XCTest
@testable import Lattices

final class CommandModelRouterTests: XCTestCase {
    private let binary = URL(fileURLWithPath: "/usr/bin/false")

    func testStickyRouteAndExplicitOverride() {
        let codex = CommandModelRoute(kind: .codex, executable: binary, model: "luna")
        let claude = CommandModelRoute(kind: .claude, executable: binary, model: "haiku")
        XCTAssertEqual(CommandModelRouter.ordered([codex, claude], preference: .automatic, selected: claude), [claude, codex])
        XCTAssertEqual(CommandModelRouter.ordered([codex, claude], preference: .codex, selected: claude), [codex])
        XCTAssertEqual(CommandModelRouter.ordered([codex], preference: .claude, selected: codex), [])
    }

    func testCatalogOnlySelectsKnownFastFamilies() {
        let catalog = """
        provider model context max-out thinking images
        xai grok-4.9 100K 64K yes yes
        xai grok-4.10 100K 64K yes yes
        google gemini-3-flash 100K 64K yes yes
        google mai-code-1.1-flash 100K 64K yes yes
        deepseek deepseek-4.1-flash 100K 64K yes yes
        other qwen3.8-flash 100K 64K yes yes
        openai gpt-6-astra 100K 64K yes yes
        """
        let routes = CommandModelRouter.routes(fromPiCatalog: catalog, executable: binary)
        XCTAssertEqual(routes.map(\.model), ["grok-4.10", "gemini-3-flash", "deepseek-4.1-flash"])
        XCTAssertEqual(routes.map(\.kind), [.grok, .flash, .flash])
    }

    func testStickyAPIRequiresCurrentProviderEligibility() {
        let api = CommandModelRoute(kind: .api, executable: binary, model: "gpt-6-luna", provider: "openai")
        XCTAssertEqual(CommandModelRouter.eligibleStickyRoute(api, apiProviders: ["openai"]), api)
        XCTAssertNil(CommandModelRouter.eligibleStickyRoute(api, apiProviders: []))
        XCTAssertNil(CommandModelRouter.eligibleStickyRoute(api, apiProviders: ["anthropic"]))
        let pi = CommandModelRoute(kind: .grok, executable: binary, model: "grok", provider: "xai")
        XCTAssertEqual(CommandModelRouter.eligibleStickyRoute(pi, apiProviders: []), pi)
    }

    func testAPIFailureFallsBackButUnknownDoesNot() async throws {
        let router = CommandModelRouter()
        var attempts: [String] = []
        let (result, _) = try await router.complete(prompt: "ambiguous command", preference: .api,
            apiProviders: ["openai", "anthropic"]) { provider, _, timeout in
            attempts.append(provider)
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, 15)
            if provider == "openai" { throw CommandInferenceError.failed }
            return "{\"intent\":\"unknown\"}"
        }
        XCTAssertEqual(attempts, ["openai", "anthropic"])
        XCTAssertTrue(result.contains("unknown"))
        attempts = []
        _ = try await router.complete(prompt: "another ambiguous command", preference: .api,
            apiProviders: ["openai", "anthropic"]) { provider, _, _ in
            attempts.append(provider)
            return "{\"intent\":\"unknown\"}"
        }
        XCTAssertEqual(attempts, ["anthropic"])
    }

    func testRuntimeRequestsAreIsolated() {
        let output = URL(fileURLWithPath: "/tmp/output")
        let codex = CommandModelRoute(kind: .codex, executable: binary, model: "gpt-6-luna").arguments(output: output)
        XCTAssertTrue(codex.contains("--ignore-user-config"))
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertTrue(codex.contains("--ephemeral"))
        let claude = CommandModelRoute(kind: .claude, executable: binary, model: "haiku").arguments(output: output)
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(claude.contains("--strict-mcp-config"))
        let pi = CommandModelRoute(kind: .grok, executable: binary, model: "grok", provider: "xai").arguments(output: output)
        XCTAssertTrue(pi.contains("--no-tools"))
        XCTAssertTrue(pi.contains("--no-context-files"))
    }

    func testProcessConsumesStdinAndPreservesLiteralText() async throws {
        let prompt = "$(touch /tmp/never-execute) `echo literal`\nhello"
        let result = try await CommandInferenceProcess.run(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], prompt: prompt, timeout: 2)
        XCTAssertEqual(result, prompt)
    }

    func testProcessTimeout() async {
        do {
            _ = try await CommandInferenceProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"], prompt: "", timeout: 0.1)
            XCTFail("Expected deadline")
        } catch { XCTAssertTrue(error is CommandInferenceError) }
    }

    func testProcessCancellation() async {
        let task = Task {
            try await CommandInferenceProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"], prompt: "", timeout: 10)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLiveCodexCommandInference() async throws {
        guard ProcessInfo.processInfo.environment["LATTICES_TEST_COMMAND_MODEL"] == "1",
              let executable = CommandModelRouter.executable("codex") else {
            throw XCTSkip("Opt-in signed-in inference probe")
        }
        let route = CommandModelRoute(kind: .codex, executable: executable, model: "gpt-6-luna")
        let result = try await CommandInferenceProcess.infer(route: route,
            prompt: "You classify voice commands. Do not use tools. Reply with only JSON: {\"intent\":\"open_application\",\"target\":\"ChatGPT\"} for the utterance: Open ChatGPT please.")
        let data = try XCTUnwrap(result.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json["intent"], "open_application")
        XCTAssertEqual(json["target"], "ChatGPT")
    }
}
