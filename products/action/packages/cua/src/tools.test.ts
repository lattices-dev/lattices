import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { describe, test, type TestContext } from "node:test";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { runCli, selectNode, selectTarget } from "./cli.js";
import { BackendHost } from "./host.js";
import { cuaHandlers, cuaTools } from "./tools.js";
import {
  BackendRefusal,
  type Backend,
  type BackendAction,
  type BackendObservation,
  type BackendTarget,
  type BackendTier,
} from "./types.js";

function body<T extends object = Record<string, unknown>>(reply: CallToolResult): T {
  assert.ok(reply.structuredContent && typeof reply.structuredContent === "object");
  const text = reply.content.find((item) => item.type === "text");
  assert.ok(text && text.type === "text");
  assert.deepEqual(JSON.parse(text.text), reply.structuredContent, "text and structured replies agree");
  return reply.structuredContent as T;
}

function fixture(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "action-cua-tools-"));
  const state: {
    initialized: string[];
    events: string[];
    acts: Array<{ backend: string; targetId: string; action: BackendAction; observationId: string; allowTiers: BackendTier[] }>;
    observed: Array<{ targetId: string; screenshot?: boolean }>;
    actError?: unknown;
    unavailable?: string;
    tierUsed?: BackendTier;
  } = { initialized: [], events: [], acts: [], observed: [] };
  const registry = Object.fromEntries(["fake-cua", "action-cua"].map((id) => [id, {
    summary: `${id} test backend`,
    factory: (ctx: { generation: string }): Backend => {
      state.initialized.push(id);
      const targetId = `${ctx.generation}:${id}:window`;
      const observation: BackendObservation = {
        observationId: `${ctx.generation}-${id}-1`,
        targetId,
        at: 123,
        ax: [
          { ref: `${ctx.generation}-${id}-1.1`, depth: 1, role: "AXRadioButton", label: "Docs", actions: ["AXPress"] },
          { ref: `${ctx.generation}-${id}-1.2`, depth: 1, role: "AXTextField", label: "Search", settable: true },
        ],
      };
      return {
        schema: 1,
        capabilities: {
          surfaces: ["computer"],
          observe: { ax: true, screenshot: true },
          actions: { press: "semantic", setValue: "semantic", key: "attention", click: "attention", scroll: "attention" },
        },
        async availability() {
          state.events.push(`${id}:status`);
          if (state.unavailable === id) throw new Error("driver unavailable");
          return { ready: true, version: "test-1" };
        },
        async targets() {
          state.events.push(`${id}:targets`);
          return [{ targetId, app: "Google Chrome", bundleId: "com.google.Chrome", title: "Docs" }];
        },
        async observe(_call, requestedTargetId, opts) {
          state.events.push(`${id}:observe`);
          assert.equal(requestedTargetId, targetId);
          state.observed.push({ targetId: requestedTargetId, ...opts });
          return observation;
        },
        async act(_call, requestedTargetId, action, opts) {
          state.events.push(`${id}:act`);
          state.acts.push({ backend: id, targetId: requestedTargetId, action, ...opts });
          if (state.actError !== undefined) throw state.actError;
          return {
            outcome: "dispatched",
            tierUsed: state.tierUsed ?? (action.kind === "press" || action.kind === "setValue" ? "semantic" : "attention"),
            mechanism: "fake:delivery",
            observation,
          };
        },
        async dispose() { state.events.push(`${id}:dispose`); },
      };
    },
  }]));
  const host = new BackendHost({
    backends: registry,
    configPath: join(dir, "absent.json"),
    shotsDir: join(dir, "shots"),
    log: () => {},
  });
  t.after(async () => {
    await host.dispose();
    rmSync(dir, { recursive: true, force: true });
  });
  const handlers = cuaHandlers(host);
  const actArgs = (action: unknown = { kind: "press", ref: `${host.generation}-fake-cua-1.1` }) => ({
    backend: "fake-cua",
    targetId: `${host.generation}:fake-cua:window`,
    observationId: `${host.generation}-fake-cua-1`,
    action,
  });
  return { host, handlers, state, actArgs };
}

