import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { createCodexCuaBackend } from "./codex-cua.js";
import { BackendHost } from "./host.js";
import { BackendRefusal, type BackendCall, type BackendContext, type BackendSetupStep, type McpClient } from "./types.js";

const call = (): BackendCall => ({ requestId: "setup-test", caller: "test", deadline: Date.now() + 1_000, signal: new AbortController().signal });

function fixture(t: TestContext, options: { missing?: boolean; apps?: string[]; tools?: string[]; manifest?: unknown } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "codex-setup-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, ".mcp.json"), JSON.stringify(options.manifest ?? { mcpServers: { cua_repl: { command: "fake-cua" } } }));
  const calls: string[] = [];
  const ctx: BackendContext = {
    generation: "test", configPath: join(dir, "custom-backends.json"), shotsDir: dir,
    options: { apps: options.apps ?? ["com.apple.calculator"] },
    newestDir: () => options.missing ? null : dir,
    log: () => {}, refuse: (code, message) => new BackendRefusal(code, message),
    stdioMcp: async () => {
      calls.push("connect");
      return {
        serverInfo: { name: "cua_repl" },
        listTools: async () => (options.tools ?? ["js"]).map((name) => ({ name })),
        callTool: async (name) => {
          calls.push(name);
          return { content: [{ type: "text", text: "@@ACTION@@2" }] };
        },
        close: () => { calls.push("close"); },
      };
    },
  };
  const backend = createCodexCuaBackend(ctx);
  t.after(() => backend.dispose());
  return { backend, calls, dir, ctx };
}

function fakeClient(overrides: Partial<McpClient> = {}): McpClient {
  return {
    serverInfo: { name: "cua_repl" }, listTools: async () => [{ name: "js" }],
    callTool: async () => ({ content: [{ type: "text", text: "@@ACTION@@2" }] }),
    close: () => {}, ...overrides,
  };
}

