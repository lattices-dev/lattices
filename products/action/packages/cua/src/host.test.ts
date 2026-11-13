import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BackendHost, parseAllowTiers, parseBackendAction } from "./host.js";
import { stdioMcp } from "./stdio-mcp.js";
import { BackendRefusal, type McpClient, type McpToolResult, type StdioMcpOptions } from "./types.js";

const scratch = () => mkdtempSync(join(tmpdir(), "action-backends-"));

function hostWith(config: Record<string, unknown>, fake: (opts: StdioMcpOptions) => McpClient) {
  const dir = scratch();
  const configPath = join(dir, "backends.json");
  writeFileSync(configPath, JSON.stringify(config));
  const spawned: StdioMcpOptions[] = [];
  const host = new BackendHost({
    configPath,
    shotsDir: join(dir, "shots"),
    log: () => {},
    stdioMcp: async (opts) => {
      spawned.push(opts);
      return fake(opts);
    },
  });
  return { host, spawned };
}

const json = (body: unknown): McpToolResult => ({ structuredContent: body });

async function refusal(promise: Promise<unknown>, code: string): Promise<BackendRefusal> {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof BackendRefusal, `expected a BackendRefusal, got ${error}`);
    assert.equal(error.code, code, error.message);
    return error;
  }
  assert.fail(`expected a ${code} refusal`);
}

describe("parseBackendAction", () => {
  test("accepts each kind and refuses malformed ones", () => {
    assert.deepEqual(parseBackendAction({ kind: "press", ref: "g-1.4" }), { kind: "press", ref: "g-1.4" });
    assert.deepEqual(parseBackendAction({ kind: "scroll", point: { x: 1, y: 2 }, direction: "down" }), { kind: "scroll", direction: "down", point: { x: 1, y: 2 } });
    assert.throws(() => parseBackendAction({ kind: "drag" }), BackendRefusal);
    assert.throws(() => parseBackendAction({ kind: "press" }), BackendRefusal);
    assert.throws(() => parseBackendAction({ kind: "scroll", direction: "down" }), BackendRefusal);
    assert.throws(() => parseBackendAction({ kind: "click", point: { x: 1, y: 2 }, button: "middle" }), BackendRefusal);
  });

  test("allowTiers defaults to observe and semantic, and always keeps observe", () => {
    assert.deepEqual(parseAllowTiers(undefined), ["observe", "semantic"]);
    assert.deepEqual(parseAllowTiers(["attention"]), ["observe", "attention"]);
    assert.throws(() => parseAllowTiers(["everything"]), BackendRefusal);
  });
});

describe("BackendHost", () => {
  test("an unknown backend is refused, not substituted", async () => {
    const { host } = hostWith({}, () => { throw new Error("never spawned"); });
    await refusal(host.targets("vision-magic"), "unsupported");
  });
});

