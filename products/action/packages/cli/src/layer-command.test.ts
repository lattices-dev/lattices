import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { parseLayerCommand } from "./layer-command.js";
import { fileURLToPath } from "node:url";

test("layer parsing preserves documented flags and record verbs", () => {
  assert.deepEqual(parseLayerCommand(["open", "--bundle-id", "com.apple.calculator", "--pip=off", "--width", "1280"]), { positionals: ["open"], flags: { "bundle-id": "com.apple.calculator", pip: "off", width: "1280" } });
  assert.deepEqual(parseLayerCommand(["snapshot", "--full", "--out", "a file.png"]).flags, { full: "true", out: "a file.png" });
  assert.deepEqual(parseLayerCommand(["record", "start", "--out=a.mov"]).positionals, ["record", "start"]);
  assert.deepEqual(parseLayerCommand([]).positionals, ["status"]);
  assert.equal(parseLayerCommand(["pip", "--preview-full"]).flags["preview-full"], "true");
  assert.equal(parseLayerCommand(["open", "--preview-full=false"]).flags["preview-full"], "false");
  assert.throws(() => parseLayerCommand(["open", "--preview-full=maybe"]), /expected true or false/);
});

test("named workspaces target every operation and reject recursive previews", () => {
  for (const verb of ["prepare", "display-status", "open", "close", "release", "status", "snapshot", "pip"]) {
    assert.equal(parseLayerCommand([verb, "--workspace", "agent"]).flags.workspace, "agent");
  }
  assert.equal(parseLayerCommand(["record", "start", "--workspace", "stage"]).flags.workspace, "stage");
  assert.equal(parseLayerCommand(["record", "stop", "--workspace", "agent"]).flags.workspace, "agent");
  assert.deepEqual(parseLayerCommand(["pip", "--workspace", "agent", "--preview-workspace", "stage"]).flags,
    { workspace: "agent", "preview-workspace": "stage" });
  for (const args of [["open", "--workspace", "../stage"], ["pip", "--workspace", "agent", "--preview-workspace", "agent"], ["list", "--workspace", "stage"]]) {
    assert.throws(() => parseLayerCommand(args));
  }
});

test("unsupported browser flags and interaction verbs give MCP routing", () => {
  for (const args of [["open", "--browser"], ["open", "--url", "https://example.com"], ["click"], ["js"], ["record", "resume"], ["status", "--browser"]]) {
    assert.throws(() => parseLayerCommand(args), /MCP layer_open/);
  }
});

test("persistent monitor setup and teardown are explicit commands", () => {
  assert.deepEqual(parseLayerCommand(["prepare", "--width=1440", "--height", "900"]), { positionals: ["prepare"], flags: { width: "1440", height: "900" } });
  for (const command of ["prepare", "display-status", "release"]) {
    assert.deepEqual(parseLayerCommand([command]), { positionals: [command], flags: {} });
  }
  for (const args of [["prepare", "--browser"], ["prepare", "--bundle-id=app"], ["prepare", "--width=-1"], ["prepare", "--height=0"], ["display-status", "--width=1440"], ["release", "--force"], ["release", "--clear-quarantine"]]) {
    assert.throws(() => parseLayerCommand(args));
  }
});

test("invalid and silently ignored arguments are rejected", () => {
  for (const args of [["open", "unexpected"], ["open", "--width"], ["open", "--width", "no"], ["open", "--pid=0"], ["open", "--pip=maybe"], ["open", "--width=1280", "--width=1440"], ["open", "--bundle-id=a", "--pid=123"], ["snapshot", "--full", "--window-id=5"], ["close", "extra"]]) {
    assert.throws(() => parseLayerCommand(args));
  }
});

test("CLI rejects unsupported requests before invoking the native host", () => {
  const cli = fileURLToPath(new URL("./main.ts", import.meta.url));
  for (const args of [["layer", "open", "--browser", "--url", "https://example.com"], ["layer", "click", "--x", "10"]]) {
    const result = spawnSync("bun", [cli, ...args], { env: { ...process.env, ACTION_NATIVE_HOST: "/nonexistent/must-not-run" }, encoding: "utf8", timeout: 10_000 });
    const output = JSON.parse(result.stdout);
    assert.equal(result.status, 1);
    assert.equal(output.ok, false);
    assert.match(output.error, /MCP layer_open/);
    assert.doesNotMatch(output.error, /ENOENT/);
  }
});