describe("standalone CUA tools", () => {
  test("lists six tools from the host registry without starting a backend", (t) => {
    const { host, state } = fixture(t);
    const tools = cuaTools(host);
    assert.deepEqual(tools.map((tool) => tool.name), ["cua_status", "cua_setup", "cua_ask", "cua_targets", "cua_observe", "cua_act"]);
    for (const tool of tools) {
      const backend = tool.inputSchema.properties?.backend as { enum?: string[] };
      assert.deepEqual(backend.enum, ["fake-cua", "action-cua"]);
      assert.equal(tool.inputSchema.properties?.leaseId, undefined);
    }
    assert.deepEqual(state.initialized, []);
    assert.deepEqual(tools.find((tool) => tool.name === "cua_act")!.inputSchema.required,
      ["backend", "targetId", "observationId", "action"]);
  });

  test("status includes each registered backend, its capabilities, and defaults", async (t) => {
    const { host, handlers } = fixture(t);
    const reply = await handlers.cua_status!({});
    assert.notEqual(reply.isError, true);
    const result = body<{ generation: string; defaultAllowTiers: string[]; backends: Array<{ backend: string; ready: boolean; version: string; tiers: Record<string, string> }> }>(reply);
    assert.equal(result.generation, host.generation);
    assert.deepEqual(result.defaultAllowTiers, ["observe", "semantic"]);
    assert.deepEqual(result.backends.map((backend) => backend.backend), host.ids());
    for (const backend of result.backends) {
      assert.equal(backend.ready, true);
      assert.equal(backend.version, "test-1");
      assert.equal(backend.tiers.key, "attention");
    }
  });

  test("setup is a mutating tool and reports availability when a backend has no setup hook", async (t) => {
    const { host, handlers, state } = fixture(t);
    const tool = cuaTools(host).find((item) => item.name === "cua_setup")!;
    assert.equal(tool.annotations?.readOnlyHint, false);
    assert.deepEqual(tool.inputSchema.required, ["backend"]);
    assert.match(tool.description ?? "", /System Settings/);
    const result = body<{ ok: boolean; backend: string; ready: boolean; steps: unknown[] }>(await handlers.cua_setup!({ backend: "fake-cua" }));
    assert.equal(result.ok, true);
    assert.equal(result.backend, "fake-cua");
    assert.equal(result.ready, true);
    assert.ok(Array.isArray(result.steps));
    assert.deepEqual(state.events, ["fake-cua:status"]);
  });

  test("status can select one backend and isolates an unavailable driver", async (t) => {
    const { handlers, state } = fixture(t);
    state.unavailable = "action-cua";
    const one = body<{ backends: Array<{ backend: string; ready: boolean; reason: string }> }>(await handlers.cua_status!({ backend: "action-cua" }));
    assert.deepEqual(state.initialized, ["action-cua"]);
    assert.equal(one.backends.length, 1);
    assert.equal(one.backends[0]!.ready, false);
    assert.match(one.backends[0]!.reason, /driver unavailable/);
    const all = body<{ backends: Array<{ backend: string; ready: boolean }> }>(await handlers.cua_status!({}));
    assert.equal(all.backends.find((backend) => backend.backend === "fake-cua")!.ready, true);
  });

  test("targets and observe route to the named backend with screenshot options", async (t) => {
    const { handlers, state, host } = fixture(t);
    const listed = body<{ targets: BackendTarget[] }>(await handlers.cua_targets!({ backend: "action-cua" }));
    assert.equal(listed.targets[0]!.targetId, `${host.generation}:action-cua:window`);
    const observed = body<{ observation: BackendObservation }>(await handlers.cua_observe!({
      backend: "action-cua", targetId: listed.targets[0]!.targetId, screenshot: true,
    }));
    assert.equal(observed.observation.ax![0]!.label, "Docs");
    assert.deepEqual(state.observed, [{ targetId: listed.targets[0]!.targetId, screenshot: true }]);
    assert.deepEqual(state.initialized, ["action-cua"]);
  });

  test("an unknown backend is refused without selecting a fallback", async (t) => {
    const { handlers, state } = fixture(t);
    const reply = await handlers.cua_targets!({ backend: "missing-cua" });
    assert.equal(reply.isError, true);
    assert.equal(body(reply).code, "unsupported");
    assert.deepEqual(state.initialized, []);
  });

  test("attention is refused by default before a backend receives an action", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    const reply = await handlers.cua_act!(actArgs({ kind: "key", combo: "cmd+l" }));
    assert.equal(reply.isError, true);
    const result = body(reply);
    assert.equal(result.code, "tier-not-allowed");
    assert.deepEqual(result.delivery, { status: "not_delivered" });
    assert.deepEqual(state.acts, []);
  });

  test("explicit attention permission allows delivery without claiming verification", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    const reply = await handlers.cua_act!({ ...actArgs({ kind: "key", combo: "cmd+l" }), allowTiers: ["attention"] });
    assert.notEqual(reply.isError, true);
    const result = body<{ result: { delivery: unknown; tierDeclared: string; tierUsed: string }; drive?: unknown }>(reply);
    assert.deepEqual(result.result.delivery, { status: "delivered_unverified" });
    assert.equal(result.result.tierDeclared, "attention");
    assert.equal(result.result.tierUsed, "attention");
    assert.equal(result.drive, undefined);
    assert.equal(state.acts.length, 1);
    assert.deepEqual(state.acts[0]!.allowTiers, ["observe", "attention"]);
  });

  test("semantic actions use the default tiers and preserve the post-action observation", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    const reply = await handlers.cua_act!(actArgs());
    assert.notEqual(reply.isError, true);
    const result = body<{ observation: BackendObservation; result: { status: string; mechanism: string; delivery: unknown } }>(reply);
    assert.equal(result.result.status, "succeeded");
    assert.equal(result.result.mechanism, "fake:delivery");
    assert.equal(result.observation.targetId, actArgs().targetId);
    assert.deepEqual(result.result.delivery, { status: "delivered_unverified" });
    assert.deepEqual(state.acts[0]!.allowTiers, ["observe", "semantic"]);
  });

  test("a stale BackendRefusal returns not_delivered and the replacement observation", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    const fresh: BackendObservation = { observationId: "fresh-2", targetId: actArgs().targetId, at: 456, ax: [] };
    state.actError = new BackendRefusal("stale-ref", "The element moved.", fresh);
    const reply = await handlers.cua_act!(actArgs());
    assert.equal(reply.isError, true);
    const result = body(reply);
    assert.equal(result.code, "stale-ref");
    assert.equal(result.message, "The element moved.");
    assert.deepEqual(result.delivery, { status: "not_delivered" });
    assert.deepEqual(result.observation, fresh);
    assert.equal(state.acts.length, 1, "the refusal is surfaced without retrying");
  });

  test("an ordinary thrown error returns delivery_uncertain and does not retry", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    state.actError = new Error("driver disconnected after dispatch");
    const reply = await handlers.cua_act!(actArgs());
    assert.equal(reply.isError, true);
    const result = body(reply);
    assert.equal(result.code, "backend-error");
    assert.equal(result.message, "driver disconnected after dispatch");
    assert.deepEqual(result.delivery, { status: "delivery_uncertain" });
    assert.equal(state.acts.length, 1);
  });

  test("malformed acts and invalid tier lists are refused before dispatch", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    for (const args of [actArgs({ kind: "press" }), { ...actArgs(), allowTiers: ["all"] }, { ...actArgs(), observationId: "" }]) {
      const reply = await handlers.cua_act!(args);
      assert.equal(reply.isError, true);
      assert.equal(body(reply).code, "invalid-action");
      assert.deepEqual(body(reply).delivery, { status: "not_delivered" });
    }
    assert.deepEqual(state.acts, []);
  });

  test("reports a backend's unexpected higher tier without treating delivery as a refusal", async (t) => {
    const { handlers, state, actArgs } = fixture(t);
    state.tierUsed = "attention";
    const reply = await handlers.cua_act!(actArgs());
    assert.notEqual(reply.isError, true);
    const result = body<{ result: { tierDeclared: string; tierUsed: string; tierExceeded: boolean; delivery: unknown } }>(reply);
    assert.equal(result.result.tierDeclared, "semantic");
    assert.equal(result.result.tierUsed, "attention");
    assert.equal(result.result.tierExceeded, true);
    assert.deepEqual(result.result.delivery, { status: "delivered_unverified" });
  });
});