describe("trycua-cua backend", () => {
  function driver(opts: { legacy?: boolean } = {}) {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    let snapshot = 0;
    const client: McpClient = {
      serverInfo: { name: "cua-driver", version: "0.9.0" },
      listTools: async () => [],
      close: () => {},
      async callTool(name, args = {}) {
        calls.push({ name, args });
        switch (name) {
          case "list_windows": return json({ windows: [{ window_id: 7, pid: 42, app_name: "Calculator", title: "Calculator", is_on_screen: true, z_index: 0, layer: 0 }] });
          case "list_apps": return json({ apps: [{ pid: 42, name: "Calculator", running: true, active: false, bundle_id: "com.apple.calculator" }] });
          case "get_window_state":
            if (opts.legacy && "tree_format" in args) return { isError: true, content: [{ type: "text", text: "unknown field `tree_format`" }] };
            snapshot += 1;
            return json({
              pid: 42,
              window_id: 7,
              elements: [
                { element_index: 1, role: "AXButton", depth: 1, element_token: `t${snapshot}-1`, label: "7", actions: ["AXPress"] },
                { element_index: 2, role: "AXStaticText", depth: 1, element_token: `t${snapshot}-2`, value: "0" },
              ],
            });
          case "click": return json({ route: "accessibility", delivery: { mode: "background" }, effect: "confirmed" });
          case "type_text": return json({ route: "cgevent", delivery: { mode: "background" } });
          default: return { isError: true, content: [{ type: "text", text: `no ${name}` }] };
        }
      },
    };
    return { calls, client };
  }

  test("telemetry is off on the spawned driver unless the operator opts in", async () => {
    const { client } = driver();
    const { host, spawned } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    await host.targets("trycua-cua");
    assert.equal(spawned[0]!.env?.CUA_DRIVER_RS_TELEMETRY_ENABLED, "false");
    assert.deepEqual(spawned[0]!.args, ["mcp"]);
  });

  test("press goes out as an AX press on the observed element token", async () => {
    const { calls, client } = driver();
    const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    const [target] = await host.targets("trycua-cua");
    assert.match(target!.targetId, new RegExp(`^${host.generation}:42:7$`));
    const observation = await host.observe("trycua-cua", target!.targetId, false);
    const button = observation.ax!.find((node) => node.label === "7")!;
    const result = await host.act("trycua-cua", target!.targetId, { kind: "press", ref: button.ref }, { observationId: observation.observationId, allowTiers: ["observe", "semantic"] });
    assert.equal(result.tierUsed, "semantic");
    assert.equal(result.tierExceeded, false);
    assert.deepEqual(calls.at(-1), { name: "click", args: { pid: 42, element_token: "t1-1", action: "press" } });
  });

  test("observe asks for the elements array, and asks a driver without tree_format again plainly", async () => {
    for (const legacy of [false, true]) {
      const { calls, client } = driver({ legacy });
      const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
      const [target] = await host.targets("trycua-cua");
      const observation = await host.observe("trycua-cua", target!.targetId, false);
      assert.ok(observation.ax!.some((node) => node.label === "7"));
      const reads = calls.filter((call) => call.name === "get_window_state");
      assert.equal(reads[0]!.args.tree_format, "elements");
      assert.equal(reads.length, legacy ? 2 : 1);
      if (legacy) assert.equal("tree_format" in reads[1]!.args, false);
    }
  });

  test("press on an element without AXPress is refused before the driver could fall back to a pixel click", async () => {
    const { calls, client } = driver();
    const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    const [target] = await host.targets("trycua-cua");
    const observation = await host.observe("trycua-cua", target!.targetId, false);
    const text = observation.ax!.find((node) => node.role === "AXStaticText")!;
    await refusal(host.act("trycua-cua", target!.targetId, { kind: "press", ref: text.ref }, { observationId: observation.observationId, allowTiers: ["observe", "semantic"] }), "unsupported");
    assert.equal(calls.filter((call) => call.name === "click").length, 0);
  });

  test("a ref from an older observation is refused with a fresh observation", async () => {
    const { client } = driver();
    const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    const [target] = await host.targets("trycua-cua");
    const first = await host.observe("trycua-cua", target!.targetId, false);
    await host.observe("trycua-cua", target!.targetId, false);
    const stale = await refusal(host.act("trycua-cua", target!.targetId, { kind: "press", ref: first.ax![0]!.ref }, { observationId: first.observationId, allowTiers: ["observe", "semantic"] }), "stale-ref");
    assert.ok(stale.observation && stale.observation.observationId !== first.observationId);
  });

  test("typing is attention, so the default allow list refuses it without calling the driver", async () => {
    const { calls, client } = driver();
    const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    const [target] = await host.targets("trycua-cua");
    const observation = await host.observe("trycua-cua", target!.targetId, false);
    await refusal(host.act("trycua-cua", target!.targetId, { kind: "type", text: "12" }, { observationId: observation.observationId, allowTiers: parseAllowTiers(undefined) }), "tier-not-allowed");
    assert.equal(calls.filter((call) => call.name === "type_text").length, 0);
    const allowed = await host.act("trycua-cua", target!.targetId, { kind: "type", text: "12" }, { observationId: observation.observationId, allowTiers: parseAllowTiers(["attention"]) });
    assert.equal(allowed.tierUsed, "attention");
  });

  test("a target from another generation is refused", async () => {
    const { client } = driver();
    const { host } = hostWith({ "trycua-cua": { command: process.execPath } }, () => client);
    await refusal(host.observe("trycua-cua", "deadbeef:42:7", false), "unknown-target");
  });
});

