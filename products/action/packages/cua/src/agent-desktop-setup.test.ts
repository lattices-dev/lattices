import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test, type TestContext } from "node:test";
import { createAgentDesktopBackend } from "./agent-desktop.js";
import type { AgentDesktopProcessInput, AgentDesktopProcessResult } from "./agent-desktop-process.js";
import { BackendRefusal, type BackendCall, type BackendContext } from "./types.js";

const call = (patch: Partial<BackendCall> = {}): BackendCall => ({ requestId: "setup", caller: "launcher-fixture", signal: new AbortController().signal, deadline: Date.now() + 5000, ...patch });
const reply = (command: string, data: unknown): AgentDesktopProcessResult => ({ stdout: JSON.stringify({ version: "2.6", ok: true, command, data }), exitCode: 0 });
function fixture(t: TestContext) {
  const requests: AgentDesktopProcessInput[] = [];
  const state = { accessibility: "granted", screenRecording: "denied", scoped: true, reads: 0, waits: 0,
    onRequest: undefined as ((input: AgentDesktopProcessInput) => Promise<void>) | undefined,
    onRead: undefined as (() => unknown) | undefined,
    onWait: undefined as ((call: BackendCall) => Promise<void>) | undefined };
  const permissions = () => ({ accessibility: { state: state.accessibility }, screen_recording: { state: state.screenRecording }, automation: { state: "unknown" },
    ...(state.scoped ? { request_capabilities: { scoped: true, permissions: ["accessibility", "screen_recording", "automation"] } } : {}) });
  const ctx: BackendContext = { generation: "setup-fixture", shotsDir: "/tmp", options: { command: "/fixture/agent-desktop",
    __run: async (input: AgentDesktopProcessInput) => {
      requests.push(input);
      if (input.args[0] === "status") return reply("status", { version: "1.2.0", permissions: permissions() });
      assert.equal(input.args[0], "permissions");
      if (input.args.includes("--request")) {
        await state.onRequest?.(input);
        return reply("permissions", { accessibility: { state: "granted" }, screen_recording: { state: "granted" } });
      }
      state.reads++;
      return reply("permissions", state.onRead ? state.onRead() : permissions());
    },
    __wait: async (call: BackendCall) => { state.waits++; if (state.onWait) await state.onWait(call); else state.screenRecording = "granted"; },
  }, log: () => {}, stdioMcp: async () => { throw new Error("No MCP spawn"); }, newestDir: () => null,
    refuse: (code, message) => new BackendRefusal(code, message) };
  const backend = createAgentDesktopBackend(ctx);
  t.after(() => backend.dispose());
  return { backend, state, requests, setup: (input = call(), interactive = true) => backend.setup!(input, { interactive }) };
}

test("explicit setup includes screenshots while normal readiness remains AX-only", async (t) => {
  const f = fixture(t);
  assert.equal((await f.backend.availability(call())).ready, true);
  const status = await f.backend.setupAvailability!(call());
  assert.equal(status.ready, false);
  assert.deepEqual(status.needs?.map((need) => need.permission), ["screen-recording"]);
  assert.equal(status.needs?.[0]?.app, undefined);
  assert.equal(status.permissionContext?.kind, "launcher");
});

test("already granted permissions need no request, including older builds", async (t) => {
  const f = fixture(t); f.state.screenRecording = "granted"; f.state.scoped = false;
  const result = await f.setup();
  assert.equal(result.ready, true);
  assert.deepEqual(f.requests.map((r) => r.args), [["permissions"]]);
});

test("noninteractive setup reports missing permissions without prompting", async (t) => {
  const f = fixture(t); f.state.accessibility = "unknown";
  const result = await f.setup(call(), false);
  assert.equal(result.ready, false);
  assert.deepEqual(result.needs?.map((need) => need.permission), ["accessibility", "screen-recording"]);
  assert.equal(result.steps[0]?.status, "skipped");
  assert.equal(f.requests.length, 1);
});

test("older builds never receive broad request or guide fallback", async (t) => {
  const f = fixture(t); f.state.scoped = false;
  const result = await f.setup();
  assert.equal(result.ready, false);
  assert.equal(result.needs?.[0]?.kind, "install");
  assert.equal(f.requests.length, 1);
});