describe("CLI target selection", () => {
  const targets: BackendTarget[] = [
    { targetId: "generation:1", app: "Google Chrome", bundleId: "com.google.Chrome", title: "Project Docs" },
    { targetId: "generation:2", app: "Google Chrome", bundleId: "com.google.Chrome", title: "Inbox" },
    { targetId: "generation:3", app: "Calculator", bundleId: "com.apple.calculator", title: "Calculator" },
  ];

  test("matches an exact bundle id, case-insensitive app name, or title regex", () => {
    assert.equal(selectTarget(targets, "com.apple.calculator").targetId, "generation:3");
    assert.equal(selectTarget(targets, "CALCULATOR").targetId, "generation:3");
    const windows = [{ targetId: "0123abcd:com.google.Chrome:50:201", bundleId: "com.google.Chrome", app: "Google Chrome", title: "Personal" },
      { targetId: "0123abcd:com.google.Chrome:50:202", bundleId: "com.google.Chrome", app: "Google Chrome", title: "Work" }];
    // A targetId from an earlier run (another generation) or without one still names its window.
    assert.equal(selectTarget(windows, "deadbeef:com.google.Chrome:50:202").title, "Work");
    assert.equal(selectTarget(windows, "com.google.Chrome:50:201").title, "Personal");
    assert.equal(selectTarget(targets, "^project.*docs$").targetId, "generation:1");
  });

  test("ambiguous matches list the candidates and require --first", () => {
    assert.throws(() => selectTarget(targets, "chrome"), (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.match(error.message, /Project Docs/);
      assert.match(error.message, /Inbox/);
      return true;
    });
    assert.equal(selectTarget(targets, "chrome", { first: true }).targetId, "generation:1");
    assert.throws(() => selectTarget(targets, "com.google.Chrome"), Error);
  });

  test("window titles select one process/window and bundle ambiguity lists every window identity", () => {
    const windows: BackendTarget[] = [
      { targetId: "generation:com.google.Chrome:42:101", pid: 42, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Personal Inbox" },
      { targetId: "generation:com.google.Chrome:84:202", pid: 84, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Agent Project Docs" },
      { targetId: "generation:com.google.Chrome:84:203", pid: 84, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Agent Preview" },
    ];
    assert.equal(selectTarget(windows, "^agent.*docs$").targetId, windows[1]!.targetId);
    assert.throws(() => selectTarget(windows, "com.google.Chrome"), (error: unknown) => {
      assert.ok(error instanceof BackendRefusal);
      assert.equal(error.code, "unknown-target");
      assert.match(error.message, /3 targets match/);
      for (const window of windows) {
        assert.ok(error.message.includes(window.title!));
        assert.ok(error.message.includes(window.targetId));
      }
      return true;
    });
  });

  test("no matches list available candidates; old target ids are not selectors", () => {
    for (const selector of ["Mail", "generation:1"]) {
      assert.throws(() => selectTarget(targets, selector), (error: unknown) => {
        assert.ok(error instanceof Error);
        assert.match(error.message, /Google Chrome/);
        assert.match(error.message, /Calculator/);
        return true;
      });
    }
  });

  test("refuses invalid selector regex", () => {
    assert.throws(() => selectTarget(targets, "["), Error);
  });
});

describe("CLI node selection", () => {
  const nodes = [
    { ref: "current.1", depth: 1, role: "AXButton", label: "Save" },
    { ref: "current.2", depth: 1, role: "AXMenuItem", label: "Save" },
    { ref: "current.3", depth: 1, role: "AXButton", label: "Save copy" },
  ];

  test("uses labels, exact roles, and a one-based occurrence", () => {
    assert.equal(selectNode(nodes, "^save$", { role: "AXButton" }).ref, "current.1");
    assert.equal(selectNode(nodes, "^save$", { nth: 2 }).ref, "current.2");
    assert.equal(selectNode(nodes, "copy$").ref, "current.3");
  });

  test("refuses ambiguous, absent, and out-of-range selections", () => {
    assert.throws(() => selectNode(nodes, "^save$"), Error);
    assert.throws(() => selectNode(nodes, "missing"), Error);
    assert.throws(() => selectNode(nodes, "save", { nth: 0 }), Error);
    assert.throws(() => selectNode(nodes, "save", { nth: 4 }), Error);
  });
});

describe("CLI action workflow", () => {
  test("press discovers and observes its target before sending a ref from that process", async (t) => {
    const { host, state } = fixture(t);
    const stdout: string[] = [];
    const stderr: string[] = [];
    const code = await runCli(["press", "fake-cua", "chrome", "--label", "^Docs$", "--role", "AXRadioButton", "--json"], {
      host, stdout: (text) => stdout.push(text), stderr: (text) => stderr.push(text),
    });
    assert.equal(code, 0, stderr.join(""));
    assert.deepEqual(state.events, ["fake-cua:status", "fake-cua:targets", "fake-cua:observe", "fake-cua:act", "fake-cua:dispose"]);
    assert.deepEqual(state.acts[0]!.action, { kind: "press", ref: `${host.generation}-fake-cua-1.1` });
    assert.equal(state.acts[0]!.observationId, `${host.generation}-fake-cua-1`);
    assert.equal(state.acts[0]!.targetId, `${host.generation}:fake-cua:window`);
    assert.equal(JSON.parse(stdout.join("")).result.delivery.status, "delivered_unverified");
  });

  test("set resolves its ref in the same process and preserves an empty value", async (t) => {
    const { host, state } = fixture(t);
    const code = await runCli(["set", "fake-cua", "chrome", "--label", "^Search$", "--value", "", "--json"], {
      host, stdout: () => {}, stderr: () => {},
    });
    assert.equal(code, 0);
    assert.deepEqual(state.events, ["fake-cua:status", "fake-cua:targets", "fake-cua:observe", "fake-cua:act", "fake-cua:dispose"]);
    assert.deepEqual(state.acts[0]!.action, { kind: "setValue", ref: `${host.generation}-fake-cua-1.2`, value: "" });
  });

  test("generic point actions observe a screenshot and add explicitly allowed tiers", async (t) => {
    const { host, state } = fixture(t);
    const code = await runCli(["act", "fake-cua", "chrome", '{"kind":"click","point":{"x":10,"y":20}}', "--allow", "attention", "--json"], {
      host, stdout: () => {}, stderr: () => {},
    });
    assert.equal(code, 0);
    assert.deepEqual(state.events, ["fake-cua:status", "fake-cua:targets", "fake-cua:observe", "fake-cua:act", "fake-cua:dispose"]);
    assert.equal(state.observed[0]!.screenshot, true);
    assert.deepEqual(state.acts[0]!.allowTiers, ["observe", "semantic", "attention"]);
  });

  test("generic ref actions resolve --label against the fresh observation", async (t) => {
    const { host, state } = fixture(t);
    const code = await runCli(["act", "fake-cua", "chrome", '{"kind":"press"}', "--label", "^Docs$", "--json"], {
      host, stdout: () => {}, stderr: () => {},
    });
    assert.equal(code, 0);
    assert.deepEqual(state.acts[0]!.action, { kind: "press", ref: `${host.generation}-fake-cua-1.1` });
  });

  test("a raw ref from another process cannot be passed through generic act", async (t) => {
    const { host, state } = fixture(t);
    const stdout: string[] = [];
    const code = await runCli(["act", "fake-cua", "chrome", '{"kind":"press","ref":"old-generation-1.1"}', "--json"], {
      host, stdout: (text) => stdout.push(text), stderr: () => {},
    });
    assert.equal(code, 1);
    assert.deepEqual(state.acts, []);
    assert.equal(JSON.parse(stdout.join("")).delivery.status, "not_delivered");
  });

  test("attention remains gated in CLI and JSON reports the refusal", async (t) => {
    const { host, state } = fixture(t);
    const stdout: string[] = [];
    const code = await runCli(["act", "fake-cua", "chrome", '{"kind":"key","combo":"cmd+l"}', "--json"], {
      host, stdout: (text) => stdout.push(text), stderr: () => {},
    });
    assert.equal(code, 1);
    assert.deepEqual(state.acts, []);
    assert.equal(JSON.parse(stdout.join("")).code, "tier-not-allowed");
    assert.equal(state.events.at(-1), "fake-cua:dispose");
  });
});

describe("MCP lifecycle", () => {
  for (const reason of ["stdin", "SIGINT", "SIGTERM"] as const) {
    test(`disposes its backend when ${reason} closes the server`, async (t) => {
      const dir = mkdtempSync(join(tmpdir(), "action-cua-mcp-"));
      const script = `
        import { BackendHost } from ${JSON.stringify(new URL("./host.ts", import.meta.url).href)};
        import { serveMcp } from ${JSON.stringify(new URL("./mcp.ts", import.meta.url).href)};
        const host = new BackendHost({
          configPath: ${JSON.stringify(join(dir, "absent.json"))},
          shotsDir: ${JSON.stringify(join(dir, "shots"))},
          backends: { "fake-cua": { summary: "lifecycle test", factory: () => ({
            schema: 1,
            capabilities: { surfaces: ["computer"], observe: { ax: true, screenshot: false }, actions: {} },
            availability: async () => ({ ready: true }),
            targets: async () => [],
            observe: async () => { throw new Error("unexpected observation"); },
            act: async () => { throw new Error("unexpected action"); },
            dispose: async () => { process.stderr.write("BACKEND_DISPOSED\\n"); }
          }) } }
        });
        await serveMcp({ host });
        process.stderr.write("SERVER_CLOSED\\n");
      `;
      const child = spawn(process.execPath, ["--eval", script], { stdio: ["pipe", "pipe", "pipe"] });
      const pending = new Map<number, { resolve: (reply: Record<string, unknown>) => void; reject: (error: Error) => void }>();
      let stderr = "";
      let protocolError: unknown;
      const lines = createInterface({ input: child.stdout! });
      lines.on("line", (line) => {
        try {
          const reply = JSON.parse(line) as Record<string, unknown>;
          const waiter = pending.get(Number(reply.id));
          if (waiter) {
            pending.delete(Number(reply.id));
            waiter.resolve(reply);
          }
        } catch (error) { protocolError = error; }
      });
      child.stderr!.setEncoding("utf8");
      child.stderr!.on("data", (chunk: string) => { stderr += chunk; });
      const exited = new Promise<{ code: number | null; signal: string | null }>((resolve, reject) => {
        child.once("error", reject);
        child.once("close", (code, signal) => {
          for (const waiter of pending.values()) waiter.reject(new Error(`server exited before responding: ${stderr}`));
          pending.clear();
          resolve({ code, signal });
        });
      });
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        for (const waiter of pending.values()) waiter.reject(new Error(`MCP lifecycle timed out: ${stderr}`));
        pending.clear();
      }, 10_000);
      t.after(async () => {
        clearTimeout(timer);
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        await exited.catch(() => {});
        lines.close();
        rmSync(dir, { recursive: true, force: true });
      });
      const request = (id: number, method: string, params: Record<string, unknown>) => new Promise<Record<string, unknown>>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        child.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });
      const initialized = await request(1, "initialize", {
        protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lifecycle-test", version: "1" },
      });
      assert.equal(initialized.error, undefined);
      child.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
      const status = await request(2, "tools/call", { name: "cua_status", arguments: {} });
      assert.equal(status.error, undefined);
      assert.equal(body(status.result as CallToolResult).ok, true);
      if (reason === "stdin") child.stdin!.end();
      else child.kill(reason);
      const exit = await exited;
      assert.deepEqual(exit, { code: 0, signal: null }, stderr);
      assert.equal(protocolError, undefined, "stdout contains only JSON protocol messages");
      assert.equal(stderr.split("BACKEND_DISPOSED").length - 1, 1, stderr);
      assert.match(stderr, /SERVER_CLOSED/);
    });
  }
});