describe("codex-cua setup", () => {
  test("reports installation and exact allow-list configuration together without spawning", async (t) => {
    const f = fixture(t, { missing: true, apps: [] });
    const status = await f.backend.availability(call());
    assert.equal(status.ready, false);
    assert.deepEqual(status.needs?.map((need) => need.kind), ["config", "install"]);
    assert.match(status.needs![0]!.detail, /\{"codex-cua":\{"apps":\["com.apple.calculator"\]\}\}/);
    assert.ok(status.needs![0]!.detail.includes(join(f.dir, "custom-backends.json")));
    assert.match(status.needs![1]!.detail, /ChatGPT desktop app/);
    assert.ok(status.needs!.every((need) => need.fix === "action setup codex-cua"));
    assert.deepEqual(f.calls, []);
  });

  test("missing cua_repl entry reports an install need", async (t) => {
    const f = fixture(t, { manifest: { mcpServers: {} } });
    const status = await f.backend.availability(call());
    assert.equal(status.needs?.[0]?.kind, "install");
    assert.match(status.reason ?? "", /mcpServers.cua_repl.command/);
    assert.deepEqual(f.calls, []);
  });

  test("a server without js is not a usable Computer Use install", async (t) => {
    const f = fixture(t, { tools: ["unrelated"] });
    const result = await f.backend.setup!(call(), { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.needs?.[0]?.kind, "install");
    assert.match(result.needs![0]!.detail, /does not expose js/);
    assert.deepEqual(f.calls, ["connect"]);
  });

  test("setup verifies the plugin and explicitly cannot grant macOS permissions", async (t) => {
    const f = fixture(t);
    const live: BackendSetupStep[] = [];
    const result = await f.backend.setup!({ ...call(), onSetupStep: (step) => live.push(step) }, { interactive: true });
    assert.equal(result.ready, true);
    assert.deepEqual(result.steps, live);
    assert.equal(result.steps[0]!.status, "skipped");
    assert.match(result.steps[0]!.detail ?? "", /cannot request or grant/);
    assert.equal(result.steps.at(-1)!.status, "done");
    assert.deepEqual(f.calls, ["connect", "js"]);
  });

  test("malformed app counts cannot make availability or setup ready", async (t) => {
    for (const count of [null, {}, "2", -1, 1.5, true, Number.MAX_SAFE_INTEGER + 1]) {
      const f = fixture(t);
      f.ctx.stdioMcp = async () => fakeClient({
        callTool: async () => ({ content: [{ type: "text", text: `@@ACTION@@${JSON.stringify(count)}` }] }),
      });
      const status = await f.backend.availability(call());
      assert.equal(status.ready, false, JSON.stringify(count));
      assert.match(status.reason ?? "", /invalid app count/);
      const setup = await f.backend.setup!(call(), { interactive: true });
      assert.equal(setup.ready, false, JSON.stringify(count));
      assert.equal(setup.steps.at(-1)?.status, "failed");
    }
  });

  test("configuration waits on the user without creating approvals or running the driver", async (t) => {
    const f = fixture(t, { apps: [] });
    const result = await f.backend.setup!(call(), { interactive: false });
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)!.status, "waiting-on-user");
    assert.deepEqual(f.calls, []);
  });

  test("pre-cancelled setup never starts the plugin", async (t) => {
    const f = fixture(t);
    const result = await f.backend.setup!({ ...call(), signal: AbortSignal.abort() }, { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)!.status, "failed");
    assert.deepEqual(f.calls, []);
  });

  test("cancelling unresolved initialization returns promptly and closes a late client", async (t) => {
    const f = fixture(t);
    const controller = new AbortController();
    let finishInitialization!: (value: McpClient) => void;
    let connected = 0;
    let closed = 0;
    f.ctx.stdioMcp = async (opts) => {
      connected += 1;
      assert.ok(opts.signal);
      assert.ok(opts.timeoutMs! <= 1_000);
      if (connected > 1) return fakeClient();
      return await new Promise<McpClient>((resolve) => { finishInitialization = resolve; });
    };
    const pending = f.backend.setup!({ ...call(), signal: controller.signal }, { interactive: true });
    controller.abort();
    const result = await pending;
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)?.status, "failed");
    finishInitialization(fakeClient({ close: () => { closed += 1; } }));
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(closed, 1, "late initialization is closed exactly once");
    assert.equal((await f.backend.availability(call())).ready, true, "cancelled initialization is not cached");
    assert.equal(connected, 2);
  });

  test("cancelling unresolved tool discovery closes the client and cannot report ready", async (t) => {
    const f = fixture(t);
    const controller = new AbortController();
    let beginDiscovery!: () => void;
    const discovering = new Promise<void>((resolve) => { beginDiscovery = resolve; });
    let closed = 0;
    let invoked = 0;
    f.ctx.stdioMcp = async () => fakeClient({
      listTools: async (opts) => {
        assert.ok(opts?.signal);
        assert.ok(opts.timeoutMs! <= 1_000);
        beginDiscovery();
        return await new Promise(() => {});
      },
      callTool: async () => { invoked += 1; return {}; },
      close: () => { closed += 1; },
    });
    const pending = f.backend.setup!({ ...call(), signal: controller.signal }, { interactive: true });
    await discovering;
    controller.abort();
    const result = await pending;
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)?.status, "failed");
    assert.equal(closed, 1);
    assert.equal(invoked, 0);
  });

  test("a direct deadline bounds tool discovery even when the caller supplied no timeout signal", async (t) => {
    const f = fixture(t);
    let closed = 0;
    f.ctx.stdioMcp = async () => fakeClient({
      listTools: async () => await new Promise(() => {}),
      close: () => { closed += 1; },
    });
    const result = await f.backend.availability({ ...call(), deadline: Date.now() + 25 });
    assert.equal(result.ready, false);
    assert.match(result.reason ?? "", /deadline expired/);
    assert.equal(closed, 1);
  });

  test("a fake tool returning success after cancellation cannot make setup ready", async (t) => {
    const f = fixture(t);
    const controller = new AbortController();
    f.ctx.stdioMcp = async () => fakeClient({ callTool: async () => {
      controller.abort();
      return { content: [{ type: "text", text: "@@ACTION@@2" }] };
    } });
    const result = await f.backend.setup!({ ...call(), signal: controller.signal }, { interactive: true });
    assert.equal(result.ready, false);
    assert.equal(result.steps.at(-1)?.status, "failed");
  });
});

test("BackendHost.setup forwards progress, interactivity and a two-minute default budget", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "host-setup-test-"));
  const controller = new AbortController();
  const live: BackendSetupStep[] = [];
  const host = new BackendHost({ configPath: join(dir, "absent.json"), shotsDir: dir, backends: {
    fake: { summary: "fake", factory: () => ({
      schema: 1, capabilities: { surfaces: ["computer"], observe: { ax: false, screenshot: false }, actions: {} },
      availability: async () => ({ ready: false }), targets: async () => [],
      observe: async () => { throw new Error("unexpected"); }, act: async () => { throw new Error("unexpected"); }, dispose: async () => {},
      setup: async (request, opts) => {
        assert.equal(opts.interactive, false);
        assert.ok(request.deadline - Date.now() > 119_000);
        assert.ok(request.deadline - Date.now() <= 120_000);
        controller.abort();
        assert.equal(request.signal.aborted, true);
        const step: BackendSetupStep = { step: "test", status: "skipped" };
        request.onSetupStep?.(step);
        return { ready: false, steps: [step] };
      },
    }) },
  } });
  t.after(async () => { await host.dispose(); rmSync(dir, { recursive: true, force: true }); });
  const result = await host.setup("fake", { signal: controller.signal, onSetupStep: (step) => live.push(step) }, { interactive: false });
  assert.deepEqual(result.steps, live);
});
