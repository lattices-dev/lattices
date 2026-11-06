import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { createActionCuaBackend } from "./action-cua.js";
import { BackendHost, computerBackends } from "./host.js";
import {
  BackendRefusal,
  type BackendAction,
  type BackendCall,
  type BackendContext,
  type BackendObservation,
  type BackendTier,
} from "./types.js";

const BUNDLE = "com.apple.calculator";
const GENERATION = "action-test";
const TARGET = `${GENERATION}:${BUNDLE}`;
const WINDOW_TARGET = `${TARGET}:42:101`;
const PATH_COMMANDS = ["press-accessibility-path", "set-accessibility-value-path", "perform-accessibility-action-path"];
const LSAPPS = [
  '1) "Calculator" ASN:0x0-0x1001:',
  '    bundleID="com.apple.calculator"',
  '    pid = 42 type="Foreground" flavor=3 Version="1.0"',
  '2) "Mail" ASN:0x0-0x1002:',
  '    bundleID="com.apple.mail"',
  '    pid = 43 type="Foreground" flavor=3 Version="1.0"',
  '3) "Menu Helper" ASN:0x0-0x1003:',
  '    bundleID="example.helper"',
  '    pid = 44 type="UIElement" flavor=3 Version="1.0"',
].join("\n");
const WINDOWS = [{ pid: 42, bundleId: BUNDLE, appName: "Calculator", windowNumber: 101,
  title: "Main calculator", frame: { x: 0, y: 0, width: 500, height: 500 }, onScreen: true, layer: 0 }];

type Node = {
  role: string;
  depth: number;
  title?: string;
  detail?: string;
  identifier?: string;
  value?: string;
  help?: string | null;
  actions: string[];
  settableAttributes: string[];
  frame?: { x: number; y: number; width: number; height: number };
  enabled?: boolean;
  focused?: boolean;
  path?: string;
  root?: "window" | "application";
  rootWindow?: { title?: string; frame?: { x: number; y: number; width: number; height: number } };
  truncated?: boolean;
};

const node = (fields: Partial<Node> = {}): Node => ({
  role: "AXButton", depth: 1, title: "Seven", help: null,
  actions: ["AXPress"], settableAttributes: [], enabled: true, focused: false,
  frame: { x: 10, y: 20, width: 30, height: 40 }, ...fields,
});

/**
 * These success fixtures deliberately model a complete application-root walk.
 * Legacy Swift inspect-app-ui returns only one window and omits AXHelp; that
 * reply shape is covered by refusal tests below, not treated as complete.
 */
const complete = (...nodes: Node[]): Node[] => [
  node({ role: "AXApplication", depth: 0, title: "Calculator", actions: [], frame: undefined }),
  ...nodes,
];

// Real path snapshots put root metadata on the root node only; paths are AX
// child indices, not positions in this flattened BFS array.
const pathSnapshot = (...nodes: Node[]): Node[] => [
  node({ role: "AXWindow", depth: 0, title: "Calculator", actions: [], path: "root", root: "window",
    rootWindow: { title: "Calculator", frame: { x: 0, y: 0, width: 500, height: 500 } }, truncated: false }),
  ...nodes,
];

const call = (signal = new AbortController().signal): BackendCall => ({
  requestId: "test-request", caller: "test", signal, deadline: Date.now() + 10_000,
});

type Sent = { command: string; args: string[] };

function fixture(t: TestContext, options: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "action-cua-test-"));
  const calls: Sent[] = [];
  const state: {
    nodes: Node[];
    snapshot?: unknown;
    reply?: unknown;
    capabilities: unknown;
    status: unknown;
    list: string;
    windows: unknown;
  } = { nodes: complete(node()), capabilities: {},
    status: { accessibility: "granted", screenRecording: "granted", notes: ["bundleId=dev.lattices.Action"] }, list: LSAPPS, windows: structuredClone(WINDOWS) };
  const run = async (command: string, args: string[], request: BackendCall): Promise<unknown> => {
    assert.ok(request.signal instanceof AbortSignal);
    calls.push({ command, args: [...args] });
    const option = (name: string) => args[args.indexOf(name) + 1];
    switch (command) {
      case "capabilities": return state.capabilities;
      case "status": return state.status;
      case "list-app-windows":
        assert.deepEqual(args, []);
        return structuredClone(state.windows);
      case "/usr/bin/lsappinfo":
        assert.deepEqual(args, ["list"]);
        return state.list;
      case "inspect-app-ui": return structuredClone(state.snapshot ?? state.nodes);
      case "screenshot-app-window": {
        const path = option("--output")!;
        // A complete 1x1 PNG, created by the fake host instead of native capture.
        writeFileSync(path, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII=", "base64"));
        return { status: "screenshot", outputPath: path };
      }
      case "press-accessibility-element":
      case "set-accessibility-value":
      case "perform-accessibility-action":
        return state.reply ?? {
          status: command === "set-accessibility-value" ? "value-set" : command === "perform-accessibility-action" ? "performed" : "pressed",
          detail: `${option("--bundle-id")} ${option("--role")} ${option("--label")}${command === "perform-accessibility-action" ? ` ${option("--action")}` : ""}`,
        };
      case "press-accessibility-path":
      case "set-accessibility-value-path":
      case "perform-accessibility-action-path":
        return state.reply ?? {
          status: command === "set-accessibility-value-path" ? "value-set" : command === "perform-accessibility-action-path" ? "performed" : "pressed",
          root: option("--root"), path: option("--path"), role: option("--expect-role"),
          labelCandidates: args.includes("--expect-label") ? [option("--expect-label")] : [],
        };
      case "type-text": return state.reply ?? { status: "typed", detail: option("--text") };
      case "press-key": return state.reply ?? { status: "pressed", detail: option("--key") };
      case "click-point": return state.reply ?? { status: "clicked" };
      case "scroll": return state.reply ?? { status: "scrolled" };
      default: throw new Error(`Unexpected fake-host command ${command}`);
    }
  };
  const ctx: BackendContext = {
    generation: GENERATION,
    options: { host: process.execPath, __run: run, ...options },
    shotsDir: dir,
    stdioMcp: async () => { throw new Error("action-cua must not start an MCP driver"); },
    newestDir: () => null,
    log: () => {},
    refuse: (code, message, observation) => new BackendRefusal(code, message, observation),
  };
  const backend = createActionCuaBackend(ctx);
  t.after(async () => {
    await backend.dispose();
    rmSync(dir, { recursive: true, force: true });
  });
  const observe = (target = TARGET) => backend.observe(call(), target, { screenshot: false });
  const act = (observation: BackendObservation, action: BackendAction, allowTiers: BackendTier[] = ["observe", "semantic", "attention"]) =>
    backend.act(call(), observation.targetId, action, { observationId: observation.observationId, allowTiers });
  const mutations = () => calls.filter(({ command }) => !["capabilities", "status", "/usr/bin/lsappinfo", "list-app-windows", "inspect-app-ui", "screenshot-app-window"].includes(command));
  return { backend, state, calls, observe, act, mutations, ctx, dir };
}

