import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { createActionCuaBackend } from "./action-cua.js";
import { BackendRefusal, type BackendCall, type BackendContext, type BackendSetupStep } from "./types.js";

const denied = { accessibility: "denied", screenRecording: "denied", notes: ["bundleId=dev.lattices.Action", "bundlePath=/Applications/Action.app"] };
const granted = { ...denied, accessibility: "granted", screenRecording: "granted" };
const call = (timeoutMs = 5_000, signal = new AbortController().signal): BackendCall => ({
  requestId: "action-setup-test", caller: "test", deadline: Date.now() + timeoutMs, signal,
});

function fixture(t: TestContext, snapshots: unknown[], overrides: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "action-setup-test-"));
  const commands: string[] = [];
  let index = 0;
  const inner = (overrides.__run ?? undefined) as ((command: string, ...rest: unknown[]) => Promise<unknown>) | undefined;
  // The native host's capability probe is answered here so tests track only permission commands.
  if (inner) overrides = { ...overrides, __run: async (command: string, ...rest: unknown[]) => command === "capabilities" ? {} : inner(command, ...rest) };
  const ctx: BackendContext = {
    generation: "test", shotsDir: dir, log: () => {}, newestDir: () => null,
    refuse: (code, message, observation) => new BackendRefusal(code, message, observation),
    stdioMcp: async () => { throw new Error("Unexpected MCP transport"); },
    options: {
      host: process.execPath,
      __wait: async () => {},
      __run: async (command: string) => {
        if (command === "capabilities") return {};
        commands.push(command);
        if (command === "status") return snapshots[Math.min(index++, snapshots.length - 1)];
        if (command === "request") return denied;
        if (command.startsWith("open-")) return { status: "opened" };
        throw new Error(`Unexpected fake command: ${command}`);
      }, ...overrides,
    },
  };
  const backend = createActionCuaBackend(ctx);
  t.after(async () => { await backend.dispose(); rmSync(dir, { recursive: true, force: true }); });
  return { backend, commands };
}

