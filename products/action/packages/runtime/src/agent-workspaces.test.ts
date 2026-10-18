import assert from "node:assert/strict";
import { existsSync, rmSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentLayerDirector, agentLayerStateDir, agentLayerWorkspaces, agentWorkspaceSerial, parseAgentWorkspace } from "./agent-layer.js";

test("workspace identifiers are stable and cannot escape their registry", () => {
  assert.equal(parseAgentWorkspace(), "default");
  assert.equal(agentWorkspaceSerial("default"), 0x41435401);
  assert.equal(agentWorkspaceSerial("stage"), agentWorkspaceSerial("stage"));
  assert.notEqual(agentWorkspaceSerial("stage"), agentWorkspaceSerial("agent"));
  assert.equal(agentLayerStateDir("stage"), join(agentLayerStateDir(), "workspaces", "stage"));
  for (const value of ["", "../stage", "/stage", "Stage", "two words", "stage\n", "0stage", "x".repeat(33), null, 5]) {
    assert.throws(() => parseAgentWorkspace(value), /workspace must/);
  }
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "action-workspaces-"));
  const live = new Map<number, { stop: string; state: string }>();
  const calls: string[][] = [];
  let nextPid = 10000;
  const create = (workspace: string) => new AgentLayerDirector("/unused", {
    root, workspace, safetyPath: join(root, "safety.json"), stateWaitMs: 200, closeWaitMs: 100,
    isAlive(pid) {
      const processState = live.get(pid);
      if (processState && existsSync(processState.stop)) {
        rmSync(processState.state, { force: true });
        live.delete(pid);
      }
      return live.has(pid);
    },
    terminate() { throw new Error("Should not force-terminate another workspace"); },
    async runHost(args) {
      calls.push(args);
      const flag = (name: string) => args[args.indexOf(`--${name}`) + 1];
      const pid = nextPid++;
      const state = flag("state-file");
      live.set(pid, { stop: flag("stop-file"), state });
      const display = args[0] === "agent-display";
      await writeFile(state, JSON.stringify(display ? {
        schemaVersion: 1, workspace, pid, displayId: pid, serialNumber: agentWorkspaceSerial(workspace),
        startedAt: new Date().toISOString(), width: Number(flag("width")), height: Number(flag("height")),
      } : {
        workspace, pid, displayId: Number(flag("display-id")), startedAt: new Date().toISOString(),
        bounds: { x: 5000, y: 5000, width: 1440, height: 900 }, pip: flag("pip") !== "off", windows: [],
        ...(args.includes("--preview-display-id") ? { previewDisplayId: Number(flag("preview-display-id")) } : {}),
      }));
      return { stdout: JSON.stringify({ status: display ? "agent-display-running" : "agent-layer-running", detail: String(pid) }) };
    },
  });
  return { root, create, calls, cleanup: () => rm(root, { recursive: true, force: true }) };
}

test("two workspaces prepare, attach, and close without replacing each other", async () => {
  const context = await fixture();
  try {
    const stage = context.create("stage");
    const agent = context.create("agent");
    const [stageDisplay, agentDisplay] = await Promise.all([stage.prepareDisplay(), agent.prepareDisplay()]);
    assert.notEqual(stageDisplay.display?.displayId, agentDisplay.display?.displayId);
    assert.notEqual(stage.paths().state, agent.paths().state);
    const [stageSession, agentSession] = await Promise.all([
      stage.open({ pip: false, previewFull: true }), agent.open({ previewDisplayId: stageDisplay.display!.displayId }),
    ]);
    assert.equal(stageSession.workspace, "stage");
    assert.equal(agentSession.workspace, "agent");
    assert.equal(context.calls.every(args => args.includes("--workspace")), true);
    assert.equal(context.calls.some(args => args.includes("--preview-full")), true);
    await assert.rejects(stage.releaseDisplay(), /Close the active task explicitly/);
    assert.equal((await stage.status()).layer?.pid, stageSession.layer?.pid);
    assert.equal((await agent.close()).active, false);
    assert.equal((await stage.status()).layer?.pid, stageSession.layer?.pid);
    assert.equal((await agent.displayStatus()).active, true);
    assert.equal((await agent.releaseDisplay()).active, false);
    assert.equal((await stage.displayStatus()).active, true);
    assert.deepEqual(await agentLayerWorkspaces(context.root), ["default", "agent", "stage"]);
    await stage.close();
    await stage.releaseDisplay();
  } finally { await context.cleanup(); }
});