function pathFixture(t: TestContext) {
  const f = fixture(t);
  f.state.capabilities = { build: { version: "0.4.0-test" }, accessibilityPathCommands: PATH_COMMANDS };
  f.state.nodes = pathSnapshot(node({ path: "0.3.2" }));
  return f;
}

function windowFixture(t: TestContext, options: Record<string, unknown> = {}) {
  const f = fixture(t, options);
  f.state.capabilities = { windowScopedAccessibility: true, accessibilityPathCommands: PATH_COMMANDS };
  f.state.nodes = pathSnapshot(node({ path: "0.3.2" }));
  return f;
}

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

describe("action-cua backend", () => {
  test("lists distinct windows across same-bundle processes including off-screen layer windows", async (t) => {
    const f = windowFixture(t);
    const chrome = { ...WINDOWS[0]!, bundleId: "com.google.Chrome", appName: "Google Chrome", pid: 50, windowNumber: 201, title: "Personal" };
    f.state.windows = [chrome, { ...chrome, windowNumber: 202, title: "Work" },
      { ...chrome, pid: 51, windowNumber: 203, title: "Agent layer", onScreen: false }];
    assert.deepEqual(await f.backend.targets(call()), [
      { targetId: `${GENERATION}:com.google.Chrome:50:201`, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Personal", pid: 50 },
      { targetId: `${GENERATION}:com.google.Chrome:50:202`, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Work", pid: 50 },
      { targetId: `${GENERATION}:com.google.Chrome:51:203`, bundleId: "com.google.Chrome", app: "Google Chrome", title: "Agent layer", pid: 51 },
    ]);
    assert.deepEqual(f.calls, [{ command: "capabilities", args: [] }, { command: "list-app-windows", args: [] }]);
  });

  test("window listings honor the bundle allow list and reject malformed identities", async (t) => {
    const f = windowFixture(t, { apps: [BUNDLE] });
    f.state.windows = [...WINDOWS, { ...WINDOWS[0]!, bundleId: "com.apple.mail", pid: 43, windowNumber: 102 }];
    assert.deepEqual((await f.backend.targets(call())).map((target) => target.targetId), [WINDOW_TARGET]);
    for (const target of [`old:${BUNDLE}:42:101`, `${TARGET}:0:101`, `${TARGET}:42:0`, `${TARGET}:42:101:extra`,
      `${TARGET}:42:01`, `${TARGET}:2147483648:101`, `${TARGET}:42:4294967296`, `${GENERATION}:com.apple.mail:43:102`]) {
      const count = f.calls.length;
      await refusal(f.observe(target), "unknown-target");
      assert.equal(f.calls.length, count);
    }
    f.state.windows = [{ ...WINDOWS[0]!, windowNumber: "101" }];
    await assert.rejects(f.backend.targets(call()), /no valid native window array/);
  });

  test("window targets carry PID and window number to inspect, screenshot and all path actions", async (t) => {
    const f = windowFixture(t);
    f.state.nodes = pathSnapshot(node({ path: "0", role: "AXTextField", title: "Search", value: "before",
      actions: ["AXPress", "AXConfirm"], settableAttributes: ["AXValue"] }));
    const observed = await f.backend.observe(call(), WINDOW_TARGET, { screenshot: true });
    await f.act(observed, { kind: "press", ref: observed.ax![1]!.ref });
    await f.act(observed, { kind: "setValue", ref: observed.ax![1]!.ref, value: "after" });
    await f.act(observed, { kind: "secondary", ref: observed.ax![1]!.ref, name: "AXConfirm" });
    const commands = ["inspect-app-ui", "screenshot-app-window", ...PATH_COMMANDS];
    for (const command of commands) {
      const sent = f.calls.find((item) => item.command === command)!;
      assert.ok(sent, command);
      assert.deepEqual(sent.args.slice(0, 6), ["--bundle-id", BUNDLE, "--pid", "42", "--window-number", "101"]);
      if (command !== "screenshot-app-window") assert.equal(sent.args[sent.args.indexOf("--root") + 1], "window");
    }
    assert.equal(readFileSync(observed.screenshot!.path).readUInt32BE(0), 0x89504e47);
  });

  test("observations of another window with the same bundle do not replace retained refs", async (t) => {
    const f = windowFixture(t);
    f.state.windows = [...WINDOWS, { ...WINDOWS[0]!, pid: 43, windowNumber: 102 }];
    const first = await f.observe(WINDOW_TARGET);
    const second = await f.observe(`${TARGET}:43:102`);
    await f.act(first, { kind: "press", ref: first.ax![1]!.ref });
    await f.act(second, { kind: "press", ref: second.ax![1]!.ref });
    assert.deepEqual(f.mutations().map(({ args }) => args.slice(2, 6)), [
      ["--pid", "42", "--window-number", "101"], ["--pid", "43", "--window-number", "102"],
    ]);
  });

  test("a vanished or reassigned window refuses observation and action before native dispatch", async (t) => {
    const f = windowFixture(t);
    const observed = await f.observe(WINDOW_TARGET);
    for (const windows of [[], [{ ...WINDOWS[0]!, pid: 43 }], [{ ...WINDOWS[0]!, bundleId: "com.apple.mail" }]]) {
      f.state.windows = windows;
      await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unknown-target");
      await refusal(f.observe(WINDOW_TARGET), "unknown-target");
    }
    assert.equal(f.calls.filter(({ command }) => command === "inspect-app-ui").length, 1);
    assert.deepEqual(f.mutations(), []);
  });

  test("a window disappearing between listing and inspect is an unknown-target refusal", async (t) => {
    const f = windowFixture(t);
    f.state.snapshot = { status: "error", detail: "window-not-found: no AXWindow 101 for PID 42" };
    const error = await refusal(f.observe(WINDOW_TARGET), "unknown-target");
    assert.match(error.message, /window-not-found/);
    assert.deepEqual(f.mutations(), []);
  });

  test("window path mismatch keeps fresh-observation refusal and handles a vanished root", async (t) => {
    const f = windowFixture(t);
    const observed = await f.observe(WINDOW_TARGET);
    f.state.nodes = pathSnapshot(node({ path: "0.3.2", title: "Changed" }));
    f.state.reply = { status: "error", detail: "path-mismatch: label changed" };
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "stale-ref");
    assert.equal(error.observation!.targetId, WINDOW_TARGET);
    assert.equal(error.observation!.ax![1]!.label, "Changed");
    f.state.reply = { status: "error", detail: "path-mismatch: window-not-found: no AXWindow 101" };
    f.state.snapshot = { status: "error", detail: "window-not-found: no AXWindow 101" };
    await refusal(f.act(error.observation!, { kind: "press", ref: error.observation!.ax![1]!.ref }), "unknown-target");
  });

  test("app IDs remain readable on scoped hosts and window IDs refuse hosts without scoped support", async (t) => {
    const scoped = windowFixture(t);
    await scoped.observe(TARGET);
    assert.equal(scoped.calls.some(({ command }) => command === "list-app-windows"), false);
    assert.equal(scoped.calls.find(({ command }) => command === "inspect-app-ui")!.args.includes("--pid"), false);
    const legacy = pathFixture(t);
    await refusal(legacy.observe(WINDOW_TARGET), "unknown-target");
    assert.equal(legacy.calls.some(({ command }) => command === "inspect-app-ui"), false);
  });

  test("lists regular apps, applies the optional bundle allow list, and generation-scopes targets", async (t) => {
    const all = fixture(t);
    const targets = await all.backend.targets(call());
    assert.deepEqual(targets.map(({ targetId, bundleId, app, pid }) => ({ targetId, bundleId, app, pid })), [
      { targetId: TARGET, bundleId: BUNDLE, app: "Calculator", pid: 42 },
      { targetId: `${GENERATION}:com.apple.mail`, bundleId: "com.apple.mail", app: "Mail", pid: 43 },
    ]);
    const allowed = fixture(t, { apps: [BUNDLE] });
    assert.deepEqual((await allowed.backend.targets(call())).map((target) => target.bundleId), [BUNDLE]);
    const sent = allowed.calls.length;
    await refusal(allowed.backend.observe(call(), `older:${BUNDLE}`, {}), "unknown-target");
    await refusal(allowed.backend.observe(call(), `${GENERATION}:com.apple.mail`, {}), "unknown-target");
    assert.equal(allowed.calls.length, sent);
    const empty = fixture(t, { apps: [] });
    assert.deepEqual(await empty.backend.targets(call()), []);
  });

  test("terminated and exited-with-subordinates lsappinfo entries are not running targets", async (t) => {
    const f = fixture(t);
    f.state.list = `${LSAPPS}\n${[
      '4) "Closed" ASN:0x0-0x1004: (terminated)',
      '    bundleID="example.closed"',
      '    pid = 45 type="Foreground" flavor=3 Version="1.0"',
      '5) "Closing" ASN:0x0-0x1005: (exited-with-subordinates)',
      '    bundleID="example.closing"',
      '    pid = 46 type="Foreground" flavor=3 Version="1.0"',
    ].join("\n")}`;
    assert.deepEqual((await f.backend.targets(call())).map((target) => target.bundleId), [BUNDLE, "com.apple.mail"]);
  });

  test("maps native labels, values, actions and both settable spellings with the full walk limits", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(
      node({ title: "Title wins", detail: "Description", identifier: "identifier", value: "7" }),
      node({ title: undefined, detail: "Description wins", identifier: "identifier", role: "AXTextField", settableAttributes: ["value"] }),
      node({ title: undefined, detail: undefined, identifier: "Only identifier", role: "AXTextArea", settableAttributes: ["AXValue"] }),
    );
    const observed = await f.observe();
    assert.deepEqual(f.calls.find(({ command }) => command === "inspect-app-ui"), {
      command: "inspect-app-ui", args: ["--bundle-id", BUNDLE, "--max-depth", "20", "--max-nodes", "12000"],
    });
    assert.equal(observed.ax![1]!.ref, `${observed.observationId}:1`);
    assert.equal(observed.ax![1]!.depth, 1);
    assert.equal(observed.ax![1]!.role, "AXButton");
    assert.equal(observed.ax![1]!.label, "Title wins");
    assert.equal(observed.ax![1]!.value, "7");
    assert.deepEqual(observed.ax![1]!.actions, ["AXPress"]);
    assert.equal(observed.ax![1]!.settable, false);
    assert.equal(observed.ax![2]!.label, "Description wins");
    assert.equal(observed.ax![2]!.settable, true);
    assert.equal(observed.ax![3]!.label, "Only identifier");
    assert.equal(observed.ax![3]!.settable, true);
  });

  test("malformed optional native label, value or help fields are rejected during observation", async (t) => {
    const f = fixture(t);
    for (const field of ["title", "detail", "identifier", "value", "help"]) {
      for (const invalid of [42, { text: "Seven" }]) {
        f.state.snapshot = [...complete(), { ...node(), [field]: invalid }];
        await assert.rejects(f.observe(), (error: unknown) => {
          assert.ok(error instanceof Error && !(error instanceof BackendRefusal), `malformed ${field} must fail observation`);
          return true;
        });
      }
    }
    assert.deepEqual(f.mutations(), []);
  });

  test("path press sends the observed path, inherited root, role, label and frame", async (t) => {
    const f = pathFixture(t);
    const observed = await f.observe();
    const result = await f.act(observed, { kind: "press", ref: observed.ax![1]!.ref });
    assert.equal(result.tierUsed, "semantic");
    assert.equal(result.mechanism, "ax-path-press");
    assert.deepEqual(f.calls.find(({ command }) => command === "inspect-app-ui"), {
      command: "inspect-app-ui", args: ["--bundle-id", BUNDLE, "--max-depth", "20", "--max-nodes", "12000", "--root", "window"],
    });
    assert.deepEqual(f.mutations(), [{ command: "press-accessibility-path", args: [
      "--bundle-id", BUNDLE, "--path", "0.3.2", "--root", "window", "--expect-role", "AXButton",
      "--expect-label", "Seven", "--expect-frame", "10,20,30,40",
    ] }]);
  });

  test("duplicate-label Rex-style tabs are independently pressable by their observed paths", async (t) => {
    const f = pathFixture(t);
    f.state.nodes = pathSnapshot(
      node({ path: "0.0.0", depth: 3, role: "AXRadioButton", title: undefined, detail: "Claude Code", help: undefined }),
      node({ path: "0.0.1", depth: 3, role: "AXRadioButton", title: undefined, detail: "Claude Code", help: undefined,
        frame: { x: 50, y: 20, width: 30, height: 40 } }),
    );
    const observed = await f.observe();
    for (const tab of observed.ax!.slice(1)) {
      const result = await f.act(observed, { kind: "press", ref: tab.ref });
      assert.equal(result.mechanism, "ax-path-press");
    }
    assert.deepEqual(f.mutations().map(({ command, args }) => ({ command, path: args[args.indexOf("--path") + 1] })), [
      { command: "press-accessibility-path", path: "0.0.0" },
      { command: "press-accessibility-path", path: "0.0.1" },
    ]);
  });

  test("path actions allow a truncated window snapshot and retain application-root metadata", async (t) => {
    for (const root of ["window", "application"] as const) {
      const f = pathFixture(t);
      f.state.nodes[0] = node({ role: root === "window" ? "AXWindow" : "AXApplication", depth: 0,
        actions: [], path: "root", root, truncated: true });
      const observed = await f.observe();
      await f.act(observed, { kind: "press", ref: observed.ax![1]!.ref });
      const sent = f.mutations()[0]!;
      assert.equal(sent.command, "press-accessibility-path");
      assert.equal(sent.args[sent.args.indexOf("--root") + 1], root);
    }
  });

  test("path label expectations use the first nonempty native candidate without changing its text", async (t) => {
    const cases: Array<[Partial<Node>, string]> = [
      [{ title: " Title ", detail: "Detail", value: "Value", identifier: "Identifier" }, " Title "],
      [{ title: "\u200B\u0085", detail: " Detail ", value: "Value", identifier: "Identifier" }, " Detail "],
      [{ title: "", detail: "\t\n", value: " Value ", identifier: "Identifier" }, " Value "],
      [{ title: "", detail: undefined, value: " ", identifier: " Identifier " }, " Identifier "],
    ];
    for (const [fields, expected] of cases) {
      const f = pathFixture(t);
      f.state.nodes = pathSnapshot(node({ path: "0", ...fields }));
      const observed = await f.observe();
      await f.act(observed, { kind: "press", ref: observed.ax![1]!.ref });
      const args = f.mutations()[0]!.args;
      assert.equal(args[args.indexOf("--expect-label") + 1], expected);
    }
  });

  test("unlabelled path targets omit optional expectations and the root path is actionable", async (t) => {
    const f = pathFixture(t);
    f.state.nodes = [node({ path: "root", root: "window", depth: 0, title: undefined, detail: undefined,
      value: undefined, identifier: undefined, frame: undefined })];
    const observed = await f.observe();
    await f.act(observed, { kind: "press", ref: observed.ax![0]!.ref });
    assert.deepEqual(f.mutations(), [{ command: "press-accessibility-path", args: [
      "--bundle-id", BUNDLE, "--path", "root", "--root", "window", "--expect-role", "AXButton",
    ] }]);
  });

  test("path setValue supports an empty value and secondary dispatches the advertised AX action", async (t) => {
    const f = pathFixture(t);
    f.state.nodes = pathSnapshot(node({ path: "1", role: "AXTextField", title: "Search", value: "before",
      settableAttributes: ["AXValue"], actions: ["AXConfirm"] }));
    const observed = await f.observe();
    const ref = observed.ax![1]!.ref;
    const set = await f.act(observed, { kind: "setValue", ref, value: "" });
    assert.equal(set.mechanism, "ax-path-set-value");
    const secondary = await f.act(observed, { kind: "secondary", ref, name: "Confirm" });
    assert.equal(secondary.mechanism, "ax-path-action");
    const expected = ["--bundle-id", BUNDLE, "--path", "1", "--root", "window", "--expect-role", "AXTextField",
      "--expect-label", "Search", "--expect-frame", "10,20,30,40"];
    assert.deepEqual(f.mutations(), [
      { command: "set-accessibility-value-path", args: [...expected, "--value", ""] },
      { command: "perform-accessibility-action-path", args: [...expected, "--action", "AXConfirm"] },
    ]);
  });

  test("a path-mismatch refuses stale refs and attaches a fresh observation", async (t) => {
    const f = pathFixture(t);
    const observed = await f.observe();
    f.state.nodes = pathSnapshot(node({ path: "0.3.2", title: "Changed" }));
    f.state.reply = { status: "error", detail: "path-mismatch: 0.3.2 label candidates do not match Seven" };
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "stale-ref");
    assert.ok(error.observation);
    assert.notEqual(error.observation.observationId, observed.observationId);
    assert.equal(error.observation.targetId, TARGET);
    assert.equal(error.observation.ax![1]!.label, "Changed");
    assert.equal(f.calls.filter(({ command }) => command === "inspect-app-ui").length, 2);
    assert.equal(f.mutations().length, 1, "the refused native attempt must not trigger a retry");
  });

  test("path reply mismatches and action failures remain uncertain errors, never refusals", async (t) => {
    for (const reply of [
      { status: "pressed", path: "0.3.1", root: "window", role: "AXButton" },
      { status: "pressed", path: "0.3.2", root: "window", role: "AXRadioButton" },
      { status: "pressed", root: "window", role: "AXButton" },
      { status: "pressed", path: "0.3.2", root: "window" },
      { status: "error", detail: "ax-action-failed: AXPress failed" },
      { status: "error", detail: "host failed unexpectedly" },
      { status: "error", detail: "ax-action-failed: path-mismatch: text is not a safe prefix" },
    ]) {
      const f = pathFixture(t);
      const observed = await f.observe();
      f.state.reply = reply;
      await assert.rejects(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), (error: unknown) => {
        assert.ok(error instanceof Error && !(error instanceof BackendRefusal));
        return true;
      });
      assert.equal(f.mutations().length, 1);
      assert.equal(f.calls.filter(({ command }) => command === "inspect-app-ui").length, 1);
    }
  });

  test("capability discovery is cached across concurrent observations, availability and actions", async (t) => {
    const f = pathFixture(t);
    await Promise.all([f.observe(), f.backend.availability(call())]);
    f.state.capabilities = {}; // A backend instance keeps its detected native contract.
    const observed = await f.observe();
    await f.act(observed, { kind: "press", ref: observed.ax![1]!.ref });
    assert.equal(f.calls.filter(({ command }) => command === "capabilities").length, 1);
    assert.equal(f.mutations()[0]!.command, "press-accessibility-path");
  });

  test("a failed or cancelled capability probe is retried on a fresh call", async (t) => {
    for (const firstOutcome of ["failed", "cancelled"] as const) {
      let probes = 0;
      let finishFirst: ((value: unknown) => void) | undefined;
      const f = fixture(t, { __run: async (command: string) => {
        if (command === "capabilities") {
          probes++;
          if (probes === 1) {
            if (firstOutcome === "failed") throw new Error("fake capability failure");
            return new Promise((resolve) => { finishFirst = resolve; });
          }
          return { accessibilityPathCommands: PATH_COMMANDS };
        }
        if (command === "inspect-app-ui") return pathSnapshot(node({ path: "0" }));
        throw new Error(`Unexpected fake command ${command}`);
      } });
      const controller = new AbortController();
      const first = f.backend.observe(call(controller.signal), TARGET, {});
      const rejected = assert.rejects(first, /fake capability failure|cancel|abort|unavailable/i);
      if (firstOutcome === "cancelled") controller.abort();
      await rejected;
      finishFirst?.({ accessibilityPathCommands: PATH_COMMANDS });
      const observed = await f.observe();
      assert.equal(observed.ax![1]!.label, "Seven");
      await f.observe();
      assert.equal(probes, 2, "only a successful probe should stay cached");
    }
  });

  test("a shared capability probe respects each waiting caller's cancellation and deadline", async (t) => {
    for (const stop of ["cancel", "deadline"] as const) {
      let probes = 0;
      let probeSignal: AbortSignal | undefined;
      let finishProbe!: (value: unknown) => void;
      let reportStarted!: () => void;
      const started = new Promise<void>((resolve) => { reportStarted = resolve; });
      const f = fixture(t, { __run: async (command: string, _args: string[], request: BackendCall) => {
        if (command === "capabilities") {
          probes++;
          probeSignal = request.signal;
          const pending = new Promise((resolve) => { finishProbe = resolve; });
          reportStarted();
          return pending;
        }
        if (command === "inspect-app-ui") return pathSnapshot(node({ path: "0" }));
        throw new Error(`Unexpected fake command ${command}`);
      } });
      let firstSettled = false;
      const first = f.observe().then((result) => { firstSettled = true; return result; });
      await started;
      const controller = new AbortController();
      const request = call(controller.signal);
      if (stop === "deadline") request.deadline = Date.now() + 30;
      const second = f.backend.observe(request, TARGET, {});
      const rejected = assert.rejects(second, /cancel|expire|abort|deadline|timed out/i);
      if (stop === "cancel") controller.abort();
      try {
        await Promise.race([rejected, delay(500).then(() => assert.fail("waiting caller ignored its own cancellation/deadline"))]);
        assert.equal(probes, 1);
        assert.equal(probeSignal?.aborted, false, "a waiting caller must not cancel the first caller's native probe");
        assert.equal(firstSettled, false, "the first caller should still be awaiting discovery");
      } finally {
        finishProbe({ accessibilityPathCommands: PATH_COMMANDS });
      }
      assert.equal((await first).targetId, TARGET);
      assert.equal(probes, 1);
    }
  });

  test("partial path command support keeps the legacy ambiguity refusal with update guidance", async (t) => {
    const f = fixture(t);
    f.state.capabilities = { accessibilityPathCommands: ["press-accessibility-path"] };
    f.state.nodes = complete(node(), node());
    const observed = await f.observe();
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.match(error.message, /update Action\.app for path-addressed actions/);
    assert.deepEqual(f.mutations(), []);
  });

  test("a complete snapshot's unique strict winner uses a native label and role, never its ref", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(
      node({ title: "Seven more" }), // Prefix scores less than exact, even when it is earlier in BFS.
      node({ title: "Seven" }),
      node({ title: "Seven", role: "AXStaticText", actions: [] }), // Role is a hard filter.
    );
    const observed = await f.observe();
    const result = await f.act(observed, { kind: "press", ref: observed.ax![2]!.ref });
    assert.equal(result.tierUsed, "semantic");
    assert.equal(result.mechanism, "ax-press");
    assert.deepEqual(f.mutations(), [{ command: "press-accessibility-element", args: ["--bundle-id", BUNDLE, "--label", "Seven", "--role", "AXButton"] }]);
  });

  test("normalized duplicate labels are ambiguous even when the requested node is first in BFS", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: "Save changes" }), node({ title: "  SAVE \n changes  " }));
    const observed = await f.observe();
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.match(error.message, /ambig|unique|tie/i);
    assert.match(error.message, /update Action\.app for path-addressed actions/);
    assert.deepEqual(f.mutations(), []);
  });

  test("canonically equivalent Unicode labels are ambiguous under native string equality", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: "Café" }), node({ title: "Cafe\u0301" }));
    const observed = await f.observe();
    await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.deepEqual(f.mutations(), []);
  });

  test("Foundation trims zero-width space and collapses NEL when matching labels", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: "Save changes" }), node({ title: "\u200BSAVE\u0085changes\u200B" }));
    const observed = await f.observe();
    await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.deepEqual(f.mutations(), []);
  });

  test("all native label candidates participate, including an explicit help value", async (t) => {
    for (const field of ["detail", "value", "identifier", "help"] as const) {
      const f = fixture(t);
      f.state.nodes = complete(node(), node({ title: "Other", [field]: "Seven" }));
      const observed = await f.observe();
      await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
      assert.deepEqual(f.mutations(), [], field);
    }
  });

  test("an omitted AXHelp cannot be assumed absent when another same-role node could tie", async (t) => {
    const f = fixture(t);
    const peer = node({ title: "Other" });
    delete peer.help;
    f.state.nodes = complete(node(), peer);
    const observed = await f.observe();
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.match(error.message, /help|ambig|unique/i);
    assert.deepEqual(f.mutations(), []);
  });

  test("the real native window-root snapshot cannot prove app-wide label uniqueness", async (t) => {
    const f = fixture(t);
    f.state.nodes = [node({ role: "AXWindow", depth: 0, title: "Calculator", actions: [] }), node()];
    const observed = await f.observe();
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.match(error.message, /window|application|app-wide|root/i);
    assert.deepEqual(f.mutations(), []);
  });

  test("hitting 12000 nodes refuses a semantic dispatch even with a unique visible label", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node(), ...Array.from({ length: 11_998 }, (_, index) => node({ role: "AXStaticText", title: `text ${index}`, actions: [] })));
    const observed = await f.observe();
    assert.equal(observed.ax!.length, 12_000);
    const error = await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.match(error.message, /cap|limit|12000|12,000/i);
    assert.deepEqual(f.mutations(), []);
  });

  test("a node without a usable label is refused before dispatch", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: undefined, detail: undefined, identifier: undefined }));
    const observed = await f.observe();
    await refusal(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), "unsupported");
    assert.deepEqual(f.mutations(), []);
  });

  test("only the newest observation per target supplies refs, and a stale ref carries a fresh observation", async (t) => {
    const f = fixture(t);
    const first = await f.observe();
    const second = await f.observe();
    const error = await refusal(f.act(first, { kind: "press", ref: first.ax![1]!.ref }), "stale-ref");
    assert.ok(error.observation);
    assert.notEqual(error.observation.observationId, first.observationId);
    assert.notEqual(error.observation.observationId, second.observationId);
    assert.equal(error.observation.targetId, TARGET);
    assert.deepEqual(f.mutations(), []);
    // A newer snapshot of a different app does not invalidate this app's refs.
    await f.observe(`${GENERATION}:com.apple.mail`);
    await f.act(error.observation, { kind: "press", ref: error.observation.ax![1]!.ref });
    assert.equal(f.mutations().length, 1);
  });

  test("an invented ref in the newest observation also returns a fresh observation", async (t) => {
    const f = fixture(t);
    const observed = await f.observe();
    const error = await refusal(f.act(observed, { kind: "press", ref: `${observed.observationId}:999` }), "stale-ref");
    assert.ok(error.observation);
    assert.notEqual(error.observation.observationId, observed.observationId);
    assert.deepEqual(f.mutations(), []);
  });

  test("a mismatched native matched-element reply is an uncertain delivery, never a refusal", async (t) => {
    for (const mismatch of [
      { role: "AXTextField", title: "Seven" },
      { role: "AXButton", title: "Other" },
      { role: "AXButton", title: "Seven", frame: { x: 500, y: 20, width: 30, height: 40 } },
    ]) {
      const f = fixture(t);
      f.state.reply = { status: "pressed", element: mismatch };
      const observed = await f.observe();
      await assert.rejects(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), (error: unknown) => {
        assert.ok(error instanceof Error);
        assert.ok(!(error instanceof BackendRefusal));
        return true;
      });
      assert.equal(f.mutations().length, 1);
    }
  });

  test("a mismatched role in the current native detail reply is also an uncertain delivery", async (t) => {
    const f = fixture(t);
    f.state.reply = { status: "pressed", detail: `${BUNDLE} AXTextField Seven` };
    const observed = await f.observe();
    await assert.rejects(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), (error: unknown) => {
      assert.ok(error instanceof Error && !(error instanceof BackendRefusal));
      return true;
    });
    assert.equal(f.mutations().length, 1);
  });

  test("numeric matched-element or detail replies are errors after dispatch, never refusals", async (t) => {
    for (const reply of [{ status: "pressed", element: 42 }, { status: "pressed", detail: 42 }]) {
      const f = fixture(t);
      f.state.reply = reply;
      const observed = await f.observe();
      await assert.rejects(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), (error: unknown) => {
        assert.ok(error instanceof Error && !(error instanceof BackendRefusal));
        return true;
      });
      assert.equal(f.mutations().length, 1);
    }
  });

  test("native status:error after dispatch remains an error with uncertain delivery", async (t) => {
    const f = fixture(t);
    f.state.reply = { status: "error", detail: "Accessibility value was not applied" };
    const observed = await f.observe();
    await assert.rejects(f.act(observed, { kind: "press", ref: observed.ax![1]!.ref }), (error: unknown) => {
      assert.ok(error instanceof Error && !(error instanceof BackendRefusal));
      assert.match(error.message, /not applied/);
      return true;
    });
  });

  test("setValue uses the label matcher and AX value command; type with ref never becomes setValue", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: "Search", role: "AXTextField", actions: [], settableAttributes: ["value"] }));
    const observed = await f.observe();
    const result = await f.act(observed, { kind: "setValue", ref: observed.ax![1]!.ref, value: "query" });
    assert.equal(result.mechanism, "ax-set-value");
    assert.deepEqual(f.mutations().at(-1), { command: "set-accessibility-value", args: ["--bundle-id", BUNDLE, "--label", "Search", "--role", "AXTextField", "--value", "query"] });
    const current = await f.observe();
    const count = f.mutations().length;
    await refusal(f.act(current, { kind: "type", ref: current.ax![1]!.ref, text: "text" }), "unsupported");
    assert.equal(f.mutations().length, count);
  });

  test("secondary uses a named native AX action", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ actions: ["AXPress", "AXConfirm"] }));
    const observed = await f.observe();
    const result = await f.act(observed, { kind: "secondary", ref: observed.ax![1]!.ref, name: "AXConfirm" });
    assert.equal(result.tierUsed, "semantic");
    assert.deepEqual(f.mutations(), [{ command: "perform-accessibility-action", args: ["--bundle-id", BUNDLE, "--label", "Seven", "--role", "AXButton", "--action", "AXConfirm"] }]);
  });

  test("attention actions use global HID commands and screen coordinates", async (t) => {
    const f = fixture(t);
    const commands: Array<[BackendAction, Sent, string]> = [
      [{ kind: "type", text: "hello" }, { command: "type-text", args: ["--text", "hello"] }, "hid-type"],
      [{ kind: "key", combo: "cmd+shift+a" }, { command: "press-key", args: ["--key", "a", "--modifiers", "cmd,shift"] }, "hid-key"],
      [{ kind: "click", point: { x: -120, y: 500 } }, { command: "click-point", args: ["--x", "-120", "--y", "500"] }, "hid-click"],
      [{ kind: "scroll", point: { x: 20, y: 30 }, direction: "down", amount: 80 }, { command: "scroll", args: ["--x", "20", "--y", "30", "--delta-x", "0", "--delta-y", "-80"] }, "hid-scroll"],
    ];
    for (const [action, expected, mechanism] of commands) {
      const observed = await f.observe();
      const result = await f.act(observed, action);
      assert.equal(result.tierUsed, "attention");
      assert.equal(result.mechanism, mechanism);
      assert.deepEqual(f.mutations().at(-1), expected);
    }
    const observed = await f.observe();
    await f.act(observed, { kind: "scroll", ref: observed.ax![1]!.ref, direction: "left", amount: 40 });
    assert.deepEqual(f.mutations().at(-1), { command: "scroll", args: ["--x", "25", "--y", "40", "--delta-x", "40", "--delta-y", "0"] });
  });

  test("lists only real windows: helper slivers, strips and badges are left out", async (t) => {
    const f = windowFixture(t);
    const base = WINDOWS[0]!;
    f.state.windows = [base,
      { ...base, windowNumber: 102, title: "", frame: { x: 0, y: 0, width: 1, height: 1 }, onScreen: false },
      { ...base, windowNumber: 103, title: "", frame: { x: 0, y: 0, width: 1440, height: 30 }, onScreen: false },
      { ...base, windowNumber: 104, title: "Badge", frame: { x: 0, y: 0, width: 54, height: 54 } },
      { ...base, windowNumber: 106, title: "Other Space", onScreen: false }];
    assert.deepEqual((await f.backend.targets(call())).map((target) => target.targetId.split(":").at(-1)), ["101", "106"]);
  });

  test("click asks the host to restore focus and pointer (auto by default) and reports what it did", async (t) => {
    for (const [restore, mode] of [[undefined, "auto"], [true, "true"], ["false", "false"]] as const) {
      const f = fixture(t, restore === undefined ? {} : { restore });
      f.state.capabilities = { restoringInputCommands: ["click-point"] };
      f.state.reply = { status: "clicked", detail: `10,20 ${mode === "auto" ? "clean-run" : mode === "true" ? "restored" : ""}`.trim() };
      const observed = await f.observe();
      const result = await f.act(observed, { kind: "click", point: { x: 10, y: 20 } });
      assert.deepEqual(f.mutations().at(-1), { command: "click-point", args: ["--x", "10", "--y", "20", "--restore", mode] });
      assert.equal(result.message, f.state.reply.detail);
    }
    const old = fixture(t);
    const observed = await old.observe();
    await old.act(observed, { kind: "click", point: { x: 10, y: 20 } });
    assert.deepEqual(old.mutations().at(-1), { command: "click-point", args: ["--x", "10", "--y", "20"] });
  });

  test("unsupported click gestures and unknown key names do not degrade to different input", async (t) => {
    const f = fixture(t);
    const observed = await f.observe();
    await refusal(f.act(observed, { kind: "click", point: { x: 1, y: 2 }, button: "right" }), "unsupported");
    await refusal(f.act(observed, { kind: "click", point: { x: 1, y: 2 }, count: 2 }), "unsupported");
    await refusal(f.act(observed, { kind: "key", combo: "cmd+not-a-key" }), "invalid-action");
    assert.deepEqual(f.mutations(), []);
  });

  test("values the native argument parser cannot represent are refused before dispatch", async (t) => {
    const f = fixture(t);
    f.state.nodes = complete(node({ title: "Search", role: "AXTextField", actions: [], settableAttributes: ["value"] }));
    const observed = await f.observe();
    for (const text of ["", "--not-a-value", "embedded\0nul"]) {
      await refusal(f.act(observed, { kind: "type", text }), "unsupported");
      await refusal(f.act(observed, { kind: "setValue", ref: observed.ax![1]!.ref, value: text }), "unsupported");
    }
    assert.deepEqual(f.mutations(), []);
    for (const title of ["--not-a-label", "embedded\0nul"]) {
      f.state.nodes = complete(node({ title }));
      const current = await f.observe();
      await refusal(f.act(current, { kind: "press", ref: current.ax![1]!.ref }), "unsupported");
    }
    assert.deepEqual(f.mutations(), []);
  });

  test("screenshot observation writes only through the fake native screenshot command", async (t) => {
    const f = fixture(t);
    const observed = await f.backend.observe(call(), TARGET, { screenshot: true });
    assert.ok(observed.screenshot);
    const screenshot = f.calls.find(({ command }) => command === "screenshot-app-window")!;
    assert.deepEqual(screenshot.args, ["--bundle-id", BUNDLE, "--output", observed.screenshot.path]);
    assert.equal(readFileSync(observed.screenshot.path).readUInt32BE(0), 0x89504e47);
  });

  test("availability verifies the native permission status without requesting grants", async (t) => {
    const f = fixture(t);
    assert.equal((await f.backend.availability(call())).ready, true);
    assert.deepEqual(f.calls, [{ command: "capabilities", args: [] }, { command: "status", args: [] }]);
  });

  test("availability reports the capability version and path support only in a not-ready reason", async (t) => {
    for (const supported of [true, false]) {
      const f = fixture(t);
      f.state.capabilities = { build: { version: "0.4.0-test" }, accessibilityPathCommands: supported ? PATH_COMMANDS : [] };
      f.state.status = { accessibility: "denied", screenRecording: "granted" };
      const unavailable = await f.backend.availability(call());
      assert.equal(unavailable.ready, false);
      assert.equal(unavailable.version, "0.4.0-test");
      assert.match(unavailable.reason!, /path.*(?:support|available)/i);
      assert.match(unavailable.reason!, supported ? /(?:supported|available)(?!.*(?:not|un))/i : /(?:not supported|unsupported|unavailable)/i);
      f.state.status = { accessibility: "granted", screenRecording: "granted" };
      assert.deepEqual(await f.backend.availability(call()), { ready: true, version: "0.4.0-test" });
      assert.equal(f.calls.filter(({ command }) => command === "capabilities").length, 1);
    }
  });

  test("availability reads a fake bundle version and checks permissions through the fake host", async (t) => {
    const f = fixture(t);
    const app = join(f.dir, "Action.app");
    const contents = join(app, "Contents");
    const marker = join(f.dir, "unexpected-launch");
    mkdirSync(join(contents, "MacOS"), { recursive: true });
    const quotedMarker = `'${marker.replaceAll("'", "'\\''")}'`;
    writeFileSync(join(contents, "MacOS/Action"), `#!/bin/sh\nprintf launched > ${quotedMarker}\n`, { mode: 0o755 });
    writeFileSync(join(contents, "Info.plist"), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>4.3.2-test</string></dict></plist>');
    const backend = createActionCuaBackend({ ...f.ctx, options: { app, __run: f.ctx.options.__run } });
    t.after(() => backend.dispose());
    assert.deepEqual(await backend.availability(call()), { ready: true, version: "4.3.2-test" });
    rmSync(join(contents, "Info.plist"));
    assert.deepEqual(await backend.availability(call()), { ready: true });
    assert.equal(existsSync(marker), false);
    assert.deepEqual(f.calls, [{ command: "capabilities", args: [] }, { command: "status", args: [] }, { command: "status", args: [] }]);
  });

  test("app capability discovery executes the fake bundle binary directly and stops on its error", async (t) => {
    const f = fixture(t);
    const app = join(f.dir, "Action.app");
    const executable = join(app, "Contents/MacOS/Action");
    const marker = join(f.dir, "capability-argv.json");
    mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
    // Return an error so availability stops before the permission command's
    // LaunchServices route. This script has no AppKit or real Action dependency.
    writeFileSync(executable, `#!${process.execPath}\nimport { writeFileSync } from "node:fs";
writeFileSync(${JSON.stringify(marker)}, JSON.stringify(process.argv.slice(2)));
console.log(JSON.stringify({ status: "error", detail: "fake-capability-stop" }));\n`, { mode: 0o755 });
    const backend = createActionCuaBackend({ ...f.ctx, options: { app } });
    t.after(() => backend.dispose());
    const inheritedHost = process.env.ACTION_NATIVE_HOST;
    delete process.env.ACTION_NATIVE_HOST;
    try {
      const status = await backend.availability(call());
      assert.equal(status.ready, false);
      assert.match(status.reason!, /fake-capability-stop/);
      assert.deepEqual(JSON.parse(readFileSync(marker, "utf8")), ["capabilities"]);
    } finally {
      if (inheritedHost === undefined) delete process.env.ACTION_NATIVE_HOST;
      else process.env.ACTION_NATIVE_HOST = inheritedHost;
    }
  });

  test("a pre-aborted call sends no native command", async (t) => {
    const f = fixture(t);
    const controller = new AbortController();
    controller.abort();
    await refusal(f.backend.observe(call(controller.signal), TARGET, {}), "unavailable");
    assert.deepEqual(f.calls, []);
  });

  test("a nonzero fake launcher preserves structured path-mismatch evidence", async (t) => {
    const f = pathFixture(t);
    const launcher = join(f.dir, "fake-path-host.js");
    // This executable only returns fixture JSON; it never runs Action.app.
    writeFileSync(launcher, `#!${process.execPath}\nconst command = process.argv[2];
if (command === "capabilities") {
  console.log(JSON.stringify(${JSON.stringify(f.state.capabilities)}));
} else if (command === "inspect-app-ui") {
  console.log(JSON.stringify(${JSON.stringify(f.state.nodes)}));
} else if (command === "press-accessibility-path") {
  console.log(JSON.stringify({ status: "error", detail: "path-mismatch: child no longer exists" }));
  process.exitCode = 1;
} else {
  throw new Error("Unexpected fake command " + command);
}\n`, { mode: 0o755 });
    const backend = createActionCuaBackend({ ...f.ctx, options: { host: launcher } });
    t.after(() => backend.dispose());
    const observed = await backend.observe(call(), TARGET, {});
    const error = await refusal(backend.act(call(), TARGET, { kind: "press", ref: observed.ax![1]!.ref }, {
      observationId: observed.observationId, allowTiers: ["semantic"],
    }), "stale-ref");
    assert.ok(error.observation);
    assert.notEqual(error.observation.observationId, observed.observationId);
  });

  test("cancelling an executable fake launcher kills its child and reports uncertain delivery", async (t) => {
    const f = fixture(t);
    const launcher = join(f.dir, "fake-host.sh");
    const pidFile = join(f.dir, "fake-host.pid");
    const quotedPidFile = `'${pidFile.replaceAll("'", "'\\''")}'`;
    // exec keeps the same PID, so this checks the actual child is killed. It
    // cannot open Action.app: the only process this fake launcher runs is sleep.
    writeFileSync(launcher, `#!/bin/sh\nprintf '%s' "$$" > ${quotedPidFile}\nexec /bin/sleep 30\n`, { mode: 0o755 });
    const backend = createActionCuaBackend({ ...f.ctx, options: { host: launcher } });
    let pid: number | undefined;
    t.after(async () => {
      await backend.dispose();
      if (pid !== undefined) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    });
    const controller = new AbortController();
    const pending = backend.observe(call(controller.signal), TARGET, { screenshot: false });
    // Attach rejection handling before abort to avoid an unhandled rejection.
    const rejected = assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof Error && !(error instanceof BackendRefusal));
      assert.match(error.message, /cancel|uncertain|abort/i);
      return true;
    });
    const startedBy = Date.now() + 2_000;
    while (!existsSync(pidFile) && Date.now() < startedBy) await delay(10);
    assert.ok(existsSync(pidFile), "fake launcher should have started");
    pid = Number(readFileSync(pidFile, "utf8"));
    assert.ok(Number.isInteger(pid) && pid > 0);
    controller.abort();
    await rejected;
    const exitedBy = Date.now() + 2_000;
    let alive = true;
    while (alive && Date.now() < exitedBy) {
      try { process.kill(pid, 0); await delay(10); }
      catch (error) {
        assert.equal((error as NodeJS.ErrnoException).code, "ESRCH");
        alive = false;
      }
    }
    assert.equal(alive, false, "aborting the backend call should kill its launcher child");
  });

  test("the registry exposes the exact tier table and the host blocks unallowed attention", async (t) => {
    const f = fixture(t);
    assert.equal(computerBackends["action-cua"]?.factory, createActionCuaBackend);
    assert.equal(computerBackends["action-cua"]?.summary, "Action's own native host (Action.app): AX press/set-value by label, HID input for attention.");
    assert.deepEqual(f.backend.capabilities, {
      surfaces: ["computer"], observe: { ax: true, screenshot: true },
      actions: { press: "semantic", setValue: "semantic", secondary: "semantic", type: "attention", key: "attention", click: "attention", scroll: "attention" },
    });
    const configPath = join(f.dir, "backends.json");
    writeFileSync(configPath, "{}");
    const host = new BackendHost({
      configPath, shotsDir: f.dir, log: () => {},
      backends: { "action-cua": { factory: () => f.backend, summary: "fake Action" } },
    });
    const observed = await f.observe();
    await refusal(host.act("action-cua", TARGET, { kind: "type", text: "hello" }, { observationId: observed.observationId, allowTiers: ["observe", "semantic"] }), "tier-not-allowed");
    assert.deepEqual(f.mutations(), []);
    const result = await host.act("action-cua", TARGET, { kind: "type", text: "hello" }, { observationId: observed.observationId, allowTiers: ["observe", "attention"] });
    assert.equal(result.declaredTier, "attention");
    assert.equal(result.tierExceeded, false);
  });
});
