import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { createAgentDesktopBackend } from "./agent-desktop.js";
import { runAgentDesktop, type AgentDesktopProcessInput, type AgentDesktopProcessResult } from "./agent-desktop-process.js";
import { BackendRefusal, type BackendAction, type BackendCall, type BackendContext, type BackendObservation, type BackendTier } from "./types.js";

const call = (patch: Partial<BackendCall> = {}): BackendCall => ({ requestId: "request", caller: "test", signal: new AbortController().signal, deadline: Date.now() + 5_000, ...patch });
const envelope = (command: string, data: unknown): AgentDesktopProcessResult => ({ stdout: JSON.stringify({ version: "2.6", command, ok: true, data }), exitCode: 0 });
const failed = (command: string, delivery: string, code = "STALE_REF"): AgentDesktopProcessResult => ({ stdout: JSON.stringify({ version: "2.6", command, ok: false,
  error: { code, message: "secret text must not leak", disposition: { delivery, retry: delivery === "not_delivered" ? "safe" : "unsafe" } } }), exitCode: 1 });
const window = { id: "w-123", title: "Fixture", app_name: "Fixture", pid: 42, process_instance: "started-123", is_focused: true, bounds: { x: 10, y: 20, width: 300, height: 200 } };
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII=", "base64");
const allTiers: BackendTier[] = ["observe", "semantic", "attention"];

function fixture(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "agent-desktop-test-"));
  const calls: AgentDesktopProcessInput[] = [];
  const state = { windows: [structuredClone(window)], snapshot: 0, identityUnproven: false, complete: true,
    actions: ["Click", "SetValue", "TypeText", "Scroll"], alterSnapshot: undefined as ((data: any) => void) | undefined,
    override: undefined as ((input: AgentDesktopProcessInput) => Promise<AgentDesktopProcessResult | undefined>) | undefined };
  const run = async (input: AgentDesktopProcessInput): Promise<AgentDesktopProcessResult> => {
    calls.push(input);
    const override = await state.override?.(input);
    if (override) return override;
    const [verb] = input.args;
    if (verb === "list-windows") return envelope(verb, state.windows);
    if (verb === "status") return envelope(verb, { version: "1.2.0", permissions: { accessibility: { state: "granted" }, screen_recording: { state: "granted" } } });
    if (verb === "snapshot") {
      const scoped = state.windows.find((w) => w.id === input.args[input.args.indexOf("--window-id") + 1]);
      assert.ok(scoped);
      const snapshotId = `s${++state.snapshot}test`;
      const data = { app: scoped.app_name, window: { id: scoped.id, title: scoped.title }, complete: state.complete, snapshot_id: snapshotId,
        identity_unproven: state.identityUnproven,
        tree: { role: "window", children: [{ role: "textfield", name: "Editor", value: "old", ref_id: `@${snapshotId}:e1`, available_actions: state.actions }] } };
      state.alterSnapshot?.(data);
      return envelope(verb, data);
    }
    if (verb === "screenshot") {
      assert.equal(input.args[1], "--window-id");
      assert.equal(input.args[2], window.id);
      const path = input.args[3]!;
      writeFileSync(path, png);
      return envelope(verb, { path, format: "png", width: 1, height: 1, scale_factor: 2 });
    }
    return envelope(verb!, { action: verb, disposition: { delivery: "delivered_unverified", retry: "unsafe" }, steps: [{ label: "semantic", outcome: "succeeded", mechanism: "semantic_api" }] });
  };
  const ctx: BackendContext = { generation: "test-generation", options: { command: "fixture-agent-desktop", __run: run }, shotsDir: dir,
    stdioMcp: async () => { throw new Error("must not spawn MCP"); }, newestDir: () => null, log: () => {},
    refuse: (code, message, observation) => new BackendRefusal(code, message, observation) };
  const backend = createAgentDesktopBackend(ctx);
  t.after(async () => { await backend.dispose(); rmSync(dir, { recursive: true, force: true }); });
  const observe = async (screenshot = false) => {
    const targets = await backend.targets(call());
    return await backend.observe(call(), targets[0]!.targetId, { screenshot });
  };
  const act = (observation: BackendObservation, action: BackendAction, allowTiers = allTiers, request = call()) => backend.act(request, observation.targetId, action, { observationId: observation.observationId, allowTiers });
  return { backend, ctx, state, calls, observe, act, dir };
}
const press = (observation: BackendObservation): BackendAction => ({ kind: "press", ref: observation.ax![1]!.ref });
const mutating = (input: AgentDesktopProcessInput) => !["list-windows", "snapshot", "screenshot", "status"].includes(input.args[0]!);
async function refusal(promise: Promise<unknown>, code: string) {
  await assert.rejects(promise, (error: unknown) => error instanceof BackendRefusal && error.code === code);
}