test("preview cycles fail before changing the current session", async () => {
  const context = await fixture();
  try {
    const stage = context.create("stage");
    const agent = context.create("agent");
    const stageDisplay = await stage.prepareDisplay();
    const agentDisplay = await agent.prepareDisplay();
    await stage.open();
    await agent.open({ previewDisplayId: stageDisplay.display!.displayId });
    const before = await stage.status();
    await assert.rejects(stage.open({ previewDisplayId: agentDisplay.display!.displayId }), /recursive workspace preview/);
    await assert.rejects(stage.showViewer({ previewDisplayId: agentDisplay.display!.displayId }), /recursive workspace preview/);
    await assert.rejects(agent.open({ previewDisplayId: agentDisplay.display!.displayId }), /recursive workspace preview/);
    assert.equal((await stage.status()).layer?.pid, before.layer?.pid);
  } finally { await context.cleanup(); }
});

test("foreign display and task manifests are rejected", async () => {
  const context = await fixture();
  try {
    const agent = context.create("agent");
    await agent.prepareDisplay();
    const original = JSON.parse(await readFile(agent.paths().displayState, "utf8"));
    await writeFile(agent.paths().displayState, JSON.stringify({ ...original, workspace: "stage" }));
    assert.equal((await agent.displayStatus()).state, "invalid");
    await assert.rejects(agent.open(), /invalid/);
    await writeFile(agent.paths().displayState, JSON.stringify({ ...original, serialNumber: agentWorkspaceSerial("stage") }));
    assert.equal((await agent.displayStatus()).state, "invalid");
    await writeFile(agent.paths().displayState, JSON.stringify(original));
    await agent.open();
    const state = JSON.parse(await readFile(agent.paths().state, "utf8"));
    await writeFile(agent.paths().state, JSON.stringify({ ...state, workspace: "stage" }));
    await assert.rejects(agent.close(), /different workspace/);
    assert.equal(existsSync(agent.paths().stop), false);
  } finally { await context.cleanup(); }
});

test("listing ignores invalid workspace directories", async () => {
  const context = await fixture();
  try {
    await mkdir(join(context.root, "workspaces", "not valid"), { recursive: true });
    await mkdir(join(context.root, "workspaces", "default"));
    assert.deepEqual(await agentLayerWorkspaces(context.root), ["default"]);
  } finally { await context.cleanup(); }
});

test("separate directors cannot replace an active task and stale ownership cannot close it", async () => {
  const context = await fixture();
  try {
    const first = context.create("agent");
    const second = context.create("agent");
    await first.prepareDisplay();
    const attempts = await Promise.allSettled([first.open(), second.open()]);
    assert.equal(attempts.filter(result => result.status === "fulfilled").length, 1);
    const original = (await first.status()).layer!;
    await first.close(original);
    const replacement = (await second.open()).layer!;
    await assert.rejects(first.close(original), /ownership changed/);
    assert.equal((await second.status()).layer?.pid, replacement.pid);
    await second.close(replacement);
  } finally { await context.cleanup(); }
});

test("release preserves the prepared display while another workspace previews onto it", async () => {
  const context = await fixture();
  try {
    const stage = context.create("stage");
    const agent = context.create("agent");
    const display = await stage.prepareDisplay();
    await agent.prepareDisplay();
    await agent.open({ previewDisplayId: display.display!.displayId });
    await assert.rejects(stage.releaseDisplay(), /Close the agent preview/);
    assert.equal((await stage.displayStatus()).active, true);
    assert.equal((await agent.status()).active, true);
    assert.equal(existsSync(stage.paths().displayStop), false);
  } finally { await context.cleanup(); }
});