test("scoped requests preserve executable and private environment and require fresh verification", async (t) => {
  const f = fixture(t);
  const result = await f.setup();
  assert.equal(result.ready, true);
  assert.equal(f.state.waits, 1, "request reply alone must not establish readiness");
  assert.equal(f.state.reads, 3);
  const request = f.requests.find((r) => r.args.includes("--request"))!;
  assert.deepEqual(request.args.slice(0, 5), ["permissions", "--request", "--only", "accessibility,screen-recording", "--timeout-ms"]);
  assert.ok(Number(request.args[5]) > 0 && Number(request.args[5]) <= 5000);
  assert.equal(f.requests.filter((r) => r.args.includes("--request")).length, 1);
  for (const input of f.requests) {
    assert.equal(input.command, "/fixture/agent-desktop");
    assert.equal(input.env.AGENT_DESKTOP_HOME, request.env.AGENT_DESKTOP_HOME);
    assert.deepEqual(Object.keys(input.env).filter((key) => key.startsWith("AGENT_DESKTOP_")), ["AGENT_DESKTOP_HOME"]);
  }
});

test("malformed or unverifiable status cannot cause a prompt or become a grant", async (t) => {
  const f = fixture(t);
  for (const invalid of [null, {}, { accessibility: true, screen_recording: true }, { accessibility: { state: "granted" } }]) {
    f.state.onRead = () => invalid;
    const result = await f.setup();
    assert.equal(result.ready, false);
    assert.equal(result.needs?.[0]?.kind, "config");
  }
  assert.ok(f.requests.every((r) => !r.args.includes("--request")));
});

test("unknown permission enum values fail before requesting even with scoped capability", async (t) => {
  const f = fixture(t); f.state.accessibility = "garbage";
  const result = await f.setup();
  assert.equal(result.ready, false);
  assert.equal(result.needs?.[0]?.kind, "config");
  assert.equal(f.requests.length, 1);
});

test("request errors are not retried and do not expose native output", async (t) => {
  const f = fixture(t);
  f.state.onRequest = async () => { throw new Error("private native diagnostic"); };
  const result = await f.setup();
  assert.equal(result.ready, false);
  assert.equal(f.requests.filter((r) => r.args.includes("--request")).length, 1);
  assert.ok(!JSON.stringify(result).includes("private native diagnostic"));
});

test("cancellation before setup sends nothing", async (t) => {
  const f = fixture(t); const controller = new AbortController(); controller.abort();
  assert.equal((await f.setup(call({ signal: controller.signal }))).ready, false);
  assert.equal((await f.setup(call({ deadline: Date.now() - 1 }))).ready, false);
  assert.equal(f.requests.length, 0);
});

test("active request cancellation settles and never polls again", async (t) => {
  const f = fixture(t); const controller = new AbortController();
  let started!: () => void; const active = new Promise<void>((resolve) => { started = resolve; });
  f.state.onRequest = async (input) => { started(); await new Promise<void>((_, reject) => input.signal.addEventListener("abort", () => reject(input.signal.reason), { once: true })); };
  const setup = f.setup(call({ signal: controller.signal }));
  await active; controller.abort();
  assert.equal((await setup).ready, false);
  assert.equal(f.state.reads, 1);
});

test("deadline aborts an unresponsive permission request without retrying", async (t) => {
  const f = fixture(t);
  f.state.onRequest = async (input) => { await new Promise<void>((_, reject) => input.signal.addEventListener("abort", () => reject(input.signal.reason), { once: true })); };
  const result = await f.setup(call({ deadline: Date.now() + 30 }));
  assert.equal(result.ready, false);
  assert.match(result.steps.at(-1)!.detail!, /cancelled or timed out/);
  assert.equal(f.state.reads, 1);
  assert.equal(f.requests.filter((r) => r.args.includes("--request")).length, 1);
});

test("polling and native request do not block independent readiness checks", async (t) => {
  const f = fixture(t);
  let started!: () => void, finish!: () => void;
  const active = new Promise<void>((resolve) => { started = resolve; });
  f.state.onRequest = async () => { started(); await new Promise<void>((resolve) => { finish = resolve; }); };
  const setup = f.setup(); await active;
  assert.equal((await f.backend.setupAvailability!(call())).ready, false);
  assert.equal((await f.setup()).ready, false, "duplicate setup must not send another request");
  finish(); assert.equal((await setup).ready, true);
  assert.equal(f.requests.filter((r) => r.args.includes("--request")).length, 1);
});

test("disposal cancels pending waits before removing backend state", async (t) => {
  const f = fixture(t);
  let started!: () => void; const waiting = new Promise<void>((resolve) => { started = resolve; });
  f.state.onWait = async (input) => { started(); await new Promise<void>((_, reject) => input.signal.addEventListener("abort", () => reject(input.signal.reason), { once: true })); };
  const setup = f.setup(); await waiting;
  const home = f.requests[0]!.env.AGENT_DESKTOP_HOME!;
  assert.equal(existsSync(home), true);
  await f.backend.dispose();
  assert.equal((await setup).ready, false);
  assert.equal(existsSync(home), false);
});