describe("agent-desktop adapter", () => {
  test("reports readiness and stable generation/process/window targets", async (t) => {
    const f = fixture(t);
    assert.deepEqual(await f.backend.availability(call()), { ready: true, version: "1.2.0" });
    const [target] = await f.backend.targets(call());
    assert.deepEqual(JSON.parse(Buffer.from(target!.targetId.split(":")[2]!, "base64url").toString()), [window.id, window.pid, window.process_instance]);
    assert.match(target!.targetId, /^test-generation:agent-desktop:/);
    await refusal(f.backend.observe(call(), target!.targetId.replace("test-generation", "old"), {}), "unknown-target");
    f.state.windows[0]!.process_instance = "restarted";
    await refusal(f.backend.observe(call(), target!.targetId, {}), "unknown-target");
  });
  test("omits unproven window identities and rejects ambiguous IDs", async (t) => {
    const f = fixture(t);
    f.state.windows[0]!.process_instance = "";
    assert.deepEqual(await f.backend.targets(call()), []);
    f.state.windows = [structuredClone(window), { ...window, pid: 43, process_instance: "other" }];
    await assert.rejects(f.backend.targets(call()), /ambiguous/);
  });
  test("Accessibility readiness does not require optional Screen Recording", async (t) => {
    const f = fixture(t);
    f.state.override = async (input) => input.args[0] === "status" ? envelope("status", { version: "1.2.0", permissions: {
      accessibility: { state: "granted" }, screen_recording: { state: "denied" } } }) : undefined;
    const ready = await f.backend.availability(call());
    assert.equal(ready.ready, true);
    assert.equal(ready.needs, undefined);
    assert.match(ready.reason!, /Optional window screenshots/);
    await f.observe();
    f.state.override = async (input) => input.args[0] === "screenshot" ? failed("screenshot", "not_delivered", "PERMISSION_DENIED") : undefined;
    await refusal(f.observe(true), "unavailable");
  });
  test("maps qualified refs and sends text on stdin without headed/global arguments", async (t) => {
    const f = fixture(t);
    const o = await f.observe();
    assert.equal(o.ax![1]!.settable, true);
    const text = "--headed $(touch /tmp/nope)\nprivate text";
    await f.act(o, { kind: "setValue", ref: o.ax![1]!.ref, value: text });
    const sent = f.calls.find(mutating)!;
    assert.equal(sent.stdin, text);
    assert.deepEqual(sent.args.slice(0, 2), ["set-value", "@s1test:e1"]);
    assert.ok(sent.args.includes("--stdin"));
    assert.ok(!sent.args.some((arg) => arg.includes(text) || arg === "--headed"));
    await refusal(f.act(o, press(o)), "stale-ref");
  });
  test("refuses old, cross-target, inert and unproven refs before dispatch", async (t) => {
    const f = fixture(t);
    const first = await f.observe();
    const next = await f.observe();
    await refusal(f.act(first, press(first)), "stale-ref");
    await refusal(f.act(next, press(first)), "stale-ref");
    await refusal(f.act(next, { kind: "press", ref: next.ax![0]!.ref }), "stale-ref");
    f.state.windows.push({ ...window, id: "w-456" });
    const targets = await f.backend.targets(call());
    const other = await f.backend.observe(call(), targets[1]!.targetId, {});
    await refusal(f.act(other, press(next)), "stale-ref");
    f.state.identityUnproven = true;
    const unproven = await f.observe();
    await refusal(f.act(unproven, press(unproven)), "stale-ref");
    assert.equal(f.calls.filter(mutating).length, 0);
  });
  test("partial presentation preserves completeness metadata and proven refs but incomplete owner scope fails", async (t) => {
    const f = fixture(t);
    f.state.complete = false;
    f.state.alterSnapshot = (data) => {
      data.truncated = true;
      data.nodes_observed = 2;
      data.tree.subtree_truncated = true;
    };
    const o = await f.observe();
    assert.equal(o.complete, false);
    assert.equal(o.truncated, true);
    assert.equal(o.nodesObserved, 2);
    assert.equal(o.ax![0]!.subtreeTruncated, true);
    assert.equal(o.ax![1]!.subtreeTruncated, undefined);
    await f.act(o, press(o));
    f.state.alterSnapshot = (data) => { delete data.window; };
    await assert.rejects(f.observe(), /selected window/);
  });
  test("rejects malformed completeness metadata without publishing new refs", async (t) => {
    const f = fixture(t);
    const complete = await f.observe();
    assert.equal(complete.complete, true);
    assert.equal(complete.truncated, undefined);
    assert.equal(complete.nodesObserved, undefined);
    const invalid: Array<(data: any) => void> = [
      (data) => { data.complete = "false"; },
      (data) => { data.truncated = "true"; },
      (data) => { data.nodes_observed = -1; },
      (data) => { data.nodes_observed = 1.5; },
      (data) => { data.nodes_observed = Number.MAX_SAFE_INTEGER + 1; },
      (data) => { data.tree.subtree_truncated = "true"; },
    ];
    for (const alter of invalid) {
      f.state.alterSnapshot = alter;
      await assert.rejects(f.observe(), /schema|malformed/);
    }
    await refusal(f.act(complete, press(complete)), "stale-ref");
    assert.equal(f.calls.filter(mutating).length, 0);
  });
  test("rejects unqualified, duplicate and wrong-snapshot refs", async (t) => {
    const f = fixture(t);
    for (const invalid of ["@e1", "@another:e1"]) {
      f.state.alterSnapshot = (data) => { data.tree.children[0].ref_id = invalid; };
      await assert.rejects(f.observe(), /invalid or duplicate/);
    }
    f.state.alterSnapshot = (data) => { data.tree.children.push(structuredClone(data.tree.children[0])); };
    await assert.rejects(f.observe(), /invalid or duplicate/);
  });
  test("does not promote unsupported actions or cross the allowTiers boundary", async (t) => {
    const f = fixture(t);
    const o = await f.observe();
    await refusal(f.act(o, { kind: "click", point: { x: 15, y: 30 } }), "unsupported");
    await refusal(f.act(o, { kind: "type", text: "secret" }), "unsupported");
    await refusal(f.act(o, { kind: "scroll", point: { x: 15, y: 30 }, direction: "down" }), "unsupported");
    await refusal(f.act(o, { kind: "type", text: "hello", ref: o.ax![1]!.ref }, ["semantic"]), "tier-not-allowed");
    f.state.actions = [];
    const unsupported = await f.observe();
    await refusal(f.act(unsupported, press(unsupported)), "unsupported");
    assert.equal(f.calls.filter(mutating).length, 0);
  });
  test("keys require current exact window focus and never use global delivery", async (t) => {
    const f = fixture(t);
    const o = await f.observe();
    f.state.windows[0]!.is_focused = false;
    await refusal(f.act(o, { kind: "key", combo: "cmd+s" }), "unsupported");
    f.state.windows[0]!.is_focused = true;
    // Real macOS output distinguishes the CLI command from its action label, and
    // headless exact-window keys may use PID-targeted synthetic delivery.
    f.state.override = async (input) => input.args[0] === "press" ? envelope("press", { action: "press_key",
      disposition: { delivery: "delivered_unverified", retry: "unsafe" },
      steps: [{ label: "CGEventPostToPid", outcome: "succeeded", mechanism: "physical_synthetic", verified: false }] }) : undefined;
    const result = await f.act(o, { kind: "key", combo: "cmd+s" });
    assert.equal(result.outcome, "dispatched");
    assert.equal(result.tierUsed, "attention");
    assert.deepEqual(f.calls.find(mutating)!.args, ["press", "cmd+s", "--window-id", window.id]);
  });
  test("captures only the selected window and preserves screenshot artifacts on dispose", async (t) => {
    const f = fixture(t);
    const o = await f.observe(true);
    assert.equal(o.scale, 2);
    assert.deepEqual(readFileSync(o.screenshot!.path), png);
    const home = f.calls[0]!.env.AGENT_DESKTOP_HOME!;
    assert.equal(statSync(home).mode & 0o777, 0o700);
    await f.backend.dispose();
    assert.equal(existsSync(home), false);
    assert.equal(existsSync(o.screenshot!.path), true);
  });
  test("isolates state per instance and scrubs inherited agent-desktop control variables", async (t) => {
    const prior = process.env.AGENT_DESKTOP_SESSION;
    process.env.AGENT_DESKTOP_SESSION = "unrelated-user-session";
    try {
      const f = fixture(t), other = fixture(t);
      await f.observe(); await other.observe();
      const env = f.calls[0]!.env;
      assert.deepEqual(Object.keys(env).filter((key) => key.startsWith("AGENT_DESKTOP_")), ["AGENT_DESKTOP_HOME"]);
      assert.notEqual(env.AGENT_DESKTOP_HOME, other.calls[0]!.env.AGENT_DESKTOP_HOME);
      await f.backend.dispose();
      assert.ok(existsSync(other.calls[0]!.env.AGENT_DESKTOP_HOME!));
    } finally { if (prior === undefined) delete process.env.AGENT_DESKTOP_SESSION; else process.env.AGENT_DESKTOP_SESSION = prior; }
  });
  test("maps only explicit not_delivered errors to refusals; preserves uncertain outcomes", async (t) => {
    const f = fixture(t);
    for (const delivery of ["not_delivered", "unknown", "delivery_uncertain", "delivered_unverified"]) {
      const o = await f.observe();
      f.state.override = async (input) => mutating(input) ? failed(input.args[0]!, delivery, "AMBIGUOUS_TARGET") : undefined;
      await assert.rejects(f.act(o, press(o)), (error: unknown) => {
        assert.equal(error instanceof BackendRefusal, delivery === "not_delivered");
        assert.ok(error instanceof Error);
        assert.ok(!error.message.includes("secret text"));
        return true;
      });
      await refusal(f.act(o, press(o)), "stale-ref");
    }
  });
  test("fails closed on mismatched envelopes, invalid delivery evidence and physical semantic reports", async (t) => {
    const f = fixture(t);
    const replies = [
      { version: "2.5", ok: true, command: "click", data: {} },
      { version: "2.6", ok: true, command: "type", data: {} },
      { version: "2.6", ok: true, command: "click", data: { action: "click" } },
      { version: "2.6", ok: true, command: "click", data: { action: "click", disposition: { delivery: "delivered_unverified" }, steps: [{ mechanism: "physical_synthetic" }] } },
    ];
    for (const reply of replies) {
      const o = await f.observe();
      f.state.override = async (input) => mutating(input) ? { stdout: JSON.stringify(reply), exitCode: 0 } : undefined;
      await assert.rejects(f.act(o, press(o)), (error: unknown) => error instanceof Error && !(error instanceof BackendRefusal));
    }
  });
  test("serializes concurrent observations so completion cannot revive stale refs", async (t) => {
    const f = fixture(t);
    const [target] = await f.backend.targets(call());
    const [first, last] = await Promise.all([f.backend.observe(call(), target!.targetId, {}), f.backend.observe(call(), target!.targetId, {})]);
    await refusal(f.act(first, press(first)), "stale-ref");
    await f.act(last, press(last));
  });
  test("late observations never publish refs and late actions never claim non-delivery", async (t) => {
    const f = fixture(t);
    const o = await f.observe();
    const readController = new AbortController();
    f.state.override = async (input) => {
      if (input.args[0] !== "snapshot") return;
      readController.abort("private cancellation details");
      return envelope("snapshot", {});
    };
    await assert.rejects(f.backend.observe(call({ signal: readController.signal }), o.targetId, {}), (error: unknown) =>
      error instanceof Error && !(error instanceof BackendRefusal) && !error.message.includes("private cancellation"));
    await refusal(f.act(o, press(o)), "stale-ref");
    f.state.override = undefined;
    const next = await f.observe();
    const writeController = new AbortController();
    f.state.override = async (input) => {
      if (!mutating(input)) return;
      writeController.abort();
      return envelope(input.args[0]!, { action: input.args[0], disposition: { delivery: "delivered_unverified" } });
    };
    await assert.rejects(f.act(next, press(next), allTiers, call({ signal: writeController.signal })), (error: unknown) => error instanceof Error && !(error instanceof BackendRefusal));
    await refusal(f.act(next, press(next)), "stale-ref");
  });
  test("expires queued calls before native dispatch and respects text byte limits", async (t) => {
    const f = fixture(t);
    const o = await f.observe();
    await refusal(f.act(o, press(o), allTiers, call({ deadline: Date.now() - 1 })), "unavailable");
    await refusal(f.act(o, { kind: "type", ref: o.ax![1]!.ref, text: "🦀".repeat(2501) }), "invalid-action");
    let release!: () => void;
    const paused = new Promise<void>((resolve) => { release = resolve; });
    f.state.override = async (input) => { if (input.args[0] === "status") await paused; return undefined; };
    const blocker = f.backend.availability(call());
    const queued = f.act(o, press(o), allTiers, call({ deadline: Date.now() + 10 }));
    const expired = refusal(queued, "unavailable");
    await new Promise((resolve) => setTimeout(resolve, 25));
    release();
    await blocker; await expired;
    assert.equal(f.calls.filter(mutating).length, 0);
  });
});