describe("codex-cua backend", () => {
  const AX = [
    "Window: Calculator, App: Calculator.",
    "0 standard window Calculator",
    "\t1 button Description: 7, ID: Seven, Secondary Actions: Press",
    "\t2 text 0",
    "\t3 radio button (selected, settable, boolean) Tab One",
  ].join("\n");

  function pluginHome() {
    const home = scratch();
    const dir = join(home, ".codex/plugins/cache/openai-bundled/unified-computer-use/26.1027.51404");
    return { home, dir };
  }

  function repl(state: { ax: string }) {
    const codes: string[] = [];
    const client: McpClient = {
      serverInfo: { name: "cua_repl" },
      listTools: async () => [],
      close: () => {},
      async callTool(name, args = {}) {
        assert.equal(name, "js");
        const code = String(args.code);
        codes.push(code);
        let body: unknown;
        if (code.includes("cua.listApps") && code.includes("filter")) body = [
          { id: "com.apple.calculator", displayName: "Calculator", isRunning: true },
          { id: "com.apple.mail", displayName: "Mail", isRunning: true },
        ];
        else if (code.includes("cua.listApps")) body = 2;
        else if (code.includes("performSecondaryAction")) body = { after: state.ax };
        else body = { text: state.ax };
        return { content: [{ type: "text", text: `log line\n@@ACTION@@${JSON.stringify(body)}` }] };
      },
    };
    return { client, codes };
  }

  test("with no apps allow list it reports not ready", async () => {
    const { client } = repl({ ax: AX });
    const { host } = hostWith({}, () => client);
    const status = await host.availability("codex-cua");
    assert.equal(status.ready, false);
    assert.match(status.reason ?? "", /apps is empty/);
  });

  test("lists only allow-listed apps and approves only their Computer Use prompts, for the session", async () => {
    const { home, dir } = pluginHome();
    const { mkdirSync } = await import("node:fs");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, ".mcp.json"), JSON.stringify({ mcpServers: { cua_repl: { command: "/bin/echo", args: ["x"], env: { CUA_REPL_ENABLED_SURFACES: "browser,computer" } } } }));
    const previous = process.env.HOME;
    process.env.HOME = home;
    try {
      const { client } = repl({ ax: AX });
      const { host, spawned } = hostWith({ "codex-cua": { apps: ["com.apple.calculator"] } }, () => client);
      const targets = await host.targets("codex-cua");
      assert.deepEqual(targets.map((target) => target.bundleId), ["com.apple.calculator"]);
      assert.equal(spawned[0]!.env?.CUA_REPL_ENABLED_SURFACES, "computer");
      const answer = spawned[0]!.onElicitation!;
      assert.deepEqual(answer({ _meta: { connector_id: "computer-use", tool_params: { app: "com.apple.calculator" } } }), { content: {}, _meta: { persist: "session" } });
      assert.equal(answer({ _meta: { connector_id: "computer-use", tool_params: { app: "com.apple.mail" } } }), null);
      assert.equal(answer({ _meta: { connector_id: "browser-use", tool_params: { app: "com.apple.calculator" } } }), null);
    } finally {
      process.env.HOME = previous;
    }
  });

  test("observes cua's AX text as refs and presses through performSecondaryAction after the verify check", async () => {
    const { home, dir } = pluginHome();
    const { mkdirSync } = await import("node:fs");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, ".mcp.json"), JSON.stringify({ mcpServers: { cua_repl: { command: "/bin/echo" } } }));
    const previous = process.env.HOME;
    process.env.HOME = home;
    try {
      const { client, codes } = repl({ ax: AX });
      const { host } = hostWith({ "codex-cua": { apps: ["com.apple.calculator"] } }, () => client);
      const targetId = `${host.generation}:com.apple.calculator`;
      const observation = await host.observe("codex-cua", targetId, false);
      const seven = observation.ax!.find((node) => node.label === "7")!;
      assert.equal(seven.role, "AXButton");
      assert.deepEqual(seven.actions, ["Press"]);
      // State/type descriptors stay out of the label so ^anchored label matches work.
      assert.ok(observation.ax!.some((node) => node.label === "Tab One"), JSON.stringify(observation.ax));
      const result = await host.act("codex-cua", targetId, { kind: "press", ref: seven.ref }, { observationId: observation.observationId, allowTiers: ["observe", "semantic"] });
      assert.equal(result.tierUsed, "semantic");
      assert.match(codes.at(-1)!, /performSecondaryAction\(args\.index, "Press"\)/);
      assert.match(codes.at(-1)!, /disableDiffing/);
      await refusal(host.observe("codex-cua", `${host.generation}:com.apple.mail`, false), "unknown-target");
    } finally {
      process.env.HOME = previous;
    }
  });
});

describe("stdioMcp", () => {
  test("answers a server's elicitation through the handler and returns the tool result", async () => {
    const server = `
      const rl = require("node:readline").createInterface({ input: process.stdin });
      const out = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
      let callId;
      rl.on("line", (line) => {
        const m = JSON.parse(line);
        if (m.method === "initialize") out({ jsonrpc: "2.0", id: m.id, result: { serverInfo: { name: "fake", version: "1" }, capabilities: {}, elicitationSeen: Boolean(m.params.capabilities.elicitation) } });
        else if (m.method === "tools/call") { callId = m.id; out({ jsonrpc: "2.0", id: "e1", method: "elicitation/create", params: { message: "Allow?", _meta: { app: "x" } } }); }
        else if (m.id === "e1") out({ jsonrpc: "2.0", id: callId, result: { content: [{ type: "text", text: JSON.stringify(m.result) }] } });
      });`;
    const client = await stdioMcp({
      command: process.execPath,
      args: ["-e", server],
      timeoutMs: 10_000,
      onElicitation: (params) => (params._meta?.app === "x" ? { content: {}, _meta: { persist: "session" } } : null),
    });
    try {
      assert.equal(client.serverInfo?.name, "fake");
      const result = await client.callTool("anything", {});
      assert.deepEqual(JSON.parse(result.content![0]!.text!), { action: "accept", content: {}, _meta: { persist: "session" } });
    } finally {
      client.close();
    }
  });
});