describe("action-cua permission setup", () => {
  test("availability maps the native snapshot to precise app-owned needs", async (t) => {
    const { backend, commands } = fixture(t, [{ ...denied, accessibility: "granted" }]);
    const status = await backend.availability(call());
    assert.equal(status.ready, false);
    assert.equal(status.needs?.length, 1);
    assert.equal(status.needs![0]!.permission, "screen-recording");
    assert.equal(status.needs![0]!.app, "/Applications/Action.app");
    assert.equal(status.needs![0]!.fix, "action setup action-cua");
    assert.match(status.needs![0]!.detail, /Privacy & Security/);
    assert.deepEqual(commands, ["status"]);
  });

  test("unknown or malformed permission status never reports ready", async (t) => {
    const { backend } = fixture(t, [{ accessibility: "unknown" }]);
    const status = await backend.availability(call());
    assert.equal(status.ready, false);
    assert.deepEqual(status.needs?.map((need) => need.permission), ["accessibility", "screen-recording"]);
  });

  test("requests, opens missing panes, polls and reports verified readiness with live steps", async (t) => {
    const { backend, commands } = fixture(t, [denied, denied, denied, granted]);
    const live: BackendSetupStep[] = [];
    const result = await backend.setup!({ ...call(), onSetupStep: (step) => live.push(step) }, { interactive: true });
    assert.equal(result.ready, true);
    assert.equal(result.needs, undefined);
    assert.deepEqual(commands, ["status", "request", "status", "open-accessibility-settings", "open-screen-recording-settings", "status", "status"]);
    assert.deepEqual(live, result.steps);
    assert.ok(result.steps.some((step) => step.status === "waiting-on-user" && /enable Action.app/.test(step.detail ?? "")));
    assert.equal(result.steps.at(-1)?.status, "done");
  });

  test("opens only the pane for the remaining missing grant", async (t) => {
    const { backend, commands } = fixture(t, [denied, { ...denied, accessibility: "granted" }, granted]);
    const result = await backend.setup!(call(), { interactive: true });
    assert.equal(result.ready, true);
    assert.equal(commands.includes("open-accessibility-settings"), false);
    assert.equal(commands.includes("open-screen-recording-settings"), true);
  });

  test("noninteractive setup only checks status and explains the required command", async (t) => {
    const { backend, commands } = fixture(t, [denied]);
    const result = await backend.setup!(call(), { interactive: false });
    assert.equal(result.ready, false);
    assert.equal(result.needs?.length, 2);
    assert.deepEqual(commands, ["status"]);
    assert.equal(result.steps.at(-1)?.status, "skipped");
    assert.match(result.steps.at(-1)?.detail ?? "", /action setup action-cua/);
  });

  test("already granted setup does not request or open anything", async (t) => {
    const { backend, commands } = fixture(t, [granted]);
    const result = await backend.setup!(call(), { interactive: true });
    assert.equal(result.ready, true);
    assert.deepEqual(commands, ["status"]);
  });

  test("deadline leaves missing permissions waiting on the user", async (t) => {
    const { backend } = fixture(t, [denied], { __wait: undefined });
    const result = await backend.setup!(call(30), { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.needs?.length, 2);
    assert.equal(result.steps.at(-1)?.status, "waiting-on-user");
    assert.match(result.steps.at(-1)?.detail ?? "", /timed out/);
  });

  test("an aborted call never requests permissions", async (t) => {
    const { backend, commands } = fixture(t, [denied]);
    const controller = new AbortController();
    controller.abort();
    const result = await backend.setup!(call(5_000, controller.signal), { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)?.status, "failed");
    assert.deepEqual(commands, []);
  });

  test("cancellation during the permission request stops before opening settings", async (t) => {
    const controller = new AbortController();
    const sent: string[] = [];
    const { backend } = fixture(t, [denied], {
      __run: async (command: string) => {
        sent.push(command);
        if (command === "status") return denied;
        if (command === "request") {
          controller.abort();
          return granted; // Even an ignored cancellation cannot report success.
        }
        throw new Error(`Unexpected command ${command}`);
      },
    });
    const result = await backend.setup!(call(5_000, controller.signal), { interactive: true });
    assert.equal(result.ready, false);
    assert.deepEqual(sent, ["status", "request"]);
    assert.equal(result.steps.at(-1)?.status, "failed");
    assert.equal(result.needs?.length, 2);
  });

  test("a failed request still checks the grants and offers the settings recovery", async (t) => {
    const sent: string[] = [];
    let statusChecks = 0;
    const { backend } = fixture(t, [denied], {
      __run: async (command: string) => {
        sent.push(command);
        if (command === "status") return ++statusChecks >= 3 ? granted : denied;
        if (command === "request") throw new Error("Permission request timed out");
        if (command.startsWith("open-")) return { status: "opened" };
        throw new Error(`Unexpected command ${command}`);
      },
    });
    const result = await backend.setup!(call(), { interactive: true });
    assert.equal(result.ready, true);
    assert.deepEqual(sent, ["status", "request", "status", "open-accessibility-settings", "open-screen-recording-settings", "status"]);
    assert.ok(result.steps.some((step) => step.step === "request" && step.status === "failed" && /timed out/.test(step.detail ?? "")));
    assert.equal(result.steps.at(-1)?.status, "done");
  });

  test("a poll transport failure retains unresolved needs and never reports ready", async (t) => {
    let statusChecks = 0;
    const { backend } = fixture(t, [denied], {
      __run: async (command: string) => {
        if (command === "status") {
          if (++statusChecks >= 3) throw new Error("status transport disconnected");
          return denied;
        }
        if (command === "request") return denied;
        if (command.startsWith("open-")) return { status: "opened" };
        throw new Error(`Unexpected command ${command}`);
      },
    });
    const result = await backend.setup!(call(), { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.needs?.length, 2);
    assert.equal(result.steps.at(-1)?.status, "failed");
    assert.match(result.steps.at(-1)?.detail ?? "", /status transport disconnected/);
  });
});