describe("agent-desktop subprocess delivery boundary", () => {
  const input = (source: string, overrides: Partial<AgentDesktopProcessInput> = {}): AgentDesktopProcessInput => ({ command: process.execPath,
    args: ["-e", source], env: process.env, signal: new AbortController().signal, deadline: Date.now() + 5_000, ...overrides });
  test("passes text through stdin without shell interpolation", async () => {
    const text = "$(not-a-command)\n--headed";
    const result = await runAgentDesktop(input("let s=''; process.stdin.on('data', c => s+=c); process.stdin.on('end',()=>process.stdout.write(s));", { stdin: text }));
    assert.equal(result.stdout, text);
  });
  test("bounded output and timeout fail as uncertain errors", async () => {
    await assert.rejects(runAgentDesktop(input("process.stdout.write('x'.repeat(5*1024*1024));")), /output limit/);
    await assert.rejects(runAgentDesktop(input("setInterval(()=>{},1000);", { deadline: Date.now() + 100 })), /deadline exceeded/);
  });
  test("cancellation after spawn is an ordinary error and handles early stdin close", async () => {
    const controller = new AbortController();
    const pending = runAgentDesktop(input("setInterval(()=>{},1000);", { signal: controller.signal }));
    setTimeout(() => controller.abort(), 50);
    await assert.rejects(pending, (error: unknown) => error instanceof Error && !(error instanceof BackendRefusal));
    const result = await runAgentDesktop(input("process.stdin.destroy(); process.stdout.write('refused');", { stdin: "x".repeat(128 * 1024) }));
    assert.equal(result.stdout, "refused");
  });
});
