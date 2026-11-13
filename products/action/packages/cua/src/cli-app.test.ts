import assert from "node:assert/strict";
import { describe, test } from "node:test";
import type { AppControl, AppStatus } from "./app.js";
import { runCli, selectNode } from "./cli.js";
import { BackendHost } from "./host.js";

function fakeApp(overrides: Partial<AppControl> = {}) {
  const calls: string[] = [];
  const status: AppStatus = {
    installed: true, path: "/Applications/Action.app", version: "0.4.0", running: true,
    agentReachable: true, agentSocket: "/tmp/action.sock", bundleId: "dev.lattices.Action", checkout: null,
  };
  const app: AppControl = {
    async status() { calls.push("status"); return status; },
    async install(log) { calls.push("install"); log("Finding the latest Action release…"); return { version: "0.4.1", path: "/Applications/Action.app", changed: true }; },
    launch() { calls.push("launch"); return { path: "/Applications/Action.app", wasRunning: false }; },
    async quit() { calls.push("quit"); return true; },
    async call(method, params) { calls.push(`call:${method}:${JSON.stringify(params)}`); return { ok: true, result: { status: "pong" } }; },
    forward(args) { calls.push(`forward:${args.join(" ")}`); return 0; },
    ...overrides,
  };
  const stdout: string[] = [];
  const stderr: string[] = [];
  const options = { app, host: new BackendHost({ backends: {} }), stdout: (t: string) => { stdout.push(t); }, stderr: (t: string) => { stderr.push(t); } };
  return { app, calls, stdout, stderr, options };
}

describe("action CLI: Action.app commands", () => {
  test("install --launch installs, then opens the app", async () => {
    const f = fakeApp();
    assert.equal(await runCli(["install", "--launch", "--json"], f.options), 0);
    assert.deepEqual(f.calls, ["install", "launch"]);
    const body = JSON.parse(f.stdout.join(""));
    assert.equal(body.version, "0.4.1");
    assert.equal(body.launched, true);
    assert.match(f.stderr.join(""), /latest Action release/);
  });

  test("update is install, and --launch belongs to install alone", async () => {
    const f = fakeApp();
    assert.equal(await runCli(["update"], f.options), 0);
    assert.match(f.stdout.join(""), /Installed Action 0\.4\.1/);
    assert.equal(await runCli(["status", "--launch"], f.options), 1);
  });

  test("call passes params as an object and prints the agent's reply", async () => {
    const f = fakeApp();
    assert.equal(await runCli(["call", "ping", '{"a":1}'], f.options), 0);
    assert.deepEqual(f.calls, ['call:ping:{"a":1}']);
    assert.deepEqual(JSON.parse(f.stdout.join("")), { status: "pong" });
    assert.equal(await runCli(["call", "ping", "[1]"], f.options), 1);
  });

  test("call names the fix when the agent is unreachable", async () => {
    const f = fakeApp({ async call() { throw new Error("ENOENT"); } });
    assert.equal(await runCli(["call", "ping"], f.options), 1);
    assert.match(f.stderr.join(""), /action launch/);
  });

  test("quit reports an unconfirmed quit as a failure", async () => {
    const f = fakeApp({ async quit() { return false; } });
    assert.equal(await runCli(["quit"], f.options), 1);
  });

  test("status with no backend leads with Action.app", async () => {
    const f = fakeApp();
    assert.equal(await runCli(["status"], f.options), 0);
    assert.match(f.stdout.join(""), /^Action\.app: 0\.4\.0 \(\/Applications\/Action\.app\)/);
  });

  test("other commands go to a runtime checkout with their flags", async () => {
    const f = fakeApp();
    assert.equal(await runCli(["layer", "prepare", "--workspace", "demo"], f.options), 0);
    assert.deepEqual(f.calls, ["forward:layer prepare --workspace demo"]);
    const none = fakeApp({ forward: () => undefined });
    assert.equal(await runCli(["layer", "prepare"], none.options), 1);
    assert.match(none.stderr.join(""), /ACTION_ROOT/);
  });
});

test("^$ selects an element that has no label", () => {
  const nodes = [
    { ref: "o.1", depth: 0, role: "AXTextField", label: "Address and search bar" },
    { ref: "o.2", depth: 0, role: "AXTextField" },
  ];
  assert.equal(selectNode(nodes, "^$", { role: "AXTextField" }).ref, "o.2");
});
